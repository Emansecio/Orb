import SwiftUI

/// What the bot is doing right now. Drives the Orb's expression (eye/mouth/brow overrides),
/// gaze pattern, body motion and the little status bubble.
enum OrbActivity: String, CaseIterable, Identifiable, Sendable {
    case idle, listening, thinking, typing, browsing, reading, searching, waiting, happy, error, sleepy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: "Parado"
        case .listening: "Ouvindo"
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
        case .listening: "ear"
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
        case .thinking, .browsing, .reading, .searching: 15
        case .idle, .listening, .sleepy: 10
        }
    }

    /// How much the idle saccades move the gaze (the rest follow their own pattern).
    var wander: Double {
        switch self {
        case .idle: 1
        case .listening, .waiting, .happy: 0.3
        default: 0
        }
    }

    /// Activity-driven gaze (x right, y up, both -1...1) and how much the pointer may override it.
    func gaze(at t: Double) -> (look: CGPoint, pointerWeight: Double) {
        switch self {
        case .idle:
            return (.zero, 1)
        case .listening:
            return (CGPoint(x: 0, y: -0.15), 1)
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

    /// Body motion and glow at time `t`.
    func motion(at t: Double) -> OrbBodyMotion {
        let breathe = sin(t * 2.0)
        switch self {
        case .idle, .listening:
            return OrbBodyMotion(lift: 0.025 * sin(t * 1.6), squash: 0.012 * breathe)
        case .thinking:
            return OrbBodyMotion(lift: 0.03 * sin(t * 1.2), squash: 0.01 * breathe, tilt: 4 * sin(t * 0.8), glow: Self.pulse(t))
        case .typing:
            return OrbBodyMotion(lift: 0.01 * sin(t * 3), squash: 0.015 * sin(t * 14), shake: 0.006 * sin(t * 38),
                                 glow: Self.pulse(t))
        case .browsing, .reading, .searching:
            return OrbBodyMotion(lift: 0.025 * sin(t * 1.8), squash: 0.012 * breathe, tilt: 3 * sin(t * 1.5), glow: Self.pulse(t))
        case .waiting:
            let hop = abs(sin(t * 3.2))
            return OrbBodyMotion(lift: 0.07 * hop, squash: Self.bounce(hop, squash: 0.06, stretch: 0.02), glow: Self.pulse(t))
        case .happy:
            let hop = abs(sin(t * 4))
            return OrbBodyMotion(lift: 0.09 * hop, squash: Self.bounce(hop, squash: 0.07, stretch: 0.03), tilt: 7 * sin(t * 4),
                                 glow: Self.pulse(t))
        case .error:
            return OrbBodyMotion(squash: 0.01 * breathe, shake: 0.025 * sin(t * 32) * (0.5 + 0.5 * sin(t * 1.5)),
                                 glow: 0.8 + 0.2 * sin(t * 10))
        case .sleepy:
            return OrbBodyMotion(lift: 0.012 * sin(t * 0.9), squash: 0.025 * sin(t * 0.9), tilt: -6, glow: 0.55)
        }
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
        OrbBodyMotion(lift: OrbMath.mix(a.lift, b.lift, t), squash: OrbMath.mix(a.squash, b.squash, t),
                      tilt: OrbMath.mix(a.tilt, b.tilt, t), shake: OrbMath.mix(a.shake, b.shake, t),
                      glow: OrbMath.mix(a.glow, b.glow, t))
    }
}
