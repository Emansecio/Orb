import Foundation

/// Who or what ended a chain of requests.
enum CancelReason: String, Sendable, Equatable {
    case user, budget, switchOff, orbDeleted
}

/// What the app offers Orbs that ask each other for work. `DelegationHub` implements it (a shell until the runtime lands).
@MainActor
protocol DelegationService: AnyObject {
    var groupHooks: GroupTurnHooks? { get set }
    /// Sends a request or a notice; throws a `DelegationRefusal` and changes nothing when it cannot.
    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?) throws -> OrbEnvelope
    /// Asks a member of a group for a turn.
    func submitGroupTurn(member: UUID, text: String, chain: ChainContext, groupID: UUID, askedBy: UUID?) -> DelegationRequest
    func cancelChain(_ id: UUID, by: CancelReason)
    /// The chains the Orb takes part in (asker with an open request, target at work, reply waiting for it).
    func chains(involving botID: UUID) -> [UUID]
    func openRequests(from botID: UUID) -> [DelegationRequest]
    /// The teammates the Orb is told about (all other Orbs, or the members of the group).
    func roster(for botID: UUID, groupID: UUID?) -> [OrbRef]
    /// Adds tokens a turn used to its chain's budget.
    func tokensUsed(_ n: Int, chain: UUID)
}

/// What a group's runtime does around the turns the hub runs for its members (implemented by the group hub, called by the
/// delegation hub).
@MainActor
protocol GroupTurnHooks: AnyObject {
    /// The text that opens a member's turn ("pedido de vez": the group, the thread since its last turn, the board).
    func prompt(for request: DelegationRequest, member: UUID) async -> String
    func turnStarted(_ request: DelegationRequest)
    func turnFinished(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus)
}
