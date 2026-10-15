import Foundation

/// A group of Orbs the user talks to together. Its orchestrator receives each message first; the others are called by it
/// or by an @mention. Saved with the app's state (`AppState.groups`).
struct OrbGroup: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    /// In display order; includes the orchestrator.
    var memberIDs: [UUID]
    var orchestratorID: UUID
    /// What one request of the user may spend.
    var budget = GroupBudget()
    var policy = GroupPolicy()
    var createdAt = Date.now

    /// How many Orbs a group has.
    static let memberLimits = 2...8

    /// The group as it should be when only the Orbs in `alive` exist: members that are gone leave (and duplicates), a missing
    /// orchestrator becomes the first member, and a group left with fewer than two members is dissolved (nil).
    func normalized(alive: Set<UUID>) -> OrbGroup? {
        var seen: Set<UUID> = []
        var copy = self
        copy.memberIDs = memberIDs.filter { alive.contains($0) && seen.insert($0).inserted }
        if copy.memberIDs.count > Self.memberLimits.upperBound {
            copy.memberIDs = Array(copy.memberIDs.prefix(Self.memberLimits.upperBound))
        }
        guard copy.memberIDs.count >= Self.memberLimits.lowerBound else { return nil }
        if !copy.memberIDs.contains(copy.orchestratorID) { copy.orchestratorID = copy.memberIDs[0] }
        return copy
    }
}

extension OrbGroup {
    /// Tolerant decoding: a group saved by another version still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.value(.name, default: "")
        memberIDs = try c.lossyArray(.memberIDs)
        orchestratorID = try c.decodeIfPresent(UUID.self, forKey: .orchestratorID) ?? memberIDs.first ?? UUID()
        budget = (try? c.decodeIfPresent(GroupBudget.self, forKey: .budget)) ?? GroupBudget()
        policy = (try? c.decodeIfPresent(GroupPolicy.self, forKey: .policy)) ?? GroupPolicy()
        createdAt = try c.value(.createdAt, default: Date.now)
    }
}

/// What one request of the user may spend in a group: the turns and the tokens, before the group pauses and asks.
struct GroupBudget: Codable, Sendable, Equatable {
    var maxTurns = 12
    var maxTokens = 150_000
}

extension GroupBudget {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxTurns = max(1, try c.value(.maxTurns, default: 12))
        maxTokens = max(1, try c.value(.maxTokens, default: 150_000))
    }
}

struct GroupPolicy: Codable, Sendable, Equatable {
    /// Members may ask each other directly, not only through the orchestrator.
    var membersMayTalk = true

    init(membersMayTalk: Bool = true) { self.membersMayTalk = membersMayTalk }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        membersMayTalk = try c.value(.membersMayTalk, default: true)
    }
}

/// The card a group's thread shows when a request reached its budget and the group paused (`TranscriptItem.Kind.groupPause`).
struct GroupPauseItem: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case turns, tokens

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .turns) }
    }

    enum State: String, Codable, Sendable {
        case open, continued, ended

        /// A state from a newer version counts as ended: a card nobody can answer must not stay open.
        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .ended) }
    }

    var groupID: UUID
    var runID: UUID
    var reason: Reason
    var state: State = .open
    var turnsUsed: Int
    var tokensUsed: Int
    var turnLimit: Int
    var tokenLimit: Int
}

extension GroupPauseItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try c.decode(UUID.self, forKey: .groupID)
        runID = try c.decode(UUID.self, forKey: .runID)
        reason = try c.value(.reason, default: Reason.turns)
        state = try c.value(.state, default: State.ended)
        turnsUsed = try c.value(.turnsUsed, default: 0)
        tokensUsed = try c.value(.tokensUsed, default: 0)
        turnLimit = try c.value(.turnLimit, default: 0)
        tokenLimit = try c.value(.tokenLimit, default: 0)
    }
}
