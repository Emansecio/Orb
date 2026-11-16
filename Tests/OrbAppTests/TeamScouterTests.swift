import Foundation
import Testing
@testable import Orb

private func scoutReply(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func scoutProposalCall(_ json: String) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: UUID().uuidString, name: TeamProposalTool.name, arguments: json)]),
     .finished(.toolUse, nil)]
}

@Suite struct TeamScouterTests {
    private let temp = TempFolder("TeamScouterTests")

    @MainActor private func makeModel(script: CallScript? = nil) -> AppModel {
        let store = Store(directory: temp.url)
        var state = AppState.initial
        let account = ProviderAccount(kind: .custom)
        state.providers = [account]
        state.defaultModel = "custom/modelo"
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [account]
        model.defaultModel = "custom/modelo"
        if let script { model.clientOverride = { CallScriptModel(script: script) } }
        return model
    }

    @Test func proposalAppliesUpdatesPreservesMatchingIDsAndValidatesBounds() throws {
        var proposal = TeamProposal()
        let changed = proposal.apply(.object([
            "name": .string("Auditoria da lateral"),
            "objective": .string("Auditar layout e testes"),
            "analysis_summary": .string("Pacote SwiftPM com SidebarView."),
            "scout_note": .string("Escalei 3 especialistas afiados."),
            "criteria": .array([.string("Testes passam"), .string("Snapshots OK")]),
            "stages": .array([.string("Mapeamento"), .string("Correção e revisão")]),
            "members": .array([
                .object(["name": .string("Maestro"), "role": .string("Líder"), "color": .string("indigo"), "is_orchestrator": .bool(true)]),
                .object(["name": .string("Executor"), "role": .string("Implementa"), "color": .string("invalid_color")]),
                .object(["name": .string("Revisor"), "role": .string("Audita"), "color": .string("sol")]),
            ]),
        ]))
        #expect(changed.contains(.teamName))
        #expect(changed.contains(.members))
        #expect(proposal.canCreate)
        #expect(proposal.ready)
        #expect(proposal.members[1].orb.color == TeamMemberDraft.preset(at: 1).color)
        let executorID = proposal.members[1].id

        // Refinement preserves ID of kept members when updating roles.
        _ = proposal.apply(.object([
            "members": .array([
                .object(["name": .string("Maestro"), "role": .string("Líder")]),
                .object(["name": .string("Executor"), "role": .string("Implementa e testa")]),
            ]),
        ]))
        #expect(proposal.members.count == 2)
        #expect(proposal.members[1].id == executorID)
        #expect(proposal.members[0].isOrchestrator)

        let built = try #require(proposal.buildTeam(idea: "Auditar", scouterModel: "custom/modelo",
                                                   projectFolder: "/tmp/proj", permissionMode: .bypass))
        #expect(built.mission.stages.count == 2)
        #expect(built.mission.stages[0].ownerMemberID != built.mission.stages[0].reviewerMemberID)
        #expect(built.permissionMode == .bypass)
    }

    @Test func proposalRejectsDuplicatesAndLessThanTwoMembers() {
        var proposal = TeamProposal(
            teamName: "Curto",
            members: [TeamMemberDraft(name: "Líder"), TeamMemberDraft(name: "líder")]
        )
        #expect(proposal.hasDuplicateNames)
        #expect(!proposal.canCreate)

        proposal.members = [TeamMemberDraft(name: "Sozinho")]
        #expect(!proposal.hasDuplicateNames)
        #expect(!proposal.canCreate)
    }

    @MainActor @Test func scouterChatsRefinesBlueprintRemembersModelAndCreatesTeam() async throws {
        let initialJSON = #"""
        {
          "name": "Caça-bugs UI",
          "objective": "Encontrar e corrigir falhas visuais.",
          "scout_note": "Escalei um trio cirúrgico.",
          "criteria": ["Snapshots em 460 e 1100 pt aprovados"],
          "stages": ["Auditoria", "Correções"],
          "members": [
            {"name": "Líder", "role": "Coordena frentes", "color": "indigo", "is_orchestrator": true},
            {"name": "Executor", "role": "Corrige UI", "color": "menta"},
            {"name": "Revisor", "role": "Audita tudo", "color": "sol"}
          ]
        }
        """#
        let refinedJSON = #"""
        {
          "name": "Caça-bugs UI",
          "members": [
            {"name": "Líder", "role": "Coordena frentes", "color": "indigo", "is_orchestrator": true},
            {"name": "Revisor Sênior", "role": "Auditoria perfeccionista", "color": "rosa"}
          ]
        }
        """#
        let script = CallScript([
            scoutProposalCall(initialJSON),
            scoutReply("Time de 3 montado! Quer ajustar alguém?"),
            scoutProposalCall(refinedJSON),
            scoutReply("Pronto, enxuguei para uma dupla focada!"),
        ])
        let model = makeModel(script: script)
        model.lastScouterModel = ""
        let runner = TeamScouterRunner(model: model)
        runner.scouterModel = "custom/modelo"
        #expect(model.lastScouterModel == "custom/modelo")

        #expect(runner.send("Monte um time para caçar bugs na interface"))
        await waitUntil("first scout proposal to settle") { !runner.isThinking && runner.liveText.isEmpty }
        #expect(runner.proposal.members.count == 3)
        #expect(runner.offersRefinements)

        #expect(runner.send("Enxugue para 2 deixando o Revisor Sênior"))
        await waitUntil("refined scout proposal to settle") { !runner.isThinking && runner.liveText.isEmpty }
        #expect(runner.proposal.members.count == 2)
        #expect(runner.proposal.members[1].name == "Revisor Sênior")

        runner.cycleMemberOrb(runner.proposal.members[1].id)
        #expect(runner.proposal.members[1].orb.color != "rosa")

        let created = try #require(runner.createTeam())
        #expect(model.teams.count == 1)
        #expect(model.selection == .team(created.id))
        #expect(runner.isFinished)
    }

    @MainActor @Test func scouterReadsProjectFolderWhenProvidedAndDirectEditsRespectLimits() async throws {
        let projectDir = temp.url.appending(path: "SampleRepo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("# SampleRepo\n".utf8).write(to: projectDir.appending(path: "README.md"))

        let listArgs = #"{"path": "."}"#
        let proposalJSON = #"""
        {
          "name": "Time SampleRepo",
          "objective": "Cobrir o repo com testes.",
          "analysis_summary": "Encontrei README.md na raiz.",
          "members": [
            {"name": "Arquiteto", "role": "Planeja", "is_orchestrator": true},
            {"name": "Auditor", "role": "Revisa"}
          ]
        }
        """#
        let script = CallScript([
            [.toolCalls([ToolCallRequest(id: "t1", name: "list_directory", arguments: listArgs)]), .finished(.toolUse, nil)],
            scoutProposalCall(proposalJSON),
            scoutReply("Li o repositório e montei a dupla."),
        ])
        let model = makeModel(script: script)
        let runner = TeamScouterRunner(model: model)
        runner.projectFolder = projectDir.path
        runner.scouterModel = "custom/modelo"

        #expect(runner.send("Analise o repo e escale o time"))
        await waitUntil("folder-aware scout to finish") { !runner.isThinking && runner.liveText.isEmpty }
        #expect(runner.proposal.analysisSummary.contains("README.md"))

        // Direct edits respect maxMembers & orchestrator invariant.
        while runner.proposal.members.count < OrbTeam.maxMembers {
            runner.addMemberDraft()
        }
        #expect(runner.proposal.members.count == OrbTeam.maxMembers)
        runner.addMemberDraft()
        #expect(runner.proposal.members.count == OrbTeam.maxMembers)

        let secondID = runner.proposal.members[1].id
        runner.setOrchestratorDraft(secondID)
        #expect(runner.proposal.members[1].isOrchestrator)
        #expect(!runner.proposal.members[0].isOrchestrator)
    }
}
