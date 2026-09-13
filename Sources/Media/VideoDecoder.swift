import CoreMedia
import CoreVideo
import Foundation
import OSLog
import Synchronization
import VideoToolbox

/// Decodes one access unit at a time off the main actor. The compressed queue is
/// bounded by SysDVRStream and the decoded queue retains only the newest frame.
actor H264Decoder {
    private let log = Logger(subsystem: "com.kagami.app", category: "decoder")
    nonisolated let frames: AsyncStream<DecodedFrame>
    private let continuation: AsyncStream<DecodedFrame>.Continuation

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    /// True until the first keyframe lands. Decoding a P-frame without its reference
    /// produces green mush, so the stream is deliberately silent until then.
    private var waitingForKeyframe = true

    init() {
        let channel = AsyncStream<DecodedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = channel.stream
        continuation = channel.continuation
    }

    isolated deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
        continuation.finish()
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
        waitingForKeyframe = true
    }

    func finish() {
        reset()
        continuation.finish()
    }

    func recoverAfterDrop() {
        // Keep SPS/PPS, but do not decode inter-predicted pictures until an IDR.
        waitingForKeyframe = true
    }

    /// Feeds one access unit straight off the wire.
    func decode(_ accessUnit: Data, timestampMicros: UInt64) throws {
        // One pass over the buffer does all of it: pulls out SPS/PPS (glued to every
        // keyframe because SysDVR is asked to inject them), notices whether this is a
        // keyframe, and leaves the picture already length-prefixed for VideoToolbox.
        let parsed = AnnexB.parse(accessUnit)
        var parametersChanged = false
        for incoming in parsed.parameterSets {
            guard let header = incoming.first else { continue }
            if let index = parameterSets.firstIndex(where: { ($0.first! & 0x1F) == (header & 0x1F) }
            ) {
                if parameterSets[index] != incoming {
                    parameterSets[index] = incoming
                    parametersChanged = true
                }
            } else {
                parameterSets.append(incoming)
                parametersChanged = true
            }
        }
        if parametersChanged, parameterSets.count >= 2 {
            try rebuildSession()
        }

        if parsed.isKeyframe { waitingForKeyframe = false }
        guard !waitingForKeyframe, let session, let format, !parsed.lengthPrefixedPicture.isEmpty else { return }

        let block = parsed.lengthPrefixedPicture
        var length = block.count

        var blockBuffer: CMBlockBuffer?
        // CoreMedia owns the compressed bytes. A pointer borrowed from Data must
        // never escape withUnsafeBytes, even when decode usually completes quickly.
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &blockBuffer)
        guard blockStatus == noErr, let blockBuffer else {
            throw DecodeFailure(status: blockStatus)
        }
        let copyStatus = block.withUnsafeBytes { pointer in
            CMBlockBufferReplaceDataBytes(
                with: pointer.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { throw DecodeFailure(status: copyStatus) }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(SysDVR.Format.frameRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(clamping: timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)

        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
            sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { throw DecodeFailure(status: sampleStatus) }

        let continuation = self.continuation
        let callbackStatus = Mutex<OSStatus>(noErr)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            callbackStatus.withLock { $0 = status }
            guard status == noErr, let image else { return }
            // VideoToolbox calls back off the actor and CVImageBuffer is not Sendable.
            // The box carries it across: the buffer leaves the decoder finished and is
            // only ever read from here on — the drawing side never writes to it.
            let ready = DecodedFrame(buffer: image)
            continuation.yield(ready)
        }
        let outputStatus = callbackStatus.withLock { $0 }
        guard status == noErr, outputStatus == noErr else {
            waitingForKeyframe = true
            throw DecodeFailure(status: status == noErr ? outputStatus : status)
        }
    }

    private func rebuildSession() throws {
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
            throw DecodeFailure(status: status)
        }
        format = description

        // Keep the decoder's native YUV planes; the video layer handles presentation.
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: VTDecompressionSession?
        let creationStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard creationStatus == noErr, created != nil else {
            throw DecodeFailure(status: creationStatus)
        }
        session = created
        if let created {
            VTSessionSetProperty(
                created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        waitingForKeyframe = true
    }
}

/// Carries a `CVPixelBuffer` off the actor. `@unchecked` is the discipline described at
/// the use site: read-only from here on.
struct DecodedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let decodedAt = ContinuousClock.now
}

struct DecodeFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Video decoder failed (\(status))." }
}
