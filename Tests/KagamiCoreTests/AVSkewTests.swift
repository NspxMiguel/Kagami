import XCTest

@testable import KagamiCore

final class AVSkewTests: XCTestCase {
    /// Video's displayed timestamp runs ahead of audio's playhead by a constant
    /// 150 ms: skew should read that gap directly, regardless of which absolute
    /// console timestamps produced it.
    func testConstantAudioLagReportsMatchingSkew() {
        var skew = AVSkew()
        let baseMicros: UInt64 = 10_000_000
        let lag = Duration.milliseconds(150)

        skew.noteVideoDisplayed(timestampMicros: baseMicros)
        // No fill/latency behind the newest write here — the 150 ms lag is baked
        // directly into the newest-written timestamp itself, which is simpler to set
        // up than an equivalent fill duration and exercises the same subtraction.
        skew.noteAudioPlayhead(
            newestWrittenTimestampMicros: baseMicros - UInt64(microseconds(lag)), fill: .zero)

        guard let measured = skew.skew else { return XCTFail("skew should be available after both notes") }
        let deltaMicros = abs(microseconds(measured) - microseconds(lag))
        XCTAssertLessThanOrEqual(deltaMicros, 5_000, "expected 150 ms ± 5 ms, got \(microseconds(measured)) µs")
        XCTAssertGreaterThan(microseconds(measured), 0, "positive skew means video is ahead of audio")
    }

    /// `nil` until both sides have reported at least once — there is nothing honest to
    /// say about skew otherwise.
    func testSkewIsNilUntilBothSidesReport() {
        var skew = AVSkew()
        XCTAssertNil(skew.skew)
        skew.noteVideoDisplayed(timestampMicros: 1_000_000)
        XCTAssertNil(skew.skew)
    }

    /// Sustained past-threshold skew, ticked over a simulated 2 s window, produces a
    /// nudge in the direction that closes the gap; a momentary spike (well under 2 s)
    /// must not.
    func testSustainedSkewNudgesTowardZeroWithinBounds() {
        var skew = AVSkew(initialTargetFillSeconds: 0.040)
        var now = ContinuousClock.now
        let baseMicros: UInt64 = 100_000_000
        // Video 150 ms ahead of audio: audio is lagging, so the nudge should shrink
        // targetFill (see AVSkew.tick's own reasoning).
        func feed() {
            skew.noteVideoDisplayed(timestampMicros: baseMicros)
            skew.noteAudioPlayhead(
                newestWrittenTimestampMicros: baseMicros - 150_000, fill: .zero)
        }

        feed()
        XCTAssertEqual(skew.tick(now: now), 0.040, "a momentary excursion must not nudge yet")

        now += .seconds(1)
        feed()
        XCTAssertEqual(skew.tick(now: now), 0.040, "still under the 2 s sustain window")

        now += .seconds(1)  // total elapsed since first excursion: 2 s
        feed()
        let nudged = skew.tick(now: now)
        XCTAssertLessThan(nudged, 0.040, "audio lagging video should shrink targetFill")
        XCTAssertGreaterThanOrEqual(nudged, AVSkew.targetFillBounds.lowerBound)
    }

    /// Repeated nudges must never walk `targetFillSeconds` past the documented bounds,
    /// however long the skew persists.
    func testNudgeNeverLeavesTheDocumentedBounds() {
        var skew = AVSkew(initialTargetFillSeconds: 0.040)
        var now = ContinuousClock.now
        let baseMicros: UInt64 = 500_000_000

        for _ in 0..<200 {
            skew.noteVideoDisplayed(timestampMicros: baseMicros)
            skew.noteAudioPlayhead(newestWrittenTimestampMicros: baseMicros - 500_000, fill: .zero)
            now += .seconds(2)
            let result = skew.tick(now: now)
            XCTAssertTrue(AVSkew.targetFillBounds.contains(result))
        }
        XCTAssertEqual(skew.targetFillSeconds, AVSkew.targetFillBounds.lowerBound)
    }

    /// A stalled video decoder (a keyframe wait, or a self-heal window) leaves
    /// `noteVideoDisplayed` uncalled while audio keeps advancing on its own,
    /// independent connection — `videoActive: false` on those ticks must not let that
    /// growing, one-sided gap read as sustained skew and nudge `targetFillSeconds`,
    /// even though the *last-known* skew value would otherwise clear the threshold.
    func testInactiveVideoTicksNeverNudgeEvenWhenLastKnownSkewIsPastThreshold() {
        var skew = AVSkew(initialTargetFillSeconds: 0.040)
        var now = ContinuousClock.now
        let baseMicros: UInt64 = 200_000_000

        // One real sample pair, comfortably past the 80 ms threshold.
        skew.noteVideoDisplayed(timestampMicros: baseMicros)
        skew.noteAudioPlayhead(newestWrittenTimestampMicros: baseMicros - 150_000, fill: .zero)
        XCTAssertNotNil(skew.skew)

        // Video stalls: nothing calls `noteVideoDisplayed` again, exactly like
        // `Session.updateAudioVideoSkew` skipping it while `displayedThisTick == 0`.
        // Ticking for well over the 2 s sustain window must still not nudge.
        for _ in 0..<5 {
            now += .seconds(1)
            let result = skew.tick(now: now, videoActive: false)
            XCTAssertEqual(result, 0.040, "an inactive video tick must never nudge")
        }

        // Video resumes with the same persistent gap: NOW a fresh sustain window
        // should start and eventually nudge, proving this is "ignore", not "reset".
        for _ in 0..<3 {
            now += .seconds(1)
            skew.noteVideoDisplayed(timestampMicros: baseMicros)
            skew.noteAudioPlayhead(newestWrittenTimestampMicros: baseMicros - 150_000, fill: .zero)
            _ = skew.tick(now: now, videoActive: true)
        }
        XCTAssertLessThan(
            skew.targetFillSeconds, 0.040,
            "the persistent gap should still be there and nudge once video is active again")
    }

    /// A timestamp older than the last one reported — a console restart, or a fresh
    /// connection after a reconnect — must reset the estimator rather than reporting a
    /// nonsensical skew across the discontinuity.
    func testTimestampGoingBackwardsResetsTheEstimator() {
        var skew = AVSkew()
        skew.noteVideoDisplayed(timestampMicros: 10_000_000)
        skew.noteAudioPlayhead(newestWrittenTimestampMicros: 9_850_000, fill: .zero)
        XCTAssertNotNil(skew.skew)

        // Console restarted: its monotonic clock is back near zero.
        skew.noteVideoDisplayed(timestampMicros: 1_000)
        XCTAssertNil(skew.skew, "video-side reset should clear the audio side too")

        skew.noteAudioPlayhead(newestWrittenTimestampMicros: 900, fill: .zero)
        XCTAssertNotNil(skew.skew, "a fresh pair of notes after the reset should measure again")
    }
}
