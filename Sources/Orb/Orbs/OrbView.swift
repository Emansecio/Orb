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
    /// false: always static (cheap for many orbs, e.g. in the transcript).
    var animated = true
    /// An animated orb that should hold still for now (e.g. an idle, unselected sidebar row). It eases into its
    /// resting pose and stops producing frames, and eases back into motion when unpaused, without a jump. The
    /// same happens while the window is inactive.
    var paused = false
    var followsPointer = true
    /// Changing this value makes the orb jump (a click on it, a button that makes it hop).
    var poke = 0
    /// Changing this value makes the orb give its small "got it" jump (a prompt was sent).
    var ack = 0
    /// Changing this value makes the orb squash and wobble as it lands (an entrance ended).
    var landing = 0
    /// Changing this value makes the orb blink and glance toward the chat (e.g. when it is selected). Not with
    /// Reduce Motion: the static orb ignores it.
    var glance = 0
    /// A new cue makes the orb blink or sigh once (you stopped its reply, a task stopped half way).
    var cue = OrbCueSignal()
    /// How big its joy is while `activity` is `happy`.
    var celebration = OrbCelebration.big
    var interactive = false
    /// What VoiceOver says (default: "Orb" and what it is doing).
    var accessibilityText: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            if animated && !reduceMotion && !OrbView.forceStatic {
                AnimatedOrb(config: config, activity: activity, size: size, followsPointer: followsPointer,
                            poke: poke, ack: ack, landing: landing, glance: glance, cue: cue, celebration: celebration,
                            interactive: interactive,
                            live: !paused && (appearsActive || OrbView.animateInactive))
            } else {
                OrbFrame(config: config, activity: activity, size: size, pose: .rest)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText ?? "Orb, \(activity.label)")
    }

    /// Dev aid for profiling: `ORB_STATIC=1`.
    /// Offscreen snapshots (`--snapshot`) can't capture Core Animation layers either.
    static let forceStatic = ProcessInfo.processInfo.environment["ORB_STATIC"] != nil
        || CommandLine.arguments.contains("--snapshot")
    /// Dev aid for profiling without focusing the app: `ORB_ANIMATE_INACTIVE=1` keeps orbs animating
    /// while the window is inactive or hidden.
    /// (A `var` so tests, which have no visible window, can turn it on.)
    nonisolated(unsafe) static var animateInactive = ProcessInfo.processInfo.environment["ORB_ANIMATE_INACTIVE"] != nil
}

/// Draws one frame of the Orb from its layers in a single Canvas (no per-frame layout work).
/// The canvas is an overlay larger than `size`, so hats, halos and glow can overflow the avatar box.
struct OrbFrame: View {
    let config: OrbConfig
    let activity: OrbActivity
    let size: CGFloat
    let pose: OrbPose

    @Environment(\.displayScale) private var displayScale
    /// Counts bitmap batches that finished decoding: the canvas draws again when one arrives.
    @State private var decodedBatches = 0
    /// The last set of layers that was entirely decoded, with the bitmaps themselves: drawn while the wanted set is still
    /// loading, so the orb never shows up half made (without eyes or mouth) and keeps its old face until the new one is
    /// ready. It holds the images, not only their keys: the shared cache is bounded and may drop them at any time (the
    /// editor makes dozens of variants), and a still orb must not go blank for that.
    @State private var complete: Complete?

    /// What the canvas needs decoded: the same layers at the same pixel size draw the same bitmaps.
    struct Bitmaps: Hashable {
        let layers: [OrbLayer]
        let pixels: CGFloat
    }

    /// A set whose bitmaps were all decoded (`images[i]` is `bitmaps.layers[i]`'s).
    struct Complete {
        let bitmaps: Bitmaps
        let images: [CGImage]
    }

    /// A layer and its bitmap. `image` is nil only when snapshots and sheets draw in place (`OrbImages.decodesSynchronously`).
    struct Drawn {
        let layer: OrbLayer
        let image: CGImage?
    }

    /// The layers to draw now, with their bitmaps: the wanted ones when they are all decoded, else the last complete set
    /// (if its pixel size matches), else nothing. Never a part of a set, and drawing never looks at the cache again.
    static func drawable(wanted: Bitmaps, complete: Complete?) -> [Drawn] {
        if OrbImages.decodesSynchronously { return wanted.layers.map { Drawn(layer: $0, image: nil) } }
        if let images = OrbImages.cachedImages(wanted.layers, pixels: wanted.pixels) {
            return zip(wanted.layers, images).map { Drawn(layer: $0, image: $1) }
        }
        guard let complete, complete.bitmaps.pixels == wanted.pixels else { return [] }
        return zip(complete.bitmaps.layers, complete.images).map { Drawn(layer: $0, image: $1) }
    }

    /// The activity's expression; a talking Orb shows an open mouth shape.
    private var layers: [OrbLayer] {
        let layers = config.layers(eyes: activity.eyes, mouth: activity.mouth(base: config.mouth), brows: activity.brows)
        guard activity == .speaking, let open = config.visemeLayers()?[.open] else { return layers }
        return layers.map { $0.kind == .mouth ? open : $0 }
    }

    var body: some View {
        let layers = layers
        let scale = displayScale
        let side = OrbGeometry.imageSide(for: size, scale: scale)
        let batches = decodedBatches
        let wanted = Bitmaps(layers: layers, pixels: side * scale)
        let drawn = Self.drawable(wanted: wanted, complete: complete)
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                Canvas(rendersAsynchronously: true) { context, _ in
                    OrbPainter(config: config, activity: activity, layers: drawn, size: size, side: side, scale: scale,
                               pose: pose, decodedBatches: batches)
                        .draw(in: &context)
                }
                .frame(width: side, height: side)
                .allowsHitTesting(false)
            }
            // The canvas draws on the main thread, so it never decodes: missing bitmaps are decoded in the
            // background and the orb appears when they are ready.
            .task(id: wanted) {
                guard !OrbImages.decodesSynchronously else { return }
                if !OrbImages.isCached(wanted.layers, pixels: wanted.pixels) {
                    await OrbImages.load(wanted.layers, pixels: wanted.pixels)
                    // A newer set was asked for meanwhile (this task was cancelled): it takes over.
                    guard !Task.isCancelled else { return }
                    decodedBatches += 1
                }
                if let images = OrbImages.cachedImages(wanted.layers, pixels: wanted.pixels) {
                    complete = Complete(bitmaps: wanted, images: images)
                }
            }
    }
}

private struct OrbPainter {
    let config: OrbConfig
    let activity: OrbActivity
    let layers: [OrbFrame.Drawn]
    let size: CGFloat
    /// Side of the rendered layer images (the orb fills ~51% of it), see `OrbGeometry.imageSide`.
    let side: CGFloat
    /// Display scale: bitmaps are decoded at exactly the drawn pixel size.
    let scale: CGFloat
    let pose: OrbPose
    /// Not used by the drawing: it makes the canvas redraw when more bitmaps are decoded.
    var decodedBatches = 0

    @MainActor
    func draw(in context: inout GraphicsContext) {
        let palette = OrbCatalog.shared.palette(config.color)
        let center = CGPoint(x: side / 2, y: side / 2)
        let lift = pose.lift * size

        // Ground glow (soft ellipse that shrinks and fades while the orb is in the air), as in the live orb
        let shadow = OrbShadow.ground(for: pose)
        var ground = context
        ground.translateBy(x: center.x, y: center.y + size * 0.5)
        ground.scaleBy(x: shadow.width, y: shadow.height)
        ground.fill(Path(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)),
                    with: .radialGradient(Gradient(colors: [palette.core.opacity(0.55 * shadow.opacity),
                                                            palette.core.opacity(0.12 * shadow.opacity), .clear]),
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

        for item in layers {
            let layer = item.layer
            let image = item.image ?? (OrbImages.decodesSynchronously
                ? OrbImages.cgImage(layer.path, pixels: side * scale, tint: layer.tint) : nil)
            guard let image else { continue }
            var layerContext = orb
            let shift = parallax(layer)
            layerContext.translateBy(x: shift.width, y: shift.height)
            if layer.isLoose, pose.hairSwing != 0 {
                // Around the top of the head, as the live orb does.
                let crown = side * OrbGeometry.crownLine
                layerContext.translateBy(x: side / 2, y: crown)
                layerContext.rotate(by: .degrees(pose.hairSwing))
                layerContext.translateBy(x: -side / 2, y: -crown)
            }
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

    /// Same offsets as `OrbAnimationView.apply` (y flipped: Canvas grows downward).
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
        bubble.fill(capsule, with: .color(Palette.chrome.opacity(OrbGeometry.bubbleFill)))
        bubble.stroke(capsule, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
        bubble.draw(resolved, at: CGPoint(x: center.x, y: center.y + bob))
    }
}

// MARK: - Bot avatar

/// An Orb's avatar. Takes the Orb's look, not the whole `Bot`, so a change to its permissions or folder does not
/// re-render it.
struct BotAvatar: View {
    let orb: OrbConfig
    var size: CGFloat = 28
    var activity: OrbActivity = .idle
    var celebration = OrbCelebration.big
    var animated = true
    var paused = false
    var poke = 0
    var ack = 0
    var landing = 0
    var glance = 0
    var cue = OrbCueSignal()
    var interactive = false

    var body: some View {
        OrbView(config: orb, activity: activity, size: size, animated: animated, paused: paused, poke: poke, ack: ack,
                landing: landing, glance: glance, cue: cue, celebration: celebration, interactive: interactive)
    }
}

extension BotAvatar {
    init(bot: Bot, size: CGFloat = 28, activity: OrbActivity = .idle, animated: Bool = true, paused: Bool = false,
         poke: Int = 0, interactive: Bool = false) {
        self.init(orb: bot.orb, size: size, activity: activity, animated: animated, paused: paused, poke: poke,
                  interactive: interactive)
    }

    /// The Orb as it is now: what it does, how much it celebrates and the cue it was given.
    init(live: BotLive, size: CGFloat, paused: Bool = false) {
        self.init(orb: live.look.orb, size: size, activity: live.activity, celebration: live.celebration, paused: paused,
                  cue: live.cue)
    }
}
