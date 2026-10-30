import SwiftUI
import AppKit
import QuartzCore

// MARK: - SwiftUI bridge

/// Live Orb. Frames are produced by a display link (shared by all orbs on a screen, see `OrbDriver`) that only
/// moves Core Animation layers, so an animating orb costs no SwiftUI updates or layout passes (SwiftUI only
/// hears about config changes).
struct AnimatedOrb: NSViewRepresentable {
    let config: OrbConfig
    let activity: OrbActivity
    let size: CGFloat
    /// nil: the bubble shows when `size` is big enough (`OrbGeometry.bubbleBox`).
    var showsBubble: Bool?
    let followsPointer: Bool
    /// Changing this value makes the orb give its big jump (what a click does).
    let poke: Int
    /// Changing this value makes the orb give its small "got it" jump (a prompt was sent).
    var ack = 0
    /// Changing this value makes the orb squash and wobble as it lands (it just arrived on the floor).
    var landing = 0
    /// Changing this value makes the orb blink and glance toward the chat (it was selected).
    var glance = 0
    /// Each new cue makes the orb blink or sigh once.
    var cue = OrbCueSignal()
    /// How big its joy is while `activity` is `happy`.
    var celebration = OrbCelebration.big
    let interactive: Bool
    /// false: the orb eases into its resting pose and stops producing frames (inactive window, idle sidebar row).
    let live: Bool

    func makeNSView(context: Context) -> OrbAnimationView {
        let view = OrbAnimationView()
        view.lastPoke = poke
        view.lastAck = ack
        view.lastLanding = landing
        view.lastGlance = glance
        view.lastCue = cue
        update(view)
        return view
    }

    static func dismantleNSView(_ view: OrbAnimationView, coordinator: ()) {
        view.stop()
    }

    func updateNSView(_ view: OrbAnimationView, context: Context) {
        update(view)
        if view.lastPoke != poke {
            view.lastPoke = poke
            view.jumpNow(.play)
        }
        if view.lastAck != ack {
            view.lastAck = ack
            view.jumpNow(.ack)
        }
        if view.lastLanding != landing {
            view.lastLanding = landing
            view.jumpNow(.landing)
        }
        if view.lastCue != cue {
            view.lastCue = cue
            view.cueNow(cue.kind)
        }
        if view.lastGlance != glance {
            view.lastGlance = glance
            view.glanceNow()
        }
    }

    private func update(_ view: OrbAnimationView) {
        view.configure(config: config, activity: activity, celebration: celebration, size: size, showsBubble: showsBubble,
                       followsPointer: followsPointer, interactive: interactive, live: live)
    }
}

// MARK: - Core Animation view

/// Each frame computes an `OrbPose` and moves the layers; nothing is laid out or redrawn. To stay cheap:
/// - the frame rate follows how fast the pose changes on screen (10 fps while just breathing, up to
///   30/60 fps for blinks, saccades, hops and hover);
/// - frames that would move nothing by a visible amount are skipped;
/// - frames stop while the window is occluded or minimized, the view is hidden or it is scrolled out of sight;
/// - bitmaps are decoded in the background: until they arrive the orb keeps showing what it showed;
/// - a paused orb (`live` false) first eases into the resting pose, then stops; it eases back out when resumed,
///   so pausing and resuming never jump.
final class OrbAnimationView: NSView {
    private(set) var config = OrbConfig()
    private(set) var activity: OrbActivity = .idle
    private var celebration = OrbCelebration.big
    private var size: CGFloat = 28
    /// The status bubble shows: the box the Orb sits in is big enough (`OrbGeometry.bubbleBox`), whatever its look shrank it to.
    private var showsBubble = true
    private var followsPointer = true
    private var interactive = false
    private var live = true
    var lastPoke = 0
    var lastAck = 0
    var lastLanding = 0
    var lastGlance = 0
    var lastCue = OrbCueSignal()

    /// A composited image layer and what `apply` needs to place it (computed once, not per frame).
    private struct Placed {
        let layer: OrbLayer
        let view: CALayer
        let isLoose: Bool
    }

    // Layers (bottom-left origin, like AppKit)
    private let stage = CALayer()
    private let ground = CAGradientLayer()
    private let orb = CALayer()
    private let bubble = CATextLayer()
    private var placed: [Placed] = []
    private var shownBubble: String?
    /// Backing scale the layers were built for (a window moving to another display rebuilds them).
    private var builtScale: CGFloat = 0
    /// Talking mouth: the regular mouth's bitmap (restored when talking stops), the viseme bitmaps (looked up
    /// on first use; prewarmed in the background) and the shape on screen.
    private var mouthImage: CGImage?
    private var visemeImages: [OrbViseme: CGImage] = [:]
    private var shownViseme: OrbViseme?

    /// The bitmap pixel size the layers were built for (viseme bitmaps must match it).
    private var builtPixels: CGFloat = 0
    /// A size or scale change is waiting for its bitmaps (see `rebuild`).
    private var needsResize = false
    /// Counts bitmap requests: only the latest one rebuilds when it arrives.
    private var imageRequest = 0
    private var visemesLoading = false

    // Motion state
    private var driver: OrbDriver?
    /// Whether the shared clock should step this orb (visible, in view, and not yet settled at rest).
    private(set) var isRunning = false
    private var clock = OrbFrameClock()
    /// Frames drawn so far (read by the bench, `OrbBench`).
    private(set) var steps = 0
    /// Frames that moved the layers (the others were skipped as too small to see), read by the bench.
    private(set) var draws = 0
    private weak var clipView: NSClipView?
    /// For tests: the timer that waits for the orb to come back into view, and the layers on screen.
    var isWatchingForReturn: Bool { OrbReturnWatch.shared.contains(self) }
    var placedLayerCount: Int { placed.count }
    /// For tests: the status bubble is on screen.
    var isBubbleShown: Bool { !bubble.isHidden }
    /// For tests: a selection glance is playing.
    var isGlancing: Bool { glanceStart != nil }
    /// For tests: a cue's blink is playing, the jump and the flourish that play, and the activity and joy on screen (not
    /// the ones asked for, which can be waiting out the pause between two tools).
    var isCueBlinking: Bool { cueBlinkStart != nil }
    var currentJumpForTesting: OrbJump? { jump?.kind }
    var currentFlourishForTesting: OrbFlourish? { flourishes.current }
    var shownForTesting: (activity: OrbActivity, celebration: OrbCelebration) { (shown, crossover.shownStyle) }
    /// For tests: the rhythm the blinks and saccades run at.
    var rhythmForTesting: [Double] {
        [blinker.gap.lowerBound, blinker.gap.upperBound, blinker.skew, blinker.doubleChance, saccades.reach, saccades.hold]
    }
    /// For tests: how fast the jelly wobble spring is going (kicks pile up here while no frames run).
    var wobbleVelocityForTesting: Double { wobble.velocity }
    /// For tests: the placed layers, back to front, with what they show.
    var placedLayersForTesting: [(layer: OrbLayer, view: CALayer)] { placed.map { ($0.layer, $0.view) } }
    private var rng = SystemRandomNumberGenerator()
    private let phase = Double.random(in: 0..<10)
    private var lastTime: Double?
    private var head = SpringPoint()     // turns the whole face, unhurried
    private var eyes = SpringPoint()     // quick saccades, leading the head
    private var loose = SpringPoint()    // hair and hats trailing the head and body
    private var swing = Spring()         // hair and hats swinging behind the body's tilt
    /// The swing the loose layers were last rotated to (infinity: not yet, e.g. new layers).
    private var appliedSwing = Double.infinity
    /// Layers were just (re)built: everything is placed once, even what never moves (the body).
    private var freshLayers = true
    private var hover = Spring()
    private var wobble = Spring()        // jelly squash after landings and expression changes
    private var bubbleIn = Spring()
    private var lean = Spring()          // head tilt toward (or away from) a close pointer
    private var jaw = Spring()           // mouth opening while speaking
    /// 0 = live motion, 1 = resting pose (what a static orb shows). Starts at rest, so a new orb eases into motion.
    private var settle = Spring(value: 1)
    private lazy var blinker = Blinker(firstAt: now + .random(in: 0.5...3))
    private lazy var saccades = Saccades(firstAt: now + .random(in: 0.3...1.5))
    private lazy var flourishes = Flourishes(firstAt: now + .random(in: 4...10))
    private lazy var glances = Glances(firstAt: now)
    private lazy var syllables = Syllables(firstAt: now)
    private var traits = OrbTemperament.Traits()
    /// The temperament `traits` and the helpers were set for (nil: not configured yet).
    private var appliedTemperament: OrbTemperament?
    /// Body motion time, advancing at the temperament's pace (continuous when the temperament changes).
    private var bodyClock = 0.0
    /// Activity on screen (the bot's, or `happy` for a moment after a click) and the one it is blending from.
    private var crossover = OrbActivityBlend()
    private var shown: OrbActivity { crossover.shown }
    private var previous: OrbActivity { crossover.previous }
    private var transitionStart: Double { crossover.start }
    private var previousStart: Double { crossover.previousStart }
    private static let transition = OrbActivityBlend.duration
    private var hoverPoint: CGPoint?
    private var hoverGate = HoverGate()
    /// The jump playing and when it started (a landing starts a moment after it was asked for).
    private var jump: (kind: OrbJump, start: Double)?
    private var glanceStart: Double?
    private var lastGlanceStart = -Double.infinity
    /// A blink asked for by a cue (over the pose, like the glance's).
    private var cueBlinkStart: Double?
    private var tickleUntil = 0.0
    /// Waits out the short thinking between two tools.
    private var hold = OrbActivityHold()
    private var trackingArea: NSTrackingArea?

    // Frame pacing
    private var lastPose = OrbPose()
    private var drawnPose: OrbPose?
    private(set) var frameRate: Float = 0
    private var motionRate: Float = 0
    private var livelyUntil = 0.0
    private var slowDownAfter = 0.0

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var side: CGFloat { OrbGeometry.imageSide(for: size, scale: backingScale) }
    /// Orbs this large (the empty chat's, the editor's) are short-lived and mostly idle.
    private static let bigSize: CGFloat = 80
    private var isBig: Bool { size >= Self.bigSize }
    private var maxFrameRate: Float { OrbFrameRate.cap(forSize: size, lively: true) }
    private var now: Double { CACurrentMediaTime() }
    private var isResting: Bool { !live && settle.value >= 0.995 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ground.type = .radial
        ground.startPoint = CGPoint(x: 0.5, y: 0.5)
        ground.endPoint = CGPoint(x: 1, y: 1)
        ground.locations = [0, 0.5, 1]
        ground.colors = OrbShadow.stops.map { NSColor.black.withAlphaComponent($0).cgColor } + [NSColor.clear.cgColor]
        bubble.alignmentMode = .center
        bubble.masksToBounds = true
        // Nearly opaque, so it reads as in front of the orb: the bow and the hat brim sit right behind it.
        bubble.backgroundColor = NSColor(Palette.chrome).withAlphaComponent(OrbGeometry.bubbleFill).cgColor
        bubble.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bubble.borderWidth = 0.5
        bubble.isHidden = true
        stage.masksToBounds = false
        orb.masksToBounds = false
        [ground, orb, bubble].forEach(stage.addSublayer)
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    // MARK: Configuration

    func configure(config: OrbConfig, activity: OrbActivity, celebration: OrbCelebration = .big, size: CGFloat,
                   showsBubble: Bool? = nil, followsPointer: Bool, interactive: Bool, live: Bool) {
        let resized = size != self.size, restyled = config != self.config
        let resumed = live && !self.live
        self.config = config
        self.activity = activity
        self.celebration = celebration
        self.size = size
        self.showsBubble = showsBubble ?? (size >= OrbGeometry.bubbleBox)
        self.followsPointer = followsPointer
        self.interactive = interactive
        self.live = live
        // A paused orb gets no mouseExited when its window loses focus; don't come back staring at the old spot.
        if !live { hoverPoint = nil }
        if resized { invalidateIntrinsicContentSize() }
        // The first configuration too: the motion helpers start with their own defaults, which are not all the default
        // temperament's. Only a change of temperament plays the showcase.
        if config.temperament != appliedTemperament {
            applyTemperament(showcase: appliedTemperament != nil && window != nil && live)
            appliedTemperament = config.temperament
        }
        if resized || restyled {
            visemeImages = [:]
            rebuild(resize: resized)
        }
        if resized || restyled || resumed { prewarmExpressions() }
        updateBlinkFactor()
        syncActivity(at: now)
        if resumed { liven(at: now) }
        updateRunning()
    }

    /// The view is leaving SwiftUI: leave the shared display link (it would keep stepping a dead view).
    func stop() {
        isRunning = false
        watchForReturn(false)
        driver?.remove(self)
        driver = nil
        imageRequest += 1
    }

    /// Hands the temperament's rhythm to the motion helpers; `showcase` plays its signature flourish.
    private func applyTemperament(showcase: Bool) {
        traits = config.temperament.traits
        blinker.gap = shown.blinkGap(traits.blinkGap)
        blinker.doubleChance = traits.doubleBlink
        blinker.skew = traits.blinkSkew
        saccades.reach = traits.saccadeReach
        saccades.hold = traits.saccadeHold
        if showcase {
            flourishes.play(config.temperament.showcase, at: now)
            liven(at: now)
        }
    }

    /// A jump of the body: a click, a prompt sent, a landing (see `OrbJump`).
    func jumpNow(_ kind: OrbJump) {
        // A paused orb would replay a stale jump when it resumes.
        guard live else { return }
        jump = (kind, now + kind.delay)
        liven(at: now)
    }

    /// A blink and a quick look toward the chat (`OrbGlance`), over whatever the orb is doing.
    func glanceNow() {
        guard live, window != nil, now - lastGlanceStart >= OrbGlance.minimumGap else { return }
        glanceStart = now
        lastGlanceStart = now
        liven(at: now)
    }

    /// A one-time reaction: a blink (you stopped the reply) or a sigh (a task stopped half way). The orb may be easing into
    /// its rest as it happens (the turn that ended is what lets it rest); one that is already at rest has no one watching.
    func cueNow(_ cue: OrbCue) {
        guard window != nil, !isResting else { return }
        switch cue {
        case .blink: cueBlinkStart = now
        case .sigh: flourishes.play(.sigh, at: now)
        }
        liven(at: now)
    }

    /// Starts a smooth transition when the activity on screen changes: body motion, gaze and glow blend over
    /// `transition` seconds, the expression crossfades behind a blink and the body gives a small wobble. Between
    /// activities with the same face (idle, attentive, listening) only motion and gaze blend: no blink (except one as
    /// the Orb starts watching you type), no wobble and nothing to rebuild, so typing bursts never twitch.
    private func syncActivity(at time: Double) {
        // A click makes a calm Orb smile for a moment; anything busier or more urgent keeps its own face.
        let tickling = time < tickleUntil && Self.smilesWhenTickled.contains(activity)
        var target = tickling ? OrbActivity.happy : activity
        // How big the joy is: the turn's own celebration, or only the smile of a click.
        let style = target == .happy ? (activity == .happy ? celebration : .smile) : OrbCelebration.big
        // A tool ending and another starting a moment later: keep the pose of the first through the gap.
        target = hold.resolve(wanted: target, shown: shown, at: time, applies: window != nil && !isResting)
        guard target != shown || (target == .happy && style != crossover.shownStyle) else { return }
        let sameFace = target.hasSameFace(as: shown, mouth: config.mouth)
        if window == nil {
            // Not on screen yet: start in the right state instead of animating into it.
            crossover.jump(to: target, celebration: style)
            bubbleIn.value = target.bubble == nil ? 0 : 1
        } else {
            let calmer = target.energy <= shown.energy
            crossover.change(to: target, at: time, body: bodyClock + phase, traits: traits, celebration: style)
            // At rest nothing moves, so a kick would pile up and burst out on resume. Nor does it where no frames run
            // (a hidden window, an orb scrolled away): the spring only moves in frames, so a long task would stack
            // dozens of kicks and the orb would squash flat when it comes back.
            if !isResting {
                if !sameFace || target == .attentive { blinker.trigger(at: time) }
                if !sameFace && !calmer && canShowFrames { wobble.velocity += 0.5 }
            }
            if !sameFace { liven(at: time) }
        }
        updateBlinkFactor()
        blinker.gap = shown.blinkGap(traits.blinkGap)
        // A resting orb runs no frames to move its bubble or open its mouth: it gets the new rest pose right here.
        let resting = window != nil && isResting
        if resting {
            bubbleIn.value = shown.bubble == nil || !showsBubble ? 0 : 1
            lastPose = restPose
        }
        if !sameFace {
            rebuild()
        } else if resting {
            apply(lastPose)
        }
    }

    /// Features that change with the expression: a new one replaces the old in the same view.
    private static let swapsInPlace: Set<OrbLayer.Kind> = [.eyes, .mouth, .brows]

    private static func fade(_ duration: CFTimeInterval) -> CATransition {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        return fade
    }

    /// A layer that was not there fades in.
    private static func appear(_ duration: CFTimeInterval) -> CABasicAnimation {
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.duration = duration
        return appear
    }

    /// The activities a click makes smile (the others are busy, or asking, or failing: they stay as they are).
    private static let smilesWhenTickled: Set<OrbActivity> = [.idle, .attentive, .listening, .speaking]

    /// How much of a blink this orb's eyes make: the ones on screen now (the activity's, or the bot's own). Kept from the
    /// last time the eyes could have changed (the activity or the look), not worked out at every frame.
    private var blinkFactor = 1.0

    private func updateBlinkFactor() { blinkFactor = Blinker.factor(eyes: shown.eyes ?? config.eyes) }

    /// Builds the layer tree for the current config, activity and size. Only on screen: bitmaps depend on the
    /// window's backing scale, and `viewDidMoveToWindow` builds everything once the orb gets one.
    ///
    /// Bitmaps that are not decoded yet are decoded in the background and the orb keeps showing what it
    /// showed (nothing, the first time) until they are all there: the main thread never waits for a PNG.
    /// `decoded`: this is the rebuild after that decoding, with the bitmaps it made.
    private func rebuild(resize: Bool = false, decoded: [OrbLayer: CGImage]? = nil) {
        guard window != nil else { return }
        let scale = backingScale, side = side
        let resize = resize || needsResize || scale != builtScale
        let layers = config.layers(eyes: shown.eyes, mouth: shown.mouth(base: config.mouth), brows: shown.brows)
        let waited = decoded != nil
        var images = decoded ?? [:]
        imageRequest += 1
        if !waited {
            let reusable = resize ? [] : Set(placed.map(\.layer))
            let needed = layers.filter { !reusable.contains($0) }
            // Hold the cached bitmaps through the rebuild: memory pressure may evict them between lookup and placement.
            for item in needed { images[item] = OrbImages.cached(item.path, pixels: side * scale, tint: item.tint) }
            if images.count < needed.count {
                needsResize = resize
                let request = imageRequest
                OrbImages.load(needed, pixels: side * scale) { [weak self] images in
                    // A failed decode keeps the previous whole face. Never retry a missing PNG on the main thread.
                    guard let self, request == self.imageRequest, images.allSatisfy({ $0 != nil }) else { return }
                    var decoded: [OrbLayer: CGImage] = [:]
                    for (layer, image) in zip(needed, images) { decoded[layer] = image }
                    self.rebuild(decoded: decoded)
                }
                // A resize with layers on screen (another display, another size): until the new bitmaps are
                // there, the old ones stand in, stretched to the new geometry (never a decode on this thread).
                if resize, !placed.isEmpty { fitPlacedToGeometry() }
                return
            }
        }
        needsResize = false
        builtScale = scale
        builtPixels = side * scale
        // Frames that ran while the new bitmaps were decoding filled this with the old resolution.
        if resize { visemeImages = [:] }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if resize {
            fitGeometry()
            bubble.contentsScale = scale
            shownBubble = nil
        }

        let current = placed.map(\.layer)
        if resize || layers != current {
            let fades = waited || (!current.isEmpty && !resize)
            // A new Orb or a new size fades in as a whole. A changed feature crossfades on its own: the Orb moves
            // meanwhile, and fading all of it would blend it with a still picture of itself.
            let fadesWhole = fades && (current.isEmpty || resize)
            if fadesWhole { orb.add(Self.fade(0.18), forKey: "swap") }
            // Layers that stay (body, cheeks, hair…) are reused; only changed features get new bitmaps.
            var reusable = resize ? [:] : Dictionary(placed.map { ($0.layer, $0) }, uniquingKeysWith: { first, _ in first })
            // The eyes, mouth or brows of another expression take over the view the old ones had.
            let wanted = Set(layers)
            var swappable = Dictionary(reusable.values.filter { !wanted.contains($0.layer) && Self.swapsInPlace.contains($0.layer.kind) }
                .map { ($0.layer.kind, $0) }, uniquingKeysWith: { first, _ in first })
            placed = layers.map { item in
                if let kept = reusable.removeValue(forKey: item) { return kept }
                let image = images[item]
                if item.kind == .mouth {
                    mouthImage = image
                    shownViseme = nil
                }
                if let old = swappable.removeValue(forKey: item.kind) {
                    if fades { old.view.add(Self.fade(0.18), forKey: "swap") }
                    old.view.contents = image
                    return Placed(layer: item, view: old.view, isLoose: item.isLoose)
                }
                let view = CALayer()
                view.contents = image
                view.contentsGravity = .resize
                // Bitmaps match the on-screen size, so plain linear filtering (no mipmaps) is the sharpest.
                view.minificationFilter = .linear
                view.magnificationFilter = .linear
                view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                if item.kind == .eyes { view.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.eyeLine) }
                if item.isLoose { view.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.crownLine) }
                if item.kind == .mouth { view.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.mouthLine) }
                if fades && !fadesWhole { view.add(Self.appear(0.18), forKey: "swap") }
                return Placed(layer: item, view: view, isLoose: item.isLoose)
            }
            orb.sublayers = placed.map(\.view)
            appliedSwing = .infinity   // new loose layers start unrotated
            freshLayers = true
        }

        if let text = shown.bubble, showsBubble, text != shownBubble {
            // A new symbol replacing a visible one pops in instead of just swapping.
            if shownBubble != nil, bubbleIn.value > 0.5 { bubbleIn.value = 0.55 }
            shownBubble = text
            let fontSize = max(8, size * 0.2)
            let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(Palette.ink)])
            let textSize = string.size()
            bubble.string = string
            bubble.bounds = CGRect(x: 0, y: 0, width: textSize.width + fontSize * 0.9, height: textSize.height + fontSize * 0.2)
            bubble.cornerRadius = bubble.bounds.height / 2
        }
        apply(lastPose)
    }

    /// Geometry that only depends on the size: set on a rebuild, never per frame.
    private func fitGeometry() {
        let side = side
        stage.frame = stageFrame
        ground.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ground.position = CGPoint(x: side / 2, y: side / 2 - size * 0.5)
        orb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orb.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.orbBottom)
    }

    /// The layers on screen, resized to the current size while their new bitmaps are being decoded (a little soft
    /// for a moment, in place of a pause on the main thread).
    private func fitPlacedToGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fitGeometry()
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        for item in placed { item.view.bounds = box }
        freshLayers = true      // the body is placed again, at the new center
        appliedSwing = .infinity
        apply(lastPose)
    }

    /// Centered on the view at a whole-pixel offset (see `OrbGeometry.imageSide`).
    private var stageFrame: CGRect {
        let scale = backingScale, side = side
        let origin = { (length: CGFloat) in ((length - side) / 2 * scale).rounded() / scale }
        return CGRect(x: origin(bounds.width), y: origin(bounds.height), width: side, height: side)
    }

    /// Decodes every expression this orb can show in the background, so activity changes never decode on
    /// the main thread. Only for live orbs: a paused sidebar row shows one expression.
    ///
    /// Big orbs (the empty chat's, the editor's) are short-lived and their bitmaps are large (a dozen MB for
    /// every expression), so they only prepare the expressions they are likely to need; whatever else shows up
    /// is decoded when asked for.
    private func prewarmExpressions() {
        guard window != nil, live else { return }
        let activities = isBig ? OrbActivity.allCases.filter { Self.likelyOnBigOrbs.contains($0) } : OrbActivity.allCases
        var layers = Set(activities.flatMap {
            config.layers(eyes: $0.eyes, mouth: $0.mouth(base: config.mouth), brows: $0.brows)
        })
        if !isBig, let visemes = config.visemeLayers() { layers.formUnion(visemes.values) }
        OrbImages.prewarm(Array(layers), pixels: side * backingScale)
    }

    private static let likelyOnBigOrbs: Set<OrbActivity> = [.idle, .thinking, .speaking, .happy, .waiting]

    // MARK: Lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(updateRunning),
                               name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            center.addObserver(self, selector: #selector(joinDriver), name: NSWindow.didChangeScreenNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isRunning = false
        driver?.remove(self)
        driver = nil
        observeScrolling()
        guard window != nil else { return watchForReturn(false) }
        visemeImages = [:]
        rebuild(resize: true)
        prewarmExpressions()
        joinDriver()
        frameRate = 0
        liven(at: now)
        updateRunning()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    /// Steps on the shared display link of the screen the window is on (and follows it to another screen).
    @objc private func joinDriver() {
        let screenDriver = OrbDriver.driver(for: window)
        guard screenDriver !== driver else { return }
        driver?.remove(self)
        driver = screenDriver
        driver?.add(self)
        clock.reset()
    }

    // MARK: Scrolling

    /// Watches the scroll view the orb lives in (the sidebar, the transcript), so an orb scrolled out of sight
    /// stops animating even when it is the selected or a working one.
    private func observeScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== clipView else { return }
        let center = NotificationCenter.default
        if let clipView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: clipView)
        }
        clipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(updateRunning), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(updateRunning), name: NSView.frameDidChangeNotification, object: clip)
    }

    /// Scrolling and most layout changes notify, but not all of them: an orb that is out of sight looks again
    /// twice a second (one timer shared by all of them, on only while some orb waits).
    private func watchForReturn(_ away: Bool) {
        if away { OrbReturnWatch.shared.add(self) } else { OrbReturnWatch.shared.remove(self) }
    }

    /// Called by `OrbReturnWatch`'s shared timer.
    func lookAgain() { updateRunning() }

    /// Not hidden, and in a window someone can see (or one that animates regardless, for measuring).
    private var isVisibleOnScreen: Bool {
        window.map { !isHiddenOrHasHiddenAncestor && (OrbView.animateInactive || $0.occlusionState.contains(.visible)) } ?? false
    }

    /// Whether frames would run for this orb if it moved: on screen and inside the visible part of its scroll view.
    private var canShowFrames: Bool { isVisibleOnScreen && isInView }

    /// False while the orb is outside the part of its scroll view that shows (`visibleRect` does not account
    /// for the clip view, which does not clip layers here).
    private var isInView: Bool {
        guard let clipView else { return true }
        return OrbVisibility.isVisible(orb: convert(bounds, to: clipView), in: clipView.bounds, margin: size)
    }

    /// Moving to a display with another backing scale: bitmaps and text are rebuilt for it.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil, backingScale != builtScale else { return }
        visemeImages = [:]
        rebuild(resize: true)
        prewarmExpressions()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
    }

    /// Frames only while someone can see them (no occluded or minimized window, no hidden view) and there is
    /// motion to show: a paused orb runs until it has settled into its resting pose.
    @objc private func updateRunning() {
        let visible = isVisibleOnScreen
        let inView = isInView
        // Paused while out of sight: the settling only moves in frames, which this orb will not get, so it would never
        // rest and would look again twice a second for good. Nobody sees the jump to rest.
        if !live, !inView, window != nil, settle.value < 0.995 { restNow() }
        let wouldRun = visible && !isResting
        // Only an orb that would run if it were in view needs to look again: hidden, covered or settled ones
        // have nothing to come back to (a change of window or of activity calls this again).
        watchForReturn(wouldRun && !inView)
        let running = wouldRun && inView
        if running != isRunning {
            isRunning = running
            if running { clock.reset() } else { wobble = Spring() }   // nobody sees it: a half-done wobble does not come back
            driver?.refresh()
        }
        if !running { lastTime = nil }
    }

    /// Skips the settling: the orb is in its resting pose right away (for one that nobody is looking at).
    private func restNow() {
        settle = Spring(value: 1)
        // As in step()'s rest: no deadline would be looked at again, so the real activity shows.
        tickleUntil = 0
        hold = OrbActivityHold()
        syncActivity(at: now)
        wobble = Spring()
        jump = nil
        glanceStart = nil
        cueBlinkStart = nil
        bubbleIn.value = shown.bubble == nil || !showsBubble ? 0 : 1
        lastPose = restPose
        apply(lastPose)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = stageFrame
        CATransaction.commit()
    }

    // MARK: Frames

    /// Called by the driver on every tick of the shared clock: a frame only when this orb's own rate asks for one.
    func stepIfDue(at time: Double) {
        guard clock.isDue(at: time, rate: OrbLinkRate.stepRate(frameRate, onLink: driver?.rate ?? frameRate)) else { return }
        step(at: time)
        steps += 1
        // Layout can move the orb without the scroll view noticing.
        if steps % 30 == 0 { updateRunning() }
    }

    private func step(at time: Double) {
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        bodyClock += dt * traits.pace
        syncActivity(at: time)
        settle.step(toward: live ? 0 : 1, dt: dt, response: 0.45)
        let resting = isResting
        let rest = restPose
        var pose = resting ? rest : OrbPose.mix(self.pose(at: time, dt: dt), rest, min(1, max(0, settle.value)))
        // Over the settling, so an orb selected while resting glances at full strength as it wakes up.
        if let start = glanceStart {
            if resting || time - start >= OrbGlance.total {
                glanceStart = nil
            } else {
                OrbGlance.apply(to: &pose, elapsed: time - start, blinkFactor: blinkFactor)
            }
        }
        if let start = cueBlinkStart {
            if resting || time - start >= Blinker.duration { cueBlinkStart = nil } else {
                pose.blink = max(pose.blink, Blinker.closure(time - start) * blinkFactor)
            }
        }
        var moved = pose
        moved.blink = lastPose.blink    // blinks are paced as short bursts, not as motion
        moved.viseme = lastPose.viseme  // so are mouth shapes and their jaw tween (speaking keeps a floor rate)
        moved.talk = lastPose.talk
        let speed = dt > 0 ? moved.pixelDistance(to: lastPose, size: size, scale: backingScale) / dt : 0
        lastPose = pose
        if resting || drawnPose.map({ pose.pixelDistance(to: $0, size: size, scale: backingScale) >= 0.25 }) ?? true {
            apply(pose)
        }
        if resting {
            settle = Spring(value: 1)
            // Frames stop here, and nothing would look at a deadline again: a click's smile or a tool's held pose that
            // outlived the settling would stay on the face. At rest the real activity shows.
            tickleUntil = 0
            hold = OrbActivityHold()
            syncActivity(at: time)
            updateRunning()
        } else {
            pace(speed: speed, at: time)
        }
    }

    /// The rate the motion needs: raised as soon as it speeds up, lowered only after it stayed slow for a bit.
    /// Blinks and events get the full rate only while they last.
    private func pace(speed: Double, at time: Double) {
        let lively = time < livelyUntil || hoverPoint != nil || jump != nil || glanceStart != nil || cueBlinkStart != nil
            || flourishes.current != nil || time - transitionStart < Self.transition
        let cap = OrbFrameRate.cap(forSize: size, lively: lively)
        let wanted = OrbFrameRate.rate(forSpeed: speed, cap: cap)
        if wanted >= motionRate {
            motionRate = wanted
            slowDownAfter = time + 0.3
        } else if time >= slowDownAfter {
            motionRate = wanted
        }
        let blending = time - transitionStart < Self.transition
        var floor = max(shown.minFrameRate(elapsed: time - transitionStart, size: size, celebration: crossover.shownStyle),
                        blending ? previous.minFrameRate(elapsed: time - previousStart, size: size,
                                                         celebration: crossover.previousStyle) : 0)
        // Blinks need 30 fps to show their shape; eyes that are closed already have none.
        let blinks = blinkFactor > 0 && (blinker.isBlinking || blinker.nextBlink - time < 0.1)
        if blinks || glanceStart != nil || cueBlinkStart != nil { floor = max(floor, 30) }
        if let flourish = flourishes.current { floor = max(floor, flourish.minFrameRate) }
        if time < livelyUntil { floor = maxFrameRate }
        setFrameRate(min(cap, max(floor, motionRate)))
    }

    /// Full frame rate right away, for events whose motion starts abruptly (click, hover, new activity).
    private func liven(at time: Double) {
        livelyUntil = time + 0.4
        setFrameRate(maxFrameRate)
    }

    private func setFrameRate(_ rate: Float) {
        guard rate != frameRate else { return }
        frameRate = rate
        clock.rateChanged(to: rate)
        driver?.refresh()
    }

    /// What a paused orb settles into: the static orb's pose (no bubble unless the activity has one; a talking
    /// mouth stays open, as the static orb draws it).
    private var restPose: OrbPose {
        var pose = OrbPose.rest
        if shown.bubble == nil || !showsBubble {
            pose.bubbleOpacity = 0
            pose.bubbleScale = 0.4
        }
        if shown == .speaking, config.mouth != "nenhuma", shown.mouth(base: config.mouth) == nil { pose.viseme = .open }
        return pose
    }

    // MARK: Pose

    private func pose(at time: Double, dt: Double) -> OrbPose {
        let t = time + phase
        let body = bodyClock + phase
        let blend = crossover.progress(at: time)
        let springs = traits.springResponse
        var pose = OrbPose()

        let motion = crossover.motion(at: time, body: body, traits: traits, blend: blend)
        pose.lift = motion.lift
        pose.squash = motion.squash
        pose.tilt = motion.tilt
        pose.shake = motion.shake
        pose.glow = motion.glow

        // The jump (a click's, a prompt's nod, a landing's squash): the landing feeds the wobble spring.
        if let (kind, start) = jump {
            let e = time - start
            if e >= kind.duration {
                jump = nil
                wobble.velocity += kind.kick
            } else {
                let offset = kind.offset(at: e, jump: traits.jump)
                pose.lift += offset.lift
                pose.squash += offset.squash
            }
        }
        wobble.step(toward: 0, dt: dt, response: 0.32, damping: 0.3)
        pose.squash += wobble.value

        // Flourishes: the temperament's spontaneous moves (only while idle and left alone) and its showcase.
        _ = flourishes.update(at: time, kinds: traits.flourishes, gap: traits.flourishGap,
                              allowed: shown == .idle && hoverPoint == nil && jump == nil, using: &rng)
        let flourish = flourishes.current.map { $0.offset(at: flourishes.elapsed(at: time)) } ?? OrbFlourish.Offset()
        pose.lift += flourish.lift * traits.jump
        pose.squash += flourish.squash
        pose.tilt += flourish.tilt
        // A click during a hop or Feliz's hops would add up past the stage's headroom.
        OrbStageRoom.limit(&pose)

        // Gaze: the activity's pattern plus idle saccades, blended across activity changes, then the pointer
        // and any flourish. Wide glances sometimes come with a blink, as people's do.
        let from = previous.gaze(at: t), to = shown.gaze(at: t)
        let wander = OrbMath.mix(previous.wander, shown.wander, blend)
        if saccades.update(at: time, using: &rng), saccades.isGlance, wander > 0.5,
           Double.random(in: 0..<1, using: &rng) < 0.35 {
            blinker.trigger(at: time)
        }
        let drift = Saccades.drift(at: t)
        var target = OrbMath.mix(from.look, to.look, blend)
        target.x += (saccades.fixation.x + drift.x) * wander
        target.y += (saccades.fixation.y + drift.y) * wander
        let pointer = pointerGaze(target, weight: OrbMath.mix(from.pointerWeight, to.pointerWeight, blend), at: time)
        target = OrbMath.mix(pointer.look, flourish.look, flourish.lookWeight)
        eyes.step(toward: target, dt: dt, response: 0.07 * springs)
        head.step(toward: target, dt: dt, response: OrbSprings.head.response * springs, damping: OrbSprings.head.damping)
        pose.look = head.value
        pose.eyeLead = CGPoint(x: (eyes.value.x - head.value.x) * 0.035, y: (eyes.value.y - head.value.y) * 0.035)
        lean.step(toward: pointer.lean, dt: dt, response: 0.5 * springs, damping: 0.8)
        pose.tilt += 7 * lean.value

        // Hair and hats trail the head turn and the body's bounce, with a little overshoot.
        pose.hairLag = OrbSprings.hairLag(&loose, anchor: OrbSprings.hairAnchor(look: pose.look, lift: pose.lift), dt: dt)
        // ...and swing behind the body's tilt, overshooting a little as it settles.
        pose.hairSwing = OrbSprings.hairSwing(&swing, tilt: pose.tilt, dt: dt)

        hover.step(toward: hoverPoint == nil ? 0 : 1, dt: dt, response: 0.35 * springs, damping: 0.6)
        pose.hover = hover.value * (1 + 0.75 * traits.lean)

        pose.blink = max(blinker.amount(at: time, using: &rng) * blinkFactor, flourish.squint)
        speak(&pose, at: time, dt: dt)

        bubbleIn.step(toward: shown.bubble != nil && showsBubble ? 1 : 0, dt: dt, response: 0.35, damping: 0.6)
        let appear = max(0, bubbleIn.value)
        pose.bubbleScale = 0.4 + 0.6 * appear
        pose.bubbleOpacity = min(1, appear) * (0.8 + 0.2 * sin(t * 2.4))
        pose.bubbleBob = sin(t * 3) * 0.03 * min(1, appear)
        return pose
    }

    /// Talking: syllable-paced mouth shapes with a springy jaw. When talking stops the mouth closes, then the
    /// regular mouth comes back. Shapes only replace the bot's own mouth (not an activity's expression).
    private func speak(_ pose: inout OrbPose, at time: Double, dt: Double) {
        let speaking = shown == .speaking
        if speaking {
            _ = syllables.update(at: time, rate: traits.syllableRate, using: &rng)
        } else if syllables.shape != .rest {
            syllables.rest(at: time)
        }
        jaw.step(toward: speaking ? syllables.shape.opening : 0, dt: dt, response: 0.09, damping: 0.7)
        pose.talk = jaw.value
        let ownMouth = config.mouth != "nenhuma" && shown.mouth(base: config.mouth) == nil
        if ownMouth && (speaking || abs(jaw.value) > 0.03) { pose.viseme = syllables.shape }
    }

    /// Mixes the pointer into the gaze: fully while hovering, otherwise within a radius around the orb (wider
    /// and stronger for curious temperaments). Shy orbs look away from a close pointer, peeking back now and
    /// then. Also returns how far the head leans toward (or away from) the pointer.
    private func pointerGaze(_ target: CGPoint, weight: Double, at time: Double) -> (look: CGPoint, lean: Double) {
        var aim: CGPoint, pull: Double, closeness: Double
        if let hoverPoint {
            aim = CGPoint(x: (hoverPoint.x / bounds.width - 0.5) * 2.4, y: (hoverPoint.y / bounds.height - 0.5) * 2.4)
            pull = max(weight, 0.6)
            closeness = 1
        } else {
            guard followsPointer, weight > 0, let window, NSApp.isActive else { return (target, 0) }
            let pointer = window.mouseLocationOutsideOfEventStream
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let offset = hypot(pointer.x - center.x, pointer.y - center.y)
            let radius = max(320, size * 5) * traits.pointerReach
            let distance = offset / radius
            guard distance < 1.6 else { return (target, 0) }
            let scale = min(1, distance) / max(distance, 0.001) / radius
            aim = CGPoint(x: (pointer.x - center.x) * scale, y: (pointer.y - center.y) * scale)
            pull = min(1, weight * traits.pointerInterest) * (1 - max(0, distance - 1) / 0.6)
            closeness = 1 - OrbMath.smoothstep((offset - size * 0.5) / max(140, size * 2))
        }
        let lean = traits.lean * max(-1, min(1, aim.x)) * closeness * pull
        if traits.avertsGaze {
            // A pointer arriving is met by looking away first; the peeks come later.
            if closeness < 0.05 { glances = Glances(firstAt: time + 1.2) } else { _ = glances.update(at: time, using: &rng) }
            aim = OrbTemperament.shyGaze(pointer: aim, closeness: closeness, peeking: glances.isPeeking)
        }
        return (OrbMath.mix(target, aim, pull), lean)
    }

    /// Moves layers only: positions, transforms and opacities (y grows upward here).
    private func apply(_ pose: OrbPose) {
        drawnPose = pose
        draws += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let side = side
        let lift = pose.lift * size
        let mid = side / 2

        let shadow = OrbShadow.ground(for: pose)
        ground.transform = CATransform3DMakeScale(shadow.width, shadow.height, 1)
        ground.opacity = Float(shadow.opacity)

        // Body: squash/tilt around the orb's bottom, then lift, shake and hover
        orb.position = CGPoint(x: mid + pose.shake * size, y: side * (1 - OrbGeometry.orbBottom) + lift)
        let turn = 1 - abs(pose.look.x) * 0.03
        let grow = pose.hover * 0.04
        let scale = CATransform3DMakeScale((1 + pose.squash + grow) * turn, 1 - pose.squash + grow, 1)
        orb.transform = CATransform3DConcat(scale, CATransform3DMakeRotation(-pose.tilt * .pi / 180, 0, 0, 1))

        // Mouthless orbs show talking with a rhythmic squint instead.
        let eyeTalk = config.mouth == "nenhuma" ? max(0, pose.talk) * traits.mouthOpening : 0
        // Loose layers are only rotated again when their swing moved their outer edge (about half the image away
        // from the center) by a quarter of a device pixel or more: most frames it doesn't.
        let swingStep = 0.25 / (0.5 * side * backingScale) * 180 / .pi
        let swingTransform: CATransform3D? = abs(pose.hairSwing - appliedSwing) >= swingStep
            ? CATransform3DMakeRotation(-pose.hairSwing * .pi / 180, 0, 0, 1) : nil
        if swingTransform != nil { appliedSwing = pose.hairSwing }
        for item in placed {
            let depth = item.layer.depth, view = item.view
            var dx = pose.look.x * depth, dy = pose.look.y * depth
            if item.isLoose { dx += pose.hairLag.x; dy += pose.hairLag.y }
            switch item.layer.kind {
            case .eyes:
                dx += pose.eyeLead.x
                dy += pose.eyeLead.y + 0.006 * eyeTalk
                view.position = CGPoint(x: mid + dx * size, y: side * (1 - OrbGeometry.eyeLine) + dy * size)
                view.transform = CATransform3DMakeScale(1, max(0.08, 1 - pose.blink - 0.14 * eyeTalk), 1)
            case .mouth:
                view.position = CGPoint(x: mid + dx * size, y: side * (1 - OrbGeometry.mouthLine) + dy * size)
                showViseme(pose.viseme, on: view)
                // The new shape starts from the jaw's current opening and springs into place.
                let stretch = 1 + 0.25 * traits.mouthOpening * (pose.talk - (pose.viseme?.opening ?? 0))
                view.transform = CATransform3DMakeScale(1, min(1.5, max(0.6, stretch)), 1)
            default:
                if item.isLoose {
                    // Hung from the top of the head (their anchor), so they swing like hair, not like a seesaw.
                    view.position = CGPoint(x: mid + dx * size, y: side * (1 - OrbGeometry.crownLine) + dy * size)
                    if let swingTransform { view.transform = swingTransform }
                } else if depth != 0 || freshLayers {
                    // The body (depth 0) never moves inside the orb: placed once, not every frame.
                    view.position = CGPoint(x: mid + dx * size, y: mid + dy * size)
                }
            }
        }
        freshLayers = false

        bubble.isHidden = shownBubble == nil || pose.bubbleOpacity < 0.01
        if !bubble.isHidden {
            bubble.position = CGPoint(x: mid + size * 0.48, y: mid + size * 0.5 + lift + pose.bubbleBob * size)
            bubble.opacity = Float(pose.bubbleOpacity)
            bubble.transform = CATransform3DMakeScale(pose.bubbleScale, pose.bubbleScale, 1)
        }
    }

    /// Swaps the mouth bitmap (no decoding here: viseme bitmaps are prewarmed and then kept, and one that is
    /// missing is decoded in the background while the mouth keeps its shape). Swaps between an opening and a
    /// closed or regular mouth get a very short crossfade (they differ most in brightness).
    private func showViseme(_ viseme: OrbViseme?, on view: CALayer) {
        guard viseme != shownViseme else { return }
        if let viseme, visemeImages[viseme] == nil, let layer = config.visemeLayers()?[viseme] {
            visemeImages[viseme] = OrbImages.cached(layer.path, pixels: builtPixels, tint: nil)
            if visemeImages[viseme] == nil {
                loadVisemes()
                return
            }
        }
        let opened = { (shape: OrbViseme?) in shape.map { $0 != .rest } ?? false }
        if opened(viseme) != opened(shownViseme) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.06
            view.add(fade, forKey: "viseme")
        }
        shownViseme = viseme
        if let viseme {
            view.contents = visemeImages[viseme]
        } else {
            view.contents = mouthImage
        }
    }

    /// Decodes the talking mouth shapes (big orbs do not prewarm them); a later frame picks them up.
    private func loadVisemes() {
        guard !visemesLoading, let layers = config.visemeLayers() else { return }
        visemesLoading = true
        OrbImages.load(Array(layers.values), pixels: builtPixels) { [weak self] _ in
            guard let self else { return }
            visemesLoading = false
            // A resting orb runs no frames: it picks the shapes up here (the open mouth of "speaking").
            if isResting { apply(lastPose) }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(event) }
    override func mouseMoved(with event: NSEvent) { setHover(event) }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        hoverGate.reset()
        liven(at: now)
    }

    /// The gaze follows every move, but the frame rate only goes up when the pointer really went somewhere (a few points,
    /// at most ten times a second): a hand resting on the mouse is not motion to draw.
    private func setHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        if hoverGate.shouldSpeedUp(at: point, time: now) { liven(at: now) }
    }

    /// Non-interactive orbs let clicks through (e.g. to select a sidebar row).
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        jumpNow(.play)
        if Self.smilesWhenTickled.contains(activity) { tickleUntil = now + OrbCelebration.smile.seconds }
        syncActivity(at: now)
    }
}
