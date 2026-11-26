import Testing
import AppKit
import Foundation
@testable import Orb
import SwiftUI

/// The shared display link, the visibility rules and the shimmer band, with real views in a real window.
/// (They need a screen: without one they do nothing.)
@Suite(.serialized) @MainActor
struct OrbDriverTests {
    // MARK: Link rate

    @Test func linkRunsAtTheLowestRateEveryOrbDivides() {
        #expect(OrbLinkRate.rate(forOrbsAt: []) == 30)
        #expect(OrbLinkRate.rate(forOrbsAt: [30]) == 30)
        #expect(OrbLinkRate.rate(forOrbsAt: [30, 60]) == 60)
        #expect(OrbLinkRate.rate(forOrbsAt: [60]) == 60)
        // A rate not set yet does not matter.
        #expect(OrbLinkRate.rate(forOrbsAt: [0, 30]) == 30)
        #expect(OrbLinkRate.rate(forOrbsAt: [0]) == 30)
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
            let link = OrbLinkRate.rate(forOrbsAt: [a, b])
            for rate in [a, b] {
                // What the orb really steps at on that link (a rate the link does not divide takes the next one up).
                let stepped = OrbLinkRate.stepRate(rate, onLink: link)
                let gaps = intervals(rate: stepped, linkRate: Double(link))
                let expected = 1 / Double(stepped)
                #expect(!gaps.isEmpty)
                #expect(gaps.allSatisfy { abs($0 - expected) < 0.002 }, "\(rate) fps (\(stepped)) on a \(link) Hz link: \(gaps.prefix(6))")
                #expect(stepped >= rate && stepped <= link, "an orb is never slowed down, nor stepped faster than the link")
            }
        } }
    }

    @Test func stepRateNeverSlowsAnOrbAndTheLinkOnlyReachesSixtyForAnOrbAtSixty() {
        let rates = OrbFrameRate.steps
        for a in rates { for b in rates { for c in rates {
            let link = OrbLinkRate.rate(forOrbsAt: [a, b, c])
            if max(a, b, c) <= 30 { #expect(link <= 30, "\(a), \(b), \(c) fps do not need a 60 Hz link") }
            for rate in [a, b, c] {
                let stepped = OrbLinkRate.stepRate(rate, onLink: link)
                #expect(stepped >= rate)
                #expect(abs(link / stepped - (link / stepped).rounded()) < 0.01)
            }
        } } }
        #expect(OrbLinkRate.stepRate(30, onLink: 30) == 30)
        #expect(OrbLinkRate.stepRate(30, onLink: 60) == 30)
        #expect(OrbLinkRate.stepRate(60, onLink: 60) == 60)
        #expect(OrbLinkRate.stepRate(0, onLink: 30) == 30)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        // On screen for the driver, but never seen: no title bar, fully transparent, and clicks go through.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
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

    private func setActivity(_ activity: OrbActivity, on view: OrbAnimationView, live: Bool = true) {
        view.configure(config: OrbConfig(), activity: activity, size: 30, followsPointer: false, interactive: false, live: live)
    }

    @Test func kicksDoNotPileUpWhileAnOrbShowsNoFrames() throws {
        try #require(hasScreen)
        // Hidden (a minimized or hidden window) but not at rest: the task goes on, speech then tool, over and over.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let hidden = orb()
        content.addSubview(hidden)
        let win = window(content)
        defer { close(win) }
        run(hidden, seconds: 1)
        hidden.isHidden = true
        #expect(!hidden.isRunning)
        for _ in 0..<40 {
            setActivity(.speaking, on: hidden)
            setActivity(.typing, on: hidden)
        }
        #expect(hidden.wobbleVelocityForTesting <= 0.5, "\(hidden.wobbleVelocityForTesting)")

        // Scrolled out of sight, in a scroll view.
        let (scroll, away) = scrollView(orbAt: 1500, live: true)
        let second = window(scroll, size: 200)
        defer { close(second) }
        #expect(!away.isRunning)
        for _ in 0..<40 {
            setActivity(.speaking, on: away)
            setActivity(.typing, on: away)
        }
        #expect(away.wobbleVelocityForTesting <= 0.5, "\(away.wobbleVelocityForTesting)")
    }

    @Test func aVisibleOrbStillWobblesWhenItGetsMoreStirredUp() throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = orb()
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        run(view, seconds: 1)
        setActivity(.speaking, on: view)
        let before = view.wobbleVelocityForTesting
        setActivity(.typing, on: view)
        #expect(view.wobbleVelocityForTesting > before)
    }

    @Test func anOrbPausedOutOfSightRestsAtOnceAndStopsWatching() throws {
        try #require(hasScreen)
        let (scroll, view) = scrollView(orbAt: 1500, live: true)
        let win = window(scroll, size: 200)
        defer { close(win) }
        // It works in view for a while (so it is far from rest), then is scrolled away.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1450))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(view.isRunning)
        run(view, seconds: 2)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(!view.isRunning)
        #expect(view.isWatchingForReturn)

        // Paused while out of sight: no frames will ever settle it, so it rests on the spot and the timer goes away.
        setActivity(.idle, on: view, live: false)
        #expect(!view.isWatchingForReturn)
        #expect(!view.isRunning)

        // Live again (selected), still away: it watches for its return again.
        setActivity(.idle, on: view, live: true)
        #expect(view.isWatchingForReturn)
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
        // Usually nothing is placed yet (cold cache); a test running alongside may have warmed these bitmaps already,
        // which only means they show at once. Either way they must end up on screen.
        await waitUntil("the decoded layers to be placed") { view.placedLayerCount > 0 }
    }

    @Test func aPendingLoadForAnOrbThatLeftTheWindowIsHarmless() async throws {
        try #require(hasScreen)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = orb(live: false, size: 39, frame: NSRect(x: 10, y: 10, width: 39, height: 39))
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        // With the bitmaps already cached by a test running alongside, the layers are placed at once and there is no
        // pending load to test: only the case this test is about is checked.
        let wasPending = view.placedLayerCount == 0
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(600))
        if wasPending { #expect(view.placedLayerCount == 0) }
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
        let body = OrbLayer(kind: .body, path: "body/perola")
        let eyes = OrbLayer(kind: .eyes, path: "eyes/pontos")
        let wanted = OrbFrame.Bitmaps(layers: [body, eyes], pixels: 161)
        guard !OrbImages.decodesSynchronously else { return }
        func layers(_ drawn: [OrbFrame.Drawn]) -> [OrbLayer] { drawn.map(\.layer) }
        // Nothing decoded: nothing to draw.
        #expect(OrbFrame.drawable(wanted: wanted, complete: nil).isEmpty)
        // The body is there but not the eyes: the last complete set stays (or nothing), never body alone.
        await OrbImages.load([body], pixels: 161)
        #expect(OrbFrame.drawable(wanted: wanted, complete: nil).isEmpty)
        let oldImages = OrbImages.cachedImages([body], pixels: 161)
        let old = oldImages.map { OrbFrame.Complete(bitmaps: OrbFrame.Bitmaps(layers: [body], pixels: 161), images: $0) }
        #expect(old != nil)
        #expect(layers(OrbFrame.drawable(wanted: wanted, complete: old)) == [body])
        // Another pixel size cannot stand in.
        let other = oldImages.map { OrbFrame.Complete(bitmaps: OrbFrame.Bitmaps(layers: [body], pixels: 99), images: $0) }
        #expect(OrbFrame.drawable(wanted: wanted, complete: other).isEmpty)
        await OrbImages.load([eyes], pixels: 161)
        let whole = OrbFrame.drawable(wanted: wanted, complete: old)
        #expect(layers(whole) == [body, eyes])
        #expect(whole.allSatisfy { $0.image != nil })
    }

    @Test func aStillOrbKeepsItsFaceWhenTheCacheDropsItsBitmaps() async throws {
        let body = OrbLayer(kind: .body, path: "body/perola")
        let eyes = OrbLayer(kind: .eyes, path: "eyes/pontos")
        guard !OrbImages.decodesSynchronously else { return }
        // A pixel size no other test draws, so evicting does not disturb them.
        let wanted = OrbFrame.Bitmaps(layers: [body, eyes], pixels: 163)
        await OrbImages.load(wanted.layers, pixels: 163)
        let images = try #require(OrbImages.cachedImages(wanted.layers, pixels: 163))
        let complete = OrbFrame.Complete(bitmaps: wanted, images: images)

        // The editor filled the cache and the byte limit dropped them: the orb on screen still draws its whole set.
        OrbImages.evictForTesting(wanted.layers, pixels: 163)
        #expect(OrbImages.cachedImages(wanted.layers, pixels: 163) == nil)
        let drawn = OrbFrame.drawable(wanted: wanted, complete: complete)
        #expect(drawn.map(\.layer) == [body, eyes])
        #expect(drawn.allSatisfy { $0.image != nil })

        // A different expression asked for while they are gone: still the last whole face, never a part of anything.
        let smiling = OrbFrame.Bitmaps(layers: [body, OrbLayer(kind: .eyes, path: "eyes/felizes")], pixels: 163)
        #expect(OrbFrame.drawable(wanted: smiling, complete: complete).map(\.layer) == [body, eyes])
        #expect(OrbFrame.drawable(wanted: smiling, complete: nil).isEmpty)
    }

    // MARK: Shimmer

    @Test func typingDotsStopOutsideTheViewportAndWhenHidden() throws {
        try #require(hasScreen)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        final class Document: NSView { override var isFlipped: Bool { true } }
        let document = Document(frame: NSRect(x: 0, y: 0, width: 120, height: 2000))
        scroll.documentView = document
        let dots = WizardTypingDotsView(animated: true)
        dots.frame = NSRect(x: 10, y: 1500, width: 36, height: 20)
        document.addSubview(dots)
        let win = window(scroll, size: 200)
        defer { close(win) }
        dots.layoutSubtreeIfNeeded()
        #expect(!dots.isAnimating)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1450))
        #expect(dots.isAnimating)
        dots.isHidden = true
        #expect(!dots.isAnimating)
        dots.isHidden = false
        #expect(dots.isAnimating)
        scroll.contentView.scroll(to: .zero)
        #expect(!dots.isAnimating)
        dots.removeFromSuperview()
        #expect(!dots.isAnimating)
    }

    @Test func hiddenStreamingTextDoesNotCreateTemporaryFadeColours() throws {
        try #require(hasScreen)
        let view = ProseTextView()
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 80)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.addSubview(view)
        let win = window(content)
        defer { close(win) }
        view.isHidden = true
        view.show(ProseText.make([.paragraph("Texto fora da tela")], cursor: true, cached: false, highlight: nil),
                  cursor: true, fades: true)
        let index = (view.string as NSString).range(of: "tela").location
        #expect(view.layoutManager?.temporaryAttributes(atCharacterIndex: index, effectiveRange: nil)[.foregroundColor] == nil)
    }

    @Test func theShimmerStopsScrolledOutOfSightAndResumes() throws {
        try #require(hasScreen)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        final class FlippedDoc: NSView { override var isFlipped: Bool { true } }
        let document = FlippedDoc(frame: NSRect(x: 0, y: 0, width: 120, height: 2000))
        scroll.documentView = document
        let band = ShimmerBandView()
        band.frame = NSRect(x: 10, y: 1500, width: 100, height: 20)
        document.addSubview(band)
        let win = window(scroll, size: 200)
        defer { close(win) }
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        #expect(!band.isSweeping)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1450))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(band.isSweeping)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(!band.isSweeping)
    }

    @Test func outOfViewOrbsShareOneTimer() throws {
        try #require(hasScreen)
        let (scrollA, a) = scrollView(orbAt: 1500, live: true)
        let (scrollB, b) = scrollView(orbAt: 1600, live: true)
        let winA = window(scrollA, size: 200)
        let winB = window(scrollB, size: 200)
        defer { close(winA); close(winB) }
        #expect(a.isWatchingForReturn && b.isWatchingForReturn)
        #expect(OrbReturnWatch.shared.isTimerOn)
        scrollA.contentView.scroll(to: NSPoint(x: 0, y: 1450))
        scrollA.reflectScrolledClipView(scrollA.contentView)
        #expect(!a.isWatchingForReturn && b.isWatchingForReturn)
        #expect(OrbReturnWatch.shared.isTimerOn)
    }

    @Test func theShimmerStopsWhenHiddenAndResumes() throws {
        try #require(hasScreen)
        let band = ShimmerBandView()
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

    @Test func aRunningCommandBreathesOnlyWhileItIsSeen() throws {
        try #require(hasScreen)
        let band = ShimmerBandView()
        band.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        content.addSubview(band)
        let win = window(content)
        defer { close(win) }
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        #expect(band.isSweeping && !band.isPulsing)
        band.pulses = true
        #expect(band.isPulsing)
        band.isHidden = true
        #expect(!band.isPulsing)
        band.isHidden = false
        #expect(band.isPulsing)
        band.pulses = false
        #expect(!band.isPulsing && band.isSweeping)
    }
}

// MARK: - VisualPolishTests

/// Part of `OrbDriverTests` so it runs serialized with it: its window puts avatars on screen, and those tests count
/// the orbs of the one shared driver (in a suite of its own the two ran side by side and those counts went wrong).
extension OrbDriverTests {
    @Test func choosingAGroupDoesNotKeepIdleAvatarsRenderingForever() async throws {
        let root = TempFolder("OrbVisualPolish")
        _ = NSApplication.shared
        try #require(NSScreen.main != nil)
        let previous = OrbView.animateInactive
        OrbView.animateInactive = true
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false)
        let host = NSHostingView(rootView: NewGroupSheet().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
            OrbView.animateInactive = previous
        }
        func avatars(in view: NSView) -> [OrbAnimationView] {
            (view as? OrbAnimationView).map { [$0] } ?? view.subviews.flatMap(avatars)
        }
        // Under Reduce Motion (the CI's runner has it on) the choices are still pictures: no animated avatar to wait for.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            await waitUntil("the group picker's initial animation") { avatars(in: host).contains(where: \.isRunning) }
        }
        let settled = await waitUntil("idle choices to settle", timeout: .seconds(12)) {
            let shown = avatars(in: host)
            return (reduceMotion || !shown.isEmpty) && shown.allSatisfy { !$0.isRunning }
        }
        if !settled {
            // What each avatar was doing: this is how the CI's Reduce Motion was found.
            let states = avatars(in: host).map { "live \($0.live) running \($0.isRunning) steps \($0.steps) fps \($0.frameRate)" }
            Issue.record("""
                \(states.count) avatars: \(states.joined(separator: "; ")); reduce motion \
                \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); screen \(NSScreen.main?.frame ?? .zero) \
                @\(NSScreen.main?.backingScaleFactor ?? 0)x; window visible \(window.occlusionState.contains(.visible))
                """)
        }
    }
}
