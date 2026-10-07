import SwiftUI
import AppKit
import QuartzCore

// MARK: - SwiftUI bridge

/// Live Orb. Frames are produced by a display link that only moves Core Animation layers, so an
/// animating orb costs no SwiftUI updates or layout passes (SwiftUI only hears about config changes).
struct AnimatedOrb: NSViewRepresentable {
    let config: OrbConfig
    let activity: OrbActivity
    let size: CGFloat
    let followsPointer: Bool
    let poke: Int
    let interactive: Bool

    func makeNSView(context: Context) -> OrbAnimationView {
        let view = OrbAnimationView()
        view.lastPoke = poke
        update(view)
        return view
    }

    func updateNSView(_ view: OrbAnimationView, context: Context) {
        update(view)
        if view.lastPoke != poke {
            view.lastPoke = poke
            view.pokeNow()
        }
    }

    private func update(_ view: OrbAnimationView) {
        view.configure(config: config, activity: activity, size: size,
                       followsPointer: followsPointer, interactive: interactive)
    }
}

// MARK: - Core Animation view

/// Each frame computes an `OrbPose` and moves the layers; nothing is laid out or redrawn. To stay cheap:
/// - the frame rate follows how fast the pose changes on screen (10 fps while just breathing, up to
///   30/60 fps for blinks, saccades, hops and hover);
/// - frames that would move nothing by a visible amount are skipped;
/// - the display link pauses while the window is occluded or minimized, or the view is hidden.
final class OrbAnimationView: NSView {
    private(set) var config = OrbConfig()
    private(set) var activity: OrbActivity = .idle
    private var size: CGFloat = 28
    private var followsPointer = true
    private var interactive = false
    var lastPoke = 0

    // Layers (bottom-left origin, like AppKit)
    private let stage = CALayer()
    private let ground = CAGradientLayer()
    private let aura = CAGradientLayer()
    private let orb = CALayer()
    private let bubble = CATextLayer()
    private var imageLayers: [(layer: OrbLayer, view: CALayer)] = []
    private var shownColor = ""
    private var shownBubble: String?
    /// Talking mouth: the regular mouth's bitmap (restored when talking stops), the viseme bitmaps (looked up
    /// on first use; prewarmed in the background) and the shape on screen.
    private var mouthImage: CGImage?
    private var visemeImages: [OrbViseme: CGImage] = [:]
    private var shownViseme: OrbViseme?

    // Motion state
    private var displayLink: CADisplayLink?
    private var rng = SystemRandomNumberGenerator()
    private let phase = Double.random(in: 0..<10)
    private var lastTime: Double?
    private var head = SpringPoint()     // turns the whole face, unhurried
    private var eyes = SpringPoint()     // quick saccades, leading the head
    private var loose = SpringPoint()    // hair and hats trailing the head and body
    private var hover = Spring()
    private var wobble = Spring()        // jelly squash after landings and expression changes
    private var bubbleIn = Spring()
    private var lean = Spring()          // head tilt toward (or away from) a close pointer
    private var jaw = Spring()           // mouth opening while speaking
    private lazy var blinker = Blinker(firstAt: now + .random(in: 0.5...3))
    private lazy var saccades = Saccades(firstAt: now + .random(in: 0.3...1.5))
    private lazy var flourishes = Flourishes(firstAt: now + .random(in: 4...10))
    private lazy var glances = Glances(firstAt: now)
    private lazy var syllables = Syllables(firstAt: now)
    private var traits = OrbTemperament.Traits()
    /// Body motion time, advancing at the temperament's pace (continuous when the temperament changes).
    private var bodyClock = 0.0
    /// Activity on screen (the bot's, or `happy` for a moment after a click) and the one it is blending from.
    private var shown: OrbActivity = .idle
    private var previous: OrbActivity = .idle
    private var transitionStart = -Double.infinity
    private static let transition = 0.35
    private var hoverPoint: CGPoint?
    private var pokeStart: Double?
    private var tickleUntil = 0.0
    private var trackingArea: NSTrackingArea?

    // Frame pacing
    private var lastPose = OrbPose()
    private var drawnPose: OrbPose?
    private var frameRate: Float = 0
    private var motionRate: Float = 0
    private var livelyUntil = 0.0
    private var slowDownAfter = 0.0

    private var side: CGFloat { size * OrbGeometry.imageScale }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var maxFrameRate: Float { size >= 80 ? 60 : 30 }
    private var now: Double { CACurrentMediaTime() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for item in [ground, aura] {
            item.type = .radial
            item.startPoint = CGPoint(x: 0.5, y: 0.5)
            item.endPoint = CGPoint(x: 1, y: 1)
        }
        ground.locations = [0, 0.5, 1]
        aura.locations = [0, 0.4, 1]
        bubble.alignmentMode = .center
        bubble.masksToBounds = true
        bubble.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        bubble.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bubble.borderWidth = 0.5
        bubble.isHidden = true
        stage.masksToBounds = false
        orb.masksToBounds = false
        [ground, aura, orb, bubble].forEach(stage.addSublayer)
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    // MARK: Configuration

    func configure(config: OrbConfig, activity: OrbActivity, size: CGFloat, followsPointer: Bool, interactive: Bool) {
        let resized = size != self.size, restyled = config != self.config
        let retempered = config.temperament != self.config.temperament
        self.config = config
        self.activity = activity
        self.size = size
        self.followsPointer = followsPointer
        self.interactive = interactive
        if resized { invalidateIntrinsicContentSize() }
        if retempered { applyTemperament(showcase: window != nil) }
        if resized || restyled {
            visemeImages = [:]
            rebuild(resize: resized)
            prewarmExpressions()
        }
        syncActivity(at: now)
    }

    /// Hands the temperament's rhythm to the motion helpers; `showcase` plays its signature flourish.
    private func applyTemperament(showcase: Bool) {
        traits = config.temperament.traits
        blinker.gap = traits.blinkGap
        blinker.doubleChance = traits.doubleBlink
        saccades.reach = traits.saccadeReach
        saccades.hold = traits.saccadeHold
        if showcase {
            flourishes.play(config.temperament.showcase, at: now)
            liven(at: now)
        }
    }

    func pokeNow() {
        pokeStart = now
        liven(at: now)
    }

    /// Starts a smooth transition when the activity on screen changes: body motion, gaze and glow blend over
    /// `transition` seconds, the expression crossfades behind a blink and the body gives a small wobble.
    private func syncActivity(at time: Double) {
        let target = time < tickleUntil ? OrbActivity.happy : activity
        guard target != shown else { return }
        if window == nil {
            // Not on screen yet: start in the right state instead of animating into it.
            shown = target
            previous = target
            bubbleIn.value = target.bubble == nil ? 0 : 1
        } else {
            previous = shown
            shown = target
            transitionStart = time
            blinker.trigger(at: time)
            wobble.velocity += 0.5
            liven(at: time)
        }
        rebuild()
    }

    private func rebuild(resize: Bool = false) {
        let scale = backingScale
        let layers = config.layers(eyes: shown.eyes, mouth: shown.mouth(base: config.mouth), brows: shown.brows)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if resize {
            // Geometry that only depends on the size: set here, never per frame.
            stage.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            ground.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            ground.position = CGPoint(x: side / 2, y: side / 2 - size * 0.5)
            aura.bounds = CGRect(x: 0, y: 0, width: size * 1.5, height: size * 1.5)
            orb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            orb.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.orbBottom)
            bubble.contentsScale = scale
            shownBubble = nil
        }

        if resize || shownColor != config.color {
            shownColor = config.color
            let core = NSColor(OrbCatalog.shared.palette(config.color).core)
            ground.colors = [core.withAlphaComponent(0.55).cgColor, core.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
            aura.colors = [core.withAlphaComponent(0.28).cgColor, core.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
        }

        let current = imageLayers.map(\.layer)
        if resize || layers != current {
            if !current.isEmpty && !resize {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                orb.add(fade, forKey: "swap")
            }
            // Layers that stay (body, cheeks, hair…) are reused; only changed features get new bitmaps.
            var reusable = resize ? [:] : Dictionary(imageLayers.map { ($0.layer, $0.view) }, uniquingKeysWith: { first, _ in first })
            imageLayers = layers.map { item in
                if let view = reusable.removeValue(forKey: item) { return (item, view) }
                let view = CALayer()
                let image = OrbImages.cgImage(item.path, pixels: side * scale, tint: item.tint)
                view.contents = image
                view.contentsGravity = .resize
                view.minificationFilter = .trilinear
                view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                if item.kind == .eyes { view.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.eyeLine) }
                if item.kind == .mouth {
                    view.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.mouthLine)
                    mouthImage = image
                    shownViseme = nil
                }
                return (item, view)
            }
            orb.sublayers = imageLayers.map(\.view)
        }

        if let text = shown.bubble, size >= 26, text != shownBubble {
            shownBubble = text
            let fontSize = max(8, size * 0.2)
            let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(Palette.ink)])
            bubble.string = string
            bubble.bounds = CGRect(x: 0, y: 0, width: string.size().width + fontSize * 0.9, height: string.size().height + fontSize * 0.2)
            bubble.cornerRadius = bubble.bounds.height / 2
        }
        apply(lastPose)
    }

    /// Decodes every expression this orb can show in the background, so activity changes never decode on
    /// the main thread.
    private func prewarmExpressions() {
        var layers = Set(OrbActivity.allCases.flatMap {
            config.layers(eyes: $0.eyes, mouth: $0.mouth(base: config.mouth), brows: $0.brows)
        })
        if let visemes = config.visemeLayers() { layers.formUnion(visemes.values) }
        OrbImages.prewarm(Array(layers), pixels: side * backingScale)
    }

    // MARK: Lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(visibilityChanged),
                               name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        rebuild(resize: true)
        prewarmExpressions()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        frameRate = 0
        liven(at: now)
        visibilityChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityChanged()
    }

    /// No frames while nobody can see them (occluded or minimized window, hidden view).
    @objc private func visibilityChanged() {
        let visible = window.map { !isHiddenOrHasHiddenAncestor && (OrbView.animateInactive || $0.occlusionState.contains(.visible)) }
        displayLink?.isPaused = visible != true
        if visible != true { lastTime = nil }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.commit()
    }

    // MARK: Frames

    @objc private func tick(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        let dt = min(0.1, max(0, time - (lastTime ?? time)))
        lastTime = time
        bodyClock += dt * traits.pace
        syncActivity(at: time)
        let pose = pose(at: time, dt: dt)
        var moved = pose
        moved.blink = lastPose.blink    // blinks are paced as short bursts, not as motion
        moved.viseme = lastPose.viseme  // so are mouth shapes and their jaw tween (speaking keeps a floor rate)
        moved.talk = lastPose.talk
        let speed = dt > 0 ? moved.pixelDistance(to: lastPose, size: size, scale: backingScale) / dt : 0
        lastPose = pose
        if drawnPose.map({ pose.pixelDistance(to: $0, size: size, scale: backingScale) >= 0.25 }) ?? true {
            apply(pose)
        }
        pace(speed: speed, at: time)
    }

    /// The rate the motion needs: raised as soon as it speeds up, lowered only after it stayed slow for a bit.
    /// Blinks and events get the full rate only while they last.
    private func pace(speed: Double, at time: Double) {
        let wanted = OrbFrameRate.rate(forSpeed: speed, cap: maxFrameRate)
        if wanted >= motionRate {
            motionRate = wanted
            slowDownAfter = time + 0.3
        } else if time >= slowDownAfter {
            motionRate = wanted
        }
        let blending = time - transitionStart < Self.transition
        var floor = max(shown.minFrameRate, blending ? previous.minFrameRate : 0)
        if blinker.isBlinking || blinker.nextBlink - time < 0.1 { floor = max(floor, 30) }
        if let flourish = flourishes.current { floor = max(floor, flourish.minFrameRate) }
        if time < livelyUntil { floor = maxFrameRate }
        setFrameRate(min(maxFrameRate, max(floor, motionRate)))
    }

    /// Full frame rate right away, for events whose motion starts abruptly (click, hover, new activity).
    private func liven(at time: Double) {
        livelyUntil = time + 0.4
        setFrameRate(maxFrameRate)
    }

    private func setFrameRate(_ rate: Float) {
        guard rate != frameRate else { return }
        frameRate = rate
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
    }

    // MARK: Pose

    private func pose(at time: Double, dt: Double) -> OrbPose {
        let t = time + phase
        let body = bodyClock + phase
        let blend = OrbMath.smoothstep((time - transitionStart) / Self.transition)
        let springs = traits.springResponse
        var pose = OrbPose()

        let motion = OrbBodyMotion.mix(previous.motion(at: body, traits: traits), shown.motion(at: body, traits: traits), blend)
        pose.lift = motion.lift
        pose.squash = motion.squash
        pose.tilt = motion.tilt
        pose.shake = motion.shake
        pose.glow = motion.glow

        // Poke: anticipation squash, then a stretched jump; the landing feeds the wobble spring.
        if let start = pokeStart {
            let e = time - start
            if e < 0.1 {
                pose.squash += 0.12 * sin(.pi * e / 0.1)
            } else if e < 0.55 {
                let p = (e - 0.1) / 0.45
                pose.lift += 0.16 * traits.jump * sin(.pi * p)
                pose.squash -= 0.06 * sin(.pi * p)
            } else {
                pokeStart = nil
                wobble.velocity += 1.6
            }
        }
        wobble.step(toward: 0, dt: dt, response: 0.32, damping: 0.3)
        pose.squash += wobble.value

        // Flourishes: the temperament's spontaneous moves (only while idle and left alone) and its showcase.
        _ = flourishes.update(at: time, kinds: traits.flourishes, gap: traits.flourishGap,
                              allowed: shown == .idle && hoverPoint == nil && pokeStart == nil, using: &rng)
        let flourish = flourishes.current.map { $0.offset(at: flourishes.elapsed(at: time)) } ?? OrbFlourish.Offset()
        pose.lift += flourish.lift * traits.jump
        pose.squash += flourish.squash
        pose.tilt += flourish.tilt

        // Gaze: the activity's pattern plus idle saccades, blended across activity changes, then the pointer
        // and any flourish.
        let from = previous.gaze(at: t), to = shown.gaze(at: t)
        _ = saccades.update(at: time, using: &rng)
        let wander = OrbMath.mix(previous.wander, shown.wander, blend)
        let drift = Saccades.drift(at: t)
        var target = OrbMath.mix(from.look, to.look, blend)
        target.x += (saccades.fixation.x + drift.x) * wander
        target.y += (saccades.fixation.y + drift.y) * wander
        let pointer = pointerGaze(target, weight: OrbMath.mix(from.pointerWeight, to.pointerWeight, blend), at: time)
        target = OrbMath.mix(pointer.look, flourish.look, flourish.lookWeight)
        eyes.step(toward: target, dt: dt, response: 0.07 * springs)
        head.step(toward: target, dt: dt, response: 0.4 * springs, damping: 0.9)
        pose.look = head.value
        pose.eyeLead = CGPoint(x: (eyes.value.x - head.value.x) * 0.035, y: (eyes.value.y - head.value.y) * 0.035)
        lean.step(toward: pointer.lean, dt: dt, response: 0.5 * springs, damping: 0.8)
        pose.tilt += 7 * lean.value

        // Hair and hats trail the head turn and the body's bounce, with a little overshoot.
        let anchor = CGPoint(x: pose.look.x * 0.05, y: pose.look.y * 0.05 + pose.lift)
        loose.step(toward: anchor, dt: dt, response: 0.28, damping: 0.4)
        pose.hairLag = CGPoint(x: max(-0.02, min(0.02, loose.value.x - anchor.x)),
                               y: max(-0.02, min(0.02, loose.value.y - anchor.y)))

        hover.step(toward: hoverPoint == nil ? 0 : 1, dt: dt, response: 0.35 * springs, damping: 0.6)
        pose.hover = hover.value * (1 + 0.75 * traits.lean)

        pose.blink = max(blinker.amount(at: time, using: &rng), flourish.squint)
        speak(&pose, at: time, dt: dt)

        bubbleIn.step(toward: shown.bubble != nil && size >= 26 ? 1 : 0, dt: dt, response: 0.35, damping: 0.6)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let lift = pose.lift * size
        let mid = side / 2

        ground.transform = CATransform3DMakeScale(1.05 * max(0.2, 1 - pose.lift * 2), 0.2, 1)
        ground.opacity = Float(pose.glow)
        aura.position = CGPoint(x: mid, y: mid + lift)
        aura.opacity = Float(pose.glow)

        // Body: squash/tilt around the orb's bottom, then lift, shake and hover
        orb.position = CGPoint(x: mid + pose.shake * size, y: side * (1 - OrbGeometry.orbBottom) + lift)
        let turn = 1 - abs(pose.look.x) * 0.03
        let grow = pose.hover * 0.04
        let scale = CATransform3DMakeScale((1 + pose.squash + grow) * turn, 1 - pose.squash + grow, 1)
        orb.transform = CATransform3DConcat(scale, CATransform3DMakeRotation(-pose.tilt * .pi / 180, 0, 0, 1))

        // Mouthless orbs show talking with a rhythmic squint instead.
        let eyeTalk = config.mouth == "nenhuma" ? max(0, pose.talk) * traits.mouthOpening : 0
        for (layer, view) in imageLayers {
            var dx = pose.look.x * layer.depth, dy = pose.look.y * layer.depth
            if layer.isLoose { dx += pose.hairLag.x; dy += pose.hairLag.y }
            switch layer.kind {
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
                view.position = CGPoint(x: mid + dx * size, y: mid + dy * size)
            }
        }

        bubble.isHidden = shownBubble == nil || pose.bubbleOpacity < 0.01
        if !bubble.isHidden {
            bubble.position = CGPoint(x: mid + size * 0.48, y: mid + size * 0.5 + lift + pose.bubbleBob * size)
            bubble.opacity = Float(pose.bubbleOpacity)
            bubble.transform = CATransform3DMakeScale(pose.bubbleScale, pose.bubbleScale, 1)
        }
    }

    /// Swaps the mouth bitmap (no decoding here: viseme bitmaps are prewarmed and then kept). Swaps between
    /// an opening and a closed or regular mouth get a very short crossfade (they differ most in brightness).
    private func showViseme(_ viseme: OrbViseme?, on view: CALayer) {
        guard viseme != shownViseme else { return }
        let opened = { (shape: OrbViseme?) in shape.map { $0 != .rest } ?? false }
        if opened(viseme) != opened(shownViseme) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.06
            view.add(fade, forKey: "viseme")
        }
        shownViseme = viseme
        if let viseme {
            if visemeImages[viseme] == nil, let layer = config.visemeLayers()?[viseme] {
                visemeImages[viseme] = OrbImages.cgImage(layer.path, pixels: side * backingScale, tint: nil)
            }
            view.contents = visemeImages[viseme]
        } else {
            view.contents = mouthImage
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
        liven(at: now)
    }

    private func setHover(_ event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        liven(at: now)
    }

    /// Non-interactive orbs let clicks through (e.g. to select a sidebar row).
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        pokeNow()
        tickleUntil = now + 1.4
        syncActivity(at: now)
    }
}
