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
        /// Non-error and error tool results observed during this turn, for mechanical provenance checks.
        var observedTools: [TeamQualityGates.ObservedTool] = []
    }

    typealias TurnExecutor = @MainActor (TurnTask) async -> TurnOutcome

    private(set) var activeRunIDs: [UUID: UUID] = [:]
    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runStarts: [UUID: Date] = [:]
    @ObservationIgnored private var extraDirectives: [UUID: String] = [:]
    @ObservationIgnored private var stagnations: [UUID: TeamStagnationDetector] = [:]
    /// What the person wrote in the Team's thread, given to every turn until the Mission completes.
    @ObservationIgnored private var userDirections: [UUID: [String]] = [:]
    /// Live steering queues for active turns of each Team, keyed by teamID -> turnID.
    @ObservationIgnored private var activeSteerings: [UUID: [UUID: SteeringQueue]] = [:]
    @ObservationIgnored var turnExecutor: TurnExecutor?

    static let maxUserDirections = 6
    /// Consecutive final audits that send the work back before the Team stops and asks the person.
    static let maxAuditRejections = 3
    /// Builder summaries longer than this are spilled to `times/<teamID>/relatorio-<stage>.md` so reviewers can read the full text.
    static let reviewSummaryInlineLimit = 3_000
    /// Caps recorded tool results per turn so provenance checks stay fast and bounded in memory.
    private static let maxObservedTools = 60
    private static let maxObservedOutputChars = 16_000

    init(model: AppModel) {
        self.model = model
    }

    func isRunning(_ teamID: UUID) -> Bool { activeRunIDs[teamID] != nil }

    /// A message from the person: pushed immediately to any running turns via `SteeringQueue`, and kept for future turns.
    func steer(_ teamID: UUID, message: String) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let clipped = String(clean.prefix(1_000))
        var list = userDirections[teamID] ?? []
        list.append(clipped)
        if list.count > Self.maxUserDirections { list.removeFirst(list.count - Self.maxUserDirections) }
        userDirections[teamID] = list

        if let queues = activeSteerings[teamID], !queues.isEmpty {
            let steered = SteeredMessage(text: clipped, prompt: clipped, delivery: .steer)
            for queue in queues.values { queue.push(steered) }
            appendAudit(teamID: teamID, member: model?.team(teamID)?.orchestrator, kind: .command,
                        summary: "Orientação enviada ao vivo (\(queues.count) turno\(queues.count == 1 ? "" : "s"))",
                        detail: MemoryText.clip(clipped, 160))
        }
    }

    /// Registers a live steering queue for an in-flight turn; returns a cleanup closure. Exposed internally for tests.
    func registerSteering(_ queue: SteeringQueue, for teamID: UUID) -> UUID {
        let turnID = UUID()
        activeSteerings[teamID, default: [:]][turnID] = queue
        return turnID
    }

    func unregisterSteering(_ turnID: UUID, for teamID: UUID) {
        activeSteerings[teamID]?.removeValue(forKey: turnID)
        if activeSteerings[teamID]?.isEmpty == true { activeSteerings.removeValue(forKey: teamID) }
    }

    func directions(for teamID: UUID) -> [String] { userDirections[teamID] ?? [] }

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

        var auditRejections = 0

        while !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID), let team = model?.team(teamID), team.status == .running {
            let readyStages = nextReadyStages(in: team)
            if readyStages.isEmpty {
                let anyOpen = team.mission.stages.contains { !$0.isDone }
                if !anyOpen {
                    let step = await attemptFinalAudit(teamID: teamID, runID: runID, lastOwnerID: lastCompletedOwnerID)
                    guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return }
                    switch step {
                    case .completed:
                        finishRun(teamID: teamID, status: .completed)
                        return
                    case .waitingUser(let note):
                        finishRun(teamID: teamID, status: .waitingUser, notice: note)
                        return
                    case .reopened:
                        auditRejections += 1
                        if auditRejections >= Self.maxAuditRejections {
                            finishRun(teamID: teamID, status: .waitingUser, notice:
                                "A auditoria final devolveu o trabalho \(auditRejections) vezes seguidas. Veja os apontamentos e oriente o time.")
                            return
                        }
                        continue
                    case .stalled:
                        noProgressRounds += 1
                        if noProgressRounds >= Self.maxNoProgressRounds {
                            finishRun(teamID: teamID, status: .waitingUser, notice: Self.stalledNotice(noProgressRounds))
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(min(4_000, 500 * noProgressRounds)))
                        continue
                    }
                }
                // Every open stage is either blocked (`blockerNote`) or waits on one that is.
                let notes = team.mission.stages.filter { !$0.isDone && !$0.blockerNote.isEmpty }
                    .map { "“\($0.title)”: \($0.blockerNote)" }
                let detail = notes.isEmpty ? "as etapas abertas dependem de etapas que não podem avançar" : notes.joined(separator: " · ")
                finishRun(teamID: teamID, status: .waitingUser, notice: "O time precisa de você: \(detail)")
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
                guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return }
                noProgressRounds += 1
                if noProgressRounds >= Self.maxNoProgressRounds {
                    finishRun(teamID: teamID, status: .waitingUser, notice: Self.stalledNotice(noProgressRounds))
                    return
                }
                try? await Task.sleep(for: .milliseconds(min(4_000, 500 * noProgressRounds)))
            }
        }
    }

    static func stalledNotice(_ rounds: Int) -> String {
        "O time parou após \(rounds) rodadas sem progresso verificável. Envie uma orientação no fio ou retome quando quiser."
    }

    /// Stages whose dependencies are done, at most one per owner: a member works in one folder (its worktree, or the main
    /// checkout for the leader), so two of its stages at once would write over each other.
    func nextReadyStages(in team: OrbTeam) -> [MissionStage] {
        let doneIDs = Set(team.mission.stages.filter(\.isDone).map(\.id))
        var busyOwners: Set<UUID> = []
        return team.mission.stages.filter { stage in
            guard !stage.isDone, stage.blockerNote.isEmpty, stage.dependsOn.allSatisfy({ doneIDs.contains($0) }),
                  let owner = resolveOwner(for: stage, in: team) else { return false }
            return busyOwners.insert(owner.id).inserted
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
        let builderPrompt = buildStagePrompt(stage: stage, directive: directive, directions: directions(for: teamID))

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
            setMemberState(teamID: teamID, memberID: owner.id, state: .idle)
            return false
        }

        setMemberState(teamID: teamID, memberID: owner.id, state: .idle)
        setMemberState(teamID: teamID, memberID: reviewer.id, state: .reviewing)
        let summaryPath = spillReviewSummaryIfNeeded(buildOutcome.reply, teamID: teamID, stageID: stage.id)
        let reviewPrompt = buildReviewPrompt(stage: stage, builderName: owner.name, builderSummary: buildOutcome.reply,
                                             summaryPath: summaryPath,
                                             criteria: team.mission.criteria, directions: directions(for: teamID))
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
                // A member that edited without committing would otherwise leave its work out of the merge.
                if let problem = await WorkFolders.commitPending(in: workspace.url, message: "time(\(WorkFolders.slug(team.name))): \(stage.title)") {
                    appendAudit(teamID: teamID, member: owner, kind: .gateRejected,
                                summary: "Commit de “\(stage.title)” falhou", detail: problem)
                    extraDirectives[stage.id] = "Commit your work in \(workspace.url.path) before finishing: \(problem)"
                    setMemberState(teamID: teamID, memberID: reviewer.id, state: .idle)
                    return false
                }
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

    /// What the final audit led to.
    enum FinalAuditStep: Equatable {
        case completed
        /// The audit sent work back: a corrective stage was added and the loop goes on with it.
        case reopened
        /// Something outside the Team (login, CAPTCHA, a key) stops the audit: the person is asked.
        case waitingUser(String)
        /// No auditor could run, or the turn failed: try again after a pause.
        case stalled
    }

    static let correctiveStageTitle = "Corrigir apontamentos da auditoria final"

    private func attemptFinalAudit(teamID: UUID, runID: UUID, lastOwnerID: UUID?) async -> FinalAuditStep {
        guard let model, let team = model.team(teamID) else { return .stalled }
        let auditor = resolveIndependentReviewer(for: nil, ownerID: lastOwnerID, in: team) ?? team.orchestrator
        guard let auditor else { return .stalled }

        setMemberState(teamID: teamID, memberID: auditor.id, state: .reviewing)
        let bank = model.memory.teamBank(for: teamID)
        let brief = await TeamBoard.brief(bank: bank, team: team, message: "Auditoria final integrada")
        let workspace = await TeamWorkspaces.prepareMemberFolder(
            team: team, member: auditor, runID: runID, dataFolder: model.store.directory
        )
        let outcome = await executeTurn(TurnTask(
            teamID: teamID, runID: runID, stageID: nil, member: auditor, role: .finalAudit,
            prompt: buildFinalAuditPrompt(team: team, directions: directions(for: teamID)),
            boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))
        guard !Task.isCancelled, isCurrentRun(teamID: teamID, runID: runID) else { return .stalled }
        if let failed = outcome.failedError, !failed.isEmpty {
            setMemberState(teamID: teamID, memberID: auditor.id, state: .idle)
            appendAudit(teamID: teamID, member: auditor, kind: .gateRejected,
                        summary: "Auditoria final não rodou", detail: String(failed.prefix(200)))
            if let blocker = TeamExternalBlocker.detect(in: failed) { return .waitingUser(blocker) }
            return .stalled
        }

        // Each criterion is verified only by its own PASS line whose evidence matches an observed tool call (fail-closed).
        let verdicts = TeamQualityGates.criterionVerdicts(in: outcome.reply, count: team.mission.criteria.count)
        let verifiedNumbers = TeamQualityGates.verifiedCriteriaNumbers(for: verdicts, in: outcome.observedTools)
        var unverifiedProvenance: [String] = []
        if let idx = model.teams.firstIndex(where: { $0.id == teamID }) {
            for (number, verdict) in verdicts {
                let cIdx = number - 1
                guard model.teams[idx].mission.criteria.indices.contains(cIdx) else { continue }
                if verdict.passed, verifiedNumbers.contains(number) {
                    model.teams[idx].mission.criteria[cIdx].isVerified = true
                    model.teams[idx].mission.criteria[cIdx].lastEvidence = String(verdict.evidence.prefix(200))
                } else {
                    model.teams[idx].mission.criteria[cIdx].isVerified = false
                    model.teams[idx].mission.criteria[cIdx].lastEvidence = ""
                    if verdict.passed {
                        unverifiedProvenance.append("#\(number) \(model.teams[idx].mission.criteria[cIdx].description)")
                    }
                }
            }
            model.teams[idx].updatedAt = .now
        }
        if !unverifiedProvenance.isEmpty {
            appendAudit(teamID: teamID, member: auditor, kind: .gateRejected,
                        summary: "Evidência da auditoria final sem comprovação em ferramentas",
                        detail: unverifiedProvenance.joined(separator: "; "))
        }

        guard let refreshed = model.team(teamID) else { return .stalled }
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
            return .completed

        case .blocked(let reason):
            setMemberState(teamID: teamID, memberID: auditor.id, state: .idle)
            appendAudit(teamID: teamID, member: auditor, kind: .gateRejected,
                        summary: "Auditoria final bloqueou conclusão", detail: "\(reason)")
            if ReviewVerdict.read(outcome.reply) != .approved, let blocker = TeamExternalBlocker.detect(in: outcome.reply) {
                return .waitingUser(blocker)
            }
            // Every stage is done, so without a new one the loop would only audit the same work again.
            let provenanceHint = unverifiedProvenance.isEmpty ? ""
                : "\nUnverified PASS lines (must run checks and quote real tool output): " + unverifiedProvenance.joined(separator: "; ")
            reopenAfterAudit(teamID: teamID, auditorID: auditor.id, lastOwnerID: lastOwnerID,
                             reply: outcome.reply + provenanceHint, reason: reason)
            if let latest = model.team(teamID) { await TeamBoard.syncMission(latest, to: bank) }
            return .reopened
        }
    }

    /// Adds the corrective stage the final audit asked for: owned by whoever did the last stage (or the leader), reviewed by
    /// the auditor, with the audit's findings as its directive.
    private func reopenAfterAudit(teamID: UUID, auditorID: UUID, lastOwnerID: UUID?, reply: String,
                                  reason: TeamQualityGates.FinalAuditRejection) {
        guard let model, let idx = model.teams.firstIndex(where: { $0.id == teamID }) else { return }
        let team = model.teams[idx]
        let owner = [lastOwnerID, team.orchestratorID].compactMap { $0 }.first { $0 != auditorID && team.member(id: $0) != nil }
            ?? team.members.first { $0.id != auditorID }?.id
            ?? team.orchestratorID
        let stage = MissionStage(title: Self.correctiveStageTitle, ownerMemberID: owner,
                                 reviewerMemberID: auditorID == owner ? nil : auditorID)
        model.teams[idx].mission.stages.append(stage)
        model.teams[idx].updatedAt = .now
        let findings: String
        switch reason {
        case .unverifiedCriteria(let open):
            findings = "These criteria are not verified with evidence yet: " + open.joined(separator: "; ")
                + (reply.isEmpty ? "" : "\nAuditor said: \(reply.prefix(1_200))")
        default:
            findings = reply.isEmpty ? "The final audit did not approve the work." : String(reply.prefix(1_500))
        }
        extraDirectives[stage.id] = "Fix what the final audit found, then verify: \(findings)"
        model.appendTeamThreadItem(TranscriptItem(.notice("A auditoria final devolveu o trabalho; nova etapa: \(Self.correctiveStageTitle).")),
                                   to: teamID)
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
            prompt: "Stage escalated due to stagnation: \(reason). Propose a clean alternate strategy or reassignment."
                + (Self.directionsBlock(directions(for: teamID)).map { "\n" + $0 } ?? ""),
            boardBrief: brief, workspace: workspace, permissionMode: team.permissionMode
        ))
        // Reassign the stage so a fresh specialist takes over: someone neither its owner nor its reviewer when the Team has
        // one (handing it to the reviewer would leave the same pair, only swapped).
        if let model, let idx = model.teams.firstIndex(where: { $0.id == teamID }),
           let sIdx = model.teams[idx].mission.stages.firstIndex(where: { $0.id == stageID }) {
            let stage = model.teams[idx].mission.stages[sIdx]
            let members = model.teams[idx].members
            let alternate = members.first { $0.id != stage.ownerMemberID && $0.id != stage.reviewerMemberID }
                ?? members.first { $0.id != stage.ownerMemberID }
            if let alternate {
                model.teams[idx].mission.stages[sIdx].ownerMemberID = alternate.id
                if stage.reviewerMemberID == alternate.id {
                    model.teams[idx].mission.stages[sIdx].reviewerMemberID = stage.ownerMemberID
                }
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

        let teamNoteHint: String
        var tools = ToolBox.offered(for: task.member.capabilities, accessibilityGranted: false)
        if task.role == .build || task.role == .review {
            let consultCounter = ConsultCounter(limit: TeamNoteTool.maxConsultsPerTurn)
            let teammates = model.team(task.teamID)?.members
                .filter { $0.id != task.member.id }
                .map { "\($0.name) (\($0.role))" }
                .joined(separator: ", ") ?? ""
            teamNoteHint = "Use team_note(action: \"contract\") to publish shared interfaces/decisions to the live board"
                + (teammates.isEmpty ? "." : ", or team_note(action: \"ask_member\") for a quick read-only question to: \(teammates).")
            tools.append(TeamNoteTool { [weak self] args in
                guard let self else { throw ToolError("Time indisponível.") }
                return try await self.handleTeamNote(args, task: task, consultCounter: consultCounter)
            })
        } else {
            teamNoteHint = ""
        }

        let constraintsBlock: String
        if let missionConstraints = model.team(task.teamID)?.mission.constraints, !missionConstraints.isEmpty {
            let lines = missionConstraints
                .map { MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub($0)), 180) }
                .filter { !$0.isEmpty }
                .map { "- \($0)" }
                .joined(separator: "\n")
            constraintsBlock = lines.isEmpty ? "" : "\n<constraints>\nFollow these immutable constraints strictly:\n\(lines)\n</constraints>"
        } else {
            constraintsBlock = ""
        }

        let system = """
        You are \(task.member.name) (\(task.member.role)) in autonomous Team.
        \(task.member.systemGoal)
        \(WorkFolders.memberNote(task.workspace))
        \(teamNoteHint)\(constraintsBlock)
        <live_board>
        \(task.boardBrief)
        </live_board>
        """
        let steeringQueue = SteeringQueue()
        let steeringTurnID = registerSteering(steeringQueue, for: task.teamID)
        defer { unregisterSteering(steeringTurnID, for: task.teamID) }

        let hasTeamNote = task.role == .build || task.role == .review
        let request = TurnRequest(
            bot: bot,
            model: ref.model,
            system: system,
            history: [],
            prompt: task.prompt,
            client: client,
            tools: tools,
            context: ToolContext(workingDirectory: task.workspace.url),
            maxSteps: 40,
            permissions: { PermissionState(mode: task.permissionMode, rules: []) },
            supportsImages: false,
            picksUpTask: false,
            steering: steeringQueue,
            wrapUpSteps: hasTeamNote ? 3 : 1,
            wrapUpTools: hasTeamNote ? ["team_note"] : []
        )

        var reply = ""
        var watch = CompletionWatch()
        var pendingRequests: [String: ToolCallRequest] = [:]
        var observedTools: [TeamQualityGates.ObservedTool] = []
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
                    let isError = msg.isError || msg.content.hasPrefix("Erro:") || msg.content.hasPrefix("Error:")
                    watch.record(call, result: msg.content, failed: isError)
                    if observedTools.count < Self.maxObservedTools {
                        observedTools.append(TeamQualityGates.ObservedTool(
                            tool: call.name,
                            input: String(call.arguments.prefix(500)),
                            output: String(msg.content.prefix(Self.maxObservedOutputChars)),
                            isError: isError
                        ))
                    }
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
                           completionWatch: watch, failedError: failed, usage: usage,
                           observedTools: observedTools)
    }

    // MARK: State helpers

    private func isCurrentRun(teamID: UUID, runID: UUID) -> Bool {
        activeRunIDs[teamID] == runID
    }

    /// Ends the run; `notice` tells the person in the thread why the Team stopped (a silent `waitingUser` looks frozen).
    private func finishRun(teamID: UUID, status: TeamStatus, notice: String? = nil) {
        activeRunIDs[teamID] = nil
        runTasks[teamID] = nil
        runStarts[teamID] = nil
        stagnations[teamID] = nil
        model?.workJournal.dropTeamRun(teamID)
        if status == .completed { userDirections[teamID] = nil }
        guard let model, let index = model.teams.firstIndex(where: { $0.id == teamID }) else { return }
        model.teams[index].status = status
        model.teams[index].updatedAt = .now
        for m in model.teams[index].members.indices {
            if status == .completed {
                model.teams[index].members[m].state = .done
            } else if model.teams[index].members[m].state != .done {
                model.teams[index].members[m].state = .idle
            }
        }
        if let notice, !notice.isEmpty {
            model.appendTeamThreadItem(TranscriptItem(.notice(notice)), to: teamID)
            appendAudit(teamID: teamID, member: model.teams[index].orchestrator, kind: .escalation, summary: notice)
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

    /// The person's messages from the Team thread, newest last; they outrank the plan.
    static func directionsBlock(_ directions: [String]) -> String? {
        guard !directions.isEmpty else { return nil }
        return "Direction from the person (follow it; it overrides the plan where they differ):\n"
            + directions.map { "- \($0)" }.joined(separator: "\n")
    }

    private func buildStagePrompt(stage: MissionStage, directive: String?, directions: [String]) -> String {
        var lines = ["Execute stage \"\(stage.title)\". Verify your changes with tests or checks after your last edit before finishing."]
        if let directive, !directive.isEmpty { lines.append("Important directive: \(directive)") }
        if let block = Self.directionsBlock(directions) { lines.append(block) }
        return lines.joined(separator: "\n")
    }

    /// Bounds `ask_member` consultations within a single Team turn to prevent loops or token blow-ups.
    final class ConsultCounter: @unchecked Sendable {
        let limit: Int
        private var count = 0
        private let lock = NSLock()

        init(limit: Int) { self.limit = limit }

        func takeSlot() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func handleTeamNote(_ arguments: JSONValue, task: TurnTask, consultCounter: ConsultCounter) async throws -> String {
        guard let model, let team = model.team(task.teamID) else { throw ToolError("Time indisponível.") }
        switch arguments["action"]?.string?.lowercased() {
        case "contract":
            let title = (arguments["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (arguments["summary"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !summary.isEmpty else {
                throw ToolError("Fill both title and summary to record a contract.")
            }
            let supersedes = (arguments["supersedes"]?.array ?? [])
                .compactMap(\.string)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let files = (arguments["files"]?.array ?? [])
                .compactMap(\.string)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let bank = model.memory.teamBank(for: task.teamID)
            await TeamBoard.recordContract(title: title, summary: summary, author: task.member.name,
                                           supersedes: supersedes, files: files, to: bank)
            appendAudit(teamID: task.teamID, member: task.member, kind: .command,
                        summary: "Contrato registrado: \(MemoryText.clip(title, 60))",
                        detail: MemoryText.clip(summary, 160))
            return "Contract \"\(title)\" recorded on the live board."

        case "ask_member":
            guard consultCounter.takeSlot() else {
                throw ToolError("Consultation limit reached (\(consultCounter.limit) per turn). Finish with what you have.")
            }
            let targetName = (arguments["to"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let question = (arguments["question"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { throw ToolError("Write a concise question in question.") }
            let clippedQuestion = String(question.prefix(1_200))
            let wanted = DelegationRules.fold(targetName)
            let candidates = team.members.filter { $0.id != task.member.id }
            let target = candidates.first { DelegationRules.fold($0.name) == wanted }
                ?? candidates.first { !wanted.isEmpty && DelegationRules.fold($0.name).hasPrefix(wanted) }
            guard let target else {
                let names = candidates.map(\.name).joined(separator: ", ")
                throw ToolError(names.isEmpty
                    ? "There are no other members in this Team."
                    : "No member named \"\(targetName)\". Available: \(names).")
            }
            let reply = try await runReadOnlyConsult(from: task.member, to: target, question: clippedQuestion,
                                                     team: team, workspace: task.workspace, boardBrief: task.boardBrief)
            appendAudit(teamID: task.teamID, member: task.member, kind: .command,
                        summary: "Consultou \(target.name)",
                        detail: MemoryText.clip(reply, 160))
            return "Answer from \(target.name):\n\(reply)"

        default:
            throw ToolError("Use action contract or ask_member.")
        }
    }

    private func runReadOnlyConsult(from caller: TeamMember, to target: TeamMember, question: String,
                                    team: OrbTeam, workspace: WorkFolder, boardBrief: String) async throws -> String {
        guard let model else { throw ToolError("AppModel indisponível.") }
        let chosen = target.model.isEmpty ? model.defaultModel : target.model
        guard let ref = ModelRef(chosen), let account = model.account(ref.provider),
              account.isEnabled, model.isUsable(account) else {
            throw ToolError("Modelo não configurado para \(target.name).")
        }
        let info = account.models.first { $0.id == ref.model }
        guard let client = model.clientOverride?() ?? account.client(for: info, credentials: AppModel.credentials(for: ref.provider),
                                                                     conversationID: "\(team.id.uuidString)-consult-\(target.id.uuidString)") else {
            throw ToolError(LLMError.notConfigured.localizedDescription)
        }
        var bot = Bot(name: target.name, role: target.role, orb: target.orb, permissionMode: .ask)
        bot.id = target.id
        bot.capabilities = target.capabilities
        bot.workingDirectory = workspace.url.path
        // Strictly read-only tools and no `team_note` to prevent nested consultations or edits.
        let safeTools = ToolBox.offered(for: target.capabilities, accessibilityGranted: false).filter { tool in
            let name = tool.spec.name
            return tool.risk(.object([:])) == .safe && name != "run_command" && name != "write_file" && name != "edit_file"
        }
        let system = """
        You are \(target.name) (\(target.role)) answering a quick read-only question from teammate \(caller.name).
        Do not edit files or run commands. Reply concisely with the concrete contract, decision, or answer.
        <live_board>
        \(boardBrief)
        </live_board>
        """
        let request = TurnRequest(
            bot: bot,
            model: ref.model,
            system: system,
            history: [],
            prompt: "<team_question from=\"\(OrbEnvelopeText.clean(caller.name))\">\n\(OrbEnvelopeText.sanitize(question))\n</team_question>",
            client: client,
            tools: safeTools,
            context: ToolContext(workingDirectory: workspace.url),
            maxSteps: 6,
            permissions: { PermissionState(mode: .ask, rules: []) },
            supportsImages: false,
            picksUpTask: false
        )
        var reply = ""
        for await event in model.engine.run(request) {
            switch event {
            case .text(let delta):
                reply += delta
            case .requestUsage(let used):
                var callUsage = UsageTotals(used)
                callUsage.billing = model.priceBook.billing(for: ref.text)
                model.usageLog.record(callUsage, orb: team.id, name: team.name, model: ref.text, source: .group)
            case .failed(let message):
                throw ToolError("\(target.name) não conseguiu responder: \(message)")
            default:
                break
            }
        }
        let clean = OrbEnvelopeText.sanitize(reply)
        return clean.isEmpty ? "\(target.name) não retornou detalhes." : String(clean.prefix(2_000))
    }

    /// Spills a long builder summary to `times/<teamID>/relatorio-<shortStage>.md` so the reviewer can read the full report.
    func spillReviewSummaryIfNeeded(_ summary: String, teamID: UUID, stageID: UUID) -> String? {
        guard summary.count > Self.reviewSummaryInlineLimit, let model else { return nil }
        let folder = model.store.teamAuditURL(teamID).deletingLastPathComponent()
        let fileURL = folder.appending(path: "relatorio-\(OrbEnvelopeText.shortID(stageID)).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(summary.utf8).write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    func buildReviewPrompt(stage: MissionStage, builderName: String, builderSummary: String,
                           summaryPath: String? = nil,
                           criteria: [MissionCriterion], directions: [String]) -> String {
        let criteriaLines = criteria.map { "- \($0.description)" }.joined(separator: "\n")
        let shownSummary = String(builderSummary.prefix(Self.reviewSummaryInlineLimit))
        let spillNote = summaryPath.map { "\nFull builder report saved at \($0) (use read_file if you need the rest)." } ?? ""
        var prompt = """
        Review stage "\(stage.title)" implemented by \(builderName).
        Verify independently and start your reply with APPROVED or CHANGES: followed by concrete fixes.
        Summary from builder: \(shownSummary)\(spillNote)
        Criteria:
        \(criteriaLines)
        """
        if let block = Self.directionsBlock(directions) { prompt += "\n" + block }
        return prompt
    }

    private func buildFinalAuditPrompt(team: OrbTeam, directions: [String]) -> String {
        let criteria = team.mission.criteria.enumerated()
            .map { "\($0.offset + 1). \($0.element.description)" + ($0.element.verification.isEmpty ? "" : " (verify: \($0.element.verification))") }
            .joined(separator: "\n")
        var prompt = """
        Run a final integrated audit across all deliverables and criteria for "\(team.name)".
        Start your answer with APPROVED if everything passes, or CHANGES: followed by the fixes needed.
        """
        if !criteria.isEmpty {
            prompt += """

            Check every criterion yourself using your tools and write one line per criterion, \
            `<number>. PASS — <exact command and observed output snippet from this turn>` or `<number>. FAIL — <what is missing>`. \
            PASS lines without matching tool output from this turn are rejected automatically:
            \(criteria)
            """
        }
        if let block = Self.directionsBlock(directions) { prompt += "\n" + block }
        return prompt
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
