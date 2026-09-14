import Foundation
import XCTest

@testable import KagamiCore

final class VideoIngestTests: XCTestCase, @unchecked Sendable {
    /// 30 fps, matching the fixture and the console's own encoder.
    private static let frameInterval: UInt64 = 33_333

    func testStallThenBurstNeverWaitsForKeyframeAndReachesLiveEdge() async throws {
        let units = try Self.loadBusyGOPAccessUnits()
        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { () -> [DecodedFrame] in
            var frames: [DecodedFrame] = []
            for await frame in ingest.frames { frames.append(frame) }
            return frames
        }

        let origin = ContinuousClock.now
        // 60 AUs, arriving right on schedule. `dequeuedAt` stands in for "the wire
        // delivered this and the actor got to it right away" without an actual sleep.
        for index in 0..<60 {
            let at = origin.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            try await ingest.accept(Self.packet(units[index], sequence: index), dequeuedAt: at)
        }

        // An 800 ms stall, then the whole backlog lands in one burst — 24 AUs at 30 fps
        // is exactly 800 ms of encoder output, the same shape Tools/fake-console.py's
        // --stall-ms/--stall-every produces against a real TCP read.
        let burstArrival = origin.advanced(
            by: .microseconds(Int64(60 * Self.frameInterval)) + .milliseconds(800))
        let burstStart = ContinuousClock.now
        for index in 60..<84 {
            try await ingest.accept(Self.packet(units[index], sequence: index), dequeuedAt: burstArrival)
        }
        let burstDuration = burstStart.duration(to: .now)

        await ingest.finish()
        let frames = await receiver.value

        XCTAssertEqual(stats.snapshot().keyframeWaitsEntered, 0)
        XCTAssertLessThan(burstDuration, .milliseconds(100), "burst took \(burstDuration)")
        XCTAssertEqual(frames.last?.timestampMicros, UInt64(83) * Self.frameInterval)
    }

    func testThreeHundredAccessUnitsAtLiveEdgeDecodeAndDisplayNearlyAll() async throws {
        let units = try Self.loadBusyGOPAccessUnits()
        XCTAssertEqual(units.count, 300)
        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { () -> Int in
            var count = 0
            for await _ in ingest.frames { count += 1 }
            return count
        }

        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<units.count {
            try await clock.sleep(
                until: start.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval))))
            // Fed right as each one's real arrival time comes due, so the default
            // `dequeuedAt: .now` in `accept` already matches the live edge — nothing
            // synthetic needed here.
            try await ingest.accept(Self.packet(units[index], sequence: index))
        }

        await ingest.finish()
        let displayed = await receiver.value

        XCTAssertEqual(stats.snapshot().decodeCalls, 300)
        XCTAssertGreaterThanOrEqual(displayed, 295)
        XCTAssertEqual(stats.snapshot().keyframeWaitsEntered, 0)
    }

    func testCorruptedPictureWaitsForExactlyOneKeyframeThenResumes() async throws {
        var units = try Self.loadBusyGOPAccessUnits()
        // Flip a byte deep enough into a P-frame (well after frame 0's IDR, well before
        // frame 150's IDR) that VideoToolbox rejects it outright rather than silently
        // tolerating a bit flip.
        let corruptedIndex = 75
        var corrupted = [UInt8](units[corruptedIndex])
        let flipAt = min(corrupted.count - 1, 200)
        corrupted[flipAt] ^= 0xFF
        units[corruptedIndex] = Data(corrupted)

        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { () -> [DecodedFrame] in
            var frames: [DecodedFrame] = []
            for await frame in ingest.frames { frames.append(frame) }
            return frames
        }

        // Feed a little past frame 150 (the fixture's second IDR) so the resumption
        // itself, not just the wait, is observable.
        for index in 0..<155 {
            // `accept` does not throw for a decode error — `H264Decoder` has already
            // recovered in place (it enters its own keyframe wait before it throws), so
            // there is nothing left for the caller to react to. A plain `try` here is
            // itself the regression test: if `accept` ever started rethrowing decode
            // errors again, `Session.runVideo`'s packet loop would tear the live
            // connection down over a single bad access unit, and this call would need
            // `try?` to keep the loop feeding the rest of the GOP.
            try await ingest.accept(Self.packet(units[index], sequence: index))
        }

        await ingest.finish()
        let frames = await receiver.value

        XCTAssertEqual(stats.snapshot().keyframeWaitsEntered, 1)
        XCTAssertEqual(stats.snapshot().decodeErrors, 1)
        // Output resumes at frame 150 (the fixture's second IDR) — nothing between the
        // corrupted frame and the next keyframe should have produced a picture.
        XCTAssertFalse(frames.contains { $0.timestampMicros >= UInt64(corruptedIndex) * Self.frameInterval
            && $0.timestampMicros < UInt64(150) * Self.frameInterval })
        XCTAssertTrue(frames.contains { $0.timestampMicros == UInt64(150) * Self.frameInterval })
    }

    /// Regression test for the bug where `receiveBacklogMillis`/the hard ceiling were
    /// computed from a timestamp the stream's own reading task stamped at wire-arrival
    /// time -- before the packet was ever queued for this actor -- rather than from the
    /// moment `accept()` actually got around to it. A producer whose own delivery is
    /// perfectly on time proves nothing about whether the CONSUMER is keeping up: here
    /// the "wire" side is not modelled as late at all, only this actor's own processing
    /// is, via a real sleep between two `accept()` calls. The fix must be measured from
    /// `accept()`'s own call time, or this is invisible to it exactly like it used to be.
    func testConsumerFallingBehindIsDetectedEvenWithNoNetworkLateness() async throws {
        let units = try Self.loadBusyGOPAccessUnits()
        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { for await _ in ingest.frames {} }
        defer { receiver.cancel() }

        // Establishes the timeline's origin; `excessDelay` always returns zero on its
        // first sample, so nothing is asserted about this call.
        try await ingest.accept(Self.packet(units[0], sequence: 0))

        // The producer would have handed this actor the next access unit one frame
        // interval later -- 33 ms of console time -- if this actor had been ready for
        // it. It was not: this real sleep stands in for the actor itself falling behind
        // (a slow decode, a busy scheduler), which is the one scenario the old
        // wire-arrival-timestamp measurement could never see.
        try await Task.sleep(for: .milliseconds(3_500))

        do {
            try await ingest.accept(Self.packet(units[1], sequence: 1))
            XCTFail("Expected .backlogExceeded once processing fell far enough behind")
        } catch SysDVRStream.Failure.backlogExceeded {
            // Expected: 3.5 s of real processing delay against one 33 ms frame
            // interval of console time is well past the 3 s hard ceiling.
        } catch {
            XCTFail("Expected .backlogExceeded, got \(error)")
        }
    }

    // MARK: - Fixture loading

    private static func loadBusyGOPAccessUnits() throws -> [Data] {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "busy-gop150", withExtension: "h264", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: file)
        return splitAccessUnits(bytes)
    }

    private static func packet(_ payload: Data, sequence: Int) -> SysDVRStream.Packet {
        let timestamp = UInt64(sequence) * frameInterval
        return SysDVRStream.Packet(
            header: SysDVR.PacketHeader(dataSize: payload.count, timestamp: timestamp, flags: [.video]),
            payload: payload,
            sequence: sequence)
    }

    /// Splits a raw Annex-B stream into one buffer per access unit, mirroring
    /// Tools/fake-console.py's `split_access_units`: a new unit starts at the first
    /// parameter set or slice that follows a slice, the same rule the console's own
    /// encoder uses to hand SysDVR one frame at a time.
    private static func splitAccessUnits(_ stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, i + 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        var units: [Data] = []
        var currentStart: Int?
        var seenSlice = false
        for (n, mark) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].code : bytes.count
            let nalType = bytes[mark.payload] & 0x1F
            let isSlice = nalType == 1 || nalType == 5

            if currentStart == nil {
                currentStart = mark.code
            } else if seenSlice, isSlice || nalType == 7 || nalType == 8 {
                units.append(Data(bytes[currentStart!..<mark.code]))
                currentStart = mark.code
                seenSlice = false
            }
            seenSlice = seenSlice || isSlice
            if n + 1 == starts.count, let start = currentStart {
                units.append(Data(bytes[start..<end]))
            }
        }
        return units
    }
}
