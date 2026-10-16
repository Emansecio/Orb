import Foundation
@testable import Orb

/// A delegation service for testing the groups: it keeps what the group runtime asks of it and lets the test play the members.
/// Nothing runs by itself. The test starts a request (`start`, which asks the group's hooks for the turn's preface exactly as the
/// real hub would, and reports the turn as started), lets the "member" ask someone (`ask`, like a call of the `orbs` tool) and
/// ends the turn (`finish`). A request that asked others and is still waiting for them ends as `awaitingChildren`; when the
/// last of them answers, the asker is owed a wake-up that the test plays with `start` again, as the real hub's inbox would.
@MainActor
final class FakeDelegationService: DelegationService {
    weak var groupHooks: GroupTurnHooks?

    /// The names the envelopes carry (the real hub knows them from the Orbs).
    var names: [UUID: String] = [:]
    /// Every request, by id.
    private(set) var requests: [UUID: DelegationRequest] = [:]
    /// The requests the group runtime made on behalf of the person, in order.
    private(set) var groupTurns: [DelegationRequest] = []
    /// Every request in the order it was made (the person's and the members').
    private(set) var order: [UUID] = []
    private(set) var cancelled: [(chain: UUID, reason: CancelReason)] = []
    /// What the preface of each turn said (`prompt(for:)`), by request id; one entry per start.
    private(set) var prefaces: [UUID: [String]] = [:]
    /// The members that are owed a wake-up in a chain (an answer arrived and they have not run again).
    private var inbox: [UUID: Set<UUID>] = [:]
    /// A request that `submitGroupTurn` should return as failed (a delegation switched off).
    var failsGroupTurns = false

    private func ref(_ id: UUID) -> OrbRef { OrbRef(id: id, name: names[id] ?? "") }

    // MARK: DelegationService

    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID, groupID: UUID?) throws -> OrbEnvelope {
        guard let target = names.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame })?.key else {
            throw DelegationRefusal.unknownOrb(name)
        }
        // The member asks inside the turn it is in: the chain is that turn's.
        guard let parent = requests.values.first(where: { $0.envelope.to.id == from && $0.state == .running }) else {
            throw DelegationRefusal.notInGroup
        }
        return try ask(from: from, to: target, text: text, parent: parent, kind: kind, messageID: messageID).envelope
    }

    func submitGroupTurn(member: UUID, text: String, chain: ChainContext, groupID: UUID, askedBy: UUID?) -> DelegationRequest {
        let envelope = OrbEnvelope(chainID: chain.chainID, kind: .ask, from: ref(askedBy ?? member), to: ref(member), text: text,
                                   hop: chain.hop, path: chain.path, groupID: groupID)
        let request = DelegationRequest(envelope: envelope, state: failsGroupTurns ? .failed : .queued)
        requests[envelope.id] = request
        order.append(envelope.id)
        groupTurns.append(request)
        return request
    }

    func cancelChain(_ id: UUID, by: CancelReason) {
        cancelled.append((id, by))
        for (key, request) in requests where request.envelope.chainID == id && [.queued, .running, .awaitingChildren].contains(request.state) {
            requests[key]?.state = .cancelled
        }
        for key in inbox.keys { inbox[key]?.remove(id) }
    }

    func chains(involving botID: UUID) -> [UUID] {
        var chains = Set<UUID>()
        for request in requests.values where [.queued, .running, .awaitingChildren].contains(request.state) {
            if request.envelope.to.id == botID || (request.envelope.from.id == botID && request.envelope.from.id != request.envelope.to.id) {
                chains.insert(request.envelope.chainID)
            }
        }
        chains.formUnion(inbox[botID] ?? [])
        return Array(chains)
    }

    func openRequests(from botID: UUID) -> [DelegationRequest] {
        requests.values.filter { $0.envelope.from.id == botID && $0.envelope.from.id != $0.envelope.to.id && [.queued, .running, .awaitingChildren].contains($0.state) }
    }

    func roster(for botID: UUID, groupID: UUID?) -> [OrbRef] { [] }

    // MARK: Playing the members

    /// The latest version of a request.
    func request(_ id: UUID) -> DelegationRequest { requests[id]! }

    /// A member inside the turn `parent` asks another member for something (a call of `orbs ask`). The group runtime may refuse it.
    @discardableResult
    func ask(from member: UUID, to target: UUID, text: String, parent: DelegationRequest, kind: OrbEnvelope.Kind = .ask,
             messageID: UUID = UUID()) throws -> DelegationRequest {
        let parent = request(parent.envelope.id)
        let chain = parent.envelope.chainID
        if let refusal = groupHooks?.refusal(forRequestFrom: member, to: target, chain: chain) { throw refusal }
        let envelope = OrbEnvelope(id: messageID, chainID: chain, kind: kind, from: ref(member), to: ref(target), text: text,
                                   hop: parent.envelope.hop + 1, path: parent.envelope.path + [member],
                                   servingRequest: parent.envelope.id, groupID: parent.envelope.groupID)
        let request = DelegationRequest(envelope: envelope, state: .queued)
        requests[envelope.id] = request
        order.append(envelope.id)
        if kind == .ask { requests[parent.envelope.id]?.openChildren.insert(envelope.id) }
        return request
    }

    /// The turn starts: the group runtime is asked for its preface (kept in `prefaces`) and told. Returns whether it started.
    @discardableResult
    func start(_ request: DelegationRequest) async -> Bool {
        var current = self.request(request.envelope.id)
        let member = current.envelope.to.id
        if let preface = await groupHooks?.prompt(for: current, member: member) { prefaces[current.envelope.id, default: []].append(preface) }
        inbox[member]?.remove(current.envelope.chainID)
        current.state = .running
        current.startedAt = .now
        requests[current.envelope.id] = current
        groupHooks?.turnStarted(current)
        return true
    }

    /// The turn ends with `reply`. A request with children still open ends as `awaitingChildren` (and is woken when the last one
    /// answers); otherwise it is closed and, when a member asked for it, the asker is owed a wake-up.
    func finish(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus = .ok) {
        var current = self.request(request.envelope.id)
        let waiting = !current.openChildren.isEmpty && outcome == .ok
        if waiting {
            current.state = .awaitingChildren
        } else {
            current.state = switch outcome {
            case .ok: .replied
            case .cancelled: .cancelled
            case .failed, .refused: .failed
            }
            current.finishedAt = .now
        }
        requests[current.envelope.id] = current
        groupHooks?.turnFinished(current, reply: reply, outcome: outcome)
        guard !waiting, let parent = current.envelope.servingRequest, var asker = requests[parent] else { return }
        asker.openChildren.remove(current.envelope.id)
        requests[parent] = asker
        if current.envelope.kind == .ask { inbox[asker.envelope.to.id, default: []].insert(asker.envelope.chainID) }
    }

    /// A member that asked and was answered is woken: its turn runs again (the same request, as the real hub resumes the
    /// conversation) and ends with `reply`.
    func wake(_ request: DelegationRequest, reply: String?) async {
        guard await start(request) else { return }
        finish(request, reply: reply)
    }

    /// The whole turn of a member that asks no one: it starts and ends with `reply`.
    func run(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus = .ok) async {
        guard await start(request) else { return }
        finish(request, reply: reply, outcome: outcome)
    }

    /// The requests made and not started yet.
    var queued: [DelegationRequest] { order.compactMap { requests[$0] }.filter { $0.state == .queued } }
}
