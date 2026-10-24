import SwiftUI

/// The "@" of the group's composer: which members a mention can name, and how the text reads once one is chosen. Pure, so
/// the rules are tested without a window.
enum MentionCandidates {
    /// The option that calls every member; offered only from two members on.
    static let everyone = "todos"

    /// The text after the "@" that is being typed at the end of `text` (without the "@"), or nil when no mention is open:
    /// a space after the word closes it, and so does anything that is not a word of a name.
    static func openQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        return String(query)
    }

    /// The members a mention can name for what was typed: names starting with the word, without accents or capitals, in
    /// the order of the group; "todos" too when there are two or more of them. Nothing typed offers them all.
    static func options(query: String, names: [String]) -> [String] {
        let word = MemoryText.fold(query)
        var found = names.filter { MemoryText.fold($0).hasPrefix(word) }
        if names.count >= 2, everyone.hasPrefix(word) { found.append(everyone) }
        return found
    }

    /// The text with the open mention replaced by the chosen name ("@Pesquisador "), the way a mention is written.
    static func inserting(_ option: String, into text: String) -> String {
        guard let at = text.lastIndex(of: "@"), openQuery(in: text) != nil else { return text + "@\(option) " }
        return String(text[..<at]) + "@\(option) "
    }
}

/// The list of members above the composer while a mention is typed: the names with avatar and role, "Todos os membros" among
/// them when there are two or more. ↑↓ choose, ↩ or ⇥ takes the highlighted one (the composer handles the keys).
struct MentionPicker: View {
    let options: [String]
    /// The members, to find the avatar and role of a name; "todos" has none.
    let looks: [BotLook]
    let selected: Int
    let choose: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { choose(option) } label: {
                    HStack(spacing: 8) {
                        if let look = look(for: option) {
                            BotAvatar(orb: look.orb, size: 20, animated: false)
                        }
                        Text("@\(option)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(detail(for: option))
                            .font(Typography.small)
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selected ? Palette.ghostSelected : Color.clear, in: .rect(cornerRadius: Radius.small))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .card(radius: Radius.card, fill: Palette.surface)
        .shadow(color: Shadow.popover, radius: 12, y: 4)
        .transition(.adapted(.rise, reduceMotion: reduceMotion))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chamar um Orb")
    }

    private func look(for option: String) -> BotLook? {
        option == MentionCandidates.everyone ? nil : looks.first { $0.name == option }
    }

    private func detail(for option: String) -> String {
        option == MentionCandidates.everyone ? "Todos os membros" : (look(for: option)?.role ?? "")
    }
}
