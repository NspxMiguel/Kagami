import RealityKit
import SwiftUI

/// A dark room around the screen.
///
/// Not a decorative environment: a lit living room behind a 720p picture washes it out,
/// and the console's own contrast is all it has. The immersion style is progressive, so
/// the Digital Crown decides how much of the room stays — this is a dimmer, not a
/// destination.
struct TheaterSpace: View {
    var body: some View {
        RealityView { content in
            let shell = ModelEntity(
                mesh: .generateSphere(radius: 12),
                materials: [UnlitMaterial(color: .black)])

            // Flipping one axis turns the sphere inside out so its inner face is what
            // gets drawn. Without this the shell is invisible from within.
            shell.scale = SIMD3(x: 1, y: 1, z: -1)
            content.add(shell)
        }
    }
}
