import AppKit
import QuartzCore

// MARK: - Frame clock

/// When one orb's next frame is due on a clock that ticks at the fastest orb's rate: an orb that wants 10 fps
/// on a 30 Hz clock takes every third tick.
struct OrbFrameClock {
    private(set) var nextDue = 0.0
    private var lastFrame = 0.0

    /// A tick can land a hair before the due time (vsync jitter); that still counts.
    private static let tolerance = 0.004

    /// Whether a frame is due at `time`; if so, schedules the next one. After a long gap (the orb was paused)
    /// the next frame is not due earlier than half an interval from now, so there is no burst of catch-up frames.
    mutating func isDue(at time: Double, rate: Float) -> Bool {
        guard time >= nextDue - Self.tolerance else { return false }
        let interval = 1 / Double(max(rate, 1))
        nextDue = max(nextDue + interval, time + interval / 2)
        lastFrame = time
        return true
    }

    /// The orb wants another rate: a faster one takes effect at the next tick that fits it.
    mutating func rateChanged(to rate: Float) {
        nextDue = min(nextDue, lastFrame + 1 / Double(max(rate, 1)))
    }

    /// Back from a pause: the first frame is due right away.
    mutating func reset() {
        nextDue = 0
        lastFrame = 0
    }
}

/// The rate the shared link runs at for the orbs that are running: the lowest one every orb's rate divides
/// evenly, so each takes every n-th tick at a regular pace (20 fps on a 30 Hz link would alternate 33 and
/// 67 ms; on a 60 Hz one it is steady at 50). Rates that do not divide each other (20 with 15 or 30) would meet
/// at 60 Hz, which wakes the main thread twice as often as the fastest orb needs: up to 30 the link stops at 30
/// instead, and an orb whose rate does not divide it steps at `stepRate` (a little faster, never slower).
enum OrbLinkRate {
    static let candidates: [Float] = [10, 15, 20, 30, 60]
    private static let fastestLinkForSmallOrbs: Float = 30

    static func rate(forOrbsAt orbRates: [Float]) -> Float {
        let rates = orbRates.filter { $0 > 0 }
        guard let fastest = rates.max() else { return candidates[0] }
        let fits = { (link: Float) in
            link >= fastest && rates.allSatisfy { divides(link, by: $0) }
        }
        let meeting = candidates.first(where: fits) ?? max(fastest, candidates[candidates.count - 1])
        return fastest <= fastestLinkForSmallOrbs ? min(meeting, fastestLinkForSmallOrbs) : meeting
    }

    /// The rate an orb that wants `wanted` fps actually steps at on a link of `link` Hz: the lowest one at or above what
    /// it wants that the link divides evenly (20 fps on a 30 Hz link takes every tick: 30 fps, smoother, never choppier).
    static func stepRate(_ wanted: Float, onLink link: Float) -> Float {
        guard link > 0 else { return wanted }
        return candidates.first { $0 >= wanted && $0 <= link && divides(link, by: $0) } ?? link
    }

    private static func divides(_ link: Float, by rate: Float) -> Bool {
        abs(link / rate - (link / rate).rounded()) < 0.01
    }
}

/// Whether an orb is worth animating inside a scroll view.
enum OrbVisibility {
    /// `orb` and `viewport` are in the same coordinates. The orb's layers (hats, glow) reach past its frame by
    /// about its size, hence `margin`. An empty viewport means the scroll view is not laid out yet: visible.
    static func isVisible(orb: CGRect, in viewport: CGRect, margin: CGFloat) -> Bool {
        viewport.isEmpty || viewport.intersects(orb.insetBy(dx: -margin, dy: -margin))
    }
}

// MARK: - Shared display link

/// One display link per screen for every animated orb on it, instead of one link (and one Core Animation
/// commit) per orb: each tick steps the orbs whose frame is due inside a single transaction. Orbs decide
/// their own rate, whether they are running and when they settle; the driver only schedules them. The link
/// runs at a rate every running orb's rate divides (see `OrbLinkRate`) and pauses when none runs.
@MainActor
final class OrbDriver: NSObject {
    private static var drivers: [ObjectIdentifier: OrbDriver] = [:]

    /// The driver for the screen `window` is on (the main screen when it is on none, e.g. offscreen).
    static func driver(for window: NSWindow?) -> OrbDriver? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let id = ObjectIdentifier(screen)
        if let driver = drivers[id] { return driver }
        let driver = OrbDriver(screen: screen)
        drivers[id] = driver
        return driver
    }

    private let screen: NSScreen
    private var link: CADisplayLink?
    private let orbs = NSHashTable<OrbAnimationView>.weakObjects()
    /// The orbs that run, found when something changes (`refresh`) and not at every tick.
    private var running: [OrbAnimationView] = []
    private(set) var rate: Float = 0

    /// For tests: whether the link is stopped, and how many orbs and drivers there are.
    var isLinkPaused: Bool { link?.isPaused ?? true }
    var orbCount: Int { orbs.count }
    static var driverCount: Int { drivers.count }

    private init(screen: NSScreen) {
        self.screen = screen
        super.init()
    }

    func add(_ orb: OrbAnimationView) {
        orbs.add(orb)
        if link == nil {
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        refresh()
    }

    func remove(_ orb: OrbAnimationView) {
        orbs.remove(orb)
        guard orbs.count == 0 else { return refresh() }
        // The link retains its target: drop it with the last orb.
        link?.invalidate()
        link = nil
        rate = 0
        running = []
        Self.drivers.removeValue(forKey: ObjectIdentifier(screen))
    }

    /// Pauses the link when no orb runs; otherwise runs it as fast as the fastest one wants.
    func refresh() {
        running = orbs.allObjects.filter(\.isRunning)
        link?.isPaused = running.isEmpty
        let wanted = OrbLinkRate.rate(forOrbsAt: running.map(\.frameRate))
        guard wanted != rate else { return }
        rate = wanted
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: wanted / 2, maximum: wanted, preferred: wanted)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        // Orbs that stop or change rate while stepping touch the driver (`refresh` replaces the list): iterate a copy, and
        // skip one that stopped meanwhile.
        let running = running
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for orb in running where orb.isRunning { orb.stepIfDue(at: time) }
        CATransaction.commit()
    }
}
