import CoreMedia
import CoreVideo
import Foundation
import Observation
import OSLog
import VideoToolbox

/// Turns the console's H.264 into frames the headset can draw.
///
/// The Switch encodes 720p30 in hardware and hands SysDVR raw Annex-B. VideoToolbox on
/// the M2 decodes that in hardware too, so this whole path costs almost nothing — the
/// expensive part of the pipeline is the network, not the decode.
@MainActor
@Observable
final class VideoDecoder {
    /// The most recent frame. The view observes this and redraws.
    private(set) var frame: CVPixelBuffer?
    private(set) var framesDecoded = 0
    /// True until the first keyframe lands. Decoding a P-frame without its reference
    /// produces green mush, so the stream is deliberately silent until then.
    private(set) var waitingForKeyframe = true

    private let log = Logger(subsystem: "com.kagami.app", category: "decoder")
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
        frame = nil
        framesDecoded = 0
        waitingForKeyframe = true
    }

    /// Feeds one access unit straight off the wire.
    func decode(_ accessUnit: Data, timestampNanos: UInt64) {
        // SysDVR is asked to inject SPS/PPS ahead of every keyframe, so they arrive
        // glued to the picture and have to be peeled off before anything else.
        let (sets, picture) = AnnexB.separateParameterSets(accessUnit)
        if !sets.isEmpty, sets != parameterSets {
            parameterSets = sets
            rebuildSession()
        }

        if AnnexB.containsKeyframe(accessUnit) { waitingForKeyframe = false }
        guard !waitingForKeyframe, let session, let format, !picture.isEmpty else { return }

        var block = AnnexB.toLengthPrefixed(picture)
        guard !block.isEmpty else { return }
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

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            // VideoToolbox calls back off the main actor and CVImageBuffer is not
            // Sendable. The box carries it across: the buffer leaves the decoder
            // finished and is only ever read from here on — the drawing side never
            // writes to it.
            let ready = DecodedFrame(buffer: image)
            Task { @MainActor in
                self?.frame = ready.buffer
                self?.framesDecoded += 1
            }
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

/// Carries a `CVPixelBuffer` from the VideoToolbox callback to the main actor.
/// `@unchecked` is the discipline described at the use site: read-only from here.
private struct DecodedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
