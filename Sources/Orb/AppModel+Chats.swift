import Foundation

// The Orb's conversations (`OrbChats`): a new one, another one opened, one renamed or deleted, and where what arrives lands
// (an answer in the conversation that asked, anything else in the latest). Each has its own history; the memory, the folder
// and the tools are the Orb's. How the session changes conversation, also while it works, is `BotSession.openChat`.

extension AppModel {
    /// "Nova conversa" (⇧⌘N): the Orb's chat shows a new, empty conversation; the one it showed stays in the list. When the
    /// one on show is already empty, it stays.
    func newChat(for botID: UUID) {
        guard bot(botID) != nil, !isResetting else { return }
        if inicioJump?.bot == botID { inicioJump = nil; sessions[botID]?.opening = nil }
        let session = session(botID)
        if !session.isUnloaded, !session.isLoading, session.shownItems.isEmpty {
            selection = .bot(botID)
            return
        }
        var chats = live(botID).chats ?? OrbChats(first: botID, updated: live(botID).lastReply?.date ?? .now)
        let id = UUID()
        chats.add(id, at: .now)
        show(id, of: botID, in: chats, fresh: true)
    }

    /// Shows another of the Orb's conversations in its chat.
    func openChat(_ chat: UUID, of botID: UUID) {
        openChat(chat, of: botID, preservingInicioJump: false)
    }

    func openChat(_ chat: UUID, of botID: UUID, preservingInicioJump: Bool) {
        guard bot(botID) != nil, !isResetting, let chats = live(botID).chats, chats.title(of: chat) != nil else { return }
        if !preservingInicioJump, inicioJump?.bot == botID { inicioJump = nil; sessions[botID]?.opening = nil }
        show(chat, of: botID, in: chats, fresh: false)
    }

    /// Folds the Orb's conversations under its row in the sidebar, or unfolds them; kept with the list.
    func setChatsCollapsed(_ collapsed: Bool, for botID: UUID) {
        guard var chats = live(botID).chats else { return }
        chats.collapsed = collapsed ? true : nil
        setChats(chats, for: botID)
    }

    func renameChat(_ chat: UUID, of botID: UUID, to title: String) {
        guard var chats = live(botID).chats else { return }
        chats.rename(chat, to: title)
        setChats(chats, for: botID)
    }

    /// Whether the conversation can be deleted: there is another one, and no turn works on it.
    func canDeleteChat(_ chat: UUID, of botID: UUID) -> Bool {
        guard let chats = live(botID).chats, chats.list.count > 1, chats.title(of: chat) != nil else { return false }
        guard let session = sessions[botID] else { return true }
        return chat != session.workingChatID && !(chat == session.chatID && session.turnTask != nil && session.parkedChat == nil)
    }

    /// Deletes one of the Orb's conversations with its file (what it gave the memory stays there). The one on show gives
    /// way to the newest one left first.
    func deleteChat(_ chat: UUID, of botID: UUID) {
        guard canDeleteChat(chat, of: botID), var chats = live(botID).chats else { return }
        chats.remove(chat)
        let session = session(botID)
        if chat == session.chatID {
            // Read now, not off the main thread: the one deleted is written as it leaves, before its file goes.
            let next = chats.active
            show(next, of: botID, in: chats, fresh: false, read: readsFirst(next, in: session) ? store.readConversation(botID, chat: next) : nil)
        } else {
            setChats(chats, for: botID)
        }
        store.deleteConversation(botID, chat: chat) // after the write of it leaving, on the same queue
    }

    /// The title of the conversation a turn still works on after you opened another one; nil when there is none.
    func workingChatTitle(_ botID: UUID) -> String? {
        guard let working = sessions[botID]?.workingChatID else { return nil }
        return live(botID).chats?.title(of: working) ?? OrbChats.newTitle
    }

    /// You wrote in the Orb's chat: its conversation goes to the top of the list, and a new one takes its title from it.
    func chatGotMessage(_ text: String, of botID: UUID) {
        guard var chats = live(botID).chats, let session = sessions[botID], session.routineID == nil else { return }
        chats.wrote(text, in: session.chatID, at: .now)
        setChats(chats, for: botID)
    }

    // MARK: Where things land

    /// The conversation of the Orb that gets what does not belong to one of them: a notice from another Orb, a routine's
    /// run, a process that ended, a group's news. The one you wrote in last (the list is newest first); the first one
    /// while the Orb has only that.
    func latestChat(of botID: UUID) -> UUID { live(botID).chats?.list.first?.id ?? botID }

    /// Whether `chat` is still one of the Orb's conversations (one may be deleted while a request it made is open).
    func isChat(_ chat: UUID, of botID: UUID) -> Bool {
        live(botID).chats.map { $0.title(of: chat) != nil } ?? (chat == botID)
    }

    /// `chat` while it is one of the Orb's conversations; otherwise the latest.
    func chatOrLatest(_ chat: UUID?, of botID: UUID) -> UUID {
        guard let chat, isChat(chat, of: botID) else { return latestChat(of: botID) }
        return chat
    }

    /// A line in one of the Orb's conversations (`chat`, or the latest) wherever it is (`BotSession.changeChat`): one that
    /// is not on show gets its dot.
    func appendToChat(_ kind: TranscriptItem.Kind, of botID: UUID, in chat: UUID? = nil) {
        guard bot(botID) != nil else { return }
        let session = session(botID), target = chatOrLatest(chat, of: botID), item = TranscriptItem(kind)
        if target == session.conversationChat { session.ensureLoaded() } // read with the rest, as a line of the chat always was
        session.changeChat(target) { $0.items.append(item) }
        markUnread(target, of: botID)
    }

    /// Something landed in one of the Orb's conversations: when it is not the one on show, its row gets a dot until you
    /// open it.
    func markUnread(_ chat: UUID, of botID: UUID) {
        guard var chats = live(botID).chats else { return }
        chats.markUnread(chat)
        setChats(chats, for: botID)
    }

    /// Reads one of the Orb's conversations off the main thread, again when one of them changed in its file meanwhile
    /// (`BotSession.amends`): what is read is never older than what was written to it.
    func readChat(_ chat: UUID, of botID: UUID) async -> StoreRead<Conversation> {
        let session = session(botID), store = store
        while true {
            let mark = session.amends
            let read = await store.readConversationAsync(botID, chat: chat)
            if session.amends == mark { return read }
        }
    }

    /// Gets the Orb ready for a turn that belongs to its conversation `chat` (the answer to what it asked there, a process
    /// it waited for): the turn machinery has it already, or it works on it behind the one on show
    /// (`BotSession.workElsewhere`), read first off the main thread, as is the one on show when it was let go of. False
    /// when the Orb took other work meanwhile, or `chat` is gone.
    func prepareTurn(in chat: UUID, of botID: UUID) async -> Bool {
        let session = session(botID)
        guard chat != session.conversationChat else { return true }
        await loadedConversation(botID)
        let read = await readChat(chat, of: botID)
        guard bot(botID) != nil, !isResetting, chatOrLatest(chat, of: botID) == chat, session.turnTask == nil,
              session.routineID == nil, session.parkedChat == nil else { return false }
        guard chat != session.chatID else { return true } // you opened it meanwhile
        session.ensureLoaded() // let go of again meanwhile (rare)
        session.workElsewhere(chat, read: read)
        return session.workingChatID == chat
    }

    // MARK: Showing

    private func show(_ chat: UUID, of botID: UUID, in chats: OrbChats, fresh: Bool, read: StoreRead<Conversation>? = nil) {
        let session = session(botID)
        selection = .bot(botID)
        session.opening = nil
        if chat != session.chatID {
            if read == nil, !fresh, readsFirst(chat, in: session) {
                // The chat cannot show a placeholder in front of a turn or a side run: the other conversation is read off the
                // main thread first (a long one takes tens of milliseconds there), then shown. Opening another one meanwhile wins.
                session.opening = chat
                Task { [weak self] in
                    guard let read = await self?.readChat(chat, of: botID), let self, session.opening == chat else { return }
                    if isResetting {
                        session.opening = nil
                        if inicioJump?.bot == botID, inicioJump?.chat == chat { inicioJump = nil }
                        return
                    }
                    guard bot(botID) != nil, let chats = live(botID).chats, chats.title(of: chat) != nil else {
                        session.opening = nil
                        if inicioJump?.bot == botID, inicioJump?.chat == chat {
                            inicioJump = nil
                            inicioNavigationNotice = "A conversa de origem não está mais disponível."
                        }
                        return
                    }
                    show(chat, of: botID, in: chats, fresh: false, read: read)
                }
                return
            }
            cancelEditing(botID) // the message being edited is the other conversation's
            giveBackQueued(botID)
            session.openChat(chat, fresh: fresh, read: read)
        }
        var chats = chats
        chats.active = chat
        setChats(chats, for: botID)
    }

    /// Whether the conversation is read before it shows: a turn or a side run holds the Orb (the conversation the turn works
    /// on is in memory already).
    private func readsFirst(_ chat: UUID, in session: BotSession) -> Bool {
        chat != session.workingChatID && (session.turnTask != nil || session.parkedChat != nil)
    }
}
