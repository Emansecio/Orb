#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `--snapshot` modes of the group screens: groups-sidebar, group-chat, group-working (presence and what the request spent),
/// group-new, group-panel, group-board and group-empty. group-approval has the Pesquisador waiting on a permission and the Revisor
/// on a question (the bar of cards above the presence line). group-panel-readonly and group-new-readonly put Atlas (the orchestrator)
/// and the Revisor in Só leitura; group-chat-requests adds a request a member sent from its chat and a notice. Each mode seeds four Orbs and the
/// sample groups into the model, with the live state that mode shows.
@MainActor
enum GroupSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        let modes: Set<String> = ["groups-sidebar", "group-chat", "group-working", "group-new", "group-panel", "group-board",
                                  "group-empty", "group-panel-readonly", "group-new-readonly", "group-chat-requests", "group-approval"]
        guard modes.contains(screen) else { return nil }
        let sample = SampleGroups(model: model, mode: screen)
        switch screen {
        case "groups-sidebar":
            return AnyView(SidebarView().frame(width: 280))
        case "group-new", "group-new-readonly":
            return AnyView(NewGroupSheet(startingWith: sample.atlas.id).frame(width: 560))
        case "group-panel", "group-panel-readonly":
            return AnyView(GroupPanel(groupID: sample.launch.id).frame(width: 360, height: 700))
        case "group-board":
            return AnyView(GroupBoardView(memory: SampleGroups.board, setObjective: { _ in }, remember: { _ in },
                                          forget: { _ in }, restore: { _ in })
                .padding(.vertical, 8)
                .frame(width: 360, height: 700)
                .background(Palette.chrome))
        case "group-empty":
            return AnyView(GroupChatView(groupID: sample.empty.id))
        default:
            return AnyView(GroupChatView(groupID: sample.launch.id))
        }
    }
}

/// The Orbs and groups the group screens show. The mode decides the live state of "Lançamento".
@MainActor
private struct SampleGroups {
    let atlas: Bot
    let research: Bot
    let review: Bot
    let lia: Bot
    let launch: OrbGroup
    let empty: OrbGroup

    init(model: AppModel, mode: String) {
        var lead = model.bots.first ?? Bot(name: "Atlas", role: "Assistente do seu Mac", orb: WelcomeLooks.atlas)
        research = Bot(name: "Pesquisador", role: "Pesquisa na web", orb: WelcomeLooks.bento)
        var reviewer = Bot(name: "Revisor", role: "Revisa código",
                           orb: OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", accessories: ["fones"]))
        if mode.hasSuffix("-readonly") {
            lead.permissionMode = .readOnly
            reviewer.permissionMode = .readOnly
        }
        atlas = lead
        review = reviewer
        lia = Bot(name: "Lia", role: "Cuida de e-mails", orb: WelcomeLooks.lia)
        model.bots = [atlas, research, review, lia]

        launch = OrbGroup(name: "Lançamento", memberIDs: [atlas.id, research.id, review.id], orchestratorID: atlas.id)
        let revision = OrbGroup(name: "Revisão do texto", memberIDs: [lia.id, review.id], orchestratorID: lia.id)
        let general = OrbGroup(name: "Pesquisa geral", memberIDs: [atlas.id, research.id, review.id, lia.id], orchestratorID: atlas.id)
        empty = OrbGroup(name: "Ideias", memberIDs: [atlas.id, lia.id], orchestratorID: atlas.id)
        model.groups = [launch, revision, general, empty]
        model.groupSessions = [:]
        model.groupLives = [:]

        var conversation = Self.conversation(atlas: atlas, research: research, review: review, group: launch.id)
        if mode == "group-chat-requests" {
            conversation.items += Self.fromChat(atlas: atlas, research: research, review: review, group: launch.id)
        }
        let working = mode == "group-working" || mode == "groups-sidebar"
        if mode == "group-approval" { Self.seedWaiting(model, research: research, review: review) }
        model.groupSessions[launch.id] = GroupSession(groupID: launch.id, conversation: conversation)
        model.groupSessions[empty.id] = GroupSession(groupID: empty.id)

        let live = model.groupLive(launch.id)
        if mode == "group-approval" {
            live.update(runState: .running, typing: [research.id, review.id], work: nil, needsYou: true, unread: 0,
                        usage: GroupUsage(turnsUsed: 4, tokensUsed: 31_000))
        } else if working {
            live.update(runState: .running, typing: [research.id, review.id], work: nil, needsYou: false, unread: 0,
                        usage: GroupUsage(turnsUsed: 9, tokensUsed: 96_000))
        } else {
            live.update(runState: .idle, typing: [], work: nil, needsYou: false, unread: 0, usage: nil)
        }
        model.groupLive(revision.id).update(runState: .running, typing: [], work: nil, needsYou: true, unread: 2, usage: nil)
        model.groupLive(general.id).update(runState: .idle, typing: [], work: nil, needsYou: false, unread: 3, usage: nil)
    }

    /// The cards the two members raised, in the side conversations their turns run on (as `startSideRun` leaves them).
    private static func seedWaiting(_ model: AppModel, research: Bot, review: Bot) {
        let permission = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "curl -s https://todoist.com/pricing",
                                         reason: "Conferir o preço do plano anual.")
        let question = ApprovalRequest.question(OrbQuestion(text: "Reviso só o texto da página inicial ou também o dos e-mails?",
                                                            options: ["Só a página", "Também os e-mails"]), botName: review.name)
        for (bot, card) in [(research, permission), (review, question)] {
            let session = model.session(bot.id)
            session.isUnloaded = false
            session.conversation = Conversation(items: [TranscriptItem(.approval(card))])
        }
    }

    /// What the chat of "Lançamento" says: the request, the assignments, the answers and the orchestrator's word.
    private static func conversation(atlas: Bot, research: Bot, review: Bot, group: UUID) -> Conversation {
        let request = UUID(), chain = UUID()
        func post(_ kind: OrbMessageItem.Kind, from: Bot, to: Bot?, _ text: String) -> TranscriptItem {
            TranscriptItem(.orbMessage(OrbMessageItem(direction: .post, kind: kind, state: .replied, from: OrbRef(from),
                                                      to: to.map(OrbRef.init), text: text, requestID: request, chainID: chain,
                                                      groupID: group)))
        }
        return Conversation(items: [
            TranscriptItem(.event(OrbEvent(kind: .groupCreated, detail: "Lançamento · 3", groupID: group))),
            TranscriptItem(.user(text: "Quero preparar o lançamento do app de tarefas: pesquisa de concorrentes e um texto para a página inicial.",
                                 attachments: [])),
            post(.ask, from: atlas, to: research, "Levante três concorrentes e o preço de cada um."),
            post(.ask, from: atlas, to: review, "Quando houver um rascunho, revise o tom e os erros."),
            post(.reply, from: research, to: atlas, """
            Três concorrentes, com o preço de cada um:

            - **Todoist**: grátis com limite; Pro a US$ 4 por mês.
            - **Things**: pago uma vez, para Mac e iPhone.
            - **TickTick**: grátis com limite; Premium a US$ 3 por mês.
            """),
            post(.reply, from: atlas, to: nil, """
            A pesquisa está pronta. Falta o texto da página inicial: o Revisor pega o rascunho quando estiver pronto e eu junto \
            as duas partes para você.
            """),
            TranscriptItem(.user(text: "Ótimo. Capriche no tom, sem jargão.", attachments: [])),
        ])
    }

    /// A request the Pesquisador sent to the group from its own chat ("a seu pedido") and a notice from the Revisor.
    private static func fromChat(atlas: Bot, research: Bot, review: Bot, group: UUID) -> [TranscriptItem] {
        let chain = UUID()
        return [
            TranscriptItem(.orbMessage(OrbMessageItem(direction: .post, kind: .ask, state: .open, from: OrbRef(research),
                                                      to: OrbRef(atlas), text: "Levantem quanto cada concorrente cobra no plano anual.",
                                                      requestID: UUID(), chainID: chain, groupID: group, fromChat: true))),
            TranscriptItem(.orbMessage(OrbMessageItem(direction: .post, kind: .tell, state: .replied, from: OrbRef(review),
                                                      to: OrbRef(research), text: "O Things mudou o preço ontem: confira no site.",
                                                      requestID: UUID(), chainID: chain, groupID: group))),
        ]
    }

    /// What the board holds: the objective, the agreements and what the members saved.
    static var board: MemorySnapshot {
        let now = Date.now
        return MemorySnapshot(identity: "Lançar o app de tarefas até sexta, com uma página inicial clara.", interviewPending: false,
                              items: [
                                  MemorySnapshot.Item(path: "preferencias/tom.md", kind: .preferencia,
                                                      title: "Português do Brasil, tom direto",
                                                      body: "Português do Brasil, tom direto e sem jargão.", date: now, compacted: false),
                                  MemorySnapshot.Item(path: "fatos/concorrentes.md", kind: .fato,
                                                      title: "Concorrentes: Todoist, Things e TickTick",
                                                      body: "Concorrentes: Todoist, Things e TickTick.", date: now, compacted: false),
                                  MemorySnapshot.Item(path: "procedimentos/revisao.md", kind: .procedimento,
                                                      title: "Revisar antes de publicar", body: "Revisar o texto antes de publicar.",
                                                      date: now, compacted: false),
                              ])
    }
}

extension GroupLive {
    /// Sets the whole live state at once, for the snapshot modes and the screen tests (the runtime uses the single setters).
    func update(runState: GroupRunState, typing: [UUID], work: WorkLine?, needsYou: Bool, unread: Int, usage: GroupUsage?) {
        setRunState(runState)
        setTyping(typing)
        setWork(work)
        setWaiting(needsYou ? typing : [])
        setUnread(unread)
        setUsage(usage)
    }
}
#endif
