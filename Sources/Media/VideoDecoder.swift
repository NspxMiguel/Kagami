import CoreMedia
import CoreVideo
import Foundation
import Observation
import OSLog
import VideoToolbox

/// The decoded picture, published for SwiftUI. Deliberately thin: everything expensive
/// lives in `H264Decoder`, off the main actor, and only ever reaches here as a finished
/// `CVPixelBuffer` — this class exists so the view has something cheap to observe.
@MainActor
@Observable
final class DecodedVideo {
    private(set) var frame: CVPixelBuffer?
    private(set) var framesDecoded = 0

    fileprivate func publish(_ buffer: CVPixelBuffer) {
        frame = buffer
        framesDecoded += 1
    }

    func reset() {
        frame = nil
        framesDecoded = 0
    }
}

/// Turns the console's H.264 into frames the headset can draw.
///
/// This is an `actor`, not `@MainActor`, on purpose: Annex-B parsing and building the
/// `CMSampleBuffer` for each frame is real CPU work, measured at 10-16ms per frame on a
/// busy scene — over a third of the 33ms budget a 30fps stream allows. Running that on
/// the main actor put it in direct competition with SwiftUI and RealityKit's own
/// per-frame work; the two only had to collide occasionally to fall behind, and once
/// behind, packets queued up and the receive loop could never catch back up — measured
/// as a frame rate that decayed over tens of seconds even though the console kept
/// sending a rock-steady 30 packets/sec the whole time (confirmed by reading the wire
/// protocol directly, bypassing this app entirely). Hardware decode itself is not the
/// bottleneck — the M-series video block barely notices 720p30 — the setup work around
/// it was, and it only had to run somewhere other than the render thread to stop
/// costing frames.
actor H264Decoder {
    private let log = Logger(subsystem: "com.kagami.app", category: "decoder")
    private let output: DecodedVideo

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    /// True until the first keyframe lands. Decoding a P-frame without its reference
    /// produces green mush, so the stream is deliberately silent until then.
    private var waitingForKeyframe = true

    init(output: DecodedVideo) {
        self.output = output
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
        waitingForKeyframe = true
        Task { @MainActor in output.reset() }
    }

    /// Feeds one access unit straight off the wire.
    func decode(_ accessUnit: Data, timestampNanos: UInt64) {
        // One pass over the buffer does all of it: pulls out SPS/PPS (glued to every
        // keyframe because SysDVR is asked to inject them), notices whether this is a
        // keyframe, and leaves the picture already length-prefixed for VideoToolbox.
        let parsed = AnnexB.parse(accessUnit)
        if !parsed.parameterSets.isEmpty, parsed.parameterSets != parameterSets {
            parameterSets = parsed.parameterSets
            rebuildSession()
        }

        if parsed.isKeyframe { waitingForKeyframe = false }
        guard !waitingForKeyframe, let session, let format, !parsed.lengthPrefixedPicture.isEmpty else { return }

        var block = parsed.lengthPrefixedPicture
        var length = block.count

        var blockBuffer: CMBlockBuffer?
        let blockStatus = block.withUnsafeMutableBytes { pointer -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: pointer.baseAddress,
                blockLength: length, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: length,
                flags: 0, blockBufferOut: &blockBuffer)
        }
        guard blockStatus == noErr, let blockBuffer else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(SysDVR.Format.frameRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)

        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
            sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { return }

        let output = self.output
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            // VideoToolbox calls back off the actor and CVImageBuffer is not Sendable.
            // The box carries it across: the buffer leaves the decoder finished and is
            // only ever read from here on — the drawing side never writes to it.
            let ready = DecodedFrame(buffer: image)
            Task { @MainActor in output.publish(ready.buffer) }
        }
    }

    private func rebuildSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil

        // The parameter sets must stay alive and contiguous for the duration of the
        // call, and CoreMedia wants non-optional pointers — hence the manual allocation
        // instead of nested `withUnsafeBytes`, which cannot be built in a loop.
        var addresses: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in parameterSets {
            let bytes = [UInt8](set)
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            copy.initialize(from: bytes, count: bytes.count)
            addresses.append(UnsafePointer(copy))
            sizes.append(bytes.count)
        }
        defer { addresses.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }

        var description: CMFormatDescription?
        let status = addresses.withUnsafeBufferPointer { pointers in
            sizes.withUnsafeBufferPointer { lengths in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: lengths.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            log.error("could not build the H.264 format description: \(status)")
            return
        }
        format = description

        // BGRA because that is what the RealityKit texture takes directly, with no
        // colour conversion step in between.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        session = created
        waitingForKeyframe = true
    }
}

/// Carries a `CVPixelBuffer` off the actor. `@unchecked` is the discipline described at
/// the use site: read-only from here on.
private struct DecodedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
