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
    private var shownLayers: [OrbLayer] = []
    private var shownColor = ""

    // Motion state
    private var displayLink: CADisplayLink?
    private let phase = Double.random(in: 0..<10)
    private var look = CGPoint.zero
    private var hover = 0.0
    private var hoverPoint: CGPoint?
    private var lastTime: Double?
    private var pokeStart: Double?
    private var tickleUntil = 0.0
    private var trackingArea: NSTrackingArea?


    private var side: CGFloat { size * OrbGeometry.imageScale }
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
        bubble.alignmentMode = .center
        bubble.masksToBounds = true
        stage.masksToBounds = false
        orb.masksToBounds = false
        [ground, aura, orb, bubble].forEach(stage.addSublayer)
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    // MARK: Configuration

    func configure(config: OrbConfig, activity: OrbActivity, size: CGFloat, followsPointer: Bool, interactive: Bool) {
        let resized = size != self.size
        self.config = config
        self.activity = activity
        self.size = size
        self.followsPointer = followsPointer
        self.interactive = interactive
        if resized { invalidateIntrinsicContentSize() }
        rebuildIfNeeded(force: resized)
        updateFrameRate()
    }

    func pokeNow() {
        pokeStart = now
        updateFrameRate()
    }

    private var effectiveActivity: OrbActivity { now < tickleUntil ? .happy : activity }

    private func rebuildIfNeeded(force: Bool = false) {
        let activity = effectiveActivity
        let layers = config.layers(eyes: activity.eyes, mouth: activity.mouth(base: config.mouth), brows: activity.brows)
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        stage.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)

        if force || shownColor != config.color {
            shownColor = config.color
            let palette = OrbCatalog.shared.palette(config.color)
            let core = NSColor(palette.core)
            ground.colors = [core.withAlphaComponent(0.55).cgColor, core.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
            ground.locations = [0, 0.5, 1]
            aura.colors = [core.withAlphaComponent(0.28).cgColor, core.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
            aura.locations = [0, 0.4, 1]
        }

        if force || layers != shownLayers {
            if !shownLayers.isEmpty && !force {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                orb.add(fade, forKey: "swap")
            }
            shownLayers = layers
            imageLayers.forEach { $0.view.removeFromSuperlayer() }
            imageLayers = layers.map { item in
                let imageLayer = CALayer()
                imageLayer.contents = OrbImages.cgImage(item.path, pixels: side * scale, tint: item.tint)
                imageLayer.contentsGravity = .resize
                imageLayer.minificationFilter = .trilinear
                imageLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                if item.kind == .eyes { imageLayer.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.eyeLine) }
                orb.addSublayer(imageLayer)
                return (item, imageLayer)
            }
        }

        if let text = activity.bubble, size >= 26 {
            let fontSize = max(8, size * 0.2)
            let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
            bubble.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(Palette.ink)])
            let textSize = (bubble.string as? NSAttributedString)?.size() ?? .zero
            bubble.bounds = CGRect(x: 0, y: 0, width: textSize.width + fontSize * 0.9, height: textSize.height + fontSize * 0.2)
            bubble.cornerRadius = bubble.bounds.height / 2
            bubble.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            bubble.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            bubble.borderWidth = 0.5
            bubble.contentsScale = scale
            bubble.isHidden = false
        } else {
            bubble.isHidden = true
        }
        applyPose(pose(at: now, advance: false))
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        rebuildIfNeeded(force: true)
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateFrameRate()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.commit()
    }

    /// Fast only while something is happening (hover, poke, busy); idle breathing is slow and cheap.
    private func updateFrameRate() {
        let lively = activity.isBusy || hoverPoint != nil || pokeStart.map { now - $0 < 1 } == true || now < tickleUntil
        let rate: Float = size >= 80 ? (lively ? 60 : 30) : (lively ? 30 : 15)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let wasTickled = now < tickleUntil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPose(pose(at: now, advance: true))
        CATransaction.commit()
        if wasTickled != (now < tickleUntil) { rebuildIfNeeded() }
        if let start = pokeStart, now - start > 1 {
            pokeStart = nil
            updateFrameRate()
        }
    }

    // MARK: Pose

    private func pose(at time: Double, advance: Bool) -> OrbPose {
        let t = time + phase
        let dt = advance ? min(0.1, lastTime.map { t - $0 } ?? 0) : 0
        if advance { lastTime = t }
        let activity = effectiveActivity

        var pose = OrbPose()
        pose.time = t
        let motion = activity.motion(at: t)
        pose.lift = motion.lift
        pose.squash = motion.squash
        pose.tilt = motion.tilt
        pose.shake = motion.shake
        pose.glow = activity.glow(at: t)

        // Gaze: activity pattern, overridden by the pointer when it is near
        var (target, pointerWeight) = activity.gaze(at: t)
        if let hoverPoint {
            let local = CGPoint(x: (hoverPoint.x / bounds.width - 0.5) * 2.4, y: (hoverPoint.y / bounds.height - 0.5) * 2.4)
            target = mix(target, local, max(pointerWeight, 0.6))
        } else if followsPointer, let window, window.isVisible, NSApp.isActive {
            let pointer = window.mouseLocationOutsideOfEventStream
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let radius = max(320, size * 5)
            let dx = (pointer.x - center.x) / radius, dy = (pointer.y - center.y) / radius
            let distance = hypot(dx, dy)
            if distance < 1.6 {
                let scale = min(1, distance) / max(distance, 0.001)
                target = mix(target, CGPoint(x: dx * scale, y: dy * scale), pointerWeight * (1 - max(0, distance - 1) / 0.6))
            }
        }
        look = mix(look, target, 1 - exp(-dt * 10))
        pose.look = look

        hover += ((hoverPoint == nil ? 0 : 1) - hover) * (1 - exp(-dt * 12))
        pose.hover = hover

        // Blink every few seconds
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        if cycle < 0.15 { pose.blink = sin(.pi * cycle / 0.15) }

        // Poke: squash, jump, land
        if let start = pokeStart {
            let e = time - start
            if e < 0.1 {
                pose.squash += 0.12 * sin(.pi * e / 0.1)
            } else if e < 0.55 {
                let p = (e - 0.1) / 0.45
                pose.lift += 0.16 * sin(.pi * p)
                pose.squash -= 0.06 * sin(.pi * p)
            } else if e < 0.75 {
                pose.squash += 0.08 * sin(.pi * (e - 0.55) / 0.2)
            }
        }
        return pose
    }

    /// Moves layers only (y grows upward here, so look.y and lift are added).
    private func applyPose(_ pose: OrbPose) {
        let lift = pose.lift * size
        let mid = side / 2

        ground.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ground.position = CGPoint(x: mid, y: mid - size * 0.5)
        ground.transform = CATransform3DMakeScale(1.05 * max(0.2, 1 - pose.lift * 2), 0.2, 1)
        ground.opacity = Float(pose.glow)

        aura.bounds = CGRect(x: 0, y: 0, width: size * 1.5, height: size * 1.5)
        aura.position = CGPoint(x: mid, y: mid + lift)
        aura.opacity = Float(pose.glow)

        // Body: squash/tilt around the orb's bottom, then lift, shake and hover
        orb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orb.anchorPoint = CGPoint(x: 0.5, y: 1 - OrbGeometry.orbBottom)
        orb.position = CGPoint(x: mid + pose.shake * size, y: side * (1 - OrbGeometry.orbBottom) + lift)
        let turn = 1 - abs(pose.look.x) * 0.03
        let scale = CATransform3DMakeScale((1 + pose.squash + pose.hover * 0.04) * turn, 1 - pose.squash + pose.hover * 0.04, 1)
        orb.transform = CATransform3DConcat(scale, CATransform3DMakeRotation(-pose.tilt * .pi / 180, 0, 0, 1))

        for (layer, imageLayer) in imageLayers {
            let dx = pose.look.x * layer.depth * size, dy = pose.look.y * layer.depth * size
            if layer.kind == .eyes {
                imageLayer.position = CGPoint(x: mid + dx, y: side * (1 - OrbGeometry.eyeLine) + dy)
                imageLayer.transform = CATransform3DMakeScale(1, max(0.08, 1 - pose.blink), 1)
            } else {
                imageLayer.position = CGPoint(x: mid + dx, y: mid + dy)
            }
        }

        if !bubble.isHidden {
            let bob = sin(pose.time * 3) * size * 0.03
            bubble.position = CGPoint(x: mid + size * 0.48, y: mid + size * 0.5 + lift + bob)
            bubble.opacity = Float(0.6 + 0.4 * (0.5 + 0.5 * sin(pose.time * 2.4)))
        }
    }

    private func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
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
        updateFrameRate()
    }

    private func setHover(_ event: NSEvent) {
        let wasHovering = hoverPoint != nil
        hoverPoint = convert(event.locationInWindow, from: nil)
        if !wasHovering { updateFrameRate() }
    }

    /// Non-interactive orbs let clicks through (e.g. to select a sidebar row).
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        pokeNow()
        tickleUntil = now + 1.4
        rebuildIfNeeded()
    }
}
