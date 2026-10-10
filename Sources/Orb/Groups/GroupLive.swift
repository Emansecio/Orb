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
/// messages you have not read). Written by `GroupHub` only, and each property only when its value differs: writing an
/// `@Observable` property notifies its readers even when nothing changed.
@MainActor
@Observable
final class GroupLive {
    let id: UUID
    private(set) var unread = 0
    private(set) var runState = GroupRunState.idle
    /// The members in a turn right now, in the order they began.
    private(set) var typing: [UUID] = []
    /// What the group says it is doing ("Atlas coordena…", "Pesquisador e Revisor trabalhando…", "Pausado: continuar?"); nil
    /// when it does nothing.
    private(set) var work: WorkLine?
    /// A member waits for your answer (an approval card).
    private(set) var needsYou = false
    /// The members that wait for your answer.
    private(set) var waiting: [UUID] = []
    /// What the running request has spent of its budget; nil when none runs.
    private(set) var budget: GroupBudgetUsage?

    init(id: UUID) { self.id = id }

    var isWorking: Bool { runState != .idle }

    // MARK: Written by the group runtime

    func setUnread(_ count: Int) { if unread != count { unread = count } }

    func setRunState(_ state: GroupRunState) { if runState != state { runState = state } }

    func setTyping(_ members: [UUID]) { if typing != members { typing = members } }

    func setWork(_ line: WorkLine?) { if work != line { work = line } }

    func setWaiting(_ members: [UUID]) {
        if waiting != members { waiting = members }
        if needsYou != !members.isEmpty { needsYou = !members.isEmpty }
    }

    func setBudget(_ usage: GroupBudgetUsage?) { if budget != usage { budget = usage } }
}
