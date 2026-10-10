import Foundation

/// One request of the person to a group, from the message that starts it until the group has nothing left to do: its chain of
/// turns (`id` is the chain's id in the delegation hub), its budget and what it has spent. Memory only: a request does not
/// survive the app closing.
struct GroupRun: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case active
        /// The budget was reached: no new turn starts until the person continues or ends it.
        case paused(GroupPauseItem.Reason)
        case done
        case stopped
    }

    /// A turn that could not start because the budget was spent: it goes out when the person continues.
    struct Held: Equatable, Sendable {
        var member: UUID
        var text: String
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
    var turnLimit: Int
    var tokenLimit: Int
    var held: [Held] = []
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

    static func new(group: OrbGroup, request: String, now: Date = .now) -> GroupRun {
        GroupRun(id: UUID(), groupID: group.id, request: request, startedAt: now, turnLimit: group.budget.maxTurns,
                 tokenLimit: group.budget.maxTokens)
    }

    var isOpen: Bool {
        switch phase {
        case .active, .paused: true
        case .done, .stopped: false
        }
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    /// Whether a new turn may start: it has not spent its turns nor its tokens.
    var budgetAllows: Bool { turnsUsed < turnLimit && tokensUsed < tokenLimit }

    /// What ran out first (turns win a tie).
    var exhausted: GroupPauseItem.Reason? {
        turnsUsed >= turnLimit ? .turns : tokensUsed >= tokenLimit ? .tokens : nil
    }

    /// "Continuar": another window of the group's budget on top of the one spent.
    mutating func extend(by budget: GroupBudget) {
        turnLimit += budget.maxTurns
        tokenLimit += budget.maxTokens
    }

    mutating func note(participant member: UUID) {
        if !participants.contains(member) { participants.append(member) }
    }

    /// The numbers the card and the header show.
    var usage: GroupBudgetUsage {
        GroupBudgetUsage(turnsUsed: turnsUsed, turnLimit: turnLimit, tokensUsed: tokensUsed, tokenLimit: tokenLimit)
    }
}

/// What a request has spent of its budget, as the header's counter and bar read it (8.7: the bar is `Palette.accentText` up to
/// 80 % and `Palette.warn` above).
struct GroupBudgetUsage: Equatable, Sendable {
    var turnsUsed: Int
    var turnLimit: Int
    var tokensUsed: Int
    var tokenLimit: Int

    var turnFraction: Double { turnLimit > 0 ? min(1, Double(turnsUsed) / Double(turnLimit)) : 0 }
    var tokenFraction: Double { tokenLimit > 0 ? min(1, Double(tokensUsed) / Double(tokenLimit)) : 0 }
    /// The one that is closer to the limit.
    var fraction: Double { max(turnFraction, tokenFraction) }
    /// Above 80 % the counter turns to the warning color.
    var isNearLimit: Bool { fraction >= 0.8 }
}
