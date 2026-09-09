import CoreImage
import CoreVideo
import SwiftUI

/// Pulls the average colour out of a frame, so the space around the screen can carry the
/// light of whatever is on it.
///
/// This is the app's one signature: a mirror that also throws light. A cave level dims
/// the room, a snow field brightens it, and the picture stops looking like a rectangle
/// pasted in front of your living room.
///
/// The averaging runs on the GPU through `CIAreaAverage` and reduces the whole frame to
/// a single pixel, which is cheap — but not free, so it samples a few times a second
/// rather than every frame. Faster than that would strobe on every cut anyway.
@MainActor
final class AmbientLight {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private var lastSample = Date.distantPast
    private let interval: TimeInterval = 0.2

    private(set) var colour: Color = .clear
    /// The same colour as raw linear components, for RealityKit material code that has
    /// no reason to round-trip through a SwiftUI `Color` to get three numbers back out.
    private(set) var components: (r: Double, g: Double, b: Double) = (0, 0, 0)

    /// Returns true when the colour changed and the view should animate to it.
    @discardableResult
    func sample(_ buffer: CVPixelBuffer) -> Bool {
        guard Date().timeIntervalSince(lastSample) >= interval else { return false }
        lastSample = Date()

        let image = CIImage(cvPixelBuffer: buffer)
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent),
        ])
        guard let output = filter?.outputImage else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)

        // Lifted towards its own brightest form: the raw average of a dark game is nearly
        // black, and light you cannot see is not light.
        let raw = (r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
        let peak = max(raw.r, max(raw.g, raw.b))
        guard peak > 0.02 else {
            colour = .clear
            components = (0, 0, 0)
            return true
        }
        let lift = min(1.0, 0.55 / max(peak, 0.08))

        components = (min(1, raw.r * lift), min(1, raw.g * lift), min(1, raw.b * lift))
        colour = Color(red: components.r, green: components.g, blue: components.b)
        return true
    }
}
