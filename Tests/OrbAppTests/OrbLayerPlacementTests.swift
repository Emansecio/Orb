import AppKit
import QuartzCore
import Testing
@testable import Orb

/// Where the live orb puts its layers when it is rebuilt: the body (placed only then) and the loose layers (hair and
/// hats, rotated only when their swing changes), with real views in a real window. Part of `OrbDriverTests` so it runs
/// serialized with it: every orb on a screen shares one driver, and those tests count its orbs.
extension OrbDriverTests {
    private func placementWindow(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        OrbView.animateInactive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        // On screen for the driver, but never seen: no title bar, fully transparent, and clicks go through.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    private func closePlacement(_ window: NSWindow) {
        window.contentView = NSView()
        window.orderOut(nil)
    }

    private func layers(_ view: OrbAnimationView, _ kind: OrbLayer.Kind) -> [CALayer] {
        view.placedLayersForTesting.filter { $0.layer.kind == kind }.map(\.view)
    }

    @Test func theBodyIsPlacedAgainWhenTheSizeChanges() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let look = OrbConfig(hair: "franja")
        view.configure(config: look, activity: .idle, size: 33, followsPointer: false, interactive: false, live: false)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        let scale = win.backingScaleFactor
        for size: CGFloat in [33, 71] {
            view.configure(config: look, activity: .idle, size: size, followsPointer: false, interactive: false, live: false)
            let side = OrbGeometry.imageSide(for: size, scale: scale)
            await waitUntil("layers at \(size) pt") { layers(view, .body).first?.bounds.width == side }
            let body = try #require(layers(view, .body).first)
            #expect(body.position == CGPoint(x: side / 2, y: side / 2), "\(size) pt")
        }
    }

    @Test func aResizeKeepsTheLayersOnScreenAndNeverDecodesOnTheMainThread() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let look = OrbConfig(hair: "franja")
        view.configure(config: look, activity: .idle, size: 31, followsPointer: false, interactive: false, live: false)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        await waitUntil("the first layers") { view.placedLayerCount > 0 }
        let scale = win.backingScaleFactor
        // A size nothing else draws, so its bitmaps start out missing (when a test running alongside warmed them
        // up, they show at once: the main thread still must not decode).
        for size: CGFloat in [57, 34] {
            let decoded = OrbImages.mainThreadDecodes
            let before = layers(view, .body).first
            view.configure(config: look, activity: .idle, size: size, followsPointer: false, interactive: false, live: false)
            let side = OrbGeometry.imageSide(for: size, scale: scale)
            #expect(OrbImages.mainThreadDecodes == decoded, "\(size) pt")
            // The old bitmaps stand in, already at the new geometry...
            #expect(view.placedLayerCount > 0)
            #expect(layers(view, .body).first?.bounds.width == side, "\(size) pt")
            // ...until the new ones arrive.
            await waitUntil("the layers at \(size) pt") { OrbImages.isCached(view.placedLayersForTesting.map(\.layer), pixels: side * scale) }
            // ...and then they replace the old ones.
            await waitUntil("the new layers to be swapped in") { layers(view, .body).first !== before }
            #expect(layers(view, .body).first?.bounds.width == side)
        }
    }

    @Test func aTalkingMouthIsRedrawnAtTheNewSizeAfterAResizeWhileTalking() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let look = OrbConfig(mouth: "sorriso")
        view.configure(config: look, activity: .speaking, size: 29, followsPointer: false, interactive: false, live: true)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        await waitUntil("the first layers") { view.placedLayerCount > 0 }
        let narrow = OrbGeometry.imageSide(for: 29, scale: win.backingScaleFactor) * win.backingScaleFactor
        await waitUntil("the talking mouth shapes") { OrbImages.isCached(Array(look.visemeLayers()!.values), pixels: narrow) }
        var time = CACurrentMediaTime()
        func step(_ frames: Int) {
            for _ in 0..<frames {
                time += 1.0 / 30
                view.stepIfDue(at: time)
            }
        }
        step(20)
        // Frames keep running while the new bitmaps are decoded: they must not leave old-size mouth shapes behind.
        let size: CGFloat = 63
        let wide = OrbImages.bitmapSide(for: OrbGeometry.imageSide(for: size, scale: win.backingScaleFactor) * win.backingScaleFactor)
        let before = layers(view, .body).first
        view.configure(config: look, activity: .speaking, size: size, followsPointer: false, interactive: false, live: true)
        step(30)   // before the new bitmaps can arrive: the main thread has not yet yielded
        await waitUntil("the new layers to be swapped in") {
            step(1)
            return layers(view, .body).first !== before
        }
        // Whatever mouth shape shows from now on has the new size.
        for _ in 0..<60 {
            step(1)
            let width = (layers(view, .mouth).first?.contents as! CGImage?)?.width
            #expect(width == wide)
        }
    }

    @Test func aRestingOrbShowsTheBubbleOfItsNewActivity() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 60, height: 60))
        func configure(_ activity: OrbActivity, live: Bool) {
            view.configure(config: OrbConfig(), activity: activity, size: 30, followsPointer: false, interactive: false, live: live)
        }
        configure(.thinking, live: true)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        await waitUntil("the layers") { view.placedLayerCount > 0 }
        var time = CACurrentMediaTime()
        func step(_ frames: Int) {
            for _ in 0..<frames {
                time += 1.0 / 30
                view.stepIfDue(at: time)
            }
        }
        step(30)
        // The window loses focus: the orb eases into its resting pose, thinking, and stops.
        configure(.thinking, live: false)
        step(150)
        try #require(!view.isRunning)
        #expect(view.isBubbleShown)
        // The turn ends while it rests: the face changes, and so must the bubble.
        configure(.idle, live: false)
        await waitUntil("the bubble to go") { !view.isBubbleShown }
        // ...and the next one asks for approval.
        configure(.waiting, live: false)
        await waitUntil("the question mark") { view.isBubbleShown }
        #expect(!view.isRunning)
    }

    @Test func aSelectedOrbGlancesOnlyWhileLiveAndThenSettles() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 60, height: 60))
        view.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: false)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        view.glanceNow()
        #expect(!view.isGlancing) // a paused orb would replay a stale glance when it wakes up
        view.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: true)
        view.glanceNow()
        #expect(view.isGlancing && view.frameRate >= 30)
        var time = CACurrentMediaTime()
        for _ in 0..<30 {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        #expect(!view.isGlancing)
    }

    /// A live orb in a window, and the way to configure it again.
    private func reactionOrb(live: Bool = true, size: CGFloat = 30, activity: OrbActivity = .idle) -> (view: OrbAnimationView, window: NSWindow) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 60, height: 60))
        view.configure(config: OrbConfig(), activity: activity, size: size, followsPointer: false, interactive: true, live: live)
        content.addSubview(view)
        return (view, placementWindow(content))
    }

    private func configure(_ view: OrbAnimationView, _ activity: OrbActivity, celebration: OrbCelebration = .big, live: Bool = true) {
        view.configure(config: OrbConfig(), activity: activity, celebration: celebration, size: 30, followsPointer: false,
                       interactive: true, live: live)
    }

    /// Steps the orb on a synthetic clock from `start`, 30 frames a second.
    private func step(_ view: OrbAnimationView, from start: Double, seconds: Double) -> Double {
        var time = start
        for _ in 0..<Int(seconds * 30) {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        return time
    }

    @Test func anOrbThatAppearsInTheErrorWaitingOrHappyStateDrawsFiniteFrames() async throws {
        try #require(NSScreen.main != nil)
        for activity in [OrbActivity.error, .waiting, .happy] {
            let (view, win) = reactionOrb(activity: activity)
            defer { closePlacement(win) }
            _ = step(view, from: CACurrentMediaTime(), seconds: 1)
            for item in view.placedLayersForTesting {
                #expect(item.view.position.x.isFinite && item.view.position.y.isFinite, "\(activity)")
            }
        }
    }

    @Test func aSecondGlanceRightAfterTheFirstIsIgnored() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb()
        defer { closePlacement(win) }
        view.glanceNow()
        #expect(view.isGlancing)
        _ = step(view, from: CACurrentMediaTime(), seconds: 1)
        #expect(!view.isGlancing)
        view.glanceNow() // less than 1.2 s after the first (the test's clock is the real one for the call)
        #expect(!view.isGlancing)
    }

    @Test func toolsInARowKeepTheirPoseThroughAShortThought() async throws {
        try #require(NSScreen.main != nil)
        // The tool ends and the model thinks: still the terminal for a while, then thinking for real.
        let (view, win) = reactionOrb(activity: .typing)
        defer { closePlacement(win) }
        #expect(view.shownForTesting.activity == .typing)
        configure(view, .thinking)
        let time = step(view, from: CACurrentMediaTime(), seconds: 0.3)
        #expect(view.shownForTesting.activity == .typing)
        _ = step(view, from: time, seconds: 0.5)
        #expect(view.shownForTesting.activity == .thinking)

        // The next tool comes in at once, and the pause leaves nothing behind.
        let (second, secondWindow) = reactionOrb(activity: .typing)
        defer { closePlacement(secondWindow) }
        configure(second, .thinking)
        configure(second, .reading)
        #expect(second.shownForTesting.activity == .reading)

        // Urgent changes never wait.
        let (third, thirdWindow) = reactionOrb(activity: .typing)
        defer { closePlacement(thirdWindow) }
        configure(third, .waiting)
        #expect(third.shownForTesting.activity == .waiting)
    }

    @Test func aClickMakesOnlyACalmOrbSmile() async throws {
        try #require(NSScreen.main != nil)
        func click(on view: OrbAnimationView) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            if let event { view.mouseDown(with: event) }
        }
        for calm in [OrbActivity.idle, .attentive, .listening, .speaking] {
            let (view, win) = reactionOrb(activity: calm)
            defer { closePlacement(win) }
            click(on: view)
            #expect(view.shownForTesting.activity == .happy && view.shownForTesting.celebration == .smile, "\(calm)")
            #expect(view.currentJumpForTesting == .play) // the body keeps the click's jump, but not the hops of joy
        }
        for busy in [OrbActivity.thinking, .typing, .waiting, .error] {
            let (view, win) = reactionOrb(activity: busy)
            defer { closePlacement(win) }
            click(on: view)
            #expect(view.shownForTesting.activity == busy, "\(busy)")
            #expect(view.currentJumpForTesting == .play)
        }
    }

    /// Steps the orb until it stops running, or `seconds` pass; returns the seconds it took.
    private func stepUntilItRests(_ view: OrbAnimationView, from start: Double, seconds: Double = 3) -> Double {
        var time = start
        while view.isRunning && time - start < seconds {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        return time - start
    }

    @Test func aSmileThatOutlastsTheSettlingDoesNotFreezeOnTheFace() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb()
        defer { closePlacement(win) }
        // Working for a while first: a new orb starts at rest and would have nothing to settle.
        let start = step(view, from: CACurrentMediaTime() - 1, seconds: 1)   // ends at about the real clock, where the click is
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        view.mouseDown(with: try #require(event))
        #expect(view.shownForTesting.activity == .happy)
        // The window goes inactive right after the click: the orb settles in about half a second, inside the 1.4 s smile.
        configure(view, .idle, live: false)
        let took = stepUntilItRests(view, from: start)
        #expect(!view.isRunning)
        #expect(took > 0 && took < OrbCelebration.smile.seconds - 0.3, "the settling must end before the smile would")
        #expect(view.shownForTesting.activity == .idle)
    }

    @Test func aHeldToolPoseDoesNotFreezeWhenTheOrbSettlesBeforeItEnds() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb(activity: .typing)
        defer { closePlacement(win) }
        let time = step(view, from: CACurrentMediaTime() - 1, seconds: 1)   // ends at about the real clock
        // The tool ends and the model thinks, and the window goes inactive at once: the pose is held for 0.6 s.
        configure(view, .thinking, live: false)
        #expect(view.shownForTesting.activity == .typing)
        let took = stepUntilItRests(view, from: time)
        #expect(!view.isRunning)
        #expect(took > 0 && took < OrbActivityHold.wait, "the settling must end before the hold would")
        #expect(view.shownForTesting.activity == .thinking)
    }

    @Test func theCelebrationOnScreenFollowsTheLevelAndCanGrow() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb()
        defer { closePlacement(win) }
        configure(view, .happy, celebration: .light)
        #expect(view.shownForTesting == (.happy, .light))
        // A bigger celebration while still happy takes over (it blends from the smaller one).
        configure(view, .happy, celebration: .big)
        #expect(view.shownForTesting == (.happy, .big))
        configure(view, .idle)
        #expect(view.shownForTesting.activity == .idle)
    }

    @Test func eachJumpKindPlaysAndEndsOnItsOwn() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb()
        defer { closePlacement(win) }
        let start = CACurrentMediaTime()
        view.jumpNow(.ack)
        #expect(view.currentJumpForTesting == .ack)
        var time = step(view, from: start, seconds: 0.2)
        #expect(view.currentJumpForTesting == .ack)
        time = step(view, from: time, seconds: 0.3)
        #expect(view.currentJumpForTesting == nil) // 0.35 s
        view.jumpNow(.landing)
        #expect(view.currentJumpForTesting == .landing)
        _ = step(view, from: time, seconds: 0.5)
        #expect(view.currentJumpForTesting == nil)
        // A paused orb jumps for nobody.
        configure(view, .idle, live: false)
        _ = step(view, from: time, seconds: 9)
        view.jumpNow(.play)
        #expect(view.currentJumpForTesting == nil)
    }

    @Test func aCueBlinksOrSighsWhileTheOrbIsStillMovingAndNotAtRest() async throws {
        try #require(NSScreen.main != nil)
        let (view, win) = reactionOrb()
        defer { closePlacement(win) }
        view.cueNow(.blink)
        #expect(view.isCueBlinking && view.frameRate >= 30)
        var time = step(view, from: CACurrentMediaTime(), seconds: 0.5)
        #expect(!view.isCueBlinking) // one blink
        view.cueNow(.sigh)
        #expect(view.currentFlourishForTesting == .sigh)
        // The turn that ended is what lets the avatar rest: the cue still shows while it settles...
        configure(view, .idle, live: false)
        view.cueNow(.blink)
        #expect(view.isCueBlinking)
        // ...but one that is already at rest has no one watching.
        time = step(view, from: time, seconds: 9)
        #expect(!view.isRunning)
        view.cueNow(.blink)
        #expect(!view.isCueBlinking)
    }

    @Test func looseLayersHangFromTheCrownAndSwingTogetherAfterARebuild() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let tail = OrbConfig(hair: "rabo-de-cavalo")
        view.configure(config: tail, activity: .happy, size: 64, followsPointer: false, interactive: false, live: true)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        await waitUntil("the hair placed") { !layers(view, .hair).isEmpty }
        // Hop for a while, so the hair swings.
        var time = CACurrentMediaTime()
        for _ in 0..<45 {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        // A bow joins the loose layers: a rebuild in the middle of the swing.
        view.configure(config: OrbConfig(hair: "rabo-de-cavalo", accessories: ["laco"]), activity: .happy, size: 64,
                       followsPointer: false, interactive: false, live: true)
        await waitUntil("the bow placed") { !layers(view, .accessory).isEmpty }
        time += 1.0 / 30
        view.stepIfDue(at: time)
        let loose = view.placedLayersForTesting.filter { $0.layer.isLoose }.map(\.view)
        #expect(loose.count == 3)   // hair, its shine, the bow
        let crown = 1 - OrbGeometry.crownLine
        #expect(loose.allSatisfy { abs($0.anchorPoint.y - crown) < 1e-9 && $0.anchorPoint.x == 0.5 })
        let first = try #require(loose.first).transform
        #expect(loose.allSatisfy { CATransform3DEqualToTransform($0.transform, first) })
        // The rest of the face doesn't swing.
        #expect(layers(view, .eyes).allSatisfy { $0.anchorPoint.y == 1 - OrbGeometry.eyeLine })
    }
}
