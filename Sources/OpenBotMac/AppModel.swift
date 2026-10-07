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
    var provider: ProviderConfig { didSet { scheduleStateSave() } }
    /// Model ids last fetched from the provider.
    var models: [String] { didSet { scheduleStateSave() } }
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
    private(set) var hasAPIKey: Bool
    var selection: SidebarItem? {
        didSet {
            if case .bot(let id) = selection { update(id) { $0.unread = 0 } }
        }
    }

    // MARK: Services

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let engine = AgentEngine()
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
        provider = state.provider
        models = state.models
        conversations = Dictionary(uniqueKeysWithValues: state.bots.map { ($0.id, store.loadConversation($0.id) ?? Conversation()) })
        hasAPIKey = Keychain.key(for: state.provider.preset) != nil
        selection = state.bots.first.map { .bot($0.id) }

        syncConnectors()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDueRoutines()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    // MARK: Queries

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    var selectedBot: Bot? {
        if case .bot(let id) = selection { bot(id) } else { nil }
    }

    func transcript(_ botID: UUID) -> [TranscriptItem] { conversations[botID]?.items ?? [] }

    func isWorking(_ botID: UUID) -> Bool { turns[botID] != nil }

    func routines(for botID: UUID) -> [Routine] { routines.filter { $0.botID == botID } }

    /// The model a bot actually uses (its own or the provider default).
    func modelID(for bot: Bot) -> String { bot.model.isEmpty ? provider.defaultModel : bot.model }

    /// True when a model can be called: base URL, key (if the provider needs one) and a default model.
    var isProviderReady: Bool {
        URL(string: provider.baseURL)?.host != nil && (hasAPIKey || !provider.preset.needsKey) && !provider.defaultModel.isEmpty
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

    // MARK: Provider

    func setAPIKey(_ key: String) {
        Keychain.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.preset)
        hasAPIKey = Keychain.key(for: provider.preset) != nil
    }

    func selectPreset(_ preset: ProviderPreset) {
        provider = ProviderConfig(preset: preset, baseURL: preset.defaultBaseURL)
        models = []
        hasAPIKey = Keychain.key(for: preset) != nil
    }

    private func makeClient() -> (any LLMClient)? {
        guard let url = URL(string: provider.baseURL), url.host != nil else { return nil }
        return OpenAIClient(baseURL: url, apiKey: Keychain.key(for: provider.preset))
    }

    /// Fetches the provider's models; picks a default model if none is set.
    func refreshModels() async throws {
        guard let client = makeClient() else { throw LLMError.notConfigured }
        let fetched = try await client.models()
        models = fetched
        if provider.defaultModel.isEmpty || !fetched.contains(provider.defaultModel), let first = fetched.first {
            provider.defaultModel = first
        }
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

    func send(_ text: String, attachments: [URL] = [], to botID: UUID) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, turns[botID] == nil, let bot = bot(botID) else { return }
        guard isProviderReady, let client = makeClient() else {
            append(.notice("Conecte um modelo em Ajustes → Modelo para começar."), to: botID)
            return
        }

        append(.user(text: typed, attachments: attachments.map(\.lastPathComponent)), to: botID)
        drafts[botID] = ""
        statusLine[botID] = "Pensando"
        pokes[botID, default: 0] += 1
        flash(\.listening, botID, seconds: 1.4)

        var prompt = typed
        if let expansion = SystemPrompt.expandSkill(in: typed, skills: skills) {
            prompt = expansion.prompt
            if let index = skills.firstIndex(where: { $0.id == expansion.skill.id }) { skills[index].uses += 1 }
        }
        if !attachments.isEmpty {
            prompt += "\n\nAttached files (read them with your tools):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        let system = SystemPrompt.make(bot: bot, skills: skills)
        let history = conversations[botID]?.messages ?? []
        let model = modelID(for: bot)
        let context = ToolContext(workingDirectory: bot.workingURL) { [weak self] fact in
            await self?.remember(fact, for: botID)
        }

        turns[botID] = Task {
            var tools = ToolBox.all.filter { $0.capability.map(bot.capabilities.contains) ?? true }
            if bot.capabilities.contains(.connectors) { tools += await mcp.tools() }
            let request = TurnRequest(bot: bot, model: model, system: system, history: history, prompt: prompt,
                                      client: client, tools: tools, context: context)
            for await event in engine.run(request) {
                apply(event, to: botID)
            }
            finishTurn(botID)
        }
    }

    func stop(_ botID: UUID) {
        guard let task = turns[botID] else { return }
        task.cancel()
        Task { await engine.cancelApprovals(for: botID) }
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
        Task { await engine.resolve(approvalID: approvalID, decision: decision) }
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
            flash(\.failed, botID, seconds: 2.5)
        }
    }

    private func finishTurn(_ botID: UUID, succeeded: Bool = true) {
        guard turns[botID] != nil else { return }
        turns[botID] = nil
        closeStreaming(botID)
        statusLine[botID] = nil
        let reply = lastReply(botID)
        if let routineID = routineTurns.removeValue(forKey: botID),
           let index = routines.firstIndex(where: { $0.id == routineID }) {
            routines[index].lastResult = succeeded ? reply.map { String($0.prefix(160)) } : "Interrompida"
        }
        if succeeded && !failed.contains(botID) {
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
        AppState(bots: bots, routines: routines, skills: skills, connectors: connectors, provider: provider, models: models)
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

    /// Writes everything immediately (on quit).
    func saveNow() {
        store.save(state)
        for (id, conversation) in conversations { store.save(conversation, for: id) }
    }
}
