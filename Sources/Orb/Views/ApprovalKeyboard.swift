import SwiftUI
import AppKit

/// Keyboard answers for the newest open approval card: ⌘↩ allows, Esc denies. ⌘↩ typed in the main composer is not
/// ours: it would mean "stop and send" there, which the composer turns off while a card is open, so a reflex ⌘↩ never
/// refuses a request (see `ComposerAction.stopAndSendEnabled`).
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
        // Only the real modifiers count: caps lock, numeric pad and fn (set by arrows and F-keys) are ignored.
        let held = modifiers.intersection([.shift, .control, .option, .command, .help])
        switch keyCode {
        case returnKey, enterKey:
            return held == .command && !isTypingInComposer ? .allow : nil
        case escapeKey:
            return held.isEmpty && !isEditingText ? .deny : nil
        default:
            return nil
        }
    }

    /// `resolve` for a key pressed with `responderIsText` &c. describing the window's first responder: the reading every card
    /// repeated (is a field being edited, is it the composer, then what the key means).
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, responderIsText: Bool, hasText: Bool,
                        hasMarkedText: Bool, noteFocused: Bool) -> ApprovalShortcut? {
        let editing = isEditing(responderIsText: responderIsText, hasText: hasText, hasMarkedText: hasMarkedText,
                                noteFocused: noteFocused)
        return resolve(keyCode: keyCode, modifiers: modifiers, isEditingText: editing,
                       isTypingInComposer: isTypingInComposer(isEditing: editing, noteFocused: noteFocused))
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

// MARK: The cards' shared wiring

extension AnyTransition {
    /// What an open approval card does when it is answered: fades out at the exit pace, whatever the animation of the change
    /// (its record fades in at the content pace, so the two overlap).
    static var cardLeaving: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }
}

/// The keyboard side of an approval card (permission, question, Orb proposal, hand-off): while `isActive` it listens for ⌘↩ and
/// Esc and, when the card is the newest open one of the Orb being shown, answers through `answer`.
private struct ApprovalKeys: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let botID: UUID
    let approvalID: UUID?
    let isActive: Bool
    /// A text field of the card has the focus (Esc then belongs to it, and ⌘↩ answers from it).
    let noteFocused: Bool
    /// The button the key is pressing, which the card draws pressed; nil answers at once (a card with no buttons to press).
    let pressed: Binding<ApprovalShortcut?>?
    /// Whether the card can take this answer right now: a key that cannot be used is left to whoever else wants it.
    let accepts: (ApprovalShortcut) -> Bool
    let answer: @MainActor (ApprovalShortcut) -> Void

    func body(content: Content) -> some View {
        content
            .background { if isActive, approvalID != nil { ApprovalKeyMonitor(handler: handleKey) } }
            .task(id: pressed?.wrappedValue) { await answerPressed() }
    }

    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        // Esc in the find field closes the find bar, so the card stays out of it.
        guard let approvalID, model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == approvalID,
              !model.findFieldHasFocus else { return false }
        let field = window.firstResponder as? NSTextView
        guard let shortcut = ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                      hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: noteFocused),
              accepts(shortcut) else { return false }
        press(shortcut)
        return true
    }

    /// A shortcut shows its button pressed for a beat so the person sees what the key did, then answers. (Under Reduce Motion
    /// nothing is pressed and the answer is immediate; a second press during the beat is ignored.)
    private func press(_ shortcut: ApprovalShortcut) {
        guard let pressed else { return answer(shortcut) }
        guard pressed.wrappedValue == nil else { return }
        if ApprovalShortcut.pressDelay(reduceMotion: reduceMotion) == .zero {
            answer(shortcut)
        } else {
            pressed.wrappedValue = shortcut
        }
    }

    /// The beat of a pressed button, then its answer. Runs also if the card goes away during the beat: the key was pressed.
    private func answerPressed() async {
        guard let pressed, let shortcut = pressed.wrappedValue else { return }
        try? await Task.sleep(for: ApprovalShortcut.pressDelay(reduceMotion: reduceMotion))
        answer(shortcut)
        pressed.wrappedValue = nil
    }
}

extension View {
    /// ⌘↩ and Esc answer this card while it is the newest open one of `botID` (the Orb being shown). `approvalID` nil, or
    /// `isActive` false, turns the keys off.
    func approvalKeys(botID: UUID, approvalID: UUID?, isActive: Bool = true, noteFocused: Bool = false,
                      pressed: Binding<ApprovalShortcut?>? = nil,
                      accepts: @escaping (ApprovalShortcut) -> Bool = { _ in true },
                      answer: @escaping @MainActor (ApprovalShortcut) -> Void) -> some View {
        modifier(ApprovalKeys(botID: botID, approvalID: approvalID, isActive: isActive, noteFocused: noteFocused,
                              pressed: pressed, accepts: accepts, answer: answer))
    }
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
