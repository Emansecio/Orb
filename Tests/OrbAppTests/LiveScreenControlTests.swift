import AppKit
import Foundation
import Testing
@testable import Orb

// Taking the Orb's browser over in the live screen's window (docs/TELA-AO-VIVO.md, 7): where a click lands on the page, the
// messages the stream gets, the wait of the Orb's tools while the person has the browser, and what a protected page shows.

// MARK: - Where a click lands, and what is sent

struct LiveInputTests {
    private let image = CGSize(width: 960, height: 600)
    private let viewport = CGSize(width: 1280, height: 800)

    @Test func aClickOnThePictureLandsOnTheSamePlaceOfThePage() throws {
        // A layer exactly the picture's shape: corners and middle map to the viewport's.
        let layer = CGSize(width: 480, height: 300)
        #expect(LiveInput.pagePoint(.zero, layerSize: layer, imageSize: image, viewport: viewport) == .zero)
        #expect(LiveInput.pagePoint(CGPoint(x: 240, y: 150), layerSize: layer, imageSize: image, viewport: viewport)
                == CGPoint(x: 640, y: 400))
        #expect(LiveInput.pagePoint(CGPoint(x: 479, y: 299), layerSize: layer, imageSize: image, viewport: viewport)
                == CGPoint(x: 1277, y: 797))
        // The far edge is past the last pixel.
        #expect(LiveInput.pagePoint(CGPoint(x: 480, y: 150), layerSize: layer, imageSize: image, viewport: viewport) == nil)
    }

    @Test func aWideWindowLeavesBarsBesideThePictureThatAreNotThePage() throws {
        // 800 x 300: the picture is 480 wide, centered, so 160 points of bar on each side.
        let layer = CGSize(width: 800, height: 300)
        #expect(LiveInput.pagePoint(CGPoint(x: 100, y: 150), layerSize: layer, imageSize: image, viewport: viewport) == nil)
        #expect(LiveInput.pagePoint(CGPoint(x: 700, y: 150), layerSize: layer, imageSize: image, viewport: viewport) == nil)
        #expect(LiveInput.pagePoint(CGPoint(x: 160, y: 0), layerSize: layer, imageSize: image, viewport: viewport) == .zero)
        #expect(LiveInput.pagePoint(CGPoint(x: 400, y: 150), layerSize: layer, imageSize: image, viewport: viewport)
                == CGPoint(x: 640, y: 400))
        #expect(LiveInput.pixelsPerPointForTests(layer) == 1280.0 / 480)
    }

    @Test func aReleaseOffThePictureIsClampedToItsEdge() {
        let layer = CGSize(width: 800, height: 300)
        #expect(LiveInput.pagePoint(CGPoint(x: 100, y: 150), layerSize: layer, imageSize: image, viewport: viewport, clamped: true)
                == CGPoint(x: 0, y: 400))
        #expect(LiveInput.pagePoint(CGPoint(x: 5000, y: 9000), layerSize: layer, imageSize: image, viewport: viewport, clamped: true) != nil)
        #expect(LiveInput.pagePoint(.zero, layerSize: .zero, imageSize: image, viewport: viewport, clamped: true) == nil)
    }

    @Test func noPictureNoPoint() {
        #expect(LiveInput.pagePoint(.zero, layerSize: CGSize(width: 10, height: 10), imageSize: .zero, viewport: viewport) == nil)
        #expect(LiveInput.pagePoint(.zero, layerSize: .zero, imageSize: image, viewport: viewport) == nil)
        #expect(LiveInput.pagePoint(.zero, layerSize: CGSize(width: 10, height: 10), imageSize: image, viewport: .zero) == nil)
    }

    @Test func theWheelScrollsTheWayTheContentWasPushed() {
        // Content pushed up (negative) scrolls the page down (positive), in the page's pixels.
        let trackpad = LiveInput.wheelDelta(scrollingDeltaX: 0, scrollingDeltaY: -12, precise: true, pixelsPerPoint: 2)
        #expect(trackpad == CGVector(dx: 0, dy: 24))
        // A mouse wheel counts lines.
        let wheel = LiveInput.wheelDelta(scrollingDeltaX: 1, scrollingDeltaY: 3, precise: false, pixelsPerPoint: 1)
        #expect(wheel == CGVector(dx: -40, dy: -120))
    }

    @Test func mouseMessagesAreTheOnesTheStreamTakes() throws {
        let press = try object(LiveInput.mouse(.pressed, at: CGPoint(x: 100, y: 40), button: .left, clickCount: 2, modifiers: [.shift]))
        #expect(press["type"] as? String == "input_mouse" && press["eventType"] as? String == "mousePressed")
        #expect(press["x"] as? Double == 100 && press["y"] as? Double == 40)
        #expect(press["button"] as? String == "left" && press["clickCount"] as? Int == 2 && press["modifiers"] as? Int == 8)
        #expect(press["deltaY"] == nil)
        let wheel = try object(LiveInput.mouse(.wheel, at: .zero, button: .none, delta: CGVector(dx: 0, dy: 300)))
        #expect(wheel["eventType"] as? String == "mouseWheel" && wheel["deltaY"] as? Double == 300 && wheel["deltaX"] as? Double == 0)
    }

    @Test func aLetterIsTypedAsTheLayoutWroteIt() throws {
        let down = try object(#require(LiveInput.key(down: true, keyCode: 0, characters: "a", modifiers: [])))
        #expect(down["type"] as? String == "input_keyboard" && down["eventType"] as? String == "keyDown")
        #expect(down["key"] as? String == "a" && down["text"] as? String == "a" && down["windowsVirtualKeyCode"] as? Int == 65)
        let up = try object(#require(LiveInput.key(down: false, keyCode: 0, characters: "a", modifiers: [])))
        #expect(up["eventType"] as? String == "keyUp" && up["text"] == nil)
        // ABNT2's ç and an accented letter after its dead key come as the Mac typed them.
        let cedilla = try object(#require(LiveInput.key(down: true, keyCode: 41, characters: "ç", modifiers: [])))
        #expect(cedilla["text"] as? String == "ç" && cedilla["windowsVirtualKeyCode"] as? Int == 0)
        let capital = try object(#require(LiveInput.key(down: true, keyCode: 0, characters: "Á", modifiers: [.shift])))
        #expect(capital["text"] as? String == "Á" && capital["modifiers"] as? Int == 8)
        let space = try object(#require(LiveInput.key(down: true, keyCode: 49, characters: " ", modifiers: [])))
        #expect(space["code"] as? String == "Space" && space["text"] as? String == " " && space["windowsVirtualKeyCode"] as? Int == 32)
    }

    @Test func textKeysGoThroughTheTextInputSoDeadKeysCompose() throws {
        // Letters, the ABNT2 dead key (´ is keyCode 33 there) and Option combinations are composed by the Mac...
        #expect(LiveInput.usesTextInput(keyCode: 0, modifiers: []) && LiveInput.usesTextInput(keyCode: 33, modifiers: []))
        #expect(LiveInput.usesTextInput(keyCode: 0, modifiers: [.shift, .option]))
        // ...shortcuts and named keys are not.
        #expect(!LiveInput.usesTextInput(keyCode: 0, modifiers: [.command]) && !LiveInput.usesTextInput(keyCode: 0, modifiers: [.control]))
        #expect(!LiveInput.usesTextInput(keyCode: 36, modifiers: []) && !LiveInput.usesTextInput(keyCode: 123, modifiers: []))
        // What the input context hands back ("á" after ´ and a) is typed whole, once.
        let typed = try LiveInput.text("á").map { try object($0) }
        #expect(typed.count == 1 && typed[0]["text"] as? String == "á" && typed[0]["eventType"] as? String == "keyDown")
    }

    @Test func namedKeysGoByTheirNameAndEnterSubmits() throws {
        let enter = try object(#require(LiveInput.key(down: true, keyCode: 36, characters: "\r", modifiers: [])))
        #expect(enter["key"] as? String == "Enter" && enter["text"] as? String == "\r" && enter["windowsVirtualKeyCode"] as? Int == 13)
        let back = try object(#require(LiveInput.key(down: true, keyCode: 51, characters: "\u{7F}", modifiers: [])))
        #expect(back["key"] as? String == "Backspace" && back["text"] == nil && back["windowsVirtualKeyCode"] as? Int == 8)
        let left = try object(#require(LiveInput.key(down: true, keyCode: 123, characters: "\u{F702}", modifiers: [.shift])))
        #expect(left["key"] as? String == "ArrowLeft" && left["modifiers"] as? Int == 8)
        let tab = try object(#require(LiveInput.key(down: true, keyCode: 48, characters: "\t", modifiers: [])))
        #expect(tab["key"] as? String == "Tab" && tab["text"] == nil)
    }

    @Test func whatStaysWithTheApp() throws {
        // ⌘ shortcuts are the app's (⌘V pastes through `paste`); a dead key waiting for its letter and an unnamed function key send nothing.
        #expect(LiveInput.key(down: true, keyCode: 9, characters: "v", modifiers: [.command]) == nil)
        #expect(LiveInput.key(down: true, keyCode: 36, characters: "\r", modifiers: [.command]) == nil)
        #expect(LiveInput.key(down: true, keyCode: 39, characters: "", modifiers: []) == nil)
        #expect(LiveInput.key(down: true, keyCode: 122, characters: "\u{F704}", modifiers: []) == nil)
        #expect(LiveInput.key(down: true, keyCode: 0, characters: nil, modifiers: []) == nil)
        // ⌃A comes as a control character: nothing to type.
        #expect(LiveInput.key(down: true, keyCode: 0, characters: "\u{1}", modifiers: [.control]) == nil)
    }

    @Test func pastedTextIsTypedACharacterAtATimeWithLineBreaksAsEnter() throws {
        let keys = try LiveInput.text("ç\r\na").map(object)
        #expect(keys.count == 3)
        #expect(keys[0]["text"] as? String == "ç" && keys[0]["eventType"] as? String == "keyDown")
        #expect(keys[1]["key"] as? String == "Enter" && keys[1]["text"] as? String == "\r")
        #expect(keys[2]["text"] as? String == "a" && keys[2]["windowsVirtualKeyCode"] as? Int == 65)
        #expect(LiveInput.text("").isEmpty)
        // Control characters are left out, and a huge paste stops at the limit.
        #expect(LiveInput.text("a\u{7}b").count == 2)
        #expect(LiveInput.text(String(repeating: "x", count: LiveInput.pasteLimit + 50)).count == LiveInput.pasteLimit)
    }

    @Test func modifierBitsAreThePagesOnes() {
        #expect(LiveInput.bits(of: []) == 0)
        #expect(LiveInput.bits(of: [.option]) == 1)
        #expect(LiveInput.bits(of: [.control]) == 2)
        #expect(LiveInput.bits(of: [.command]) == 4)
        #expect(LiveInput.bits(of: [.shift, .option, .control, .command]) == 15)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

extension LiveInput {
    static func pixelsPerPointForTests(_ layer: CGSize) -> CGFloat {
        pagePixelsPerPoint(layerSize: layer, imageSize: CGSize(width: 960, height: 600), viewport: CGSize(width: 1280, height: 800))
    }
}

// MARK: - The wait of the Orb's tools

struct BrowserControlTests {
    @Test func aBrowserNobodyTookIsNotWaitedFor() async {
        let control = BrowserControl()
        #expect(await control.waitWhileHeld(UUID()) == false)
    }

    @Test func toolsWaitUntilThePersonHandsItBackAndAnotherOrbDoesNot() async {
        let control = BrowserControl()
        let bot = UUID(), other = UUID()
        control.take(bot)
        #expect(control.isHeld(bot) && !control.isHeld(other))
        #expect(await control.waitWhileHeld(other) == false)
        let first = Task { await control.waitWhileHeld(bot) }
        let second = Task { await control.waitWhileHeld(bot) }
        await waitUntil("both wait") { control.waitingCount(bot) == 2 }
        control.giveBack(bot)
        #expect(await first.value == true)
        #expect(await second.value == true)
        #expect(!control.isHeld(bot))
        #expect(await control.waitWhileHeld(bot) == false)
    }

    @Test func pararEndsTheWait() async {
        let control = BrowserControl()
        let bot = UUID()
        control.take(bot)
        let waiting = Task { await control.waitWhileHeld(bot) }
        await waitUntil("it waits") { control.waitingCount(bot) == 1 }
        waiting.cancel()
        #expect(await waiting.value == true)
        #expect(control.waitingCount(bot) == 0)
        #expect(control.isHeld(bot))
    }

    @Test func aBrowserToolThatWaitedTellsTheModelToLookAgain() async throws {
        let setup = FakeBrowserSetup()
        setup.hub.control.take(setup.botID)
        let context = setup.context()
        let click = Task { () -> String in
            do { return try await BrowseSnapshotTool().run(.object([:]), context: context) } catch { return error.localizedDescription }
        }
        await waitUntil("the tool waits") { setup.hub.control.waitingCount(setup.botID) == 1 }
        #expect(setup.driver.calls.isEmpty)
        setup.hub.control.giveBack(setup.botID)
        let text = await click.value
        #expect(text == BrowserControl.handedBack)
        #expect(setup.driver.calls.isEmpty)
        // Handed back: the next call goes through.
        _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
        #expect(!setup.driver.calls.isEmpty)
    }

    @Test func pararWhileWaitingOpensNoBrowserAndChangesNoProxy() async throws {
        let setup = FakeBrowserSetup()
        setup.hub.control.take(setup.botID)
        let context = setup.context()
        let snapshot = Task { () -> Bool in
            do { _ = try await BrowseSnapshotTool().run(.object([:]), context: context); return false } catch { return error is CancellationError }
        }
        let proxy = Task { () -> Bool in
            do {
                _ = try await BrowseProxyTool().run(.object(["action": .string("set"), "proxy": .string("socks5://127.0.0.1:1080")]), context: context)
                return false
            } catch { return error is CancellationError }
        }
        await waitUntil("both wait") { setup.hub.control.waitingCount(setup.botID) == 2 }
        snapshot.cancel()
        proxy.cancel()
        #expect(await snapshot.value)
        #expect(await proxy.value)
        #expect(setup.configs.withLock { $0.isEmpty })
        #expect(setup.hub.proxy(botID: setup.botID) == nil)
    }

    @Test func aTakeoverBetweenTwoCallsStillTellsTheModelToLookAgain() async throws {
        let setup = FakeBrowserSetup()
        let context = setup.context()
        _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
        // Taken and returned with no tool waiting in between.
        setup.hub.control.take(setup.botID)
        setup.hub.control.giveBack(setup.botID)
        await #expect(throws: ToolError.self) { _ = try await BrowseSnapshotTool().run(.object([:]), context: context) }
        _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
    }

    @Test func theBrowserOpensInTheModeTheOrbHasWhenItIsNeeded() async throws {
        let setup = FakeBrowserSetup(mode: .background)
        var context = setup.context()
        // The panel changed the mode after the turn began.
        context.browser.current = { (mode: .visible, searchProvider: .google) }
        _ = try await BrowseSnapshotTool().run(.object([:]), context: context)
        #expect(setup.configs.withLock { $0.map(\.visibleByDefault) } == [true])
        #expect(await context.browser.liveSearchProvider() == .google)
    }
}

// MARK: - The hub while the person has the browser

@MainActor
struct LiveScreenControlHubTests {
    @Test func inputGoesOutOnlyWhileThePersonHasTheBrowser() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot, wide: true)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 40)))
        #expect(await liveUntil { rig.hub.store(bot).phase == .live })
        let click = LiveInput.mouse(.pressed, at: CGPoint(x: 5, y: 5), button: .left, clickCount: 1)
        // The Orb drives: nothing of the person's goes to the page.
        #expect(!rig.hub.send(click, to: bot))
        rig.hub.takeControl(bot)
        #expect(rig.hub.store(bot).isUserInControl)
        #expect(rig.source.userControl(bot) == true)
        #expect(rig.hub.send(click, to: bot))
        #expect(socket.written == [click])
        // Another Orb's page never gets it.
        #expect(!rig.hub.send(click, to: UUID()))
        rig.hub.giveBackControl(bot)
        #expect(!rig.hub.store(bot).isUserInControl)
        #expect(rig.source.userControl(bot) == false)
        #expect(!rig.hub.send(click, to: bot))
        #expect(socket.written == [click])
    }

    @Test func anotherOrbsCardDoesNotTakeTheStreamFromTheOrbThePersonControls() async throws {
        let rig = LiveRig()
        let a = rig.orb(), b = rig.orb()
        rig.hub.acquire(a, wide: true)
        #expect(await rig.opened(1))
        rig.hub.takeControl(a)
        rig.hub.acquire(b, wide: false)
        let click = LiveInput.mouse(.pressed, at: CGPoint(x: 5, y: 5), button: .left, clickCount: 1)
        #expect(rig.hub.send(click, to: a), "A keeps the connection the input goes on")
        #expect(rig.hub.store(a).phase != .paused)
        // Back to the Orb: the latest card (B) streams.
        rig.hub.giveBackControl(a)
        rig.hub.acquire(b, wide: false)
        #expect(await rig.opened(2))
    }

    @Test func aDeletedOrbGivesTheBrowserBack() async {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot, wide: true)
        rig.hub.takeControl(bot)
        rig.hub.forget(bot)
        #expect(rig.source.userControl(bot) == false)
    }

    @Test func aProtectedPageShowsOnlyWhileThePersonHasItAndIsNeverKept() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.source.setSensitive(true)
        let log = rig.log(bot)
        rig.hub.beginUse(bot)
        rig.hub.acquire(bot, wide: true)
        #expect(await rig.opened(1))
        #expect(await liveUntil { rig.hub.store(bot).isProtected })
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 33)))
        rig.transport.sockets[0].send(LiveTestJPEG.urlMessage("https://banco.example/entrar"))
        #expect(await liveUntil { rig.hub.store(bot).url == "https://banco.example/entrar" })
        #expect(log.frames.isEmpty)
        // Taken over: the stream opens anew and the login shows, for the window.
        rig.hub.takeControl(bot)
        #expect(await rig.opened(2))
        rig.transport.sockets[1].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 34)))
        #expect(await liveUntil { log.frames.count == 1 })
        #expect(rig.hub.store(bot).lastFrame?.image.width == 34)
        #expect(rig.hub.store(bot).isProtected)
        // Handed back: what the person saw goes, and it never becomes the use's last screen.
        rig.hub.giveBackControl(bot)
        #expect(rig.hub.store(bot).lastFrame == nil)
        let item = UUID()
        rig.hub.endUse(bot, itemID: item)
        #expect(rig.hub.lastScreen(of: item) == nil)
    }
}

// MARK: - The card while the person has the browser

struct LiveCardControlTests {
    @Test func theCardSaysThePersonHasItAndHidesThePage() {
        let state = LiveCardState.of(outcome: .running, phase: .live, isProtected: false, isPrivate: false, handoff: false,
                                     userControls: true)
        #expect(state == .youControl)
        #expect(state.veil == .opaque && !state.showsFrames && !state.showsPointer)
        #expect(state.buttons == [.enlarge, .giveBack])
        #expect(state.chip == "Você no controle")
        #expect(LiveScreenText.caption(for: state, work: nil, handoffPage: nil, lastAction: nil) == "O Orb espera você devolver o navegador")
        #expect(LiveScreenText.announcement(for: state) != nil)
        // A broken stream is not hidden behind "you control": the window shows the failure.
        #expect(LiveCardState.of(outcome: .running, phase: .failed, isProtected: false, isPrivate: false, handoff: false,
                                 userControls: true) == .failed)
        // A hand-off still comes first; a finished use is the closing line.
        #expect(LiveCardState.of(outcome: .running, phase: .live, isProtected: false, isPrivate: false, handoff: true,
                                 userControls: true) == .needsYou)
        #expect(LiveCardState.of(outcome: .done, phase: .live, isProtected: false, isPrivate: false, handoff: false,
                                 userControls: true) == .ended)
    }

    @Test func theWindowLetsThePersonTakeOverOnlyAPageThatIsThere() {
        #expect(LiveScreenWindow.canTakeOver(.live) && LiveScreenWindow.canTakeOver(.protected))
        for state in [LiveCardState.connecting, .needsYou, .privateView, .paused, .failed, .ended, .youControl] {
            #expect(!LiveScreenWindow.canTakeOver(state), "\(state)")
        }
        #expect(LiveScreenWindow.caption(for: .live, isIdle: true, handoffPage: nil).contains("Quando o Orb abrir"))
        #expect(LiveScreenWindow.caption(for: .youControl, isIdle: false, handoffPage: nil).contains("⌘V"))
    }

    @Test func thePointerOnTheWholePictureIsWhereTheBoxIs() throws {
        // A 1000 x 300 window shows a 960 x 600 picture 480 wide, from x = 260: the middle of the page is the middle.
        let point = try #require(LiveCursor.point(of: CGRect(x: 630, y: 390, width: 20, height: 20), viewport: CGSize(width: 1280, height: 800),
                                                  scroll: .zero, imageSize: CGSize(width: 960, height: 600),
                                                  layerSize: CGSize(width: 1000, height: 300), fits: true))
        #expect(point == CGPoint(x: 500, y: 150))
    }
}
