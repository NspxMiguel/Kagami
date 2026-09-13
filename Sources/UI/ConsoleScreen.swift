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
            VideoSurface(video: session.decoder)
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
        .task {
            while !Task.isCancelled {
                if session.state == .streaming, let frame = session.decoder.frame {
                    if let components = await ambient.sample(DecodedFrame(buffer: frame)),
                        !Task.isCancelled, session.state == .streaming
                    {
                        glow = Color(red: components.r, green: components.g, blue: components.b)
                        session.ambientComponents = components
                    }
                } else {
                    glow = .clear
                }
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            }
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

        case .reconnecting:
            status(
                icon: "antenna.radiowaves.left.and.right",
                title: String(localized: "Reconnecting to the console"),
                detail: String(
                    localized: "Keep the console awake. The picture will return automatically."),
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

}
