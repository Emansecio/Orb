import SwiftUI
import AppKit

/// Keyboard answers for the newest open approval card: ⌘↩ allows, Esc denies. ⌘↩ typed in the main composer is not
/// ours: there it stops the turn (which denies the card) and sends what was written (see `ComposerView`).
enum ApprovalShortcut: Equatable {
    case allow, deny

    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let escapeKey: UInt16 = 53

    /// What a key press means for the card, or nil when it is not ours. Esc never counts while the user is editing
    /// text: it belongs to the field (cancelling an input method's composition, leaving the note). ⌘↩ answers from
    /// the card's own note field but not while something is typed in the composer (`isTypingInComposer`).
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isEditingText: Bool,
                        isTypingInComposer: Bool = false) -> ApprovalShortcut? {
        let held = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch keyCode {
        case returnKey, enterKey:
            return held == .command && !isTypingInComposer ? .allow : nil
        case escapeKey:
            return held.isEmpty && !isEditingText ? .deny : nil
        default:
            return nil
        }
    }

    // MARK: Feedback

    /// How long the button a shortcut stands for shows pressed before the card is answered: the beat of `Motion.press`,
    /// so the person sees what the key did (docs/MOVIMENTO.md §2.4).
    static let pressDuration = Duration.milliseconds(120)
    /// The scale of a pressed button.
    static let pressScale: CGFloat = 0.97

    /// The wait between the key and the answer: none under Reduce Motion, where nothing is shown pressed.
    static func pressDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .zero : pressDuration
    }

    /// Whether a text field is being edited. The composer is focused by default, so an empty field does not count:
    /// something typed, text being composed, or the card's own note field does.
    static func isEditing(responderIsText: Bool, hasText: Bool, hasMarkedText: Bool, noteFocused: Bool) -> Bool {
        noteFocused || (responderIsText && (hasText || hasMarkedText))
    }

    /// Whether the editing is in the main composer: a text field is being edited and it is not the card's note.
    static func isTypingInComposer(isEditing: Bool, noteFocused: Bool) -> Bool { isEditing && !noteFocused }
}

/// Listens for keys in its window while it is on screen. `handler` returns true when it used the key.
struct ApprovalKeyMonitor: NSViewRepresentable {
    let handler: @MainActor (NSEvent, NSWindow) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

    final class MonitorView: NSView {
        var handler: (@MainActor (NSEvent, NSWindow) -> Bool)?
        private var token: Token?

        /// Removes the monitor when the view goes away, whatever thread releases it.
        private final class Token: @unchecked Sendable {
            let monitor: Any
            init(_ monitor: Any) { self.monitor = monitor }
            deinit { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            token = nil
            guard window != nil else { return }
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread; the event never leaves it.
                nonisolated(unsafe) let event = event
                let used = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return false }
                    return self.handler?(event, window) == true
                }
                return used ? nil : event
            }
            token = monitor.map(Token.init)
        }
    }
}
