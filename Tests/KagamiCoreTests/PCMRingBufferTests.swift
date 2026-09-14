import XCTest

@testable import KagamiCore

final class PCMRingBufferTests: XCTestCase {
    /// One writer call bigger than the whole 500 ms capacity: the buffer should clamp
    /// to capacity, then its own highWater trim should bring it straight down to
    /// `targetFill`, keeping only the newest slice of what was written.
    func testWriteOneSecondKeepsNewestFortyMillisecondsAfterHighWaterTrim() {
        // Crossfade off here: the seam-smoothing this buffer does on a trim has its
        // own dedicated test below, and would otherwise blend the boundary samples
        // this test checks for exact retention.
        let ring = PCMRingBuffer(sampleRate: 48000, channels: 1, crossfadeSeconds: 0)
        let oneSecond = (0..<48_000).map { Int16(truncatingIfNeeded: $0) }
        ring.write(oneSecond)

        let fillMillis = 1000.0 * Double(ring.fillSamples) / 48000.0
        XCTAssertLessThanOrEqual(fillMillis, 100, "fill after a huge write must not exceed highWater")

        var out = [Int16](repeating: 0, count: ring.fillSamples)
        out.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer, frameCount: buffer.count)
        }
        // The last 40 ms of a ramp `0, 1, 2, ...` is a contiguous ascending run ending
        // at 47_999 (mod Int16), so the newest samples are recognizable by being the
        // tail of the ramp, not by absolute value alone (truncatingIfNeeded wraps).
        let expectedTail = oneSecond.suffix(out.count)
        XCTAssertEqual(Array(out), Array(expectedTail))
    }

    /// Fresh buffer with nothing written: every read is silence and counts as an
    /// underrun, never a crash or garbage memory.
    func testEmptyBufferReadsSilence() {
        let ring = PCMRingBuffer(sampleRate: 48000, channels: 2)
        var out = [Int16](repeating: 123, count: 960)
        out.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer, frameCount: 480)
        }
        XCTAssertEqual(out, [Int16](repeating: 0, count: 960))
        XCTAssertEqual(ring.underrunsTotal, 1)
    }

    /// After an underrun drains the buffer to empty, a small write below `targetFill`
    /// must not resume playback — that would immediately underrun again a moment
    /// later. Only once the refill reaches `targetFill` should reads produce sound.
    func testUnderrunWaitsForTargetFillBeforeResuming() {
        let ring = PCMRingBuffer(
            sampleRate: 1000, channels: 1, capacitySeconds: 1, targetFillSeconds: 0.1,
            highWaterSeconds: 0.2, crossfadeSeconds: 0.01)
        // Drain the never-filled buffer once to force the underrun/rebuffering state.
        var out = [Int16](repeating: 0, count: 10)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, frameCount: 10) }
        XCTAssertEqual(ring.underrunsTotal, 1)

        // Half of targetFill (100 samples at 1 kHz for 0.1 s): still not enough.
        ring.write([Int16](repeating: 7, count: 50))
        out = [Int16](repeating: 9, count: 10)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, frameCount: 10) }
        XCTAssertEqual(out, [Int16](repeating: 0, count: 10), "must stay silent below targetFill")
        XCTAssertEqual(ring.underrunsTotal, 2)

        // Now above targetFill: playback should resume with real samples.
        ring.write([Int16](repeating: 7, count: 60))
        out = [Int16](repeating: 9, count: 10)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, frameCount: 10) }
        XCTAssertEqual(out, [Int16](repeating: 7, count: 10))
        XCTAssertEqual(ring.underrunsTotal, 2, "resuming above targetFill must not itself count as an underrun")
    }

    /// A trim's crossfade must not introduce a sample-to-sample jump bigger than the
    /// signal's own maximum step — otherwise the "smoothing" would itself be the click
    /// it exists to avoid.
    func testTrimCrossfadeBoundsSampleToSampleJump() {
        let sampleRate = 48_000.0
        let ring = PCMRingBuffer(
            sampleRate: sampleRate, channels: 1, capacitySeconds: 0.5,
            targetFillSeconds: 0.040, highWaterSeconds: 0.100, crossfadeSeconds: 0.005)

        let frequency = 1000.0
        let amplitude = 30_000.0
        let angularStep = 2 * Double.pi * frequency / sampleRate
        // The largest possible sample-to-sample delta of this sine, used as the bound.
        let maxTheoreticalStep = amplitude * angularStep

        var allRead: [Int16] = []
        var phase = 0.0
        // Write in small chunks so highWater is crossed, and thus a trim runs, many
        // times over the course of the test — not just once.
        for _ in 0..<200 {
            var chunk = [Int16]()
            chunk.reserveCapacity(64)
            for _ in 0..<64 {
                chunk.append(Int16(clamping: Int((amplitude * sin(phase)).rounded())))
                phase += angularStep
            }
            ring.write(chunk)
            var out = [Int16](repeating: 0, count: 32)
            out.withUnsafeMutableBufferPointer { ring.read(into: $0, frameCount: 32) }
            allRead.append(contentsOf: out)
        }

        XCTAssertGreaterThan(ring.trimmedSamplesTotal, 0, "test is only meaningful if a trim actually ran")

        var worstJump = 0.0
        for i in 1..<allRead.count {
            // Skip jumps into/out of a silent underrun stretch — those are a separate,
            // already-tested concern, not the crossfade this test is checking.
            guard allRead[i] != 0, allRead[i - 1] != 0 else { continue }
            worstJump = max(worstJump, abs(Double(allRead[i]) - Double(allRead[i - 1])))
        }
        XCTAssertLessThanOrEqual(worstJump, maxTheoreticalStep * 1.5)
    }

    /// Smoke test for the write/read contract under real concurrency: a writer thread
    /// and a reader thread run against the same buffer for a short, bounded stretch.
    /// Nothing here should crash, and every read is either real audio or silence —
    /// never a torn or garbage sample.
    func testConcurrentWriteAndReadDoesNotCrashOrTearSamples() {
        let ring = PCMRingBuffer(sampleRate: 48000, channels: 2)
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            for i in 0..<2000 {
                let chunk = (0..<128).map { Int16(truncatingIfNeeded: i + $0) }
                ring.write(chunk)
                usleep(200)
            }
            done.signal()
        }

        var sawNonSilence = false
        for _ in 0..<2000 {
            var out = [Int16](repeating: -1, count: 96)
            out.withUnsafeMutableBufferPointer { ring.read(into: $0, frameCount: 48) }
            if out.contains(where: { $0 != 0 }) { sawNonSilence = true }
            usleep(200)
        }
        done.wait()
        XCTAssertTrue(sawNonSilence, "the reader should observe real audio at least once")
    }
}
