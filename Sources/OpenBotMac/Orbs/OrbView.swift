import SwiftUI
import AppKit

// MARK: - Orb view

/// A bot's Orb: composited 3D-rendered layers with live animation.
/// - Eyes, brows and mouth shift with the gaze (parallax), so the orb seems to turn its head.
/// - Gaze follows the pointer within a radius, otherwise follows the activity's pattern.
/// - Blinks, breathes, hops and changes expression with the activity; jumps on `poke` changes and taps.
/// Animated orbs run on Core Animation (`OrbAnimationView`); static ones draw once with a Canvas.
struct OrbView: View {
    let config: OrbConfig
    var activity: OrbActivity = .idle
    var size: CGFloat = 28
    var animated = true
    var followsPointer = true
    /// Changing this value makes the orb jump (e.g. when a prompt is sent).
    var poke = 0
    var interactive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            if animated && appearsActive && !reduceMotion && !OrbView.forceStatic {
                AnimatedOrb(config: config, activity: activity, size: size, followsPointer: followsPointer,
                            poke: poke, interactive: interactive)
            } else {
                OrbFrame(config: config, activity: activity, size: size, pose: .rest)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Orb, \(activity.label)")
    }

    /// Dev aid for profiling: `OPENBOT_STATIC_PETS=1`.
    static let forceStatic = ProcessInfo.processInfo.environment["OPENBOT_STATIC_PETS"] != nil
}

/// Per-frame pose (all relative to size).
struct OrbPose {
    var look = CGPoint.zero
    var lift = 0.0
    var squash = 0.0
    var tilt = 0.0
    var shake = 0.0
    var blink = 0.0
    var glow = 1.0
    var hover = 0.0
    var time = 0.0

    static let rest = OrbPose()
}

/// Draws one frame of the Orb from its layers in a single Canvas (no per-frame layout work).
/// The canvas is an overlay larger than `size`, so hats, halos and glow can overflow the avatar box.
struct OrbFrame: View {
    let config: OrbConfig
    let activity: OrbActivity
    let size: CGFloat
    let pose: OrbPose

    var body: some View {
        let layers = config.layers(eyes: activity.eyes, mouth: activity.mouth(base: config.mouth), brows: activity.brows)
        let side = size * 1.96
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                Canvas(rendersAsynchronously: true) { context, _ in
                    OrbPainter(config: config, activity: activity, layers: layers, size: size, side: side, pose: pose)
                        .draw(in: &context)
                }
                .frame(width: side, height: side)
                .allowsHitTesting(false)
            }
    }
}

private struct OrbPainter {
    let config: OrbConfig
    let activity: OrbActivity
    let layers: [OrbLayer]
    let size: CGFloat
    /// Side of the rendered layer images (the orb fills ~51% of it).
    let side: CGFloat
    let pose: OrbPose

    /// Eye line and orb bottom in image-relative coordinates.
    private static let eyeLine: CGFloat = 0.455
    private static let orbBottom: CGFloat = 0.755

    @MainActor
    func draw(in context: inout GraphicsContext) {
        let palette = OrbCatalog.shared.palette(config.color)
        let center = CGPoint(x: side / 2, y: side / 2)
        let lift = pose.lift * size

        // Ground glow (soft ellipse that shrinks while the orb is in the air)
        var ground = context
        ground.translateBy(x: center.x, y: center.y + size * 0.5)
        ground.scaleBy(x: 1.05 * (1 - pose.lift * 2), y: 0.2)
        ground.fill(Path(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)),
                    with: .radialGradient(Gradient(colors: [palette.core.opacity(0.55 * pose.glow),
                                                            palette.core.opacity(0.12 * pose.glow), .clear]),
                                          center: .zero, startRadius: 0, endRadius: size / 2))
        // Aura
        let aura = CGRect(x: center.x - size * 0.75, y: center.y - lift - size * 0.75, width: size * 1.5, height: size * 1.5)
        context.fill(Path(ellipseIn: aura),
                     with: .radialGradient(Gradient(colors: [palette.core.opacity(0.28 * pose.glow), .clear]),
                                           center: CGPoint(x: aura.midX, y: aura.midY),
                                           startRadius: size * 0.3, endRadius: size * 0.75))

        // Body transform: squash/tilt around the orb's bottom, then lift, shake and hover
        var orb = context
        let anchor = CGPoint(x: center.x, y: side * Self.orbBottom)
        orb.translateBy(x: anchor.x + pose.shake * size, y: anchor.y - lift)
        orb.rotate(by: .degrees(pose.tilt))
        let turn = 1 - abs(pose.look.x) * 0.03
        orb.scaleBy(x: (1 + pose.squash + pose.hover * 0.04) * turn, y: 1 - pose.squash + pose.hover * 0.04)
        orb.translateBy(x: -anchor.x, y: -anchor.y)

        for layer in layers {
            guard let image = OrbImages.image(layer.path, pixels: side * 2) else { continue }
            var layerContext = orb
            let shift = parallax(layer.kind)
            layerContext.translateBy(x: shift.width, y: shift.height)
            if layer.kind == .eyes, pose.blink > 0 {
                let line = side * Self.eyeLine
                layerContext.translateBy(x: 0, y: line)
                layerContext.scaleBy(x: 1, y: max(0.08, 1 - pose.blink))
                layerContext.translateBy(x: 0, y: -line)
            }
            if let tint = layer.tint {
                layerContext.addFilter(.colorMultiply(Color(hex: tint)))
            }
            layerContext.draw(Image(nsImage: image).interpolation(.high), in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        if let bubble = activity.bubble, size >= 26 {
            drawBubble(bubble, in: &context, center: CGPoint(x: center.x + size * 0.48, y: center.y - size * 0.5 - lift))
        }
    }

    private func parallax(_ kind: OrbLayer.Kind) -> CGSize {
        let depth: Double = switch kind {
        case .body: 0
        case .eyes: 0.075
        case .brows: 0.07
        case .mouth, .mustache, .cheeks: 0.055
        case .hair, .accessory: 0.025
        }
        return CGSize(width: pose.look.x * depth * size, height: -pose.look.y * depth * size)
    }

    private func drawBubble(_ text: String, in context: inout GraphicsContext, center: CGPoint) {
        let bob = sin(pose.time * 3) * size * 0.03
        let fontSize = max(8, size * 0.2)
        let resolved = context.resolve(Text(text).font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Palette.ink))
        let textSize = resolved.measure(in: CGSize(width: 200, height: 100))
        let rect = CGRect(x: center.x - textSize.width / 2 - fontSize * 0.45, y: center.y + bob - textSize.height / 2 - fontSize * 0.1,
                          width: textSize.width + fontSize * 0.9, height: textSize.height + fontSize * 0.2)
        var bubble = context
        bubble.opacity = 0.6 + 0.4 * (0.5 + 0.5 * sin(pose.time * 2.4))
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        bubble.fill(capsule, with: .color(.white.opacity(0.14)))
        bubble.stroke(capsule, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        bubble.draw(resolved, at: CGPoint(x: center.x, y: center.y + bob))
    }
}

// MARK: - Bot avatar

struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 28
    var activity: OrbActivity = .idle
    var animated = true
    var poke = 0
    var interactive = false

    var body: some View {
        OrbView(config: bot.orb, activity: activity, size: size, animated: animated, poke: poke, interactive: interactive)
    }
}
