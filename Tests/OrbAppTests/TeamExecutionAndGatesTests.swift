import Foundation
import Testing
@testable import Orb

@Suite struct TeamExecutionAndGatesTests {
    private let temp = TempFolder("TeamExecutionAndGates")

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

            case .review, .finalAudit:
                return TeamHub.TurnOutcome(reply: "APPROVED: todos os critérios passaram.", completionWatch: CompletionWatch())

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
            return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
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
            return TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }
        model.startTeam(team.id)
        #expect(model.teamHub.isRunning(team.id))
        model.pauseTeam(team.id)
        await gate.open()
        #expect(!model.teamHub.isRunning(team.id))
        #expect(model.team(team.id)?.status == .paused)

        // Resume to completion.
        model.teamHub.turnExecutor = { _ in
            TeamHub.TurnOutcome(reply: "APPROVED", completionWatch: CompletionWatch())
        }
        model.startTeam(team.id)
        await waitUntil("team completes after resume") {
            model.team(team.id)?.status == .completed
        }
    }
}
