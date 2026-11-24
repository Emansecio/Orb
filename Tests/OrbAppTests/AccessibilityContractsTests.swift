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

// MARK: - Apps

struct AppIdentityTests {
    @Test func theLaunchDateIsOptionalInAnAppAndDoesNotChangeItsOldIdentity() {
        let dated = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100, launchDate: Date(timeIntervalSince1970: 5))
        #expect(AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100) == notes)
        #expect(dated != notes)
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

    @Test func findingAnAppByNameAsksNoAppWhetherItIsInFront() async {
        // A stopped app whose window is on top made every call wait half a second on this question, and the call that must
        // fail at once ("ainda está ocupado") took 0.5 s.
        let probe = DesktopProbe()
        let desktop = LiveDesktop(topWindowOwner: { 7 }, isFrontmost: { pid in probe.ask(pid); return nil },
                                  processes: { probe.listed(); return self.apps([7, 8]) })
        let system = LiveAccessibilitySystem(desktop: desktop)
        let listed = await system.runningApps(withFrontmost: false)
        #expect(listed.map(\.pid) == [7, 8] && probe.frontmostAsked.isEmpty)
        _ = await system.runningApps(withFrontmost: true)
        #expect(probe.frontmostAsked == [7])
    }

    @Test func theLiveProcessListFindsThisVeryProcessWithoutTheMainRunLoop() async {
        // The test runner is not an app Launch Services lists as one; the list must still be made off the main thread.
        let apps = await LiveDesktop.offPool { LiveDesktop.liveProcesses() }
        #expect(apps.allSatisfy { $0.pid > 0 && !$0.name.isEmpty && !$0.isActive })
    }
}
