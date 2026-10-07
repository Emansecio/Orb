import Foundation
import CoreGraphics

/// A bot's personality. It doesn't change what the Orb does, only how: blink and saccade rhythm, how snappy
/// the gaze is, jump height, how it reacts to the pointer and the odd spontaneous flourish.
enum OrbTemperament: String, Codable, CaseIterable, Identifiable, Sendable {
    case calmo, equilibrado, animado, timido, curioso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calmo: "Calmo"
        case .equilibrado: "Equilibrado"
        case .animado: "Animado"
        case .timido: "Tímido"
        case .curioso: "Curioso"
        }
    }

    var summary: String {
        switch self {
        case .calmo: "Pisca devagar, olha pouco em volta e flutua sem pressa."
        case .equilibrado: "Nem tanto nem tão pouco: o jeito padrão do Orb."
        case .animado: "Rápido e saltitante; de vez em quando pula sozinho."
        case .timido: "Desvia o olhar quando você chega perto, mas espia de volta."
        case .curioso: "Nota o ponteiro de longe, inclina a cabeça e olha em volta."
        }
    }

    var symbol: String {
        switch self {
        case .calmo: "leaf"
        case .equilibrado: "circle.lefthalf.filled"
        case .animado: "bolt"
        case .timido: "eye.slash"
        case .curioso: "binoculars"
        }
    }

    /// Played once when the temperament is picked, so the editor's stage shows it right away.
    var showcase: OrbFlourish {
        switch self {
        case .calmo: .sigh
        case .equilibrado: .hop
        case .animado: .wiggle
        case .timido: .bashful
        case .curioso: .lookAround
        }
    }

    /// Motion parameters. `equilibrado` reproduces the Orb's original behavior (all multipliers 1).
    struct Traits: Equatable, Sendable {
        /// Seconds between blinks (short gaps are more likely) and the chance of a double blink.
        var blinkGap: ClosedRange<Double> = 2...7
        var doubleBlink = 0.12
        /// Multipliers on the time an idle fixation is held and on how far saccades go.
        var saccadeHold = 1.0
        var saccadeReach = 1.0
        /// Multiplier on the response time of the gaze and hover springs (lower = snappier).
        var springResponse = 1.0
        /// Multipliers on jump/hop height, on the idle bob and breathing, and on the speed of body motion.
        var jump = 1.0
        var bob = 1.0
        var pace = 1.0
        /// Multipliers on the distance the pointer is noticed from and on how much it pulls the gaze.
        var pointerReach = 1.0
        var pointerInterest = 1.0
        /// Head tilt and hover growth toward (+) or away from (-) a close pointer.
        var lean = 0.0
        /// Looks away from a close pointer, peeking back now and then.
        var avertsGaze = false
        /// Spontaneous idle flourishes and the time between them.
        var flourishes: [OrbFlourish] = []
        var flourishGap: ClosedRange<Double> = 10...20
        /// Mouth shapes per second while speaking, and how big the mouth moves.
        var syllableRate = 5.2
        var mouthOpening = 1.0
    }

    var traits: Traits {
        switch self {
        case .equilibrado:
            Traits()
        case .calmo:
            Traits(blinkGap: 3.5...9, doubleBlink: 0.05, saccadeHold: 1.8, saccadeReach: 0.6, springResponse: 1.5,
                   jump: 0.7, bob: 0.75, pace: 0.7, pointerReach: 0.85, pointerInterest: 0.7,
                   flourishes: [.sigh], flourishGap: 25...50, syllableRate: 4.2, mouthOpening: 0.75)
        case .animado:
            Traits(blinkGap: 1.4...4.5, doubleBlink: 0.2, saccadeHold: 0.6, saccadeReach: 1.2, springResponse: 0.75,
                   jump: 1.4, bob: 1.25, pace: 1.2, pointerReach: 1.2, pointerInterest: 1.2, lean: 0.4,
                   flourishes: [.hop, .wiggle], flourishGap: 8...20, syllableRate: 6.6, mouthOpening: 1.3)
        case .timido:
            Traits(blinkGap: 1.8...6, doubleBlink: 0.25, saccadeReach: 0.7, springResponse: 1.1,
                   jump: 0.65, bob: 0.8, pace: 0.9, lean: -1, avertsGaze: true,
                   syllableRate: 4.6, mouthOpening: 0.7)
        case .curioso:
            Traits(blinkGap: 2...6.5, doubleBlink: 0.1, saccadeHold: 0.8, saccadeReach: 1.25, springResponse: 0.8,
                   jump: 1.1, pace: 1.1, pointerReach: 1.7, pointerInterest: 1.6, lean: 1,
                   flourishes: [.lookAround], flourishGap: 10...24, syllableRate: 5.6, mouthOpening: 1.05)
        }
    }

    /// Where a shy Orb looks: the closer the pointer (`closeness` 0...1), the more it looks away and down from
    /// it, except while peeking back. `pointer` and the result are gaze coordinates (-1...1, y up).
    static func shyGaze(pointer: CGPoint, closeness: Double, peeking: Bool) -> CGPoint {
        guard !peeking else { return pointer }
        let away = CGPoint(x: -0.6 * max(-1, min(1, pointer.x * 3)), y: -0.5)
        return OrbMath.mix(pointer, away, OrbMath.smoothstep(closeness))
    }
}

// MARK: - Flourishes

/// Short gestures layered on top of the activity: spontaneous idle moves (by temperament) and the showcase
/// played when a temperament is picked. Pure functions of the elapsed time; zero at both ends.
enum OrbFlourish: Sendable, CaseIterable {
    case hop, wiggle, lookAround, bashful, sigh

    struct Offset: Equatable {
        var lift = 0.0
        var squash = 0.0
        var tilt = 0.0
        /// Gaze target and how much it overrides the regular gaze.
        var look = CGPoint.zero
        var lookWeight = 0.0
        /// Extra eyelid closure.
        var squint = 0.0
    }

    var duration: Double {
        switch self {
        case .hop: 0.8
        case .wiggle: 0.75
        case .lookAround: 2.2
        case .bashful: 1.8
        case .sigh: 2
        }
    }

    /// Hops and wiggles move fast enough to alias below 30 fps.
    var minFrameRate: Float {
        switch self {
        case .hop, .wiggle: 30
        case .lookAround, .bashful, .sigh: 15
        }
    }

    func offset(at elapsed: Double) -> Offset {
        guard elapsed > 0, elapsed < duration else { return Offset() }
        let p = elapsed / duration
        let envelope = sin(.pi * p)
        switch self {
        case .hop:
            // Anticipation squash, stretched jump, then a damped jelly landing.
            var offset = Offset()
            switch elapsed {
            case ..<0.1:
                offset.squash = 0.08 * sin(.pi * elapsed / 0.1)
            case ..<0.5:
                let air = sin(.pi * (elapsed - 0.1) / 0.4)
                offset.lift = 0.1 * air
                offset.squash = -0.045 * air
            default:
                let landing = (elapsed - 0.5) / (duration - 0.5)
                offset.squash = 0.06 * sin(.pi * 3 * landing) * (1 - landing)
            }
            return offset
        case .wiggle:
            return Offset(squash: 0.025 * sin(.pi * 6 * p) * envelope, tilt: 9 * sin(.pi * 6 * p) * envelope,
                          look: CGPoint(x: 0, y: 0.15), lookWeight: 0.5 * envelope)
        case .lookAround:
            // Left, then right, then back, with a curious head tilt.
            let side = OrbMath.smoothstep((p - 0.15) / 0.1) - 2 * OrbMath.smoothstep((p - 0.5) / 0.1)
            let weight = OrbMath.smoothstep(p / 0.12) * OrbMath.smoothstep((1 - p) / 0.15)
            return Offset(tilt: -5 * side * weight, look: CGPoint(x: -0.8 * side, y: 0.2), lookWeight: weight)
        case .bashful:
            // Looks down and away, shrinks a little, then peeks back.
            let peek = OrbMath.smoothstep((p - 0.55) / 0.08) * OrbMath.smoothstep((0.8 - p) / 0.08)
            let weight = OrbMath.smoothstep(p / 0.15) * OrbMath.smoothstep((1 - p) / 0.15)
            return Offset(squash: 0.03 * weight, tilt: -5 * weight * (1 - peek),
                          look: OrbMath.mix(CGPoint(x: -0.55, y: -0.55), .zero, peek), lookWeight: weight)
        case .sigh:
            // Slow deep breath in (stretch), out (settle) with eyes half closing.
            return Offset(lift: 0.025 * envelope, squash: -0.035 * sin(2 * .pi * p) * envelope,
                          squint: 0.4 * OrbMath.smoothstep((p - 0.45) / 0.15) * OrbMath.smoothstep((1 - p) / 0.25))
        }
    }
}

/// Schedules spontaneous flourishes at random gaps, and plays requested ones.
struct Flourishes {
    private(set) var current: OrbFlourish?
    private(set) var start = 0.0
    private(set) var next: Double

    init(firstAt time: Double) { next = time }

    func elapsed(at time: Double) -> Double { time - start }

    /// Ends a finished flourish and starts a spontaneous one when due (only if `allowed`; otherwise it is
    /// skipped). Returns the flourish that starts at `time`.
    mutating func update<R: RandomNumberGenerator>(at time: Double, kinds: [OrbFlourish], gap: ClosedRange<Double>,
                                                   allowed: Bool, using rng: inout R) -> OrbFlourish? {
        if let current, time - start >= current.duration { self.current = nil }
        guard current == nil, time >= next else { return nil }
        next = time + Double.random(in: gap, using: &rng)
        guard allowed, let kind = kinds.randomElement(using: &rng) else { return nil }
        play(kind, at: time)
        return kind
    }

    mutating func play(_ kind: OrbFlourish, at time: Double) {
        current = kind
        start = time
    }
}

/// Alternates long looks away with brief peeks (a shy Orb glancing back at the pointer).
struct Glances {
    private(set) var isPeeking = false
    private(set) var next: Double

    init(firstAt time: Double) { next = time }

    /// Returns true when the state flips at `time`.
    mutating func update<R: RandomNumberGenerator>(at time: Double, using rng: inout R) -> Bool {
        guard time >= next else { return false }
        isPeeking.toggle()
        next = time + (isPeeking ? Double.random(in: 0.35...0.75, using: &rng) : Double.random(in: 1.6...3.8, using: &rng))
        return true
    }
}
