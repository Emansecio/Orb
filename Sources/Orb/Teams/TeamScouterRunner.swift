import Foundation
import Observation

/// Interactive Team Scouter (`Olheiro`) session inside `NewTeamSheet`.
/// Inspects the optional project folder read-only, chats lightly in pt-BR, populates/refines `TeamProposal` live via
/// `team_proposal`, and materializes the `OrbTeam` once the user confirms.
@MainActor
@Observable
final class TeamScouterRunner {
    static let maxSteps = 12
    static let usageOrbID = UUID(uuidString: "0B5E5E5E-0000-4000-8000-0000007EA301")!
    static let usageName = "Olheiro de times"
    static let unavailable = "Conecte um modelo em Ajustes → Modelos para acionar o Olheiro."
    static let scoutOrb = OrbConfig(color: "sol", eyes: "pontos", mouth: "sorrisao", cheeks: "sardas", temperament: .curioso)

    let id = UUID()
    private(set) var messages: [TranscriptItem]
    var proposal = TeamProposal()
    var idea = ""
    var scouterModel = "" {
        didSet {
            guard !isPreviewOnly else { return }
            model?.lastScouterModel = scouterModel
        }
    }
    var projectFolder = ""
    var permissionMode = PermissionMode.bypass

    private(set) var isThinking = false
    private(set) var liveText = "" {
        didSet { if liveText.isEmpty == isSpeaking { isSpeaking = !liveText.isEmpty } }
    }
    private(set) var isSpeaking = false
    private(set) var failure: String?
    private(set) var searchingStep = 0
    private(set) var scoutAck = 0
    private(set) var scoutLanding = 0
    private(set) var highlightedFields: Set<TeamProposalField> = []

    private(set) var history: [ChatMessage] = []
    private(set) var isFinished = false

    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var turn: Task<Void, Never>?
    @ObservationIgnored private var phraseTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrompt: String?
    @ObservationIgnored private var initialIdea = ""
    @ObservationIgnored private var historyMark = 0
    @ObservationIgnored private var messagesMark = 0
    @ObservationIgnored private let isPreviewOnly: Bool

    init(model: AppModel? = nil) {
        self.model = model
        self.isPreviewOnly = false
        self.messages = [TranscriptItem(.bot(text: TeamScouterPrompt.firstLine, isStreaming: false))]
        if let model { self.scouterModel = model.lastScouterModel }
    }

    /// Static preview state for `--snapshot` (never invokes any model or writes preferences).
    init(messages: [TranscriptItem], proposal: TeamProposal, idea: String = "", scouterModel: String = "",
         projectFolder: String = "", isThinking: Bool = false, liveText: String = "", failure: String? = nil) {
        self.isPreviewOnly = true
        self.messages = messages
        self.proposal = proposal
        self.idea = idea
        self.scouterModel = scouterModel
        self.projectFolder = projectFolder
        self.isThinking = isThinking
        self.liveText = liveText
        self.isSpeaking = !liveText.isEmpty
        self.failure = failure
    }

    var offersStarters: Bool { messages.count == 1 && !proposal.hasContent && !isThinking && failure == nil }
    var offersRefinements: Bool { proposal.hasContent && !isThinking && failure == nil && !isFinished }
    var canSend: Bool { !isThinking && !isFinished }

    var activity: OrbActivity {
        if failure != nil { return .error }
        guard isThinking else { return proposal.canCreate ? .happy : .idle }
        if isSpeaking { return .speaking }
        return projectFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .thinking : .searching
    }

    var currentSearchingPhrase: String {
        TeamScouterPrompt.searchingPhrases[searchingStep % TeamScouterPrompt.searchingPhrases.count]
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if scouterModel.isEmpty { scouterModel = model.lastScouterModel }
    }

    // MARK: Conversation

    @discardableResult
    func send(_ text: String) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, canSend else { return false }
        if initialIdea.isEmpty { initialIdea = typed }
        failure = nil
        scoutAck += 1
        messages.append(TranscriptItem(.user(text: typed, attachments: [])))
        lastPrompt = typed
        start(prompt: typed)
        return true
    }

    func retry() {
        guard failure != nil, !isThinking, !isFinished, let prompt = lastPrompt else { return }
        failure = nil
        scoutAck += 1
        start(prompt: prompt)
    }

    func stop() {
        guard isThinking else { return }
        turn?.cancel()
        turn = nil
        stopPhraseCycle()
        dropLiveText()
        isThinking = false
        failure = "A análise foi pausada. Ajuste o texto ou clique em Tentar de novo."
        if history.count > historyMark { history.removeSubrange(historyMark...) }
        dropTurnMessages()
    }

    func cancel() {
        isFinished = true
        isThinking = false
        turn?.cancel()
        turn = nil
        stopPhraseCycle()
        highlightTask?.cancel()
    }

    // MARK: Direct edits on proposal

    func addMemberDraft() {
        guard proposal.members.count < OrbTeam.maxMembers else { return }
        let existingNames = proposal.members.map(\.name)
        var candidate = "Especialista \(proposal.members.count + 1)"
        var idx = proposal.members.count + 1
        while existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            idx += 1
            candidate = "Especialista \(idx)"
        }
        let preset = TeamMemberDraft.preset(at: proposal.members.count)
        proposal.members.append(TeamMemberDraft(
            name: candidate,
            role: "Nova frente de trabalho",
            orb: preset,
            isOrchestrator: proposal.members.isEmpty
        ))
    }

    func removeMemberDraft(_ id: UUID) {
        guard proposal.members.count > 1 else { return }
        proposal.members.removeAll { $0.id == id }
        if !proposal.members.contains(where: \.isOrchestrator), !proposal.members.isEmpty {
            proposal.members[0].isOrchestrator = true
        }
    }

    func setOrchestratorDraft(_ id: UUID) {
        for index in proposal.members.indices {
            proposal.members[index].isOrchestrator = (proposal.members[index].id == id)
        }
    }

    func cycleMemberOrb(_ id: UUID) {
        guard let index = proposal.members.firstIndex(where: { $0.id == id }) else { return }
        proposal.members[index].orb = proposal.members[index].nextPreset()
    }

    func addCriterion(_ text: String = "Novo critério de pronto") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, proposal.criteria.count < 8 else { return }
        proposal.criteria.append(trimmed)
    }

    func removeCriterion(at index: Int) {
        guard proposal.criteria.indices.contains(index) else { return }
        proposal.criteria.remove(at: index)
    }

    @discardableResult
    func createTeam(startNow: Bool = false) -> OrbTeam? {
        guard let model, !isFinished, proposal.canCreate else { return nil }
        let ideaSource = initialIdea.isEmpty ? idea : initialIdea
        let effectiveModel = scouterModel.isEmpty ? model.defaultModel : scouterModel
        guard let created = model.createTeam(from: proposal, idea: ideaSource, scouterModel: effectiveModel,
                                             projectFolder: projectFolder, permissionMode: permissionMode,
                                             startNow: startNow) else {
            return nil
        }
        cancel()
        return created
    }

    // MARK: Tool bridge & Engine execution

    func applyProposalTool(_ arguments: JSONValue) -> String {
        guard !isFinished else { return "O Olheiro já foi encerrado." }
        let changed = proposal.apply(arguments)
        if !changed.isEmpty {
            scoutLanding += 1
            flash(changed)
        }
        return proposal.modelSummary(changed)
    }

    private func flash(_ fields: Set<TeamProposalField>) {
        highlightedFields = fields
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(950))
            guard !Task.isCancelled else { return }
            self?.highlightedFields = []
        }
    }

    private func start(prompt: String) {
        guard let model else {
            failure = Self.unavailable
            return
        }
        let chosen = scouterModel.isEmpty ? model.defaultModel : scouterModel
        guard let ref = ModelRef(chosen), let account = model.account(ref.provider), account.isEnabled, model.isUsable(account) else {
            failure = Self.unavailable
            return
        }
        isThinking = true
        dropLiveText()
        startPhraseCycle()
        historyMark = history.count
        messagesMark = messages.count
        turn = Task { [weak self] in await self?.runNative(prompt: prompt, ref: ref, account: account, usedModel: ref.text) }
    }

    private func runNative(prompt: String, ref: ModelRef, account: ProviderAccount, usedModel: String) async {
        guard let model else { return }
        let info = account.models.first { $0.id == ref.model }
        guard let client = model.clientOverride?() ?? account.client(for: info, credentials: AppModel.credentials(for: ref.provider),
                                                                     conversationID: id.uuidString) else {
            fail(LLMError.notConfigured.localizedDescription)
            return
        }
        let cleanFolder = projectFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDir = cleanFolder.isEmpty
            ? FileManager.default.temporaryDirectory
            : URL(fileURLWithPath: cleanFolder, isDirectory: true)
        var bot = Bot(name: "Olheiro de times", role: "", orb: Self.scoutOrb, permissionMode: .readOnly)
        bot.id = id
        bot.capabilities = []
        bot.workingDirectory = workingDir.path

        var context = ToolContext(workingDirectory: workingDir)
        context.canSaveFiles = false
        context.computerUseAllowed = false
        context.teamProposal = { [weak self] arguments in
            await self?.applyProposalTool(arguments) ?? "O Olheiro foi encerrado."
        }
        let allowed = cleanFolder.isEmpty ? Set([TeamProposalTool.name]) : ToolBox.teamScouterFolderToolNames
        let request = TurnRequest(
            bot: bot,
            model: ref.model,
            system: TeamScouterPrompt.system(projectFolder: cleanFolder, profile: model.profile.promptSection),
            history: history,
            prompt: prompt,
            client: client,
            tools: ToolBox.teamScouterTools,
            context: context,
            maxSteps: Self.maxSteps,
            permissions: { PermissionState(mode: .readOnly, rules: []) },
            supportsImages: false,
            picksUpTask: false,
            onlyTools: allowed
        )
        await consume(model.engine.run(request), usedModel: usedModel)
    }

    private func consume(_ events: AsyncStream<TurnEvent>, usedModel: String) async {
        var failed = false
        var unfinished: TokenUsage?
        var streamed = 0
        for await event in events {
            switch event {
            case .requestUsage(let used):
                unfinished = nil
                record(UsageTotals(used), model: usedModel)
                continue
            case .pendingUsage(let used):
                unfinished = used
                streamed = 0
                continue
            case .text(let delta):
                streamed += delta.count
            default:
                break
            }
            guard !Task.isCancelled, !isFinished else { continue }
            switch event {
            case .text(let delta):
                pendingText += delta
                scheduleLiveFlush()
            case .toolStarted:
                flushLiveText()
            case .message(let message):
                history.append(message)
            case .failed(let message):
                failed = true
                failure = message
            case .requestUsage, .usage, .status, .approval, .toolFinished, .pendingUsage, .notice, .taskPaused, .steered, .compacted:
                break
            }
        }
        if let unfinished { record(UsageTotals(unfinished.withOutput(atLeastCharacters: streamed)), model: usedModel) }
        guard !Task.isCancelled, !isFinished else { return }
        stopPhraseCycle()
        isThinking = false
        turn = nil
        if failed {
            dropLiveText()
            if history.count > historyMark { history.removeSubrange(historyMark...) }
            dropTurnMessages()
            return
        }
        flushLiveText()
    }

    private func fail(_ message: String) {
        stopPhraseCycle()
        failure = message
        isThinking = false
        turn = nil
    }

    private func dropTurnMessages() {
        if messages.count > messagesMark { messages.removeSubrange(messagesMark...) }
    }

    private func startPhraseCycle() {
        stopPhraseCycle()
        searchingStep = 0
        phraseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { break }
                self?.searchingStep += 1
            }
        }
    }

    private func stopPhraseCycle() {
        phraseTask?.cancel()
        phraseTask = nil
    }

    private var pendingText = ""
    private var liveFlush: Task<Void, Never>?

    private func scheduleLiveFlush() {
        guard liveFlush == nil else { return }
        liveFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            self?.commitPendingText()
        }
    }

    private func commitPendingText() {
        liveFlush?.cancel()
        liveFlush = nil
        guard !pendingText.isEmpty else { return }
        liveText += pendingText
        pendingText = ""
    }

    private func dropLiveText() {
        liveFlush?.cancel()
        liveFlush = nil
        pendingText = ""
        liveText = ""
    }

    private func flushLiveText() {
        commitPendingText()
        let text = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        dropLiveText()
        guard !text.isEmpty else { return }
        messages.append(TranscriptItem(.bot(text: text, isStreaming: false)))
    }

    private func record(_ totals: UsageTotals, model usedModel: String) {
        guard let model, !model.isResetting, !totals.isEmpty else { return }
        var totals = totals
        totals.billing = model.priceBook.billing(for: usedModel)
        model.usageLog.record(totals, orb: Self.usageOrbID, name: Self.usageName, model: usedModel, source: .creation)
    }
}
