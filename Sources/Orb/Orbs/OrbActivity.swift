import SwiftUI

/// What the bot is doing right now. Drives the Orb's expression (eye/mouth/brow overrides),
/// gaze pattern, body motion and the little status bubble.
enum OrbActivity: String, CaseIterable, Identifiable, Sendable {
    case idle, attentive, listening, speaking, thinking, typing, browsing, reading, searching, waiting, happy, error, sleepy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: "Parado"
        case .attentive: "Atento"
        case .listening: "Ouvindo"
        case .speaking: "Falando"
        case .thinking: "Pensando"
        case .typing: "Terminal"
        case .browsing: "Navegando"
        case .reading: "Lendo"
        case .searching: "Buscando"
        case .waiting: "Esperando você"
        case .happy: "Feliz"
        case .error: "Erro"
        case .sleepy: "Dormindo"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle"
        case .attentive: "keyboard"
        case .listening: "ear"
        case .speaking: "waveform"
        case .thinking: "ellipsis"
        case .typing: "terminal"
        case .browsing: "globe"
        case .reading: "doc.text"
        case .searching: "magnifyingglass"
        case .waiting: "hand.raised"
        case .happy: "sparkles"
        case .error: "exclamationmark.triangle"
        case .sleepy: "moon.zzz"
        }
    }

    // Expression overrides (nil keeps the bot's own choice)

    var eyes: String? {
        switch self {
        case .typing: "fendas"
        case .searching: "ovais"
        case .waiting: "grandes"
        case .happy: "felizes"
        case .error: "tontos"
        case .sleepy: "sono"
        default: nil
        }
    }

    func mouth(base: String) -> String? {
        switch self {
        case .thinking: "assobio"
        case .typing: "neutra"
        case .waiting: "surpresa"
        case .happy: "sorrisao"
        case .error: "triste"
        case .sleepy: base == "nenhuma" ? nil : "neutra"
        default: nil
        }
    }

    var brows: String? {
        switch self {
        case .waiting: "preocupadas"
        case .typing: "retas"
        case .error: "preocupadas"
        default: nil
        }
    }

    /// Small floating bubble next to the orb.
    var bubble: String? {
        switch self {
        case .thinking: "…"
        case .waiting: "?"
        case .error: "!"
        case .sleepy: "z"
        default: nil
        }
    }

    /// Lowest frame rate that still shows this activity's fastest motion (vibrations and hops would alias
    /// into slow wobbles below it).
    var minFrameRate: Float {
        switch self {
        case .typing, .error, .waiting, .happy: 30
        case .speaking: 20
        case .thinking, .browsing, .reading, .searching: 15
        case .idle, .attentive, .listening, .sleepy: 10
        }
    }

    /// How much the idle saccades move the gaze (the rest follow their own pattern).
    var wander: Double {
        switch self {
        case .idle: 1
        case .listening, .waiting, .happy: 0.3
        case .attentive: 0.2
        case .speaking: 0.35
        default: 0
        }
    }

    /// The two show the same face (eyes, mouth, brows and bubble): switching between them changes only motion and
    /// gaze (parado, atento, ouvindo), so it needs no blink to hide a swap and no wobble.
    func hasSameFace(as other: OrbActivity, mouth base: String) -> Bool {
        eyes == other.eyes && brows == other.brows && bubble == other.bubble
            && mouth(base: base) == other.mouth(base: base)
    }

    /// Seconds between blinks, from the temperament's: watching you type, the Orb blinks less (people do while
    /// reading).
    func blinkGap(_ gap: ClosedRange<Double>) -> ClosedRange<Double> {
        self == .attentive ? gap.lowerBound * 1.5...gap.upperBound * 1.5 : gap
    }

    /// Activity-driven gaze (x right, y up, both -1...1) and how much the pointer may override it.
    func gaze(at t: Double) -> (look: CGPoint, pointerWeight: Double) {
        switch self {
        case .idle:
            return (.zero, 1)
        case .listening:
            return (CGPoint(x: 0, y: -0.15), 1)
        case .attentive:
            // Watching the user type: eyes down toward the message field, a lazy drift along the line.
            return (CGPoint(x: 0.08 * sin(t * 0.9), y: -0.45), 0.3)
        case .speaking:
            return (CGPoint(x: 0.06 * sin(t * 0.7), y: -0.05), 0.7)
        case .thinking:
            return (CGPoint(x: 0.55 + 0.08 * sin(t * 1.3), y: 0.6), 0.25)
        case .typing:
            return (CGPoint(x: 0.12 * sin(t * 5), y: -0.55), 0.15)
        case .browsing:
            return (CGPoint(x: 0.85 * sin(t * 1.5), y: 0.05), 0.2)
        case .reading:
            let line = (t * 0.6).truncatingRemainder(dividingBy: 1)
            return (CGPoint(x: -0.6 + 1.2 * line, y: -0.5), 0.2)
        case .searching:
            return (CGPoint(x: 0.75 * cos(t * 2.1), y: 0.5 * sin(t * 2.1)), 0.2)
        case .waiting:
            return (CGPoint(x: 0, y: -0.1), 0.9)
        case .happy:
            return (CGPoint(x: 0, y: 0.1), 0.6)
        case .error:
            return (CGPoint(x: 0.2 * sin(t * 9), y: 0), 0)
        case .sleepy:
            return (CGPoint(x: 0, y: -0.3), 0)
        }
    }

    /// Body motion and glow at time `t`, `elapsed` seconds after the activity started (one-shot reactions use it;
    /// nil plays them in a loop). The temperament scales the idle bob and the hops (its pace is applied to `t` by the
    /// caller, so the motion stays continuous when it changes).
    func motion(at t: Double, elapsed: Double? = nil, traits: OrbTemperament.Traits = .init()) -> OrbBodyMotion {
        let breathe = sin(t * 2.0)
        let bob = traits.bob, jump = traits.jump
        switch self {
        case .idle, .attentive, .listening:
            // Breathing, a slow float and a barely-there sway, out of step so it never looks like a loop.
            return OrbBodyMotion(lift: 0.025 * bob * sin(t * 1.6), squash: 0.012 * bob * breathe, tilt: 1.1 * bob * sin(t * 0.55 + 0.8))
        case .speaking:
            // A gentle nod in the rhythm of speech.
            return OrbBodyMotion(lift: 0.014 * bob * sin(t * 4.4), squash: 0.01 * bob * sin(t * 2.2 + 1), tilt: 2 * sin(t * 1.3))
        case .thinking:
            return OrbBodyMotion(lift: 0.03 * sin(t * 1.2), squash: 0.01 * breathe, tilt: 4 * sin(t * 0.8), glow: Self.pulse(t))
        case .typing:
            return OrbBodyMotion(lift: 0.01 * sin(t * 3), squash: 0.015 * sin(t * 14), shake: 0.006 * sin(t * 38),
                                 glow: Self.pulse(t))
        case .browsing, .reading, .searching:
            return OrbBodyMotion(lift: 0.025 * sin(t * 1.8), squash: 0.012 * breathe, tilt: 3 * sin(t * 1.5), glow: Self.pulse(t))
        case .waiting:
            let hop = abs(sin(t * 3.2))
            return OrbBodyMotion(lift: 0.07 * jump * hop, squash: Self.bounce(hop, squash: 0.06, stretch: 0.02), glow: Self.pulse(t))
        case .happy:
            // A burst of joy that calms down: a squash to get ready (long enough to show through the blend into
            // the activity), hops each lower than the last, then the idle float with a contented sway. Without
            // timing it hops in a loop; an orb that was already happy when it appeared (infinite `elapsed`) is calm.
            guard let e = elapsed.map({ $0 * traits.pace }) else {
                let hop = abs(sin(t * 4.2))
                return OrbBodyMotion(lift: 0.1 * jump * hop, squash: Self.bounce(hop, squash: 0.075, stretch: 0.03),
                                     tilt: 7 * sin(t * 4.2), glow: Self.pulse(t))
            }
            if e < Self.happyReady {
                return OrbBodyMotion(squash: 0.075 * OrbMath.smoothstep(e / Self.happyReady), glow: Self.pulse(t))
            }
            let since = e.isFinite ? e - Self.happyReady : .infinity
            let energy = 1 - OrbMath.smoothstep((since - 0.6) / (Self.happyCalm - 0.6))
            let phase = since.isFinite ? since : 0
            let hop = abs(sin(phase * 4.2))
            return OrbBodyMotion(lift: 0.1 * jump * hop * energy + (1 - energy) * 0.025 * bob * sin(t * 1.6),
                                 squash: Self.bounce(hop, squash: 0.075 * energy, stretch: 0.03 * energy)
                                     + (1 - energy) * 0.012 * bob * breathe,
                                 tilt: 7 * sin(phase * 4.2) * energy + 2 * (1 - energy) * sin(t * 1.1), glow: Self.pulse(t))
        case .error:
            return OrbBodyMotion(squash: 0.01 * breathe, shake: 0.025 * sin(t * 32) * (0.5 + 0.5 * sin(t * 1.5)),
                                 glow: 0.8 + 0.2 * sin(t * 10))
        case .sleepy:
            return OrbBodyMotion(lift: 0.012 * bob * sin(t * 0.9), squash: 0.025 * bob * sin(t * 0.9), tilt: -6, glow: 0.55)
        }
    }

    /// `happy`: seconds of the getting-ready squash, and seconds of hopping after it until the orb has calmed down.
    static let happyReady = 0.3, happyCalm = 2.2

    /// `minFrameRate` for an activity that started `elapsed` seconds ago: once `happy` has calmed down it needs no
    /// more than idle (the editor's preview can stay happy for minutes).
    func minFrameRate(elapsed: Double) -> Float {
        // (The slowest temperament paces motion at 0.7×.)
        self == .happy && elapsed > (Self.happyReady + Self.happyCalm) / 0.7 ? OrbActivity.idle.minFrameRate : minFrameRate
    }

    /// Busy orbs' glow pulses.
    private static func pulse(_ t: Double) -> Double { 1 + 0.25 * sin(t * 4) }

    /// Squashed on contact (`hop` near 0), stretched in the air, with a smooth hand-off between the two.
    static func bounce(_ hop: Double, squash: Double, stretch: Double) -> Double {
        let contact = pow(max(0, 1 - hop / 0.3), 2)
        return -stretch + (squash + stretch) * contact
    }
}

/// Body motion: vertical offset (fraction of size, + = up), squash (+ = wider), tilt (degrees),
/// shake (fraction of size) and glow multiplier.
struct OrbBodyMotion: Equatable {
    var lift = 0.0
    var squash = 0.0
    var tilt = 0.0
    var shake = 0.0
    var glow = 1.0

    static func mix(_ a: OrbBodyMotion, _ b: OrbBodyMotion, _ t: Double) -> OrbBodyMotion {
        guard t > 0 else { return a }
        guard t < 1 else { return b }
        return OrbBodyMotion(lift: OrbMath.mix(a.lift, b.lift, t), squash: OrbMath.mix(a.squash, b.squash, t),
                      tilt: OrbMath.mix(a.tilt, b.tilt, t), shake: OrbMath.mix(a.shake, b.shake, t),
                      glow: OrbMath.mix(a.glow, b.glow, t))
    }
}
