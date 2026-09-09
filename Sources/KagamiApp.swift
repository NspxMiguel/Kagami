import SwiftUI

enum WindowID {
    static let setup = "setup"
    static let screen = "screen"
    static let theater = "theater"
}

@main
struct KagamiApp: App {
    @State private var session = Session()

    var body: some Scene {
        // Setup and picture are separate windows rather than one window swapping its
        // contents: a form wants to be form-sized and a 16:9 picture wants to be as big
        // as the wall, and one window cannot be both without fighting the person.
        WindowGroup(id: WindowID.setup) {
            ConnectView()
                .environment(session)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 700)

        WindowGroup(id: WindowID.screen) {
            ScreenWindow()
                .environment(session)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)

        ImmersiveSpace(id: WindowID.theater) {
            TheaterSpace()
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive, .full)
    }
}
