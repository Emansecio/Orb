import SwiftUI

/// `--snapshot` modes of the group screens: groups-sidebar, group-chat, group-working (presence and the budget), group-pause
/// (the card that asks to continue), group-new, group-panel, group-board and group-empty. Each mode seeds four Orbs and the
/// sample groups into the model, with the live state that mode shows.
@MainActor
enum GroupSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        let modes: Set<String> = ["groups-sidebar", "group-chat", "group-working", "group-pause", "group-new", "group-panel",
                                  "group-board", "group-empty"]
        guard modes.contains(screen) else { return nil }
        let sample = SampleGroups(model: model, mode: screen)
        switch screen {
        case "groups-sidebar":
            return AnyView(SidebarView().frame(width: 280))
        case "group-new":
            return AnyView(NewGroupSheet(startingWith: sample.atlas.id).frame(width: 560))
        case "group-panel":
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
        atlas = model.bots.first ?? Bot(name: "Atlas", role: "Assistente do seu Mac", orb: WelcomeLooks.atlas)
        research = Bot(name: "Pesquisador", role: "Pesquisa na web", orb: WelcomeLooks.bento)
        review = Bot(name: "Revisor", role: "Revisa código",
                     orb: OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", accessories: ["fones"]))
        lia = Bot(name: "Lia", role: "Cuida de e-mails", orb: WelcomeLooks.lia)
        model.bots = [atlas, research, review, lia]

        launch = OrbGroup(name: "Lançamento", memberIDs: [atlas.id, research.id, review.id], orchestratorID: atlas.id,
                          budget: GroupBudget(maxTurns: 12, maxTokens: 150_000))
        let revision = OrbGroup(name: "Revisão do texto", memberIDs: [lia.id, review.id], orchestratorID: lia.id)
        let general = OrbGroup(name: "Pesquisa geral", memberIDs: [atlas.id, research.id, review.id, lia.id], orchestratorID: atlas.id)
        empty = OrbGroup(name: "Ideias", memberIDs: [atlas.id, lia.id], orchestratorID: atlas.id)
        model.groups = [launch, revision, general, empty]
        model.groupSessions = [:]
        model.groupLives = [:]

        var conversation = Self.conversation(atlas: atlas, research: research, review: review, group: launch.id)
        let working = mode == "group-working" || mode == "groups-sidebar"
        let paused = mode == "group-pause"
        if paused {
            conversation.items.append(TranscriptItem(.groupPause(GroupPauseItem(groupID: launch.id, runID: UUID(), reason: .turns,
                                                                                state: .open, turnsUsed: 12, tokensUsed: 148_000,
                                                                                turnLimit: 12, tokenLimit: 150_000))))
        }
        model.groupSessions[launch.id] = GroupSession(groupID: launch.id, conversation: conversation)
        model.groupSessions[empty.id] = GroupSession(groupID: empty.id)

        let live = model.groupLive(launch.id)
        if working {
            live.update(runState: .running, typing: [research.id, review.id], work: nil, needsYou: false, unread: 0,
                        usage: GroupUsage(turns: 9, turnLimit: 12, tokens: 96_000, tokenLimit: 150_000))
        } else if paused {
            live.update(runState: .paused(.turns), typing: [], work: nil, needsYou: false, unread: 0,
                        usage: GroupUsage(turns: 12, turnLimit: 12, tokens: 148_000, tokenLimit: 150_000))
        } else {
            live.update(runState: .idle, typing: [], work: nil, needsYou: false, unread: 0, usage: nil)
        }
        model.groupLive(revision.id).update(runState: .paused(.turns), typing: [], work: nil, needsYou: true, unread: 2, usage: nil)
        model.groupLive(general.id).update(runState: .idle, typing: [], work: nil, needsYou: false, unread: 3, usage: nil)
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
