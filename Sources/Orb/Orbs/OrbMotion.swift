import Foundation
import CoreGraphics

// Small, pure building blocks for the live Orb (unit-tested in OrbTests).

/// Per-frame pose of an Orb. Lengths are fractions of the orb size; `look` is -1...1 (x right, y up).
struct OrbPose: Equatable {
    /// Head turn: drives the parallax of every face layer.
    var look = CGPoint.zero
    /// Extra eye offset while the eyes lead the head during a saccade.
    var eyeLead = CGPoint.zero
    /// Offset of loose layers (hair, hats) trailing the head and body.
    var hairLag = CGPoint.zero
    /// Extra rotation (degrees) of loose layers swinging behind the body's tilt.
    var hairSwing = 0.0
    var lift = 0.0
    var squash = 0.0
    var tilt = 0.0
    var shake = 0.0
    var blink = 0.0
    var glow = 1.0
    var hover = 0.0
    var bubbleBob = 0.0
    var bubbleOpacity = 0.8
    var bubbleScale = 1.0
    /// Speaking: jaw opening (0 closed ... ~1 open) and the mouth shape shown (nil = the regular mouth).
    var talk = 0.0
    var viseme: OrbViseme?

    static let rest = OrbPose()

    /// Largest on-screen change between two poses, in device pixels (opacity changes count as a few pixels).
    /// Frames whose change is below a fraction of a pixel can be skipped.
    func pixelDistance(to other: OrbPose, size: Double, scale: Double) -> Double {
        let length = max(abs(lift - other.lift), abs(shake - other.shake), abs(bubbleBob - other.bubbleBob),
                         hypot(eyeLead.x - other.eyeLead.x, eyeLead.y - other.eyeLead.y),
                         hypot(hairLag.x - other.hairLag.x, hairLag.y - other.hairLag.y),
                         abs(hairSwing - other.hairSwing) * .pi / 360,
                         hypot(look.x - other.look.x, look.y - other.look.y) * OrbLayer.maxDepth,
                         abs(squash - other.squash) / 2, abs(hover - other.hover) * 0.02,
                         abs(tilt - other.tilt) * .pi / 360, abs(blink - other.blink) * 0.12,
                         abs(bubbleScale - other.bubbleScale) * 0.2, abs(talk - other.talk) * 0.02)
        let fade = max(abs(glow - other.glow), abs(bubbleOpacity - other.bubbleOpacity)) * 8
        let swap = viseme == other.viseme ? 0.0 : 8
        return max(length * size * scale, fade, swap)
    }

    /// Blend between two poses (`t` 0 = `a`, 1 = `b`); the mouth shape switches halfway.
    static func mix(_ a: OrbPose, _ b: OrbPose, _ t: Double) -> OrbPose {
        guard t > 0 else { return a }
        guard t < 1 else { return b }
        let m = { (x: Double, y: Double) in OrbMath.mix(x, y, t) }
        var pose = OrbPose()
        pose.look = OrbMath.mix(a.look, b.look, t)
        pose.eyeLead = OrbMath.mix(a.eyeLead, b.eyeLead, t)
        pose.hairLag = OrbMath.mix(a.hairLag, b.hairLag, t)
        pose.hairSwing = m(a.hairSwing, b.hairSwing)
        pose.lift = m(a.lift, b.lift)
        pose.squash = m(a.squash, b.squash)
        pose.tilt = m(a.tilt, b.tilt)
        pose.shake = m(a.shake, b.shake)
        pose.blink = m(a.blink, b.blink)
        pose.glow = m(a.glow, b.glow)
        pose.hover = m(a.hover, b.hover)
        pose.bubbleBob = m(a.bubbleBob, b.bubbleBob)
        pose.bubbleOpacity = m(a.bubbleOpacity, b.bubbleOpacity)
        pose.bubbleScale = m(a.bubbleScale, b.bubbleScale)
        pose.talk = m(a.talk, b.talk)
        pose.viseme = t < 0.5 ? a.viseme : b.viseme
        return pose
    }
}

/// Springs that the live orb and the review sheets (`OrbPosePreview`) share, so the sheets show the real motion.
enum OrbSprings {
    /// The head turning toward where the eyes look.
    static let head = (response: 0.4, damping: 0.9)
    /// Hair and hats trailing the head and body (position), and swinging behind the body's tilt (rotation).
    static let loose = (response: 0.28, damping: 0.4)
    static let swing = (response: 0.3, damping: 0.42)
    /// Largest trailing offset (fraction of the orb) and swing (degrees).
    static let maxLag = 0.02, maxSwing = 3.0
}

/// How far a live Orb reaches above its size box, so a stage can leave room for it (fractions of its size). Lifts
/// from hops, the click jump and the temperament's flourishes can stack (a click during a hop), so the body's lift
/// and stretch are eased under caps (`limit`) instead of adding up past them. With the tallest hat (~0.39 above the
/// box at rest), the caps, the hover growth and the hair's trailing, `headroomFraction` is enough (`OrbDesignTests`).
enum OrbStageRoom {
    static let maxLift = 0.19, liftKnee = 0.15
    static let maxStretch = 0.06, stretchKnee = 0.045
    /// Hover growth at its largest: 4 % × (1 + 0.75 × the strongest lean, curious) with the spring's overshoot.
    static let maxGrow = 0.04 * 1.75 * 1.1
    static let headroomFraction = 0.82, footroomFraction = 0.2

    static func headroom(for size: CGFloat) -> CGFloat { size * headroomFraction }
    static func footroom(for size: CGFloat) -> CGFloat { size * footroomFraction }

    /// Eases the pose's lift and stretch under the caps; below the knees nothing changes (a single jump of a
    /// balanced Orb is untouched).
    static func limit(_ pose: inout OrbPose) {
        pose.lift = softCap(pose.lift, knee: liftKnee, cap: maxLift)
        pose.squash = -softCap(-pose.squash, knee: stretchKnee, cap: maxStretch)
    }

    /// `value` up to `knee`, then eased toward `cap` without ever reaching it (smooth and increasing).
    static func softCap(_ value: Double, knee: Double, cap: Double) -> Double {
        guard value > knee else { return value }
        return knee + (cap - knee) * tanh((value - knee) / (cap - knee))
    }
}

/// Contact shadow under the orb: narrower, flatter and fainter the higher the orb is, wider while it squashes
/// or grows under the pointer. Scales are relative to the orb size; at rest it is 1.05 × 0.2 at full opacity.
enum OrbShadow {
    static func ground(for pose: OrbPose) -> (width: Double, height: Double, opacity: Double) {
        let air = max(0, pose.lift)
        let width = 1.05 * max(0.2, 1 - pose.lift * 2) * (1 + 0.8 * pose.squash + 0.04 * pose.hover)
        let height = 0.2 * max(0.6, 1 - air * 1.5)
        let opacity = max(0.35, 1 - air * 3.5) * pose.glow
        return (width, height, opacity)
    }
}

/// Damped spring (SwiftUI-style `response`/`dampingFraction`), integrated with small fixed substeps so it
/// stays stable at any frame rate. damping 1 = critically damped (no overshoot), < 1 = a little bounce.
struct Spring: Equatable {
    var value = 0.0
    var velocity = 0.0

    mutating func step(toward target: Double, dt: Double, response: Double, damping: Double = 1) {
        guard dt > 0 else { return }
        let omega = 2 * .pi / response
        let steps = Int((dt * 240).rounded(.up))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * h
            value += velocity * h
        }
    }
}

/// A 2D point that follows its target with a spring on each axis.
struct SpringPoint: Equatable {
    var x = Spring(), y = Spring()

    var value: CGPoint { CGPoint(x: x.value, y: y.value) }

    mutating func step(toward target: CGPoint, dt: Double, response: Double, damping: Double = 1) {
        x.step(toward: target.x, dt: dt, response: response, damping: damping)
        y.step(toward: target.y, dt: dt, response: response, damping: damping)
    }
}

/// Natural blinking: irregular intervals, quick close and slower open, and an occasional double blink.
struct Blinker {
    private(set) var nextBlink: Double
    private var start: Double?
    /// Seconds between blinks (short gaps are more likely) and the chance of a double blink.
    var gap: ClosedRange<Double> = 2...7
    var doubleChance = 0.12
    static let close = 0.06, hold = 0.03, open = 0.14
    static var duration: Double { close + hold + open }

    init(firstAt time: Double) { nextBlink = time }

    var isBlinking: Bool { start != nil }

    /// Eyelid closure 0...1 at `time`, scheduling the next blink as needed.
    mutating func amount<R: RandomNumberGenerator>(at time: Double, using rng: inout R) -> Double {
        if start == nil, time >= nextBlink {
            start = time
            let double = Double.random(in: 0..<1, using: &rng) < doubleChance
            let pause = gap.lowerBound + (gap.upperBound - gap.lowerBound) * pow(Double.random(in: 0..<1, using: &rng), 2)
            nextBlink = time + (double ? Self.duration + 0.06 : pause)
        }
        guard let start else { return 0 }
        let amount = Self.closure(time - start)
        if time - start >= Self.duration { self.start = nil }
        return amount
    }

    /// Blink now (e.g. as the expression changes), unless already blinking.
    mutating func trigger(at time: Double) {
        if start == nil { nextBlink = time }
    }

    /// 0 → 1 (eased in) → hold → 0 (eased out).
    static func closure(_ elapsed: Double) -> Double {
        switch elapsed {
        case ..<0: 0
        case ..<close: pow(elapsed / close, 2)
        case ..<(close + hold): 1
        case ..<duration:
            1 - OrbMath.smoothstep((elapsed - close - hold) / open)
        default: 0
        }
    }
}

/// Idle gaze: holds a fixation point, then jumps (saccade) to a new one. Mostly small moves around the
/// center, sometimes a wider glance, often a return to center.
struct Saccades {
    private(set) var fixation = CGPoint.zero
    /// The current fixation is a wide glance (people often blink with those).
    private(set) var isGlance = false
    private(set) var next: Double
    /// Multipliers on how far the saccades go and how long each fixation is held.
    var reach = 1.0
    var hold = 1.0

    init(firstAt time: Double) { next = time }

    /// Returns true when a new saccade starts at `time`.
    mutating func update<R: RandomNumberGenerator>(at time: Double, using rng: inout R) -> Bool {
        guard time >= next else { return false }
        let kind = Double.random(in: 0..<1, using: &rng)
        let radius = kind < 0.3 ? Double.random(in: 0...0.1, using: &rng)
            : kind < 0.85 ? Double.random(in: 0.15...0.4, using: &rng)
            : Double.random(in: 0.5...0.75, using: &rng)
        let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
        let distance = min(0.9, radius * reach)
        fixation = CGPoint(x: distance * cos(angle), y: distance * sin(angle) * 0.6)
        isGlance = distance > 0.45
        next = time + hold * (isGlance ? Double.random(in: 0.5...1.1, using: &rng) : Double.random(in: 0.8...2.8, using: &rng))
        return true
    }

    /// Tiny continuous drift so a fixation never looks frozen.
    static func drift(at time: Double) -> CGPoint {
        CGPoint(x: 0.02 * sin(time * 0.83), y: 0.015 * sin(time * 1.27 + 1))
    }
}

/// The Orb was selected in the sidebar: a quick look toward the chat (to its right) and a blink as it gets there,
/// laid over whatever it was doing and back again in `duration` seconds. The eyes get there a moment before the
/// head, and the hair a moment after it.
enum OrbGlance {
    static let duration = 0.6
    /// Where it looks (gaze x right, y up): the chat, beside the sidebar.
    static let look = CGPoint(x: 0.75, y: -0.05)
    /// Seconds the eyes lead the head by, and the hair trails it by.
    static let eyeLead = 0.05, hairDelay = 0.07
    /// Until the hair is back too.
    static let total = duration + hairDelay
    /// Seconds to turn and to come back.
    private static let turn = 0.12, back = 0.22
    /// The blink starts as the head arrives, so the turn itself (eyes first) shows.
    static let blinkAt = 0.12

    /// How far the head has turned toward `look`, 0...1, `elapsed` seconds into the glance: a quick turn, a short
    /// hold, an unhurried return, smooth at both ends.
    static func weight(_ elapsed: Double) -> Double {
        guard elapsed > 0, elapsed < duration else { return 0 }
        return OrbMath.smoothstep(elapsed / turn) * (1 - OrbMath.smoothstep((elapsed - (duration - back)) / back))
    }

    /// Lays the glance over `pose`: the look, the eyes leading it, the hair trailing it and the blink.
    static func apply(to pose: inout OrbPose, elapsed: Double) {
        let head = weight(elapsed), eyes = weight(elapsed + eyeLead), hair = weight(elapsed - hairDelay)
        let from = pose.look
        let dx = Double(look.x - from.x), dy = Double(look.y - from.y)
        pose.look = OrbMath.mix(from, look, head)
        let lead: Double = (eyes - head) * 0.035
        pose.eyeLead.x += CGFloat(dx * lead)
        pose.eyeLead.y += CGFloat(dy * lead)
        // The loose layers follow the head at 5 % of its turn (as in the live pose), a moment late.
        let lag: Double = OrbSprings.maxLag
        let trail: Double = (hair - head) * 0.05
        let lagX: Double = Double(pose.hairLag.x) + dx * trail
        let lagY: Double = Double(pose.hairLag.y) + dy * trail
        pose.hairLag.x = CGFloat(max(-lag, min(lag, lagX)))
        pose.hairLag.y = CGFloat(max(-lag, min(lag, lagY)))
        pose.blink = max(pose.blink, Blinker.closure(elapsed - blinkAt))
    }
}

/// Picks the display-link rate from how fast the pose is changing on screen.
enum OrbFrameRate {
    static let steps: [Float] = [10, 15, 20, 30, 60]
    /// Largest step per frame (device pixels) that still reads as smooth motion.
    static let maxStep = 0.8

    /// The fastest rate an orb may ask for. Small orbs never need more than 30. Big ones (the empty chat's,
    /// the editor's) reach 60 only while something lively happens (click, hover, a hop, a change of
    /// activity); idle saccades and blinks are fine at 30.
    static func cap(forSize size: CGFloat, lively: Bool) -> Float {
        size >= 80 && lively ? 60 : 30
    }

    static func rate(forSpeed pixelsPerSecond: Double, cap: Float) -> Float {
        let needed = Float(pixelsPerSecond / maxStep)
        return min(cap, steps.first { $0 >= needed } ?? cap)
    }
}

enum OrbMath {
    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
    }
}
