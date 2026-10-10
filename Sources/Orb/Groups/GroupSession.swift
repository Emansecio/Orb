import Foundation
import Observation

/// A group's thread in memory: the conversation of the group (`.user`, `.orbMessage(post)`, `.event`, `.groupPause`) and what
/// the chat view shows of it. The shell the group runtime fills in (saving, unloading, the loop).
@MainActor
@Observable
final class GroupSession {
    let groupID: UUID
    var conversation = Conversation()
    let transcript: OrbTranscript
    private(set) var unread = 0

    init(groupID: UUID, conversation: Conversation = Conversation()) {
        self.groupID = groupID
        self.conversation = conversation
        transcript = OrbTranscript(items: conversation.items)
    }
}

// MARK: MultiOrb (WP6 placeholders: WP5 replaces every member of this extension)

extension AppModel {
    /// A group's thread, made empty the first time it is asked for. // WP5 replaces
    func groupSession(_ id: UUID) -> GroupSession {
        if let session = groupSessions[id] { return session }
        let session = GroupSession(groupID: id)
        groupSessions[id] = session
        return session
    }

    /// A group's live state, made the first time it is asked for. // WP5 replaces
    func groupLive(_ id: UUID) -> GroupLive {
        if let live = groupLives[id] { return live }
        let live = GroupLive(id: id)
        groupLives[id] = live
        return live
    }

    /// The person's message to the group: the thread shows it. The runtime also wakes the orchestrator. // WP5 replaces
    func postUserMessage(_ id: UUID, text: String) {
        let session = groupSession(id)
        session.conversation.items.append(TranscriptItem(.user(text: text, attachments: [])))
        session.transcript.show(session.conversation.items)
    }

    /// Continuar: one more window of the budget, and the members in the queue run. // WP5 replaces
    func continueRun(_ id: UUID) {}

    /// Parar grupo (and Encerrar): cancels the request's turns and queue. // WP5 replaces
    func stopGroup(_ id: UUID) {}

    /// The group's shared board (its memory bank as a snapshot). // WP5 replaces
    func groupBoard(_ id: UUID) -> MemorySnapshot { MemorySnapshot() }

    /// Writes the objective (the board's identity note). // WP5 replaces
    func setGroupObjective(_ id: UUID, to text: String) {}

    /// Adds a shared agreement to the board. // WP5 replaces
    func rememberGroupAgreement(_ id: UUID, text: String) {}

    /// "Esquecer" on the board, and its "Desfazer". // WP5 replaces
    func forgetGroupNote(_ item: MemorySnapshot.Item, of id: UUID) {}
    func restoreGroupNote(_ item: MemorySnapshot.Item, of id: UUID) {}

    /// Creates a group with these members (in this order) and orchestrator. // WP5 replaces (it also normalizes the groups)
    @discardableResult
    func createGroup(name: String, memberIDs: [UUID], orchestratorID: UUID, budget: GroupBudget) -> OrbGroup {
        let group = OrbGroup(name: name, memberIDs: memberIDs, orchestratorID: orchestratorID, budget: budget)
        groups.append(group)
        return group
    }

    func renameGroup(_ id: UUID, to name: String) { // WP5 replaces
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    func setGroupOrchestrator(_ id: UUID, to memberID: UUID) { // WP5 replaces
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].memberIDs.contains(memberID) else { return }
        groups[index].orchestratorID = memberID
    }

    /// Adds an Orb (at most `OrbGroup.memberLimits`). // WP5 replaces
    func addGroupMember(_ id: UUID, memberID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }), !groups[index].memberIDs.contains(memberID),
              groups[index].memberIDs.count < OrbGroup.memberLimits.upperBound else { return }
        groups[index].memberIDs.append(memberID)
    }

    /// Removes an Orb (never below two); the orchestrator leaving hands the role to the first member. // WP5 replaces
    func removeGroupMember(_ id: UUID, memberID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].memberIDs.count > OrbGroup.memberLimits.lowerBound,
              groups[index].memberIDs.contains(memberID) else { return }
        groups[index].memberIDs.removeAll { $0 == memberID }
        if groups[index].orchestratorID == memberID { groups[index].orchestratorID = groups[index].memberIDs[0] }
    }

    func setGroupBudget(_ id: UUID, to budget: GroupBudget) { // WP5 replaces
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].budget = budget
    }

    func setGroupPolicy(_ id: UUID, to policy: GroupPolicy) { // WP5 replaces
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].policy = policy
    }

    /// Apaga o grupo, a thread e o quadro. // WP5 replaces
    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        groupSessions[id] = nil
        groupLives[id] = nil
    }
}
