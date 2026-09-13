import CoreVideo
import Synchronization
import XCTest

@testable import KagamiCore

final class LatestFrameSlotTests: XCTestCase {
    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    func testUnreadWriteIsSupersededAndOnlyTheNewestSurvives() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()

        for index in 0..<5 {
            slot.write(.init(buffer: buffer, timestampMicros: UInt64(index)))
        }
        XCTAssertEqual(stats.snapshot().framesSuperseded, 4)

        let taken = slot.take()
        XCTAssertEqual(taken?.timestampMicros, 4)
        // Emptied by the read: a second take before any new write finds nothing.
        XCTAssertNil(slot.take())
    }

    func testDecodedEqualsDisplayedPlusSupersededUnderRandomTiming() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()

        var displayed = 0
        var rng = SystemRandomNumberGenerator()
        for index in 0..<10_000 {
            slot.write(.init(buffer: buffer, timestampMicros: UInt64(index)))
            // A consumer that only sometimes keeps up, same as a real renderer racing
            // the decoder: whenever it does read, that frame counts as displayed.
            if Bool.random(using: &rng), slot.take() != nil {
                displayed += 1
            }
        }
        // Whatever is left waiting at the end is neither displayed nor superseded yet.
        if slot.take() != nil { displayed += 1 }

        XCTAssertEqual(10_000, displayed + stats.snapshot().framesSuperseded)
    }

    func testWriteWakesTheRegisteredReader() {
        let slot = LatestFrameSlot()
        let buffer = makePixelBuffer()
        let woken = Mutex(0)
        slot.setDidWrite { woken.withLock { $0 += 1 } }

        slot.write(.init(buffer: buffer, timestampMicros: 1))
        slot.write(.init(buffer: buffer, timestampMicros: 2))

        XCTAssertEqual(woken.withLock { $0 }, 2)
    }
}
