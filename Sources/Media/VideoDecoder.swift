import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import OSLog
import Synchronization
import VideoToolbox

/// Decodes one access unit at a time off the main actor. The compressed side is no
/// longer bounded here — `VideoIngest` decides per packet whether this decoder should
/// keep the reference chain alive silently or actually emit a picture — and the
/// decoded side retains only the newest frame a consumer has not yet taken.
actor H264Decoder {
    private let log = Logger(subsystem: "com.kagami.app", category: "decoder")
    nonisolated let frames: AsyncStream<DecodedFrame>
    private let continuation: AsyncStream<DecodedFrame>.Continuation
    private let stats: PipelineStats?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    /// True until the first keyframe lands. Decoding a P-frame without its reference
    /// produces green mush, so the stream is deliberately silent until then.
    ///
    /// This only ever flips to `true` for a real break in the reference chain: before
    /// the first IDR, on a decode error, or when the SPS changes and the session is
    /// rebuilt. A slow network no longer sets it — `VideoIngest` keeps decoding every
    /// access unit while it catches up, it just tells VideoToolbox not to bother
    /// producing a picture for the ones behind the live edge.
    private var waitingForKeyframe = true
    /// Set only while a wait is one this decoder itself is tracking (as opposed to the
    /// constructor's initial default), so `keyframeWaitMillisTotal` never counts the
    /// time before the very first packet arrives.
    private var keyframeWaitStartedAt: ContinuousClock.Instant?

    init(stats: PipelineStats? = nil) {
        self.stats = stats
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
        keyframeWaitStartedAt = nil
    }

    func finish() {
        reset()
        continuation.finish()
    }

    /// Forces a wait for the next keyframe. Nothing in the normal pipeline calls this
    /// any more — a network stall is handled by suppressing output, not by breaking the
    /// reference chain — but it stays as the honest response to a caller who knows for a
    /// fact that decoded state upstream was lost.
    func recoverAfterDrop() {
        enterKeyframeWait()
    }

    /// Feeds one access unit straight off the wire. When `suppressOutput` is set, the
    /// picture is still decoded — so its reference frame is available for the next
    /// access unit — but VideoToolbox is asked not to bother producing a `CVPixelBuffer`
    /// for it, which is how the pipeline catches up to the live edge after a stall
    /// without ever waiting for a keyframe.
    func decode(_ accessUnit: Data, timestampMicros: UInt64, suppressOutput: Bool = false) throws {
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
        // Retried on every keyframe while there is no live session, not only when the
        // parameter sets themselves changed: a session that failed to build (a rare
        // VideoToolbox/CoreMedia allocation failure) leaves `parameterSets` already
        // holding byte-identical content to what the next IDR will carry, so
        // `parametersChanged` alone would never fire again and the decoder would be
        // stuck silently forever. `parsed.isKeyframe` keeps the retry off the far more
        // frequent P-frames, where there is nothing new to rebuild from anyway.
        if parameterSets.count >= 2, parametersChanged || (session == nil && parsed.isKeyframe) {
            try rebuildSession()
        }

        if parsed.isKeyframe { endKeyframeWaitIfNeeded() }
        guard !waitingForKeyframe, let session, let format, !parsed.lengthPrefixedPicture.isEmpty else { return }

        let block = parsed.lengthPrefixedPicture
        var length = block.count

        // Any failure from here on means this access unit never reached VideoToolbox at
        // all — if it was a P-frame, the reference chain it would have updated is now
        // missing, exactly like a rejected decode. `enterKeyframeWait()` is idempotent
        // (guarded by `waitingForKeyframe`), so this only ever costs one counter
        // increment even though `submit` below also calls it on its own failure path.
        do {
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

            try submit(sample, session: session, timestampMicros: timestampMicros, suppressOutput: suppressOutput)
        } catch {
            enterKeyframeWait()
            throw error
        }
    }

    /// Submits one sample to VideoToolbox, with the do-not-output hint when the pipeline
    /// is behind the live edge. `kVTDecodeFrame_DoNotOutputFrame` is documented as a
    /// hint, not a guarantee, so a decoder that refuses it is a real possibility this
    /// falls back for: retry the same sample without the hint (still under 2 ms per the
    /// measured decode cost) rather than treating a hint-related failure as a broken
    /// reference chain and forcing an unnecessary keyframe wait.
    private func submit(
        _ sample: CMSampleBuffer, session: VTDecompressionSession, timestampMicros: UInt64,
        suppressOutput: Bool
    ) throws {
        var result = attemptDecode(sample, session: session, timestampMicros: timestampMicros, doNotOutput: suppressOutput)
        if suppressOutput, result != noErr {
            log.notice("VideoToolbox rejected kVTDecodeFrame_DoNotOutputFrame; falling back to a normal decode")
            result = attemptDecode(sample, session: session, timestampMicros: timestampMicros, doNotOutput: false)
        }
        guard result == noErr else {
            enterKeyframeWait()
            throw DecodeFailure(status: result)
        }
    }

    private func attemptDecode(
        _ sample: CMSampleBuffer, session: VTDecompressionSession, timestampMicros: UInt64,
        doNotOutput: Bool
    ) -> OSStatus {
        let continuation = self.continuation
        let stats = self.stats
        let callbackStatus = Mutex<OSStatus>(noErr)
        // Without `.enableAsynchronousDecompression` the callback is documented to fire
        // before `VTDecompressionSessionDecodeFrame` returns, but that is a hint about
        // typical decoder behaviour, not a contract every hardware decoder honours.
        // Waiting on this instead of reading the Mutex immediately after the call
        // returns means a genuinely asynchronous callback is still observed correctly
        // rather than silently read as its stale `noErr` default. The wait costs
        // nothing in the documented (synchronous) case, because `done` is already
        // signalled by the time this line runs.
        let done = DispatchSemaphore(value: 0)
        let flags: VTDecodeFrameFlags = doNotOutput ? [._DoNotOutputFrame] : []
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: flags, infoFlagsOut: nil
        ) { status, _, image, _, _ in
            callbackStatus.withLock { $0 = status }
            if status == noErr, let image {
                // VideoToolbox calls back off the actor and CVImageBuffer is not
                // Sendable. The box carries it across: the buffer leaves the decoder
                // finished and is only ever read from here on — the drawing side never
                // writes to it.
                stats?.increment(\.framesDecoded)
                continuation.yield(DecodedFrame(buffer: image, timestampMicros: timestampMicros))
            }
            done.signal()
        }
        guard status == noErr else { return status }
        // Bounded well above the ~2 ms measured decode cost and the 33 ms frame budget,
        // so a genuinely wedged decoder cannot hang this actor forever — it is treated
        // as a decode error (a real one, since nothing decoded) instead.
        if done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            log.error("VideoToolbox decode callback did not fire within 200ms")
            return kVTVideoDecoderMalfunctionErr
        }
        return callbackStatus.withLock { $0 }
    }

    private func enterKeyframeWait() {
        guard !waitingForKeyframe else { return }
        waitingForKeyframe = true
        keyframeWaitStartedAt = .now
        stats?.increment(\.keyframeWaitsEntered)
    }

    private func endKeyframeWaitIfNeeded() {
        guard waitingForKeyframe else { return }
        waitingForKeyframe = false
        if let startedAt = keyframeWaitStartedAt {
            stats?.increment(\.keyframeWaitMillisTotal, by: milliseconds(startedAt.duration(to: .now)))
        }
        keyframeWaitStartedAt = nil
    }

    private func rebuildSession() throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        // Whatever reference frames the old session held are gone the moment it is
        // invalidated — called unconditionally, before either failure path below, so a
        // rebuild that fails to even produce a session still leaves the decoder in the
        // same recovered state a successful rebuild would, instead of leaving
        // `waitingForKeyframe` stale while `session` is nil.
        enterKeyframeWait()

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
    }
}

/// Carries a `CVPixelBuffer` off the actor. `@unchecked` is the discipline described at
/// the use site: read-only from here on.
struct DecodedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// The console's own capture timestamp, in microseconds — the same clock
    /// `SysDVRStream.Packet.header.timestamp` carries, so a caller can tell which
    /// access unit a decoded frame came from.
    let timestampMicros: UInt64
    let decodedAt = ContinuousClock.now

    init(buffer: CVPixelBuffer, timestampMicros: UInt64 = 0) {
        self.buffer = buffer
        self.timestampMicros = timestampMicros
    }
}

struct DecodeFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Video decoder failed (\(status))." }
}
