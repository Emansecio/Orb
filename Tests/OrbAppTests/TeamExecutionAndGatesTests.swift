import Foundation
import Testing
@testable import Orb

@Suite struct TeamExecutionAndGatesTests {
    private let temp = TempFolder("TeamExecutionAndGates")
    /// A final audit that verifies the world's single criterion with observed tool provenance.
    static let auditPass = "APPROVED\n1. PASS — swift test: 12 passed"
    static let auditOutcome = TeamHub.TurnOutcome(
        reply: auditPass,
        completionWatch: CompletionWatch(),
        observedTools: [.init(tool: "run_command", input: #"{"command":"swift test"}"#,
                              output: "Test run with 12 tests passed", isError: false)]
    )

    @MainActor private func makeWorld() -> (model: AppModel, team: OrbTeam, lead: TeamMember, builder: TeamMember, reviewer: TeamMember) {
        let store = Store(directory: temp.url)
        let model = AppModel(store: store, runsBackgroundWork: false)
        let lead = TeamMember(name: "Líder", role: "Orquestra")
        let builder = TeamMember(name: "Executor", role: "Implementa")
        let reviewer = TeamMember(name: "Revisor", role: "Audita")
        let stage = MissionStage(title: "Implementar módulo", ownerMemberID: builder.id, reviewerMemberID: reviewer.id)
        let criterion = MissionCriterion(description: "Testes passam")
        let team = OrbTeam(
            name: "Time Perfeccionista",
            idea: "Testar portões",
            permissionMode: .bypass,
            orchestratorID: lead.id,
            members: [lead, builder, reviewer],
            mission: TeamMission(objective: "Entregar com portões", criteria: [criterion], stages: [stage]),
            status: .paused
        )
        let added = model.addTeam(team, select: false)!
        return (model, added, lead, builder, reviewer)
    }

    @Test func gateBlocksSelfReviewAndEditWithoutFreshCheck() {
        var watch = CompletionWatch()
        let testCall = ToolCallRequest(id: "1", name: "run_command", arguments: #"{"command":"swift test"}"#)
        watch.record(testCall, result: CommandOutput.exitLead + "0", failed: false)
        let editCall = ToolCallRequest(id: "2", name: "edit_file", arguments: #"{"path":"Foo.swift"}"#)
        watch.record(editCall, result: "edited", failed: false)

        let owner = UUID(), reviewer = UUID()
        let unverified = TeamQualityGates.evaluateStage(
            ownerID: owner, reviewerID: reviewer, builderReply: "Pronto, concluído!",
            completionWatch: watch, reviewerReply: "APPROVED"
        )
        guard case .rejected(.needsFreshCheck) = unverified else {
            Issue.record("Expected needsFreshCheck, got \(unverified)")
            return
        }

        // Re-running check clears the edit flag, then same-author review is still rejected.
        watch.record(testCall, result: CommandOutput.exitLead + "0", failed: false)
        let selfReview = TeamQualityGates.evaluateStage(
            ownerID: owner, reviewerID: owner, builderReply: "Pronto!",
            completionWatch: watch, reviewerReply: "APPROVED"
        )
        #expect(selfReview == .rejected(.sameAuthorReviewer))

        let approved = TeamQualityGates.evaluateStage(
            ownerID: owner, reviewerID: reviewer, builderReply: "Pronto!",
            completionWatch: watch, reviewerReply: "APPROVED: tudo ok"
        )
        #expect(approved == .approved)
    }

    @Test func stagnationDetectorPivotsEscalatesAndDetectsExternalBlockers() {
        var detector = TeamStagnationDetector()
        let stageID = UUID()

        #expect(detector.recordFailure(stageID: stageID, rawError: "exit 1 in 12 ms") == .none)
        if case .pivotStrategy = detector.recordFailure(stageID: stageID, rawError: "exit 1 in 48 ms") {
            // Expected pivot on second identical normalized failure.
        } else {
            Issue.record("Expected pivotStrategy on repeated failure")
        }
        if case .escalateToLeader(let id, _) = detector.recordFailure(stageID: stageID, rawError: "exit 1 in 99 ms") {
            #expect(id == stageID)
        } else {
            Issue.record("Expected escalateToLeader on third failure after pivot")
        }

        let blocker = detector.recordFailure(stageID: UUID(), rawError: "HTTP 403 login required on provider")
        guard case .pauseFrontForUser(_, let prompt) = blocker else {
            Issue.record("Expected pauseFrontForUser for external login blocker, got \(blocker)")
            return
        }
        #expect(prompt.contains("login"))
    }

    @Test @MainActor func hubEnforcesPostEditGateLoopRecoveryAuditLogAndFinalAudit() async throws {
        let (model, team, _, _, _) = makeWorld()
        var builderAttempts = 0
        var sawPivotDirective = false
        var sawFreshCheckReminder = false

        model.teamHub.turnExecutor = { task in
            switch task.role {
            case .build:
                builderAttempts += 1
                if builderAttempts <= 2 {
                    // Two identical failures trigger pivotStrategy.
                    return TeamHub.TurnOutcome(reply: "", completionWatch: CompletionWatch(),
                                               failedError: "build error code 42 in 10 ms")
                }
                if builderAttempts == 3 {
                    if task.prompt.contains("pare de tentar o mesmo") { sawPivotDirective = true }
                    // Edit without running check afterwards triggers post-edit gate rejection!
                    var watch = CompletionWatch()
                    watch.record(ToolCallRequest(id: "c1", name: "run_command", arguments: #"{"command":"swift test"}"#),
                                 result: CommandOutput.exitLead + "0", failed: false)
                    watch.record(ToolCallRequest(id: "e1", name: "edit_file", arguments: #"{"path":"A.swift"}"#),
                                 result: "ok", failed: false)
                    return TeamHub.TurnOutcome(reply: "Pronto!", completionWatch: watch)
                }
                if task.prompt.contains("run it again") { sawFreshCheckReminder = true }
                var cleanWatch = CompletionWatch()
                cleanWatch.record(ToolCallRequest(id: "c2", name: "run_command", arguments: #"{"command":"swift test"}"#),
                                  result: CommandOutput.exitLead + "0", failed: false)
                return TeamHub.TurnOutcome(reply: "Pronto e testado!", completionWatch: cleanWatch)

            case .review:
                return TeamHub.TurnOutcome(reply: "APPROVED: todos os critérios passaram.", completionWatch: CompletionWatch())
            case .finalAudit:
                return Self.auditOutcome

            case .leaderReplan:
                return TeamHub.TurnOutcome(reply: "Use outra abordagem.", completionWatch: CompletionWatch())
            }
        }

        model.startTeam(team.id)
        await waitUntil("team mission to complete after recovery and gates") {
            model.team(team.id)?.status == .completed
        }

        #expect(sawPivotDirective)
        #expect(sawFreshCheckReminder)
        let updated = try #require(model.team(team.id))
        #expect(updated.mission.stages.allSatisfy { $0.isDone })
        #expect(updated.mission.criteria.allSatisfy { $0.isVerified })

        let auditEntries = TeamAuditLog.readRecent(from: model.store.teamAuditURL(team.id))
        #expect(auditEntries.contains { $0.kind == .loopRecovery })
        #expect(auditEntries.contains { $0.kind == .gateRejected })
        #expect(auditEntries.contains { $0.kind == .completed })
    }

    @Test @MainActor func hubPausesOnExternalBlockerAndSupportsImmediatePauseResume() async throws {
        let (model, team, _, _, _) = makeWorld()
        var blockWithCaptcha = true

        model.teamHub.turnExecutor = { task in
            if task.role == .build && blockWithCaptcha {
                return TeamHub.TurnOutcome(reply: "", completionWatch: CompletionWatch(),
                                           failedError: "CAPTCHA challenge blocking automated fetch")
            }
            return task.role == .finalAudit
                ? Self.auditOutcome
                : TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }

        model.startTeam(team.id)
        await waitUntil("external blocker pauses front as waitingUser") {
            model.team(team.id)?.status == .waitingUser
        }
        #expect(model.team(team.id)?.mission.stages.first?.blockerNote.contains("CAPTCHA") == true)

        // Resuming clears blocker and completes once obstacle is gone; test pause mid-flight too.
        blockWithCaptcha = false
        let gate = TestGate()
        model.teamHub.turnExecutor = { task in
            if task.role == .build { await gate.wait() }
            return task.role == .finalAudit
                ? Self.auditOutcome
                : TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }
        model.startTeam(team.id)
        #expect(model.teamHub.isRunning(team.id))
        model.pauseTeam(team.id)
        await gate.open()
        #expect(!model.teamHub.isRunning(team.id))
        #expect(model.team(team.id)?.status == .paused)

        // Resume to completion.
        model.teamHub.turnExecutor = { task in
            task.role == .finalAudit ? Self.auditOutcome : TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }
        model.startTeam(team.id)
        await waitUntil("team completes after resume") {
            model.team(team.id)?.status == .completed
        }
    }

    @Test func finalAuditVerifiesOnlyCriteriaWithTheirOwnPassLine() {
        let reply = """
        APPROVED
        1. PASS — swift test: 48 passed
        - **2. FAIL**: falta o teste de borda
        [3] PASS
        9. PASS — fora do intervalo
        """
        let verdicts = TeamQualityGates.criterionVerdicts(in: reply, count: 3)
        #expect(verdicts[1] == .init(passed: true, evidence: "swift test: 48 passed"))
        #expect(verdicts[2]?.passed == false)
        #expect(verdicts[3]?.passed == true)
        #expect(verdicts[9] == nil)
        #expect(TeamQualityGates.criterionVerdicts(in: "APPROVED: tudo certo", count: 2).isEmpty)
    }

    @Test func externalBlockersMatchWholeWordsInPortugueseToo() {
        #expect(TeamExternalBlocker.detect(in: "O site pediu autenticação em duas etapas") != nil)
        #expect(TeamExternalBlocker.detect(in: "Falta a chave de API do provedor") != nil)
        #expect(TeamExternalBlocker.detect(in: "commit a2fa91c integrado") == nil)
        #expect(TeamExternalBlocker.detect(in: "recaptchaToken renomeado") == nil)
    }

    @Test func proposalStagesRunInOrder() throws {
        var proposal = TeamProposal()
        proposal.members = [TeamMemberDraft(name: "Líder", isOrchestrator: true), TeamMemberDraft(name: "Executor")]
        proposal.stages = ["Mapear", "Implementar", "Testar"]
        let team = try #require(proposal.buildTeam(idea: "x", scouterModel: "", projectFolder: "", permissionMode: .bypass))
        let stages = team.mission.stages
        #expect(stages[0].dependsOn.isEmpty)
        #expect(stages[1].dependsOn == [stages[0].id])
        #expect(stages[2].dependsOn == [stages[1].id])
    }

    @Test @MainActor func readyStagesNeverGiveOneMemberTwoStagesAtOnce() {
        let (model, team, lead, builder, reviewer) = makeWorld()
        var copy = team
        copy.mission.stages = [
            MissionStage(title: "A", ownerMemberID: builder.id, reviewerMemberID: reviewer.id),
            MissionStage(title: "B", ownerMemberID: builder.id, reviewerMemberID: reviewer.id),
            MissionStage(title: "C", ownerMemberID: lead.id, reviewerMemberID: reviewer.id),
        ]
        let ready = model.teamHub.nextReadyStages(in: copy).map(\.title)
        #expect(ready == ["A", "C"])
    }

    @Test @MainActor func bareApprovedAuditReopensWorkInsteadOfVerifyingEverything() async throws {
        let (model, team, _, _, _) = makeWorld()
        var audits = 0
        var correctiveSawFindings = false
        model.teamHub.turnExecutor = { task in
            switch task.role {
            case .finalAudit:
                audits += 1
                return audits == 1
                    ? TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
                    : Self.auditOutcome
            case .build:
                if task.prompt.contains("final audit found") { correctiveSawFindings = true }
                return TeamHub.TurnOutcome(reply: "Pronto", completionWatch: CompletionWatch())
            default:
                return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
            }
        }
        model.startTeam(team.id)
        await waitUntil("team completes after the corrective stage") { model.team(team.id)?.status == .completed }
        let updated = try #require(model.team(team.id))
        #expect(audits == 2)
        #expect(correctiveSawFindings)
        #expect(updated.mission.stages.contains { $0.title == TeamHub.correctiveStageTitle && $0.isDone })
        #expect(updated.mission.criteria.allSatisfy { $0.isVerified && $0.lastEvidence.contains("swift test") })
    }

    @Test @MainActor func personMessageReachesTheTurnsOfARunningTeam() async throws {
        let (model, team, _, _, _) = makeWorld()
        let gate = TestGate()
        var reviewPrompt = ""
        model.teamHub.turnExecutor = { task in
            switch task.role {
            case .build:
                await gate.wait()
                return TeamHub.TurnOutcome(reply: "Pronto", completionWatch: CompletionWatch())
            case .review:
                reviewPrompt = task.prompt
                return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
            default:
                return Self.auditOutcome
            }
        }
        model.startTeam(team.id)
        #expect(model.postTeamMessage("Use apenas a API pública", to: team.id))
        await gate.open()
        await waitUntil("team completes") { model.team(team.id)?.status == .completed }
        #expect(reviewPrompt.contains("Use apenas a API pública"))
    }

    @Test @MainActor func stoppingForThePersonSaysWhyInTheThread() async throws {
        let (model, team, _, _, _) = makeWorld()
        model.teamHub.turnExecutor = { task in
            if task.role == .build {
                return TeamHub.TurnOutcome(reply: "", completionWatch: CompletionWatch(), failedError: "login required by provider")
            }
            return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }
        model.startTeam(team.id)
        await waitUntil("team waits for the person") { model.team(team.id)?.status == .waitingUser }
        let notices = model.teamThreadItems(for: team.id).compactMap { item -> String? in
            if case .notice(let text) = item.kind { return text }
            return nil
        }
        #expect(notices.contains { $0.contains("precisa de você") && $0.contains("login") })
    }

    @Test @MainActor func teamNoteContractWritesToBoardAndAskMemberRespectsLimit() async throws {
        let (model, team, _, builder, _) = makeWorld()
        let workspace = WorkFolder(url: model.store.directory)
        let task = TeamHub.TurnTask(
            teamID: team.id, runID: UUID(), stageID: team.mission.stages.first?.id,
            member: builder, role: .build, prompt: "build", boardBrief: "",
            workspace: workspace, permissionMode: .bypass
        )
        let counter = TeamHub.ConsultCounter(limit: 1)
        let contractOut = try await model.teamHub.handleTeamNote(
            .object(["action": .string("contract"), "title": .string("API Auth"), "summary": .string("Usa header X-Token")]),
            task: task, consultCounter: counter
        )
        #expect(contractOut.contains("API Auth"))
        let brief = await TeamBoard.brief(bank: model.memory.teamBank(for: team.id), team: team, message: "auth")
        #expect(brief.contains("API Auth") && brief.contains("Usa header X-Token"))

        // Exhaust the 1-slot consult counter and verify a second consult is refused cleanly.
        #expect(counter.takeSlot())
        await #expect(throws: ToolError.self) {
            _ = try await model.teamHub.handleTeamNote(
                .object(["action": .string("ask_member"), "to": .string("Revisor"), "question": .string("Qual contrato?")]),
                task: task, consultCounter: counter
            )
        }
    }

    @Test @MainActor func longBuilderSummarySpillsToTeamFolderForReviewer() throws {
        let (model, team, _, _, _) = makeWorld()
        let stage = try #require(team.mission.stages.first)
        let huge = String(repeating: "detalhe de build\n", count: 250)
        let path = try #require(model.teamHub.spillReviewSummaryIfNeeded(huge, teamID: team.id, stageID: stage.id))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == huge)
        let prompt = model.teamHub.buildReviewPrompt(
            stage: stage, builderName: "Executor", builderSummary: huge,
            summaryPath: path, criteria: team.mission.criteria, directions: []
        )
        #expect(prompt.contains(path))
        #expect(prompt.contains("read_file"))
    }

    @Test @MainActor func finalAuditProvenanceRejectsHallucinatedPassAndAcceptsObservedOutput() async throws {
        let observed = [
            TeamQualityGates.ObservedTool(tool: "run_command", input: #"{"command":"swift test"}"#,
                                          output: "Test run with 48 tests passed", isError: false),
            TeamQualityGates.ObservedTool(tool: "run_command", input: #"{"command":"npm test"}"#,
                                          output: "Error: 3 failed", isError: true),
        ]
        #expect(TeamQualityGates.hasProvenance(evidence: "swift test: 48 passed", in: observed))
        #expect(!TeamQualityGates.hasProvenance(evidence: "swift test: 99 passed", in: observed)) // fabricated test count
        #expect(!TeamQualityGates.hasProvenance(evidence: "swift test: 4 passed", in: observed)) // "4" must not match inside "48"
        #expect(!TeamQualityGates.hasProvenance(evidence: "", in: observed))
        #expect(!TeamQualityGates.hasProvenance(evidence: "swift test: 48 passed", in: []))
        #expect(!TeamQualityGates.hasProvenance(evidence: "pytest: 99 passed", in: observed))
        // Failed tool outputs cannot prove a PASS criterion.
        #expect(!TeamQualityGates.hasProvenance(evidence: "npm test: 3 failed", in: observed))

        // End-to-end: a final audit claiming PASS with zero observed tools is blocked and reopens work.
        let (model, team, _, _, _) = makeWorld()
        var audits = 0
        model.teamHub.turnExecutor = { task in
            switch task.role {
            case .finalAudit:
                audits += 1
                if audits == 1 {
                    return TeamHub.TurnOutcome(reply: Self.auditPass, completionWatch: CompletionWatch(), observedTools: [])
                }
                return Self.auditOutcome
            case .build:
                return TeamHub.TurnOutcome(reply: "Pronto", completionWatch: CompletionWatch())
            default:
                return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
            }
        }
        model.startTeam(team.id)
        await waitUntil("team completes only after observed provenance") { model.team(team.id)?.status == .completed }
        #expect(audits == 2)
        let auditEntries = TeamAuditLog.readRecent(from: model.store.teamAuditURL(team.id))
        #expect(auditEntries.contains { $0.summary.contains("sem comprovação") })
    }

    @Test @MainActor func liveSteeringPushesImmediatelyToActiveTurnQueues() {
        let (model, team, _, _, _) = makeWorld()
        let queueA = SteeringQueue()
        let queueB = SteeringQueue()
        let idA = model.teamHub.registerSteering(queueA, for: team.id)
        let idB = model.teamHub.registerSteering(queueB, for: team.id)

        model.teamHub.steer(team.id, message: "Não altere a API pública")
        #expect(queueA.drainSteering().map(\.text) == ["Não altere a API pública"])
        #expect(queueB.drainSteering().map(\.text) == ["Não altere a API pública"])

        model.teamHub.unregisterSteering(idA, for: team.id)
        model.teamHub.unregisterSteering(idB, for: team.id)
        model.teamHub.steer(team.id, message: "Depois do fim")
        #expect(queueA.isEmpty && queueB.isEmpty)
    }

    @Test @MainActor func missionConstraintsAndContractSupersedesAndStaleness() async throws {
        var proposal = TeamProposal()
        proposal.members = [TeamMemberDraft(name: "Líder", isOrchestrator: true), TeamMemberDraft(name: "Executor")]
        let changed = proposal.apply(.object([
            "constraints": .array([.string("Sem dependências externas"), .string("Manter macOS 14")]),
            "stages": .array([.string("Construir")]),
        ]))
        #expect(changed.contains(.constraints))
        let team = try #require(proposal.buildTeam(idea: "x", scouterModel: "", projectFolder: "", permissionMode: .bypass))
        #expect(team.mission.constraints == ["Sem dependências externas", "Manter macOS 14"])

        // Tolerant decoding for legacy TeamMission JSON without `constraints`.
        let legacyJSON = Data(#"{"objective":"Legado","criteria":[],"stages":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(TeamMission.self, from: legacyJSON)
        #expect(decoded.constraints.isEmpty)

        let bank = MemoryBank(directory: temp.url.appending(path: "board-constraints"))
        await TeamBoard.recordContract(
            title: "Auth v1", summary: "Header X-Old", author: "Executor",
            files: ["Sources/Auth.swift"], to: bank
        )
        await TeamBoard.recordContract(
            title: "Auth v2", summary: "Header X-Token", author: "Executor",
            supersedes: ["auth v1"], files: ["Sources/Auth.swift"], to: bank
        )
        await TeamBoard.markStaleContracts(touching: ["Sources/Auth.swift"], commit: "abc1234", to: bank)
        // Re-running with the same commit does not duplicate the stale tag.
        await TeamBoard.markStaleContracts(touching: ["Sources/Auth.swift"], commit: "abc1234", to: bank)

        let brief = await TeamBoard.brief(bank: bank, team: team, message: "auth")
        #expect(brief.contains("Sem dependências externas"))
        #expect(!brief.contains("Auth v1"))
        #expect(brief.contains("Auth v2"))
        #expect(brief.contains("[revisar após abc1234]"))
        #expect(!brief.contains("[revisar após abc1234] [revisar após abc1234]"))
    }
}
