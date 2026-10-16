import Foundation

/// What a tool that reaches the app on the Orb's behalf (`orbs`, `orb_draft`) is handed: the call's arguments, and the text
/// the model reads back. Like `ScheduleHandler`, the app does the work.
typealias BridgeHandler = @Sendable (JSONValue) async throws -> String

/// Opens the creation card for a proposal and waits for the person's decision. The engine defines it, as it does `handoff`.
typealias ProposalHandler = @Sendable (OrbProposal) async -> ProposalOutcome

/// A request between Orbs as the app keeps it while it is in flight (memory only; a request does not survive the app closing).
struct DelegationRequest: Sendable, Equatable {
    enum State: String, Sendable {
        case queued, running, awaitingChildren, replied, failed, cancelled
    }

    var envelope: OrbEnvelope
    var state: State = .queued
    /// The requests the target asked in turn and has not seen answered.
    var openChildren: Set<UUID> = []
    var startedAt: Date?
    var finishedAt: Date?
}

/// The sizes and waits of Orbs talking to each other (tests cite these). How many requests, how deep a chain and how many
/// turns are not limited: the person stops a chain with ⌘. or Parar.
enum DelegationLimits {
    static let messageLimit = 4_000, replyLimit = 6_000, wakeBatch = 5
    static let requestTimeout: TimeInterval = 30 * 60, keptPedidos = 20
    static let rosterLimit = 12, roleClip = 80
    /// How long a request may wait while the work it waits for goes on (a child still at work, a queue behind a turn in
    /// progress): past `requestTimeout` it is still waiting for real work, so only this ceiling ends it (a turn that hangs).
    static let workTimeout: TimeInterval = 3 * 3600
}

/// Why a request between Orbs was not sent. `message` is what the model reads (it becomes a `ToolError`).
enum DelegationRefusal: Error, Equatable, Sendable {
    case switchedOff, unknownOrb(String), selfRequest, notInGroup, alreadyInChain(String)
    case stopped, duplicate, emptyMessage, tooLong, orbBusyDeleting

    var message: String {
        switch self {
        case .switchedOff: "Os Orbs não podem conversar entre si agora (o usuário desligou isso nos Ajustes)."
        case .unknownOrb(let name): "Não existe um Orb chamado “\(name)”. Use list para ver os colegas."
        case .selfRequest: "Você não pode pedir a si mesmo."
        case .notInGroup: "Esse Orb não está neste grupo."
        case .alreadyInChain(let name): "\(name) já está esperando por você nesta conversa."
        case .stopped: "Esta conversa entre Orbs foi interrompida."
        case .duplicate: "Pedido idêntico já enviado."
        case .emptyMessage: "A mensagem está vazia."
        case .tooLong: "A mensagem passa de \(DelegationLimits.messageLimit) caracteres: resuma."
        case .orbBusyDeleting: "Esse Orb está sendo apagado."
        }
    }

    var toolError: ToolError { ToolError(message) }
}

/// Where a turn stands in its chain of requests.
struct ChainContext: Sendable, Equatable {
    var chainID: UUID
    var hop: Int
    var path: [UUID]
    var groupID: UUID?
    var serving: UUID?
}

/// What a turn that is a side run (a routine's run, a request from another Orb, a group's turn) knows about itself.
struct SideRunInfo: Sendable, Equatable {
    var kind: SideRunKind
    var id: UUID
    var chain: ChainContext?
}

/// What `BotSession.routineID` stands for when it is set: a routine's run, a request from another Orb, or a turn in a group.
enum SideRunKind: String, Sendable, Equatable {
    case routine, delegation, group
}
