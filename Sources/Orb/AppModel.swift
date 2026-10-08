import SwiftUI
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    // MARK: Persisted state

    var bots: [Bot] { didSet { scheduleStateSave() } }
    var routines: [Routine] { didSet { scheduleStateSave() } }
    var skills: [Skill] { didSet { scheduleStateSave() } }
    var connectors: [MCPServerConfig] { didSet { scheduleStateSave(); syncConnectors() } }
    /// Providers the user set up, with their last fetched model lists.
    var providers: [ProviderAccount] { didSet { scheduleStateSave() } }
    /// "provider/model" for bots without a model of their own.
    var defaultModel: String { didSet { scheduleStateSave() } }
    /// Conversations loaded so far. At launch only the selected Orb's is; the rest follow in the background
    /// (`unloadedConversations`), and anything that needs one earlier loads it on demand (`ensureLoaded`).
    private(set) var conversations: [UUID: Conversation]
    /// Things the user should hear about the data files (an unreadable file and where its copy is, a failed save).
    /// The first one is shown as an alert; `dismissDataNotice` moves on to the next.
    private(set) var dataNotices: [StoreNotice] = []

    // MARK: UI state

    var drafts: [UUID: String] = [:]
    var statusLine: [UUID: String] = [:]
    /// Bumped on every transcript mutation so chat views can keep the bottom in view.
    var scrollTick: [UUID: Int] = [:]
    var showInspector = true
    var showNewBot = false
    /// Bots that just finished a turn; their Orb celebrates for a moment.
    var celebrating: Set<UUID> = []
    /// Bots that just received a prompt (short "listening" beat before thinking).
    var listening: Set<UUID> = []
    /// Bots whose last turn was interrupted or failed (brief "error" expression).
    var failed: Set<UUID> = []
    /// Incremented when a prompt is sent; Orbs jump when it changes.
    var pokes: [UUID: Int] = [:]
    var connectorStatus: [UUID: MCPStatus] = [:]
    /// Tokens each Orb's last turn used, summed over its model calls (for a context meter; nothing shows it yet).
    private(set) var usage: [UUID: TokenUsage] = [:]
    /// Providers with a key in the Keychain (or, for ChatGPT and Claude Code, a sign-in).
    private(set) var connected: Set<ProviderKind> = []
    /// What each working bot's current tool does, and bots waiting for an approval. Kept apart from the
    /// transcript so the Orbs (sidebar, inspector) don't re-render on every streamed token.
    private var runningTool: [UUID: ToolCall.Kind] = [:]
    private var awaitingApproval: Set<UUID> = []
    /// What the local Claude Code reports (checked while that provider is set up).
    private(set) var claudeCode = ClaudeCodeStatus()
    /// Bots whose reply text is arriving right now (the Orb talks). Changes only when a burst of text starts
    /// or ends, not per token.
    private var speaking: Set<UUID> = []
    @ObservationIgnored private var speakingUntil: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var speakingWatch: [UUID: Task<Void, Never>] = [:]
    private static let speakingQuiet = Duration.milliseconds(600)
    var selection: SidebarItem? {
        didSet {
            if case .bot(let id) = selection {
                ensureLoaded(id)
                update(id) { $0.unread = 0 }
            }
        }
    }

    // MARK: Services

    @ObservationIgnored private var store: Store
    /// Every Orb's own memory bank (`memoria/<id>/` in the data folder).
    @ObservationIgnored let memory: MemoryLibrary
    /// What each Orb's memory panel shows, refreshed after changes.
    private(set) var memories: [UUID: MemorySnapshot] = [:]
    /// Saves a conversation stretch to memory once the user has been away for `SessionSummary.idleGap`.
    @ObservationIgnored private var memoryIdle: [UUID: Task<Void, Never>] = [:]
    /// Turns where you asked the Orb to remember something, and where that turn's transcript starts.
    @ObservationIgnored private var memoryRequests: [UUID: (intent: MemoryIntent, from: Int)] = [:]
    /// The approval cards open in any turn, whichever engine runs it (internal so tests can open cards).
    @ObservationIgnored let gate: ApprovalGate
    @ObservationIgnored private let engine: AgentEngine
    @ObservationIgnored private let claudeEngine: ClaudeCodeEngine
    /// Bots whose running turn belongs to `claudeEngine` (stop and approvals go there).
    @ObservationIgnored private var claudeTurns: Set<UUID> = []
    /// The folder each running Claude Code turn started in; its session belongs to that folder.
    @ObservationIgnored private var claudeTurnFolders: [UUID: String] = [:]
    @ObservationIgnored private let mcp = MCPManager()
    /// Processes the Orbs left running with `run_command(background: true)`.
    @ObservationIgnored private let jobs = BackgroundJobs()
    @ObservationIgnored var turns: [UUID: Task<Void, Never>] = [:] // internal for tests
    /// Each Orb's running turn has an id. A turn that was stopped can still be finishing its setup or draining
    /// events while the next one runs; only the current id may change the Orb's state.
    @ObservationIgnored private(set) var turnIDs: [UUID: UUID] = [:]
    /// Bot id → routine id, for turns started by a routine.
    @ObservationIgnored private var routineTurns: [UUID: UUID] = [:]
    @ObservationIgnored private var stateSave: Task<Void, Never>?
    @ObservationIgnored private var conversationSaves: [UUID: Task<Void, Never>] = [:]
    /// Orbs whose conversation changed since it was last written; quitting saves only these.
    @ObservationIgnored private var dirtyConversations: Set<UUID> = []
    /// Orbs whose conversation file hasn't been read yet (never in `conversations`).
    @ObservationIgnored private var unloadedConversations: Set<UUID> = []
    @ObservationIgnored private var didReportSaveFailure = false
    /// A conversation that keeps changing (a streaming reply) is written at most this often.
    private static let streamingSaveInterval = 5.0
    /// Streamed text not shown yet: deltas are published at most every `textFlushInterval`.
    @ObservationIgnored private var pendingText: [UUID: String] = [:]
    @ObservationIgnored private var textFlushes: [UUID: Task<Void, Never>] = [:]
    private static let textFlushInterval = Duration.milliseconds(33)
    @ObservationIgnored private var scheduler: Task<Void, Never>?

    /// `runsBackgroundWork: false` skips the scheduler, Keychain checks and app-wide observers (tests).
    init(store: Store = .standard, runsBackgroundWork: Bool = true) {
        self.store = store
        let gate = ApprovalGate()
        self.gate = gate
        engine = AgentEngine(gate: gate)
        claudeEngine = ClaudeCodeEngine(gate: gate)
        memory = MemoryLibrary.at(store.directory.appending(path: "memoria"))
        var notices: [StoreNotice] = []
        let stateRead = store.readState()
        notices += stateRead.notice.map { [$0] } ?? []
        let state = stateRead.value ?? .initial
        bots = state.bots
        routines = state.routines
        skills = state.skills
        connectors = state.connectors
        providers = state.providers
        defaultModel = state.defaultModel
        // Only the Orb shown first is read before the first frame.
        var firstConversations: [UUID: Conversation] = [:]
        if let first = state.bots.first {
            let read = store.readConversation(first.id)
            notices += Self.labeled(read.notice, for: first).map { [$0] } ?? []
            firstConversations[first.id] = read.value?.closingInterruptedTurn() ?? Conversation()
        }
        conversations = firstConversations
        unloadedConversations = Set(state.bots.dropFirst().map(\.id))
        dataNotices = notices
        selection = state.bots.first.map { .bot($0.id) }
        self.store.onSaveFailure = { [weak self] notice in
            Task { @MainActor in self?.reportSaveFailure(notice) }
        }

        syncConnectors()
        guard runsBackgroundWork else { return }
        Task { [weak self] in
            await self?.loadRemainingConversations()
            await self?.prepareMemory()
        }
        scheduler = Task { [weak self] in
            await self?.refreshConnections()
            while !Task.isCancelled {
                self?.runDueRoutines()
                await self?.refreshAllModels()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
                self?.jobs.killAllNow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, case .bot(let id) = self.selection {
                    self.update(id) { $0.unread = 0 }
                    Task { await self.refreshMemory(id) } // picks up pages edited by hand meanwhile
                }
            }
        }
    }

    // MARK: Loading and data notices

    func dismissDataNotice() {
        if !dataNotices.isEmpty { dataNotices.removeFirst() }
    }

    private func reportSaveFailure(_ notice: StoreNotice) {
        guard !didReportSaveFailure else { return } // once: a full disk would otherwise repeat on every save
        didReportSaveFailure = true
        dataNotices.append(notice)
    }

    /// Reads the conversation of an Orb that hasn't been loaded yet, right now. Everything that reads or changes
    /// a conversation outside a running turn goes through here first, so an unloaded one is never mistaken for an
    /// empty one (and then saved over its file).
    private func ensureLoaded(_ botID: UUID) {
        guard unloadedConversations.remove(botID) != nil else { return }
        let read = store.readConversation(botID)
        addNotice(Self.labeled(read.notice, for: bot(botID)))
        conversations[botID] = read.value?.closingInterruptedTurn() ?? Conversation()
        rewriteIfItLostItems(botID, read)
    }

    /// A file that lost items while decoding is rewritten once (its original is kept aside), so the loss is
    /// reported once instead of on every launch.
    private func rewriteIfItLostItems(_ botID: UUID, _ read: StoreRead<Conversation>) {
        guard read.value != nil, read.notice?.copy != nil else { return }
        scheduleConversationSave(botID, delay: 0)
    }

    /// The same message is never queued twice (a file read from two places at once reports the same thing).
    private func addNotice(_ notice: StoreNotice?) {
        guard let notice, !dataNotices.contains(notice) else { return }
        dataNotices.append(notice)
    }

    /// Tells which Orb a notice is about: the file name alone (`<UUID>.json`) doesn't.
    private static func labeled(_ notice: StoreNotice?, for bot: Bot?) -> StoreNotice? {
        guard var notice, let bot else { return notice }
        notice.message = "Conversa de \(bot.name): \(notice.message)"
        return notice
    }

    /// Reads the other Orbs' conversations one by one, decoding on the store's queue instead of the main thread.
    func loadRemainingConversations() async {
        for bot in bots where unloadedConversations.contains(bot.id) {
            let read = await store.readConversationAsync(bot.id)
            // Loaded on demand, or the Orb deleted, while this was reading: that result wins. Its notice still
            // stands when the file was moved aside (the on-demand read then found nothing), but not when the
            // on-demand read already reported the same lost items.
            let stillUnloaded = unloadedConversations.remove(bot.id) != nil
            if stillUnloaded || read.value == nil {
                addNotice(Self.labeled(read.notice, for: bot))
            }
            guard stillUnloaded, self.bot(bot.id) != nil else { continue }
            conversations[bot.id] = read.value?.closingInterruptedTurn() ?? Conversation()
            rewriteIfItLostItems(bot.id, read)
        }
    }

    // MARK: Queries

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    var selectedBot: Bot? {
        if case .bot(let id) = selection { bot(id) } else { nil }
    }

    func transcript(_ botID: UUID) -> [TranscriptItem] { conversations[botID]?.items ?? [] }

    /// Observable (the status line is set for exactly as long as a turn runs).
    func isWorking(_ botID: UUID) -> Bool { statusLine[botID] != nil }

    func routines(for botID: UUID) -> [Routine] { routines.filter { $0.botID == botID } }

    var enabledSkills: [Skill] { skills.filter(\.isEnabled) }

    /// The model a bot actually uses: its own or the default ("provider/model").
    func modelRef(for bot: Bot) -> ModelRef? { ModelRef(bot.model.isEmpty ? defaultModel : bot.model) }

    /// Short model name for the UI ("" when none is set).
    func modelName(for bot: Bot) -> String {
        guard let ref = modelRef(for: bot) else { return "" }
        return account(ref.provider)?.models.first { $0.id == ref.model }?.name ?? ref.model
    }

    /// True when the default model's provider is set up and usable.
    var isProviderReady: Bool {
        guard let ref = ModelRef(defaultModel), let account = account(ref.provider) else { return false }
        return account.isEnabled && isUsable(account)
    }

    /// What the bot's Orb is doing right now (expression, gaze and motion follow this).
    func activity(for botID: UUID) -> OrbActivity {
        if awaitingApproval.contains(botID) { return .waiting }
        if failed.contains(botID) { return .error }
        if celebrating.contains(botID) { return .happy }
        guard isWorking(botID) else { return .idle }
        if let kind = runningTool[botID] {
            switch kind {
            case .shell: return .typing
            case .browser, .computer: return .browsing
            case .file: return .reading
            case .search: return .searching
            case .connector, .memory: return .thinking
            }
        }
        if speaking.contains(botID) { return .speaking }
        return listening.contains(botID) ? .listening : .thinking
    }

    /// Keeps the bot `speaking` until no text arrived for `speakingQuiet`.
    private func markSpeaking(_ botID: UUID) {
        speakingUntil[botID] = .now + Self.speakingQuiet
        guard !speaking.contains(botID) else { return }
        speaking.insert(botID)
        speakingWatch[botID] = Task { [weak self] in
            while !Task.isCancelled, let deadline = self?.speakingUntil[botID] {
                if deadline <= .now { self?.stopSpeaking(botID); return }
                try? await Task.sleep(until: deadline)
            }
        }
    }

    private func stopSpeaking(_ botID: UUID) {
        speakingUntil[botID] = nil
        speakingWatch.removeValue(forKey: botID)?.cancel()
        if speaking.contains(botID) { speaking.remove(botID) }
    }

    // MARK: Providers

    func account(_ kind: ProviderKind) -> ProviderAccount? { providers.first { $0.kind == kind } }

    /// Has what it needs to be called: a sign-in, a key, or nothing (local servers).
    func isUsable(_ account: ProviderAccount) -> Bool {
        connected.contains(account.kind) || (!account.kind.needsKey && !account.kind.usesSignIn)
    }

    /// Models of every enabled, usable provider, for pickers.
    var modelChoices: [(account: ProviderAccount, models: [ProviderModel])] {
        providers.filter { $0.isEnabled && isUsable($0) && !$0.models.isEmpty }.map { ($0, $0.models) }
    }

    func addProvider(_ kind: ProviderKind) {
        guard account(kind) == nil else { return }
        providers.append(ProviderAccount(kind: kind))
    }

    func removeProvider(_ kind: ProviderKind) {
        signOut(kind)
        providers.removeAll { $0.kind == kind }
        if ModelRef(defaultModel)?.provider == kind { defaultModel = "" }
    }

    /// Forgets the key or sign-in (the provider stays listed). Claude Code's own login is left alone:
    /// it belongs to the user's Claude Code, not to Orb (see `signOutOfClaudeCode`).
    func signOut(_ kind: ProviderKind) {
        Keychain.set("", account: kind.rawValue)
        if kind == .chatgpt { Task { await ChatGPTAuth.shared.signOut() } }
        connected.remove(kind)
        updateProvider(kind) { $0.models = [] }
    }

    func updateProvider(_ kind: ProviderKind, _ change: (inout ProviderAccount) -> Void) {
        guard let index = providers.firstIndex(where: { $0.kind == kind }) else { return }
        change(&providers[index])
    }

    /// Saves (or, when empty, removes) the provider's key and reloads its models.
    func setKey(_ key: String, for kind: ProviderKind) async throws {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: kind.rawValue)
        await refreshConnections()
        try await refreshModels(kind)
    }

    /// Browser sign-in (ChatGPT's, or Claude Code's own `claude auth login`), then loads the plan's models.
    func signIn(_ kind: ProviderKind) async throws {
        switch kind {
        case .chatgpt:
            _ = try await ChatGPTAuth.shared.signIn { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        case .claudeCode:
            try await ClaudeCode.shared.login()
        default:
            return
        }
        addProvider(kind)
        await refreshConnections()
        if kind == .claudeCode && !connected.contains(kind) { throw ToolError("O login do Claude Code não foi concluído.") }
        try await refreshModels(kind)
    }

    /// Runs `claude auth logout`: Claude Code signs out on this Mac (in the Terminal too).
    func signOutOfClaudeCode() async {
        await ClaudeCode.shared.logout()
        await refreshConnections()
    }

    func refreshConnections() async {
        var found = Set(ProviderKind.allCases.filter { $0.needsKey && Keychain.get($0.rawValue) != nil })
        if await ChatGPTAuth.shared.credential != nil { found.insert(.chatgpt) }
        if account(.claudeCode) != nil {
            claudeCode = await ClaudeCode.shared.status()
            if claudeCode.isLoggedIn { found.insert(.claudeCode) }
        }
        connected = found
    }

    /// Reloads the provider's live model list; picks a default model if there is none yet.
    func refreshModels(_ kind: ProviderKind) async throws {
        guard let current = account(kind) else { return }
        let fetched = try await ModelCatalog.fetch(current, token: try await token(for: kind))
        updateProvider(kind) {
            $0.models = fetched
            $0.modelsUpdatedAt = .now
        }
        if ModelRef(defaultModel).flatMap({ account($0.provider) }) == nil, let first = fetched.first {
            defaultModel = ModelRef(provider: kind, model: first.id).text
        }
    }

    /// Keeps model lists current: on launch and then every few hours, for every usable provider.
    func refreshAllModels(olderThan age: TimeInterval = 6 * 3600) async {
        for account in providers where account.isEnabled && isUsable(account)
            && (account.modelsUpdatedAt.map { -$0.timeIntervalSinceNow > age } ?? true) {
            try? await refreshModels(account.kind)
        }
    }

    private func token(for kind: ProviderKind) async throws -> String? {
        try await Self.credentials(for: kind)(false)
    }

    /// Looked up again before every model request, so an expired sign-in is refreshed and a changed key is picked up.
    private static func credentials(for kind: ProviderKind) -> CredentialsProvider {
        { forceRefresh in
            kind == .chatgpt ? try await ChatGPTAuth.shared.accessToken(forceRefresh: forceRefresh) : Keychain.get(kind.rawValue)
        }
    }

    // MARK: Bots

    /// A new Orb comes with its own memory. `identity` (how it should work, written by you) starts it; with
    /// `interview` it also asks about you in its first conversation and keeps the answers.
    func createBot(name: String, role: String, orb: OrbConfig, model: String, mode: PermissionMode,
                   identity: String = "", interview: Bool = true) {
        let bot = Bot(name: name, role: role, orb: orb, model: model, permissionMode: mode)
        conversations[bot.id] = Conversation()
        bots.append(bot)
        selection = .bot(bot.id)
        let bank = memory.bank(for: bot.id)
        Task {
            await bank.ensureIdentity(notes: identity, interview: interview)
            await refreshMemory(bot.id)
        }
    }

    func update(_ botID: UUID, _ change: (inout Bot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        var bot = bots[index]
        let mode = bot.permissionMode
        change(&bot)
        if bot != bots[index] { bots[index] = bot }
        if bot.permissionMode != mode { permissionModeChanged(botID, to: bot.permissionMode) }
    }

    /// The mode and "Sempre permitir" rules of an Orb as they are now; the engines read this at every tool call,
    /// so a change (or a revoked grant) applies to the turn already running.
    func permissionState(of botID: UUID) -> PermissionState? {
        bot(botID).map { PermissionState(mode: $0.permissionMode, rules: $0.permissionRules) }
    }

    private func permissionSource(for bot: Bot) -> PermissionSource {
        let botID = bot.id, fallback = PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
        return { [weak self] in await self?.permissionState(of: botID) ?? fallback }
    }

    /// Changing the mode while the Orb waits for an answer answers the open cards: "Sem pedir permissão" allows
    /// them, "Automático" the ones it would not have asked about, "Só leitura" denies them. Claude Code is told too.
    private func permissionModeChanged(_ botID: UUID, to mode: PermissionMode) {
        guard turns[botID] != nil else { return }
        let isClaudeCode = claudeTurns.contains(botID)
        Task {
            let answered = await gate.applyModeChange(to: mode, for: botID)
            if isClaudeCode { await claudeEngine.modeChanged(for: botID, to: mode) }
            markDecided(answered, of: botID)
        }
    }

    private func markDecided(_ answered: [(approvalID: UUID, decision: ApprovalDecision)], of botID: UUID) {
        guard !answered.isEmpty else { return }
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.decision == nil,
                   let match = answered.first(where: { $0.approvalID == request.id }) {
                    request.decision = match.decision
                    items[index].kind = .approval(request)
                }
            }
        }
        let stillOpen = (conversations[botID]?.items ?? []).contains {
            if case .approval(let request) = $0.kind { request.decision == nil } else { false }
        }
        if !stillOpen { awaitingApproval.remove(botID) }
    }

    /// Deletes the Orb with its conversation and routines. Its memory goes too, unless `keepMemory`: then the
    /// last conversation stretch is saved and the folder moves to `memoria/_guardadas/`.
    func deleteBot(_ botID: UUID, keepMemory: Bool = false) {
        let name = bot(botID)?.name ?? "Orb"
        memoryRequests[botID] = nil
        stop(botID)
        let jobs = jobs
        Task { await jobs.forget(botID: botID) }
        memoryIdle.removeValue(forKey: botID)?.cancel()
        let library = memory
        if keepMemory {
            let stretch = pendingStretch(of: botID)
            let bank = library.bank(for: botID)
            Task.detached(priority: .utility) {
                if let stretch, let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
                library.keep(botID, name: name)
            }
        } else {
            library.delete(botID)
        }
        memories[botID] = nil
        bots.removeAll { $0.id == botID }
        routines.removeAll { $0.botID == botID }
        conversations[botID] = nil
        unloadedConversations.remove(botID)
        dirtyConversations.remove(botID)
        conversationSaves.removeValue(forKey: botID)?.cancel()
        store.deleteConversation(botID)
        if selection == .bot(botID) { selection = bots.first.map { .bot($0.id) } }
    }

    func selectAdjacentBot(offset: Int) {
        guard !bots.isEmpty else { return }
        let current = selectedBot.flatMap { bot in bots.firstIndex { $0.id == bot.id } } ?? -offset
        let next = (current + offset + bots.count) % bots.count
        selection = .bot(bots[next].id)
    }

    func newConversation(_ botID: UUID) {
        stop(botID)
        memoryIdle.removeValue(forKey: botID)?.cancel()
        saveMemory(of: botID)
        unloadedConversations.remove(botID)
        conversations[botID] = Conversation()
        drafts[botID] = ""
        scheduleConversationSave(botID, delay: 0)
    }

    // MARK: Memory

    func refreshMemory(_ botID: UUID) async {
        guard bot(botID) != nil else { return }
        let snapshot = await memory.bank(for: botID).snapshot()
        if bot(botID) != nil, memories[botID] != snapshot { memories[botID] = snapshot }
    }

    func forgetMemory(_ path: String, of botID: UUID) {
        let bank = memory.bank(for: botID)
        Task {
            await bank.forget(path)
            await refreshMemory(botID)
        }
    }

    func setIdentity(_ text: String, of botID: UUID) {
        let bank = memory.bank(for: botID)
        Task {
            await bank.setIdentity(text)
            await refreshMemory(botID)
        }
    }

    /// The identity notes as they are on disk now (the editor starts from these, not from an older snapshot).
    func identityText(of botID: UUID) async -> String {
        await memory.bank(for: botID).identity()?.body ?? ""
    }

    func restartInterview(of botID: UUID) {
        let bank = memory.bank(for: botID)
        Task {
            await bank.restartInterview()
            await refreshMemory(botID)
        }
    }

    /// Every Orb has a memory bank: older Orbs get one on the first launch of this version (with their old memory
    /// list moved in), conversation stretches left from the last run are saved and cold sessions age.
    private func prepareMemory() async {
        for bot in bots {
            guard self.bot(bot.id) != nil else { continue } // deleted meanwhile
            let bank = memory.bank(for: bot.id)
            await bank.ensureIdentity(notes: "", interview: false)
            if !bot.memory.isEmpty {
                var moved = true
                for fact in bot.memory where await bank.remember(fact.text, kind: .fato, origin: .voce) == .failed { moved = false }
                // The old list stays until every item is safely in the bank.
                if moved { update(bot.id) { $0.memory = [] } }
            }
            if !saveMemory(of: bot.id, ifIdleFor: SessionSummary.idleGap), hasUnsavedStretch(bot.id) {
                scheduleMemorySave(bot.id)
            }
            await bank.sweep()
            await refreshMemory(bot.id)
        }
    }

    private func hasUnsavedStretch(_ botID: UUID) -> Bool {
        ensureLoaded(botID)
        guard let conversation = conversations[botID] else { return false }
        return conversation.items.count > (conversation.memorySavedCount ?? 0)
    }

    /// The conversation since the last saved stretch (nil when there is nothing new, or not yet idle for `gap`).
    /// Marks it saved.
    private func pendingStretch(of botID: UUID, ifIdleFor gap: TimeInterval? = nil) -> [TranscriptItem]? {
        ensureLoaded(botID)
        guard turns[botID] == nil, let conversation = conversations[botID] else { return nil }
        let start = min(conversation.memorySavedCount ?? 0, conversation.items.count)
        let stretch = Array(conversation.items[start...])
        guard let last = stretch.last else { return nil }
        if let gap, Date.now.timeIntervalSince(last.date) < gap { return nil }
        conversations[botID]?.memorySavedCount = conversation.items.count
        scheduleConversationSave(botID, delay: 0)
        return stretch
    }

    /// Saves the conversation since the last saved stretch as a session page, built off the main thread (a long
    /// conversation takes a moment). Returns whether there was a stretch to save.
    @discardableResult
    private func saveMemory(of botID: UUID, ifIdleFor gap: TimeInterval? = nil) -> Bool {
        guard let stretch = pendingStretch(of: botID, ifIdleFor: gap) else { return false }
        let bank = memory.bank(for: botID)
        Task.detached(priority: .utility) { [weak self] in
            if let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
            await self?.refreshMemory(botID)
        }
        return true
    }

    /// When you asked the Orb to remember something and the turn ended without it saving, the app keeps what you
    /// said (or tells you it couldn't tell what to keep). Not after a turn you stopped or that failed.
    private func keepRequestedMemory(_ botID: UUID, succeeded: Bool) {
        guard let request = memoryRequests.removeValue(forKey: botID), succeeded, bot(botID) != nil else { return }
        let items = conversations[botID]?.items ?? []
        let saved = items.dropFirst(request.from).contains { item in
            if case .tool(let call) = item.kind { return call.kind == .memory && call.title.hasPrefix("Guardando") && call.state == .done }
            return false
        }
        guard !saved else { return }
        guard let content = request.intent.content else {
            append(.notice("Não deu para saber o que guardar na memória. Diga, por exemplo: “memorize que …”."), to: botID)
            return
        }
        append(.notice("Guardado na memória: \(MemoryText.clip(content, 160))"), to: botID)
        let bank = memory.bank(for: botID)
        Task {
            await bank.remember("O usuário pediu para lembrar: \(content)", kind: .fato, title: content, origin: .voce)
            await refreshMemory(botID)
        }
    }

    private func scheduleMemorySave(_ botID: UUID) {
        memoryIdle[botID]?.cancel()
        memoryIdle[botID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SessionSummary.idleGap))
            guard !Task.isCancelled else { return }
            self?.memoryIdle[botID] = nil
            self?.saveMemory(of: botID)
        }
    }

    // MARK: Turns

    @ObservationIgnored private var didSendLaunchPrompt = false

    /// The snapshot and rules marks of each running turn, recorded on its conversation once the model has been given them.
    @ObservationIgnored var pendingMarks: [UUID: DeliveryMarks] = [:]

    /// Dev aid for scripted end-to-end checks: `ORB_SEND="texto"` sends it to the selected bot once,
    /// after the provider connections are known.
    func sendLaunchPrompt() {
        guard !didSendLaunchPrompt, let text = ProcessInfo.processInfo.environment["ORB_SEND"],
              let id = selectedBot?.id else { return }
        didSendLaunchPrompt = true
        Task {
            await refreshConnections()
            send(text, to: id)
        }
    }

    /// Starts a turn. Returns false when nothing was sent (empty text, a turn already running, no usable model),
    /// so the composer keeps what you wrote. Only a message typed in the composer (`fromUser`) clears its draft:
    /// routines and quick ask must not wipe what you are typing for that Orb.
    @discardableResult
    func send(_ text: String, attachments: [URL] = [], to botID: UUID, fromUser: Bool = false) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, turns[botID] == nil, let bot = bot(botID) else { return false }
        ensureLoaded(botID)
        guard let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else {
            append(.notice("Conecte um modelo em Ajustes → Modelos para começar."), to: botID)
            return false
        }
        let modelInfo = account.models.first { $0.id == ref.model }

        memoryIdle.removeValue(forKey: botID)?.cancel()
        append(.user(text: typed, attachments: attachments.map(\.lastPathComponent)), to: botID)
        if fromUser { drafts[botID] = "" }
        statusLine[botID] = "Pensando"
        pokes[botID, default: 0] += 1
        flash(\.listening, botID, seconds: 1.4)

        let intent = MemoryIntent.detect(typed)
        memoryRequests[botID] = intent.map { ($0, max(0, (conversations[botID]?.items.count ?? 1) - 1)) }
        // Your request is the approval: this turn saves to memory without asking (the Orb's saved settings don't change).
        let rememberTool = ref.provider == .claudeCode ? ClaudeCodeTools.memoryPrefix + "remember" : "remember"
        let turnGrants = intent == nil ? [] : [PermissionRule(family: .memory)]

        var prompt = typed
        if let expansion = SystemPrompt.expandSkill(in: typed, skills: enabledSkills) {
            prompt = expansion.prompt
            if let index = skills.firstIndex(where: { $0.id == expansion.skill.id }) { skills[index].uses += 1 }
        }
        if !attachments.isEmpty {
            prompt += "\n\nAttached files (read them with your tools):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        if intent != nil {
            prompt += "\n\n(The user is asking you to remember something. Save it now with the \(rememberTool) tool, picking the "
                + "right tipo; if it refers to something said earlier, save that. Then confirm in one short sentence.)"
        }
        if ref.provider == .claudeCode {
            runClaudeCode(bot, model: ref.model, prompt: prompt, message: typed, turnGrants: turnGrants)
            return true
        }
        let skills = enabledSkills
        let budget = ContextBudget(model: modelInfo, provider: ref.provider, format: ref.provider == .custom ? account.format : nil)
        let prepared = conversations[botID, default: Conversation()].prepareHistory(budget: budget)
        let history = prepared.history
        if prepared.firstCompaction { append(.notice("Conversa compactada: o começo virou um resumo."), to: botID) }
        let bank = memory.bank(for: botID)
        let context = ToolContext(workingDirectory: bot.workingURL, memory: bank, botID: botID, jobs: jobs)
        let userTurns = userTurnCount(botID)
        let maxSteps = routineTurns[botID] != nil ? AgentEngine.routineMaxSteps : AgentEngine.defaultMaxSteps
        let lastWorkspaceHash = conversations[botID]?.workspaceHash

        let turn = beginTurn(botID)
        turns[botID] = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: typed, conversationIsNew: history.isEmpty, userTurns: userTurns,
                                         canSave: bot.permissionMode != .readOnly)
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard isCurrent(turn, of: botID) else { return } // stopped while preparing
            let built = TurnPrompt.native(inputs, history: history, lastWorkspaceHash: lastWorkspaceHash)
            let client: any LLMClient
            do {
                guard let made = account.client(for: modelInfo, credentials: Self.credentials(for: ref.provider),
                                                 conversationID: botID.uuidString) else { throw LLMError.notConfigured }
                client = made
            } catch {
                failSetup(error, of: botID, turn: turn)
                return
            }
            var tools = ToolBox.all.filter { $0.capability.map(bot.capabilities.contains) ?? true }
            if bot.capabilities.contains(.connectors) { tools += await mcp.tools() }
            guard isCurrent(turn, of: botID) else { return }
            // Recorded when the prompt with the snapshot is stored (see `apply`), not before.
            pendingMarks[botID] = built.marks
            let request = TurnRequest(bot: bot, model: ref.model, system: built.system, history: history,
                                      prompt: TurnPreface.prepend(built.preface, to: prompt),
                                      client: client, tools: tools, context: context, budget: budget, maxSteps: maxSteps,
                                      turnGrants: turnGrants, permissions: permissionSource(for: bot))
            await play(engine.run(request), for: botID, turn: turn)
        }
        return true
    }

    /// A turn run by the user's Claude Code, continuing the conversation's Claude Code session.
    private func runClaudeCode(_ bot: Bot, model: String, prompt: String, message: String, turnGrants: [PermissionRule]) {
        let botID = bot.id
        let conversation = conversations[botID] ?? Conversation()
        let folder = bot.workingURL.standardizedFileURL.path
        // Claude Code keeps sessions per folder: once the Orb's folder changed, the old one can't be resumed, so a
        // new session starts and gets the conversation so far as catch-up.
        let sessionID = conversation.claudeSession(forFolder: folder)
        // New session: hand it the whole conversation so far. Resumed: only what other models did since.
        // (Sessions from before this was tracked count as up to date.)
        let seen = sessionID == nil ? 0 : min(conversation.claudeSeenCount ?? conversation.messages.count, conversation.messages.count)
        let catchUp = ClaudeCodePrompt.catchUp(Array(conversation.messages[seen...]).modelContext())
        let skills = enabledSkills
        let bank = memory.bank(for: botID)
        let servers = [OrbToolsMCPServer.config(directory: bank.directory, mac: bot.capabilities.contains(.computerUse),
                                                folder: bot.workingURL)]
            + (bot.capabilities.contains(.connectors) ? connectors.filter(\.isEnabled) : [])
        let isNew = conversation.messages.isEmpty
        let userTurns = userTurnCount(botID)
        claudeTurns.insert(botID)
        claudeTurnFolders[botID] = folder
        let turn = beginTurn(botID)
        turns[botID] = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: message, conversationIsNew: isNew, userTurns: userTurns,
                                         tools: ClaudeCodePrompt.memoryTools, canSave: bot.permissionMode != .readOnly)
            // A resumed session keeps the system prompt of its first request: whatever changed since rides along.
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard isCurrent(turn, of: botID) else { return } // stopped while preparing
            let built = TurnPrompt.claudeCode(inputs, session: .init(isNewSession: sessionID == nil,
                                                                     workspaceHash: conversation.claudeWorkspaceHash,
                                                                     pinned: conversation.claudeMemoryPinned,
                                                                     standingHash: conversation.claudeStandingHash))
            let context = [built.context, catchUp].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let found = await ClaudeCode.shared.installation()
            guard isCurrent(turn, of: botID) else { return }
            guard let installation = found else {
                failSetup("O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos.", of: botID, turn: turn)
                return
            }
            let environment = await ClaudeCode.shared.environment(for: installation)
            guard isCurrent(turn, of: botID) else { return }
            let claudeTurn = ClaudeCodeTurn(bot: bot, executable: installation.executable, model: model, system: built.system,
                                            prompt: prompt, context: context, sessionID: sessionID, connectors: servers,
                                            environment: environment, turnGrants: turnGrants,
                                            permissions: permissionSource(for: bot))
            // Recorded when the session answers (see `apply`): a turn that fails before that sent nothing.
            pendingMarks[botID] = built.marks
            await play(claudeEngine.run(claudeTurn), for: botID, turn: turn)
        }
    }

    /// Your messages in the current conversation (the interview lasts the first few).
    private func userTurnCount(_ botID: UUID) -> Int {
        (conversations[botID]?.items ?? []).reduce(0) { count, item in
            if case .user = item.kind { return count + 1 }
            return count
        }
    }

    /// Registers a new turn of the Orb and returns its id.
    private func beginTurn(_ botID: UUID) -> UUID {
        let turn = UUID()
        turnIDs[botID] = turn
        return turn
    }

    /// Whether `turn` is still the Orb's running turn (not stopped, not replaced by a newer one).
    private func isCurrent(_ turn: UUID, of botID: UUID) -> Bool {
        !Task.isCancelled && turnIDs[botID] == turn
    }

    /// A turn that could not even start (no client, no Claude Code). A stopped turn says nothing: the failure
    /// would be its own cancellation, or belong to a turn the user already left.
    private func failSetup(_ error: Error, of botID: UUID, turn: UUID) {
        failSetup(error is CancellationError ? nil : error.localizedDescription, of: botID, turn: turn)
    }

    private func failSetup(_ message: String?, of botID: UUID, turn: UUID) {
        guard isCurrent(turn, of: botID), let message else { return }
        apply(.failed(message), to: botID)
        finishTurn(botID, turn: turn, succeeded: false)
    }

    private func play(_ events: AsyncStream<TurnEvent>, for botID: UUID, turn: UUID) async {
        var succeeded = true
        for await event in events {
            // A stopped stream still delivers queued events; `stop` already closed the turn.
            guard isCurrent(turn, of: botID) else { break }
            if case .failed = event { succeeded = false }
            apply(event, to: botID)
        }
        if !Task.isCancelled { finishTurn(botID, turn: turn, succeeded: succeeded) }
    }

    func stop(_ botID: UUID) {
        guard let task = turns[botID], let turn = turnIDs[botID] else { return }
        task.cancel()
        Task { await gate.cancelApprovals(for: botID) }
        closeStreaming(botID)
        awaitingApproval.remove(botID)
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.decision == nil {
                    request.decision = .deny
                    items[index].kind = .approval(request)
                }
            }
        }
        append(.notice("Você interrompeu esta resposta"), to: botID)
        finishTurn(botID, turn: turn, succeeded: false)
    }

    /// Your answer to an approval card. `rule` is the standing rule picked under "Sempre…"; "Sempre" without one
    /// takes the card's first suggestion, and "Só nesta tarefa" grants that rule until the turn ends.
    func decide(_ decision: ApprovalDecision, rule: PermissionRule? = nil, approvalID: UUID, botID: UUID) {
        var chosen = rule
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    if decision == .always || decision == .task { chosen = chosen ?? request.suggestions.first }
                    items[index].kind = .approval(request)
                }
            }
        }
        awaitingApproval.remove(botID)
        // Saved before the engine is answered, so its next tool call already sees the rule.
        if decision == .always, let chosen, chosen.isValid {
            update(botID) { if !$0.permissionRules.contains(chosen) { $0.permissionRules.append(chosen) } }
        }
        let answer = ApprovalAnswer(decision: decision, rule: chosen)
        Task { await gate.resolve(approvalID: approvalID, answer: answer) }
    }

    /// Records the marks of the turn's prompt when it has been delivered: for Orb's own engine, when the user message (with
    /// the snapshot) is stored; for Claude Code, when its session answers.
    private func recordMarks(_ botID: UUID, native: Bool) {
        guard let marks = pendingMarks[botID], marks.isNative == native else { return }
        pendingMarks[botID] = nil
        conversations[botID]?.record(marks)
    }

    func apply(_ event: TurnEvent, to botID: UUID) { // internal for tests
        switch event {
        case .status(let text):
            statusLine[botID] = text
        case .text(let delta):
            // Shown by `flushText`; anything that adds to the transcript flushes first (`closeStreaming`).
            pendingText[botID, default: ""] += delta
            if !delta.allSatisfy(\.isWhitespace) { markSpeaking(botID) }
            if textFlushes[botID] == nil {
                textFlushes[botID] = Task { [weak self] in
                    try? await Task.sleep(for: Self.textFlushInterval)
                    if !Task.isCancelled { self?.flushText(botID) }
                }
            }
        case .toolStarted(let call):
            stopSpeaking(botID)
            closeStreaming(botID)
            append(.tool(call), to: botID)
            runningTool[botID] = call.kind
        case .toolFinished(let id, let state, let output):
            runningTool[botID] = nil
            mutateItems(of: botID) { items in
                for index in items.indices {
                    if case .tool(var call) = items[index].kind, call.id == id {
                        call.state = state
                        call.output = output
                        call.finishedAt = .now
                        items[index].kind = .tool(call)
                    }
                }
            }
        case .approval(let request):
            stopSpeaking(botID)
            closeStreaming(botID)
            append(.approval(request), to: botID)
            awaitingApproval.insert(botID)
            if let bot = bot(botID) { notify(bot.name, "Precisa da sua permissão: \(request.title.lowercased())") }
        case .message(let message):
            ensureLoaded(botID)
            conversations[botID, default: Conversation()].messages.append(message)
            if message.role == .user { recordMarks(botID, native: true) }
            scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
        case .failed(let message):
            closeStreaming(botID)
            append(.notice("Não deu certo: \(message)"), to: botID)
        case .notice(let text):
            closeStreaming(botID)
            append(.notice(text), to: botID)
        case .usage(let total):
            usage[botID] = total
        case .session(let id):
            ensureLoaded(botID)
            conversations[botID, default: Conversation()].claudeSessionReported(id, folder: claudeTurnFolders[botID])
            if !id.isEmpty { recordMarks(botID, native: false) }
            scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
        }
    }

    /// Closes the turn `turn`; a turn that is no longer the Orb's current one (stopped, then replaced) is ignored.
    func finishTurn(_ botID: UUID, turn: UUID, succeeded: Bool = true) {
        guard turnIDs[botID] == turn, turns[botID] != nil else { return }
        turns[botID] = nil
        turnIDs[botID] = nil
        pendingMarks[botID] = nil
        // The turn may have changed files: the next message reads the folder again.
        Task { await WorkspaceSnapshots.shared.invalidate(botID) }
        let turnFolder = claudeTurnFolders.removeValue(forKey: botID)
        if claudeTurns.remove(botID) != nil { conversations[botID]?.claudeTurnFinished(folder: turnFolder) }
        stopSpeaking(botID)
        closeStreaming(botID)
        statusLine[botID] = nil
        if routineTurns[botID] != nil {
            // A routine's run isn't a conversation with you: it stays out of the memory's sessions.
            let count = conversations[botID]?.items.count
            conversations[botID]?.memorySavedCount = count
        } else {
            keepRequestedMemory(botID, succeeded: succeeded)
            scheduleMemorySave(botID)
        }
        Task { await refreshMemory(botID) }
        runningTool[botID] = nil
        awaitingApproval.remove(botID)
        let reply = lastReply(botID)
        if let routineID = routineTurns.removeValue(forKey: botID),
           let index = routines.firstIndex(where: { $0.id == routineID }) {
            routines[index].lastResult = succeeded ? reply.map { String($0.prefix(160)) } : "Não terminou: veja a conversa."
        }
        if succeeded {
            flash(\.celebrating, botID, seconds: 3)
            if let bot = bot(botID), let reply { notify(bot.name, String(reply.prefix(180))) }
        } else {
            flash(\.failed, botID, seconds: 2.5)
        }
        if selection != .bot(botID) || !(NSApp?.isActive ?? false) {
            update(botID) { $0.unread += 1 }
        }
        scheduleConversationSave(botID, delay: 0)
    }

    private func lastReply(_ botID: UUID) -> String? {
        for item in transcript(botID).reversed() {
            if case .bot(let text, _) = item.kind { return text }
            if case .user = item.kind { return nil }
        }
        return nil
    }

    /// Puts the bot in a transient state set for a few seconds.
    private func flash(_ keyPath: ReferenceWritableKeyPath<AppModel, Set<UUID>>, _ botID: UUID, seconds: Double) {
        self[keyPath: keyPath].insert(botID)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self[keyPath: keyPath].remove(botID)
        }
    }

    /// Shows the streamed text received since the last flush (one transcript update for many tokens).
    private func flushText(_ botID: UUID) {
        textFlushes.removeValue(forKey: botID)?.cancel()
        guard let delta = pendingText.removeValue(forKey: botID) else { return }
        mutateItems(of: botID) { items in
            if let last = items.indices.last, case .bot(let text, true) = items[last].kind {
                items[last].kind = .bot(text: text + delta, isStreaming: true)
            } else {
                items.append(TranscriptItem(.bot(text: delta.trimmingCharacters(in: .newlines), isStreaming: true)))
            }
        }
    }

    private func closeStreaming(_ botID: UUID) {
        flushText(botID)
        guard let last = conversations[botID]?.items.last, case .bot(let text, true) = last.kind else { return }
        mutateItems(of: botID) { items in
            items[items.count - 1].kind = .bot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isStreaming: false)
        }
    }

    private func append(_ kind: TranscriptItem.Kind, to botID: UUID) {
        mutateItems(of: botID) { $0.append(TranscriptItem(kind)) }
    }

    private func mutateItems(of botID: UUID, _ change: (inout [TranscriptItem]) -> Void) {
        ensureLoaded(botID)
        change(&conversations[botID, default: Conversation()].items)
        scrollTick[botID, default: 0] += 1
        scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
    }

    // MARK: Routines

    func runRoutine(_ routineID: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        let routine = routines[index]
        guard !isWorking(routine.botID), bot(routine.botID) != nil else { return }
        routines[index].lastRun = .now
        saveMemory(of: routine.botID) // your conversation so far is its own session
        append(.notice("Rotina “\(routine.name)”"), to: routine.botID)
        routineTurns[routine.botID] = routine.id
        send(routine.prompt, to: routine.botID)
        if !isWorking(routine.botID) {
            routineTurns[routine.botID] = nil
            routines[index].lastResult = "Não rodou: conecte um modelo em Ajustes."
        }
    }

    private func runDueRoutines(now: Date = .now) {
        for routine in routines where routine.isEnabled && routine.nextRun <= now {
            runRoutine(routine.id)
        }
    }

    // MARK: Catalogs

    func installedSkill(_ catalogID: String) -> Skill? { skills.first { $0.source == catalogID } }

    /// Adds a catalog skill; its slug gets a numeric suffix if one is already taken.
    func install(_ document: SkillDocument, from entry: CatalogSkill) {
        guard installedSkill(entry.id) == nil else { return }
        let base = Skill.slugify(entry.skillId)
        var slug = base, suffix = 2
        while skills.contains(where: { $0.slug == slug }) {
            slug = "\(base)-\(suffix)"
            suffix += 1
        }
        skills.append(Skill(slug: slug, name: document.name, summary: document.description,
                            instructions: document.instructions, source: entry.id, folderURL: document.folderURL))
    }

    func installedConnector(_ registryName: String) -> MCPServerConfig? { connectors.first { $0.source == registryName } }

    // MARK: Connectors

    func syncConnectors() {
        let configs = connectors
        Task {
            // `sync` waits for servers to start; show "Conectando…" meanwhile.
            let syncing = Task { await mcp.sync(configs) }
            try? await Task.sleep(for: .milliseconds(150))
            connectorStatus = await mcp.status()
            await syncing.value
            connectorStatus = await mcp.status()
        }
    }

    // MARK: Notifications

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true
    }

    /// Posts a banner when the app is in the background (bundled app only).
    private func notify(_ title: String, _ body: String) {
        guard !(NSApp?.isActive ?? false), Self.notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    // MARK: Saving

    private var state: AppState {
        AppState(bots: bots, routines: routines, skills: skills, connectors: connectors, providers: providers,
                 defaultModel: defaultModel)
    }

    private func scheduleStateSave() {
        stateSave?.cancel()
        stateSave = Task { [store] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(state)
        }
    }

    /// Saves `delay` seconds after the first unsaved change (a streaming reply is written at most every
    /// `streamingSaveInterval`, not rescheduled per token); `delay: 0` saves right away (end of a turn, new
    /// conversation). Encoding and pruning happen on the store's queue.
    private func scheduleConversationSave(_ botID: UUID, delay: Double) {
        guard conversations[botID] != nil else { return } // not loaded: nothing of ours to write
        dirtyConversations.insert(botID)
        if delay > 0, conversationSaves[botID] != nil { return }
        conversationSaves[botID]?.cancel()
        conversationSaves[botID] = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            conversationSaves[botID] = nil
            writeConversation(botID)
        }
    }

    private func writeConversation(_ botID: UUID) {
        guard let conversation = conversations[botID] else { return }
        dirtyConversations.remove(botID)
        store.save(conversation, for: botID)
    }

    /// Writes everything that changed and waits for the disk (on quit).
    func saveNow() {
        store.save(state)
        for botID in dirtyConversations { writeConversation(botID) }
        store.flush()
    }
}
