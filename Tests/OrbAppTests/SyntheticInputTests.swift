import CoreGraphics
import Foundation
import Testing
@testable import Orb

/// Synthetic keyboard, mouse and scroll events: how they are built, which keys a layout needs, how text is cut and what
/// cancelling does. Events are built into a recorder; nothing is posted to a real app.
struct SyntheticInputTests {
    // MARK: Fakes

    /// Collects what would have been posted.
    final class RecordingSink: SyntheticEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(event: CGEvent, pid: Int32)] = []
        /// Called after each post with the number of events so far.
        var afterPost: (@Sendable (Int) -> Void)?

        var posted: [(event: CGEvent, pid: Int32)] { lock.withLock { log } }
        var events: [CGEvent] { posted.map(\.event) }

        func post(_ event: CGEvent, to pid: Int32) throws {
            let count = lock.withLock { () -> Int in
                log.append((event, pid))
                return log.count
            }
            afterPost?(count)
        }
    }

    /// A keyboard where "ç" has a key and "/" is on its own extra key (94), "\\" is on the ISO key (10), ";" moved to 44 and
    /// "[" "]" to 30 and 42, like ABNT2; the letters and digits it shares with a US keyboard are the few used here.
    private static let abnt2Keys: [UInt16: (String, String)] = [
        41: ("ç", "Ç"), 44: (";", ":"), 94: ("/", "?"), 42: ("]", "}"), 30: ("[", "{"), 10: ("\\", "|"), 50: ("'", "\""),
        0: ("a", "A"), 1: ("s", "S"), 12: ("q", "Q"), 24: ("=", "+"), 18: ("1", "!"), 19: ("2", "@"), 49: (" ", " "),
    ]

    private static let abnt2 = TranslatedKeyLayout { keyCode, state in
        guard let pair = abnt2Keys[keyCode] else { return nil }
        switch state {
        case .plain: return pair.0
        case .shift: return pair.1
        case .option, .shiftOption: return nil
        }
    }

    private func keyCode(_ event: CGEvent) -> UInt16 { UInt16(event.getIntegerValueField(.keyboardEventKeycode)) }

    private func unicode(_ event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    private func input(sink: RecordingSink = RecordingSink(), layout: any KeyLayout = USKeyLayout.layout) -> LiveSyntheticInput {
        LiveSyntheticInput(sink: sink, layout: layout, pacing: .none, secureInput: { false })
    }

    // MARK: Keycodes from the layout

    @Test func theUSLayoutMapsCharactersToTheirPhysicalKeys() {
        let us = USKeyLayout.layout
        #expect(us.entry(for: "s") == KeyLayoutEntry(keyCode: 1))
        #expect(us.entry(for: "a") == KeyLayoutEntry(keyCode: 0))
        #expect(us.entry(for: "/") == KeyLayoutEntry(keyCode: 44))
        #expect(us.entry(for: "?") == KeyLayoutEntry(keyCode: 44, shift: true))
        #expect(us.entry(for: "+") == KeyLayoutEntry(keyCode: 24, shift: true))
        #expect(us.entry(for: "5") == KeyLayoutEntry(keyCode: 23), "the number row, not the keypad")
        #expect(us.entry(for: "S") == KeyLayoutEntry(keyCode: 1, shift: true))
        #expect(us.entry(for: "ç") == nil)
    }

    @Test func abnt2AndUSPutTheSameCharacterOnDifferentKeys() {
        let us = USKeyLayout.layout
        let abnt2 = Self.abnt2
        #expect(us.entry(for: "/")?.keyCode == 44 && abnt2.entry(for: "/")?.keyCode == 94)
        #expect(us.entry(for: ";")?.keyCode == 41 && abnt2.entry(for: ";")?.keyCode == 44)
        #expect(us.entry(for: "\\")?.keyCode == 42 && abnt2.entry(for: "\\")?.keyCode == 10)
        #expect(abnt2.entry(for: "ç") == KeyLayoutEntry(keyCode: 41))
        #expect(abnt2.entry(for: "Ç") == KeyLayoutEntry(keyCode: 41, shift: true))
        #expect(abnt2.entry(for: "ç") == abnt2.entry(for: "Ç").map { KeyLayoutEntry(keyCode: $0.keyCode) }, "an uppercase letter is the shifted key")
    }

    @Test func plainKeysBeatShiftedAndOptionOnesAndTheKeypadIsIgnored() {
        // Key 82 (keypad 0) and key 29 both type "0"; key 5 types "g" plain and "©" with option, key 6 types "©" with shift+option.
        let layout = TranslatedKeyLayout { keyCode, state in
            switch (keyCode, state) {
            case (82, .plain), (29, .plain): "0"
            case (5, .plain): "g"
            case (5, .option): "©"
            case (6, .shiftOption): "©"
            case (7, .shift): "g"
            default: nil
            }
        }
        #expect(layout.entry(for: "0") == KeyLayoutEntry(keyCode: 29))
        #expect(layout.entry(for: "g") == KeyLayoutEntry(keyCode: 5))
        #expect(layout.entry(for: "©") == KeyLayoutEntry(keyCode: 5, option: true))
    }

    @Test func aLayoutSkipsKeysThatTypeControlCharactersOrSeveralCharacters() {
        let layout = TranslatedKeyLayout { keyCode, state in
            guard state == .plain else { return nil }
            return [1: "\r", 2: "\t", 3: "ab", 4: "x", 5: "\u{7F}"][keyCode]
        }
        #expect(layout.characters == ["x"])
    }

    // MARK: Shortcuts

    @Test func aShortcutIsAKeyDownAndUpWithExplicitFlags() throws {
        let us = try SyntheticEventBuilder.keyEvents(KeyStroke.parse("cmd+s"), layout: USKeyLayout.layout, source: nil)
        #expect(keyCode(us.down) == 1 && keyCode(us.up) == 1)
        #expect(us.down.type == .keyDown && us.up.type == .keyUp)
        #expect(us.down.flags.contains(.maskCommand) && us.up.flags.contains(.maskCommand))
        #expect(!us.down.flags.contains(.maskShift) && !us.down.flags.contains(.maskAlternate) && !us.down.flags.contains(.maskControl))
        let all = try SyntheticEventBuilder.keyEvents(KeyStroke.parse("cmd+shift+option+ctrl+a"), layout: USKeyLayout.layout, source: nil)
        #expect(all.down.flags.isSuperset(of: [.maskCommand, .maskShift, .maskAlternate, .maskControl]) && keyCode(all.down) == 0)
    }

    @Test func theSameShortcutUsesTheKeyOfTheLayoutInUse() throws {
        let stroke = try KeyStroke.parse("cmd+/")
        #expect(keyCode(try SyntheticEventBuilder.keyEvents(stroke, layout: USKeyLayout.layout, source: nil).down) == 44)
        #expect(keyCode(try SyntheticEventBuilder.keyEvents(stroke, layout: Self.abnt2, source: nil).down) == 94)
        let cedilla = KeyStroke(.character("ç"), modifiers: [.command])
        #expect(keyCode(try SyntheticEventBuilder.keyEvents(cedilla, layout: Self.abnt2, source: nil).down) == 41)
    }

    @Test func aCharacterThatNeedsShiftOnTheLayoutGetsTheFlagEvenIfNotAsked() throws {
        let plus = try SyntheticEventBuilder.keyEvents(KeyStroke.parse("cmd++"), layout: USKeyLayout.layout, source: nil)
        #expect(keyCode(plus.down) == 24)
        #expect(plus.down.flags.contains(.maskCommand) && plus.down.flags.contains(.maskShift))
    }

    @Test func aCharacterWithNoKeyIsRefusedWithAnExplanation() {
        #expect(throws: ToolError.self) {
            try SyntheticEventBuilder.keyEvents(KeyStroke(.character("ç"), modifiers: [.command]), layout: USKeyLayout.layout, source: nil)
        }
        do {
            _ = try SyntheticEventBuilder.keyEvents(KeyStroke(.character("ç"), modifiers: []), layout: USKeyLayout.layout, source: nil)
        } catch {
            #expect(error.localizedDescription.contains("ç") && error.localizedDescription.contains("type"))
        }
    }

    @Test func namedKeysUseTheirFixedCodeOnAnyLayout() throws {
        for (text, code) in [("return", 36), ("escape", 53), ("tab", 48), ("left", 123), ("up", 126), ("f5", 96), ("delete", 51), ("space", 49)] as [(String, UInt16)] {
            for layout in [USKeyLayout.layout as any KeyLayout, Self.abnt2] {
                let events = try SyntheticEventBuilder.keyEvents(KeyStroke.parse(text), layout: layout, source: nil)
                #expect(keyCode(events.down) == code && events.down.flags.isEmpty, "\(text)")
            }
        }
        let arrow = try SyntheticEventBuilder.keyEvents(KeyStroke.parse("ctrl+option+left"), layout: USKeyLayout.layout, source: nil)
        #expect(keyCode(arrow.down) == 123 && arrow.down.flags.contains(.maskControl) && arrow.down.flags.contains(.maskAlternate))
    }

    @Test func keysAreSentInOrderToTheTargetPidOnly() async throws {
        let sink = RecordingSink()
        try await input(sink: sink).keys([KeyStroke.parse("cmd+a"), KeyStroke.parse("delete")], to: 4_242)
        #expect(sink.posted.map(\.pid) == [4_242, 4_242, 4_242, 4_242])
        #expect(sink.events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(sink.events.map(keyCode) == [0, 0, 51, 51])
    }

    @Test func aShortcutOnAKeyTheLayoutLacksPostsNothing() async {
        let sink = RecordingSink()
        await #expect(throws: ToolError.self) {
            try await input(sink: sink).keys([KeyStroke.parse("cmd+a"), KeyStroke(.character("ç"), modifiers: [.command])], to: 1)
        }
        #expect(sink.posted.count == 2, "the first shortcut went out, the second was never built")
    }

    // MARK: Text

    @Test func textIsCutInPiecesOfAtMostTwentyUTF16Units() {
        let text = String(repeating: "a", count: 45)
        let segments = SyntheticEventBuilder.segments(of: text)
        #expect(segments == [.text(String(repeating: "a", count: 20), characters: 20), .text(String(repeating: "a", count: 20), characters: 20),
                             .text("aaaaa", characters: 5)])
        #expect(SyntheticEventBuilder.segments(of: "").isEmpty)
        #expect(SyntheticEventBuilder.maxUnits == 20)
    }

    @Test func aCharacterIsNeverSplitAcrossPieces() {
        // 19 letters, then a 2-unit emoji: it would reach 21 units, so it starts the next piece.
        let text = String(repeating: "x", count: 19) + "😀" + "y"
        let segments = SyntheticEventBuilder.segments(of: text)
        #expect(segments == [.text(String(repeating: "x", count: 19), characters: 19), .text("😀y", characters: 2)])
        // A family emoji is 11 units and stays whole.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf16.count == 11)
        let mixed = SyntheticEventBuilder.segments(of: "abcdefghij" + family)
        #expect(mixed == [.text("abcdefghij", characters: 10), .text(family, characters: 1)])
        // Accents written as base letter plus combining mark are one character too.
        let decomposed = String(repeating: "e\u{301}", count: 15) // 30 units, 15 characters
        let pieces = SyntheticEventBuilder.segments(of: decomposed)
        #expect(pieces.count == 2)
        for case .text(let piece, let characters) in pieces {
            #expect(piece.utf16.count <= 20 && piece.count == characters)
        }
    }

    @Test func everyPieceFitsAndTheyAddUpToTheText() {
        var random = SystemRandomNumberGenerator()
        let alphabet = Array("abc ção😀é🇧🇷日本語\u{301}xyz.,;!?0123456789")
        for _ in 0..<200 {
            let text = String((0..<Int.random(in: 0...200, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            let segments = SyntheticEventBuilder.segments(of: text)
            var rebuilt = ""
            var characters = 0
            for case .text(let piece, let count) in segments {
                #expect(piece.utf16.count <= 20)
                rebuilt += piece
                characters += count
            }
            #expect(rebuilt == text)
            #expect(characters == text.count)
        }
    }

    @Test func aCharacterLongerThanTheLimitIsCutAtScalarBoundariesAndCountedOnce() {
        // A base letter with 25 combining marks: 26 units, one character.
        let stack = "a" + String(repeating: "\u{301}", count: 25)
        #expect(stack.count == 1)
        let segments = SyntheticEventBuilder.segments(of: stack)
        var rebuilt = ""
        var counted = 0
        for case .text(let piece, let count) in segments {
            #expect(piece.utf16.count <= 20)
            rebuilt += piece
            counted += count
        }
        #expect(rebuilt == stack && counted == 1)
    }

    @Test func newlinesAndTabsBecomeTheirOwnKeys() {
        let segments = SyntheticEventBuilder.segments(of: "um\ndois\r\ntrês\tfim")
        #expect(segments == [.text("um", characters: 2), .key(.return), .text("dois", characters: 4), .key(.return),
                             .text("três", characters: 4), .key(.tab), .text("fim", characters: 3)])
    }

    @Test func textEventsCarryTheStringAndNoModifiers() throws {
        let events = try SyntheticEventBuilder.textEvents("Olá, mundo 😀", source: nil)
        #expect(unicode(events.down) == "Olá, mundo 😀" && unicode(events.up) == "Olá, mundo 😀")
        #expect(events.down.type == .keyDown && events.up.type == .keyUp)
        #expect(events.down.flags.isEmpty)
    }

    @Test func typingPostsEachPieceToThePidAndReturnsTheCount() async throws {
        let sink = RecordingSink()
        let text = String(repeating: "abcde", count: 9) // 45 characters
        let typed = try await input(sink: sink).text(text, to: 777)
        #expect(typed == 45)
        #expect(sink.posted.allSatisfy { $0.pid == 777 })
        let downs = sink.events.filter { $0.type == .keyDown }
        let first: String = String(text.prefix(20))
        let second: String = String(text.dropFirst(20).prefix(20))
        let third: String = String(text.suffix(5))
        let expected: [String] = [first, second, third]
        #expect(downs.map { unicode($0) } == expected)
        #expect(sink.events.count == 6, "a key down and a key up for each of three pieces")
        #expect(sink.events.allSatisfy { $0.flags.isEmpty })
    }

    @Test func typingNewlinesPressesReturnAndTabPressesTab() async throws {
        let sink = RecordingSink()
        let typed = try await input(sink: sink).text("a\nb\tc", to: 5)
        #expect(typed == 5)
        let downs = sink.events.filter { $0.type == .keyDown }
        #expect(downs.count == 5)
        #expect(keyCode(downs[1]) == 36 && keyCode(downs[3]) == 48)
        #expect(unicode(downs[0]) == "a" && unicode(downs[2]) == "b" && unicode(downs[4]) == "c")
    }

    @Test func cancellingBetweenPiecesStopsAndReportsHowMuchWasTyped() async throws {
        let sink = RecordingSink()
        // The third piece's key-up is the 6th event: cancel the task right after it.
        sink.afterPost = { count in
            if count == 6 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let live = input(sink: sink)
        let text = String(repeating: "z", count: 200)
        let typed = try await Task { try await live.text(text, to: 9) }.value
        #expect(typed == 60, "three pieces of 20")
        #expect(sink.events.count == 6)
    }

    @Test func aTaskCancelledBeforeTypingTypesNothing() async throws {
        let sink = RecordingSink()
        let live = input(sink: sink)
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try await live.text("abc", to: 1)
        }
        task.cancel()
        #expect(try await task.value == 0 && sink.posted.isEmpty)
    }

    @Test func aFailureWhilePostingPropagates() async {
        struct Refused: Error {}
        struct RefusingSink: SyntheticEventSink { func post(_ event: CGEvent, to pid: Int32) throws { throw Refused() } }
        let live = LiveSyntheticInput(sink: RefusingSink(), layout: USKeyLayout.layout, pacing: .none, secureInput: { false })
        await #expect(throws: Refused.self) { try await live.text("a", to: 1) }
        await #expect(throws: Refused.self) { try await live.keys([KeyStroke.parse("return")], to: 1) }
    }

    @Test func secureInputIsReportedFromTheSystemQuery() {
        var live = input()
        #expect(!live.secureInputActive)
        live.secureInput = { true }
        #expect(live.secureInputActive)
    }

    // MARK: Mouse

    @Test func aClickIsMouseDownAndUpAimedAtTheWindow() throws {
        let events = try SyntheticEventBuilder.clickEvents(at: CGPoint(x: 410.5, y: -120), window: 321, button: .left, count: 1, source: nil)
        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp])
        for event in events {
            #expect(event.location == CGPoint(x: 410.5, y: -120))
            #expect(event.getIntegerValueField(.mouseEventClickState) == 1)
            #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 321)
            #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 321)
        }
    }

    @Test func aDoubleClickCountsTheClicks() throws {
        let events = try SyntheticEventBuilder.clickEvents(at: .zero, window: 1, button: .left, count: 2, source: nil)
        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        #expect(try SyntheticEventBuilder.clickEvents(at: .zero, window: 1, button: .left, count: 9, source: nil).count == 6, "at most a triple click")
        #expect(try SyntheticEventBuilder.clickEvents(at: .zero, window: 1, button: .left, count: 0, source: nil).count == 2)
    }

    @Test func otherButtonsUseTheirOwnEventTypes() throws {
        #expect(try SyntheticEventBuilder.clickEvents(at: .zero, window: 1, button: .right, count: 1, source: nil).map(\.type) == [.rightMouseDown, .rightMouseUp])
        let middle = try SyntheticEventBuilder.clickEvents(at: .zero, window: 1, button: .middle, count: 1, source: nil)
        #expect(middle.map(\.type) == [.otherMouseDown, .otherMouseUp])
        #expect(middle[0].getIntegerValueField(.mouseEventButtonNumber) == 2)
    }

    @Test func clickingPostsToThePidAndNeverToTheHIDTap() async throws {
        let sink = RecordingSink()
        try await input(sink: sink).click(at: CGPoint(x: 5, y: 6), window: 8, button: .left, count: 2, to: 31)
        #expect(sink.posted.count == 4 && sink.posted.allSatisfy { $0.pid == 31 })
        // The sink is the only way out: there is no other path that posts, so the cursor is never moved by these events.
        #expect(sink.events.allSatisfy { $0.location == CGPoint(x: 5, y: 6) })
    }

    // MARK: Scroll

    @Test func aScrollIsCutIntoSteps() {
        #expect(SyntheticEventBuilder.scrollSteps(0).isEmpty)
        #expect(SyntheticEventBuilder.scrollSteps(50) == [50])
        #expect(SyntheticEventBuilder.scrollSteps(130) == [60, 60, 10])
        #expect(SyntheticEventBuilder.scrollSteps(-130) == [-60, -60, -10])
        for total in [1, 59, 61, 600, 2_400, 8_000, -8_000] {
            let steps = SyntheticEventBuilder.scrollSteps(total)
            #expect(steps.reduce(0, +) == total)
            #expect(steps.count <= 45, "\(total): \(steps.count)")
        }
    }

    @Test func scrollEventsArePixelUnitsAtThePointOverTheWindow() throws {
        let events = try SyntheticEventBuilder.scrollEvents(dx: 0, dy: 130, at: CGPoint(x: 300, y: 200), window: 44, source: nil)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.type == .scrollWheel && $0.location == CGPoint(x: 300, y: 200) })
        #expect(events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } == [60, 60, 10])
        #expect(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0 })
        #expect(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 })
        let sideways = try SyntheticEventBuilder.scrollEvents(dx: -70, dy: 0, at: .zero, window: 1, source: nil)
        #expect(sideways.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == [-60, -10])
        let both = try SyntheticEventBuilder.scrollEvents(dx: 60, dy: 120, at: .zero, window: 1, source: nil)
        #expect(both.count == 2 && both[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 60 && both[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 60)
        #expect(both[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
    }

    @Test func scrollingPostsEveryStepToThePid() async throws {
        let sink = RecordingSink()
        try await input(sink: sink).scroll(dx: 0, dy: -300, at: CGPoint(x: 1, y: 2), window: 3, to: 66)
        #expect(sink.posted.count == 5 && sink.posted.allSatisfy { $0.pid == 66 })
    }

    // MARK: The live pieces

    @Test func theKeyLayoutOfThisMacAnswersWithoutCrashing() async {
        // Asked from a background task, which is how the tools ask: it reaches the main queue for the Text Input Sources.
        let known = await Task.detached { () -> (a: KeyLayoutEntry?, space: KeyLayoutEntry?, count: Int) in
            let layout = LiveKeyLayout()
            return (layout.entry(for: "a"), layout.entry(for: " "), layout.current.characters.count)
        }.value
        #expect(known.a != nil && known.space?.keyCode == 49)
        #expect(known.count > 40)
        let probe = LiveKeyLayout()
        let wanted: [Character] = ["ç", "/", "\\", ";", "[", "'", "s", "?"]
        let found = wanted.map { character -> String in
            guard let entry = probe.entry(for: character) else { return "\(character)=none" }
            return "\(character)=\(entry.keyCode)\(entry.shift ? "+shift" : "")\(entry.option ? "+opt" : "")"
        }
        print("layout of this Mac:", found)
    }

    @Test func theEventSinkRefusesTheOrbItselfAndAPidThatIsGone() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        // Without the Accessibility permission the first guard speaks; with it, the pid checks do. Either way: refused.
        #expect(throws: ToolError.self) { try PidEventSink().post(event, to: ProcessInfo.processInfo.processIdentifier) }
        #expect(throws: ToolError.self) { try PidEventSink().post(event, to: 2_000_000_000) }
    }
}
