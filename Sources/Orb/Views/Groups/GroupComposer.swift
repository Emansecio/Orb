import SwiftUI

/// The field under a group's thread. ↩ sends, ⌥↩ breaks the line, "@" opens the members (and "todos") with ↑↓ and ↩. No
/// attachments in a group (v1).
struct GroupComposer: View {
    /// The names of the members: what a mention can call.
    let names: [String]
    let onSend: (String) -> Void
    @State private var text = ""
    @State private var selected = 0
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String? { MentionCandidates.openQuery(in: text) }
    private var options: [String] { query.map { MentionCandidates.options(query: $0, names: names) } ?? [] }
    private var isPicking: Bool { query != nil && !options.isEmpty }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPicking {
                MentionPicker(options: options, selected: min(selected, options.count - 1), choose: choose)
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
                        // ⌥↩ is the line break: the field takes it as it is.
                        if press.modifiers.contains(.option) { return .ignored }
                        if isPicking {
                            choose(options[min(selected, options.count - 1)])
                        } else {
                            send()
                        }
                        return .handled
                    }
                    .onKeyPress(.downArrow) { isPicking ? move(1) : .ignored }
                    .onKeyPress(.upArrow) { isPicking ? move(-1) : .ignored }
                    .onChange(of: text) { selected = 0 }
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
