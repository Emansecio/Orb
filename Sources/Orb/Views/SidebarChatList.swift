import SwiftUI

/// The conversations of the open Orb, under its row in the sidebar, once it has more than one (`OrbChats`): the newest
/// three, the one on show and any with something unread, "N mais…" for the rest, and "Nova conversa". The one on show is
/// lit, the one the Orb works on breathes, one where something landed unseen has a dot. A conversation's menu renames it
/// (in the row itself, as a category) or deletes it.
struct SidebarChatList: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let chats: OrbChats
    @State private var showsAll = false
    @State private var renaming: UUID?
    @State private var deleting: OrbChats.Entry?

    /// How many of the newest show before "N mais…".
    static let shownAtRest = 3

    var body: some View {
        let working = workingChat
        let visible = Self.visible(chats, showsAll: showsAll)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(visible) { entry in
                if renaming == entry.id {
                    ChatTitleField(initial: entry.title) { model.renameChat(entry.id, of: botID, to: $0) } done: { renaming = nil }
                } else {
                    SidebarChatRow(entry: entry, isShown: entry.id == chats.active, isWorking: entry.id == working,
                                   isUnread: entry.unread == true) {
                        model.openChat(entry.id, of: botID)
                    }
                    .contextMenu {
                        Button("Renomear…", systemImage: "pencil") { renaming = entry.id }
                        Divider()
                        Button("Apagar conversa…", systemImage: "trash", role: .destructive) { deleting = entry }
                            .disabled(!model.canDeleteChat(entry.id, of: botID))
                    }
                }
            }
            if chats.list.count > Self.shownAtRest + 1 {
                SidebarChatAction(title: showsAll ? "Mostrar menos" : "\(chats.list.count - visible.count) mais…", tint: Palette.faint) {
                    showsAll.toggle()
                }
            }
            SidebarChatAction(title: OrbChats.newTitle, symbol: "plus", tint: Palette.accentText) { model.newChat(for: botID) }
                .help("\(OrbChats.newTitle) (\(AppShortcut.newChat.label))")
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        .padding(.leading, 46)
        .padding(.top, 2)
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

/// One conversation in the list: its title and when you last wrote in it; a breathing dot while the Orb works on it, a
/// still one when something landed in it unseen.
private struct SidebarChatRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: OrbChats.Entry
    let isShown: Bool
    let isWorking: Bool
    let isUnread: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(entry.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isWorking {
                    BreathingDot(color: Palette.accentText, breathes: !reduceMotion)
                        .frame(width: 5, height: 5)
                        .frame(width: 10)
                } else if isUnread {
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 6, height: 6)
                        .frame(width: 10)
                } else {
                    Text(ReplyTime.label(entry.updated))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Palette.hint)
                }
            }
            .font(.system(size: 12, weight: isUnread ? .semibold : .regular))
            .foregroundStyle(isShown || isUnread ? Palette.ink : Palette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isShown ? Palette.ghostSelected : .clear, in: .rect(cornerRadius: 7))
            .hoverFill(isHovering && !isShown, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.fade, value: isHovering)
        .help(entry.title)
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityValue(isWorking ? "o Orb está trabalhando nela" : isUnread ? "não lida" : "")
    }
}

/// "N mais…" and "Nova conversa" at the foot of the list.
private struct SidebarChatAction: View {
    let title: String
    var symbol: String?
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.fade, value: isHovering)
    }
}

/// The title typed in the row itself, as a category's name: ↩ keeps it, esc gives up, clicking elsewhere keeps what was
/// typed. A blank one keeps the old title (`OrbChats.rename`).
private struct ChatTitleField: View {
    let initial: String
    let save: (String) -> Void
    let done: () -> Void
    @State private var text: String
    @State private var isDone = false
    @FocusState private var isFocused: Bool

    init(initial: String, save: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.initial = initial
        self.save = save
        self.done = done
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("Nome da conversa", text: $text, prompt: Text("Nome da conversa"))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
            .focused($isFocused)
            .onSubmit { finish(keeping: true) }
            .onExitCommand { finish(keeping: false) }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.lineStrong))
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { if !isFocused { finish(keeping: true) } }
            .accessibilityLabel("Nome da conversa")
    }

    private func finish(keeping: Bool) {
        guard !isDone else { return }
        isDone = true
        if keeping, text != initial { save(text) }
        done()
    }
}
