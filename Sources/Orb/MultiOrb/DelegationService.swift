import Foundation

/// Who or what ended a chain of requests.
enum CancelReason: String, Sendable, Equatable {
    case user, switchOff, orbDeleted
    /// A card waited a day with no answer and the Orb gave up (`AppModel.giveUpWaiting`): nobody stopped it.
    case gaveUp
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
    /// A member asks its group from its own chat, at the person's request: the orchestrator gets a turn whose final answer goes
    /// back to the asker's chat (`OrbEnvelope.fromChat`). `id` is the message id of the call.
    func submitGroupRequest(from asker: UUID, text: String, chain: ChainContext, groupID: UUID, orchestrator: UUID,
                            id: UUID) -> DelegationRequest
    /// The person wrote to the group again before `member`'s turn for their last message began: `text` joins that turn, which
    /// answers both. Nil when there is no such turn (the new message gets a turn of its own).
    func joinQueuedGroupTurn(member: UUID, chainID: UUID, text: String) -> DelegationRequest?
    func cancelChain(_ id: UUID, by: CancelReason)
    /// The chains the Orb takes part in (asker with an open request, target at work, reply waiting for it).
    func chains(involving botID: UUID) -> [UUID]
    func openRequests(from botID: UUID) -> [DelegationRequest]
    /// The teammates the Orb is told about (all other Orbs, or the members of the group).
    func roster(for botID: UUID, groupID: UUID?) -> [OrbRef]
}

/// What a group's runtime does around the turns the hub runs for its members (implemented by the group hub, called by the
/// delegation hub).
@MainActor
protocol GroupTurnHooks: AnyObject {
    /// The text that opens a member's turn ("pedido de vez": the group, the thread since its last turn, the board).
    func prompt(for request: DelegationRequest, member: UUID) async -> String
    func turnStarted(_ request: DelegationRequest)
    func turnFinished(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus)
    // MARK: MultiOrb (WP5)
    /// Asked by `submit` for a request inside a group's chain, after its own checks: a refusal (`.membersMayNotTalk` when the
    /// group's policy keeps members from asking each other) replaces the send. The default allows.
    func refusal(forRequestFrom asker: UUID, to member: UUID, chain: UUID) -> DelegationRefusal?
    // MARK: end MultiOrb (WP5)
    /// A group's chain was stopped by the person from outside the group's screen (the Parar of an Orb that waits for it, or of a
    /// member at work): the group stops as with "Parar grupo".
    func chainStopped(_ chainID: UUID)
    /// A member left a notice (`tell`) inside the group's chain: it is a post in the thread and runs no turn.
    func noticePosted(_ envelope: OrbEnvelope)
}

// MARK: MultiOrb (WP5)
// Optional parts of the contract: a class that conforms gets these when it does not write its own.
extension GroupTurnHooks {
    func refusal(forRequestFrom asker: UUID, to member: UUID, chain: UUID) -> DelegationRefusal? { nil }
    func chainStopped(_ chainID: UUID) {}
    func noticePosted(_ envelope: OrbEnvelope) {}
}
// MARK: end MultiOrb (WP5)
