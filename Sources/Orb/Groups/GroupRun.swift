import Foundation

/// One request of the person to a group, from the message that starts it until the group has nothing left to do: its chain of
/// turns (`id` is the chain's id in the delegation hub) and what it has spent. Nothing limits it: the person stops it (Parar
/// grupo, ⌘.). Memory only; the `WorkJournal` keeps the fact that one was open, and the next launch resumes it.
struct GroupRun: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case active
        case done
        case stopped
    }

    /// A member's turn in progress and the request it answers.
    struct Turn: Equatable, Sendable {
        var request: UUID
        var member: UUID
    }

    let id: UUID
    let groupID: UUID
    var phase = Phase.active
    /// The message that started the request (the board's session page says what was asked).
    var request: String
    var startedAt: Date
    var turnsUsed = 0
    var tokensUsed = 0
    /// The requests the person's messages made (from the person, not from a member), by id: the turns the hub owes the group.
    var asked: [UUID: UUID] = [:]
    /// The turns running now, in the order they began.
    var running: [Turn] = []
    /// The assignments already written in the thread (by request id), so a request that wakes its member again is not repeated.
    var posted: Set<UUID> = []
    /// Everyone who took a turn, in the order they first did.
    var participants: [UUID] = []
    /// The last thing the orchestrator said that closed a round, and the last thing anyone said (the page's result).
    var finalText: String?
    var lastText: String?
    /// Review replies seen (a member's reply that starts with APPROVED or CHANGES) and the last verdict.
    var round = 0
    var verdict: ReviewVerdict?

    /// `id`: a request resumed after the app closed keeps its run's id, so each member finds its worktree and branch again.
    static func new(group: OrbGroup, request: String, now: Date = .now, id: UUID = UUID()) -> GroupRun {
        GroupRun(id: id, groupID: group.id, request: request, startedAt: now)
    }

    var isOpen: Bool { phase == .active }

    mutating func note(participant member: UUID) {
        if !participants.contains(member) { participants.append(member) }
    }

    /// The numbers the header shows.
    var usage: GroupUsage { GroupUsage(turnsUsed: turnsUsed, tokensUsed: tokensUsed) }
}

/// What a request has spent so far, as the header shows it.
struct GroupUsage: Equatable, Sendable {
    var turnsUsed: Int
    var tokensUsed: Int
}
