import SwiftUI

/// The conversations of the open Orb, inside its card in the sidebar (the selection wraps both), once it has more than one
/// (`OrbChats`): the newest three, the one on show and any with something unread, "N conversas mais antigas" for the rest,
/// and "Nova conversa". Their text lines up with the Orb's name. The one on show is lit, the one the Orb works on has a
/// ring, one where something landed unseen has a dot. A conversation's menu renames it (in the row itself, as a category) or deletes it.
struct SidebarChatList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    let chats: OrbChats
    /// The highlight of the conversation on show slides to the one opened through this namespace.
    @Namespace private var chatSelectionSpace
    @State private var showsAll = false
    @State private var renaming: UUID?
    @State private var deleting: OrbChats.Entry?

    /// How many of the newest show before "N conversas mais antigas".
    nonisolated static let shownAtRest = 3
    /// A conversation's row, and its rename field, at least: a click target (the text alone made it about 23 pt).
    static let rowHeight: CGFloat = 28
    /// Where the Orb's name starts in its row, and a conversation's text in its own.
    static let nameInset: CGFloat = 46
    static let rowInset: CGFloat = 8

    var body: some View {
        let working = workingChat
        let visible = Self.visible(chats, showsAll: showsAll)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(visible) { entry in
                if renaming == entry.id {
                    ChatTitleField(initial: entry.title) { model.renameChat(entry.id, of: botID, to: $0) } done: { renaming = nil }
                } else {
                    SidebarChatRow(entry: entry, isShown: entry.id == chats.active, isWorking: entry.id == working,
                                   isUnread: entry.unread == true, selectionSpace: chatSelectionSpace) {
                        model.openChat(entry.id, of: botID)
                    }
                    // "Mostrar menos" and "N mais antigas" add and take rows: they unfold, or fade under Reduce Motion.
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
                    .contextMenu {
                        Button("Renomear…", systemImage: "pencil") { renaming = entry.id }
                        Divider()
                        Button("Apagar conversa…", systemImage: "trash", role: .destructive) { deleting = entry }
                            .disabled(!model.canDeleteChat(entry.id, of: botID))
                    }
                }
            }
            if chats.list.count > Self.shownAtRest + 1 {
                SidebarChatAction(title: showsAll ? "Mostrar menos" : Self.olderLabel(chats.list.count - visible.count)) {
                    withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { showsAll.toggle() }
                }
            }
            SidebarChatAction(title: OrbChats.newTitle, symbol: "plus") { model.newChat(for: botID) }
                .help("\(OrbChats.newTitle) (\(AppShortcut.newChat.label))")
        }
        // Bound to the conversation on show: the highlight slides (fades under Reduce Motion) and the titles change weight with it.
        .motion(Motion.content, value: chats.active)
        // The rows' text starts where the Orb's name does (the row's 8 pt, the 30 pt avatar, 8 pt between them).
        .padding(.leading, Self.nameInset - Self.rowInset)
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .confirmationDialog("Apagar “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("Apagar conversa", role: .destructive) { model.deleteChat(entry.id, of: botID) }
        } message: { _ in
            Text("A conversa sai da lista e o arquivo dela é apagado. O que o Orb guardou na memória fica.")
        }
    }

    /// The conversation a turn works on: the one you left (`BotSession.workingChatID`), or the one on show. A routine's run
    /// or another Orb's request has a conversation of its own.
    private var workingChat: UUID? {
        guard let session = model.sessions[botID] else { return nil }
        if let working = session.workingChatID { return working }
        return model.live(botID).isWorking && session.routineID == nil ? chats.active : nil
    }

    /// What the button that unfolds the rest says: it names what is hidden.
    nonisolated static func olderLabel(_ hidden: Int) -> String {
        hidden == 1 ? "1 conversa mais antiga" : "\(hidden) conversas mais antigas"
    }

    /// The newest `shownAtRest`, the one on show and the unread ones, in the list's order; all of them when `showsAll`, or
    /// when only one more would be left out.
    nonisolated static func visible(_ chats: OrbChats, showsAll: Bool) -> [OrbChats.Entry] {
        guard !showsAll, chats.list.count > shownAtRest + 1 else { return chats.list }
        let rows = chats.list.enumerated().filter { index, entry in
            index < shownAtRest || entry.id == chats.active || entry.unread == true
        }.map(\.element)
        return rows.count + 1 >= chats.list.count ? chats.list : rows
    }
}

/// The one mark a row carries at its right edge. A ring is "at work", a filled dot is "unseen": two shapes, so they
/// differ without color or motion (Reduce Motion stills the ring's breath, it stays a ring).
enum SidebarMarker: Equatable {
    case working, unread

    /// A conversation: while the Orb works on it, that is what matters; an unseen reply is shown once it stops.
    static func forChat(isWorking: Bool, isUnread: Bool) -> SidebarMarker? {
        isWorking ? .working : isUnread ? .unread : nil
    }
}

/// One conversation in the list: its title and when you last wrote in it; a ring while the Orb works on it, a dot when
/// something landed in it unseen.
private struct SidebarChatRow: View {
    let entry: OrbChats.Entry
    let isShown: Bool
    let isWorking: Bool
    let isUnread: Bool
    let selectionSpace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(entry.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch SidebarMarker.forChat(isWorking: isWorking, isUnread: isUnread) {
                case .working:
                    WorkingRing()
                        .frame(width: 10)
                case .unread:
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 6, height: 6)
                        .frame(width: 10)
                case nil:
                    Text(ReplyTime.label(entry.updated))
                        .font(Typography.small.monospacedDigit())
                        .foregroundStyle(Palette.faint)
                }
            }
            .font(Typography.label.weight(isShown || isUnread ? .medium : .regular))
            .foregroundStyle(isShown || isUnread ? Palette.ink : Palette.muted)
            .padding(.horizontal, SidebarChatList.rowInset)
            .padding(.vertical, 4)
            .frame(minHeight: SidebarChatList.rowHeight)
            // On the card's own fill: a second, lighter one marks the conversation on show.
            .background {
                if isShown { SlidingSelectionFill(space: selectionSpace, radius: Radius.small) }
            }
            .hoverFill(isHovering && !isShown, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.title)
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityValue(isWorking ? "o Orb está trabalhando nela" : isUnread ? "não lida" : "")
    }
}

/// "N conversas mais antigas" and "Nova conversa" at the foot of the list, quieter than the conversations.
private struct SidebarChatAction: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(SectionPlus.glyph) }
                Text(title)
            }
            .font(Typography.small)
            .foregroundStyle(isHovering ? Palette.muted : Palette.faint)
            .padding(.horizontal, SidebarChatList.rowInset)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.fade, value: isHovering)
    }
}

/// The row of a conversation being renamed: `InlineNameField` in the row's own height and inset. A blank title is saved
/// as typed and `OrbChats.rename` keeps the old one.
private struct ChatTitleField: View {
    let initial: String
    let save: (String) -> Void
    let done: () -> Void

    var body: some View {
        InlineNameField(initial: initial, label: "Nome da conversa", font: Typography.label, save: save, finish: done)
            .padding(.horizontal, SidebarChatList.rowInset)
            .padding(.vertical, 4)
            // Same height as SidebarChatRow, so the list does not jump when a title is renamed.
            .frame(minHeight: SidebarChatList.rowHeight)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.lineStrong))
    }
}
