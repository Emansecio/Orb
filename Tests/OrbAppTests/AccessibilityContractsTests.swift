import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Orb

// The contracts of background computer use (AccessibilityContracts.swift) and the fakes that stand in for them. Nothing
// here touches the real Accessibility API, input or screen.

private let notes = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100)

// MARK: - KeyStroke

struct KeyStrokeTests {
    private func parse(_ text: String) throws -> KeyStroke { try KeyStroke.parse(text) }

    @Test func modifiersAndACharacterKey() throws {
        #expect(try parse("cmd+s") == KeyStroke(.character("s"), modifiers: [.command]))
        #expect(try parse("cmd+shift+s") == KeyStroke(.character("s"), modifiers: [.command, .shift]))
        #expect(try parse("ctrl+option+alt+opt+command+shift+9") == KeyStroke(.character("9"), modifiers: [.control, .option, .command, .shift]))
        #expect(try parse("control+/") == KeyStroke(.character("/"), modifiers: [.control]))
    }

    @Test func modifierSpellingsAndCaseDoNotMatter() throws {
        #expect(try parse("CMD+Shift+S") == parse("cmd+shift+s"))
        #expect(try parse("Command+Alt+x") == KeyStroke(.character("x"), modifiers: [.command, .option]))
        #expect(try parse("  cmd + s  ") == parse("cmd+s"))
        #expect(try parse("shift+cmd+s") == parse("cmd+shift+s"))
    }

    @Test func namedKeysAndTheirAliases() throws {
        let expected: [(String, KeyStroke.Named)] = [
            ("return", .return), ("enter", .return), ("escape", .escape), ("esc", .escape), ("tab", .tab), ("space", .space),
            ("delete", .delete), ("backspace", .delete), ("forwarddelete", .forwardDelete), ("up", .up), ("down", .down),
            ("left", .left), ("right", .right), ("home", .home), ("end", .end), ("pageup", .pageUp), ("pagedown", .pageDown),
        ]
        for (text, named) in expected {
            #expect(try parse(text) == KeyStroke(.named(named)), "\(text)")
            #expect(try parse(text.uppercased()) == KeyStroke(.named(named)), "\(text.uppercased())")
        }
        #expect(try parse("cmd+return") == KeyStroke(.named(.return), modifiers: [.command]))
        #expect(try parse("ctrl+option+left") == KeyStroke(.named(.left), modifiers: [.control, .option]))
    }

    @Test func functionKeysGoFromF1ToF12() throws {
        for number in 1...12 { #expect(try parse("f\(number)") == KeyStroke(.named(.function(number)))) }
        #expect(try parse("shift+F5") == KeyStroke(.named(.function(5)), modifiers: [.shift]))
        #expect(throws: KeyStroke.ParseError.self) { try parse("f0") }
        #expect(throws: KeyStroke.ParseError.self) { try parse("f13") }
    }

    @Test func aSingleCharacterIsAKeyAndAnUppercaseLetterImpliesShift() throws {
        #expect(try parse("a") == KeyStroke(.character("a")))
        #expect(try parse("A") == KeyStroke(.character("a"), modifiers: [.shift]))
        #expect(try parse("cmd+S") == KeyStroke(.character("s"), modifiers: [.command]), "a capital in a shortcut is only how it is written")
        #expect(try parse("Cmd+Z") == KeyStroke(.character("z"), modifiers: [.command]), "⌘Z is undo, not ⌘⇧Z (redo)")
        #expect(try parse("cmd+shift+Z") == KeyStroke(.character("z"), modifiers: [.command, .shift]))
        #expect(try parse("ç") == KeyStroke(.character("ç")))
        #expect(try parse(",") == KeyStroke(.character(",")))
        #expect(try parse("cmd+,") == KeyStroke(.character(","), modifiers: [.command]))
    }

    @Test func thePlusKeyCanBePressedToo() throws {
        #expect(try parse("+") == KeyStroke(.character("+")))
        #expect(try parse("cmd++") == KeyStroke(.character("+"), modifiers: [.command]))
        #expect(try parse("cmd+shift++") == KeyStroke(.character("+"), modifiers: [.command, .shift]))
    }

    @Test func badInputIsRefusedWithAMessageThatNamesTheProblem() {
        #expect(throws: KeyStroke.ParseError.empty) { try parse("") }
        #expect(throws: KeyStroke.ParseError.empty) { try parse("   ") }
        #expect(throws: KeyStroke.ParseError.unknownModifier("hyper")) { try parse("hyper+s") }
        #expect(throws: KeyStroke.ParseError.unknownModifier("")) { try parse("+cmd+s") }
        #expect(throws: KeyStroke.ParseError.unknownKey("enterr")) { try parse("enterr") }
        #expect(throws: KeyStroke.ParseError.unknownKey("cmd+")) { try parse("cmd+") }
        #expect(throws: KeyStroke.ParseError.unknownKey("++")) { try parse("++") }
        #expect(throws: KeyStroke.ParseError.unknownKey("ab")) { try parse("cmd+ab") }
        for error in [KeyStroke.ParseError.empty, .unknownModifier("x"), .unknownKey("y")] {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test func theCanonicalSpellingParsesBackToTheSameStroke() throws {
        for text in ["cmd+shift+s", "return", "ctrl+option+left", "cmd+,", "f12", "cmd++", "option+space", "shift+tab", "a", "forwarddelete"] {
            let stroke = try parse(text)
            #expect(try parse(stroke.description) == stroke, "\(text)")
        }
        #expect(try parse("shift+cmd+S").description == "cmd+shift+s")
        #expect(try parse("alt+ctrl+Escape").description == "option+ctrl+escape")
    }

    @Test func namedKeysCarryTheFixedVirtualKeyCodes() {
        #expect(KeyStroke.Named.return.virtualKey == 36)
        #expect(KeyStroke.Named.tab.virtualKey == 48)
        #expect(KeyStroke.Named.space.virtualKey == 49)
        #expect(KeyStroke.Named.delete.virtualKey == 51)
        #expect(KeyStroke.Named.escape.virtualKey == 53)
        #expect(KeyStroke.Named.forwardDelete.virtualKey == 117)
        #expect(KeyStroke.Named.left.virtualKey == 123 && KeyStroke.Named.right.virtualKey == 124)
        #expect(KeyStroke.Named.down.virtualKey == 125 && KeyStroke.Named.up.virtualKey == 126)
        #expect(KeyStroke.Named.home.virtualKey == 115 && KeyStroke.Named.end.virtualKey == 119)
        #expect(KeyStroke.Named.pageUp.virtualKey == 116 && KeyStroke.Named.pageDown.virtualKey == 121)
        #expect((1...12).map { KeyStroke.Named.function($0).virtualKey } == [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111])
    }
}

// MARK: - Snapshots and apps

struct SnapshotCompatibilityTests {
    /// A snapshot as the version before this one stored it: no generation, marks, shot, frames or launch date.
    private let oldJSON = """
    {"app":{"name":"Notas","bundleID":"com.apple.Notes","pid":100},"windowIndex":0,"windowTitle":"Notas",
     "entries":{"w1":{"rawRole":"AXWindow","label":"Notas","secure":false},
                "w1.1":{"rawRole":"AXTextField","label":"Buscar","secure":true}},
     "takenAt":780000000}
    """

    @Test func anOldSnapshotStillDecodesWithDefaultsForTheNewFields() throws {
        let snapshot = try JSONDecoder().decode(UISnapshot.self, from: Data(oldJSON.utf8))
        #expect(snapshot.app == notes)
        #expect(snapshot.app.launchDate == nil)
        #expect(snapshot.windowIndex == 0 && snapshot.windowTitle == "Notas")
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries["w1.1"]?.secure == true)
        #expect(snapshot.entries["w1.1"]?.frame == nil && snapshot.entries["w1.1"]?.actionable == false)
        #expect(snapshot.generation == 0 && snapshot.marks.isEmpty && snapshot.shot == nil)
    }

    @Test func aSnapshotWithEverythingRoundTripsAndWritesMarksWithStringKeys() throws {
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        let shot = ShotGeometry(pixelWidth: 1280, pixelHeight: 800, scale: 2, windowFrame: CGRect(x: -1440, y: 25, width: 640, height: 400), windowID: 4242)
        let snapshot = UISnapshot(
            app: AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100, launchDate: launched), windowIndex: 1,
            windowTitle: "Notas", entries: ["w1.2": .init(rawRole: "AXButton", label: "Salvar", secure: false, frame: CGRect(x: 10, y: 20, width: 80, height: 24), actionable: true)],
            takenAt: Date(timeIntervalSince1970: 1_700_000_100), generation: 7, marks: [1: "w1.2", 12: "w1.9.3"], shot: shot)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(UISnapshot.self, from: data) == snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["marks"] as? [String: String] == ["1": "w1.2", "12": "w1.9.3"])
    }

    @Test func fieldsOfTheWrongTypeDoNotMakeTheSnapshotUnreadable() throws {
        let json = """
        {"app":{"name":"Notas","bundleID":"com.apple.Notes","pid":100,"launchDate":"ontem"},"windowTitle":"Notas",
         "entries":{"w1":{"rawRole":"AXWindow","label":"Notas","secure":false,"frame":"grande","actionable":"sim"}},
         "takenAt":780000000,"generation":"x","marks":[1,2,3],"shot":{"pixelWidth":"muito"}}
        """
        let snapshot = try JSONDecoder().decode(UISnapshot.self, from: Data(json.utf8))
        #expect(snapshot.app.launchDate == nil)
        #expect(snapshot.entries["w1"]?.frame == nil && snapshot.entries["w1"]?.actionable == false)
        #expect(snapshot.generation == 0 && snapshot.marks.isEmpty && snapshot.shot == nil)
    }

    @Test func theStoreKeepsTheNewFieldsThroughItsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OrbAccessibilityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = UISnapshot(app: notes, windowIndex: 0, windowTitle: "Notas", entries: [:], generation: 3, marks: [5: "w1.1"])
        UISnapshotStore(directory: directory).save(snapshot, bot: nil)
        // A second store (another process) reads it from the file.
        #expect(UISnapshotStore(directory: directory).snapshot(bot: nil, app: notes)?.marks == [5: "w1.1"])
        #expect(UISnapshotStore(directory: directory).snapshot(bot: nil, app: notes)?.generation == 3)
    }

    @Test func theLaunchDateIsOptionalInAnAppAndDoesNotChangeItsOldIdentity() throws {
        let plain = try JSONDecoder().decode(AccessibilityApp.self, from: Data(#"{"name":"Notas","bundleID":"com.apple.Notes","pid":100}"#.utf8))
        #expect(plain == notes)
        let dated = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100, launchDate: Date(timeIntervalSince1970: 5))
        #expect(try JSONDecoder().decode(AccessibilityApp.self, from: JSONEncoder().encode(dated)) == dated)
        #expect(dated != notes)
        let noBundle = try JSONDecoder().decode(AccessibilityApp.self, from: Data(#"{"name":"X","pid":1}"#.utf8))
        #expect(noBundle.bundleID == nil)
    }
}

// MARK: - Element defaults

/// A conformer that only implements the original requirements, as every element did before the contracts grew.
private struct BareElement: AccessibilityElement {
    func attribute(_ name: String) -> AXAttributeValue? { name == "AXRole" ? .string("AXButton") : nil }
    func actionNames() -> [String] { [] }
    func isSettable(_ name: String) -> Bool { false }
    func perform(_ action: String) throws {}
    func setValue(_ value: AXAttributeValue, for name: String) throws {}
}

/// A system that only implements the original requirements.
private struct BareSystem: AccessibilitySystem {
    func isTrusted() -> Bool { true }
    func runningApps() async -> [RunningAppInfo] { [] }
    func root(of app: AccessibilityApp) -> any AccessibilityElement { BareElement() }
    func activate(_ app: AccessibilityApp) {}
}

struct AccessibilityContractDefaultsTests {
    @Test func anElementThatKnowsNothingNewStillWorks() {
        let element = BareElement()
        #expect(element.pid == nil)
        #expect(!element.isSame(as: BareElement()), "value types cannot be told apart without help")
        guard case .values(let values) = element.read(["AXRole", "AXTitle"]) else { Issue.record("expected values"); return }
        #expect(values["AXRole"]?.string == "AXButton" && values["AXTitle"] == nil)
    }

    @Test func classElementsAreTheSameOnlyWhenTheyAreTheSameObject() {
        let button = fakeButton("OK")
        #expect(button.isSame(as: button))
        #expect(!button.isSame(as: fakeButton("OK")))
        #expect(!button.isSame(as: BareElement()))
    }

    @Test func theSystemStandInsSayUnavailable() async throws {
        let system = BareSystem()
        #expect(system.hitTest(notes, at: .zero) == nil)
        #expect(await system.frontmostPID() == nil)
        #expect(system.secondsSinceUserInput() == .infinity)

        var received = 0
        for await _ in system.events.events(pid: 100, [.valueChanged]) { received += 1 }
        #expect(received == 0, "the stream ends at once")

        #expect(!system.input.secureInputActive)
        await #expect(throws: ToolError.self) { try await system.input.keys([KeyStroke(.named(.return))], to: 100) }
        await #expect(throws: ToolError.self) { try await system.input.text("oi", to: 100) }
        await #expect(throws: ToolError.self) { try await system.input.click(at: .zero, window: 1, button: .left, count: 1, to: 100) }
        await #expect(throws: ToolError.self) { try await system.input.scroll(dx: 0, dy: 10, at: .zero, window: 1, to: 100) }
        await #expect(throws: ToolError.self) { try await system.capturer.windows(pid: 100) }
        let window = CapturableWindow(windowID: 1, pid: 100, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        await #expect(throws: ToolError.self) { try await system.capturer.capture(window, maxSide: 100) }
        await #expect(throws: ToolError.self) { try await system.screen.takeOver(notes, window: nil, limit: .seconds(1)) { _ in 1 } }
    }

    @Test func theLiveSystemHandsOutTheLiveCollaborators() {
        // Only the wiring: nothing real is called, and no live state of this Mac (Secure Event Input may be on here) is read.
        let live = LiveAccessibilitySystem()
        #expect(live.input is LiveSyntheticInput)
        #expect(live.capturer is LiveWindowCapturer)
        #expect(live.screen is LiveScreenOwner)
        #expect(live.events is AXEventHub)
    }

    @Test func theLiveElementKnowsItsProcessAndComparesHandles() {
        let own = getpid()
        let first = LiveAccessibilityElement(AXUIElementCreateApplication(own))
        let second = LiveAccessibilityElement(AXUIElementCreateApplication(own))
        let other = LiveAccessibilityElement(AXUIElementCreateApplication(own &+ 1))
        #expect(first.pid == own)
        #expect(first.isSame(as: second))
        #expect(!first.isSame(as: other))
        #expect(!first.isSame(as: BareElement()))
    }

    @Test func askingOneByOneStopsAtTheFirstCallAHungAppDoesNotAnswer() {
        // The fallback for elements without the batch call: five names to a hung app cost one timeout, not five.
        var asked: [String] = []
        let found = LiveAccessibilityElement.oneByOne(["AXRole", "AXTitle", "AXValue", "AXSize", "AXPosition"]) { name in
            asked.append(name)
            return name == "AXRole" ? (.success, .string("AXButton")) : (.cannotComplete, nil)
        }
        #expect(asked == ["AXRole", "AXTitle"])
        #expect(found.failure == .cannotComplete && found.values["AXRole"]?.string == "AXButton")
        let missing = LiveAccessibilityElement.oneByOne(["AXRole", "AXTitle"]) { _ in (.attributeUnsupported, nil) }
        #expect(missing.failure == nil && missing.values.isEmpty, "a missing attribute is not a hung app")
    }

    @Test func aRangeIsAValueAndIsReadBack() {
        let value = AXAttributeValue.range(AXTextRange(location: 3, length: 5))
        #expect(value.range == AXTextRange(location: 3, length: 5))
        #expect(value.string == nil && AXAttributeValue.string("x").range == nil)
        let element = fake("AXTextField")
        element.settable = ["AXSelectedTextRange"]
        try? element.setValue(value, for: "AXSelectedTextRange")
        #expect(element.assignedValue("AXSelectedTextRange")?.range == AXTextRange(location: 3, length: 5))
    }
}

// MARK: - The element fake

struct FakeElementTests {
    @Test func everyCallIsOneRoundTripAndBatchesCountOnce() {
        let button = fakeButton("OK")
        _ = button.attribute("AXRole")
        _ = button.attributes(["AXRole", "AXTitle", "AXEnabled"])
        _ = button.read(["AXRole", "AXTitle"])
        _ = button.actionNames()
        _ = button.isSettable("AXValue")
        try? button.perform("AXPress")
        #expect(button.roundTrips == 6)
        #expect(button.reads == ["AXRole", "AXRole", "AXTitle", "AXEnabled", "AXRole", "AXTitle"])
        button.resetRoundTrips()
        #expect(button.roundTrips == 0)
    }

    @Test func theTreeCounterAddsUpEveryElementBelow() {
        let window = fake("AXWindow", title: "W", [fakeButton("A"), fakeButton("B")])
        _ = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        // One batch per element (AXChildren comes in it), plus the actions of each listed element below the window;
        // buttons carry no AXValue to read.
        #expect(window.subtree.count == 3)
        #expect(window.treeRoundTrips == 1 + 2 * 2)
        #expect(window.children.allSatisfy { $0.roundTrips == 2 })
    }

    @Test func frameIsPositionAndSize() {
        let element = fake("AXButton", size: nil)
        #expect(element.frame == nil)
        element.frame = CGRect(x: 5, y: 6, width: 70, height: 20)
        #expect(element.frame == CGRect(x: 5, y: 6, width: 70, height: 20))
        if case .point(let origin)? = element.attribute("AXPosition") { #expect(origin == CGPoint(x: 5, y: 6)) } else { Issue.record("no AXPosition") }
        element.frame = nil
        #expect(element.attrs["AXPosition"] == nil && element.attrs["AXSize"] == nil)
    }

    @Test func scriptedFailuresSurfaceInReadAndThrowInActions() throws {
        let field = fake("AXTextField", value: .string("x"), actions: ["AXPress"])
        field.settable = ["AXValue"]
        field.pid = 321
        #expect(field.pid == 321)

        field.failures["AXValue"] = .cannotComplete
        #expect(field.read(["AXRole", "AXValue"]).failure == .cannotComplete)
        #expect(field.read(["AXRole"]).attributes?["AXRole"]?.string == "AXTextField")
        #expect(field.attribute("AXValue") == nil, "plain reads swallow it, like the live element")
        #expect(field.attributes(["AXRole", "AXValue"]).keys.sorted() == ["AXRole"])

        field.failures = ["perform:AXPress": .invalidElement, "set:AXValue": .apiDisabled]
        #expect(throws: AXFailure.invalidElement) { try field.perform("AXPress") }
        #expect(throws: AXFailure.apiDisabled) { try field.setValue(.string("y"), for: "AXValue") }
        #expect(field.performed.isEmpty && field.assignedValue("AXValue") == nil)

        field.failures = ["*": .cannotComplete]
        #expect(field.read(["AXRole"]).failure == .cannotComplete)
        field.failures = [:]
        try field.perform("AXPress")
        #expect(field.performed == ["AXPress"])
    }

    @Test func aStalledElementBlocksEachCall() {
        let button = fakeButton("OK")
        button.stall = .milliseconds(120)
        let started = ContinuousClock.now
        _ = button.attribute("AXRole")
        _ = button.read(["AXRole"])
        #expect(started.duration(to: .now) >= .milliseconds(220))
    }
}

// MARK: - The other fakes

struct FakeSyntheticInputTests {
    @Test func everyCallIsRecordedInOrder() async throws {
        let input = FakeSyntheticInput()
        let save = try KeyStroke.parse("cmd+s")
        try await input.keys([save], to: 100)
        try await input.click(at: CGPoint(x: 4, y: 5), window: 9, button: .right, count: 2, to: 100)
        try await input.scroll(dx: 0, dy: -30, at: CGPoint(x: 1, y: 2), window: 9, to: 100)
        let sent = try await input.text("olá", to: 100)
        #expect(sent == 3)
        #expect(input.events == [
            .keys([save], pid: 100),
            .click(CGPoint(x: 4, y: 5), window: 9, button: .right, count: 2, pid: 100),
            .scroll(dx: 0, dy: -30, at: CGPoint(x: 1, y: 2), window: 9, pid: 100),
            .text("olá", pid: 100),
        ])
        #expect(input.typed(to: 100) == "olá" && input.typed(to: 7).isEmpty)
    }

    @Test func textGoesOutInChunks() async throws {
        let input = FakeSyntheticInput()
        input.chunkSize = 4
        #expect(try await input.text("0123456789", to: 1) == 10)
        #expect(input.events == [.text("0123", pid: 1), .text("4567", pid: 1), .text("89", pid: 1)])
        #expect(input.typed(to: 1) == "0123456789")
    }

    @Test func aCancelledTaskStopsTypingBetweenChunksAndSaysHowMuchWentOut() async throws {
        let input = FakeSyntheticInput()
        input.chunkSize = 1
        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await input.text("abcdef", to: 1)
        }
        #expect(try await task.value == 0)
        #expect(input.events.isEmpty)
    }

    @Test func secureInputAndFailuresAreScriptable() async {
        let input = FakeSyntheticInput()
        input.secureInputActive = true
        #expect(input.secureInputActive)
        input.error = ToolError("negado")
        await #expect(throws: ToolError.self) { try await input.keys([KeyStroke(.named(.tab))], to: 1) }
        await #expect(throws: ToolError.self) { try await input.text("x", to: 1) }
        #expect(input.events.isEmpty)
    }
}

struct FakeWindowCapturerTests {
    @Test func windowsAreListedPerProcess() async throws {
        let capturer = FakeWindowCapturer()
        let window = CapturableWindow(windowID: 7, pid: 100, frame: CGRect(x: 0, y: 0, width: 640, height: 400), title: "Notas")
        capturer.setWindows([window], pid: 100)
        #expect(try await capturer.windows(pid: 100) == [window])
        #expect(try await capturer.windows(pid: 5).isEmpty)
    }

    @Test func theImageIsInPixelsAndScaledDownToMaxSide() async throws {
        let capturer = FakeWindowCapturer()
        let window = CapturableWindow(windowID: 7, pid: 100, frame: CGRect(x: -1440, y: 0, width: 640, height: 400))
        let full = try await capturer.capture(window, maxSide: 4000)
        #expect(full.width == 1280 && full.height == 800)
        let small = try await capturer.capture(window, maxSide: 640)
        #expect(small.width == 640 && small.height == 400)
        #expect(capturer.captures == [.init(windowID: 7, maxSide: 4000), .init(windowID: 7, maxSide: 640)])
    }

    @Test func theImageIsNotBlank() throws {
        let image = try FakeWindowCapturer.image(width: 32, height: 32)
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(Set(data).count > 8)
    }

    @Test func aFailureIsThrown() async {
        let capturer = FakeWindowCapturer()
        capturer.error = ToolError("sem permissão")
        await #expect(throws: ToolError.self) { try await capturer.windows(pid: 1) }
        await #expect(throws: ToolError.self) { try await capturer.capture(CapturableWindow(windowID: 1, pid: 1, frame: .zero), maxSide: 10) }
    }
}

struct FakeScreenOwnerTests {
    @Test func aTakeoverGivesTheBodyTheHandAndRestoresAfterwards() async throws {
        let owner = FakeScreenOwner()
        let report = try await owner.takeOver(notes, window: fakeButton("janela"), limit: .seconds(10)) { hand in
            try await hand.click(at: CGPoint(x: 1, y: 2), button: .left, count: 1)
            try await hand.type("oi")
            try await hand.key(KeyStroke(.named(.return)))
            try await hand.drag(from: .zero, to: CGPoint(x: 9, y: 9))
            return 42
        }
        #expect(report.value == 42 && report.restoredApp == "Safari" && report.cursorRestored)
        #expect(owner.steps == [.took(pid: 100, windowGiven: true, limit: .seconds(10)), .restored(cancelled: false)])
        #expect(owner.hand.actions == [
            .click(CGPoint(x: 1, y: 2), button: .left, count: 1), .type("oi"), .key(KeyStroke(.named(.return))),
            .drag(from: .zero, to: CGPoint(x: 9, y: 9)),
        ])
    }

    @Test func aBodyThatThrowsStillRestoresAndTheErrorPropagates() async {
        let owner = FakeScreenOwner()
        await #expect(throws: ToolError.self) {
            try await owner.takeOver(notes, window: nil, limit: .seconds(1)) { _ -> Int in throw ToolError("falhou") }
        }
        #expect(owner.takes == 1 && owner.restores == 1)
    }

    @Test func cancellationStillRestoresBeforeTheCallReturns() async throws {
        let owner = FakeScreenOwner()
        let task = Task {
            try await owner.takeOver(notes, window: nil, limit: .seconds(10)) { hand -> Int in
                try await hand.type("x")
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        await waitUntil("the body to start") { owner.hand.actions.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(owner.steps.last == .restored(cancelled: true))
        #expect(owner.takes == 1 && owner.restores == 1)
    }

    @Test func aRefusedTakeoverTakesNothing() async {
        let owner = FakeScreenOwner()
        owner.error = ToolError("outro Orb está usando a tela")
        await #expect(throws: ToolError.self) { try await owner.takeOver(notes, window: nil, limit: .seconds(1)) { _ in 1 } }
        #expect(owner.steps.isEmpty)
    }
}

struct FakeAccessibilityEventsTests {
    private func firstEvent(of stream: AsyncStream<AXEvent>) async -> AXEvent? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    @Test func eventsReachOnlyTheSubscriptionsThatAskedForThem() async {
        let hub = FakeAccessibilityEvents()
        let values = hub.events(pid: 100, [.valueChanged], on: nil)
        let other = hub.events(pid: 200, [.valueChanged], on: nil)
        let titles = hub.events(pid: 100, [.titleChanged], on: nil)
        #expect(hub.activeSubscriptions == 3)
        hub.emit(.titleChanged, pid: 100)
        hub.emit(.valueChanged, pid: 100)
        hub.finishAll()

        #expect(await firstEvent(of: values)?.notification == .valueChanged)
        #expect(await firstEvent(of: titles)?.notification == .titleChanged)
        #expect(await firstEvent(of: other) == nil)
        #expect(hub.requests.map { $0.pid } == [100, 200, 100])
    }

    @Test func aSubscriptionOnAnElementOnlySeesThatElement() async {
        let hub = FakeAccessibilityEvents()
        let field = fake("AXTextField")
        let stream = hub.events(pid: 100, [.valueChanged], on: field)
        hub.emit(.valueChanged, pid: 100, element: fake("AXTextField"))
        hub.emit(.valueChanged, pid: 100)
        hub.emit(.valueChanged, pid: 100, element: field)
        hub.finishAll()
        var count = 0
        for await event in stream { count += 1; #expect(event.element?.isSame(as: field) == true) }
        #expect(count == 1)
    }

    @Test func stoppingIterationEndsTheSubscription() async {
        let hub = FakeAccessibilityEvents()
        let task = Task { () -> Int in
            var count = 0
            for await _ in hub.events(pid: 1, [.created], on: nil) { count += 1 }
            return count
        }
        await waitUntil("the subscription") { hub.activeSubscriptions == 1 }
        task.cancel()
        _ = await task.value
        await waitUntil("the subscription to end") { hub.activeSubscriptions == 0 }
    }

    @Test func anAppWithoutNotificationsGivesAStreamThatEndsAtOnce() async {
        let hub = FakeAccessibilityEvents()
        hub.available = false
        #expect(await firstEvent(of: hub.events(pid: 1, [.created])) == nil)
        #expect(hub.activeSubscriptions == 0)
    }

    @Test func theNotificationNamesAreTheApisOwnStrings() {
        #expect(AXNotification.valueChanged.rawValue == "AXValueChanged")
        #expect(AXNotification.elementDestroyed.rawValue == "AXUIElementDestroyed")
        #expect(AXNotification.focusedElementChanged.rawValue == "AXFocusedUIElementChanged")
        #expect(AXNotification.loadComplete.rawValue == "AXLoadComplete")
        #expect(AXNotification.applicationActivated.rawValue == "AXApplicationActivated")
        #expect(AXNotification.allCases.count == 15)
        #expect(Set(AXNotification.allCases.map(\.rawValue)).count == 15)
    }
}

struct FakeAccessibilitySystemTests {
    @Test func theSystemFakeAnswersTheNewCalls() async {
        let system = FakeAccessibility()
        #expect(await system.frontmostPID() == nil)
        system.frontmost = 100
        system.userIdle = 1.5
        #expect(await system.frontmostPID() == 100 && system.secondsSinceUserInput() == 1.5)

        let button = fakeButton("OK")
        system.hitHandler = { _, point in point.x > 0 ? button : nil }
        #expect(system.hitTest(notes, at: CGPoint(x: 5, y: 5))?.isSame(as: button) == true)
        #expect(system.hitTest(notes, at: .zero) == nil)
        #expect(system.hitTests == [CGPoint(x: 5, y: 5), .zero])
    }

    @Test func theFakeCollaboratorsAreWhatTheSystemHandsOut() async throws {
        let system = FakeAccessibility()
        try await system.input.keys([KeyStroke(.named(.escape))], to: 100)
        #expect(system.syntheticInput.events == [.keys([KeyStroke(.named(.escape))], pid: 100)])
        _ = try await system.screen.takeOver(notes, window: nil, limit: .seconds(1)) { _ in 0 }
        #expect(system.screenOwner.takes == 1)
        system.windowCapturer.setWindows([CapturableWindow(windowID: 1, pid: 100, frame: .zero)], pid: 100)
        #expect(try await system.capturer.windows(pid: 100).count == 1)
        let stream = system.events.events(pid: 100, [.layoutChanged])
        system.axEvents.emit(.layoutChanged, pid: 100)
        system.axEvents.finishAll()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1)
    }
}

// MARK: - Which apps run, and which is in front

/// Counts what a `LiveDesktop` asked.
private final class DesktopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var listings = 0
    private var asked: [Int32] = []
    var processLists: Int { lock.withLock { listings } }
    var frontmostAsked: [Int32] { lock.withLock { asked } }
    func listed() { lock.withLock { listings += 1 } }
    func ask(_ pid: Int32) { lock.withLock { asked.append(pid) } }
}

struct LiveDesktopTests {
    private func apps(_ pids: [Int32], active: Int32? = nil) -> [RunningAppInfo] {
        pids.map { RunningAppInfo(name: "App \($0)", bundleID: "app.\($0)", pid: $0, isActive: $0 == active, isHidden: false, isRegular: true) }
    }

    @Test func theFrontAppIsTheTopWindowsOwnerWhenItSaysSoAndNotWhatTheProcessListClaims() {
        let probe = DesktopProbe()
        // The process list says 1 is active (stale, as NSWorkspace's is in the tools server); the window list and the app say 2.
        let desktop = LiveDesktop(topWindowOwner: { 2 }, isFrontmost: { pid in probe.ask(pid); return pid == 2 },
                                  processes: { probe.listed(); return self.apps([1, 2, 3], active: 1) })
        #expect(desktop.frontmost() == 2)
        let running = desktop.runningApps()
        #expect(running.filter(\.isActive).map(\.pid) == [2])
        #expect(probe.frontmostAsked == [2, 2], "the top window's owner answered: nobody else is asked")
    }

    @Test func whenTheTopWindowIsNotTheFrontAppsTheAppsAreAsked() {
        // A floating window of another app on top: its owner says it is not in front, and app 3 says it is.
        let desktop = LiveDesktop(topWindowOwner: { 1 }, isFrontmost: { $0 == 3 }, processes: { self.apps([1, 2, 3]) })
        #expect(desktop.frontmost() == 3)
        // Nobody claims it: the top window's owner is the best guess. No window at all and nobody: nil.
        #expect(LiveDesktop(topWindowOwner: { 1 }, isFrontmost: { _ in false }, processes: { self.apps([1, 2]) }).frontmost() == 1)
        #expect(LiveDesktop(topWindowOwner: { nil }, isFrontmost: { _ in nil }, processes: { self.apps([1, 2]) }).frontmost() == nil)
        // An app that does not answer is taken at its window's word.
        #expect(LiveDesktop(topWindowOwner: { 2 }, isFrontmost: { _ in nil }, processes: { self.apps([1, 2]) }).frontmost() == 2)
    }

    @Test func theProcessesAreReadAnewOnEveryCall() async {
        let probe = DesktopProbe()
        var desktop = LiveDesktop(topWindowOwner: { nil }, isFrontmost: { _ in nil }, processes: { probe.listed(); return [] })
        desktop.isFrontmost = { _ in nil }
        let system = LiveAccessibilitySystem(desktop: desktop)
        _ = await system.runningApps()
        _ = await system.runningApps()
        _ = await system.frontmostPID()
        #expect(probe.processLists == 3, "nothing is cached between calls")
    }

    @Test func theLiveProcessListFindsThisVeryProcessWithoutTheMainRunLoop() async {
        // The test runner is not an app Launch Services lists as one; the list must still be made off the main thread.
        let apps = await LiveDesktop.offPool { LiveDesktop.liveProcesses() }
        #expect(apps.allSatisfy { $0.pid > 0 && !$0.name.isEmpty && !$0.isActive })
    }
}
