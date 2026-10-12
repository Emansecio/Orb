import Foundation
import Observation

/// A group's thread in memory: the conversation of the group (`.user`, `.orbMessage(post)`, `.event`, `.groupPause`) and what
/// the chat view shows of it. A lean cousin of `BotSession`: it has no turn (the members' turns run in their own sessions), only
/// the thread, its unread count and saving it. It is saved a moment after the last change (through `persist`, which the app
/// points at the store's queue) and let go of by `AppModel.unloadIdleGroupSessions` when nobody looks at it.
@MainActor
@Observable
final class GroupSession {
    let groupID: UUID
    private(set) var conversation = Conversation()
    let transcript: OrbTranscript
    private(set) var unread = 0

    /// Writes the thread (the app: `Store.saveGroupConversation`). Nil in a session nobody saves (snapshots, tests that do not look).
    @ObservationIgnored var persist: (@MainActor (Conversation) -> Void)?
    /// The thread changed since it was last handed to `persist`; quitting saves only the sessions with this set.
    @ObservationIgnored private(set) var isDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var lastUsed = ContinuousClock.now
    /// How long after a change the thread is saved.
    @ObservationIgnored var saveDelay: Duration = .milliseconds(400)

    init(groupID: UUID, conversation: Conversation = Conversation()) {
        self.groupID = groupID
        self.conversation = conversation
        transcript = OrbTranscript(items: conversation.items)
    }

    var items: [TranscriptItem] { conversation.items }

    // MARK: Changing the thread

    /// Adds an item at the end and returns it.
    @discardableResult
    func append(_ kind: TranscriptItem.Kind, id: UUID? = nil, date: Date = .now) -> TranscriptItem {
        var item = TranscriptItem(kind)
        if let id { item.id = id }
        item.date = date
        change { $0.items.append(item) }
        return item
    }

    /// Changes the kind of the item `id`; false when there is none.
    @discardableResult
    func update(_ id: UUID, _ change: (inout TranscriptItem.Kind) -> Void) -> Bool {
        guard let index = conversation.items.firstIndex(where: { $0.id == id }) else { return false }
        var kind = conversation.items[index].kind
        change(&kind)
        guard kind != conversation.items[index].kind else { return true }
        self.change { $0.items[index].kind = kind }
        return true
    }

    /// Changes every item `matching` (an assignment line gets its state when the member answers, a pause card its choice).
    func updateAll(where matching: (TranscriptItem.Kind) -> Bool, _ change: (inout TranscriptItem.Kind) -> Void) {
        var indices: [Int] = []
        for (index, item) in conversation.items.enumerated() where matching(item.kind) { indices.append(index) }
        guard !indices.isEmpty else { return }
        self.change { conversation in
            for index in indices {
                var kind = conversation.items[index].kind
                change(&kind)
                conversation.items[index].kind = kind
            }
        }
    }

    /// Puts a conversation in memory without saving it (`--snapshot` modes, tests).
    func seedConversation(_ seeded: Conversation) {
        conversation = seeded
        transcript.swapped()
        transcript.show(conversation.items)
    }

    private func change(_ edit: (inout Conversation) -> Void) {
        edit(&conversation)
        transcript.show(conversation.items)
        lastUsed = .now
        scheduleSave()
    }

    // MARK: Unread

    func addUnread() { unread += 1 }

    func clearUnread() { if unread != 0 { unread = 0 } }

    // MARK: Saving

    private func scheduleSave() {
        isDirty = true
        guard persist != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let delay = self?.saveDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Hands the thread to `persist` now (quitting, deleting the Orb of the last turn…).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let persist else { return }
        isDirty = false
        persist(conversation)
    }

    /// The write `saveNow` handed over failed: the thread is unsaved again (unless the group is gone).
    func markUnsaved() {
        if persist != nil { isDirty = true }
    }

    /// Cancels the pending save (the group is deleted: its file goes, and nothing may bring it back).
    func discard() {
        saveTask?.cancel()
        saveTask = nil
        isDirty = false
        persist = nil
    }
}
