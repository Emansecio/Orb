import SwiftUI
import AppKit

// The find bar of a chat (⌘F) and the list of its results. They draw `ConversationFind`; the chat scrolls to what it
// chooses (`TranscriptList`). Nothing here reads the conversation: it shows counts, snippets and buttons.

/// A compact bar at the top of the chat, like the one of Safari or Xcode: the field, "3 de 12", the arrows, the list of
/// results and "Fechar". ↩ / ↓ / ⌘G go to the next result, ⇧↩ / ↑ / ⇧⌘G to the previous one, Esc closes.
struct FindBar: View {
    /// How far the chat's content is pushed down while the bar is open: the bar sits 10 pt from the top and is about 34 pt
    /// tall, the list already has 20 pt of its own above the first message, and a gap of 8 pt is left under the bar.
    static let clearance: CGFloat = 32

    @Environment(AppModel.self) private var model
    let find: ConversationFind
    let botID: UUID
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var find = find
        let hasResults = (find.results?.hits.isEmpty == false)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            TextField("Buscar na conversa", text: $find.query, prompt: Text("Buscar na conversa"))
                .textFieldStyle(.plain)
                .font(Typography.text)
                .focused($isFieldFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { find.previous() } else { find.next() }
                    return .handled
                }
                .onKeyPress(.downArrow) { find.next(); return .handled }
                .onKeyPress(.upArrow) { find.previous(); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityLabel("Buscar na conversa")
            status
            HStack(spacing: 2) {
                step("chevron.up", help: Tip.findPrevious(), label: "Resultado anterior", enabled: hasResults) { find.previous() }
                step("chevron.down", help: Tip.findNext(), label: "Próximo resultado", enabled: hasResults) { find.next() }
                step("list.bullet", help: Tip.findResults, label: "Lista de resultados", enabled: hasResults) { find.showsResults.toggle() }
                    .popover(isPresented: $find.showsResults, arrowEdge: .bottom) {
                        FindResultsList(find: find, botName: model.live(botID).look.name)
                    }
                step("xmark", help: Tip.findClose, label: "Fechar a busca", enabled: true) { close() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: 480)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.lineStrong))
        .shadow(color: Shadow.popover, radius: 10, y: 3)
        .background {
            // ⌘G and ⇧⌘G, while the bar is open (the app has no Edit menu to carry them).
            Group {
                Button("Próximo resultado") { find.next() }.keyboardShortcut(AppShortcut.findNext)
                Button("Resultado anterior") { find.previous() }.keyboardShortcut(AppShortcut.findPrevious)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: find.focusRequests, initial: true) {
            isFieldFocused = true
            // The last query comes back selected, so typing replaces it.
            Task {
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onChange(of: isFieldFocused, initial: true) { model.findFieldHasFocus = isFieldFocused }
        .onDisappear { model.findFieldHasFocus = false }
    }

    private func close() {
        find.close()
        model.findFieldHasFocus = false
        model.focusComposer() // typing goes on where it was
    }

    /// "3 de 12" / "Sem resultados" / "Buscando…" (or "Carregando…" while the conversation is still being read).
    private var status: some View {
        let loading = model.isLoadingConversation(botID)
        return Text(loading ? "Carregando…" : find.statusText)
            .font(Typography.label.monospacedDigit())
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(loading ? "Carregando a conversa" : find.spokenStatus)
    }

    private func step(_ symbol: String, help: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typography.small.weight(.medium))
                .foregroundStyle(enabled ? Palette.secondary : Palette.hint)
        }
        .buttonStyle(CircleGhostStyle(side: 24, fontSize: 11)) // hover, press and the 24 pt hit area of the other round buttons
        .disabled(!enabled)
        .iconTip(help, label: label)
    }
}

/// The results as a list of snippets ("…trecho com a palavra destacada…"), oldest first; a click goes to that message.
/// Rows are made as it scrolls, so a thousand results cost no more than a screenful.
private struct FindResultsList: View {
    @Environment(\.dismiss) private var dismiss
    let find: ConversationFind
    let botName: String

    var body: some View {
        let hits = find.results?.hits ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { hit in
                        FindResultRow(hit: hit, who: Self.who(of: hit.source, botName: botName), isCurrent: hit.id == find.cursor.index) {
                            find.choose(hit.id)
                            dismiss()
                        }
                        .id(hit.id)
                    }
                    if find.results?.isTruncated == true {
                        Text("Só os primeiros \(hits.count) resultados aparecem. Escreva mais para afinar a busca.")
                            .font(Typography.small)
                            .foregroundStyle(Palette.muted)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .onAppear {
                if let index = find.cursor.index { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .frame(width: 380, height: min(CGFloat(max(hits.count, 1)) * 52 + 24, 360))
        .accessibilityLabel("Resultados da busca")
    }

    static func who(of source: ConversationSearch.Source, botName: String) -> String {
        switch source {
        case .user: "Você"
        case .bot, .greeting: botName
        case .notice: "Aviso"
        case .tool: "Ferramenta"
        case .exchange: "Entre Orbs"
        }
    }
}

private struct FindResultRow: View {
    let hit: ConversationSearch.Hit
    let who: String
    let isCurrent: Bool
    let choose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 2) {
                Text(who)
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(Palette.muted)
                Text(snippet)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: Radius.small).fill(Palette.ghostSelected).opacity(isCurrent ? 1 : 0) }
            .hoverFill(isHovering && !isCurrent, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(who): \(hit.snippet.text)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var snippet: AttributedString {
        var match = AttributedString(hit.snippet.match)
        match.backgroundColor = Palette.findMatch
        match.foregroundColor = Palette.ink
        return AttributedString(hit.snippet.before) + match + AttributedString(hit.snippet.after)
    }
}
