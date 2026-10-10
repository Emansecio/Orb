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

/// One group as the views see it: what changes while the app runs (who is typing, whether the group waits for you, the
/// messages you have not read). The shell the group runtime fills in; nothing writes to it yet.
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

    init(id: UUID) { self.id = id }
}
