import SwiftUI

/// Toolbar button of the chat: the Orb's earlier conversations, to reopen or delete.
struct ConversationsMenuButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var isOpen = false

    var body: some View {
        Button("Conversas anteriores", systemImage: "clock.arrow.circlepath") { isOpen.toggle() }
            .keyboardShortcut(AppShortcut.conversations)
            .help("Conversas anteriores deste Orb (\(AppShortcut.conversations.label))")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                ConversationsMenu(botID: botID) { isOpen = false }
            }
            // ⌘Y and "Conversas anteriores…" in the sidebar's menu: when this chat was just created for the Orb, the
            // request is already waiting (`onAppear`); when it was open, it arrives later (`onChange`).
            .onAppear(perform: takeRequest)
            .onChange(of: model.pendingChatRequest) { takeRequest() }
    }
}

extension ConversationsMenuButton {
    private func takeRequest() {
        // A toggle: with the popover open it is the key window, so ⌘Y reaches the menu command, not the button, and the
        // key that opened the list also has to close it.
        if model.takeChatRequest(.showConversations, of: botID) { isOpen.toggle() }
    }
}

/// Archived conversations of one Orb, newest first, by day. The whole row reopens it; the arrow keys move, Return
/// reopens and Delete asks to delete. "Nova conversa" puts the current one here.
struct ConversationsMenu: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let onClose: () -> Void

    @State private var query = ""
    @State private var isLoading = true
    /// The conversation whose "Apagar" was clicked and is waiting for the confirmation.
    @State private var confirmingDelete: UUID?
    /// The row the keyboard is on (Return reopens it).
    @State private var selection: UUID?
    /// The list as shown, grouped by day: rebuilt when the archive or the search changes, not on every draw.
    @State private var groups: [ConversationGroup] = []
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    private var all: [ConversationSummary] { model.archives[botID] ?? [] }
    private var hasSearch: Bool { all.count >= ConversationListing.searchFrom }
    private var shownIDs: [UUID] { groups.flatMap { $0.entries.map(\.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversas anteriores")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if hasSearch {
                TextField("Buscar", text: $query, prompt: Text("Buscar nas conversas"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
            }
            if groups.isEmpty {
                Text(isLoading ? "Carregando…" : all.isEmpty
                     ? "Nada por aqui ainda. Ao começar uma nova conversa, a atual fica guardada aqui."
                     : "Nenhuma conversa com “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                            ForEach(groups) { group in
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, 8)
                                    .padding(.top, group.id == groups.first?.id ? 0 : 8)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.entries) { entry in
                                    ConversationRow(entry: entry, isSelected: selection == entry.id,
                                                    isConfirming: confirmingDelete == entry.id,
                                                    onReopen: { reopen(entry.id) },
                                                    onAskDelete: { confirmingDelete = entry.id },
                                                    onCancelDelete: { confirmingDelete = nil },
                                                    onDelete: { delete(entry.id) })
                                        .id(entry.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                Text("A conversa atual fica guardada aqui quando você reabre outra.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(14)
        .frame(width: 380)
        .focusable(!hasSearch)
        .focused($isListFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { submit(); return confirmingDelete == nil && selection == nil ? .ignored : .handled }
        .onKeyPress(.escape) {
            // While "Apagar de vez?" is open, Esc takes back the question instead of closing the popover.
            guard confirmingDelete != nil else { return .ignored }
            confirmingDelete = nil
            return .handled
        }
        .onKeyPress(.delete) {
            // With a search field, Delete edits its text: the trash button asks instead.
            guard !hasSearch || query.isEmpty, let selection else { return .ignored }
            confirmingDelete = selection
            return .handled
        }
        .task {
            await model.loadArchive(botID)
            isLoading = false
            rebuild()
            if hasSearch { isSearchFocused = true } else { isListFocused = true }
        }
        .onChange(of: model.archives[botID]) { rebuild() }
        .onChange(of: query) {
            rebuild()
            selection = shownIDs.first
        }
    }

    private func rebuild() {
        groups = ConversationListing.groups(ConversationListing.filter(all, query: query))
        if selection == nil || !shownIDs.contains(selection!) { selection = shownIDs.first }
        if let confirmingDelete, !shownIDs.contains(confirmingDelete) { self.confirmingDelete = nil }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !groups.isEmpty else { return .ignored }
        selection = ConversationListing.moved(selection, by: step, in: shownIDs)
        return .handled
    }

    /// Return: confirms the deletion being asked about, or else reopens the selected conversation.
    private func submit() {
        if let confirmingDelete { delete(confirmingDelete) } else if let selection { reopen(selection) }
    }

    private func reopen(_ id: UUID) {
        Task { if await model.reopenConversation(id, of: botID) { onClose() } }
    }

    private func delete(_ id: UUID) {
        model.deleteArchivedConversation(id, of: botID)
        confirmingDelete = nil
    }
}

private struct ConversationRow: View {
    let entry: ConversationSummary
    let isSelected: Bool
    let isConfirming: Bool
    let onReopen: () -> Void
    let onAskDelete: () -> Void
    let onCancelDelete: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onReopen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(ConversationListing.subtitle(entry))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.title), \(ConversationListing.subtitle(entry))")
                .accessibilityHint("Reabre esta conversa")
                // The trash is invisible (and out of VoiceOver's reach) except on the hovered or selected row.
                .accessibilityAction(named: "Apagar", onAskDelete)
                if !isConfirming {
                    Button("Apagar", systemImage: "trash", action: onAskDelete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.muted)
                        .help("Apagar esta conversa")
                        .opacity(isHovering || isSelected ? 1 : 0)
                }
            }
            if isConfirming {
                HStack {
                    Text("Apagar de vez? Não dá para desfazer.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                    Spacer()
                    Button("Cancelar", action: onCancelDelete)
                    Button("Apagar", role: .destructive, action: onDelete)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected || isConfirming ? Palette.ghostSelected : (isHovering ? Palette.ghostHover : .clear),
                    in: .rect(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }
}
