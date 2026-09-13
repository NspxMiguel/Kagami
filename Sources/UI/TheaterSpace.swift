import RealityKit
import SwiftUI

/// An emissive dark environment whose tint follows the console's average color.
struct TheaterSpace: View {
    @Environment(Session.self) private var session
    @State private var shell: ModelEntity?

    var body: some View {
        RealityView { content in
            let shell = ModelEntity(
                mesh: .generateSphere(radius: 12),
                materials: [UnlitMaterial(color: .black)])
            // Flipping one axis turns the sphere inside out so its inner face is what
            // gets drawn. Without this the shell is invisible from within.
            shell.scale = SIMD3(x: 1, y: 1, z: -1)
            content.add(shell)
            self.shell = shell
        } update: { _ in
            guard let shell else { return }
            let (r, g, b) = session.ambientComponents
            // Direct emission follows the content reliably. A black diffuse material
            // cannot reflect the colored point light used by the previous version.
            let strength = Design.theaterBrightness
            shell.model?.materials = [
                UnlitMaterial(
                    color: PlatformColor(
                        red: r * strength, green: g * strength, blue: b * strength, alpha: 1))
            ]
        }
        .onAppear { session.theaterOpen = true }
        .onDisappear { session.theaterOpen = false }
    }
}

#if os(visionOS) || os(iOS)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif
