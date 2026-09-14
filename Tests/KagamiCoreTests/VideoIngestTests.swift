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

    /// Regression test for the live-edge freeze from two independent simulator soaks
    /// (`Tools/fake-console.py --gop 150 --motion noise --stall-ms 800 --stall-every
    /// 5`), which froze at exactly `framesDecoded == 16368` after roughly 600 s of
    /// playback. Asserts the CORRECT behaviour — the pipeline recovers and keeps
    /// decoding — which `enterKeyframeWait()` invalidating `session` (VideoDecoder.swift)
    /// now guarantees. Runs in well under a minute — no simulator, no `--stall-ms`, no
    /// real-time pacing.
    ///
    /// This is not a bitstream defect, and the checked-in fixture proves it: looping
    /// the existing 300-frame `busy-gop150.h264` (a completely different, much
    /// lower-entropy stream than the soak's noisy one) hits the *exact same* failure at
    /// the *exact same* access-unit count, 16381 — a number suspiciously close to
    /// 2^14 = 16384. The boundary moved by only 13 access units between two unrelated
    /// bitstreams, does not scale with content, and does not reproduce at all when a
    /// fresh decoder is fed only the ~250 access units surrounding that same boundary
    /// (verified separately, off this test, with zero errors). All of that points at an
    /// internal VideoToolbox limit on how many access units one `VTDecompressionSession`
    /// can decode before `VTDecompressionSessionDecodeFrame` starts synchronously
    /// rejecting every submission with `kVTVideoDecoderMalfunctionErr` (-12909; verified
    /// separately, off this test, that the rejection is synchronous, not the 200 ms
    /// timeout path) — not at anything wrong with a particular frame's bytes.
    ///
    /// VideoToolbox malfunctioning is not itself the bug under test — a real console
    /// session could trip the same wall from something else entirely (thermal
    /// throttling, a hiccupping hardware decoder, memory pressure), and a long enough
    /// real play session hits this exact ceiling too: 16,381 frames at 30 fps is about
    /// nine minutes. The bug is that `H264Decoder` has no recovery from it:
    /// `enterKeyframeWait()` (VideoDecoder.swift) never invalidates `session`, so
    /// `decode()`'s rebuild guard — `parametersChanged || (session == nil &&
    /// parsed.isKeyframe)` — never re-fires once the parameter sets stop changing (true
    /// for this whole stream after the very first IDR), and every later keyframe keeps
    /// resubmitting to the same wedged session, which rejects it identically, forever.
    func testRecoversAfterVideoToolboxSessionMalfunctionInsteadOfFreezingForever() async throws {
        let units = try Self.loadBusyGOPAccessUnits()
        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { for await _ in ingest.frames {} }
        defer { receiver.cancel() }

        // Comfortably past three IDRs (every 150 frames) beyond the ~16,381st access
        // unit where VideoToolbox first malfunctions on this machine, so a real
        // recovery — not just surviving the first failure — has room to show up.
        let totalToFeed = 17_000
        let origin = ContinuousClock.now
        for index in 0..<totalToFeed {
            let unit = units[index % units.count]
            let at = origin.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            try await ingest.accept(Self.packet(unit, sequence: index), dequeuedAt: at)
        }
        await ingest.finish()

        let final = stats.snapshot()
        // An IDR after a VideoToolbox malfunction rebuilds the session and decoding
        // resumes, so framesDecoded should keep pace with what was fed, not freeze at
        // whatever it reached right before the first failure.
        XCTAssertGreaterThan(
            final.framesDecoded, totalToFeed - 300,
            "framesDecoded should keep advancing after the session recovers, not freeze once "
                + "VideoToolbox malfunctions (the live-edge freeze this test reproduces)")
        // One malfunction costs one keyframe wait, not one per IDR forever.
        XCTAssertLessThanOrEqual(
            final.decodeErrors, 1,
            "expected the decoder to recover after the next keyframe, not fail identically on "
                + "every later IDR forever (the livelock)")
    }

    /// Regression test for `VideoIngest`'s self-heal policy: an unknown failure mode
    /// — not the VideoToolbox session malfunction above, and not a single corrupted
    /// picture either — that leaves the decoder waiting for a keyframe it will never
    /// get from this input must still recover once real access units come back,
    /// bounded by how long packets can keep arriving here without a single one
    /// producing a frame before `VideoIngest` steps in and resets the decoder itself.
    func testSelfHealResetsTheDecoderAfterAProlongedStallThenRecoversOnRealIDRs() async throws {
        let units = try Self.loadBusyGOPAccessUnits()
        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { for await _ in ingest.frames {} }
        defer { receiver.cancel() }

        // No Annex-B start code anywhere in this — `AnnexB.parse` finds neither a
        // parameter set nor a keyframe, so `H264Decoder` never even reaches
        // VideoToolbox with it; it just sits waiting for a keyframe that will never
        // arrive from this input. Exactly the "something this pipeline has no
        // targeted fix for" case the self-heal net exists for.
        let garbage = Data(repeating: 0x42, count: 4096)

        let origin = ContinuousClock.now
        // 75 packets, 33.3 ms apart in the same synthetic clock `dequeuedAt` already
        // uses elsewhere in this file: 2.5 s of packets steadily arriving, comfortably
        // past the 2 s reset threshold and well under the 6 s reconnect one.
        for index in 0..<75 {
            let at = origin.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            try await ingest.accept(Self.packet(garbage, sequence: index), dequeuedAt: at)
        }

        let stalled = stats.snapshot()
        XCTAssertEqual(stalled.framesDecoded, 0, "garbage input should never decode")
        XCTAssertGreaterThanOrEqual(
            stalled.decoderResets, 1,
            "a 2+ s stall with packets still arriving should have triggered a self-heal reset")
        XCTAssertEqual(
            stalled.reconnects, 0,
            "2.5 s of stall is under the 6 s reconnect bound — a reset should have been enough")

        // Real access units resume right where the garbage left off, on the same
        // clock, starting with the fixture's own first frame (an IDR).
        let resumeAt = origin.advanced(by: .microseconds(75 * Int64(Self.frameInterval)))
        for index in 0..<units.count {
            let at = resumeAt.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            try await ingest.accept(Self.packet(units[index], sequence: 75 + index), dequeuedAt: at)
        }
        await ingest.finish()

        XCTAssertGreaterThan(
            stats.snapshot().framesDecoded, 0,
            "the decoder should recover and resume decoding once real access units return")
    }

    /// A second self-heal regression, distinct from the garbage-input one above: here
    /// every packet IS a well-formed keyframe as far as Annex-B parsing and the SPS/PPS
    /// are concerned — `H264Decoder` rebuilds a session and reaches VideoToolbox every
    /// single time — but the picture payload itself is corrupted, so
    /// `VTDecompressionSessionDecodeFrame` rejects it identically on every attempt. This
    /// is what an unrecoverable-by-itself run of "undecodable IDRs" looks like: unlike
    /// the P-frame corruption in `testCorruptedPictureWaitsForExactlyOneKeyframeThenResumes`
    /// (one bad frame, healthy ones on either side), nothing here ever lets
    /// `H264Decoder`'s own per-access-unit recovery succeed, because the very next
    /// keyframe is exactly as corrupted as the last one. Only `VideoIngest`'s self-heal
    /// noticing that packets keep arriving with no frame ever produced — first a reset,
    /// then, if that alone does not help, a reconnect — bounds this.
    func testSelfHealRecoversAfterRepeatedlyUndecodableKeyframesOnceValidOnesReturn() async throws {
        let units = try Self.loadBusyGOPAccessUnits()

        // `units[0]` is the fixture's first IDR: valid SPS/PPS followed by the slice
        // itself. Corrupting the last third of it leaves the parameter sets untouched
        // (so `H264Decoder` rebuilds a session successfully every time) while mangling
        // enough of the slice that VideoToolbox has no reasonable concealment to fall
        // back on and rejects the submission outright, every single time.
        var corruptedBytes = [UInt8](units[0])
        let corruptStart = corruptedBytes.count - max(1, corruptedBytes.count / 3)
        for index in corruptStart..<corruptedBytes.count { corruptedBytes[index] ^= 0xFF }
        let undecodableKeyframe = Data(corruptedBytes)

        let stats = PipelineStats()
        let ingest = VideoIngest(stats: stats)
        let receiver = Task { for await _ in ingest.frames {} }
        defer { receiver.cancel() }

        let origin = ContinuousClock.now
        // 200 packets, 33.3 ms apart on the console clock and the synthetic
        // `dequeuedAt` clock together — matching `Self.packet`'s own timestamp cadence
        // is deliberate here, not incidental: `dequeuedAt` racing ahead of the
        // packet's own header timestamp is exactly `StreamTimeline.excessDelay`'s
        // definition of falling behind, and would throw `.backlogExceeded` long before
        // this ever reached the self-heal path under test. 6.67 s of matched elapsed
        // time comfortably clears both the 2 s reset threshold and the 6 s reconnect
        // one, so this exercises the full escalation, not just the reset.
        var wedged = false
        for index in 0..<200 {
            let at = origin.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            do {
                try await ingest.accept(Self.packet(undecodableKeyframe, sequence: index), dequeuedAt: at)
            } catch SysDVRStream.Failure.decoderWedged {
                wedged = true
                break
            }
        }

        XCTAssertTrue(
            wedged,
            "repeated undecodable keyframes over 6.67 s of arrival should have exhausted the reset-"
                + "then-reconnect self-heal policy, the same way `Session.runVideo` relies on to know "
                + "when to give up on this connection and try a fresh one")
        let afterWedge = stats.snapshot()
        XCTAssertEqual(afterWedge.framesDecoded, 0, "a corrupted keyframe should never decode")
        XCTAssertGreaterThanOrEqual(
            afterWedge.decoderResets, 1,
            "the self-heal policy should have reset the decoder before giving up on the connection")

        // Mirrors `Session.runVideo`: a `.decoderWedged` throw is a signal to reconnect,
        // which in production means a brand-new `VideoIngest`/`H264Decoder` for the next
        // attempt — sharing the same `stats` the way `Session` shares one `PipelineStats`
        // across every reconnect of a single session.
        let freshIngest = VideoIngest(stats: stats)
        let freshReceiver = Task { for await _ in freshIngest.frames {} }
        defer { freshReceiver.cancel() }
        let resumeAt = origin.advanced(by: .microseconds(200 * Int64(Self.frameInterval)))
        for index in 0..<units.count {
            let at = resumeAt.advanced(by: .microseconds(Int64(index) * Int64(Self.frameInterval)))
            try await freshIngest.accept(Self.packet(units[index], sequence: 1000 + index), dequeuedAt: at)
        }
        await freshIngest.finish()

        XCTAssertGreaterThan(
            stats.snapshot().framesDecoded, 0,
            "a fresh connection fed real access units should recover and start decoding again")
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
