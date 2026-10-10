import SwiftUI

/// What the bot is doing right now. Drives the Orb's expression (eye/mouth/brow overrides),
/// gaze pattern, body motion and the little status bubble.
enum OrbActivity: String, CaseIterable, Identifiable, Sendable {
    case idle, attentive, listening, speaking, thinking, typing, browsing, reading, searching, waiting, happy, error, sleepy
    /// Waiting for another Orb's answer after asking it (`orbs`): the face of `attentive`, with its own gaze and sway.
    case conversing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: "Parado"
        case .attentive: "Atento"
        case .conversing: "Conversando"
        case .listening: "Ouvindo"
        case .speaking: "Falando"
        case .thinking: "Pensando"
        case .typing: "Terminal"
        case .browsing: "Navegando"
        case .reading: "Lendo"
        case .searching: "Buscando"
        case .waiting: "Precisa de você"
        case .happy: "Feliz"
        case .error: "Erro"
        case .sleepy: "Dormindo"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle"
        case .attentive: "keyboard"
        case .conversing: "bubble.left.and.bubble.right"
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
    /// into slow wobbles below it). The worst case: `minFrameRate(elapsed:size:celebration:)` lowers it when the motion
    /// is calmer than that (small Orbs, a reaction that has died down).
    var minFrameRate: Float {
        switch self {
        case .typing, .error, .waiting, .happy: 30
        case .speaking: 20
        case .thinking, .browsing, .reading, .searching: 15
        case .idle, .attentive, .listening, .sleepy, .conversing: 10
        }
    }

    /// The Orb shows what a tool does (the terminal, the browser, a file, a search).
    var isTool: Bool {
        switch self {
        case .typing, .browsing, .reading, .searching: true
        default: false
        }
    }

    /// How stirred up the Orb looks: 0 calm, 1 at work, 2 worked up. Changing to a more stirred up face gives the body a
    /// little jelly wobble; to a calmer one it just settles.
    var energy: Int {
        switch self {
        case .idle, .attentive, .listening, .speaking, .sleepy, .conversing: 0
        case .thinking, .typing, .browsing, .reading, .searching: 1
        case .waiting, .happy, .error: 2
        }
    }

    /// How much the idle saccades move the gaze (the rest follow their own pattern).
    var wander: Double {
        switch self {
        case .idle: 1
        case .listening, .waiting, .happy: 0.3
        case .attentive, .conversing: 0.2
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
        case .conversing:
            // Waiting for a teammate's answer: the eyes go back and forth between the chat (to the right) and the middle, every ~1.8 s.
            let toChat = Int((t / 1.8).rounded(.down)) % 2 == 0
            return (toChat ? CGPoint(x: 0.7, y: 0.05) : .zero, 0.25)
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
    func motion(at t: Double, elapsed: Double? = nil, traits: OrbTemperament.Traits = .init(),
                celebration: OrbCelebration = .big) -> OrbBodyMotion {
        let breathe = sin(t * 2.0)
        let bob = traits.bob, jump = traits.jump
        switch self {
        case .idle, .attentive, .listening:
            // Breathing, a slow float and a barely-there sway, out of step so it never looks like a loop.
            return OrbBodyMotion(lift: Self.float(t, bob: bob), squash: Self.breath(t, bob: bob), tilt: 1.1 * bob * sin(t * 0.55 + 0.8))
        case .conversing:
            // Breathing with a slight lean that comes and goes: it is waiting, not working.
            return OrbBodyMotion(lift: Self.float(t, bob: bob), squash: Self.breath(t, bob: bob), tilt: 2 * sin(t * 0.9))
        case .speaking:
            // A gentle nod in the rhythm of speech.
            return OrbBodyMotion(lift: 0.014 * bob * sin(t * 4.4), squash: 0.01 * bob * sin(t * 2.2 + 1), tilt: 2 * sin(t * 1.3))
        case .thinking:
            return OrbBodyMotion(lift: 0.03 * sin(t * 1.2), squash: 0.01 * breathe, tilt: 4 * sin(t * 0.8), glow: Self.pulse(t))
        case .typing:
            return OrbBodyMotion(lift: 0.01 * sin(t * 3), squash: 0.015 * sin(t * 14), shake: 0.006 * sin(t * 28),
                                 glow: Self.pulse(t))
        case .browsing, .reading, .searching:
            return OrbBodyMotion(lift: 0.025 * sin(t * 1.8), squash: 0.012 * breathe, tilt: 3 * sin(t * 1.5), glow: Self.pulse(t))
        case .waiting:
            // Asking for you: three hops that lose energy in the first seconds, then two small ones every few seconds with
            // only the breathing between them (a long wait is not a long tantrum). Timed in seconds, not in body time, so the
            // frame rate floor (`minFrameRate(elapsed:size:celebration:)`) knows when the hops are.
            let wait = OrbWaiting.state(at: elapsed ?? t)
            return OrbBodyMotion(lift: 0.07 * jump * wait.hop * wait.amplitude + Self.float(t, bob: bob),
                                 squash: Self.bounce(wait.hop, squash: 0.06 * wait.amplitude, stretch: 0.02 * wait.amplitude)
                                     * wait.contact + Self.breath(t, bob: bob),
                                 glow: Self.pulse(t))
        case .happy:
            return happy(at: t, elapsed: elapsed, traits: traits, style: celebration)
        case .error:
            // A shake of the head ("no", 3 Hz) that dies out in about a second, then it stays slumped, its glow dimmed and still.
            let e = min(elapsed ?? t, 100) // (an Orb that appears in the error state has been in it "forever": infinite)
            let slump = OrbMath.smoothstep((e - 0.3) / 0.9)
            return OrbBodyMotion(squash: 0.01 * breathe, tilt: -3 * slump,
                                 shake: 0.025 * exp(-2.2 * e) * sin(2 * .pi * 3 * e), glow: 0.85)
        case .sleepy:
            return OrbBodyMotion(lift: 0.012 * bob * sin(t * 0.9), squash: 0.025 * bob * sin(t * 0.9), tilt: -6, glow: 0.55)
        }
    }

    /// `happy`: seconds of the getting-ready squash, and seconds of hopping after it until the biggest celebration has
    /// calmed down (`OrbCelebration.calm` has each one's).
    static let happyReady = 0.3, happyCalm = OrbCelebration.big.calm

    /// `happy` as a burst of joy that calms down: a squash to get ready (long enough to show through the blend into the
    /// activity), hops each lower than the last (one only, for a light celebration), then the idle float with a contented
    /// sway. Without timing it hops in a loop; an orb that was already happy when it appeared (infinite `elapsed`) is calm.
    /// A smile (the click) is only the face: no hops.
    private func happy(at t: Double, elapsed: Double?, traits: OrbTemperament.Traits, style: OrbCelebration) -> OrbBodyMotion {
        let bob = traits.bob, jump = traits.jump
        let calmSway = Self.float(t, bob: bob), calmBreath = Self.breath(t, bob: bob)
        guard style.hop > 0 else {
            return OrbBodyMotion(lift: calmSway, squash: calmBreath, tilt: 2 * sin(t * 1.1), glow: Self.pulse(t))
        }
        let size = style.hop / OrbCelebration.big.hop // the tilt and the stretch follow the height
        guard let e = elapsed.map({ $0 * traits.pace }) else {
            let hop = abs(sin(t * 4.2))
            return OrbBodyMotion(lift: style.hop * jump * hop, squash: Self.bounce(hop, squash: style.ready, stretch: 0.03 * size),
                                 tilt: 7 * size * sin(t * 4.2), glow: Self.pulse(t))
        }
        if e < Self.happyReady {
            return OrbBodyMotion(squash: style.ready * OrbMath.smoothstep(e / Self.happyReady), glow: Self.pulse(t))
        }
        let since = e.isFinite ? e - Self.happyReady : .infinity
        let energy = 1 - OrbMath.smoothstep((since - 0.6) / (style.calm - 0.6))
        // One hop is a half period of |sin(4.2 s)|.
        let phase = since.isFinite ? min(since, style.hops.map { Double($0) * .pi / 4.2 } ?? .infinity) : 0
        let hop = abs(sin(phase * 4.2))
        return OrbBodyMotion(lift: style.hop * jump * hop * energy + (1 - energy) * calmSway,
                             squash: Self.bounce(hop, squash: style.ready * energy, stretch: 0.03 * size * energy)
                                 + (1 - energy) * calmBreath,
                             tilt: 7 * size * sin(phase * 4.2) * energy + 2 * (1 - energy) * sin(t * 1.1), glow: Self.pulse(t))
    }

    /// `minFrameRate` for an activity that started `elapsed` seconds ago, on an Orb of `size` points: the floor is what the
    /// motion needs *now*. Once `happy` has calmed down it needs no more than idle (the editor's preview can stay happy for
    /// minutes); "precisa de você" needs 30 only while it hops; the terminal shakes slowly enough for 20 on small Orbs; the
    /// error is still after its "no"; and the activities that only drift need 10 on small Orbs, where a step is a fraction of
    /// a pixel.
    func minFrameRate(elapsed: Double, size: CGFloat = 96, celebration: OrbCelebration = .big) -> Float {
        switch self {
        case .happy:
            // (The slowest temperament paces motion at 0.7×.)
            let hops = celebration.hop > 0 && elapsed <= (Self.happyReady + celebration.calm) / 0.7
            return hops ? minFrameRate : OrbActivity.idle.minFrameRate
        case .waiting:
            return OrbWaiting.isHopping(at: elapsed) ? minFrameRate : OrbActivity.idle.minFrameRate
        case .error:
            return elapsed > OrbActivity.errorShake ? OrbActivity.idle.minFrameRate : (size < Self.vibratesBelow ? 20 : minFrameRate)
        case .typing:
            return size < Self.vibratesBelow ? 20 : minFrameRate
        case .thinking, .browsing, .reading, .searching:
            return size < Self.smallOrb ? OrbActivity.idle.minFrameRate : minFrameRate
        default:
            return minFrameRate
        }
    }

    /// Orbs under these sizes need fewer frames: 20 for a shake, 10 for a drift.
    static let vibratesBelow: CGFloat = 80, smallOrb: CGFloat = 40
    /// Seconds the error's "no" lasts (it is still after it).
    static let errorShake = 1.3

    /// Busy orbs' glow pulses: under 1 so it never clips at full opacity, and slow enough that a 10 fps frame changes it by
    /// less than a pixel.
    private static func pulse(_ t: Double) -> Double { 0.89 + 0.11 * sin(t * 2.4) }

    /// The slow float and the breathing of a calm Orb (also under the hops of the others).
    static func float(_ t: Double, bob: Double) -> Double { 0.018 * bob * sin(t * 1.3) }
    static func breath(_ t: Double, bob: Double) -> Double { 0.016 * bob * sin(t * 2.0) }

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

/// The activity on screen and the one it is blending from. Body motion, gaze and glow cross over `duration`
/// seconds; a change that arrives in the middle of a crossover starts from what was on screen at that moment, not
/// from the activity that weighed only a little by then (a quick tool between two thoughts would otherwise
/// snap the body to it for a frame).
struct OrbActivityBlend {
    static let duration = 0.35

    private(set) var shown: OrbActivity
    private(set) var previous: OrbActivity
    /// When `shown` started.
    private(set) var start = -Double.infinity
    /// When `previous` started (one-shot reactions like `happy` keep their timing while they fade out).
    private(set) var previousStart = -Double.infinity
    /// The body motion on screen when a crossover was interrupted: the origin of the next one.
    private var origin: OrbBodyMotion?
    /// How big the `happy` on screen (and the one it blends from) is.
    private(set) var shownStyle = OrbCelebration.big
    private(set) var previousStyle = OrbCelebration.big

    init(_ activity: OrbActivity = .idle) {
        shown = activity
        previous = activity
    }

    /// 0...1 (eased) through the crossover.
    func progress(at time: Double) -> Double {
        OrbMath.smoothstep((time - start) / Self.duration)
    }

    func isBlending(at time: Double) -> Bool { time - start < Self.duration }

    /// Starts blending to `target`. `body` is the body clock the motions are read at.
    mutating func change(to target: OrbActivity, at time: Double, body: Double, traits: OrbTemperament.Traits,
                         celebration: OrbCelebration = .big) {
        origin = isBlending(at: time) ? motion(at: time, body: body, traits: traits) : nil
        previous = shown
        previousStart = start
        previousStyle = shownStyle
        shown = target
        start = time
        shownStyle = celebration
    }

    /// Starts in `activity` with nothing to blend (not on screen yet).
    mutating func jump(to activity: OrbActivity, celebration: OrbCelebration = .big) {
        shown = activity
        previous = activity
        shownStyle = celebration
        previousStyle = celebration
        origin = nil
    }

    func motion(at time: Double, body: Double, traits: OrbTemperament.Traits) -> OrbBodyMotion {
        motion(at: time, body: body, traits: traits, blend: progress(at: time))
    }

    /// Same, with the blend already computed (once per frame).
    func motion(at time: Double, body: Double, traits: OrbTemperament.Traits, blend: Double) -> OrbBodyMotion {
        let target = shown.motion(at: body, elapsed: time - start, traits: traits, celebration: shownStyle)
        guard blend < 1 else { return target }
        let from = origin ?? previous.motion(at: body, elapsed: time - previousStart, traits: traits, celebration: previousStyle)
        return OrbBodyMotion.mix(from, target, blend)
    }
}

// MARK: - Celebration

/// How much the Orb celebrates the end of a turn: a short answer gets a smile and one small hop, a long job the whole show.
enum OrbCelebration: String, CaseIterable, Sendable {
    /// Only the happy face, no hops (a click on a calm Orb).
    case smile
    case light, normal, big

    /// How long the Orb stays happy.
    var seconds: Double {
        switch self {
        case .smile: 1.4
        case .light: 1.6
        case .normal: 2.2
        case .big: 3
        }
    }

    /// Height of the hops (fraction of the orb size); none for the smile.
    var hop: Double {
        switch self {
        case .smile: 0
        case .light: 0.05
        case .normal: 0.08
        case .big: 0.1
        }
    }

    /// The squash the Orb gets ready with and lands with.
    var ready: Double {
        switch self {
        case .smile: 0
        case .light: 0.05
        case .normal, .big: 0.075
        }
    }

    /// Seconds of hopping, after the getting-ready squash, until the Orb has calmed down.
    var calm: Double {
        switch self {
        case .smile: 0
        case .light: 1
        case .normal: 1.6
        case .big: 2.2
        }
    }

    /// How many hops it makes (nil: as many as its energy lasts).
    var hops: Int? { self == .light ? 1 : nil }

    /// What a turn deserves. A routine that ran while you looked at its Orb is a big moment, one that ran somewhere else
    /// gets a light one whatever it did; otherwise the turn's length and number of actions decide: a quick answer (under 8 s,
    /// one action at most) is light, a long job (over 45 s or 8 actions) is big.
    static func level(seconds: Double, actions: Int, ranRoutine: Bool, selected: Bool) -> OrbCelebration {
        if ranRoutine { return selected ? .big : .light }
        if seconds > 45 || actions >= 8 { return .big }
        if seconds < 8 && actions <= 1 { return .light }
        return .normal
    }
}

/// A one-time reaction that an Orb's avatars play: a blink when you stop the reply, a sigh when a task stopped half way.
enum OrbCue: Sendable, Equatable {
    case blink, sigh
}

/// A cue and how many there have been: avatars play one each time the count changes.
struct OrbCueSignal: Equatable, Sendable {
    var count = 0
    var kind = OrbCue.blink
}

// MARK: - Waiting

/// The hops of "precisa de você" over time: three that lose energy in the first 3 s, then two small ones (0.4 of the height)
/// at the start of every 7 s with only the breathing between, and after a minute of waiting a lower height (0.6×).
enum OrbWaiting {
    static let intro = 3.0, cycle = 7.0, group = 1.4, period = 0.7, small = 0.4
    /// Seconds around a group of hops in which the landing squash fades in and out.
    static let edge = 0.15
    static let tiredAfter = 60.0, tiredHeight = 0.6

    /// `hop`: 0...1, 0 on the ground. `amplitude`: height of this hop in terms of the biggest. `contact`: how much of the
    /// landing squash is there (it fades in before a group and out after it, so the body never snaps).
    static func state(at e: Double) -> (hop: Double, amplitude: Double, contact: Double) {
        // An Orb that appears already waiting has been waiting "forever" (infinite): quiet, and tired.
        guard e.isFinite else { return (0, small * tiredHeight, 0) }
        let tired = 1 - (1 - tiredHeight) * OrbMath.smoothstep((e - tiredAfter) / 2)
        if e < intro {
            return (abs(sin(.pi * e)), (1 - (1 - small) * OrbMath.smoothstep(e / intro)) * tired, 1)
        }
        let c = (e - intro).truncatingRemainder(dividingBy: cycle)
        if c < group { return (abs(sin(.pi * c / period)), small * tired, 1) }
        let after = OrbMath.smoothstep(1 - (c - group) / edge), before = OrbMath.smoothstep(1 - (cycle - c) / edge)
        return (0, small * tired, max(after, before))
    }

    /// Whether the hops (and the landing squash around them) are going on at `e`: the only time it needs 30 fps.
    static func isHopping(at e: Double) -> Bool {
        guard e.isFinite else { return false }
        if e < intro { return true }
        let c = (e - intro).truncatingRemainder(dividingBy: cycle)
        return c < group + edge + 0.1 || c > cycle - edge - 0.1
    }
}

// MARK: - Tools in a row

/// A tool ends and the model thinks for a moment before the next: the Orb keeps the tool's pose for `wait` seconds instead
/// of flipping to "pensando" and back. Everything else (waiting for you, the error, joy, a new tool) comes at once.
struct OrbActivityHold {
    static let wait = 0.6
    private var since: Double?

    /// The activity to show now. `applies` false (the Orb is not on screen, or is at rest) never waits.
    mutating func resolve(wanted: OrbActivity, shown: OrbActivity, at time: Double, applies: Bool = true) -> OrbActivity {
        guard applies, wanted == .thinking, shown.isTool else {
            since = nil
            return wanted
        }
        let start = since ?? time
        since = start
        return time - start < Self.wait ? shown : wanted
    }
}
