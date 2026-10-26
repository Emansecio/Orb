import SwiftUI

// Small controls that more than one screen draws. A copy per screen had already drifted apart (size, colour).

/// The round "send" arrow of the quick ask, the creation chat and the group's composer. Same family as the main
/// composer's send button (`RoundActionStyle`): white (`ink`) when it can send, and the same 25% of it when it cannot.
/// 24 pt: the main composer's disc is 28 pt, and these fields are lighter, so a little under it, not 22 or 24 by screen.
struct SendArrowButton: View {
    let canSend: Bool
    /// The hover text, which is also the VoiceOver label's detail: "Enviar (↩)".
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(canSend ? Palette.ink : Palette.ink.opacity(0.25))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .iconTip(help, label: "Enviar")
    }
}

/// What typing a name inside a row decides, as plain values so the branches can be tested.
enum InlineNameEdit {
    /// What to save when the edit ends, or nil to save nothing. `keeping: false` is Esc. `normalize` turns the typed text
    /// into the name to keep (nil: it is not a name, e.g. blank); an unchanged name is not saved again.
    static func committed(typed: String, initial: String, keeping: Bool, normalize: (String) -> String?) -> String? {
        guard keeping, let name = normalize(typed), name != initial else { return nil }
        return name
    }

    /// The typed text cut to `limit` characters (no limit: as typed).
    static func limited(_ typed: String, to limit: Int?) -> String {
        guard let limit, typed.count > limit else { return typed }
        return String(typed.prefix(limit))
    }
}

/// A name typed in the row itself (a conversation's title, a category's name): ↩ keeps it, esc gives up, and clicking
/// elsewhere keeps what was typed. It is the field only; the caller draws the row around it. `finish` runs once, after
/// `save` (when there is a name to save), so the caller can take the row out of editing.
struct InlineNameField: View {
    let initial: String
    /// The field's prompt and its VoiceOver label.
    let label: LocalizedStringKey
    let font: Font
    var limit: Int?
    /// The typed text to the name to keep; nil when it is not one (blank). The default keeps it as typed.
    var normalize: (String) -> String? = { $0 }
    let save: (String) -> Void
    let finish: () -> Void
    @State private var text: String
    @State private var isDone = false
    @FocusState private var isFocused: Bool

    init(initial: String, label: LocalizedStringKey, font: Font, limit: Int? = nil,
         normalize: @escaping (String) -> String? = { $0 },
         save: @escaping (String) -> Void, finish: @escaping () -> Void) {
        self.initial = initial
        self.label = label
        self.font = font
        self.limit = limit
        self.normalize = normalize
        self.save = save
        self.finish = finish
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(label))
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Palette.ink)
            .focused($isFocused)
            .onSubmit { end(keeping: true) }
            .onExitCommand { end(keeping: false) }
            .onChange(of: text) {
                let limited = InlineNameEdit.limited(text, to: limit)
                if limited != text { text = limited }
            }
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { if !isFocused { end(keeping: true) } }
            .accessibilityLabel(label)
    }

    private func end(keeping: Bool) {
        // ↩ and the focus that leaves with it both land here: the first one decides.
        guard !isDone else { return }
        isDone = true
        if let name = InlineNameEdit.committed(typed: text, initial: initial, keeping: keeping, normalize: normalize) { save(name) }
        finish()
    }
}
