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

    private let decoder: H264Decoder
    private let stats: PipelineStats
    private var timeline = StreamTimeline()
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

    func accept(_ packet: SysDVRStream.Packet) async throws {
        let backlog = timeline.excessDelay(
            timestampMicros: packet.header.timestamp, receivedAt: packet.receivedAt)
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
            if let frame, let colour = await ambient.sample(frame) {
                stats.setAmbientColor(colour)
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
        }
    }

    func reset() async {
        await decoder.reset()
        await ambient.reset()
        timeline = StreamTimeline()
    }

    func finish() async {
        await decoder.finish()
    }
}
