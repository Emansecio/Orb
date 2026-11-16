#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `--snapshot` scenarios for the `Times` wing and Team views: `teams-sidebar`, `team-detail`, `team-member`,
/// `team-new-empty`, `team-new-proposal`.
@MainActor
enum TeamSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        let modes: Set<String> = ["teams-sidebar", "team-detail", "team-member", "team-panel", "team-new-empty", "team-new-proposal"]
        guard modes.contains(screen) else { return nil }
        let sample = SampleTeams(model: model)
        switch screen {
        case "teams-sidebar":
            model.selection = .teamMember(teamID: sample.running.id, memberID: sample.executor.id)
            return AnyView(SidebarView().frame(width: Snapshot.paneWidth(280)))
        case "team-detail":
            model.selection = .team(sample.running.id)
            model.teamThreads[sample.running.id] = [
                TranscriptItem(.notice("Time em execução contínua.")),
                TranscriptItem(.bot(text: "**Etapa concluída:** Definir modelos tolerantes e persistência isolada (revisão aprovada por Revisor QA)", isStreaming: false)),
            ]
            return AnyView(TeamChatView(teamID: sample.running.id))
        case "team-member":
            model.selection = .teamMember(teamID: sample.running.id, memberID: sample.executor.id)
            return AnyView(TeamMemberChatView(teamID: sample.running.id, memberID: sample.executor.id))
        case "team-panel":
            model.selection = .team(sample.running.id)
            return AnyView(TeamPanel(teamID: sample.running.id).frame(width: 320, height: 700))
        case "team-new-empty":
            let emptyRunner = TeamScouterRunner(messages: [TranscriptItem(.bot(text: TeamScouterPrompt.firstLine, isStreaming: false))],
                                                proposal: TeamProposal())
            emptyRunner.attach(model)
            return AnyView(NewTeamSheet(runner: emptyRunner))
        case "team-new-proposal":
            let runner = SampleTeams.proposalRunner(model: model)
            return AnyView(NewTeamSheet(runner: runner))
        default:
            return nil
        }
    }
}

@MainActor
private struct SampleTeams {
    let running: OrbTeam
    let completed: OrbTeam
    let executor: TeamMember

    init(model: AppModel) {
        let atlas = Bot(name: "Atlas", role: "Assistente do seu Mac", orb: WelcomeLooks.atlas)
        let lia = Bot(name: "Lia", role: "Cuida de e-mails", orb: WelcomeLooks.lia)
        model.bots = [atlas, lia]
        model.groups = [OrbGroup(name: "Lançamento", memberIDs: [atlas.id, lia.id], orchestratorID: atlas.id)]

        let leader = TeamMember(name: "Arquiteto", role: "Coordena contratos e entregas",
                                orb: OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso"), state: .working)
        let builder = TeamMember(name: "Executor Swift", role: "Implementa e escreve testes",
                                 orb: OrbConfig(color: "menta", eyes: "pontos", mouth: "sorrisao"),
                                 model: "openai/gpt-5", state: .working)
        let reviewer = TeamMember(name: "Revisor QA", role: "Valida critérios e regressões",
                                  orb: OrbConfig(color: "sol", eyes: "ovais", brows: "retas"), state: .reviewing)
        executor = builder

        let stage1 = MissionStage(title: "Definir modelos tolerantes e persistência isolada",
                                  ownerMemberID: leader.id, reviewerMemberID: reviewer.id, isDone: true)
        let stage2 = MissionStage(title: "Implementar ala Times na lateral com expansão",
                                  ownerMemberID: builder.id, reviewerMemberID: reviewer.id, isDone: false)
        let stage3 = MissionStage(title: "Auditoria final integrada em 460 e 1100 pt",
                                  ownerMemberID: reviewer.id, reviewerMemberID: leader.id, isDone: false)

        let crit1 = MissionCriterion(description: "Decodificação tolerante mantém compatibilidade entre versões",
                                     verification: "swift test --filter TeamModelTests",
                                     isVerified: true, lastEvidence: "swift test: 14 testes aprovados")
        let crit2 = MissionCriterion(description: "Ala Times isolada sem vazar integrantes em Orbs",
                                     verification: "swift test --filter TeamSidebarTests",
                                     isVerified: false)

        running = OrbTeam(
            name: "Auditoria de UX",
            idea: "Revisar e unificar animações e arquitetura da barra lateral.",
            scouterModel: "anthropic/claude-sonnet-4-5",
            projectFolder: "/Users/thiagomacbookpro/Orb",
            permissionMode: .bypass,
            orchestratorID: leader.id,
            members: [leader, builder, reviewer],
            mission: TeamMission(objective: "Entregar revisão completa da interface com testes e snapshots aprovados.",
                                 criteria: [crit1, crit2],
                                 stages: [stage1, stage2, stage3]),
            status: .running,
            unread: 0
        )

        let analyst = TeamMember(name: "Pesquisadora", role: "Mapeamento de fontes",
                                 orb: OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso"), state: .done)
        let auditor = TeamMember(name: "Auditora", role: "Checagem de consistência",
                                 orb: OrbConfig(color: "grafite", eyes: "pilulas", mouth: "sorriso"), state: .done)
        completed = OrbTeam(
            name: "Pesquisa de mercado",
            idea: "Comparar planos e limites dos provedores.",
            projectFolder: "",
            permissionMode: .bypass,
            orchestratorID: analyst.id,
            members: [analyst, auditor],
            mission: TeamMission(objective: "Relatório comparativo verificado.",
                                 criteria: [MissionCriterion(description: "Fontes citadas com data", isVerified: true)],
                                 stages: [MissionStage(title: "Coleta e síntese", ownerMemberID: analyst.id,
                                                       reviewerMemberID: auditor.id, isDone: true)]),
            status: .completed
        )

        model.teams = [running, completed]
        model.expandedTeamIDs = [running.id]
    }

    static func proposalRunner(model: AppModel) -> TeamScouterRunner {
        let messages = [
            TranscriptItem(.bot(text: TeamScouterPrompt.firstLine, isStreaming: false)),
            TranscriptItem(.user(text: "Quero um time perfeccionista para auditar e refatorar a barra lateral com testes e capturas.", attachments: [])),
            TranscriptItem(.bot(text: "Dei uma espiada no projeto: já temos a lateral, as animações e a suíte de testes pronta. Escalei um quarteto afiado com revisor independente para nada passar batido!", isStreaming: false)),
        ]
        var proposal = TeamProposal(
            teamName: "Auditoria da barra lateral",
            objective: "Auditar espaçamento, acessibilidade e fluidez de animações com cobertura completa de testes.",
            analysisSummary: "Projeto organizado com a interface da lateral, sistema de movimento e suíte de testes automatizados.",
            scoutNote: "Time compacto de 4 integrantes: líder coordena contratos, dois executam em paralelo e o revisor audita cada critério.",
            criteria: [
                "Todos os testes da lateral passando sem regressões",
                "Conferência visual aprovada nas larguras estreita e ampla",
            ],
            stages: [
                "Mapear espaçamento e pontos de animação",
                "Aplicar correções e escrever testes de regressão",
                "Auditoria visual final",
            ],
            members: [
                TeamMemberDraft(name: "Maestro", role: "Coordena contratos e integração",
                                orb: TeamMemberDraft.preset(at: 0), isOrchestrator: true),
                TeamMemberDraft(name: "Artesã SwiftUI", role: "Polimento visual e animações",
                                orb: TeamMemberDraft.preset(at: 1)),
                TeamMemberDraft(name: "Guardião de Testes", role: "Testes unitários e casos de borda",
                                orb: TeamMemberDraft.preset(at: 2)),
                TeamMemberDraft(name: "Revisor Sênior", role: "Auditoria independente de critérios",
                                orb: TeamMemberDraft.preset(at: 3)),
            ],
            ready: true
        )
        proposal.ready = true
        let runner = TeamScouterRunner(
            messages: messages,
            proposal: proposal,
            projectFolder: "/Users/thiagomacbookpro/Orb"
        )
        runner.attach(model)
        return runner
    }
}
#endif
