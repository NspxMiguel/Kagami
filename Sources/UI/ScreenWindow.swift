import SwiftUI

/// The window that holds the picture, plus the controls that float below it.
struct ScreenWindow: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var theaterOpen = false

    var body: some View {
        ConsoleScreen()
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                controls
                    .padding(.top, 18)
            }
            .onChange(of: session.isRunning) { _, running in
                // Losing the console should not leave an empty black pane floating in
                // the room with no way back to the address field.
                if !running {
                    openWindow(id: WindowID.setup)
                    dismissWindow(id: WindowID.screen)
                }
            }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            frameRate

            Divider().frame(height: 22)

            Toggle(isOn: Binding(
                get: { theaterOpen },
                set: { wanted in
                    theaterOpen = wanted
                    Task {
                        if wanted {
                            _ = await openSpace(id: WindowID.theater)
                        } else {
                            await dismissSpace()
                        }
                    }
                })) {
                    Label(String(localized: "Dim the room"), systemImage: "moon.stars")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(String(localized: "Dim the room"))

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Label(String(localized: "Disconnect"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Disconnect"))
        }
        .buttonBorderShape(.circle)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    /// A live frame counter, monospaced so it does not reflow on every digit. It is the
    /// one honest readout of whether the network is keeping up: 30 is the ceiling the
    /// console encodes at, and anything under 25 is felt before it is seen.
    private var frameRate: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state == .streaming ? Design.accent : .secondary)
                .frame(width: 7, height: 7)
            Text(session.framesPerSecond.formatted())
                .font(Design.counter)
                .contentTransition(.numericText())
                .accessibilityIdentifier("frameRateLabel")
            Text(String(localized: "fps"))
                .font(Design.counter)
                .foregroundStyle(.secondary)
        }
        .animation(Design.Motion.value, value: session.framesPerSecond)
    }
}
