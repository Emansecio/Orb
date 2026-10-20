import Foundation
import Observation

/// The "Criar conversando" assistant: a conversation that exists only while the sheet is open and writes nothing down. It
/// runs like `reviewSkillsIfDue` does: a `TurnRequest` put together by hand for a stand-in Orb that is not
/// in `bots`, with `orb_draft` as its only tool. What it learns goes into `draft`, which the preview shows live; nothing
/// exists until `create()`, and `cancel()` throws it all away.
@MainActor @Observable
final class WizardRunner {
    /// Model calls in one answer, and messages in one session. Past either the assistant closes with what there is.
    static let maxSteps = 14
    static let maxUserMessages = 30
    /// What the Uso page files the assistant's calls under ("Criação de Orb"): one row for all the sessions.
    static let usageOrbID = UUID(uuidString: "0B5E5E5E-0000-4000-8000-0000000C4EA7")!
    static let usageName = "Criação de Orb"
    static let unavailable = "Conecte um modelo em Ajustes → Modelos para conversar."

    /// The stand-in Orb's id: its usage and its temporary folder are named for it.
    let id = UUID()
    /// What the chat shows: only the person's messages and the assistant's words (`.user` / `.bot`).
    private(set) var messages: [TranscriptItem] { didSet { userMessageCount = Self.userCount(in: messages) } }
    private(set) var draft = OrbDraft()
    private(set) var isThinking = false
    /// The assistant's words as they stream, until a tool call or the end of the answer makes them a message.
    private(set) var liveText = "" {
        didSet { if liveText.isEmpty == isSpeaking { isSpeaking = !liveText.isEmpty } }
    }
    /// Whether any words have streamed: written only when `liveText` goes empty or non-empty, so what reads it (`activity`)
    /// is not redone for every token.
    private(set) var isSpeaking = false
    private(set) var failure: String?
    /// What the model has been told.
    private(set) var history: [ChatMessage] = []
    /// The sheet closed (cancelled, or the Orb was made): nothing more happens.
    private(set) var isFinished = false
    /// A limit was reached and the assistant closed with what there is.
    private(set) var hitLimit = false

    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var turn: Task<Void, Never>?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var lastPrompt: String?
    /// Where the new Orb's own folder is made (`~/Orbs`; a test puts a temporary one).
    @ObservationIgnored var orbsBase = OrbFolder.defaultBase
    @ObservationIgnored private var historyMark = 0
    /// How many messages the chat had when the turn began (the person's own included): what the turn wrote after that goes
    /// when it fails or is stopped, so "Tentar de novo" does not show the same answer twice.
    @ObservationIgnored private var messagesMark = 0

    init(model: AppModel? = nil) {
        self.model = model
        messages = [TranscriptItem(.bot(text: WizardPrompt.firstLine, isStreaming: false))]
        userMessageCount = Self.userCount(in: messages)
    }

    /// A runner in a given state, for the review snapshots: it never calls a model.
    init(messages: [TranscriptItem], draft: OrbDraft, isThinking: Bool = false, liveText: String = "", failure: String? = nil) {
        self.messages = messages
        self.draft = draft
        self.isThinking = isThinking
        self.liveText = liveText
        isSpeaking = !liveText.isEmpty
        userMessageCount = Self.userCount(in: messages)
        self.failure = failure
    }

    deinit { removeFolder() }

    // MARK: State the views read

    /// How many messages the person has sent, kept up to date where `messages` changes (`canSend` reads it on every render).
    private(set) var userMessageCount = 0

    private static func userCount(in messages: [TranscriptItem]) -> Int {
        messages.filter { if case .user = $0.kind { true } else { false } }.count
    }

    /// The chips under the first line: only while nothing else was said.
    var offersSuggestions: Bool { messages.count == 1 && !isThinking && failure == nil && !isFinished }

    /// The person may type: not while the assistant answers, after a failure that waits for "Tentar de novo", or at the limit.
    var canSend: Bool { !isThinking && failure == nil && !isFinished && !hitLimit && userMessageCount < Self.maxUserMessages }

    /// What the Orb on the preview does.
    var activity: OrbActivity {
        guard isThinking else { return .idle }
        return isSpeaking ? .speaking : .thinking
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
    }

    // MARK: The person writes

    /// Sends a message of the person's. False when it does not go (empty, the assistant is answering, a limit).
    @discardableResult
    func send(_ text: String) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, canSend else { return false }
        messages.append(TranscriptItem(.user(text: typed, attachments: [])))
        // Talking again: the final card gives way until the assistant says it is ready once more.
        draft.ready = false
        lastPrompt = typed
        start(prompt: typed)
        return true
    }

    /// "Tentar de novo" after a failure: the same message again.
    func retry() {
        guard failure != nil, !isThinking, !isFinished, let prompt = lastPrompt else { return }
        failure = nil
        start(prompt: prompt)
    }

    static let interrupted = "A resposta parou quando você foi para o formulário."

    /// The person left the conversation for the form: the answer being written stops, and the draft stays as it is. The message
    /// left without an answer, so coming back offers "Tentar de novo" (it sends the same message; what had streamed is dropped).
    func stopTalking() {
        guard isThinking else { return }
        turn?.cancel()
        turn = nil
        dropLiveText()
        isThinking = false
        failure = Self.interrupted
        if history.count > historyMark { history.removeSubrange(historyMark...) }
        dropTurnMessages()
    }

    /// "Voltar a conversar" on the final card.
    func backToChatting() {
        draft.ready = false
    }

    // MARK: Ending

    /// "Criar": the Orb the draft describes, with the look the person chose (`look`: the assistant never designs it), as the
    /// person's own (`createdBy` stays nil). The assistant ends.
    @discardableResult
    func create(look: OrbConfig = OrbConfig()) -> Bot? {
        guard let model, !isFinished, draft.canCreate else { return nil }
        let bot = model.createBot(name: draft.name, role: NewBotSheet.finalRole(draft.role), orb: look,
                                  model: "", mode: draft.mode, identity: draft.instructions, interview: false, folder: .own,
                                  base: orbsBase)
        let capabilities = draft.capabilities.subtracting([.connectors])
        model.update(bot.id) { $0.capabilities = capabilities }
        finish()
        return bot
    }

    /// The sheet closed without an Orb: the turn stops, and nothing was kept.
    func cancel() { finish() }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        isThinking = false
        turn?.cancel()
        turn = nil
        removeFolder()
    }

    private nonisolated func removeFolder() {
        // The stand-in's working folder: one temporary folder.
        let url = FileManager.default.temporaryDirectory.appending(path: Self.folderName(for: id), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func folderName(for id: UUID) -> String { "orb-assistente-\(id.uuidString.lowercased())" }

    // MARK: The tool

    /// One `orb_draft` call: the draft takes it, and the model reads the draft back. Called from the engine's tool.
    func applyDraft(_ arguments: JSONValue) -> String {
        guard !isFinished else { return "The assistant is closed." }
        let report = draft.apply(arguments)
        return draft.modelSummary(report)
    }

    // MARK: A turn

    private var syntheticBot: Bot {
        var bot = Bot(name: "Assistente de criação", role: "", orb: OrbConfig(), permissionMode: .readOnly)
        bot.id = id
        bot.capabilities = []
        bot.workingDirectory = ensureFolder().path
        return bot
    }

    @discardableResult
    private func ensureFolder() -> URL {
        if let folder { return folder }
        let url = FileManager.default.temporaryDirectory.appending(path: Self.folderName(for: id), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folder = url
        return url
    }

    private func start(prompt: String) {
        guard let model else {
            failure = Self.unavailable
            return
        }
        guard let ref = ModelRef(model.defaultModel), let account = model.account(ref.provider), account.isEnabled, model.isUsable(account) else {
            failure = Self.unavailable
            return
        }
        failure = nil
        isThinking = true
        dropLiveText()
        historyMark = history.count
        messagesMark = messages.count
        let usedModel = ref.text
        // Every provider, Claude Code's included, goes through the native engine (`account.client` picks the transport).
        turn = Task { [weak self] in await self?.runNative(prompt: prompt, ref: ref, account: account, usedModel: usedModel) }
    }

    private func runNative(prompt: String, ref: ModelRef, account: ProviderAccount, usedModel: String) async {
        guard let model else { return }
        let info = account.models.first { $0.id == ref.model }
        guard let client = model.clientOverride?() ?? account.client(for: info, credentials: AppModel.credentials(for: ref.provider),
                                                                     conversationID: id.uuidString) else {
            fail(LLMError.notConfigured.localizedDescription)
            return
        }
        var context = ToolContext(workingDirectory: ensureFolder())
        context.canSaveFiles = false
        context.computerUseAllowed = false
        context.draft = { [weak self] arguments in await self?.applyDraft(arguments) ?? "The assistant is closed." }
        let request = TurnRequest(bot: syntheticBot, model: ref.model, system: WizardPrompt.system(profile: model.profile.promptSection),
                                  history: history, prompt: prompt, client: client, tools: ToolBox.wizardTools, context: context,
                                  maxSteps: Self.maxSteps,
                                  permissions: { PermissionState(mode: .readOnly, rules: []) },
                                  supportsImages: false, picksUpTask: false, onlyTools: [OrbDraftTool.name])
        await consume(model.engine.run(request), usedModel: usedModel)
    }

    /// Reads a turn's events into the chat.
    private func consume(_ events: AsyncStream<TurnEvent>, usedModel: String) async {
        var failed = false
        var reachedStepLimit = false
        for await event in events {
            guard !Task.isCancelled, !isFinished else { return }
            switch event {
            case .text(let delta):
                pendingText += delta
                scheduleLiveFlush()
            case .toolStarted:
                flushLiveText()
            case .message(let message):
                history.append(message)
            case .requestUsage(let used):
                record(UsageTotals(used), model: usedModel)
            case .usage:
                break // the turn's running sum: every call is recorded once, as `.requestUsage` arrives
            case .failed(let message):
                failed = true
                failure = message
            case .notice(let text):
                if text == AgentEngine.pausedNotice(after: Self.maxSteps) { reachedStepLimit = true }
            case .status, .approval, .toolFinished, .pendingUsage, .taskPaused, .steered, .compacted:
                break
            }
        }
        guard !Task.isCancelled, !isFinished else { return }
        isThinking = false
        turn = nil
        if failed {
            // The turn's own messages leave the history and the chat, and what had streamed is dropped: "Tentar de novo"
            // sends the same message to the same state (the answer starts over, it does not follow a cut sentence).
            dropLiveText()
            if history.count > historyMark { history.removeSubrange(historyMark...) }
            dropTurnMessages()
            return
        }
        flushLiveText()
        if reachedStepLimit || userMessageCount >= Self.maxUserMessages { closeWithWhatThereIs() }
    }

    private func fail(_ message: String) {
        failure = message
        isThinking = false
        turn = nil
    }

    /// The turn's words that already became messages of the chat (a tool call flushes them) go: it is being redone.
    private func dropTurnMessages() {
        if messages.count > messagesMark { messages.removeSubrange(messagesMark...) }
    }

    /// Words that streamed and are not in `liveText` yet: it takes them every ~33 ms, not a token at a time (each change
    /// parses the text again), like the main chat.
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

    /// The pending words join `liveText` (always before it is read as the answer).
    private func commitPendingText() {
        liveFlush?.cancel()
        liveFlush = nil
        guard !pendingText.isEmpty else { return }
        liveText += pendingText
        pendingText = ""
    }

    /// The streamed words go, those not shown yet too.
    private func dropLiveText() {
        liveFlush?.cancel()
        liveFlush = nil
        pendingText = ""
        liveText = ""
    }

    /// The answer's streamed words become a message of the chat.
    private func flushLiveText() {
        commitPendingText()
        let text = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        dropLiveText()
        guard !text.isEmpty else { return }
        messages.append(TranscriptItem(.bot(text: text, isStreaming: false)))
    }

    /// A limit was reached: the assistant says so and the final card shows what there is (if it has a name).
    private func closeWithWhatThereIs() {
        hitLimit = true
        messages.append(TranscriptItem(.bot(text: WizardPrompt.closing, isStreaming: false)))
        if draft.canCreate { draft.ready = true }
    }

    private func record(_ totals: UsageTotals, model usedModel: String) {
        guard let model, !model.isResetting, !totals.isEmpty else { return }
        model.usageLog.record(totals, orb: Self.usageOrbID, name: Self.usageName, model: usedModel, source: .creation)
    }
}
