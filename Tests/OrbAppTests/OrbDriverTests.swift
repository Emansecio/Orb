import Testing
import AppKit
import Foundation
@testable import Orb

/// The shared display link, the visibility rules and the shimmer band, with real views in a real window.
/// (They need a screen: without one they do nothing.)
@Suite(.serialized) @MainActor
struct OrbDriverTests {
    // MARK: Link rate

    @Test func linkRunsAtTheLowestRateEveryOrbDivides() {
        #expect(OrbLinkRate.rate(forOrbsAt: []) == 10)
        #expect(OrbLinkRate.rate(forOrbsAt: [10]) == 10)
        #expect(OrbLinkRate.rate(forOrbsAt: [10, 20]) == 20)
        #expect(OrbLinkRate.rate(forOrbsAt: [10, 30]) == 30)
        #expect(OrbLinkRate.rate(forOrbsAt: [10, 15]) == 30)
        #expect(OrbLinkRate.rate(forOrbsAt: [15, 30]) == 30)
        // Rates that do not divide each other meet at 60.
        #expect(OrbLinkRate.rate(forOrbsAt: [20, 30]) == 60)
        #expect(OrbLinkRate.rate(forOrbsAt: [15, 20]) == 60)
        #expect(OrbLinkRate.rate(forOrbsAt: [10, 15, 20]) == 60)
        #expect(OrbLinkRate.rate(forOrbsAt: [30, 60]) == 60)
        // A rate not set yet does not matter.
        #expect(OrbLinkRate.rate(forOrbsAt: [0, 20]) == 20)
        #expect(OrbLinkRate.rate(forOrbsAt: [0]) == 10)
    }

    /// Intervals between the frames an orb of `rate` gets from a link at `linkRate`.
    private func intervals(rate: Float, linkRate: Double, seconds: Double = 3) -> [Double] {
        var clock = OrbFrameClock()
        var times: [Double] = []
        for tick in 1...Int(linkRate * seconds) {
            let time = Double(tick) / linkRate
            if clock.isDue(at: time, rate: rate) { times.append(time) }
        }
        // (The first frame comes at once, so the gap after it is shorter.)
        return zip(times.dropFirst(), times).map { $0 - $1 }.dropFirst().map { $0 }
    }

    @Test func everyCombinationOfRatesGetsSteadyFrames() {
        let rates = OrbFrameRate.steps
        for a in rates { for b in rates {
            let link = Double(OrbLinkRate.rate(forOrbsAt: [a, b]))
            for rate in [a, b] {
                let gaps = intervals(rate: rate, linkRate: link)
                let expected = 1 / Double(rate)
                #expect(!gaps.isEmpty)
                #expect(gaps.allSatisfy { abs($0 - expected) < 0.002 }, "\(rate) fps on a \(link) Hz link: \(gaps.prefix(6))")
            }
        } }
    }

    @Test func aLinkThatDoesNotDivideTheRateWouldStutter() {
        // What the shared link used to do: 20 fps on a 30 Hz link alternates 33 and 67 ms.
        let gaps = intervals(rate: 20, linkRate: 30)
        #expect(Set(gaps.map { ($0 * 1000).rounded() }).count > 1)
    }

    // MARK: Fixtures

    private var hasScreen: Bool { NSScreen.main != nil }

    private func window(_ content: NSView, size: CGFloat = 200) -> NSWindow {
        _ = NSApplication.shared
        // No window is visible to a test run (no one looks at the screen): frames run regardless.
        OrbView.animateInactive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    /// Takes the views out of the window, so their orbs leave the shared driver.
    private func close(_ window: NSWindow) {
        window.contentView = NSView()
        window.orderOut(nil)
    }

    private func orb(live: Bool = true, size: CGFloat = 30, frame: NSRect = NSRect(x: 10, y: 10, width: 30, height: 30)) -> OrbAnimationView {
        let view = OrbAnimationView(frame: frame)
        view.configure(config: OrbConfig(), activity: .idle, size: size, followsPointer: false, interactive: false, live: live)
        return view
    }

    /// Steps an orb on its own clock, as the display link would, until `done` or `seconds` pass.
    private func run(_ orb: OrbAnimationView, seconds: Double, from start: Double = 100) {
        var time = start
        while time < start + seconds {
            time += 0.05
            orb.stepIfDue(at: time)
        }
    }

    // MARK: Driver

    @Test func theLinkPausesWhenNoOrbRunsAndResumesWhenOneDoes() throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let first = orb()
        content.addSubview(first)
        let win = window(content)
        defer { close(win) }

        let driver = try #require(OrbDriver.driver(for: win))
        #expect(driver.orbCount == 1)
        #expect(first.isRunning)
        #expect(!driver.isLinkPaused)

        // Paused: it eases into its resting pose, and then the link stops.
        first.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: false)
        run(first, seconds: 8)
        #expect(!first.isRunning)
        #expect(driver.isLinkPaused)

        first.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: true)
        #expect(first.isRunning)
        #expect(!driver.isLinkPaused)
    }

    @Test func theLinkRunsAtARateEveryRunningOrbDivides() throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let a = orb(), b = orb(frame: NSRect(x: 60, y: 10, width: 30, height: 30))
        content.addSubview(a)
        content.addSubview(b)
        let win = window(content)
        defer { close(win) }
        let driver = try #require(OrbDriver.driver(for: win))

        driver.refresh()
        let rates = [a, b].filter(\.isRunning).map(\.frameRate)
        #expect(!rates.isEmpty)
        #expect(rates.allSatisfy { driver.rate / $0 == (driver.rate / $0).rounded() })
        #expect(driver.rate == OrbLinkRate.rate(forOrbsAt: rates))
    }

    @Test func removingTheLastOrbDropsTheDriver() throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let first = orb()
        content.addSubview(first)
        let win = window(content)
        defer { close(win) }
        let driver = try #require(OrbDriver.driver(for: win))
        #expect(driver.orbCount == 1)
        #expect(OrbDriver.driverCount == 1)

        first.removeFromSuperview()
        #expect(driver.orbCount == 0)
        #expect(driver.isLinkPaused)
        #expect(OrbDriver.driverCount == 0)

        // A stopped orb (dismantled by SwiftUI) leaves too.
        let second = orb()
        content.addSubview(second)
        let again = try #require(OrbDriver.driver(for: win))
        #expect(again.orbCount == 1)
        second.stop()
        #expect(OrbDriver.driverCount == 0)
    }

    // MARK: Scrolling and visibility

    private func scrollView(orbAt y: CGFloat, live: Bool) -> (NSScrollView, OrbAnimationView) {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        let document = Flipped(frame: NSRect(x: 0, y: 0, width: 120, height: 2000))
        scroll.documentView = document
        let view = orb(live: live, frame: NSRect(x: 10, y: y, width: 30, height: 30))
        document.addSubview(view)
        return (scroll, view)
    }

    @Test func anOrbScrolledOutOfSightStopsAndComesBackOnScroll() throws {
        try #require(hasScreen)
        let (scroll, view) = scrollView(orbAt: 1500, live: true)
        let win = window(scroll, size: 200)
        defer { close(win) }

        #expect(!view.isRunning)
        #expect(view.isWatchingForReturn)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1450))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(view.isRunning)
        #expect(!view.isWatchingForReturn)

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(!view.isRunning)
        #expect(view.isWatchingForReturn)
    }

    @Test func anOrbThatWouldNotRunAnywayDoesNotWatchForItsReturn() throws {
        try #require(hasScreen)
        // Paused and already at rest (an idle, unselected sidebar row): nothing to come back to.
        let (restingScroll, resting) = scrollView(orbAt: 1500, live: false)
        let win = window(restingScroll, size: 200)
        defer { close(win) }
        #expect(!resting.isRunning)
        #expect(!resting.isWatchingForReturn)

        // A working one out of sight does watch, until it is hidden or goes away.
        let (scroll, working) = scrollView(orbAt: 1500, live: true)
        let second = window(scroll, size: 200)
        defer { close(second) }
        #expect(working.isWatchingForReturn)
        working.isHidden = true
        #expect(!working.isWatchingForReturn)
        working.isHidden = false
        #expect(working.isWatchingForReturn)
        working.removeFromSuperview()
        #expect(!working.isWatchingForReturn)
    }

    // MARK: Background bitmaps

    @Test func layersAppearOnceTheirBitmapsAreDecoded() async throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        // A size no other test uses, so the cache starts cold.
        let view = orb(live: false, size: 37, frame: NSRect(x: 10, y: 10, width: 37, height: 37))
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        #expect(view.placedLayerCount == 0)
        for _ in 0..<100 where view.placedLayerCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.placedLayerCount > 0)
    }

    @Test func aPendingLoadForAnOrbThatLeftTheWindowIsHarmless() async throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = orb(live: false, size: 39, frame: NSRect(x: 10, y: 10, width: 39, height: 39))
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(600))
        #expect(view.placedLayerCount == 0)
        #expect(OrbDriver.driverCount == 0)
    }

    @Test func aStaleRequestIsDiscarded() async throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = orb(live: false, size: 41, frame: NSRect(x: 10, y: 10, width: 41, height: 41))
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        // The activity changes while the first expression is still decoding: only the last request rebuilds.
        view.configure(config: OrbConfig(), activity: .thinking, size: 41, followsPointer: false, interactive: false, live: false)
        view.configure(config: OrbConfig(), activity: .happy, size: 41, followsPointer: false, interactive: false, live: false)
        for _ in 0..<100 where view.placedLayerCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(view.placedLayerCount > 0)
    }

    // MARK: Whole sets only

    @Test func theCanvasNeverDrawsAPartOfASet() async {
        let body = OrbLayer(kind: .body, path: "body/perola", tint: nil)
        let eyes = OrbLayer(kind: .eyes, path: "eyes/pontos", tint: nil)
        let old = OrbFrame.Bitmaps(layers: [body], pixels: 161)
        let wanted = OrbFrame.Bitmaps(layers: [body, eyes], pixels: 161)
        guard !OrbImages.decodesSynchronously else { return }
        // Nothing decoded: nothing to draw.
        #expect(OrbFrame.drawable(wanted: wanted, complete: nil).isEmpty)
        // The body is there but not the eyes: the last complete set stays (or nothing), never body alone.
        await OrbImages.load([body], pixels: 161)
        #expect(OrbFrame.drawable(wanted: wanted, complete: nil).isEmpty)
        #expect(OrbFrame.drawable(wanted: wanted, complete: old) == [body])
        // Another pixel size cannot stand in.
        #expect(OrbFrame.drawable(wanted: wanted, complete: OrbFrame.Bitmaps(layers: [body], pixels: 99)).isEmpty)
        await OrbImages.load([eyes], pixels: 161)
        #expect(OrbFrame.drawable(wanted: wanted, complete: old) == [body, eyes])
    }

    // MARK: Shimmer

    @Test func theShimmerStopsWhenHiddenAndResumes() throws {
        try #require(hasScreen)
        let band = ShimmerBandView(fillsBackground: true)
        band.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.addSubview(band)
        let win = window(content)
        defer { close(win) }
        band.layoutSubtreeIfNeeded()
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        #expect(band.isSweeping)
        band.isHidden = true
        #expect(!band.isSweeping)
        band.isHidden = false
        #expect(band.isSweeping)
        band.removeFromSuperview()
        #expect(!band.isSweeping)
    }
}
