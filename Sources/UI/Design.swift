import SwiftUI

/// Every colour, radius and duration in the app, in one place.
///
/// Nothing here is hard-coded at a use site. visionOS supplies the surface — glass over
/// passthrough — so this file is small on purpose: it defines what the system does not.
enum Design {
    /// The one accent. Phosphor green-cyan: the colour of a console that is switched on,
    /// and nobody else's brand.
    static let accent = Color(red: 0.24, green: 0.88, blue: 0.82)

    enum Radius {
        /// Anything you touch.
        static let pill: CGFloat = 999
        static let card: CGFloat = 24
        static let field: CGFloat = 16
        /// The console picture. Matches the Switch's own screen corners closely enough
        /// that the image reads as a device rather than a video player.
        static let screen: CGFloat = 20
    }

    enum Motion {
        /// Touch, state colour.
        static let tap = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.15)
        /// A value arriving or changing.
        static let value = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
        /// A panel, a screen.
        static let panel = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
        /// The ambient light following the picture. Slow on purpose: matching the frame
        /// rate would strobe the room on every cut.
        static let ambient = Animation.easeInOut(duration: 1.2)
    }

    /// Numbers are monospaced — frame counters that reflow on every digit look broken.
    static let counter = Font.system(.caption, design: .monospaced).weight(.medium)
}
