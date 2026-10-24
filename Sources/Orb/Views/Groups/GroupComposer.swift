import SwiftUI

/// The field under a group's thread. ↩ sends, ⇧↩ or ⌥↩ breaks the line, "@" opens the members (and "todos") with ↑↓, ↩ or ⇥, and
/// Esc closes the list. No attachments in a group (v1).
struct GroupComposer: View {
    /// The names of the members: what a mention can call.
    let names: [String]
    /// The members as the picker draws them (avatar and role); `names` is what the mention rules work on.
    let looks: [BotLook]
    /// The draft: kept by the app per group, so it is still there after a visit to another conversation.
    @Binding var text: String
    let onSend: (String) -> Void
    @State private var selected = 0
    /// Esc closed the list; a change of the text opens it again.
    @State private var isPickerDismissed = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String? { MentionCandidates.openQuery(in: text) }
    private var options: [String] { query.map { MentionCandidates.options(query: $0, names: names) } ?? [] }
    private var isPicking: Bool { !isPickerDismissed && query != nil && !options.isEmpty }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPicking {
                MentionPicker(options: options, looks: looks, selected: min(selected, options.count - 1), choose: choose)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Escreva para o grupo. Use @ para chamar um Orb", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Palette.conversationFont)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // ⌥↩ is the line break: the field takes it as it is. ⇧↩ makes the same one.
                        if press.modifiers.contains(.option) { return .ignored }
                        if press.modifiers.contains(.shift), let window = NSApp.keyWindow {
                            return NewLineKey.insert(in: window) ? .handled : .ignored
                        }
                        if isPicking {
                            choose(options[min(selected, options.count - 1)])
                        } else {
                            send()
                        }
                        return .handled
                    }
                    .onKeyPress(.downArrow) { isPicking ? move(1) : .ignored }
                    .onKeyPress(.upArrow) { isPicking ? move(-1) : .ignored }
                    .onKeyPress(keys: [.tab]) { _ in
                        guard isPicking else { return .ignored }
                        choose(options[min(selected, options.count - 1)])
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard isPicking else { return .ignored }
                        isPickerDismissed = true
                        return .handled
                    }
                    .onChange(of: text) {
                        selected = 0
                        isPickerDismissed = false
                    }
                    .accessibilityLabel("Mensagem para o grupo")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? Palette.ink : Palette.faint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Enviar para o grupo (↩)")
                .accessibilityLabel("Enviar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isFocused ? Palette.surfaceFocused : Palette.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isFocused ? Palette.lineStrong : Palette.line, lineWidth: 1))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: isPicking)
        // The caller gives each group its own composer (`.id`), so this runs when the group opens or changes.
        .onAppear { isFocused = true }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        text = ""
        onSend(message)
    }

    private func choose(_ option: String) {
        text = MentionCandidates.inserting(option, into: text)
        selected = 0
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = options.count
        guard count > 0 else { return .ignored }
        selected = (selected + step + count) % count
        return .handled
    }
}
