import Foundation

/// Mouth shapes for talking. Raw values are the image ids in `Resources/Orbs/visemes/`.
enum OrbViseme: String, CaseIterable, Sendable {
    case rest = "fala-m", open = "fala-a", round = "fala-o", wide = "fala-e"

    /// How open the jaw is (drives the opening tween and, for mouthless Orbs, the eye squint).
    var opening: Double {
        switch self {
        case .rest: 0.1
        case .open: 1
        case .round: 0.75
        case .wide: 0.55
        }
    }

    /// Regular mouth used when the viseme image isn't available.
    var fallbackMouth: String {
        switch self {
        case .rest: "neutra"
        case .open: "sorrisao"
        case .round: "surpresa"
        case .wide: "sorriso"
        }
    }
}

/// Procedural lip-sync: syllable-like open mouth shapes at `rate` per second (±30 %), grouped in "words" of
/// 1–4 syllables separated by short closed pauses (and now and then a longer one, like a comma).
struct Syllables {
    private(set) var shape = OrbViseme.rest
    private(set) var next: Double
    private var left = 0

    init(firstAt time: Double) { next = time }

    /// Returns true when the shape changes at `time`.
    mutating func update<R: RandomNumberGenerator>(at time: Double, rate: Double, using rng: inout R) -> Bool {
        guard time >= next else { return false }
        let previous = shape
        if left > 0 {
            left -= 1
            // Open shapes only: the closed one is kept for pauses (on dark bodies it is a light line, so
            // alternating it with dark openings would flicker).
            let roll = Double.random(in: 0..<1, using: &rng)
            var pick: OrbViseme = roll < 0.45 ? .open : roll < 0.8 ? .wide : .round
            if pick == shape { pick = shape == .open ? .wide : .open }
            shape = pick
            next = time + Double.random(in: 0.7...1.3, using: &rng) / rate
        } else {
            shape = .rest
            left = Int.random(in: 1...4, using: &rng)
            let comma = Double.random(in: 0..<1, using: &rng) < 0.1
            next = time + (comma ? Double.random(in: 0.4...0.7, using: &rng) : Double.random(in: 0.1...0.25, using: &rng))
        }
        return shape != previous
    }

    /// Closes the mouth (speech stopped); the next update starts a new word.
    mutating func rest(at time: Double) {
        shape = .rest
        left = 0
        next = time
    }
}
