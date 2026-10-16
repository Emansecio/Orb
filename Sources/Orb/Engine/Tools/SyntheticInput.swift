import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// Keyboard, mouse and scroll events sent to one process (`CGEvent.postToPid`), the "N1" step of background computer use
// (docs/USO-DO-COMPUTADOR.md): they reach the app without moving the cursor or touching the focus of the person using the
// Mac. Nothing here posts to the HID tap (that belongs to the screen takeover only) and nothing touches the clipboard.
//
// The work is split in three so each part is tested alone: `SyntheticEventBuilder` builds the events (pure), `KeyLayout`
// says which key types a character on the keyboard in use, and a `SyntheticEventSink` delivers them (the real one posts to
// the pid; tests record them).

// MARK: - Keyboard layouts

/// The key that types a character on a layout: its virtual key code and the modifiers the layout needs for it.
struct KeyLayoutEntry: Sendable, Equatable {
    var keyCode: UInt16
    var shift = false
    var option = false
}

/// Which physical key produces a character. ABNT2 is not US: "/" is on another key, "ç" has one, "\" moves.
protocol KeyLayout: Sendable {
    func entry(for character: Character) -> KeyLayoutEntry?
}

/// A layout built by asking "what does this key type with these modifiers?" for every key: the live layout answers with
/// `UCKeyTranslate`, tests with a table. Plain keys win over shifted ones, shifted over option ones; among equals the
/// lowest key code wins, and the numeric keypad is left out so "5" is the number row's key.
struct TranslatedKeyLayout: KeyLayout {
    private let table: [Character: KeyLayoutEntry]

    enum State: CaseIterable {
        case plain, shift, option, shiftOption

        var shift: Bool { self == .shift || self == .shiftOption }
        var option: Bool { self == .option || self == .shiftOption }
    }

    /// Key codes of the numeric keypad and the keys that never type text.
    static let ignoredKeyCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// `translate(keyCode, state)` is what the key types; nil when it types nothing or starts a dead-key sequence.
    init(translate: (UInt16, State) -> String?) {
        var table: [Character: KeyLayoutEntry] = [:]
        for state in State.allCases {
            for keyCode in UInt16(0)..<128 where !Self.ignoredKeyCodes.contains(keyCode) {
                guard let typed = translate(keyCode, state), typed.count == 1, let character = typed.first,
                      !character.isNewline, character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { continue }
                if table[character] == nil { table[character] = KeyLayoutEntry(keyCode: keyCode, shift: state.shift, option: state.option) }
            }
        }
        self.table = table
    }

    func entry(for character: Character) -> KeyLayoutEntry? {
        if let hit = table[character] { return hit }
        let lower = String(character).lowercased()
        return lower.count == 1 ? lower.first.flatMap { table[$0] } : nil
    }

    /// Characters the layout can type (for messages and tests).
    var characters: Set<Character> { Set(table.keys) }
}

/// The US keyboard, the layout assumed when the system cannot be asked.
enum USKeyLayout {
    static let keys: [UInt16: (String, String)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"),
        8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
        16: ("y", "Y"), 17: ("t", "T"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"),
        23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"),
        30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"), 37: ("l", "L"),
        38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"), 42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"),
        45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
    ]

    static let layout = TranslatedKeyLayout { keyCode, state in
        guard let pair = keys[keyCode] else { return nil }
        switch state {
        case .plain: return pair.0
        case .shift: return pair.1
        case .option, .shiftOption: return nil
        }
    }
}

/// The keyboard layout in use now, asked of the system (`UCKeyTranslate` over the current layout's data) and remembered
/// for a few seconds. When the system cannot answer in time the US layout stands in.
final class LiveKeyLayout: KeyLayout, @unchecked Sendable {
    static let shared = LiveKeyLayout()

    private let lock = NSLock()
    private var cached: (layout: TranslatedKeyLayout, at: ContinuousClock.Instant)?
    private let lifetime: Duration

    init(lifetime: Duration = .seconds(10)) {
        self.lifetime = lifetime
    }

    func entry(for character: Character) -> KeyLayoutEntry? { current.entry(for: character) }

    var current: TranslatedKeyLayout {
        let now = ContinuousClock.now
        if let hit = lock.withLock({ cached.flatMap { now - $0.at < lifetime ? $0.layout : nil }}) { return hit }
        let fresh = Self.systemLayout() ?? USKeyLayout.layout
        lock.withLock { cached = (fresh, now) }
        return fresh
    }

    /// Text Input Sources must be asked on the main queue (a background call can trap). The wait is bounded so a busy main
    /// thread cannot hang a tool.
    private static func systemLayout() -> TranslatedKeyLayout? {
        if Thread.isMainThread { return readLayout() }
        let box = LayoutBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.value = readLayout()
            done.signal()
        }
        return done.wait(timeout: .now() + .milliseconds(400)) == .success ? box.value : nil
    }

    private final class LayoutBox: @unchecked Sendable { var value: TranslatedKeyLayout? }

    private static func readLayout() -> TranslatedKeyLayout? {
        // The documented name of `kTISPropertyUnicodeKeyLayoutData`: the C global is not usable under Swift 6 concurrency checking.
        let property = "TISPropertyUnicodeKeyLayoutData" as CFString
        var sources: [TISInputSource] = [TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()]
        sources.append(TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue())
        for source in sources {
            guard let raw = TISGetInputSourceProperty(source, property) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let layoutPointer = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 0)
            return TranslatedKeyLayout { keyCode, state in
                var modifiers: UInt32 = 0
                if state.shift { modifiers |= UInt32(shiftKey >> 8) }
                if state.option { modifiers |= UInt32(optionKey >> 8) }
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layoutPointer, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0,
                                            &deadKeys, characters.count, &length, &characters)
                guard status == noErr, length > 0, deadKeys == 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
        return nil
    }
}

// MARK: - Building events

/// A piece of text to type: letters sent as a Unicode string, or a key that has a place of its own.
enum TypingSegment: Equatable, Sendable {
    /// At most 20 UTF-16 units; `characters` is how many characters of the text it carries.
    case text(String, characters: Int)
    case key(KeyStroke.Named)
}

enum SyntheticEventBuilder {
    /// The most UTF-16 units one keyboard event carries reliably.
    static let maxUnits = 20

    /// Splits `text` for typing: newlines become Return, tabs become Tab, the rest is cut into runs of at most `maxUnits`
    /// UTF-16 units without splitting a character (a family emoji stays whole; only a character longer than the limit by
    /// itself is cut, at a scalar boundary).
    static func segments(of text: String) -> [TypingSegment] {
        var result: [TypingSegment] = []
        var run = ""
        var runUnits = 0
        var runCharacters = 0
        func flush() {
            if !run.isEmpty { result.append(.text(run, characters: runCharacters)) }
            run = ""; runUnits = 0; runCharacters = 0
        }
        for character in text {
            if character.isNewline {
                flush()
                result.append(.key(.return))
                continue
            }
            if character == "\t" {
                flush()
                result.append(.key(.tab))
                continue
            }
            let units = character.utf16.count
            if units > maxUnits {
                flush()
                var piece = ""
                var pieceUnits = 0
                var pieces: [String] = []
                for scalar in character.unicodeScalars {
                    let scalarUnits = scalar.utf16.count
                    if pieceUnits + scalarUnits > maxUnits { pieces.append(piece); piece = ""; pieceUnits = 0 }
                    piece.unicodeScalars.append(scalar)
                    pieceUnits += scalarUnits
                }
                if !piece.isEmpty { pieces.append(piece) }
                for (index, part) in pieces.enumerated() { result.append(.text(part, characters: index == pieces.count - 1 ? 1 : 0)) }
                continue
            }
            if runUnits + units > maxUnits { flush() }
            run.append(character)
            runUnits += units
            runCharacters += 1
        }
        flush()
        return result
    }

    static func flags(for modifiers: KeyStroke.Modifiers, extraShift: Bool = false, extraOption: Bool = false) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) || extraShift { flags.insert(.maskShift) }
        if modifiers.contains(.option) || extraOption { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    /// Key down and key up for a stroke. Named keys use their fixed code; characters ask the layout, adding the shift or
    /// option that layout needs to the modifiers asked for. The flags are set explicitly, so what the person holds down on
    /// the real keyboard cannot leak in.
    static func keyEvents(_ stroke: KeyStroke, layout: any KeyLayout, source: CGEventSource?) throws -> (down: CGEvent, up: CGEvent) {
        let code: UInt16
        var flags: CGEventFlags
        switch stroke.key {
        case .named(let named):
            code = named.virtualKey
            flags = Self.flags(for: stroke.modifiers)
        case .character(let character):
            guard let entry = layout.entry(for: character) else {
                throw ToolError("A tecla “\(character)” não existe no teclado em uso; digite o texto com type em vez de um atalho.")
            }
            code = entry.keyCode
            flags = Self.flags(for: stroke.modifiers, extraShift: entry.shift, extraOption: entry.option)
        }
        return try pair(code: code, flags: flags, unicode: nil, source: source)
    }

    /// Key down and key up carrying a Unicode string (the key code is a placeholder; apps read the characters).
    static func textEvents(_ text: String, source: CGEventSource?) throws -> (down: CGEvent, up: CGEvent) {
        try pair(code: 0, flags: [], unicode: text, source: source)
    }

    private static func pair(code: UInt16, flags: CGEventFlags, unicode: String?, source: CGEventSource?) throws -> (down: CGEvent, up: CGEvent) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
            throw ToolError("O macOS não deixou criar o evento de teclado.")
        }
        for event in [down, up] {
            event.flags = flags
            if let unicode {
                let units = Array(unicode.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
        }
        return (down, up)
    }

    /// Mouse down and up for each click of a multi-click (`mouseEventClickState` counts 1, 2…), aimed at a window by its
    /// `CGWindowID` and positioned in screen points. The cursor is not moved: the events go to the pid, not to the HID tap.
    static func clickEvents(at point: CGPoint, window: UInt32, button: MouseButton, count: Int, source: CGEventSource?) throws -> [CGEvent] {
        let types: (down: CGEventType, up: CGEventType, button: CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        var events: [CGEvent] = []
        for click in 1...max(1, min(count, 3)) {
            for type in [types.down, types.up] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: types.button) else {
                    throw ToolError("O macOS não deixou criar o evento do mouse.")
                }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
                events.append(event)
            }
        }
        return events
    }

    /// The amounts a scroll is cut into, so apps see a gesture and not one huge jump (at most about 40 steps).
    static func scrollSteps(_ total: Int) -> [Int] {
        guard total != 0 else { return [] }
        let step = max(60, abs(total) / 40 + 1)
        var left = abs(total)
        var steps: [Int] = []
        while left > 0 {
            let part = min(step, left)
            steps.append(total < 0 ? -part : part)
            left -= part
        }
        return steps
    }

    /// Pixel scroll events at `point` (screen points, over the window): positive `dy` moves the content down, like a trackpad.
    static func scrollEvents(dx: Int, dy: Int, at point: CGPoint, window: UInt32, source: CGEventSource?) throws -> [CGEvent] {
        let horizontal = scrollSteps(dx)
        let vertical = scrollSteps(dy)
        var events: [CGEvent] = []
        for index in 0..<max(horizontal.count, vertical.count) {
            let x = Int32(horizontal.indices.contains(index) ? horizontal[index] : 0)
            let y = Int32(vertical.indices.contains(index) ? vertical[index] : 0)
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else {
                throw ToolError("O macOS não deixou criar o evento de rolagem.")
            }
            // Unlike mouse events, a scroll event keeps no window fields (they read back as 0): the app finds the window
            // under `location`, which is why the point matters and `window` is only the caller's record of where it aimed.
            event.location = point
            events.append(event)
        }
        return events
    }
}

// MARK: - Delivering events

/// Where built events go.
protocol SyntheticEventSink: Sendable {
    func post(_ event: CGEvent, to pid: Int32) throws
}

/// Posts to one process (`CGEvent.postToPid`). Refuses the Orb's own pid and a pid that is gone.
struct PidEventSink: SyntheticEventSink {
    func post(_ event: CGEvent, to pid: Int32) throws {
        guard AXIsProcessTrusted() else { throw ToolError(MacPermissionProblem.accessibility.modelMessage) }
        guard pid != ProcessInfo.processInfo.processIdentifier else { throw ToolError("O Orb não envia teclas nem cliques para si mesmo.") }
        guard kill(pid, 0) == 0 || errno == EPERM else { throw ToolError("O app (pid \(pid)) não está mais aberto.") }
        event.postToPid(pid)
    }
}

/// The waits between events: long enough for an app to take them in, short enough to type 2,000 characters in well under
/// a second.
struct SyntheticPacing: Sendable {
    var betweenKeys: Duration = .milliseconds(12)
    var betweenChunks: Duration = .milliseconds(1)
    var betweenClicks: Duration = .milliseconds(15)
    var betweenScrolls: Duration = .milliseconds(8)

    static let none = SyntheticPacing(betweenKeys: .zero, betweenChunks: .zero, betweenClicks: .zero, betweenScrolls: .zero)
}

struct LiveSyntheticInput: SyntheticInput {
    static let shared = LiveSyntheticInput()

    var sink: any SyntheticEventSink = PidEventSink()
    var layout: any KeyLayout = LiveKeyLayout.shared
    var pacing = SyntheticPacing()
    /// Whether Secure Event Input is on; replaceable so tests need no password field.
    var secureInput: @Sendable () -> Bool = { IsSecureEventInputEnabled() }

    var secureInputActive: Bool { secureInput() }

    /// A source of its own, so the person's held keys and buttons are not mixed into the events.
    private var source: CGEventSource? { CGEventSource(stateID: .privateState) }

    private func pause(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }

    func keys(_ strokes: [KeyStroke], to pid: Int32) async throws {
        let source = source
        for stroke in strokes {
            try Task.checkCancellation()
            let events = try SyntheticEventBuilder.keyEvents(stroke, layout: layout, source: source)
            try sink.post(events.down, to: pid)
            try sink.post(events.up, to: pid)
            try await pause(pacing.betweenKeys)
        }
    }

    @discardableResult
    func text(_ text: String, to pid: Int32) async throws -> Int {
        let source = source
        var sent = 0
        for segment in SyntheticEventBuilder.segments(of: text) {
            // Stopping between pieces keeps what was typed whole; the caller is told how much went out.
            if Task.isCancelled { break }
            switch segment {
            case .text(let piece, let characters):
                let events = try SyntheticEventBuilder.textEvents(piece, source: source)
                try sink.post(events.down, to: pid)
                try sink.post(events.up, to: pid)
                sent += characters
            case .key(let named):
                let events = try SyntheticEventBuilder.keyEvents(KeyStroke(.named(named)), layout: layout, source: source)
                try sink.post(events.down, to: pid)
                try sink.post(events.up, to: pid)
                sent += 1
            }
            try? await pause(pacing.betweenChunks)
        }
        return sent
    }

    func click(at point: CGPoint, window: UInt32, button: MouseButton, count: Int, to pid: Int32) async throws {
        let events = try SyntheticEventBuilder.clickEvents(at: point, window: window, button: button, count: count, source: source)
        for (index, event) in events.enumerated() {
            // Stop is looked at only before a press: between a press and its release it would leave the button held down in the app.
            if index % 2 == 0 { try Task.checkCancellation() }
            try sink.post(event, to: pid)
            // A gap after each release, so the app sees two clicks and not one long one.
            if index % 2 == 1, index < events.count - 1 { try await pause(pacing.betweenClicks) }
        }
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint, window: UInt32, to pid: Int32) async throws {
        let events = try SyntheticEventBuilder.scrollEvents(dx: dx, dy: dy, at: point, window: window, source: source)
        for event in events {
            try Task.checkCancellation()
            try sink.post(event, to: pid)
            try await pause(pacing.betweenScrolls)
        }
    }
}
