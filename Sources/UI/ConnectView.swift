import SwiftUI

/// The first screen: where the console is, and what has to be true for this to work.
///
/// Deliberately one field and one button. Everything else on this screen exists to
/// answer the question someone actually has the first time — "what do I install on the
/// Switch?" — instead of making them find a wiki.
struct ConnectView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var session = session

        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kagami")
                    .font(.system(size: 34, weight: .heavy))
                    .tracking(-0.7)
                Text(String(localized: "Your Switch, on your face."))
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "CONSOLE ADDRESS"))
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)

                TextField("192.168.0.42", text: $session.host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, design: .monospaced))
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.field, style: .continuous))
                    .focused($addressFocused)
                    .onSubmit { session.connect() }
                    .accessibilityIdentifier("consoleAddressField")

                Text(String(localized: "On the console: System Settings › Internet, under the connected network."))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 14) {
                Toggle(String(localized: "Play console audio"), isOn: $session.playAudio)
                Toggle(String(localized: "Blank the console screen while streaming"), isOn: $session.turnOffConsoleScreen)
            }
            .font(.system(size: 15))

            if case .failed(let message) = session.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            Button {
                session.connect()
            } label: {
                Text(String(localized: "Connect"))
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Design.accent)
            .buttonBorderShape(.capsule)
            .disabled(session.host.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("connectButton")

            requirements
        }
        .padding(40)
        .frame(width: 560)
        .animation(Design.Motion.value, value: session.state)
        .onChange(of: session.isRunning) { _, running in
            guard running else { return }
            openWindow(id: WindowID.screen)
            dismissWindow(id: WindowID.setup)
        }
    }

    /// What has to be set up on the console. Three lines, in order, no wiki.
    private var requirements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "ON THE SWITCH"))
                .font(.system(size: 12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            step(1, String(localized: "Atmosphère, with SysDVR installed as a sysmodule."))
            step(2, String(localized: "SysDVR set to Simple network mode (TCP), then reboot."))
            step(3, String(localized: "Both devices on the same network. Wired beats Wi-Fi."))
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number.formatted())
                .font(Design.counter)
                .foregroundStyle(Design.accent)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}
