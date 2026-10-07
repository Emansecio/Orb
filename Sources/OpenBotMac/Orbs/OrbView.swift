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
            if animated && (appearsActive || OrbView.animateInactive) && !reduceMotion && !OrbView.forceStatic {
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

    /// Dev aid for profiling: `OPENBOT_STATIC_ORBS=1`.
    static let forceStatic = ProcessInfo.processInfo.environment["OPENBOT_STATIC_ORBS"] != nil
    /// Dev aid for profiling without focusing the app: `OPENBOT_ANIMATE_INACTIVE=1` keeps orbs animating
    /// while the window is inactive or hidden.
    static let animateInactive = ProcessInfo.processInfo.environment["OPENBOT_ANIMATE_INACTIVE"] != nil
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
        let side = size * OrbGeometry.imageScale
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
        let anchor = CGPoint(x: center.x, y: side * OrbGeometry.orbBottom)
        orb.translateBy(x: anchor.x + pose.shake * size, y: anchor.y - lift)
        orb.rotate(by: .degrees(pose.tilt))
        let turn = 1 - abs(pose.look.x) * 0.03
        orb.scaleBy(x: (1 + pose.squash + pose.hover * 0.04) * turn, y: 1 - pose.squash + pose.hover * 0.04)
        orb.translateBy(x: -anchor.x, y: -anchor.y)

        for layer in layers {
            guard let image = OrbImages.cgImage(layer.path, pixels: side * 2, tint: layer.tint) else { continue }
            var layerContext = orb
            let shift = parallax(layer)
            layerContext.translateBy(x: shift.width, y: shift.height)
            if layer.kind == .eyes, pose.blink > 0 {
                let line = side * OrbGeometry.eyeLine
                layerContext.translateBy(x: 0, y: line)
                layerContext.scaleBy(x: 1, y: max(0.08, 1 - pose.blink))
                layerContext.translateBy(x: 0, y: -line)
            }
            layerContext.draw(Image(decorative: image, scale: 1).interpolation(.high), in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        if let bubble = activity.bubble, size >= 26 {
            drawBubble(bubble, in: &context, center: CGPoint(x: center.x + size * 0.48, y: center.y - size * 0.5 - lift))
        }
    }

    /// Same offsets as `OrbAnimationView.applyPose` (y flipped: Canvas grows downward).
    private func parallax(_ layer: OrbLayer) -> CGSize {
        var x = pose.look.x * layer.depth, y = pose.look.y * layer.depth
        if layer.kind == .eyes { x += pose.eyeLead.x; y += pose.eyeLead.y }
        if layer.isLoose { x += pose.hairLag.x; y += pose.hairLag.y }
        return CGSize(width: x * size, height: -y * size)
    }

    private func drawBubble(_ text: String, in context: inout GraphicsContext, center: CGPoint) {
        let bob = pose.bubbleBob * size
        let fontSize = max(8, size * 0.2)
        let resolved = context.resolve(Text(text).font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Palette.ink))
        let textSize = resolved.measure(in: CGSize(width: 200, height: 100))
        let rect = CGRect(x: center.x - textSize.width / 2 - fontSize * 0.45, y: center.y + bob - textSize.height / 2 - fontSize * 0.1,
                          width: textSize.width + fontSize * 0.9, height: textSize.height + fontSize * 0.2)
        var bubble = context
        bubble.opacity = pose.bubbleOpacity
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
