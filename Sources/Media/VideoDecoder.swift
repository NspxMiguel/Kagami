import CoreMedia
import CoreVideo
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
    /// Identifies which submission VideoToolbox's completion callback is allowed to
    /// actually deliver a frame for. Bumped by `reset()` and by `enterKeyframeWait()` —
    /// every point where this decoder declares the reference chain broken and moves on
    /// — and read from inside the completion closure itself, which runs on VideoToolbox's
    /// own thread rather than this actor's. A plain `Mutex` rather than actor-isolated
    /// state is exactly what makes that possible without a hop back onto the actor.
    ///
    /// This exists because `kVTDecodeFrame_DoNotOutputFrame`'s callback ordering is
    /// "a hint about typical decoder behaviour, not a contract every hardware decoder
    /// honours" (see `attemptDecode`), so a submission this decoder has already given up
    /// on — a timeout, a rebuilt session, a reset — can still have its callback fire
    /// later with a perfectly good image. Without this check that stale image would be
    /// pushed to the screen exactly like a fresh one, decoded against a reference chain
    /// this decoder itself already declared suspect.
    private let epoch = Mutex<UInt64>(0)

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

    func reset() async {
        if let session { invalidate(session) }
        session = nil
        format = nil
        parameterSets = []
        waitingForKeyframe = true
        keyframeWaitStartedAt = nil
        epoch.withLock { $0 &+= 1 }
    }

    func finish() async {
        await reset()
        continuation.finish()
    }

    /// Forces a wait for the next keyframe. Nothing in the normal pipeline calls this
    /// any more — a network stall is handled by suppressing output, not by breaking the
    /// reference chain — but it stays as the honest response to a caller who knows for a
    /// fact that decoded state upstream was lost.
    func recoverAfterDrop() async {
        await enterKeyframeWait()
    }

    /// Feeds one access unit straight off the wire. When `suppressOutput` is set, the
    /// picture is still decoded — so its reference frame is available for the next
    /// access unit — but VideoToolbox is asked not to bother producing a `CVPixelBuffer`
    /// for it, which is how the pipeline catches up to the live edge after a stall
    /// without ever waiting for a keyframe.
    ///
    /// Returns the produced frame, if this call actually produced one — `nil` while
    /// waiting for a keyframe, while suppressing output, or if this access unit carried
    /// no picture. The same frame is also yielded to `frames`; this return value only
    /// exists so a caller already holding this actor (`VideoIngest`, for the ambient
    /// sampler) can use it without a second hop through the async stream.
    @discardableResult
    func decode(_ accessUnit: Data, timestampMicros: UInt64, suppressOutput: Bool = false)
        async throws -> DecodedFrame?
    {
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
            try await rebuildSession()
        }

        if parsed.isKeyframe { endKeyframeWaitIfNeeded() }
        guard !waitingForKeyframe, let session, let format, !parsed.lengthPrefixedPicture.isEmpty
        else { return nil }

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

            return try await submit(
                sample, session: session, timestampMicros: timestampMicros,
                suppressOutput: suppressOutput)
        } catch {
            await enterKeyframeWait()
            throw error
        }
    }

    /// The result of one `VTDecompressionSessionDecodeFrame` call, distinguishing a
    /// synchronous rejection (no callback will ever follow) from a callback that never
    /// arrived in time (which may still be outstanding). That distinction is exactly
    /// what decides whether `submit` may safely resubmit the same sample.
    enum DecodeOutcome: Equatable {
        case success
        /// Either the decode call itself returned a non-`noErr` status, or its callback
        /// already fired (in time) with a non-`noErr` status. Either way, no completion
        /// for this submission is still pending, so the sample can be resubmitted.
        case rejectedSynchronously(OSStatus)
        /// The call was accepted (`noErr`) but its completion callback did not fire
        /// within the timeout. VideoToolbox may still be holding this exact submission
        /// — resubmitting it now would risk decoding the same access unit twice
        /// concurrently in the same stateful session, corrupting the reference chain
        /// or yielding a duplicate/stale frame. Always a hard failure, never retried.
        case timedOut
    }

    /// Whether a first attempt's outcome may be retried without the do-not-output hint.
    /// Pulled out as a pure function so the one rule that matters here — a timeout is
    /// never retried, only a genuine synchronous rejection is — can be tested without a
    /// real VideoToolbox session.
    static func shouldRetryWithoutHint(after first: DecodeOutcome, suppressOutput: Bool) -> Bool {
        guard suppressOutput, case .rejectedSynchronously = first else { return false }
        return true
    }

    /// Submits one sample to VideoToolbox, with the do-not-output hint when the pipeline
    /// is behind the live edge. `kVTDecodeFrame_DoNotOutputFrame` is documented as a
    /// hint, not a guarantee, so a decoder that refuses it is a real possibility this
    /// falls back for: retry the same sample without the hint (still under 2 ms per the
    /// measured decode cost) rather than treating a hint-related failure as a broken
    /// reference chain and forcing an unnecessary keyframe wait. That retry only ever
    /// happens on a *synchronous* rejection (see `shouldRetryWithoutHint`) — never after
    /// a timeout, since the original call could still be in flight then.
    private func submit(
        _ sample: CMSampleBuffer, session: VTDecompressionSession, timestampMicros: UInt64,
        suppressOutput: Bool
    ) async throws -> DecodedFrame? {
        let first = await attemptDecode(sample, session: session, timestampMicros: timestampMicros, doNotOutput: suppressOutput)
        let outcome: DecodeOutcome
        let frame: DecodedFrame?
        if Self.shouldRetryWithoutHint(after: first.outcome, suppressOutput: suppressOutput) {
            log.notice("VideoToolbox rejected kVTDecodeFrame_DoNotOutputFrame; falling back to a normal decode")
            let retry = await attemptDecode(sample, session: session, timestampMicros: timestampMicros, doNotOutput: false)
            outcome = retry.outcome
            frame = retry.frame
        } else {
            outcome = first.outcome
            frame = first.frame
        }
        switch outcome {
        case .success:
            return frame
        case .rejectedSynchronously(let status):
            await enterKeyframeWait()
            throw DecodeFailure(status: status)
        case .timedOut:
            await enterKeyframeWait()
            throw DecodeFailure(status: kVTVideoDecoderMalfunctionErr)
        }
    }

    /// Submits one sample and waits for VideoToolbox's completion callback without
    /// blocking any thread — the previous implementation blocked this actor's shared
    /// cooperative-pool thread on a `DispatchSemaphore` for up to 200 ms per call, which
    /// could starve every other actor sharing that pool (`VideoIngest`, the watchdog,
    /// `H264Decoder.reset()`/`finish()` itself) on any VideoToolbox hiccup. A suspended
    /// `Task.sleep` costs nothing while waiting, which is what makes this safe to do on
    /// every single access unit instead of only occasionally.
    ///
    /// The timeout and the callback race to resume the same continuation exactly once
    /// (`finish`, below); whichever loses is simply ignored rather than blocked on, the
    /// same shape as `SysDVRStream.receiveSomeWithIdleTimeout`'s race against a dead
    /// socket. Unlike that race, though, there is no way to force VideoToolbox's
    /// callback to fire early the way cancelling the connection forces a pending
    /// `receive` to complete — so a callback that loses the race is not cancelled, only
    /// ignored, and `epoch` is what keeps its eventual, late result from ever reaching
    /// `continuation` once this decoder has moved on.
    private func attemptDecode(
        _ sample: CMSampleBuffer, session: VTDecompressionSession, timestampMicros: UInt64,
        doNotOutput: Bool
    ) async -> (outcome: DecodeOutcome, frame: DecodedFrame?) {
        let continuation = self.continuation
        let stats = self.stats
        let log = self.log
        // `Mutex` is a non-copyable type, so `epoch` itself cannot be extracted into a
        // local the way `continuation`/`stats`/`log` are above — instead the closures
        // below reach it through `self.epoch` directly. That is safe without `await`
        // because it is a `let` stored property of `Sendable` type: an actor's own
        // immutable, thread-safe state is exactly what does not need isolation to read.
        let submissionEpoch = self.epoch.withLock { $0 }
        let frameBox = Mutex<DecodedFrame?>(nil)
        let resumed = Mutex(false)
        let flags: VTDecodeFrameFlags = doNotOutput ? [._DoNotOutputFrame] : []

        return await withCheckedContinuation { (cont: CheckedContinuation<(DecodeOutcome, DecodedFrame?), Never>) in
            @Sendable
            func finish(_ outcome: DecodeOutcome) {
                let shouldResume = resumed.withLock { already -> Bool in
                    defer { already = true }
                    return !already
                }
                guard shouldResume else { return }
                cont.resume(returning: (outcome, frameBox.withLock { $0 }))
            }

            // Bounded well above the ~2 ms measured decode cost and the 33 ms frame
            // budget, so a genuinely wedged decoder cannot hang this actor forever.
            let timeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                // Bumped here, not only in the caller's later `enterKeyframeWait()`:
                // this closes the race where VideoToolbox's callback fires in the
                // instant right after the timeout wins but before the actor gets back
                // around to declaring the reference chain broken.
                self.epoch.withLock { $0 &+= 1 }
                log.error("VideoToolbox decode callback did not fire within 200ms")
                finish(.timedOut)
            }

            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample,
                flags: flags, infoFlagsOut: nil
            ) { status, _, image, _, _ in
                // Whichever of the timeout task or this callback runs first cancels
                // the other's reason to do anything further; cancelling here is what
                // stops a callback that arrives just past 200ms from racing the
                // timeout's own epoch bump below.
                timeoutTask.cancel()
                if status == noErr, let image, self.epoch.withLock({ $0 }) == submissionEpoch {
                    // VideoToolbox calls back off the actor and CVImageBuffer is not
                    // Sendable. The box carries it across: the buffer leaves the
                    // decoder finished and is only ever read from here on — the
                    // drawing side never writes to it. The epoch check above is what
                    // makes this safe to do without being isolated to the actor: a
                    // stale epoch means this decoder already gave up on this exact
                    // submission (a timeout, a rebuilt session, a reset) and moved on,
                    // so yielding this image now would push a picture decoded against
                    // a reference chain already declared suspect.
                    stats?.increment(\.framesDecoded)
                    let frame = DecodedFrame(buffer: image, timestampMicros: timestampMicros)
                    frameBox.withLock { $0 = frame }
                    continuation.yield(frame)
                }
                finish(status == noErr ? .success : .rejectedSynchronously(status))
            }
            // A non-noErr return here means VideoToolbox rejected the submission
            // outright — per Apple's documented contract for
            // VTDecompressionSessionDecodeFrame, the callback fires if and only if the
            // frame was accepted (status == noErr from this call), so no callback will
            // ever follow and there is nothing pending to wait for.
            if status != noErr {
                timeoutTask.cancel()
                finish(.rejectedSynchronously(status))
            }
        }
    }

    private func enterKeyframeWait() async {
        guard !waitingForKeyframe else { return }
        waitingForKeyframe = true
        keyframeWaitStartedAt = .now
        stats?.increment(\.keyframeWaitsEntered)
        epoch.withLock { $0 &+= 1 }
        // A decode failure means this exact session may be the problem, not only the
        // bitstream — most notably, a single long-lived `VTDecompressionSession` can
        // only decode roughly 16k access units before VideoToolbox starts
        // synchronously rejecting every submission with `kVTVideoDecoderMalfunctionErr`
        // (measured directly against this decoder; see VideoIngestTests). Tearing the
        // session down here, on every path that declares the reference chain broken —
        // not only when the parameter sets themselves changed — guarantees `decode`'s
        // rebuild guard (`session == nil && parsed.isKeyframe`) actually fires on the
        // very next keyframe. Without this, SysDVR re-sending byte-identical SPS/PPS
        // ahead of every keyframe meant `parametersChanged` never fired again once the
        // first session existed, so every later IDR just resubmitted to the same
        // already-wedged session, which rejected it identically — forever, once per
        // incoming keyframe.
        if let session {
            invalidate(session)
            self.session = nil
        }
        format = nil
    }

    private func endKeyframeWaitIfNeeded() {
        guard waitingForKeyframe else { return }
        waitingForKeyframe = false
        if let startedAt = keyframeWaitStartedAt {
            stats?.increment(\.keyframeWaitMillisTotal, by: milliseconds(startedAt.duration(to: .now)))
        }
        keyframeWaitStartedAt = nil
    }

    /// Gives any asynchronous decode still outstanding on `session` a chance to
    /// retire before the session is thrown away. Per Apple's documented contract for
    /// `VTDecompressionSessionInvalidate`, invalidating a session while a
    /// decompression is still outstanding — the one real possibility in this decoder
    /// being `attemptDecode`'s 200 ms timeout path, where this actor deliberately
    /// moves on without ever learning whether VideoToolbox's callback is still going
    /// to fire — risks leaking whatever hardware or software decode resource that
    /// submission was holding rather than returning it to the pool a later session
    /// could use.
    ///
    /// Deliberately fire-and-forget rather than awaited: `VTDecompressionSessionWait-
    /// ForAsynchronousFrames` is a genuinely blocking call with no documented upper
    /// bound, and a session that is truly wedged may never retire anything. Blocking
    /// this actor on it would risk trading one hang (a permanently frozen decoder)
    /// for a worse one (a permanently frozen actor); running it detached means the
    /// worst case is a single background thread parked for a while, not this
    /// decoder's own ability to move on to rebuilding a replacement session.
    /// `session` is not `Sendable`, so it crosses into the detached work as a bare
    /// pointer — `passRetained`/`takeRetainedValue` add and then consume one extra
    /// retain specifically so the object stays alive for the background call even
    /// though the caller (`enterKeyframeWait`/`reset`) clears its own `self.session`
    /// to `nil` immediately after this returns.
    private nonisolated func invalidate(_ session: VTDecompressionSession) {
        // `Unmanaged` itself carries no Sendable conformance (it says nothing about
        // whether crossing an isolation boundary with it is actually safe), so it is
        // wrapped the same way `DecodedFrame` wraps `CVPixelBuffer` just below: the
        // discipline living at this one use site — a single extra retain consumed by
        // exactly one background closure — is what makes it safe here, not the type.
        let retained = UnsafeTransfer(value: Unmanaged.passRetained(session))
        DispatchQueue.global(qos: .userInitiated).async {
            let session = retained.value.takeRetainedValue()
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    private func rebuildSession() async throws {
        if let session { invalidate(session) }
        session = nil
        format = nil
        // Whatever reference frames the old session held are gone the moment it is
        // invalidated — called unconditionally, before either failure path below, so a
        // rebuild that fails to even produce a session still leaves the decoder in the
        // same recovered state a successful rebuild would, instead of leaving
        // `waitingForKeyframe` stale while `session` is nil.
        await enterKeyframeWait()

        // Deliberately no backoff before rebuilding: a decode error followed by an
        // IDR must recover on that IDR, not several seconds later. An earlier attempt
        // added a growing delay here on the theory that a session which fails
        // immediately after being rebuilt might need real wall-clock time before a
        // replacement can work — but that delay ran *inside* this call, which
        // `VideoIngest.accept` awaits directly from `Session.runVideo`'s per-packet
        // loop. Once several IDRs in a row kept failing, the delay grew to multiple
        // seconds, which blocked that loop from draining the socket for that long,
        // which made the next packet's `receiveBacklogMillis` look like the
        // *connection* had fallen behind — tripping `VideoIngest.hardBacklogCeiling`
        // and forcing an ordinary reconnect that had nothing to do with the real
        // problem. That reconnect, in turn, was not tagged `.decoderWedged`, so it
        // reset `Session.runVideo`'s own give-up counter every time — which is why a
        // soak measured 19-21 reconnects with the pipeline never once concluding it
        // should stop trying. If the underlying cause is transient, rebuilding
        // immediately recovers on the very next keyframe with no perceptible delay,
        // exactly like a single bad access unit always has. If it is not transient,
        // no amount of waiting here was ever going to fix it — see
        // `VideoIngest.selfHealIfWedged` and `Session.runVideo`'s own backoff for the
        // policy that actually bounds a failure that keeps recurring.

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

/// A one-off vehicle for handing a single non-`Sendable` value to exactly one
/// background closure — used by `H264Decoder.invalidate` to carry an `Unmanaged`
/// session reference across to `DispatchQueue.global()`. `@unchecked` is the
/// discipline described at each use site, never a blanket claim about `Wrapped`.
struct UnsafeTransfer<Wrapped>: @unchecked Sendable {
    let value: Wrapped
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
