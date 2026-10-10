import Foundation

/// The runtime of Orbs asking each other for work. This is the shell the other packages build against: it refuses every
/// request (`switchedOff`) and holds nothing, so the app behaves as it did before Orbs could talk.
@MainActor
final class DelegationHub: DelegationService {
    weak var groupHooks: GroupTurnHooks?

    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?) throws -> OrbEnvelope {
        throw DelegationRefusal.switchedOff
    }

    func submitGroupTurn(member: UUID, text: String, chain: ChainContext, groupID: UUID, askedBy: UUID?) -> DelegationRequest {
        let envelope = OrbEnvelope(chainID: chain.chainID, kind: .ask, from: OrbRef(id: askedBy ?? member, name: ""),
                                   to: OrbRef(id: member, name: ""), text: text, hop: chain.hop, path: chain.path,
                                   groupID: groupID)
        return DelegationRequest(envelope: envelope, state: .failed)
    }

    func cancelChain(_ id: UUID, by: CancelReason) {}

    func chains(involving botID: UUID) -> [UUID] { [] }

    func openRequests(from botID: UUID) -> [DelegationRequest] { [] }

    func roster(for botID: UUID, groupID: UUID?) -> [OrbRef] { [] }

    func tokensUsed(_ n: Int, chain: UUID) {}
}
