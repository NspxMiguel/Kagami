import CoreVideo
import SwiftUI
import VideoToolbox

/// The console's picture, floating in the room.
struct ConsoleScreen: View {
    @Environment(Session.self) private var session
    @State private var ambient = AmbientLight()
    @State private var glow: Color = .clear

    var body: some View {
        ZStack {
            picture
            overlay
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.screen, style: .continuous))
        // The light of the game, thrown past the edges of the screen. Sits behind the
        // picture and outside it, which is why it reads as spill rather than a border.
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.screen, style: .continuous)
                .fill(glow)
                .blur(radius: 70)
                .opacity(0.55)
                .padding(-28)
                .allowsHitTesting(false)
        }
        .animation(Design.Motion.ambient, value: glow)
    }

    @ViewBuilder
    private var picture: some View {
        if let frame = session.decoder.frame {
            Image(decorative: cgImage(from: frame), scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .onChange(of: session.decoder.framesDecoded) {
                    if ambient.sample(frame) {
                        glow = ambient.colour
                        session.ambientComponents = ambient.components
                    }
                }
        } else {
            Color.black
        }
    }

    /// What the screen says when there is no picture. Each case names the next step
    /// rather than the failure — "no frames" is true and useless.
    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connecting:
            status(icon: "antenna.radiowaves.left.and.right",
                   title: String(localized: "Reaching the console"),
                   detail: String(localized: "Make sure SysDVR is running in TCP mode."),
                   spinning: true)

        case .waitingForGame:
            status(icon: "gamecontroller",
                   title: String(localized: "Waiting for a game"),
                   detail: String(localized: "The console only shares its screen while a game is open — the HOME menu stays private."),
                   spinning: true)

        case .failed(let message):
            status(icon: "exclamationmark.triangle",
                   title: String(localized: "The stream stopped"),
                   detail: message,
                   spinning: false)

        case .idle, .streaming:
            EmptyView()
        }
    }

    private func status(icon: String, title: String, detail: String, spinning: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 22, weight: .semibold))

            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if spinning { ProgressView().controlSize(.small) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image ?? Self.blank
    }

    private static let blank: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return context.makeImage()!
    }()
}
