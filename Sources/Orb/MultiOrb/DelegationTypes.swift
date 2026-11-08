import Foundation

/// What a tool that reaches the app on the Orb's behalf (`orbs`, `orb_draft`) is handed: the call's arguments, and the text
/// the model reads back. Like `ScheduleHandler`, the app does the work.
typealias BridgeHandler = @Sendable (JSONValue) async throws -> String

/// Opens the creation card for a proposal and waits for the person's decision. The engine defines it, as it does `handoff`.
typealias ConfirmHandler = @Sendable (_ title: String, _ detail: String) async -> Bool
typealias ProposalHandler = @Sendable (OrbProposal) async -> ProposalOutcome

/// A request between Orbs as the app keeps it while it is in flight (memory only; the `WorkJournal` keeps the envelope of one outside any group, to send it again after the app closed).
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
    /// `group_create` was not let through (`DelegationHub.createGroup`).
    case groupSetup(GroupSetup)
    /// `group_edit` was not let through (`DelegationHub.editGroup`).
    case groupEdit(GroupEdit)
    /// The work the pulse pays for asked for more after the day's budget ran out (`AppModel.pulseBudgetSpent`).
    case pulseBudget

    /// Why a group was not changed.
    enum GroupEdit: Sendable, Equatable {
        /// "Orbs organizam o time" is off.
        case switchedOff
        /// No group has that name; the names that exist.
        case noGroup(String, [String])
        case unknownEdit(String)
        /// The edit needs `orb`, `name` or `objective` and it came empty.
        case missing(String)
        case alreadyMember(orb: String, group: String)
        case notMember(orb: String, group: String)
        case full(String)
        case nameTaken(String)
        /// Deleting, or taking out the member that dissolves the group, runs only after the user confirms.
        case needsConfirmation
        /// The group or the Orb behind the names changed between the user's card and the edit.
        case changed
        case objectiveRefused
        case unavailable
    }

    /// Why a group was not created.
    enum GroupSetup: Sendable, Equatable {
        /// "Orbs podem acionar grupos" is off.
        case switchedOff
        /// A routine's run or another Orb's request: only the Orb's own chat may create a group.
        case notFromHere
        /// The turn is the chat's but the person did not start it.
        case notAsked
        /// In a group's turn only the orchestrator creates groups.
        case notOrchestrator
        case noName
        /// An Orb or a group already has the name.
        case nameTaken(String)
        case memberCount
        case orchestratorNotMember(String)
        case unavailable
    }

    /// Why a request to a group was refused.
    enum GroupDoor: Sendable, Equatable {
        /// "Orbs podem acionar grupos" is off.
        case switchedOff
        case notMember
        /// A routine's run or another Orb's request: only the Orb's own chat may ask a group.
        case notFromHere
        /// The turn is the chat's but the person did not start it (an answer from another Orb woke it).
        case notAsked
        /// In a group's turn only the orchestrator asks another group.
        case notOrchestrator
        /// That group is already in this chain of groups asking groups: asking it back would loop.
        case inChain
        /// The group could not take the request (the app is resetting, its orchestrator is gone).
        case unavailable
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
        case .duplicate: "Pedido idêntico enviado há menos de um minuto: a resposta chega sozinha como mensagem (ou já chegou nesta conversa); não repita."
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
            case .notOrchestrator:
                "Só o orquestrador aciona outro grupo: responda com o resultado e diga o que falta."
            case .inChain:
                "O grupo “\(name)” já está nesta cadeia de grupos (ele acionou este, direta ou indiretamente): não peça de volta. "
                    + "Termine com o que tem; sua resposta final segue para quem pediu."
            case .unavailable:
                "O grupo “\(name)” não pôde receber o pedido agora: diga isso ao usuário e ofereça pedir a cada membro "
                    + "separadamente."
            case .tell:
                "Para um grupo, use ask: o grupo trabalha no fio dele e a resposta final volta para você."
            }
        case .groupSetup(let why):
            switch why {
            case .switchedOff:
                "O usuário desligou “Orbs podem acionar grupos” nos Ajustes: ele cria o grupo em Novo grupo (⌥⌘G). Diga isso."
            case .notFromHere:
                "Daqui não se cria grupo: só no seu chat, a pedido do usuário. Diga no resultado que grupo faria sentido."
            case .notAsked:
                "Você só cria um grupo quando o usuário pede, no turno dele: pergunte se ele quer."
            case .notOrchestrator:
                "Só o orquestrador cria grupos no turno de um grupo: diga ao orquestrador que grupo faria sentido."
            case .noName:
                "Dê um nome ao grupo em name."
            case .nameTaken(let name):
                "Já existe um Orb ou um grupo chamado “\(name)”: escolha outro nome."
            case .memberCount:
                "Um grupo tem de \(OrbGroup.memberLimits.lowerBound) a \(OrbGroup.memberLimits.upperBound) Orbs: ponha os nomes "
                    + "em members (list mostra os colegas)."
            case .orchestratorNotMember(let name):
                "“\(name)” não está em members: o orquestrador é um dos membros."
            case .unavailable:
                "Não consegui criar o grupo agora: diga isso ao usuário; ele cria em Novo grupo (⌥⌘G)."
            }
        case .groupEdit(let why):
            switch why {
            case .switchedOff:
                "O usuário desligou “Orbs organizam o time” nos Ajustes: ele muda o grupo na tela dele. Diga o que você mudaria."
            case .noGroup(let name, let known):
                "Não há grupo chamado “\(name)”." + (known.isEmpty ? " O usuário não tem grupos." : " Grupos: " + known.joined(separator: ", ") + ".")
            case .unknownEdit(let edit):
                "“\(edit)” não é uma mudança: use add, remove, orchestrator, rename, objective ou delete."
            case .missing(let field):
                "Preencha \(field) para essa mudança."
            case .alreadyMember(let orb, let group):
                "\(orb) já é membro do grupo “\(group)”."
            case .notMember(let orb, let group):
                "\(orb) não é membro do grupo “\(group)”."
            case .full(let group):
                "O grupo “\(group)” já tem \(OrbGroup.memberLimits.upperBound) membros, o máximo. Tire alguém antes de pôr outro Orb."
            case .nameTaken(let name):
                "Já existe um Orb ou um grupo chamado “\(name)”: escolha outro nome."
            case .needsConfirmation:
                "Essa mudança só vale depois que o usuário confirma, e ele não confirmou. Nada mudou."
            case .changed:
                "O grupo ou o Orb mudou desde que o usuário confirmou (outro nome, outro membro): nada mudou. Confira com orbs list e peça de novo."
            case .objectiveRefused:
                "Não consegui gravar o objetivo (grande demais ou a pasta do grupo não aceita escrita): encurte o texto ou diga isso ao usuário."
            case .unavailable:
                "Não consegui mudar o grupo agora: diga isso ao usuário; ele muda na tela do grupo."
            }
        case .pulseBudget:
            "O teto diário de tokens do pulso acabou: não peça mais nada nesta conversa. Termine com o que tem e diga o que "
                + "ficou faltando."
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

/// What `BotSession.routineID` stands for when it is set: a routine's run, a request from another Orb, a turn in a group, or the
/// pulse (an Orb waking itself, `Pulse.swift`).
enum SideRunKind: String, Sendable, Equatable {
    case routine, delegation, group, pulse
}
