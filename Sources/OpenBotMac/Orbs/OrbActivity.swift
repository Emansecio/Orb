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

    var isBusy: Bool { ![.idle, .sleepy].contains(self) }

    /// Activity-driven gaze (x right, y up, both -1...1) and how much the pointer may override it.
    func gaze(at t: Double) -> (look: CGPoint, pointerWeight: Double) {
        switch self {
        case .idle:
            return (CGPoint(x: 0.35 * sin(t * 0.37), y: 0.18 * sin(t * 0.29 + 1)), 1)
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

    /// Body motion: vertical offset (fraction of size, + = up), squash (+ = wider), tilt (degrees), shake (fraction).
    func motion(at t: Double) -> (lift: Double, squash: Double, tilt: Double, shake: Double) {
        let breathe = sin(t * 2.0)
        switch self {
        case .idle, .listening:
            return (0.025 * sin(t * 1.6), 0.012 * breathe, 0, 0)
        case .thinking:
            return (0.03 * sin(t * 1.2), 0.01 * breathe, 4 * sin(t * 0.8), 0)
        case .typing:
            return (0.01 * sin(t * 3), 0.015 * sin(t * 14), 0, 0.006 * sin(t * 38))
        case .browsing, .reading, .searching:
            return (0.025 * sin(t * 1.8), 0.012 * breathe, 3 * sin(t * 1.5), 0)
        case .waiting:
            let hop = abs(sin(t * 3.2))
            return (0.07 * hop, hop < 0.15 ? 0.06 : -0.02, 0, 0)
        case .happy:
            let hop = abs(sin(t * 4))
            return (0.09 * hop, hop < 0.15 ? 0.07 : -0.03, 7 * sin(t * 4), 0)
        case .error:
            return (0, 0.01 * breathe, 0, 0.025 * sin(t * 32) * (0.5 + 0.5 * sin(t * 1.5)))
        case .sleepy:
            return (0.012 * sin(t * 0.9), 0.025 * sin(t * 0.9), -6, 0)
        }
    }

    /// Glow intensity multiplier (busy orbs pulse).
    func glow(at t: Double) -> Double {
        switch self {
        case .idle, .listening: 1
        case .sleepy: 0.55
        case .error: 0.8 + 0.2 * sin(t * 10)
        default: 1 + 0.25 * sin(t * 4)
        }
    }
}
