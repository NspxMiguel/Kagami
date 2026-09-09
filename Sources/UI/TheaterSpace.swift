import RealityKit
import SwiftUI

/// A dark room around the screen — lit only by the screen itself.
///
/// The first version of this was a flat black sphere: correct for hiding a lit living
/// room behind a 720p picture, but dead on arrival — it had no relationship to the
/// window it was meant to be dimming *around*, so it read as static no matter what was
/// playing. This version takes the same colour `ConsoleScreen` already bleeds past its
/// own edges (`Session.ambientComponents`) and uses it as the room's only light source:
/// a cave level goes near-black, a snow field casts a pale wash across the walls. The
/// room is dark because the console is the only thing allowed to light it, not because
/// it is painted a fixed colour.
struct TheaterSpace: View {
    @Environment(Session.self) private var session
    @State private var lamp: PointLight?

    var body: some View {
        RealityView { content in
            let shell = ModelEntity(
                mesh: .generateSphere(radius: 12),
                // Near-black, not pure black: a little diffuse reflectance is what lets
                // the point light below actually paint the walls with colour. Pure black
                // would swallow the light as fast as it arrives.
                materials: [SimpleMaterial(color: .black, roughness: 1, isMetallic: false)])
            // Flipping one axis turns the sphere inside out so its inner face is what
            // gets drawn. Without this the shell is invisible from within.
            shell.scale = SIMD3(x: 1, y: 1, z: -1)
            content.add(shell)

            let light = PointLight()
            light.light.intensity = 0
            light.light.attenuationRadius = 14
            content.add(light)
            lamp = light
        } update: { _ in
            guard let lamp else { return }
            let (r, g, b) = session.ambientComponents
            let peak = max(r, max(g, b))

            lamp.light.color = PlatformColor(red: r, green: g, blue: b, alpha: 1)
            // Scaled well past the window glow's own intensity: that effect lights a
            // few centimetres past the screen's edge, this one has an entire room to
            // reach, and light falls off with distance far faster than it looks like it
            // should from behind a rectangle of glass.
            lamp.light.intensity = Float(peak) * 8000
        }
    }
}

#if os(visionOS) || os(iOS)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif
