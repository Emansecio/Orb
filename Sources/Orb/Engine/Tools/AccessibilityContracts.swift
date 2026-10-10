import CoreGraphics
import Foundation

// The seams of background computer use (docs/USO-DO-COMPUTADOR.md): what the Accessibility layer needs from the rest of
// macOS, as small protocols so each piece is built and tested on its own against fakes. Nothing here does any work. The
// stand-ins at the bottom are what `AccessibilitySystem` hands out until a real implementation replaces them.

// MARK: - Reading with failures

/// The outcome of reading attributes when the caller must tell "the element has none" from "the app did not answer".
enum AXRead: Sendable {
    /// The attributes the element has (a missing one is simply absent).
    case values([String: AXAttributeValue])
    /// The app, not the attribute, is the problem: hung (`cannotComplete`), gone (`invalidElement`), or denied.
    case failed(AXFailure)

    var attributes: [String: AXAttributeValue]? { if case .values(let values) = self { values } else { nil } }
    var failure: AXFailure? { if case .failed(let failure) = self { failure } else { nil } }
}

// MARK: - Notifications

/// An Accessibility notification the tools can wait for. The raw value is the API's own string.
enum AXNotification: String, Sendable, CaseIterable, Hashable {
    case valueChanged = "AXValueChanged"
    case elementDestroyed = "AXUIElementDestroyed"
    case created = "AXCreated"
    case windowCreated = "AXWindowCreated"
    case focusedElementChanged = "AXFocusedUIElementChanged"
    case focusedWindowChanged = "AXFocusedWindowChanged"
    case titleChanged = "AXTitleChanged"
    case selectedChildrenChanged = "AXSelectedChildrenChanged"
    case selectedRowsChanged = "AXSelectedRowsChanged"
    case selectedTextChanged = "AXSelectedTextChanged"
    case layoutChanged = "AXLayoutChanged"
    case sheetCreated = "AXSheetCreated"
    case rowCountChanged = "AXRowCountChanged"
    case loadComplete = "AXLoadComplete"
    /// Not an interface change: the app became the active one (what a screen takeover waits for).
    case applicationActivated = "AXApplicationActivated"
}

/// One notification, as it arrived.
struct AXEvent: Sendable {
    var notification: AXNotification
    var pid: Int32
    /// The element it is about; nil when the app did not say.
    var element: (any AccessibilityElement)?
    var receivedAt: ContinuousClock.Instant

    init(_ notification: AXNotification, pid: Int32, element: (any AccessibilityElement)? = nil,
         receivedAt: ContinuousClock.Instant = .now) {
        self.notification = notification
        self.pid = pid
        self.element = element
        self.receivedAt = receivedAt
    }
}

/// Notifications from running apps (`AXObserver`).
protocol AccessibilityEvents: Sendable {
    /// The given notifications from one app, optionally only for `element` (the app itself when nil). Subscribing happens
    /// before the stream is returned, so an action taken right after cannot be missed. The subscription ends when the
    /// stream is no longer iterated. A stream that finishes at once means notifications are not available for that app:
    /// the caller falls back to polling.
    func events(pid: Int32, _ notifications: Set<AXNotification>, on element: (any AccessibilityElement)?) -> AsyncStream<AXEvent>
}

extension AccessibilityEvents {
    func events(pid: Int32, _ notifications: Set<AXNotification>) -> AsyncStream<AXEvent> {
        events(pid: pid, notifications, on: nil)
    }
}

// MARK: - Keys

/// A key press with modifiers, independent of the keyboard layout until it is sent.
struct KeyStroke: Sendable, Equatable, CustomStringConvertible {
    struct Modifiers: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Keys that have a fixed place on every layout.
    enum Named: Sendable, Equatable, Hashable {
        case `return`, escape, tab, space, delete, forwardDelete
        case up, down, left, right, home, end, pageUp, pageDown
        /// F1…F12.
        case function(Int)

        /// The virtual key code (`kVK_*`), the same on every layout.
        var virtualKey: UInt16 {
            switch self {
            case .return: 36
            case .tab: 48
            case .space: 49
            case .delete: 51
            case .escape: 53
            case .forwardDelete: 117
            case .home: 115
            case .end: 119
            case .pageUp: 116
            case .pageDown: 121
            case .left: 123
            case .right: 124
            case .down: 125
            case .up: 126
            case .function(let number):
                // F1…F12 are not contiguous.
                [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111][max(1, min(number, 12)) - 1]
            }
        }

        fileprivate static let byName: [String: Named] = {
            var names: [String: Named] = [
                "return": .return, "enter": .return, "escape": .escape, "esc": .escape, "tab": .tab, "space": .space,
                "delete": .delete, "backspace": .delete, "forwarddelete": .forwardDelete,
                "up": .up, "down": .down, "left": .left, "right": .right,
                "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
            ]
            for number in 1...12 { names["f\(number)"] = .function(number) }
            return names
        }()

        fileprivate var name: String {
            switch self {
            case .return: "return"
            case .escape: "escape"
            case .tab: "tab"
            case .space: "space"
            case .delete: "delete"
            case .forwardDelete: "forwarddelete"
            case .up: "up"
            case .down: "down"
            case .left: "left"
            case .right: "right"
            case .home: "home"
            case .end: "end"
            case .pageUp: "pageup"
            case .pageDown: "pagedown"
            case .function(let number): "f\(number)"
            }
        }
    }

    enum Key: Sendable, Equatable, Hashable {
        case named(Named)
        /// A character key, lowercased; the layout in use decides which physical key produces it.
        case character(Character)
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unknownModifier(String)
        case unknownKey(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Atalho vazio. Use por exemplo \"cmd+s\" ou \"return\"."
            case .unknownModifier(let text): "Modificador desconhecido \"\(text)\". Use cmd, shift, option (ou alt) e ctrl."
            case .unknownKey(let text): "Tecla desconhecida \"\(text)\". Use uma letra, um número ou um nome como return, tab, escape, up, f5."
            }
        }
    }

    var key: Key
    var modifiers: Modifiers

    init(_ key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "cmd+shift+s", "return", "ctrl+option+left", "cmd++" (the plus key). Modifiers: cmd (command), shift, option (alt,
    /// opt), ctrl (control). Keys: return (enter), escape (esc), tab, space, delete (backspace), forwarddelete, up, down,
    /// left, right, home, end, pageup, pagedown, f1…f12, or one character. Case does not matter; an uppercase letter
    /// alone ("A", with no modifier) means shift plus the letter, while "Cmd+Z" is ⌘Z (shift only when written).
    static func parse(_ text: String) throws -> KeyStroke {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        var modifierTokens: [Substring]
        let keyText: String
        if trimmed.hasSuffix("+") {
            // The plus key itself: "+" or "cmd++".
            keyText = "+"
            let rest = trimmed.dropLast()
            if rest.isEmpty {
                modifierTokens = []
            } else if rest.hasSuffix("+"), rest.count > 1 {
                modifierTokens = rest.dropLast().split(separator: "+", omittingEmptySubsequences: false)
            } else {
                throw ParseError.unknownKey(trimmed)
            }
        } else {
            let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            keyText = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
            modifierTokens = Array(parts.dropLast())
        }

        var modifiers: Modifiers = []
        for token in modifierTokens {
            switch token.trimmingCharacters(in: .whitespaces).lowercased() {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt", "opt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: throw ParseError.unknownModifier(String(token))
            }
        }

        if let named = Named.byName[keyText.lowercased()] { return KeyStroke(.named(named), modifiers: modifiers) }
        guard keyText.count == 1, let character = keyText.first else { throw ParseError.unknownKey(keyText) }
        // Only a lone letter carries an implicit shift: in "Cmd+Z" the capital is just how the shortcut is written.
        if character.isUppercase, modifierTokens.isEmpty { modifiers.insert(.shift) }
        let lower = character.lowercased()
        return KeyStroke(.character(lower.count == 1 ? Character(lower) : character), modifiers: modifiers)
    }

    /// The canonical spelling, which `parse` reads back: "cmd+shift+s".
    var description: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        switch key {
        case .named(let named): parts.append(named.name)
        case .character(let character): parts.append(String(character))
        }
        return parts.joined(separator: "+")
    }
}

// MARK: - Synthetic input

enum MouseButton: String, Sendable, Equatable, Hashable {
    case left, right, middle
}

/// Keyboard and mouse events sent to one process (`CGEvent.postToPid`): they do not move the cursor or touch the focus of
/// the person using the Mac. Points are in screen coordinates (origin at the top left of the main display, like
/// Accessibility frames); `window` is the `CGWindowID` the event is meant for.
protocol SyntheticInput: Sendable {
    /// Whether Secure Event Input is on (a password field somewhere): keystrokes may be dropped.
    var secureInputActive: Bool { get }
    /// Presses each stroke in turn.
    func keys(_ strokes: [KeyStroke], to pid: Int32) async throws
    /// Types text in chunks, stopping between chunks when the task is cancelled. Returns how many characters were sent.
    @discardableResult func text(_ text: String, to pid: Int32) async throws -> Int
    func click(at point: CGPoint, window: UInt32, button: MouseButton, count: Int, to pid: Int32) async throws
    /// Scrolls by pixels; positive `dy` moves the content down (the page goes up), like a trackpad.
    func scroll(dx: Int, dy: Int, at point: CGPoint, window: UInt32, to pid: Int32) async throws
}

// MARK: - Window capture

/// A window ScreenCaptureKit can capture.
struct CapturableWindow: Sendable, Equatable {
    var windowID: UInt32
    var pid: Int32
    /// In screen points.
    var frame: CGRect
    var title: String
    var isOnScreen: Bool

    init(windowID: UInt32, pid: Int32, frame: CGRect, title: String = "", isOnScreen: Bool = true) {
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
        self.title = title
        self.isOnScreen = isOnScreen
    }
}

/// Images of single windows, also when covered or on another Space.
protocol WindowCapturer: Sendable {
    func windows(pid: Int32) async throws -> [CapturableWindow]
    /// The window's own pixels, nominal resolution, scaled down so the longer side is at most `maxSide`.
    func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage
}

// MARK: - Taking the screen over

/// The real mouse and keyboard, available only inside `ScreenOwner.takeOver`.
protocol TakeoverHand: Sendable {
    func click(at point: CGPoint, button: MouseButton, count: Int) async throws
    func type(_ text: String) async throws
    func key(_ stroke: KeyStroke) async throws
    /// Presses at `start`, moves in interpolated steps and releases at `end`.
    func drag(from start: CGPoint, to end: CGPoint) async throws
}

struct TakeoverReport<Value: Sendable>: Sendable {
    var value: Value
    var duration: Duration
    /// The app put back in front (its name); nil when nothing needed restoring.
    var restoredApp: String?
    /// Whether the pointer is back where it was.
    var cursorRestored: Bool
    /// The app that was in front could not be put back (neither way worked): the person must be told.
    var restoreFailed: Bool

    init(value: Value, duration: Duration, restoredApp: String? = nil, cursorRestored: Bool = true, restoreFailed: Bool = false) {
        self.value = value
        self.duration = duration
        self.restoredApp = restoredApp
        self.cursorRestored = cursorRestored
        self.restoreFailed = restoreFailed
    }
}

/// Lends the screen to a Orb for a short time and gives it back. Whatever happens to `body` (it throws, the task is
/// cancelled, time runs out), the front app, its focused window and the cursor are restored before this returns, and the
/// restoration itself cannot be cancelled. Only one takeover runs on the whole system.
protocol ScreenOwner: Sendable {
    /// Brings `app` (and `window`, its target window, when given) to the front, runs `body` with the real input, and
    /// restores. `limit` caps the whole takeover (10 s by design).
    func takeOver<Value: Sendable>(_ app: AccessibilityApp, window: (any AccessibilityElement)?, limit: Duration,
                                   _ body: @escaping @Sendable (any TakeoverHand) async throws -> Value) async throws -> TakeoverReport<Value>
}

// MARK: - Not available yet

private func unavailable(_ what: String) -> ToolError { ToolError("\(what) ainda não está disponível neste motor.") }

/// Hands out nothing: the stream ends at once, which callers read as "no notifications".
struct UnavailableAccessibilityEvents: AccessibilityEvents {
    func events(pid: Int32, _ notifications: Set<AXNotification>, on element: (any AccessibilityElement)?) -> AsyncStream<AXEvent> {
        AsyncStream { $0.finish() }
    }
}

struct UnavailableSyntheticInput: SyntheticInput {
    var secureInputActive: Bool { false }
    func keys(_ strokes: [KeyStroke], to pid: Int32) async throws { throw unavailable("O envio de teclas ao app") }
    func text(_ text: String, to pid: Int32) async throws -> Int { throw unavailable("A digitação no app") }
    func click(at point: CGPoint, window: UInt32, button: MouseButton, count: Int, to pid: Int32) async throws {
        throw unavailable("O clique no app")
    }
    func scroll(dx: Int, dy: Int, at point: CGPoint, window: UInt32, to pid: Int32) async throws { throw unavailable("A rolagem no app") }
}

struct UnavailableWindowCapturer: WindowCapturer {
    func windows(pid: Int32) async throws -> [CapturableWindow] { throw unavailable("A captura de janelas") }
    func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage { throw unavailable("A captura de janelas") }
}

struct UnavailableScreenOwner: ScreenOwner {
    func takeOver<Value: Sendable>(_ app: AccessibilityApp, window: (any AccessibilityElement)?, limit: Duration,
                                   _ body: @escaping @Sendable (any TakeoverHand) async throws -> Value) async throws -> TakeoverReport<Value> {
        throw unavailable("Assumir a tela")
    }
}
