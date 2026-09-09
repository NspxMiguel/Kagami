import XCTest

/// Drives the app exactly as a person would after the address is filled in: hit
/// Connect, watch for a picture. This is the proof a plain screenshot cannot give —
/// that the button actually reaches SysDVRStream and a real decoded frame comes back.
///
/// The address itself is preset via a launch argument rather than typed, because
/// `UserDefaults` reads `-key value` launch arguments into its standard domain — the
/// documented way to seed state for a UI test — and it sidesteps the visionOS
/// Simulator's hardware-keyboard quirks entirely, which are a simulator detail, not
/// something this test is meant to be about.
final class ConnectFlowTests: XCTestCase {
    func testConnectsToFakeConsoleAndReceivesFrames() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-console.host", "127.0.0.1"]
        app.launch()

        let field = app.textFields["consoleAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the address field never appeared")
        XCTAssertEqual(field.value as? String, "127.0.0.1", "the preset host did not reach the field")

        let connect = app.buttons["connectButton"]
        XCTAssertTrue(connect.isEnabled, "Connect stayed disabled with a host already set")
        connect.tap()

        // The screen window opens as its own scene; frameRateLabel only exists there.
        let fps = app.staticTexts["frameRateLabel"]
        XCTAssertTrue(fps.waitForExistence(timeout: 15), "the screen window never opened")

        // Give the decoder a few seconds of real packets, then require a non-zero rate —
        // that means SysDVRStream connected, handshook, and VideoToolbox decoded frames.
        let deadline = Date().addingTimeInterval(15)
        var sawFrames = false
        while Date() < deadline {
            if let value = fps.value as? String, let rate = Int(value), rate > 0 {
                sawFrames = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(sawFrames, "frame rate stayed at zero — no frames were decoded")
    }
}
