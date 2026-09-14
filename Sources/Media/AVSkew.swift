import Foundation

/// Tracks how far apart the video and audio outputs are, in the console's own
/// microsecond clock, and offers a bounded nudge to how much audio `PCMRingBuffer`
/// buffers ahead of the speaker when that gap persists.
///
/// Both streams are already bounded to the live edge on their own (`VideoIngest` for
/// video, the ring buffer's own trimming for audio), so under the goal invariants skew
/// should stay small by construction. This exists to make a *persistent* offset
/// measurable and to correct only that — similar to SysDVR's own 90 ms sync rule —
/// without ever touching video, which the invariants forbid delaying for sync: a nudge
/// only ever retunes audio's `targetFill`.
struct AVSkew: Sendable {
    /// Bounds `targetFillSeconds` may be nudged within. Below this, the slightest
    /// jitter underruns; above it is `PCMRingBuffer`'s own `highWater`, past which a
    /// trim would just undo the nudge.
    static let targetFillBounds = 0.020...0.100
    /// "Only if |skew| > 80 ms" — a momentary spike (one stall) should not retune
    /// steady-state buffering.
    static let nudgeThreshold = Duration.milliseconds(80)
    /// "...for 2 s" — how long the threshold must stay exceeded before a nudge, and
    /// the spacing between consecutive nudges.
    static let sustainedFor = Duration.seconds(2)
    /// One nudge step, in seconds of target fill.
    static let nudgeStep = 0.005

    private var lastVideoTimestampMicros: UInt64?
    private var lastAudioPlayheadMicros: UInt64?
    private var outOfBoundsSince: ContinuousClock.Instant?

    private(set) var targetFillSeconds: Double

    init(initialTargetFillSeconds: Double = 0.040) {
        targetFillSeconds = initialTargetFillSeconds
    }

    /// Console timestamp, in microseconds, of the frame currently on screen. A
    /// timestamp older than the last one reported means the console (or the
    /// connection) restarted, and the whole estimate resets rather than reporting a
    /// nonsensical skew across the discontinuity.
    mutating func noteVideoDisplayed(timestampMicros: UInt64) {
        if let last = lastVideoTimestampMicros, timestampMicros < last {
            reset()
        }
        lastVideoTimestampMicros = timestampMicros
    }

    /// `newestWrittenTimestampMicros` is the console timestamp of the most recent audio
    /// payload handed to the ring buffer; `fill` and `outputLatency` are subtracted
    /// from it because that much of what was written has not reached the speaker yet.
    mutating func noteAudioPlayhead(
        newestWrittenTimestampMicros: UInt64, fill: Duration, outputLatency: Duration = .zero
    ) {
        if let last = lastAudioPlayheadMicros, newestWrittenTimestampMicros < last {
            reset()
        }
        let behindMicros = UInt64(max(0, Int64(microseconds(fill)) + Int64(microseconds(outputLatency))))
        let playhead =
            behindMicros < newestWrittenTimestampMicros
            ? newestWrittenTimestampMicros - behindMicros : 0
        lastAudioPlayheadMicros = playhead
    }

    /// Positive means video is ahead of audio (audio is lagging); negative the
    /// reverse. `nil` until both streams have reported at least once since the last
    /// reset.
    var skew: Duration? {
        guard let video = lastVideoTimestampMicros, let audio = lastAudioPlayheadMicros else {
            return nil
        }
        return .microseconds(Int64(video) - Int64(audio))
    }

    /// Call once per tick with the current skew already available from `noteVideo…`/
    /// `noteAudio…`. Returns the (possibly just-updated) target fill; never touches
    /// video. Tests drive `now` directly to simulate the 2 s sustain window without a
    /// real sleep.
    ///
    /// `videoActive` must be `false` on any tick where video did not actually display a
    /// new frame — a stalled decoder (mid keyframe wait, or the ~2-6 s self-heal window
    /// in `VideoIngest`) freezes `lastVideoTimestampMicros` while audio's playhead keeps
    /// advancing normally, since audio is a wholly independent connection unaffected by
    /// a video decoder failure. Without this, that gap grows without bound for as long
    /// as video stays stuck and reads as "audio is lagging" — which is backwards: audio
    /// is fine, video is the one that stopped, and nudging `targetFillSeconds` in
    /// response would only mistune a buffer that was never the problem. Ignoring the
    /// tick — not resetting the estimator outright — means a persistent skew that
    /// predates the stall is still there, correctly, the moment video resumes.
    @discardableResult
    mutating func tick(now: ContinuousClock.Instant = .now, videoActive: Bool = true) -> Double {
        guard videoActive, let skew, magnitude(skew) > Self.nudgeThreshold else {
            outOfBoundsSince = nil
            return targetFillSeconds
        }
        guard let since = outOfBoundsSince else {
            outOfBoundsSince = now
            return targetFillSeconds
        }
        guard since.duration(to: now) >= Self.sustainedFor else { return targetFillSeconds }

        // Video ahead (skew > 0) means audio is behind live: a SMALLER target fill
        // makes the ring buffer trim sooner and settle closer to the newest write,
        // closing the gap. Audio ahead (skew < 0) is the opposite: a LARGER target
        // fill holds audio back (through the underrun/rebuffer wait) so video can
        // catch up to it instead.
        let direction = skew > .zero ? -1.0 : 1.0
        targetFillSeconds = min(
            Self.targetFillBounds.upperBound,
            max(Self.targetFillBounds.lowerBound, targetFillSeconds + direction * Self.nudgeStep))
        // Restart the window: consecutive nudges are spaced by `sustainedFor` too,
        // rather than firing every tick once the threshold has been crossed once.
        outOfBoundsSince = now
        return targetFillSeconds
    }

    private mutating func reset() {
        lastVideoTimestampMicros = nil
        lastAudioPlayheadMicros = nil
        outOfBoundsSince = nil
    }
}

private func magnitude(_ duration: Duration) -> Duration {
    duration < .zero ? .zero - duration : duration
}
