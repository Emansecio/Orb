import Foundation
import Observation

/// Where a group's current request stands.
enum GroupRunState: Equatable, Sendable {
    /// No request is running.
    case idle
    case running
    /// The budget was reached and the group waits for the person (Continuar / Encerrar).
    case paused(GroupPauseItem.Reason)
}

/// What the running request has spent against its budget (the header's counter and bar). nil when no request runs.
struct GroupUsage: Equatable, Sendable {
    var turns: Int
    var turnLimit: Int
    var tokens: Int
    var tokenLimit: Int

    init(turns: Int, turnLimit: Int, tokens: Int, tokenLimit: Int) {
        self.turns = turns
        self.turnLimit = turnLimit
        self.tokens = tokens
        self.tokenLimit = tokenLimit
    }
}

/// One group as the views see it: what changes while the app runs (who is typing, whether the group waits for you, the
/// messages you have not read). The shell the group runtime fills in; the group screens only read it.
@MainActor
@Observable
final class GroupLive {
    let id: UUID
    private(set) var unread = 0
    private(set) var runState = GroupRunState.idle
    /// The members in a turn right now.
    private(set) var typing: [UUID] = []
    private(set) var work: WorkLine?
    /// A member waits for your answer (an approval card).
    private(set) var needsYou = false
    /// What the running request has spent; nil when none runs.
    private(set) var usage: GroupUsage?

    init(id: UUID) { self.id = id }

    // WP5 replaces: the runtime writes the state of the group as the request moves on (never per token).
    func update(runState: GroupRunState, typing: [UUID], work: WorkLine?, needsYou: Bool, unread: Int, usage: GroupUsage?) {
        if self.runState != runState { self.runState = runState }
        if self.typing != typing { self.typing = typing }
        if self.work != work { self.work = work }
        if self.needsYou != needsYou { self.needsYou = needsYou }
        if self.unread != unread { self.unread = unread }
        if self.usage != usage { self.usage = usage }
    }
}
