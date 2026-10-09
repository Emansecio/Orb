import SwiftUI
import AppKit

/// Puts text on the general pasteboard.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// The "Copiado" state of a copy button: on for 1.5 s after `trigger()`. A second click starts the 1.5 s over instead
/// of being cut short by the first one's timer.
@MainActor @Observable
final class CopiedFlash {
    private(set) var isOn = false
    private var reset: Task<Void, Never>?

    func trigger(animation: Animation? = nil) {
        set(true, animation: animation)
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            set(false, animation: animation)
        }
    }

    private func set(_ value: Bool, animation: Animation?) {
        if let animation { withAnimation(animation) { isOn = value } } else { isOn = value }
    }
}
