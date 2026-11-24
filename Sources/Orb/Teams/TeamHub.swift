import Foundation
import Observation

/// Continuous background orchestrator for autonomous Teams (`Times`), enforcing quality gates (`TeamQualityGates`),
/// autonomous loop recovery (`TeamStagnationDetector`), `WorkJournal` tracking, and `audit.jsonl` logging.
@MainActor
@Observable
final class TeamHub {
    struct TurnTask: Sendable {
        enum Role: String, Sendable {
            case build, review, finalAudit, leaderReplan
        }

        var teamID: UUID
        var runID: UUID
        var stageID: UUID?
        var member: TeamMember
        var role: Role
        var prompt: String
        var boardBrief: String
        var workspace: WorkFolder
        var permissionMode: PermissionMode
    }

    struct TurnOutcome: Sendable {
        var reply: String
        var completionWatch: CompletionWatch
        var failedError: String?
        var usage: UsageTotals = UsageTotals()
    }

    typealias TurnExecutor = @MainActor (TurnTask) async -> TurnOutcome

    private(set) var activeRunIDs: [UUID: UUID] = [:]
    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runStarts: [UUID: Date] = [:]
    @ObservationIgnored private var extraDirectives: [UUID: String] = [:]
    @ObservationIgnored private var stagnations: [UUID: TeamStagnationDetector] = [:]
    @ObservationIgnored var turnExecutor: TurnExecutor?

    init(model: AppModel) {
        self.model = model
    }

    func isRunning(_ teamID: UUID) -> Bool { activeRunIDs[teamID] != nil }

    /// Starts or resumes continuous autonomous execution for `teamID`.
    func start(_ teamID: UUID) {
        guard let model, let index = model.teams.firstIndex(where: { $0.id == teamID }),
              !isRunning(teamID) else { return }
        let runID = UUID()
        activeRunIDs[teamID] = runID
        runStarts[teamID] = .now

        model.teams[index].status = .running
        model.teams[index].updatedAt = .now
        for m in model.teams[index].members.indices {
            model.teams[index].members[m].state = .idle
        }
        // Clear previous blocker notes when explicitly resumed by the user.
        for s in model.teams[index].mission.stages.indices {
            model.teams[index].mission.stages[s].blockerNote = ""
        }

        let team = model.teams[index]
        syncWorkJournal()
        model.appendTeamThreadItem(TranscriptItem(.notice("Time em execução contínua.")), to: teamID)
        appendAudit(teamID: team.id, member: team.orchestrator, kind: .resumed,
                    summary: "Execução contínua iniciada (\(team.mission.stages.count) etapas)")

        runTasks[teamID] = Task { [weak self] in
            await self?.runLoop(teamID: teamID, runID: runID)
        }
    }

    /// Immediately pauses continuous execution and cancels any in-flight tasks for `teamID`.
    func pause(_ teamID: UUID) {
        runTasks[teamID]?.cancel()
        runTasks[teamID] = nil
        activeRunIDs[teamID] = nil
        runStarts[teamID] = nil
        stagnations[teamID] = nil
        model?.workJournal.dropTeamRun(teamID)

        guard let model, let index = model.teams.firstIndex(where: { $0.id == teamID }) else { return }
        if model.teams[index].status == .running || model.teams[index].status == .preparing {
            model.teams[index].status = .paused
        }
        model.teams[index].updatedAt = .now
        for m in model.teams[index].members.indices where model.teams[index].members[m].state != .done {
            model.teams[index].members[m].state = .idle
        }
        model.appendTeamThreadItem(TranscriptItem(.notice("Execução pausada.")), to: teamID)
        appendAudit(teamID: teamID, member: model.teams[index].orchestrator, kind: .paused,
                    summary: "Execução pausada pelo usuário")
    }

    func stopAll() {
        for id in Array(runTasks.keys) { pause(id) }
    }

    // MARK: Continuous loop

    private static let maxNoProgressRounds = 6

    private func runLoop(teamID: UUID, runID: UUID) async {
        stagnations[teamID] = TeamStagnationDetector()
        var lastCompletedOwnerID: UUID?
        var noProgressRounds = 0

        while !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID), let team = model?.team(teamID), team.status == .running {
            let readyStages = nextReadyStages(in: team)
            if readyStages.isEmpty {
                let anyOpen = team.mission.stages.contains { !$0.isDone }
                if !anyOpen {
                    let completed = await attemptFinalAudit(teamID: teamID, runID: runID, lastOwnerID: lastCompletedOwnerID)
                    if completed {
                        finishRun(teamID: teamID, status: .completed)
                        return
                    }
                    noProgressRounds += 1
                    if noProgressRounds >= Self.maxNoProgressRounds {
                        finishRun(teamID: teamID, status: .waitingUser)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(min(4_000, 500 * noProgressRounds)))
                    continue
                }
                // All remaining open stages are waiting on external blockers (`blockerNote`).
                finishRun(teamID: teamID, status: .waitingUser)
                return
            }

            // Execute independent ready fronts concurrently.
            let stageTasks = readyStages.map { stage in
                (stage.id, Task { @MainActor [weak self] in
                    guard let self else { return false }
                    return await self.processStage(teamID: teamID, runID: runID, stage: stage)
                })
            }
            var results: [(UUID, Bool)] = []
            for (stageID, task) in stageTasks {
                let ok = await task.value
                results.append((stageID, ok))
            }
            if let doneStage = results.first(where: { $0.1 })?.0,
               let latest = model?.team(teamID)?.mission.stages.first(where: { $0.id == doneStage }) {
                lastCompletedOwnerID = latest.ownerMemberID
                noProgressRounds = 0
            } else {
                noProgressRounds += 1
                if noProgressRounds >= Self.maxNoProgressRounds {
                    finishRun(teamID: teamID, status: .waitingUser)
                    return
                }
                try? await Task.sleep(for: .milliseconds(min(4_000, 500 * noProgressRounds)))
            }
        }
    }

    private func nextReadyStages(in team: OrbTeam) -> [MissionStage] {
        let doneIDs = Set(team.mission.stages.filter(\.isDone).map(\.id))
        return team.mission.stages.filter { stage in
            !stage.isDone && stage.blockerNote.isEmpty && stage.dependsOn.allSatisfy { doneIDs.contains($0) }
        }
    }

    private func processStage(teamID: UUID, runID: UUID, stage: MissionStage) async -> Bool {
        guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID),
              let model, let team = model.team(teamID),
              let owner = resolveOwner(for: stage, in: team) else { return false }

        let reviewer = resolveIndependentReviewer(for: stage, ownerID: owner.id, in: team)
        let bank = model.memory.teamBank(for: teamID)
        setMemberState(teamID: teamID, memberID: owner.id, state: .working)

        let workspace = await TeamWorkspaces.prepareMemberFolder(
            team: team, member: owner, runID: runID, dataFolder: model.store.directory
        )
        let brief = await TeamBoard.brief(bank: bank, team: team, message: stage.title)
        let directive = extraDirectives.removeValue(forKey: stage.id)
        let builderPrompt = buildStagePrompt(stage: stage, directive: directive)

        let buildOutcome = await executeTurn(TurnTask(
            teamID: teamID, runID: runID, stageID: stage.id, member: owner, role: .build,
            prompt: builderPrompt, boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))

        guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return false }
        appendAudit(teamID: teamID, member: owner, kind: .command,
                    summary: "Etapa “\(stage.title)” executada",
                    detail: String((buildOutcome.failedError ?? buildOutcome.reply).prefix(200)))

        if let err = buildOutcome.failedError, !err.isEmpty {
            await handleRecovery(teamID: teamID, runID: runID, stage: stage, rawError: err,
                                 workspace: workspace, bank: bank)
            setMemberState(teamID: teamID, memberID: owner.id, state: .idle)
            return false
        }

        // Gate 1: programmatic check-after-edit validation (`CompletionWatch`).
        if let reminder = buildOutcome.completionWatch.reminder(for: buildOutcome.reply) {
            appendAudit(teamID: teamID, member: owner, kind: .gateRejected,
                        summary: "Portão pós-edição bloqueou etapa “\(stage.title)”", detail: reminder)
            extraDirectives[stage.id] = reminder
            let recovery = stagnations[teamID, default: TeamStagnationDetector()].recordFailure(stageID: stage.id, rawError: reminder)
            if case .escalateToLeader(let id, let reason) = recovery {
                await escalateToLeader(teamID: teamID, runID: runID, stageID: id, reason: reason,
                                       workspace: workspace, bank: bank)
            }
            setMemberState(teamID: teamID, memberID: owner.id, state: .idle)
            return false
        }

        // Gate 2: independent reviewer != owner.
        guard let reviewer else {
            appendAudit(teamID: teamID, member: owner, kind: .gateRejected,
                        summary: "Etapa “\(stage.title)” exige revisor distinto do autor")
            setStageBlocker(teamID: teamID, stageID: stage.id, note: "Time precisa de ao menos 2 integrantes para revisão independente.")
            return false
        }

        setMemberState(teamID: teamID, memberID: owner.id, state: .idle)
        setMemberState(teamID: teamID, memberID: reviewer.id, state: .reviewing)
        let reviewPrompt = buildReviewPrompt(stage: stage, builderName: owner.name, builderSummary: buildOutcome.reply,
                                             criteria: team.mission.criteria)
        let reviewOutcome = await executeTurn(TurnTask(
            teamID: teamID, runID: runID, stageID: stage.id, member: reviewer, role: .review,
            prompt: reviewPrompt, boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))
        guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return false }

        let gate = TeamQualityGates.evaluateStage(
            ownerID: owner.id,
            reviewerID: reviewer.id,
            builderReply: buildOutcome.reply,
            completionWatch: buildOutcome.completionWatch,
            reviewerReply: reviewOutcome.reply
        )

        switch gate {
        case .approved:
            if let branch = workspace.branch, !team.projectFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let project = URL(fileURLWithPath: team.projectFolder, isDirectory: true)
                let mergeOutcome = await TeamWorkspaces.integrateBranch(
                    branch, into: project, stageTitle: stage.title, team: team,
                    board: bank, runID: runID, dataFolder: model.store.directory
                )
                switch mergeOutcome {
                case .integrated(let commit, _):
                    appendAudit(teamID: teamID, member: team.orchestrator, kind: .merge,
                                summary: "Ramo \(branch) integrado", commit: commit)
                case .conflict(let detail), .postMergeFailed(_, _, let detail), .unavailable(let detail):
                    appendAudit(teamID: teamID, member: team.orchestrator, kind: .gateRejected,
                                summary: "Integração de “\(stage.title)” falhou", detail: detail)
                    extraDirectives[stage.id] = "Resolva o problema de integração antes de concluir: \(detail)"
                    setMemberState(teamID: teamID, memberID: reviewer.id, state: .idle)
                    return false
                }
            }
            markStageDone(teamID: teamID, stageID: stage.id, reviewerID: reviewer.id)
            stagnations[teamID]?.clearStage(stage.id)
            setMemberState(teamID: teamID, memberID: reviewer.id, state: .done)
            model.appendTeamThreadItem(
                TranscriptItem(.bot(text: "**Etapa concluída:** \(stage.title) (revisão aprovada por \(reviewer.name))", isStreaming: false)),
                to: teamID
            )
            appendAudit(teamID: teamID, member: reviewer, kind: .review,
                        summary: "Etapa “\(stage.title)” aprovada por \(reviewer.name)")
            await TeamBoard.recordVerification(stageTitle: stage.title, command: "revisão independente", passed: true,
                                               summary: "Aprovada por \(reviewer.name)", to: bank)
            if let latest = model.team(teamID) { await TeamBoard.syncMission(latest, to: bank) }
            return true

        case .rejected(let rejection):
            setMemberState(teamID: teamID, memberID: reviewer.id, state: .idle)
            let reason = describeRejection(rejection)
            appendAudit(teamID: teamID, member: reviewer, kind: .gateRejected,
                        summary: "Revisão devolveu “\(stage.title)”", detail: reason)
            extraDirectives[stage.id] = reason
            let action = stagnations[teamID, default: TeamStagnationDetector()].recordReviewChanges(stageID: stage.id, feedback: reason)
            if case .escalateToLeader(let id, let leaderReason) = action {
                await escalateToLeader(teamID: teamID, runID: runID, stageID: id, reason: leaderReason,
                                       workspace: workspace, bank: bank)
            }
            return false
        }
    }

    private func attemptFinalAudit(teamID: UUID, runID: UUID, lastOwnerID: UUID?) async -> Bool {
        guard let model, let team = model.team(teamID) else { return false }
        let auditor = resolveIndependentReviewer(for: nil, ownerID: lastOwnerID, in: team) ?? team.orchestrator
        guard let auditor else { return false }

        // If any criteria lack verification/evidence yet, mark verified only after explicit audit pass.
        setMemberState(teamID: teamID, memberID: auditor.id, state: .reviewing)
        let bank = model.memory.teamBank(for: teamID)
        let brief = await TeamBoard.brief(bank: bank, team: team, message: "Auditoria final integrada")
        let workspace = await TeamWorkspaces.prepareMemberFolder(
            team: team, member: auditor, runID: runID, dataFolder: model.store.directory
        )
        let auditPrompt = """
        Run a final integrated audit across all deliverables and criteria for "\(team.name)".
        Verify every criterion and start your answer with APPROVED if everything passes, or CHANGES: followed by fixes.
        """
        let outcome = await executeTurn(TurnTask(
            teamID: teamID, runID: runID, stageID: nil, member: auditor, role: .finalAudit,
            prompt: auditPrompt, boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))
        guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return false }

        // Refresh team snapshot and mark verified criteria when auditor explicitly APPROVED.
        if ReviewVerdict.read(outcome.reply) == .approved,
           let idx = model.teams.firstIndex(where: { $0.id == teamID }) {
            for cIdx in model.teams[idx].mission.criteria.indices where !model.teams[idx].mission.criteria[cIdx].isVerified {
                model.teams[idx].mission.criteria[cIdx].isVerified = true
                if model.teams[idx].mission.criteria[cIdx].lastEvidence.isEmpty {
                    model.teams[idx].mission.criteria[cIdx].lastEvidence = "Auditoria final por \(auditor.name)"
                }
            }
        }

        guard let refreshed = model.team(teamID) else { return false }
        let auditResult = TeamQualityGates.evaluateFinalAudit(
            team: refreshed, lastStageOwnerID: lastOwnerID, auditorID: auditor.id, auditorReply: outcome.reply
        )
        switch auditResult {
        case .passed:
            setMemberState(teamID: teamID, memberID: auditor.id, state: .done)
            if !refreshed.projectFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await WorkFolders.cleanUp(project: URL(fileURLWithPath: refreshed.projectFolder),
                                              run: runID, root: WorkFolders.root(in: model.store.directory))
            }
            model.appendTeamThreadItem(
                TranscriptItem(.bot(text: "Missão concluída e aprovada na auditoria final por \(auditor.name). \(outcome.reply)", isStreaming: false)),
                to: teamID
            )
            appendAudit(teamID: teamID, member: auditor, kind: .completed,
                        summary: "Auditoria final aprovada e Missão concluída")
            await TeamBoard.syncMission(refreshed, to: bank)
            return true

        case .blocked(let reason):
            setMemberState(teamID: teamID, memberID: auditor.id, state: .idle)
            appendAudit(teamID: teamID, member: auditor, kind: .gateRejected,
                        summary: "Auditoria final bloqueou conclusão", detail: "\(reason)")
            // If an external blocker appeared in the audit reply, surface cleanly.
            if let firstStage = refreshed.mission.stages.first {
                let action = stagnations[teamID, default: TeamStagnationDetector()].recordFailure(stageID: firstStage.id, rawError: outcome.reply)
                if case .pauseFrontForUser(let id, let prompt) = action {
                    setStageBlocker(teamID: teamID, stageID: id, note: prompt)
                }
            }
            return false
        }
    }

    private func handleRecovery(teamID: UUID, runID: UUID, stage: MissionStage, rawError: String,
                                workspace: WorkFolder, bank: MemoryBank) async {
        switch stagnations[teamID, default: TeamStagnationDetector()].recordFailure(stageID: stage.id, rawError: rawError) {
        case .none:
            extraDirectives[stage.id] = "A execução anterior falhou (\(rawError.prefix(180))). Corrija e valide antes de concluir."
        case .pivotStrategy(let directive):
            appendAudit(teamID: teamID, member: model?.team(teamID)?.orchestrator, kind: .loopRecovery,
                        summary: "Quebra de loop acionada na etapa “\(stage.title)”", detail: directive)
            extraDirectives[stage.id] = directive
        case .escalateToLeader(let stageID, let reason):
            await escalateToLeader(teamID: teamID, runID: runID, stageID: stageID, reason: reason,
                                   workspace: workspace, bank: bank)
        case .pauseFrontForUser(let stageID, let prompt):
            setStageBlocker(teamID: teamID, stageID: stageID, note: prompt)
            appendAudit(teamID: teamID, member: model?.team(teamID)?.orchestrator, kind: .escalation,
                        summary: "Frente pausada aguardando usuário", detail: prompt)
        }
    }

    private func escalateToLeader(teamID: UUID, runID: UUID, stageID: UUID, reason: String,
                                  workspace: WorkFolder, bank: MemoryBank) async {
        guard let team = model?.team(teamID), let lead = team.orchestrator else { return }
        appendAudit(teamID: teamID, member: lead, kind: .escalation,
                    summary: "Etapa escalada ao líder", detail: reason)
        let brief = await TeamBoard.brief(bank: bank, team: team, message: reason)
        let outcome = await executeTurn(TurnTask(
            teamID: teamID, runID: runID, stageID: stageID, member: lead, role: .leaderReplan,
            prompt: "Stage escalated due to stagnation: \(reason). Propose a clean alternate strategy or reassignment.",
            boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))
        // Reassign stage to another available member if possible so a fresh specialist takes over.
        if let idx = model?.teams.firstIndex(where: { $0.id == teamID }),
           let sIdx = model?.teams[idx].mission.stages.firstIndex(where: { $0.id == stageID }) {
            let currentOwner = model?.teams[idx].mission.stages[sIdx].ownerMemberID
            if let alternate = model?.teams[idx].members.first(where: { $0.id != currentOwner }) {
                model?.teams[idx].mission.stages[sIdx].ownerMemberID = alternate.id
            }
        }
        if !outcome.reply.isEmpty {
            extraDirectives[stageID] = outcome.reply
        }
    }

    // MARK: Engine bridge

    private func executeTurn(_ task: TurnTask) async -> TurnOutcome {
        if let turnExecutor { return await turnExecutor(task) }
        guard let model else {
            return TurnOutcome(reply: "", completionWatch: CompletionWatch(), failedError: "AppModel indisponível.")
        }
        let chosen = task.member.model.isEmpty ? model.defaultModel : task.member.model
        guard let ref = ModelRef(chosen), let account = model.account(ref.provider),
              account.isEnabled, model.isUsable(account) else {
            return TurnOutcome(reply: "", completionWatch: CompletionWatch(),
                               failedError: "Modelo não configurado para \(task.member.name).")
        }
        let info = account.models.first { $0.id == ref.model }
        guard let client = model.clientOverride?() ?? account.client(for: info, credentials: AppModel.credentials(for: ref.provider),
                                                                     conversationID: "\(task.teamID.uuidString)-\(task.member.id.uuidString)") else {
            return TurnOutcome(reply: "", completionWatch: CompletionWatch(), failedError: LLMError.notConfigured.localizedDescription)
        }

        var bot = Bot(name: task.member.name, role: task.member.role, orb: task.member.orb, permissionMode: task.permissionMode)
        bot.id = task.member.id
        bot.capabilities = task.member.capabilities
        bot.workingDirectory = task.workspace.url.path

        let system = """
        You are \(task.member.name) (\(task.member.role)) in autonomous Team.
        \(task.member.systemGoal)
        \(WorkFolders.memberNote(task.workspace))
        <live_board>
        \(task.boardBrief)
        </live_board>
        """
        let request = TurnRequest(
            bot: bot,
            model: ref.model,
            system: system,
            history: [],
            prompt: task.prompt,
            client: client,
            tools: ToolBox.offered(for: task.member.capabilities, accessibilityGranted: false),
            context: ToolContext(workingDirectory: task.workspace.url),
            maxSteps: 40,
            permissions: { PermissionState(mode: task.permissionMode, rules: []) },
            supportsImages: false,
            picksUpTask: false
        )

        var reply = ""
        var watch = CompletionWatch()
        var pendingRequests: [String: ToolCallRequest] = [:]
        var failed: String?
        var usage = UsageTotals()

        for await event in model.engine.run(request) {
            switch event {
            case .text(let delta):
                reply += delta
            case .message(let msg):
                for call in msg.toolCalls { pendingRequests[call.id] = call }
                if msg.role == .tool, let callID = msg.toolCallID,
                   let call = pendingRequests.removeValue(forKey: callID) {
                    let isError = msg.content.hasPrefix("Erro:") || msg.content.hasPrefix("Error:")
                    watch.record(call, result: msg.content, failed: isError)
                }
            case .requestUsage(let used):
                var callUsage = UsageTotals(used)
                callUsage.billing = model.priceBook.billing(for: ref.text)
                model.usageLog.record(callUsage, orb: task.teamID, name: model.team(task.teamID)?.name ?? "Time",
                                      model: ref.text, source: .group)
                usage = callUsage
            case .failed(let message):
                failed = message
            default:
                break
            }
        }
        return TurnOutcome(reply: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                           completionWatch: watch, failedError: failed, usage: usage)
    }

    // MARK: State helpers

    private func isCurrentRun(teamID: UUID, runID: UUID) -> Bool {
        activeRunIDs[teamID] == runID
    }

    private func finishRun(teamID: UUID, status: TeamStatus) {
        activeRunIDs[teamID] = nil
        runTasks[teamID] = nil
        runStarts[teamID] = nil
        model?.workJournal.dropTeamRun(teamID)
        guard let model, let index = model.teams.firstIndex(where: { $0.id == teamID }) else { return }
        model.teams[index].status = status
        model.teams[index].updatedAt = .now
        if status == .completed {
            for m in model.teams[index].members.indices { model.teams[index].members[m].state = .done }
        }
    }

    private func syncWorkJournal() {
        guard let model else { return }
        let entries: [(teamID: UUID, runID: UUID, objective: String, startedAt: Date)] = activeRunIDs.compactMap { teamID, runID in
            guard let team = model.team(teamID) else { return nil }
            let objective = team.mission.objective.isEmpty ? team.idea : team.mission.objective
            return (teamID: teamID, runID: runID, objective: objective, startedAt: runStarts[teamID] ?? .now)
        }
        model.workJournal.syncTeamRuns(entries)
    }

    private func resolveOwner(for stage: MissionStage, in team: OrbTeam) -> TeamMember? {
        if let ownerID = stage.ownerMemberID, let member = team.member(id: ownerID) { return member }
        return team.orchestrator ?? team.members.first
    }

    private func resolveIndependentReviewer(for stage: MissionStage?, ownerID: UUID?, in team: OrbTeam) -> TeamMember? {
        if let reviewerID = stage?.reviewerMemberID, reviewerID != ownerID,
           let member = team.member(id: reviewerID) {
            return member
        }
        return team.members.first { $0.id != ownerID }
    }

    private func setMemberState(teamID: UUID, memberID: UUID, state: TeamMemberState) {
        guard let model, let tIdx = model.teams.firstIndex(where: { $0.id == teamID }),
              let mIdx = model.teams[tIdx].members.firstIndex(where: { $0.id == memberID }),
              model.teams[tIdx].members[mIdx].state != state else { return }
        model.teams[tIdx].members[mIdx].state = state
    }

    private func markStageDone(teamID: UUID, stageID: UUID, reviewerID: UUID) {
        guard let model, let tIdx = model.teams.firstIndex(where: { $0.id == teamID }),
              let sIdx = model.teams[tIdx].mission.stages.firstIndex(where: { $0.id == stageID }) else { return }
        model.teams[tIdx].mission.stages[sIdx].isDone = true
        model.teams[tIdx].mission.stages[sIdx].reviewerMemberID = reviewerID
        model.teams[tIdx].mission.stages[sIdx].blockerNote = ""
        model.teams[tIdx].updatedAt = .now
    }

    private func setStageBlocker(teamID: UUID, stageID: UUID, note: String) {
        guard let model, let tIdx = model.teams.firstIndex(where: { $0.id == teamID }),
              let sIdx = model.teams[tIdx].mission.stages.firstIndex(where: { $0.id == stageID }) else { return }
        model.teams[tIdx].mission.stages[sIdx].blockerNote = note
        model.teams[tIdx].updatedAt = .now
    }

    private func buildStagePrompt(stage: MissionStage, directive: String?) -> String {
        var lines = ["Execute stage \"\(stage.title)\". Verify your changes with tests or checks after your last edit before finishing."]
        if let directive, !directive.isEmpty { lines.append("Important directive: \(directive)") }
        return lines.joined(separator: "\n")
    }

    private func buildReviewPrompt(stage: MissionStage, builderName: String, builderSummary: String,
                                   criteria: [MissionCriterion]) -> String {
        let criteriaLines = criteria.map { "- \($0.description)" }.joined(separator: "\n")
        return """
        Review stage "\(stage.title)" implemented by \(builderName).
        Verify independently and start your reply with APPROVED or CHANGES: followed by concrete fixes.
        Summary from builder: \(builderSummary.prefix(800))
        Criteria:
        \(criteriaLines)
        """
    }

    private func describeRejection(_ rejection: TeamQualityGates.StageRejection) -> String {
        switch rejection {
        case .needsFreshCheck(let reminder): return reminder
        case .sameAuthorReviewer: return "A etapa exige um revisor diferente de quem executou."
        case .reviewNotApproved(let feedback): return feedback
        case .missingReviewVerdict: return "O revisor não iniciou com APPROVED ou CHANGES:."
        }
    }

    private func appendAudit(teamID: UUID, member: TeamMember?, kind: TeamAuditEntry.Kind,
                             summary: String, detail: String = "", commit: String = "") {
        guard let url = model?.store.teamAuditURL(teamID) else { return }
        TeamAuditLog.append(TeamAuditEntry(
            teamID: teamID,
            memberID: member?.id,
            memberName: member?.name ?? "Sistema",
            kind: kind,
            summary: summary,
            detail: detail,
            commit: commit
        ), to: url)
    }
}
