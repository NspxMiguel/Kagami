import SwiftUI

/// The window that holds the picture, plus the controls that float below it.
struct ScreenWindow: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var theaterError = false

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
                    Task {
                        if session.theaterOpen { await dismissSpace() }
                        openWindow(id: WindowID.setup)
                        dismissWindow(id: WindowID.screen)
                    }
                }
            }
            .task {
                // Same manual-verification hook as `-autoConnect`: lets the theater
                // light be checked with a screenshot, with nothing driving the UI.
                if UserDefaults.standard.bool(forKey: "autoTheater") {
                    await setTheater(true)
                }
            }
            .onDisappear {
                if session.isRunning { session.disconnect() }
                if session.theaterOpen { Task { await dismissSpace() } }
            }
            .alert(String(localized: "Could not dim the room"), isPresented: $theaterError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "Try again after closing other immersive experiences."))
            }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            frameRate

            Divider().frame(height: 22)

            Toggle(isOn: Binding(
                    get: { session.theaterOpen },
                set: { wanted in
                        Task { await setTheater(wanted) }
                })) {
                    Label(String(localized: "Dim the room"), systemImage: "moon.stars")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(String(localized: "Dim the room"))
            .disabled(session.theaterTransitioning)

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

    private func setTheater(_ wanted: Bool) async {
        guard !session.theaterTransitioning else { return }
        session.theaterTransitioning = true
        defer { session.theaterTransitioning = false }
        if wanted {
            switch await openSpace(id: WindowID.theater) {
            case .opened:
                session.theaterOpen = true
                if !session.isRunning { await dismissSpace() }
            case .userCancelled: session.theaterOpen = false
            case .error:
                session.theaterOpen = false
                theaterError = true
            @unknown default: session.theaterOpen = false
            }
        } else {
            await dismissSpace()
            session.theaterOpen = false
        }
    }

    /// Uses the video renderer's displayed-frame metrics, excluding dropped frames.
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
