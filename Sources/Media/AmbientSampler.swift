import Accelerate
import CoreVideo
import Foundation
import VideoToolbox

/// Publishes an average colour for the theater to glow, sampled far below the video
/// frame rate and entirely off the main actor.
///
/// This used to be `AmbientLight`, a `CoreImage`-backed actor living in `Sources/UI`
/// that a SwiftUI `.task` polled every 220 ms. That polling loop still ran on the view
/// (the immersive space's own compositor budget), and `CIContext` cannot be exercised
/// by `swift test` because `Sources/UI` sits outside the package `swift test` builds.
/// This type lives in the ingest pipeline instead: `VideoIngest` feeds it every
/// successfully decoded picture, and it decides for itself — by the console's own
/// capture clock, never wall time — whether there is anything worth doing.
///
/// The reduction happens in two stages, each doing the part it is actually good at:
/// `VTPixelTransferSession` collapses a full-resolution YUV frame straight to a tiny
/// 16x9 BGRA buffer in one call (format conversion and the big downscale together,
/// wherever the platform can push that into fixed-function hardware), and only then
/// does `vImage` reduce that already-tiny buffer the rest of the way to one pixel —
/// cheap precisely because there are only 144 pixels left to look at by then.
actor AmbientSampler {
    /// How rarely to actually do the work. Four samples a second is fast enough that a
    /// scene cut is never far behind, and slow enough that the cost is not worth
    /// measuring against a 33 ms frame budget.
    static let sampleIntervalMicros: UInt64 = 250_000
    /// A colour distance below this is "the same colour" and is not republished — a
    /// rough delta-E stand-in, cheap enough to compute from the raw channels rather
    /// than round-tripping through Lab for a light that ends up blurred and dimmed
    /// before anyone sees it anyway.
    static let changeThreshold: Double = 0.03

    private static let width = 16
    private static let height = 9

    private var transferSession: VTPixelTransferSession?
    private var lastSampledTimestampMicros: UInt64?
    private var hasPublished = false
    private(set) var components: (r: Double, g: Double, b: Double) = (0, 0, 0)

    init() {}

    isolated deinit {
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    /// Downscales and averages `frame` when enough console-clock time has passed since
    /// the last sample, and returns the new colour only when it changed by more than
    /// `changeThreshold`. Returns `nil` on every call that either skips the interval
    /// gate or fails to change enough — a caller never needs to re-derive "did this
    /// publish" by comparing against the last value it saw.
    func sample(_ frame: DecodedFrame) -> (r: Double, g: Double, b: Double)? {
        guard shouldSample(at: frame.timestampMicros) else { return nil }
        lastSampledTimestampMicros = frame.timestampMicros

        guard let candidate = averageColor(of: frame.buffer) else { return nil }
        guard !hasPublished || distance(candidate, components) > Self.changeThreshold else {
            return nil
        }

        components = candidate
        hasPublished = true
        return candidate
    }

    func reset() {
        lastSampledTimestampMicros = nil
        hasPublished = false
        components = (0, 0, 0)
    }

    /// Gated on the console's own capture clock rather than wall time, so a test can
    /// feed 300 frames instantly and still see exactly the sampling cadence a real
    /// 30 fps stream would produce. A timestamp older than the last one sampled (a
    /// console restart) is treated as due immediately rather than underflowing.
    private func shouldSample(at timestampMicros: UInt64) -> Bool {
        guard let last = lastSampledTimestampMicros else { return true }
        guard timestampMicros >= last else { return true }
        return timestampMicros - last >= Self.sampleIntervalMicros
    }

    private func distance(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func averageColor(of source: CVPixelBuffer) -> (r: Double, g: Double, b: Double)? {
        guard let session = transferSessionOrMake() else { return nil }

        var small: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, Self.width, Self.height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &small) == kCVReturnSuccess,
            let small
        else { return nil }

        guard VTPixelTransferSessionTransferImage(session, from: source, to: small) == noErr
        else { return nil }

        return averagePixel(of: small)
    }

    private func transferSessionOrMake() -> VTPixelTransferSession? {
        if let transferSession { return transferSession }
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
            let created
        else { return nil }
        transferSession = created
        return created
    }

    /// The final reduction, 16x9 down to a single pixel. `vImageScale_ARGB8888`'s own
    /// high-quality resampler does an honest area average when shrinking, so a uniform
    /// input reduces to exactly itself and a non-uniform one reduces to its mean —
    /// there is nothing left to hand-roll here.
    private func averagePixel(of buffer: CVPixelBuffer) -> (r: Double, g: Double, b: Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))

        // `vImage_Buffer.data` only borrows whatever pointer it is given — it does not
        // extend that pointer's lifetime — so the destination buffer must be built and
        // consumed inside the same `withUnsafeMutableBytes` scope as the array backing
        // it. Building it from `&pixel` directly (valid only for that one call
        // expression) would let `destination.data` dangle by the time `pixel` is read
        // below.
        var pixel = [UInt8](repeating: 0, count: 4)
        let error = pixel.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(data: raw.baseAddress, height: 1, width: 1, rowBytes: 4)
            return vImageScale_ARGB8888(
                &source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard error == kvImageNoError else { return nil }

        // BGRA byte order in memory: B, G, R, A.
        return (r: Double(pixel[2]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[0]) / 255)
    }
}
