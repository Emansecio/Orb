import Foundation

/// The conversations of an Orb that has more than one (an Orb with only its first has none): which one the chat shows,
/// and each one's title, when you last wrote in it and whether something landed in it unseen, newest first. Saved with the app's state; each conversation is a
/// file of its own (`Store.conversationURL`), and the first one's id is the Orb's. They share the Orb's memory, folder and
/// tools, never their history.
struct OrbChats: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var title: String
        /// When you last wrote in it (when it was made, before that).
        var updated: Date
        /// Something landed in it while another one was on show (an answer, a notice, the end of a turn): true until you
        /// open it. nil, not false, so the file only names the ones that have it.
        var unread: Bool?
    }

    /// The one the chat shows (`BotSession.chatID`): opening one reads it.
    var active: UUID {
        didSet { if let index = list.firstIndex(where: { $0.id == active }) { list[index].unread = nil } }
    }
    /// Newest first.
    private(set) var list: [Entry]

    static let firstTitle = "Primeira conversa"
    static let newTitle = "Nova conversa"
    /// The longest title a first message gives.
    static let titleLength = 48

    /// The Orb's first conversation alone, as the list starts when a second one is made.
    init(first botID: UUID, updated: Date) {
        active = botID
        list = [Entry(id: botID, title: Self.firstTitle, updated: updated)]
    }

    /// A new, empty conversation, on top and on show.
    mutating func add(_ id: UUID, at date: Date) {
        list.insert(Entry(id: id, title: Self.newTitle, updated: date), at: 0)
        active = id
    }

    /// You wrote `text` in the conversation: it goes to the top, and a new one takes its title from its first message.
    mutating func wrote(_ text: String, in id: UUID, at date: Date) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        var entry = list.remove(at: index)
        entry.updated = date
        if entry.title == Self.newTitle {
            let title = RoutineRun.preview(of: text, limit: Self.titleLength)
            if !title.isEmpty { entry.title = title }
        }
        list.insert(entry, at: 0)
    }

    /// An empty name keeps the one it had.
    mutating func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].title = String(trimmed.prefix(80))
    }

    /// Takes a conversation out of the list, never the last one; when it was on show, the newest one left is.
    mutating func remove(_ id: UUID) {
        guard list.count > 1 else { return }
        list.removeAll { $0.id == id }
        if active == id { active = list[0].id }
    }

    /// Something landed in a conversation that is not on show.
    mutating func markUnread(_ id: UUID) {
        guard id != active, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].unread = true
    }

    func title(of id: UUID) -> String? { list.first { $0.id == id }?.title }

    /// Nothing to choose between any more: only the Orb's first conversation is left (the app then keeps no list).
    func isOnlyFirst(of botID: UUID) -> Bool { list.count == 1 && list[0].id == botID }
}
