import Foundation

/// Owns the one policy that used to live inline in `Session.runVideo`: what to do with
/// each access unit as it comes off the wire.
///
/// Every packet is decoded — the compressed side is never dropped, so the reference
/// chain stays intact — but only the ones within about one frame of the live edge are
/// allowed to actually produce a picture. Anything further behind is decoded with
/// output suppressed, which is far cheaper than a real frame (VideoToolbox does the
/// motion compensation either way, it just skips building the displayable buffer) and
/// keeps latency bounded by decode speed rather than by a threshold: at a measured
/// ~2 ms per 720p access unit against a 33 ms budget, a backlog burst drains in a
/// handful of milliseconds, not by waiting for anything.
actor VideoIngest {
    /// About one frame at 30 fps. Backlog at or under this rides the wire normally —
    /// there is no meaningful catch-up to do. Above it, the picture is already stale by
    /// the time it would reach the screen, so producing it at all is wasted work.
    private static let oneFrameBudget = Duration.milliseconds(40)
    /// However far behind is too far behind: at this point the connection itself is
    /// almost certainly the problem, not a burst decode can drain, and no amount of
    /// suppressing output brings the picture back to something worth waiting for.
    private static let hardBacklogCeiling = Duration.seconds(3)

    /// A self-heal net under whatever decode failure this pipeline does not already
    /// have a targeted fix for: `H264Decoder` recovers a single bad access unit or a
    /// VideoToolbox session malfunction on its own at the next keyframe (see
    /// `enterKeyframeWait`), but nothing guarantees every future failure mode looks
    /// like one of those. If packets keep arriving here but none of them has produced
    /// a frame in this long, the decoder is presumed wedged in some way it cannot see
    /// past on its own, and gets a full reset — cleared parameter sets and VT session —
    /// so the very next keyframe rebuilds from scratch rather than resubmitting into
    /// whatever bad state caused this.
    private static let selfHealResetAfter = Duration.seconds(2)
    /// If a reset alone does not bring frames back this much longer — roughly two more
    /// incoming keyframes at SysDVR's usual GOP, hence "or ~6 s" — the decoder itself is
    /// exonerated: only tearing down the TCP connection and renegotiating from scratch
    /// is left to try.
    private static let selfHealReconnectAfter = Duration.seconds(6)

    private let decoder: H264Decoder
    private let stats: PipelineStats
    private var timeline = StreamTimeline()
    /// The moment the most recent frame actually reached `frames`, or this actor's own
    /// creation time if none has yet — the clock the self-heal policy above measures
    /// against. Deliberately keyed off `dequeuedAt`, the same synthetic-clock-friendly
    /// timestamp `excessDelay` already uses, so a test can drive this without a real
    /// sleep exactly the way `testConsumerFallingBehindIsDetectedEvenWithNoNetworkLateness`
    /// already does for the backlog ceiling.
    private var lastFrameProducedAt = ContinuousClock.now
    /// Sticky within one stall so a reset costs exactly one, not one per packet still
    /// arriving before the next keyframe. Cleared the moment a frame is produced again.
    private var resetSinceLastFrame = false
    /// Owns the ambient-colour reduction described in `AmbientSampler`'s own header.
    /// Fed every successfully decoded picture; the sampler decides for itself, by the
    /// console's own clock, whether 250 ms have passed and whether the colour actually
    /// changed enough to be worth publishing.
    private let ambient = AmbientSampler()

    /// The decoder's own decoded-frame stream, forwarded so callers never need to know
    /// this actor wraps one.
    nonisolated let frames: AsyncStream<DecodedFrame>

    init(stats: PipelineStats) {
        self.stats = stats
        let decoder = H264Decoder(stats: stats)
        self.decoder = decoder
        frames = decoder.frames
    }

    /// `dequeuedAt` defaults to the real clock and only ever takes another value from a
    /// test: measuring backlog from the moment this call actually starts running is the
    /// whole fix. The stream's own reading task stamps each packet's wire-arrival time
    /// long before this actor gets around to it, and an unbounded `AsyncThrowingStream`
    /// never blocks that reading task waiting on a slow consumer — so if this actor
    /// falls behind (a slow decode, a busy scheduler), packets queue up invisibly, each
    /// one still carrying a wire-arrival timestamp that looks perfectly on time.
    /// Resampling `now` right here, instead, means the backlog this method computes is
    /// however far the console's live edge actually is from the moment its picture is
    /// about to be decoded — queueing delay included, not just network transit.
    func accept(_ packet: SysDVRStream.Packet, dequeuedAt: ContinuousClock.Instant = .now) async throws {
        let backlog = timeline.excessDelay(
            timestampMicros: packet.header.timestamp, receivedAt: dequeuedAt)
        stats.set(\.receiveBacklogMillis, to: milliseconds(backlog))
        guard backlog < Self.hardBacklogCeiling else { throw SysDVRStream.Failure.backlogExceeded }

        stats.increment(\.decodeCalls)
        do {
            let frame = try await decoder.decode(
                packet.payload, timestampMicros: packet.header.timestamp,
                suppressOutput: backlog > Self.oneFrameBudget)
            // `frame` is `nil` for every suppressed access unit (VideoToolbox never
            // produces a picture for those), so this already only ever sees "the
            // newest decoded buffer" the plan calls for — no separate freshness check
            // needed here.
            if let frame {
                lastFrameProducedAt = dequeuedAt
                resetSinceLastFrame = false
                if let colour = await ambient.sample(frame) {
                    stats.setAmbientColor(colour)
                }
            } else {
                try await selfHealIfWedged(now: dequeuedAt)
            }
        } catch {
            // A decode error is not a dead connection. `H264Decoder` has already
            // recovered in place — it enters its own keyframe wait before it ever
            // throws (see `H264Decoder.submit`/`rebuildSession`) — so the reference
            // chain is already back to a known-good state and decoding resumes on its
            // own at the next IDR. Rethrowing here would reach `Session.runVideo`'s
            // packet loop, which has no way to tell this apart from a dead socket and
            // would tear the live TCP connection down: that discards whatever access
            // units the console already queued in the OS socket buffer, which is
            // exactly the client-side packet drop this pipeline exists to avoid, and
            // pays a full handshake plus keyframe wait for a single bad access unit
            // the decoder was already recovering from without any help from us.
            stats.increment(\.decodeErrors)
            try await selfHealIfWedged(now: dequeuedAt)
        }
    }

    /// The self-heal policy described on this actor's own properties above: escalates
    /// from "reset the decoder" to "reconnect the stream" only as long as packets keep
    /// arriving here without a single one producing a frame. A packet that does
    /// produce a frame (handled in `accept`, above) clears `lastFrameProducedAt` and
    /// `resetSinceLastFrame` before this is ever consulted again, so a stall that
    /// resolves on its own — the ordinary keyframe wait `H264Decoder` already recovers
    /// from — never reaches here for long enough to do anything.
    private func selfHealIfWedged(now: ContinuousClock.Instant) async throws {
        let stalledFor = lastFrameProducedAt.duration(to: now)
        guard stalledFor >= Self.selfHealResetAfter else { return }
        guard resetSinceLastFrame else {
            stats.increment(\.decoderResets)
            await decoder.reset()
            resetSinceLastFrame = true
            return
        }
        guard stalledFor >= Self.selfHealReconnectAfter else { return }
        throw SysDVRStream.Failure.decoderWedged
    }

    func reset() async {
        await decoder.reset()
        await ambient.reset()
        timeline = StreamTimeline()
        lastFrameProducedAt = .now
        resetSinceLastFrame = false
    }

    func finish() async {
        await decoder.finish()
    }
}
