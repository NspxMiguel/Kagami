import Foundation
import XCTest

@testable import KagamiCore

final class PipelineStatsTests: XCTestCase {
    func testConcurrentIncrementsAreExact() async {
        let stats = PipelineStats()
        let tasks = 8
        let incrementsPerTask = 10_000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    for _ in 0..<incrementsPerTask {
                        stats.increment(\.packetsReceived)
                        stats.increment(\.bytesReceived, by: 2)
                    }
                }
            }
        }

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.packetsReceived, tasks * incrementsPerTask)
        XCTAssertEqual(snapshot.bytesReceived, tasks * incrementsPerTask * 2)
    }

    func testSetOverwritesRatherThanAccumulates() {
        let stats = PipelineStats()
        stats.increment(\.framesDisplayed, by: 5)
        stats.set(\.framesDisplayed, to: 42)
        XCTAssertEqual(stats.snapshot().framesDisplayed, 42)
        stats.set(\.receiveBacklogMillis, to: 17)
        XCTAssertEqual(stats.snapshot().receiveBacklogMillis, 17)
    }

    func testResetClearsEveryCounter() {
        let stats = PipelineStats()
        stats.increment(\.packetsReceived)
        stats.increment(\.decodeErrors)
        stats.reset()
        XCTAssertEqual(stats.snapshot(), PipelineStats.Snapshot())
    }

    func testDiagnosticsLineIsCompactJSONWithEveryCounter() {
        var snapshot = PipelineStats.Snapshot()
        snapshot.packetsReceived = 900
        snapshot.bytesReceived = 123_456
        snapshot.compressedDropped = 1
        snapshot.decodeCalls = 899
        snapshot.decodeErrors = 2
        snapshot.keyframeWaitsEntered = 3
        snapshot.keyframeWaitMillisTotal = 240
        snapshot.framesDecoded = 895
        snapshot.framesSuperseded = 5
        snapshot.rendererNotReady = 4
        snapshot.framesDisplayed = 890
        snapshot.reconnects = 0
        snapshot.audioSamplesTrimmed = 6
        snapshot.audioUnderruns = 1
        snapshot.receiveBacklogMillis = 37
        snapshot.avSkewMicros = -12_000
        snapshot.audioFillMillis = 42

        let line = snapshot.diagnosticsLine(framesDisplayedPerSecond: 30)

        // Compact: one line, no pretty-printing whitespace.
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("  "))
        // Every field of the snapshot round-trips, plus the derived per-second rate
        // that the raw cumulative counter cannot show by itself.
        let expected = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Int]
        XCTAssertEqual(
            expected,
            [
                "packetsReceived": 900,
                "bytesReceived": 123_456,
                "compressedDropped": 1,
                "decodeCalls": 899,
                "decodeErrors": 2,
                "keyframeWaitsEntered": 3,
                "keyframeWaitMillisTotal": 240,
                "framesDecoded": 895,
                "framesSuperseded": 5,
                "rendererNotReady": 4,
                "framesDisplayed": 890,
                "framesDisplayedPerSecond": 30,
                "reconnects": 0,
                "audioSamplesTrimmed": 6,
                "audioUnderruns": 1,
                "receiveBacklogMillis": 37,
                "avSkewMicros": -12_000,
                "audioFillMillis": 42,
            ])
    }

    func testMillisecondsRoundsDownToTheMillisecond() {
        XCTAssertEqual(milliseconds(.zero), 0)
        XCTAssertEqual(milliseconds(.milliseconds(800)), 800)
        XCTAssertEqual(milliseconds(.seconds(3)), 3000)
        // 2.5 ms truncates rather than rounds — a fractional millisecond left over
        // from a Duration computed elsewhere should not be silently rounded up.
        XCTAssertEqual(milliseconds(.milliseconds(2) + .microseconds(500)), 2)
    }
}
