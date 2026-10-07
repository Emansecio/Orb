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
    private(set) var conversations: [UUID: Conversation]

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
    /// Providers with a key in the Keychain (or, for ChatGPT and Claude Code, a sign-in).
    private(set) var connected: Set<ProviderKind> = []
    /// What the local Claude Code reports (checked while that provider is set up).
    private(set) var claudeCode = ClaudeCodeStatus()
    var selection: SidebarItem? {
        didSet {
            if case .bot(let id) = selection { update(id) { $0.unread = 0 } }
        }
    }

    // MARK: Services

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let engine = AgentEngine()
    @ObservationIgnored private let claudeEngine = ClaudeCodeEngine()
    /// Bots whose running turn belongs to `claudeEngine` (stop and approvals go there).
    @ObservationIgnored private var claudeTurns: Set<UUID> = []
    @ObservationIgnored private let mcp = MCPManager()
    @ObservationIgnored private var turns: [UUID: Task<Void, Never>] = [:]
    /// Bot id → routine id, for turns started by a routine.
    @ObservationIgnored private var routineTurns: [UUID: UUID] = [:]
    @ObservationIgnored private var stateSave: Task<Void, Never>?
    @ObservationIgnored private var conversationSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scheduler: Task<Void, Never>?

    init(store: Store = .standard) {
        self.store = store
        let state = store.loadState() ?? .initial
        bots = state.bots
        routines = state.routines
        skills = state.skills
        connectors = state.connectors
        providers = state.providers
        defaultModel = state.defaultModel
        conversations = Dictionary(uniqueKeysWithValues: state.bots.map { bot in
            (bot.id, store.loadConversation(bot.id)?.closingInterruptedTurn() ?? Conversation())
        })
        selection = state.bots.first.map { .bot($0.id) }

        syncConnectors()
        scheduler = Task { [weak self] in
            await self?.refreshConnections()
            while !Task.isCancelled {
                self?.runDueRoutines()
                await self?.refreshAllModels()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, case .bot(let id) = self.selection { self.update(id) { $0.unread = 0 } }
            }
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
        if hasPendingApproval(botID) { return .waiting }
        if failed.contains(botID) { return .error }
        if celebrating.contains(botID) { return .happy }
        guard isWorking(botID) else { return .idle }
        if let kind = runningToolKind(botID) {
            switch kind {
            case .shell: return .typing
            case .browser, .computer: return .browsing
            case .file: return .reading
            case .search: return .searching
            case .connector, .memory: return .thinking
            }
        }
        return listening.contains(botID) ? .listening : .thinking
    }

    private func runningToolKind(_ botID: UUID) -> ToolCall.Kind? {
        for item in transcript(botID).reversed().prefix(3) {
            if case .tool(let call) = item.kind, call.state == .running { return call.kind }
        }
        return nil
    }

    private func hasPendingApproval(_ botID: UUID) -> Bool {
        transcript(botID).reversed().prefix(4).contains { item in
            if case .approval(let request) = item.kind { request.decision == nil } else { false }
        }
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
    /// it belongs to the user's Claude Code, not to OpenBot (see `signOutOfClaudeCode`).
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
        kind == .chatgpt ? try await ChatGPTAuth.shared.accessToken() : Keychain.get(kind.rawValue)
    }

    // MARK: Bots

    func createBot(name: String, role: String, orb: OrbConfig, model: String, mode: PermissionMode) {
        let bot = Bot(name: name, role: role, orb: orb, model: model, permissionMode: mode)
        conversations[bot.id] = Conversation()
        bots.append(bot)
        selection = .bot(bot.id)
    }

    func update(_ botID: UUID, _ change: (inout Bot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        var bot = bots[index]
        change(&bot)
        if bot != bots[index] { bots[index] = bot }
    }

    func deleteBot(_ botID: UUID) {
        stop(botID)
        bots.removeAll { $0.id == botID }
        routines.removeAll { $0.botID == botID }
        conversations[botID] = nil
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
        conversations[botID] = Conversation()
        drafts[botID] = ""
        scheduleConversationSave(botID, delay: 0)
    }

    private func remember(_ fact: String, for botID: UUID) {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update(botID) { bot in
            if !bot.memory.contains(where: { $0.text == text }) { bot.memory.append(MemoryFact(text: text)) }
        }
    }

    // MARK: Turns

    @ObservationIgnored private var didSendLaunchPrompt = false

    /// Dev aid for scripted end-to-end checks: `OPENBOT_SEND="texto"` sends it to the selected bot once,
    /// after the provider connections are known.
    func sendLaunchPrompt() {
        guard !didSendLaunchPrompt, let text = ProcessInfo.processInfo.environment["OPENBOT_SEND"],
              let id = selectedBot?.id else { return }
        didSendLaunchPrompt = true
        Task {
            await refreshConnections()
            send(text, to: id)
        }
    }

    func send(_ text: String, attachments: [URL] = [], to botID: UUID) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, turns[botID] == nil, let bot = bot(botID) else { return }
        guard let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else {
            append(.notice("Conecte um modelo em Ajustes → Modelos para começar."), to: botID)
            return
        }
        let modelInfo = account.models.first { $0.id == ref.model }

        append(.user(text: typed, attachments: attachments.map(\.lastPathComponent)), to: botID)
        drafts[botID] = ""
        statusLine[botID] = "Pensando"
        pokes[botID, default: 0] += 1
        flash(\.listening, botID, seconds: 1.4)

        var prompt = typed
        if let expansion = SystemPrompt.expandSkill(in: typed, skills: enabledSkills) {
            prompt = expansion.prompt
            if let index = skills.firstIndex(where: { $0.id == expansion.skill.id }) { skills[index].uses += 1 }
        }
        if !attachments.isEmpty {
            prompt += "\n\nAttached files (read them with your tools):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        if ref.provider == .claudeCode {
            runClaudeCode(bot, model: ref.model, prompt: prompt)
            return
        }
        let system = SystemPrompt.make(bot: bot, skills: enabledSkills)
        let history = (conversations[botID]?.messages ?? []).modelContext()
        let context = ToolContext(workingDirectory: bot.workingURL) { [weak self] fact in
            await self?.remember(fact, for: botID)
        }

        turns[botID] = Task {
            let client: any LLMClient
            do {
                guard let made = account.client(for: modelInfo, token: try await token(for: ref.provider),
                                                 conversationID: botID.uuidString) else { throw LLMError.notConfigured }
                client = made
            } catch {
                apply(.failed(error.localizedDescription), to: botID)
                finishTurn(botID, succeeded: false)
                return
            }
            var tools = ToolBox.all.filter { $0.capability.map(bot.capabilities.contains) ?? true }
            if bot.capabilities.contains(.connectors) { tools += await mcp.tools() }
            let request = TurnRequest(bot: bot, model: ref.model, system: system, history: history, prompt: prompt,
                                      client: client, tools: tools, context: context)
            await play(engine.run(request), for: botID)
        }
    }

    /// A turn run by the user's Claude Code, continuing the conversation's Claude Code session.
    private func runClaudeCode(_ bot: Bot, model: String, prompt: String) {
        let botID = bot.id
        let sessionID = conversations[botID]?.claudeSessionID
        let system = ClaudeCodePrompt.make(bot: bot, skills: enabledSkills)
        let servers = bot.capabilities.contains(.connectors) ? connectors.filter(\.isEnabled) : []
        claudeTurns.insert(botID)
        turns[botID] = Task {
            guard let installation = await ClaudeCode.shared.installation() else {
                apply(.failed("O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos."), to: botID)
                finishTurn(botID, succeeded: false)
                return
            }
            let turn = ClaudeCodeTurn(bot: bot, executable: installation.executable, model: model, system: system,
                                      prompt: prompt, sessionID: sessionID, connectors: servers,
                                      environment: await ClaudeCode.shared.environment(for: installation))
            await play(claudeEngine.run(turn), for: botID)
        }
    }

    private func play(_ events: AsyncStream<TurnEvent>, for botID: UUID) async {
        var succeeded = true
        for await event in events {
            // A stopped stream still delivers queued events; `stop` already closed the turn.
            guard !Task.isCancelled else { break }
            if case .failed = event { succeeded = false }
            apply(event, to: botID)
        }
        if !Task.isCancelled { finishTurn(botID, succeeded: succeeded) }
    }

    func stop(_ botID: UUID) {
        guard let task = turns[botID] else { return }
        task.cancel()
        if claudeTurns.contains(botID) {
            Task { await claudeEngine.cancelApprovals(for: botID) }
        } else {
            Task { await engine.cancelApprovals(for: botID) }
        }
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.decision == nil {
                    request.decision = .deny
                    items[index].kind = .approval(request)
                }
            }
        }
        append(.notice("Você interrompeu esta resposta"), to: botID)
        finishTurn(botID, succeeded: false)
    }

    func decide(_ decision: ApprovalDecision, approvalID: UUID, botID: UUID) {
        var toolName: String?
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    toolName = request.toolName
                    items[index].kind = .approval(request)
                }
            }
        }
        if decision == .always, let toolName {
            update(botID) { $0.allowedTools.insert(toolName) }
        }
        if claudeTurns.contains(botID) {
            Task { await claudeEngine.resolve(approvalID: approvalID, decision: decision) }
        } else {
            Task { await engine.resolve(approvalID: approvalID, decision: decision) }
        }
    }

    private func apply(_ event: TurnEvent, to botID: UUID) {
        switch event {
        case .status(let text):
            statusLine[botID] = text
        case .text(let delta):
            mutateItems(of: botID) { items in
                if let last = items.indices.last, case .bot(let text, true) = items[last].kind {
                    items[last].kind = .bot(text: text + delta, isStreaming: true)
                } else {
                    items.append(TranscriptItem(.bot(text: delta.trimmingCharacters(in: .newlines), isStreaming: true)))
                }
            }
        case .toolStarted(let call):
            closeStreaming(botID)
            append(.tool(call), to: botID)
        case .toolFinished(let id, let state, let output):
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
            closeStreaming(botID)
            append(.approval(request), to: botID)
            if let bot = bot(botID) { notify(bot.name, "Precisa da sua permissão: \(request.title.lowercased())") }
        case .message(let message):
            conversations[botID, default: Conversation()].messages.append(message)
        case .failed(let message):
            closeStreaming(botID)
            append(.notice("Não deu certo: \(message)"), to: botID)
        case .session(let id):
            conversations[botID, default: Conversation()].claudeSessionID = id.isEmpty ? nil : id
            scheduleConversationSave(botID, delay: 1)
        }
    }

    private func finishTurn(_ botID: UUID, succeeded: Bool = true) {
        guard turns[botID] != nil else { return }
        turns[botID] = nil
        claudeTurns.remove(botID)
        closeStreaming(botID)
        statusLine[botID] = nil
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
        if selection != .bot(botID) || !NSApp.isActive {
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

    private func closeStreaming(_ botID: UUID) {
        guard let last = conversations[botID]?.items.last, case .bot(let text, true) = last.kind else { return }
        mutateItems(of: botID) { items in
            items[items.count - 1].kind = .bot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isStreaming: false)
        }
    }

    private func append(_ kind: TranscriptItem.Kind, to botID: UUID) {
        mutateItems(of: botID) { $0.append(TranscriptItem(kind)) }
    }

    private func mutateItems(of botID: UUID, _ change: (inout [TranscriptItem]) -> Void) {
        change(&conversations[botID, default: Conversation()].items)
        scrollTick[botID, default: 0] += 1
        scheduleConversationSave(botID, delay: 1)
    }

    // MARK: Routines

    func runRoutine(_ routineID: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        let routine = routines[index]
        guard !isWorking(routine.botID), bot(routine.botID) != nil else { return }
        routines[index].lastRun = .now
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
        guard !NSApp.isActive, Self.notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
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

    private func scheduleConversationSave(_ botID: UUID, delay: Double) {
        conversationSaves[botID]?.cancel()
        conversationSaves[botID] = Task { [store] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let conversation = conversations[botID] else { return }
            store.save(conversation, for: botID)
        }
    }

    /// Writes everything and waits for the disk (on quit).
    func saveNow() {
        store.save(state)
        for (id, conversation) in conversations { store.save(conversation, for: id) }
        store.flush()
    }
}
