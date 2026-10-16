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
    /// progress): past `requestTimeout` it is still waiting for real work, so only this ceiling ends it. A request at work
    /// itself is never ended by time: past this, you get a banner with Parar (`DelegationHub.sweep`).
    static let workTimeout: TimeInterval = 3 * 3600
}

/// Why a request between Orbs was not sent. `message` is what the model reads (it becomes a `ToolError`): what happened and
/// what to do next, so the model does not guess or try again blindly.
enum DelegationRefusal: Error, Equatable, Sendable {
    case switchedOff, unknownOrb(String), selfRequest, notInGroup, alreadyInChain(String)
    case stopped, duplicate, emptyMessage, tooLong, orbBusyDeleting
    /// The group lets only its orchestrator hand out work (`GroupPolicy.membersMayTalk` off).
    case membersMayNotTalk
    /// The name is a group's, not an Orb's.
    case groupName(String)
    /// The name is the group whose turn this is.
    case ownGroup(String)
    /// `orbs ask` with the name of a group was not let through (`DelegationHub.submitToGroup`).
    case groupDoor(String, GroupDoor)

    /// Why a request to a group was refused.
    enum GroupDoor: Sendable, Equatable {
        /// "Orbs podem acionar grupos" is off.
        case switchedOff
        case notMember
        /// A routine's run or another Orb's request: only the Orb's own chat may ask a group.
        case notFromHere
        /// The turn is the chat's but the person did not start it (an answer from another Orb woke it).
        case notAsked
        /// The group is working on a request already.
        case busy
        /// A group is asked, not told.
        case tell
    }

    var message: String {
        switch self {
        case .switchedOff:
            "Os Orbs não podem conversar entre si agora (o usuário desligou isso nos Ajustes): faça você mesmo ou diga ao usuário "
                + "o que precisaria de outro Orb."
        case .unknownOrb(let name):
            "Não existe um Orb chamado “\(name)”. Use o nome de um Orb por chamada (para vários, uma chamada para cada); list "
                + "mostra os colegas."
        case .selfRequest: "Você não pode pedir a si mesmo: faça você mesmo."
        case .notInGroup: "Esse Orb não está neste grupo: peça só aos membros (list mostra quem são)."
        case .membersMayNotTalk:
            "Neste grupo só o orquestrador distribui o trabalho: responda com o resultado e diga o que falta; sua resposta final "
                + "volta para quem pediu."
        case .alreadyInChain(let name):
            "\(name) já está esperando a resposta desta conversa: não peça de volta. Termine o turno com o que tem; sua resposta "
                + "final segue para quem pediu."
        case .stopped: "O usuário interrompeu esta conversa entre Orbs: não peça mais nada nela; termine com o que tem."
        case .duplicate: "Pedido idêntico já enviado: a resposta chega sozinha como mensagem; não repita."
        case .emptyMessage: "A mensagem está vazia: escreva o pedido em message."
        case .tooLong: "A mensagem passa de \(DelegationLimits.messageLimit) caracteres: resuma."
        case .orbBusyDeleting: "Esse Orb está sendo apagado: peça a outro colega ou faça você mesmo."
        case .groupName(let name):
            "“\(name)” é um grupo, não um Orb. Você não escreve no fio de um grupo nem inicia o trabalho dele: o usuário faz isso "
                + "na tela do grupo. Diga isso e ofereça pedir a cada membro separadamente (cada pedido roda fora do grupo) ou "
                + "escrever o texto para o usuário colar."
        case .groupDoor(let name, let why):
            switch why {
            case .switchedOff:
                "O usuário desligou “Orbs podem acionar grupos” nos Ajustes: ele inicia o trabalho de “\(name)” na tela do grupo. "
                    + "Ofereça escrever o texto para ele colar ou pedir a cada membro separadamente."
            case .notMember:
                "Você não faz parte do grupo “\(name)”: só um membro aciona o grupo. Ofereça pedir a cada membro separadamente ou "
                    + "escrever o texto para o usuário colar."
            case .notFromHere:
                "Daqui não se aciona o grupo “\(name)”: só do seu chat, a pedido do usuário (não de uma rotina nem de um pedido de "
                    + "outro Orb). Diga no resultado o que o grupo deveria fazer."
            case .notAsked:
                "Você só aciona o grupo “\(name)” quando o usuário pede, no turno dele: pergunte se ele quer."
            case .busy:
                "O grupo “\(name)” já está trabalhando num pedido: espere ele terminar (o usuário acompanha na tela do grupo) ou "
                    + "peça a cada membro separadamente."
            case .tell:
                "Para um grupo, use ask: o grupo trabalha no fio dele e a resposta final volta para você."
            }
        case .ownGroup(let name):
            "Você já está trabalhando no grupo “\(name)”: peça a um membro pelo nome (os membros estão no início da mensagem do "
                + "grupo)."
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

/// What `BotSession.routineID` stands for when it is set: a routine's run, a request from another Orb, or a turn in a group.
enum SideRunKind: String, Sendable, Equatable {
    case routine, delegation, group
}
