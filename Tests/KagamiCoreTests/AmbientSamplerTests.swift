import CoreVideo
import XCTest

@testable import KagamiCore

final class AmbientSamplerTests: XCTestCase {
    /// 30 fps, matching the console's own encoder and every other fixture in this
    /// target. The sampler gates purely on this clock, never on wall time, so a whole
    /// 10 s stream can be fed to it instantly.
    private static let frameInterval: UInt64 = 33_333

    /// A hard cut every 24 frames (0.8 s) — far bigger than the 3% change threshold —
    /// landing exactly on the sampler's own ~266 ms sampling boundary (24 frames is a
    /// multiple of the ~8-frame gate 250 ms works out to at 30 fps), so every cut
    /// produces exactly one publish instead of straddling two. 300 frames make 13 such
    /// blocks (12 full, one partial), so this is a deterministic count, not a guess.
    func testTwoToneStreamPublishesAtMostThirteenTimesOverTenSeconds() async {
        let sampler = AmbientSampler()
        var publishes = 0
        for index in 0..<300 {
            let level: UInt8 = (index / 24) % 2 == 0 ? 20 : 220
            let frame = DecodedFrame(
                buffer: Self.makeSolidPixelBuffer(level: level),
                timestampMicros: UInt64(index) * Self.frameInterval)
            if await sampler.sample(frame) != nil { publishes += 1 }
        }
        XCTAssertLessThanOrEqual(publishes, 13, "expected at most 13 publishes, got \(publishes)")
        XCTAssertGreaterThan(publishes, 0, "the very first sample must always publish")
    }

    func testConstantColorPublishesExactlyOnce() async {
        let sampler = AmbientSampler()
        var publishes = 0
        for index in 0..<300 {
            let frame = DecodedFrame(
                buffer: Self.makeSolidPixelBuffer(level: 128),
                timestampMicros: UInt64(index) * Self.frameInterval)
            if await sampler.sample(frame) != nil { publishes += 1 }
        }
        XCTAssertEqual(publishes, 1)
    }

    /// A fully detached task carries no actor context of its own. If `AmbientSampler`
    /// were pinned to `@MainActor`, calling into it here would still type-check — every
    /// actor call needs `await` — but the work would run on the main actor's queue, the
    /// opposite of what step 8 asks for. Reading `components` back from the very same
    /// detached task, with no `MainActor.run` anywhere in sight, is the observable proof
    /// that never happened.
    func testSamplerIsNotMainActorIsolated() async {
        let sampler = AmbientSampler()
        let frame = DecodedFrame(buffer: Self.makeSolidPixelBuffer(level: 90), timestampMicros: 0)

        let result = await Task.detached {
            await sampler.sample(frame)
        }.value

        XCTAssertNotNil(result)
    }

    func testAverageColorMatchesASolidInput() async {
        let sampler = AmbientSampler()
        let frame = DecodedFrame(
            buffer: Self.makeSolidPixelBuffer(red: 200, green: 40, blue: 10), timestampMicros: 0)

        guard let colour = await sampler.sample(frame) else {
            return XCTFail("the first sample must always publish")
        }
        XCTAssertEqual(colour.r, 200.0 / 255, accuracy: 0.02)
        XCTAssertEqual(colour.g, 40.0 / 255, accuracy: 0.02)
        XCTAssertEqual(colour.b, 10.0 / 255, accuracy: 0.02)
    }

    /// A console restart brings its monotonic clock back near zero, so the next frame's
    /// timestamp lands *behind* the last one sampled rather than merely close to it.
    /// That must read as "due immediately", not underflow into "not due for a very
    /// long time".
    func testTimestampGoingBackwardsResamplesImmediately() async {
        let sampler = AmbientSampler()
        let before = DecodedFrame(
            buffer: Self.makeSolidPixelBuffer(level: 10), timestampMicros: 10_000_000)
        _ = await sampler.sample(before)

        let afterRestart = DecodedFrame(
            buffer: Self.makeSolidPixelBuffer(level: 250), timestampMicros: 1_000)
        let colour = await sampler.sample(afterRestart)
        XCTAssertNotNil(colour, "a clock reset should not be read as 'not due yet'")
    }

    // MARK: - Fixtures

    private static func makeSolidPixelBuffer(
        level: UInt8, width: Int = 64, height: Int = 36
    ) -> CVPixelBuffer {
        makeSolidPixelBuffer(red: level, green: level, blue: level, width: width, height: height)
    }

    private static func makeSolidPixelBuffer(
        red: UInt8, green: UInt8, blue: UInt8, width: Int = 64, height: Int = 36
    ) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        let pixelBuffer = buffer!

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
