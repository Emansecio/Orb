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
    var state: State
    /// The requests the target asked in turn and has not seen answered.
    var openChildren: Set<UUID>
    var startedAt: Date?
    var finishedAt: Date?

    init(envelope: OrbEnvelope, state: State = .queued, openChildren: Set<UUID> = [], startedAt: Date? = nil,
         finishedAt: Date? = nil) {
        self.envelope = envelope
        self.state = state
        self.openChildren = openChildren
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// The limits of Orbs talking to each other (tests cite these).
enum DelegationLimits {
    static let maxHops = 4, maxOpenPerOrb = 3, maxMessagesPerChain = 12, maxTurnsPerChain = 10
    static let maxTokensPerChain = 200_000, maxPerPair = 3
    static let messageLimit = 4_000, replyLimit = 6_000, wakeBatch = 5
    static let sideRunMaxSteps = 40, requestTimeout: TimeInterval = 30 * 60, keptPedidos = 20
    static let rosterLimit = 12, roleClip = 80
}

/// Why a request between Orbs was not sent. `message` is what the model reads (it becomes a `ToolError`).
enum DelegationRefusal: Error, Equatable, Sendable {
    case switchedOff, unknownOrb(String), selfRequest, notInGroup, hopLimit, alreadyInChain(String)
    case tooManyOpen, budgetSpent, pairLimit, duplicate, emptyMessage, tooLong, orbBusyDeleting

    var message: String {
        switch self {
        case .switchedOff: "Os Orbs não podem conversar entre si agora (o usuário desligou isso nos Ajustes)."
        case .unknownOrb(let name): "Não existe um Orb chamado “\(name)”. Use list para ver os colegas."
        case .selfRequest: "Você não pode pedir a si mesmo."
        case .notInGroup: "Esse Orb não está neste grupo."
        case .hopLimit: "Limite de \(DelegationLimits.maxHops) encadeamentos atingido: responda com o que tem."
        case .alreadyInChain(let name): "\(name) já está esperando por você nesta conversa."
        case .tooManyOpen: "Você já tem \(DelegationLimits.maxOpenPerOrb) pedidos abertos; espere as respostas."
        case .budgetSpent: "O orçamento desta conversa entre Orbs acabou."
        case .pairLimit: "Você já falou \(DelegationLimits.maxPerPair) vezes com esse Orb nesta conversa."
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
