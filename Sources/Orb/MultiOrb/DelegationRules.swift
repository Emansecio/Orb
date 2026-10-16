import Foundation

/// What a request between Orbs has to satisfy, as pure functions over a snapshot (no hub, no clock): the order of the
/// refusals is the contract (`DelegationRefusal`), and the tests cite each limit. The hub builds the `Input` from its state.
enum DelegationRules {
    /// What the hub knows about the chain a request would join.
    struct ChainFacts: Equatable, Sendable {
        var messages = 0
        var turns = 0
        var tokens = 0
        var cancelled = false
        /// Requests the sender already made to this very target in the chain.
        var pairCount = 0
    }

    struct Input: Sendable {
        /// The switch of Ajustes (a group's request does not depend on it).
        var switchOn = true
        var groupID: UUID?
        /// The members of the group, when the request belongs to one.
        var groupMembers: Set<UUID>?
        /// Every Orb, in the order of the sidebar.
        var orbs: [OrbRef] = []
        var sender: OrbRef
        var targetName: String
        var text: String
        var kind = OrbEnvelope.Kind.ask
        var messageID = UUID()
        /// The chain the sender's turn belongs to (nil: the turn is the person's own chat; a new chain begins).
        var context: ChainContext?
        var chain = ChainFacts()
        /// Requests of the sender, in every chain, that nobody answered yet.
        var openFromSender = 0
        /// Orbs of the chain's path that wait for an answer in this chain.
        var waitingInPath: Set<UUID> = []
        var seenMessage = false
        /// The same text went to the same target in this chain within `duplicateWindow`.
        var recentSameText = false
        var newChainID = UUID()
    }

    /// What a valid request becomes.
    struct Plan: Equatable, Sendable {
        var target: OrbRef
        var text: String
        var chainID: UUID
        var hop: Int
        var path: [UUID]
        var isNewChain: Bool
    }

    /// The same text sent to the same Orb again within this long is a repeat.
    static let duplicateWindow: TimeInterval = 60

    /// The refusals in the order they are checked; throws the first one that applies.
    static func validate(_ input: Input) throws -> Plan {
        // 1. The person's switch (a group was made by the person, so it works regardless).
        guard input.switchOn || input.groupID != nil else { throw DelegationRefusal.switchedOff }
        // 2. The target: the same name without accents or case, else a unique prefix; not the sender; in the group, a member.
        guard let target = resolve(input.targetName, among: input.orbs) else {
            throw DelegationRefusal.unknownOrb(input.targetName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard target.id != input.sender.id else { throw DelegationRefusal.selfRequest }
        if input.groupID != nil {
            guard let members = input.groupMembers, members.contains(target.id) else { throw DelegationRefusal.notInGroup }
        }
        // 3. The text.
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal.emptyMessage }
        guard text.count <= DelegationLimits.messageLimit else { throw DelegationRefusal.tooLong }
        // 4. The chain: the sender's own, or a new one that starts with this request.
        let hop = (input.context?.hop ?? 0) + 1
        let path = (input.context?.path.isEmpty == false ? input.context?.path : nil) ?? [input.sender.id]
        // 5. How deep.
        guard hop <= DelegationLimits.maxHops else { throw DelegationRefusal.hopLimit }
        // 6. No A→B→A: the target is already in the path and waits for an answer.
        if path.contains(target.id), input.waitingInPath.contains(target.id) {
            throw DelegationRefusal.alreadyInChain(target.name)
        }
        // 7. Open requests (a notice needs no answer, so it is not one); in a group, one per teammate when that is more.
        if input.kind == .ask, input.openFromSender >= openLimit(groupSize: input.groupMembers?.count) { throw DelegationRefusal.tooManyOpen }
        // 8. and 9. The chain's budget and the pair; a group's own budget (turns and tokens, visible to the person) governs its requests.
        if input.groupID == nil {
            let facts = input.chain
            if facts.cancelled || facts.messages >= DelegationLimits.maxMessagesPerChain
                || facts.turns >= DelegationLimits.maxTurnsPerChain || facts.tokens >= DelegationLimits.maxTokensPerChain {
                throw DelegationRefusal.budgetSpent
            }
            if facts.pairCount >= DelegationLimits.maxPerPair { throw DelegationRefusal.pairLimit }
        } else if input.chain.cancelled {
            throw DelegationRefusal.budgetSpent
        }
        // 10. The same message again (by id), or the same words to the same target a moment ago.
        if input.seenMessage || input.recentSameText { throw DelegationRefusal.duplicate }
        return Plan(target: target, text: text, chainID: input.context?.chainID ?? input.newChainID, hop: hop, path: path,
                    isNewChain: input.context == nil)
    }

    /// How many requests an Orb may have waiting for an answer: `maxOpenPerOrb`, or in a group of more than four, one per
    /// teammate (the orchestrator of a group of six assigns five pieces at once).
    static func openLimit(groupSize: Int?) -> Int {
        max(DelegationLimits.maxOpenPerOrb, (groupSize ?? 0) - 1)
    }

    /// "pesquisador", "Pesquisador" and "pesquisadór" are one name; a name that starts the same way as exactly one Orb is that
    /// Orb ("pesq"). An ambiguous prefix is no Orb at all (the model is told to use `list`).
    static func resolve(_ name: String, among orbs: [OrbRef]) -> OrbRef? {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return nil }
        let exact = orbs.filter { fold($0.name) == wanted }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let prefixed = orbs.filter { fold($0.name).hasPrefix(wanted) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What makes two sends "the same words": the target and the text without case, accents or spacing.
    static func repeatKey(to target: UUID, text: String) -> String { target.uuidString + "|" + fold(text) }
}
