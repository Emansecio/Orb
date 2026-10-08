import SwiftUI
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    // MARK: Persisted state

    var bots: [Bot] { didSet { scheduleStateSave(); syncLives() } }
    var routines: [Routine] { didSet { scheduleStateSave(); queueFollowsEdits(from: oldValue) } }
    var skills: [Skill] { didSet { scheduleStateSave() } }
    var connectors: [MCPServerConfig] { didSet { scheduleStateSave(); syncConnectors() } }
    /// Providers the user set up, with their last fetched model lists.
    var providers: [ProviderAccount] { didSet { scheduleStateSave() } }
    /// "provider/model" for bots without a model of their own.
    var defaultModel: String { didSet { scheduleStateSave() } }
    /// How much conversation the Orbs remember word for word before the start is folded into a summary.
    var contextMemory: ContextMemoryLevel { didSet { scheduleStateSave() } }
    /// Each Orb's running machinery (see `BotSession`): its conversation in memory, its turn, its streamed reply.
    /// Conversations: at launch only the selected Orb's is read (off the main thread, `beginLoading`); the others are
    /// read when they are needed (`BotSession.isUnloaded`): when you switch to the Orb, or something has to change
    /// its conversation (`ensureLoaded`). One nobody has looked at for a while and that has nothing left to save goes
    /// back to disk (`unloadIdleConversations`). Not observed itself: a session is made with its Orb (`syncLives`)
    /// and views read the session's own observed properties.
    @ObservationIgnored private(set) var sessions: [UUID: BotSession] = [:]
    /// Earlier conversations of each Orb as last listed (see `loadArchive`).
    private(set) var archives: [UUID: [ConversationSummary]] = [:]
    /// Routines that came due while their Orb was busy; each runs when the Orb is free. One entry per routine.
    private(set) var queuedRoutines: [UUID] = []
    /// Archived conversations being read to be reopened, and the routine each Orb is reading its conversation for
    /// before starting it (at most one per Orb): a second request for either waits for that one.
    @ObservationIgnored private var reopening: Set<UUID> = []
    @ObservationIgnored private var startingRoutines: [UUID: UUID] = [:]
    var isStartingRoutine: Bool { !startingRoutines.isEmpty } // internal for tests
    /// Things the user should hear about the data files (an unreadable file and where its copy is, a failed save).
    /// The first one is shown as an alert; `dismissDataNotice` moves on to the next.
    private(set) var dataNotices: [StoreNotice] = []

    // MARK: UI state

    var drafts: [UUID: String] = [:]
    var showInspector = true
    var showNewBot = false
    // Commands and shortcuts (see AppModel+Commands.swift).
    var showCommandPalette = false
    var showShortcuts = false
    /// The Orb whose "Apagar…" sheet is open (one dialog for the sidebar and the inspector).
    var deletingBotID: UUID?
    /// The edit sheets that are on screen right now (each registers itself, see `registersOpenSheet`). Tokens rather
    /// than a bare count: a sheet that reports twice still counts once, and one that goes away takes its entry along.
    var openSheetTokens: Set<UUID> = []
    /// "Memória de X guardada", shown in the sidebar for a few seconds after deleting an Orb and keeping its memory.
    var keptMemoryNotice: KeptMemoryNotice?
    /// Something a command asked of an Orb's chat that the chat takes when it is on screen (see `PendingChatRequest`).
    var pendingChatRequest: PendingChatRequest?
    /// The routine whose conversation the Routines page opens when it appears (a routine waiting for an answer: "Ver pedido",
    /// a tap on its banner). Taken by the page, like `pendingChatRequest`.
    var routineToShow: UUID?
    /// The "Esqueceu isso. Desfazer" of the memory screens: here so it outlives the panel being rebuilt (switching Orbs).
    @ObservationIgnored let memoryUndo = MemoryUndo()
    var connectorStatus: [UUID: MCPStatus] = [:]
    /// Providers with a key in the Keychain (or, for ChatGPT and Claude Code, a sign-in).
    private(set) var connected: Set<ProviderKind> = []
    /// What the local Claude Code reports (checked while that provider is set up).
    private(set) var claudeCode = ClaudeCodeStatus()
    /// Counts the times you tried to send before any model was connected (the first-use card pulses on each).
    private(set) var setupNudge = 0

    // MARK: Per-Orb live state

    /// The Orbs in sidebar order. Changes only when an Orb is added, deleted or moved, so a list that shows one
    /// view per Orb (sidebar, menu bar, Orbs menu) re-renders then and not when an Orb's own state changes.
    private(set) var botIDs: [UUID] = []
    /// The Orbs working right now and the ones waiting for an answer, in sidebar order (the menu bar lists them).
    private(set) var workingIDs: [UUID] = []
    private(set) var waitingIDs: [UUID] = []
    /// One observable object per Orb (see `BotLive`). Not observed itself: the Orbs it holds change with `bots`.
    @ObservationIgnored private var lives: [UUID: BotLive] = [:]
    /// The Orb the user was last on (what "Usar" on a skill talks to, while a catalog page is open).
    private(set) var lastSelectedBotID: UUID?
    var selection: SidebarItem? {
        didSet {
            if case .bot(let id) = selection { lastSelectedBotID = id }
            if case .bot(let old) = oldValue, let left = sessions[old], left.conversation != nil { left.lastUsed = .now } // leaving it: the clock starts now
            if case .bot(let id) = selection {
                beginLoading(id)
                session(id).lastUsed = .now
                setUnread(0, for: id)
                if selection != oldValue { liveBot(id)?.glanced() } // its sidebar Orb glances toward the chat
            }
        }
    }

    // MARK: Services

    @ObservationIgnored private(set) var store: Store
    /// Pictures attached to messages and returned by tools (`anexos/<id>/` in the data folder).
    @ObservationIgnored let images: ImageStore
    /// Models ("provider/model") that answered that they cannot read pictures, so later turns do not try again.
    @ObservationIgnored private var visionRejected: Set<String> = []
    /// Context windows learned from refusals ("provider/model"); they shrink the history budget of that model.
    @ObservationIgnored private(set) var learnedContexts: [String: LearnedContext]
    /// Where outputs too big for a conversation are saved for the model to read back (`saidas/<id>/` in the data folder).
    @ObservationIgnored let outputsDirectory: URL
    /// Every Orb's own memory bank (`memoria/<id>/` in the data folder).
    @ObservationIgnored let memory: MemoryLibrary
    /// The approval cards open in any turn, whichever engine runs it (internal so tests can open cards).
    @ObservationIgnored let gate: ApprovalGate
    @ObservationIgnored private let engine: AgentEngine
    @ObservationIgnored private let claudeEngine: ClaudeCodeEngine
    @ObservationIgnored let mcp = MCPManager()
    /// Keeps the tokens of connectors in the Keychain instead of the data file.
    @ObservationIgnored let connectorSecrets: ConnectorSecrets
    /// The syncs of connectors, one after another: waiting for the last one means every connector has started or failed.
    @ObservationIgnored private var connectorSync: Task<Void, Never>?
    /// Syncs started and not yet finished, the newest one's number, and how each connector ended in it: what
    /// `connectAndWait` reads, so one connector's answer does not wait for the others.
    @ObservationIgnored private var pendingConnectorSyncs = 0
    @ObservationIgnored private var connectorSyncGeneration = 0
    @ObservationIgnored private var settledConnectors: [UUID: MCPStatus] = [:]
    /// Processes the Orbs left running with `run_command(background: true)`.
    @ObservationIgnored private let jobs = BackgroundJobs()
    /// Stands in for the provider's client (tests).
    /// Where "the home folder" is, for deciding whether an Orb's folder is its own (tests point it elsewhere).
    @ObservationIgnored var homeFolder = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored var clientOverride: (@MainActor () -> (any LLMClient)?)?
    /// Whether macOS trusts the app for Accessibility, read when a turn starts (tests replace it).
    @ObservationIgnored var accessibilityProbe: @Sendable () -> Bool = { LiveMacPermissionSystem().isAccessibilityTrusted() }
    @ObservationIgnored private var stateSave: Task<Void, Never>?
    /// How long a conversation nobody is looking at stays in memory (tests shorten it).
    @ObservationIgnored var conversationKeepAlive = Duration.seconds(300)
    @ObservationIgnored private var didReportSaveFailure = false
    /// The Keychain reads of a `refreshConnections` under way, and which state of the Keychain they started from
    /// (`keychainGeneration` changes when the app itself changes a key).
    @ObservationIgnored private var keyReads: (generation: Int, task: Task<Set<ProviderKind>, Never>)?
    @ObservationIgnored private var keychainGeneration = 0
    @ObservationIgnored private(set) var scheduler: Task<Void, Never>?
    /// Whether this is a developer mode (`--snapshot`, `--render-*`): it draws and exits, so nothing with an effect
    /// outside the process runs in it, not even over a data folder with routines or connectors (see `DevRun`).
    @ObservationIgnored private let isDevRun: Bool

    /// `runsBackgroundWork: false` skips the scheduler, Keychain checks and app-wide observers (tests).
    /// `devRun` (the process's own mode unless given) also skips the scheduler, the connectors' servers and the
    /// Claude Code check, whatever `runsBackgroundWork` says.
    /// `asyncLoading` says whether the first Orb's conversation is read off the main thread after `init` returns
    /// (the window does not wait for it; the app) or before it returns (what tests rely on); it follows
    /// `runsBackgroundWork` unless given.
    init(store: Store = .standard, runsBackgroundWork: Bool = true, asyncLoading: Bool? = nil, secretVault: (any SecretVault)? = nil,
         devRun: Bool = DevRun.isActive) {
        self.store = store
        isDevRun = devRun
        let secrets = ConnectorSecrets(vault: secretVault ?? (runsBackgroundWork && !devRun ? KeychainVault() : MemoryVault()))
        connectorSecrets = secrets
        images = ImageStore(dataFolder: store.directory)
        let gate = ApprovalGate()
        self.gate = gate
        engine = AgentEngine(gate: gate)
        claudeEngine = ClaudeCodeEngine(gate: gate)
        memory = MemoryLibrary.at(store.directory.appending(path: "memoria"))
        var notices: [StoreNotice] = []
        let stateRead = store.readState()
        notices += stateRead.notice.map { [Self.described($0, bots: [], routines: [])] } ?? []
        let state = stateRead.value ?? .initial
        bots = state.bots
        routines = state.routines
        skills = state.skills
        connectors = secrets.resolve(state.connectors)
        providers = state.providers
        defaultModel = state.defaultModel
        contextMemory = state.contextMemory
        learnedContexts = state.learnedContexts
        outputsDirectory = ToolOutputCap.directory(inDataFolder: store.directory)
        // Only the Orb shown first is read at launch, and the window does not wait for it (`beginLoading` below).
        let readsFirstLater = asyncLoading ?? runsBackgroundWork
        for bot in state.bots { session(bot.id).isUnloaded = true }
        if !readsFirstLater, let first = state.bots.first {
            let read = store.readConversation(first.id)
            notices += Self.labeled(read.notice, for: first).map { [$0] } ?? []
            let shown = session(first.id)
            shown.conversation = read.value?.closingInterruptedTurn() ?? Conversation()
            shown.isUnloaded = false
            shown.lastUsed = .now
        }
        dataNotices = notices
        selection = state.bots.first.map { .bot($0.id) }
        self.store.onSaveFailure = { [weak self] notice in
            Task { @MainActor in self?.reportSaveFailure(notice) }
        }

        syncLives()
        for (id, count) in state.unread {
            if let id = UUID(uuidString: id) { live(id).setUnread(count) }
        }
        syncConnectors()
        // Tokens an older version left in the data file move to the Keychain with the next save.
        if secrets.hasUnprotectedSecrets(connectors) { scheduleStateSave() }
        if readsFirstLater, let first = state.bots.first { beginLoading(first.id) }
        guard runsBackgroundWork else { return }
        let outputs = outputsDirectory
        // A developer run shares the user's $TMPDIR (`ORB_DATA_DIR` only moves the data), so it leaves alone what a running app wrote.
        let cleansTemporaryFiles = !DevRun.isActive
        Task.detached(priority: .utility) {
            ToolOutputCap.cleanUp(directory: outputs)
            if cleansTemporaryFiles { ClaudeCodeEngine.removeStaleMCPConfigs() }
        }
        ApprovalNotifications.clearStale()
        ApprovalNotifications.install { [weak self] route in self?.handle(route) }
        Task { [weak self] in await self?.prepareMemory() }
        // No routines, connections or model lists in a developer mode: a copy of real data must not set real work going.
        if !devRun {
            scheduler = Task { [weak self] in
                await self?.refreshConnections()
                while !Task.isCancelled {
                    self?.runDueRoutines()
                    await self?.refreshAllModels()
                    await self?.unloadIdleConversations()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                ApprovalNotifications.clear(self?.pendingApprovals.map(\.id) ?? [])
                self?.saveNow()
                self?.jobs.killAllNow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, case .bot(let id) = self.selection {
                    self.setUnread(0, for: id)
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
        dataNotices.append(Self.described(notice, bots: bots, routines: routines))
    }

    /// The notice with its file named for the user: what the file holds (a conversation, the app's settings) instead
    /// of `<UUID>.json` or `state.json`. A file it can't place keeps its name.
    nonisolated static func described(_ notice: StoreNotice, bots: [Bot], routines: [Routine]) -> StoreNotice {
        guard let file = notice.file, let subject = subject(of: file, bots: bots, routines: routines) else { return notice }
        var notice = notice
        notice.message = notice.message.replacingOccurrences(of: "“\(file.lastPathComponent)”", with: subject)
        return notice
    }

    private nonisolated static func subject(of file: URL, bots: [Bot], routines: [Routine]) -> String? {
        let name = file.lastPathComponent, folder = file.deletingLastPathComponent().lastPathComponent
        guard name.hasSuffix(".json") else { return nil }
        if name == "state.json" { return "os ajustes do app (Orbs, rotinas, provedores)" }
        let stem = String(name.dropLast(".json".count))
        if folder == "conversations", let id = UUID(uuidString: stem) {
            return bots.first { $0.id == id }.map { "a conversa de \($0.name)" }
        }
        // Inside an Orb's folder of earlier conversations: `<conversationID>`, `routine-<routineID>` or `index`.
        guard let owner = UUID(uuidString: folder).flatMap({ id in bots.first { $0.id == id } }) else { return nil }
        if stem == "index" { return "a lista de conversas antigas de \(owner.name)" }
        if stem.hasPrefix("routine-"), let id = UUID(uuidString: String(stem.dropFirst("routine-".count))) {
            return routines.first { $0.id == id }.map { "o histórico da rotina \($0.name)" } ?? "o histórico de uma rotina de \(owner.name)"
        }
        return UUID(uuidString: stem) == nil ? nil : "uma conversa antiga de \(owner.name)"
    }

    /// Reads the Orb's conversation now if it isn't in memory (see `BotSession.ensureLoaded`).
    func ensureLoaded(_ botID: UUID) { sessions[botID]?.ensureLoaded() }

    /// Starts reading the Orb's conversation off the main thread if it isn't in memory (see `BotSession.beginLoading`).
    @discardableResult
    private func beginLoading(_ botID: UUID) -> Task<Void, Never>? { sessions[botID]?.beginLoading() }

    /// Waits until the Orb's conversation is in memory, reading it off the main thread if it is not.
    func loadedConversation(_ botID: UUID) async {
        guard bot(botID) != nil, let task = beginLoading(botID) ?? sessions[botID]?.loadTask else { return }
        await task.value
    }

    /// Whether the chat should show that the conversation is still on its way.
    func isLoadingConversation(_ botID: UUID) -> Bool { sessions[botID]?.isLoading ?? false }

    /// Reads every conversation not in memory now. Testing only: the app reads them when they are needed.
    func loadRemainingConversations() async {
        for bot in bots where sessions[bot.id]?.isUnloaded == true { await loadedConversation(bot.id) }
    }

    /// Lets go of conversations nobody is looking at: not the selected Orb's, not one that is working, parked by a
    /// routine, or waiting to be saved, and not one used within `conversationKeepAlive`. Only when the file on disk
    /// is known to hold what is in memory (the note beside it says so), and never after a failed save, when memory
    /// may be the only copy. A conversation that comes back is read again from its file, off the main thread.
    func unloadIdleConversations(now: ContinuousClock.Instant = .now, only: UUID? = nil) async {
        guard !didReportSaveFailure else { return }
        let keepAlive = conversationKeepAlive
        let candidates = sessions.values.filter { (only == nil || $0.id == only) && $0.isIdle(now: now, keepAlive: keepAlive) }
        for session in candidates {
            let botID = session.id
            guard let meta = await store.readMetaAsync(botID) else { continue }
            // Looked at again after waiting: it may have been used, changed or started a turn meanwhile.
            guard sessions[botID] === session, session.isIdle(now: now, keepAlive: keepAlive),
                  let conversation = session.conversation, meta.matches(conversation) else { continue }
            session.unload()
            store.releaseCache(for: botID)
        }
    }

    /// The same message is never queued twice (a file read from two places at once reports the same thing).
    func addNotice(_ notice: StoreNotice?) {
        guard let notice, !dataNotices.contains(notice) else { return }
        dataNotices.append(notice)
    }

    /// Tells which Orb a notice is about: the file name alone (`<UUID>.json`) doesn't.
    static func labeled(_ notice: StoreNotice?, for bot: Bot?) -> StoreNotice? {
        guard var notice, let bot else { return notice }
        notice.message = "Conversa de \(bot.name): \(notice.message)"
        return notice
    }

    // MARK: Queries

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    var selectedBot: Bot? {
        if case .bot(let id) = selection { bot(id) } else { nil }
    }

    /// The user's chat (not a running routine's conversation, which `conversations` holds meanwhile). The reply
    /// being streamed is in it as it began; `liveText(for:of:)` has its text.
    func transcript(_ botID: UUID) -> [TranscriptItem] {
        guard let session = sessions[botID] else { return [] }
        return session.transcript?.items ?? session.shownItems
    }

    /// The chat of one Orb as its view reads it. Observed on its own: a change in another Orb's conversation, or
    /// in this one's streamed text, does not touch it.
    func orbTranscript(_ botID: UUID) -> OrbTranscript { session(botID).makeTranscript() }

    /// The text of `itemID` while it streams (nil for any other item, and once the reply is closed).
    func liveText(for itemID: UUID, of botID: UUID) -> LiveText? {
        guard let live = sessions[botID]?.liveText, live.itemID == itemID else { return nil }
        return live
    }

    /// Observable per Orb (the status line is set for exactly as long as a turn runs).
    func isWorking(_ botID: UUID) -> Bool { live(botID).isWorking }

    func routines(for botID: UUID) -> [Routine] { routines.filter { $0.botID == botID } }

    var enabledSkills: [Skill] { skills.filter(\.isEnabled) }

    /// The model a bot actually uses: its own or the default ("provider/model").
    func modelRef(for bot: Bot) -> ModelRef? { ModelRef(bot.model.isEmpty ? defaultModel : bot.model) }

    /// Short model name for the UI ("" when none is set).
    func modelName(for bot: Bot) -> String { modelName(forModel: bot.model) }

    /// The same for a bot's `model` string alone (views that show nothing else of the bot).
    func modelName(forModel model: String) -> String {
        guard let ref = ModelRef(model.isEmpty ? defaultModel : model) else { return "" }
        return account(ref.provider)?.models.first { $0.id == ref.model }?.name ?? ref.model
    }

    /// True when the default model's provider is set up and usable.
    var isProviderReady: Bool {
        guard let ref = ModelRef(defaultModel), let account = account(ref.provider) else { return false }
        return account.isEnabled && isUsable(account)
    }

    /// What the bot's Orb is doing right now (expression, gaze and motion follow this).
    func activity(for botID: UUID) -> OrbActivity { live(botID).activity }

    // MARK: Per-Orb live state

    /// The Orb's running machinery, made when first asked for (every Orb has one from the moment it exists; an
    /// unknown id, such as a late write for an Orb just deleted, gets one too, as the dictionaries it replaced did).
    func session(_ botID: UUID) -> BotSession {
        if let session = sessions[botID] { return session }
        let session = BotSession(id: botID, model: self)
        sessions[botID] = session
        return session
    }

    /// The conversations in memory, by Orb (a routine's while it runs). A view over the sessions, for tests and the
    /// few places that look at all of them; the app reads and changes one Orb's through its session.
    var conversations: [UUID: Conversation] { sessions.compactMapValues { $0.conversation } }

    /// Each Orb's running turn and its id (views over the sessions, read by tests).
    var turns: [UUID: Task<Void, Never>] { sessions.compactMapValues { $0.turnTask } }
    var turnIDs: [UUID: UUID] { sessions.compactMapValues { $0.turnID } }
    /// Bot id → routine id, for turns started by a routine.
    var routineTurns: [UUID: UUID] { sessions.compactMapValues { $0.routineID } }
    /// Bots whose running turn belongs to Claude Code.
    var claudeTurns: Set<UUID> { Set(sessions.values.filter(\.isClaudeTurn).map(\.id)) }
    /// The snapshot and rules marks of each running turn (see `BotSession.pendingMarks`).
    var pendingMarks: [UUID: DeliveryMarks] { sessions.compactMapValues { $0.pendingMarks } }
    /// Tokens each Orb's last turn used, its latest model call alone, and its latest compaction (for the context
    /// meter). Views over the sessions: a view showing one Orb reads `session(id)` instead, which is observed on its own.
    var usage: [UUID: TokenUsage] { sessions.compactMapValues { $0.usage } }
    var requestUsage: [UUID: TokenUsage] { sessions.compactMapValues { $0.requestUsage } }
    var lastCompaction: [UUID: CompactionReport] { sessions.compactMapValues { $0.lastCompaction } }

    /// The Orb's live state. Views read this (and only this) for the Orb they show. An unknown id (an Orb that was
    /// just deleted) gets a stand-in nothing is attached to, so a late write or a view still on screen is harmless.
    func live(_ id: UUID) -> BotLive {
        lives[id] ?? BotLive(Bot(id: id, name: "", role: "", orb: OrbConfig()))
    }

    /// The live state of an Orb that exists; nil once it is deleted. Reads the list of Orbs, which changes only
    /// when one is added or deleted, so a view that checks this still depends on no other Orb's state.
    func liveBot(_ id: UUID) -> BotLive? { botIDs.contains(id) ? lives[id] : nil }

    /// Brings the per-Orb objects in line with `bots`: new Orbs get one, deleted Orbs lose theirs, and an Orb whose
    /// settings changed publishes that to its own object only.
    private func syncLives() {
        for bot in bots {
            if let existing = lives[bot.id] { existing.update(bot) } else { lives[bot.id] = BotLive(bot) }
            _ = session(bot.id) // made with the Orb, so a view that reads it from the start sees its changes
        }
        if lives.count != bots.count { lives = lives.filter { id, _ in bots.contains { $0.id == id } } }
        assign(\.botIDs, to: bots.map(\.id))
        refreshPresence()
    }

    /// The lists of working and waiting Orbs, after a status or an approval card changed.
    private func refreshPresence() {
        assign(\.workingIDs, to: botIDs.filter { lives[$0]?.isWorking == true })
        assign(\.waitingIDs, to: botIDs.filter { lives[$0]?.needsYou == true })
    }

    func setStatus(_ text: String?, of botID: UUID) {
        let live = live(botID)
        let was = live.isWorking
        live.setStatus(text)
        if live.isWorking != was { refreshPresence() }
    }

    func setAwaitingApproval(_ isWaiting: Bool, of botID: UUID) {
        let live = live(botID)
        let was = live.needsYou
        live.setAwaitingApproval(isWaiting)
        if live.needsYou != was { refreshPresence() }
    }

    /// The unread count is saved with the app's state, so a change schedules a save.
    func setUnread(_ count: Int, for botID: UUID) {
        let live = live(botID)
        guard live.unread != count else { return }
        live.setUnread(count)
        scheduleStateSave()
    }

    /// The draft in the composer, kept per Orb. Writing what is already there does nothing (no draft counts as "").
    /// An emptied draft (sent, cleared) also ends the Orb's watching you type; other changes made by the app (a
    /// queued message given back, a skill inserted) do not start it.
    func setDraft(_ text: String, for botID: UUID) {
        if text.isEmpty { liveBot(botID)?.stopComposing() }
        guard drafts[botID, default: ""] != text else { return }
        drafts[botID] = text
    }

    /// You changed the draft in the composer (typing, completing a `/skill`, dropping a file's name in): it is kept,
    /// and the Orb watches you type until you pause (see `BotLive.noteComposing`).
    func editDraft(_ text: String, for botID: UUID) {
        setDraft(text, for: botID)
        liveBot(botID)?.noteComposing(draftIsEmpty: text.isEmpty)
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
        keychainGeneration += 1
        Keychain.set("", account: kind.rawValue)
        if kind == .chatgpt { Task { await ChatGPTAuth.shared.signOut() } }
        if connected.contains(kind) { connected.remove(kind) }
        updateProvider(kind) { $0.models = [] }
    }

    func updateProvider(_ kind: ProviderKind, _ change: (inout ProviderAccount) -> Void) {
        guard let index = providers.firstIndex(where: { $0.kind == kind }) else { return }
        change(&providers[index])
    }

    /// Saves (or, when empty, removes) the provider's key and reloads its models.
    func setKey(_ key: String, for kind: ProviderKind) async throws {
        keychainGeneration += 1
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
        var found = await keyedProviders()
        if await ChatGPTAuth.shared.credential != nil { found.insert(.chatgpt) }
        if !isDevRun, account(.claudeCode) != nil { // the status runs the real `claude`
            claudeCode = await ClaudeCode.shared.status()
            if claudeCode.isLoggedIn { found.insert(.claudeCode) }
        }
        connected = found
    }

    /// Providers with a key in the Keychain. Each read takes milliseconds (and the system may ask permission for an
    /// item another app made), so they run off the main thread; a refresh asked for while another is under way
    /// (launch asks from more than one place) shares its reads instead of repeating them.
    private func keyedProviders() async -> Set<ProviderKind> {
        if let running = keyReads, running.generation == keychainGeneration { return await running.task.value }
        let generation = keychainGeneration
        let task = Task.detached(priority: .userInitiated) {
            Set(ProviderKind.allCases.filter { $0.needsKey && Keychain.get($0.rawValue) != nil })
        }
        keyReads = (generation, task)
        let found = await task.value
        if keyReads?.task == task { keyReads = nil }
        return found
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

    /// After the user connected `kind` on purpose (the first-use card): when the default model cannot be used
    /// (its provider is signed out, has no key, or was turned off) the new provider's first model takes its place,
    /// and the provider is turned on if it was off. `refreshModels` alone only replaces a default whose provider is
    /// gone from the list, so a stale default would keep the new connection from ever counting as ready.
    @discardableResult
    func adoptDefaultModel(from kind: ProviderKind) -> Bool {
        guard !isProviderReady, let account = account(kind), isUsable(account), let first = account.models.first else { return false }
        if !account.isEnabled { updateProvider(kind) { $0.isEnabled = true } }
        defaultModel = ModelRef(provider: kind, model: first.id).text
        return true
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
    /// `interview` it also asks about you in its first conversation and keeps the answers. Unless `folder` says
    /// otherwise it gets a folder of its own in `base` (`~/Orbs`); if that cannot be made it works in the home
    /// folder and says so in its conversation.
    @discardableResult
    func createBot(name: String, role: String, orb: OrbConfig, model: String, mode: PermissionMode,
                   identity: String = "", interview: Bool = true, folder: OrbFolderChoice = .own,
                   base: URL = OrbFolder.defaultBase) -> Bot {
        let name = Self.clippedName(name)
        var bot = Bot(name: name, role: role, orb: orb, model: model, permissionMode: mode)
        var folderProblem: String?
        switch folder {
        case .own:
            do {
                bot.workingDirectory = OrbFolder.storedPath(try OrbFolder.create(for: name, in: base))
            } catch {
                folderProblem = error.localizedDescription
            }
        case .home:
            break
        case .existing(let url):
            bot.workingDirectory = OrbFolder.storedPath(url)
        }
        let session = session(bot.id)
        session.conversation = Conversation()
        session.lastUsed = .now
        bots.append(bot)
        selection = .bot(bot.id)
        if let folderProblem { append(.notice("\(folderProblem). \(bot.name) vai trabalhar na pasta pessoal."), to: bot.id) }
        let bank = memory.bank(for: bot.id)
        Task {
            await bank.ensureIdentity(notes: identity, interview: interview)
            await refreshMemory(bot.id)
        }
        return bot
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
        effectiveBot(botID).map { PermissionState(mode: $0.permissionMode, rules: $0.permissionRules) }
    }

    /// The permission mode the running routine asked for, if it asked for one.
    private func routineModeOverride(_ botID: UUID) -> PermissionMode? {
        sessions[botID]?.routineID.flatMap { id in routines.first { $0.id == id }?.permissionMode }
    }

    /// The Orb as its running turn sees it: a routine's run may have a permission mode of its own.
    private func effectiveBot(_ botID: UUID) -> Bot? {
        guard var bot = bot(botID) else { return nil }
        if let mode = routineModeOverride(botID) { bot.permissionMode = mode }
        return bot
    }

    private func permissionSource(for bot: Bot) -> PermissionSource {
        let botID = bot.id, fallback = PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
        return { [weak self] in await self?.permissionState(of: botID) ?? fallback }
    }

    /// Changing the mode while the Orb waits for an answer answers the open cards: "Sem pedir permissão" allows
    /// them, "Automático" the ones it would not have asked about, "Só leitura" denies them. Claude Code is told too.
    private func permissionModeChanged(_ botID: UUID, to mode: PermissionMode) {
        guard let session = sessions[botID], session.turnTask != nil, routineModeOverride(botID) == nil else { return } // the routine's own mode stands
        let isClaudeCode = session.isClaudeTurn
        Task {
            let answered = await gate.applyModeChange(to: mode, for: botID)
            if isClaudeCode { await claudeEngine.modeChanged(for: botID, to: mode) }
            self.sessions[botID]?.markDecided(answered)
        }
    }

    /// Deletes the Orb with its conversation and routines. Its memory goes too, unless `keepMemory`: then the
    /// last conversation stretch is saved and the folder moves to `memoria/_guardadas/`.
    /// With `keepMemory`, returns the move of the memory, which ends with the folder it went to (nil: it did not move).
    @discardableResult
    func deleteBot(_ botID: UUID, keepMemory: Bool = false) -> Task<URL?, Never>? {
        let name = bot(botID)?.name ?? "Orb"
        let session = session(botID)
        liveBot(botID)?.stopComposing() // its watcher task ends with it
        session.memoryRequest = nil
        session.lastCompaction = nil
        session.compactedInTurn = false
        // First, so that stopping a running routine does not start the next one waiting for this Orb.
        let ownRoutines = routines.filter { $0.botID == botID }.map(\.id)
        queuedRoutines.removeAll { ownRoutines.contains($0) }
        routines.removeAll { $0.botID == botID }
        stop(botID)
        let jobs = jobs
        Task { await jobs.forget(botID: botID) }
        let pictures = images, outputs = outputsDirectory
        Task.detached(priority: .utility) {
            pictures.deleteAll(for: botID)
            ToolOutputCap.removeAll(for: botID, in: outputs)
        }
        session.memoryIdle?.cancel()
        session.memoryIdle = nil
        let library = memory
        var keeping: Task<URL?, Never>?
        if keepMemory {
            let stretch = session.pendingStretch()
            let bank = library.bank(for: botID)
            keeping = Task.detached(priority: .utility) {
                if let stretch, let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
                return library.keep(botID, name: name)
            }
        } else {
            library.delete(botID)
        }
        bots.removeAll { $0.id == botID }
        session.close()
        writeIfChanged(nil, at: botID, in: \.archives)
        sessions[botID] = nil // with its transcript: whatever still holds the session writes to nothing anyone shows
        store.deleteConversation(botID)
        store.deleteArchive(botID) // the earlier conversations and the routines' ones
        if selection == .bot(botID) { selection = bots.first.map { .bot($0.id) } }
        if lastSelectedBotID == botID { lastSelectedBotID = nil } // a catalog sheet must not default to an Orb that is gone
        return keeping
    }

    func selectAdjacentBot(offset: Int) {
        guard !bots.isEmpty else { return }
        let current = selectedBot.flatMap { bot in bots.firstIndex { $0.id == bot.id } } ?? -offset
        let next = (current + offset + bots.count) % bots.count
        selection = .bot(bots[next].id)
    }

    // MARK: Conversation history

    /// Starts a new conversation. The current one is archived (when you said anything in it), not thrown away. The
    /// draft belongs to the Orb, not to the conversation: it stays in the composer, with what was queued during a
    /// stopped turn (which `leaveChat` gave back to it, attachments and all).
    func newConversation(_ botID: UUID) {
        guard bot(botID) != nil else { return }
        leaveChat(botID)
        archiveChat(botID)
        session(botID).installChat(Conversation())
    }

    /// Makes an archived conversation the current one. The current one is archived first (if you said anything in
    /// it), so nothing is lost either way. The conversation keeps its Claude Code session and its memory
    /// bookkeeping (how much of it is already saved as memory), so reopening it saves nothing twice. The file is read
    /// off the main thread; what changed meanwhile is looked at again before the chat is replaced.
    @discardableResult
    func reopenConversation(_ id: UUID, of botID: UUID) async -> Bool {
        guard bot(botID) != nil, !reopening.contains(id) else { return false }
        reopening.insert(id)
        defer { reopening.remove(id) }
        let read = await store.readArchivedAsync(id, for: botID)
        // The Orb was deleted, or the conversation was deleted from the list, while it was being read.
        guard let owner = bot(botID), archives[botID]?.contains(where: { $0.id == id }) ?? true else { return false }
        addNotice(Self.labeled(read.notice, for: owner))
        guard let chosen = read.value else {
            archives[botID]?.removeAll { $0.id == id }
            return false
        }
        leaveChat(botID)
        archiveChat(botID)
        session(botID).installChat(chosen.closingInterruptedTurn())
        store.deleteArchived(id, for: botID) // after the reopened chat is written (`installChat`, same queue): a crash in between keeps both
        archives[botID]?.removeAll { $0.id == id }
        return true
    }

    /// Permanently deletes an archived conversation, and the pictures (`anexos/`) only it pointed to.
    func deleteArchivedConversation(_ id: UUID, of botID: UUID) {
        store.deleteArchived(id, for: botID, removingPicturesUnlessUsedBy: pictureNamesInUse(by: botID))
        archives[botID]?.removeAll { $0.id == id }
    }

    /// The file names of the pictures this Orb's live state points to: the open conversation (the store reads the saved
    /// one too), the pictures attached to the message box and the ones in queued messages.
    func pictureNamesInUse(by botID: UUID) -> Set<String> {
        guard let session = sessions[botID] else { return [] }
        var pictures = (session.conversation?.messages ?? []).flatMap(\.images)
        if let lane = session.lane {
            pictures += lane.pictures + lane.queued.flatMap(\.pictures)
        }
        return Set(pictures.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    }

    /// Reads the Orb's archive (the conversations menu does this when it opens).
    func loadArchive(_ botID: UUID) async {
        let list = await store.readArchiveAsync(botID)
        guard bot(botID) != nil else { return }
        writeIfChanged(list, at: botID, in: \.archives)
    }

    /// Before the chat is replaced: a turn of the chat stops (a running routine does not: it has its own
    /// conversation), the pending memory save is dropped (archiving saves it) and the conversation is read if it
    /// was not yet.
    private func leaveChat(_ botID: UUID) {
        if sessions[botID]?.routineID == nil { stop(botID) }
        sessions[botID]?.memoryIdle?.cancel()
        sessions[botID]?.memoryIdle = nil
        ensureLoaded(botID)
    }

    /// Archives the chat if you said anything in it. Whatever of it is not yet in memory is saved first, once: the
    /// mark of how much is saved goes into the archive with the conversation.
    private func archiveChat(_ botID: UUID) {
        guard let session = sessions[botID], var chat = session.parkedChat ?? session.conversation else { return }
        let start = min(chat.memorySavedCount ?? 0, chat.items.count)
        let stretch = Array(chat.items[start...])
        if !stretch.isEmpty {
            chat.memorySavedCount = chat.items.count
            session.persistStretch(stretch)
        }
        guard chat.hasUserMessages else { return }
        let summary = store.archive(chat, for: botID)
        if archives[botID] != nil {
            archives[botID]?.append(summary)
            archives[botID]?.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: Memory

    func refreshMemory(_ botID: UUID) async {
        guard bot(botID) != nil else { return }
        let snapshot = await memory.bank(for: botID).snapshot()
        if bot(botID) != nil { live(botID).setMemory(snapshot) }
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
    func prepareMemory() async { // internal for tests
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
            // The note beside the conversation says whether there is anything to save; only then is it read.
            if await mayHaveUnsavedStretch(bot.id) {
                let wasInMemory = sessions[bot.id]?.conversation != nil
                await loadedConversation(bot.id)
                let session = session(bot.id)
                if !session.saveMemory(ifIdleFor: SessionSummary.idleGap), session.hasUnsavedStretch() {
                    session.scheduleMemorySave()
                }
                // Read only for this: it goes back to disk now, not after the keep-alive (it may still be waiting to be
                // written, then it goes with the next sweep).
                if !wasInMemory { await unloadIdleConversations(now: .now + conversationKeepAlive, only: bot.id) }
            }
            await bank.sweep()
            await refreshMemory(bot.id)
        }
    }

    /// Whether the Orb's conversation may have a stretch not yet saved to memory, without reading the conversation
    /// when the note beside it can tell (a conversation with no valid note is read, off the main thread).
    private func mayHaveUnsavedStretch(_ botID: UUID) async -> Bool {
        if sessions[botID]?.isUnloaded == true, let meta = await store.readMetaAsync(botID) {
            return meta.hasUnsavedStretch || sessions[botID]?.isUnloaded != true
        }
        return true
    }

    // MARK: Compaction

    static let compactionBusyMessage = "Espere o Orb terminar o que está fazendo para compactar a conversa."

    /// "Compactar agora": folds the older part of the Orb's conversation into the summary right away, with the same
    /// machinery as an automatic compaction but down to `ContextMeter.compactingShare` of the budget, after saving to the
    /// Orb's memory what it held. `focus` is something the summary should pay attention to. The result carries the
    /// numbers (estimated tokens of the history before and after) and a sentence for the screen; when something was
    /// compacted the same sentence is added to the transcript. Not while a message is being answered. For Claude
    /// Code, whose context is its own session, the session is dropped and the next message starts a new one from the
    /// summary (Orb cannot ask the CLI to compact; it compacts itself, see `ClaudeCodeMessage.compacted`): the numbers
    /// are then estimates from Orb's copy of the conversation.
    @discardableResult
    func compactNow(botID: UUID, focus: String? = nil) -> CompactionResult {
        guard let bot = bot(botID) else {
            return CompactionResult(status: .unavailable, message: "Esse Orb não existe mais.")
        }
        let session = session(botID)
        guard session.turnTask == nil else {
            return CompactionResult(status: .busy, message: Self.compactionBusyMessage)
        }
        ensureLoaded(botID)
        guard var conversation = session.conversation else {
            return CompactionResult(status: .nothingToCompact, message: ContextWords.nothingToFold)
        }
        let tooShort = CompactionResult(
            status: .nothingToCompact,
            message: ContextWords.nothingToCompact(requests: conversation.requestCount(in: conversation.coveredMessageCount..<conversation.messages.count),
                                                   alreadySummarized: conversation.summary != nil))
        guard conversation.messages.count > 1 else { return tooShort }

        let claudeCode = modelRef(for: bot)?.provider == .claudeCode
        let budget = contextBudget(for: bot) ?? .fallback
        // Claude Code's session holds what Orb's messages do not show, so its conversation is folded down to the latest
        // turn: the new session starts from the summary and that turn.
        let attempt = claudeCode ? conversation.compactAllButLatestTurn(focus: focus)
            : conversation.compact(budget: budget, focus: focus)
        guard let report = attempt else { return tooShort }
        if claudeCode {
            conversation.claudeSessionReported("", folder: nil)
            conversation.claudeMemoryPinned = nil
            conversation.claudeWorkspaceHash = nil
            conversation.claudeStandingHash = nil
        }
        session.conversation = conversation
        let saved = session.announce(report)
        var message = report.notice
        if claudeCode { message += " " + Self.claudeRestartNote }
        if saved { message += " Guardei o essencial na memória do Orb." }
        scheduleConversationSave(botID, delay: 0)
        return CompactionResult(status: claudeCode ? .claudeSessionRestarted : .compacted, foldedMessages: report.foldedMessages,
                                tokensBefore: report.tokensBefore ?? 0, tokensAfter: report.tokensAfter ?? 0,
                                savedToMemory: saved, message: message)
    }

    nonisolated static let claudeRestartNote = "A próxima mensagem começa uma sessão nova do Claude Code, com esse resumo. Os números são estimativas."

    /// "/compactar [foco]" typed in the composer: compacts and tells what happened in the transcript (when something
    /// was compacted the notice is already there; otherwise, or when the Claude Code session starts over, a line says so).
    private func runCompactionCommand(focus: String?, for botID: UUID) {
        let result = compactNow(botID: botID, focus: focus)
        switch result.status {
        case .compacted: break
        case .claudeSessionRestarted: append(.notice(Self.claudeRestartNote), to: botID)
        case .nothingToCompact, .busy, .unavailable: append(.notice(result.message), to: botID)
        }
    }

    /// What the summary of the Orb's conversation holds (nil while nothing has been folded away).
    func contextSummary(for botID: UUID) -> ContextSummaryInfo? {
        ensureLoaded(botID)
        guard let conversation = sessions[botID]?.conversation, let text = conversation.summary else { return nil }
        return ContextSummaryInfo(text: text, foldedMessages: conversation.coveredMessageCount,
                                  compactions: conversation.compactions ?? 1, focus: conversation.ledger?.focus,
                                  ledger: conversation.ledger)
    }

    // MARK: Turns

    @ObservationIgnored private var didSendLaunchPrompt = false

    /// Dev aid for scripted end-to-end checks: `ORB_SEND="texto"` sends it to the selected bot once,
    /// after the provider connections are known.
    func sendLaunchPrompt() {
        guard !didSendLaunchPrompt, let text = ProcessInfo.processInfo.environment["ORB_SEND"],
              let id = selectedBot?.id else { return }
        didSendLaunchPrompt = true
        Task {
            await refreshConnections()
            sendWhenLoaded(text, to: id)
        }
    }

    /// `send` for callers that do not use its result: when the Orb's conversation is not in memory it is read off the
    /// main thread first, instead of making the window wait for it.
    func sendWhenLoaded(_ text: String, to botID: UUID) {
        guard sessions[botID]?.isUnloaded == true else {
            send(text, to: botID)
            return
        }
        Task {
            await loadedConversation(botID)
            ensureLoaded(botID)
            send(text, to: botID)
        }
    }

    /// Starts a turn. Returns false when nothing was sent (empty text, a turn already running, no usable model),
    /// so the composer keeps what you wrote. Only a message typed in the composer (`fromUser`) clears its draft:
    /// routines and quick ask must not wipe what you are typing for that Orb.
    @discardableResult
    func send(_ text: String, attachments: [URL] = [], images pictures: [ImageAttachment] = [], to botID: UUID,
              fromUser: Bool = false) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session(botID)
        guard !typed.isEmpty || !pictures.isEmpty, session.turnTask == nil, let bot = effectiveBot(botID) else { return false }
        ensureLoaded(botID)
        // "/compactar [foco]" is a command of the composer, not a message for the model.
        if fromUser, attachments.isEmpty, pictures.isEmpty, let focus = CompactionCommand.parse(typed) {
            setDraft("", for: botID)
            runCompactionCommand(focus: focus, for: botID)
            return true
        }
        guard let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else {
            if fromUser && !isProviderReady {
                // The first-use card or banner is on screen: it pulses, and what you typed stays in the composer.
                setupNudge += 1
            } else {
                append(.notice("Conecte um modelo em Ajustes → Modelos para começar."), to: botID)
            }
            return false
        }
        let modelInfo = account.models.first { $0.id == ref.model }
        let sees: Bool? = visionRejected.contains(ref.text) ? false : modelInfo?.supportsImages

        session.memoryIdle?.cancel()
        session.memoryIdle = nil
        // Full paths: the bubble shows thumbnails of the pictures (a name alone, as older conversations have, still renders).
        let itemsBeforeMessage = session.conversation?.items.count ?? 0
        append(.user(text: typed, attachments: attachments.map(\.path) + pictures.map(\.path)), to: botID)
        if fromUser { setDraft("", for: botID) }
        setStatus("Pensando", of: botID)
        live(botID).poked()
        session.flash(\.isListening, seconds: 1.4)

        let intent = session.routineID == nil ? MemoryIntent.detect(typed) : nil // a routine's prompt is not a request to remember
        session.memoryRequest = intent.map { ($0, max(0, (session.conversation?.items.count ?? 1) - 1)) }
        // Your request is the approval: this turn saves to memory without asking (the Orb's saved settings don't change).
        let rememberTool = ref.provider == .claudeCode ? ClaudeCodeTools.memoryPrefix + "remember" : "remember"
        let turnGrants = intent == nil ? [] : [PermissionRule(family: .memory)]

        var prompt = typed
        if let expansion = SystemPrompt.expandSkill(in: typed, skills: skills(for: botID)) {
            prompt = expansion.prompt
            if let index = skills.firstIndex(where: { $0.id == expansion.skill.id }) { skills[index].uses += 1 }
        }
        if !attachments.isEmpty {
            prompt += "\n\nAttached files (read them with your tools):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
        }
        if !pictures.isEmpty {
            prompt += Self.pictureNote(pictures, forClaudeCode: ref.provider == .claudeCode, modelSees: sees)
        }
        prompt = unattendedPrompt(prompt, for: botID)
        if intent != nil {
            prompt += MemoryIntent.instruction(tool: rememberTool)
        }
        if ref.provider == .claudeCode {
            runClaudeCode(bot, model: ref.model, prompt: prompt, images: pictures, message: typed, turnGrants: turnGrants)
            return true
        }
        let skills = self.skills(for: botID)
        let allowedConnectors = connectors(for: botID)
        let budget = contextBudget(ref: ref, account: account, botID: botID)
        // Read before this turn's own messages are recorded: it is whether the last task is waiting for "continua".
        let paused = session.conversation?.isTaskPaused ?? false
        // The message and what goes before it (workspace snapshot, memory notes) take room too.
        let reserve = prompt.count + Self.prefaceAllowance
        let prepared = session.changeConversation { $0.prepareHistory(budget: budget, reserving: reserve) }
        let history = prepared.history
        let ledger = session.conversation?.currentLedger
        if let report = prepared.compaction { session.announce(report, memoryUpTo: itemsBeforeMessage) }
        let bank = memory.bank(for: botID)
        let context = ToolContext(workingDirectory: bot.workingURL, memory: bank, botID: botID, jobs: jobs,
                                  imageStore: images, acceptsImages: sees != false,
                                  outputsDirectory: outputsDirectory,
                                  canSaveFiles: bot.capabilities.contains(.terminal),
                                  computerUseAllowed: bot.capabilities.contains(.computerUse))
        let userTurns = session.userTurnCount()
        let maxSteps = session.routineID != nil ? AgentEngine.routineMaxSteps : AgentEngine.defaultMaxSteps
        let lastWorkspaceHash = session.conversation?.workspaceHash
        let sessionID = session.gatewaySessionID()
        let lastWorkspace = session.conversation?.workspaceSeen
        let sentMemories = TurnPreface.relatedLines(in: history)

        let turn = session.beginTurn()
        let steering = composerLane(botID).queue // messages sent during the turn reach the model between its steps
        session.turnTask = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: typed, conversationIsNew: history.isEmpty, userTurns: userTurns,
                                         canSave: bot.permissionMode != .readOnly, alreadySent: sentMemories)
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard session.isCurrent(turn) else { return } // stopped while preparing
            let built = TurnPrompt.native(inputs, history: history, lastWorkspaceHash: lastWorkspaceHash, lastWorkspace: lastWorkspace)
            let client: any LLMClient
            do {
                guard let made = clientOverride?() ?? account.client(for: modelInfo, credentials: Self.credentials(for: ref.provider),
                                                                      conversationID: sessionID) else { throw LLMError.notConfigured }
                client = made
            } catch {
                session.failSetup(error, turn: turn)
                return
            }
            let accessibilityGranted = !bot.capabilities.contains(.computerUse) || accessibilityProbe()
            var tools = ToolBox.offered(for: bot.capabilities, accessibilityGranted: accessibilityGranted)
            if bot.capabilities.contains(.connectors) { tools += await mcp.tools(allowing: Set(allowedConnectors.map(\.id))) }
            guard session.isCurrent(turn) else { return }
            // Recorded when the prompt with the snapshot is stored (see `apply`), not before.
            session.pendingMarks = built.marks
            // The system prompt tells the Orb when the interface tools are held back (see `ToolBox.offered`).
            let system = accessibilityGranted ? built.system : built.system + "\n\n" + ToolBox.accessibilityUnavailableNote
            let request = TurnRequest(bot: bot, model: ref.model, system: system, history: history,
                                      prompt: TurnPreface.prepend(built.preface, to: prompt),
                                      client: client, tools: tools, context: context, budget: budget, ledger: ledger,
                                      maxSteps: maxSteps,
                                      turnGrants: turnGrants, permissions: permissionSource(for: bot),
                                      images: pictures, supportsImages: sees,
                                      onImagesRejected: { [weak self] in Task { @MainActor in self?.visionRejected.insert(ref.text) } },
                                      outputsDirectory: outputsDirectory,
                                      onContextLearned: { [weak self] tokens, stated in
                                          Task { @MainActor in self?.learnContextWindow(tokens, of: ref.text, stated: stated) }
                                      },
                                      onOverheadMeasured: { [weak self] tokens in
                                          Task { @MainActor in self?.noteMeasuredOverhead(tokens, of: botID) }
                                      },
                                      picksUpTask: paused,
                                      steering: steering)
            await session.play(engine.run(request), turn: turn)
        }
        return true
    }

    // MARK: Context

    /// Characters set aside for what a request carries besides the history and the message: the workspace snapshot
    /// and the memory notes.
    nonisolated static let prefaceAllowance = 4_000

    /// The history budget of the model `bot` uses, the memory level and what a refusal once taught about the model's
    /// window included. nil for Claude Code, which manages its own context.
    func contextBudget(for bot: Bot) -> ContextBudget? {
        guard let ref = modelRef(for: bot), ref.provider != .claudeCode, let account = account(ref.provider) else { return nil }
        return contextBudget(ref: ref, account: account, botID: bot.id)
    }

    /// With the overhead (system prompt and tool specs) the engine measured on this Orb's last turn, so the history
    /// prepared here is the one the engine will fit: planned with a guess, the engine would cut it again every turn.
    private func contextBudget(ref: ModelRef, account: ProviderAccount, botID: UUID) -> ContextBudget {
        let learned = learnedContexts[ref.text].flatMap { $0.isFresh() ? $0.tokens : nil }
        let budget = ContextBudget(model: account.models.first { $0.id == ref.model }, provider: ref.provider,
                                   format: ref.provider == .custom ? account.format : nil, level: contextMemory, learnedWindow: learned)
        return sessions[botID]?.measuredOverhead.map { budget.refined(overheadTokens: $0) } ?? budget
    }

    /// How full the context of the Orb's conversation is, for the meter. nil for Claude Code or while the Orb has no
    /// usable model.
    func contextFill(for botID: UUID) -> ContextFill? {
        guard let bot = bot(botID), let budget = contextBudget(for: bot) else { return nil }
        return (sessions[botID]?.conversation ?? Conversation()).contextFill(budget: budget)
    }

    /// Remembers what the system prompt and tool specs of the Orb's last turn took, to plan the next history by.
    func noteMeasuredOverhead(_ tokens: Int, of botID: UUID) {
        session(botID).measuredOverhead = tokens
    }

    /// Remembers that a model's window is `tokens` (a request was refused for its size and worked with less).
    func learnContextWindow(_ tokens: Int, of model: String, stated: Bool = true) {
        guard tokens > 0 else { return }
        learnedContexts[model] = LearnedContext(tokens: tokens, date: .now, inferred: stated ? nil : true)
        scheduleStateSave()
    }

    /// Forgets what was learned about a model's window (after raising the server's limit, for instance).
    func forgetLearnedContext(of model: String) {
        guard learnedContexts.removeValue(forKey: model) != nil else { return }
        scheduleStateSave()
    }

    /// What the prompt says about the pictures of a message. Claude Code cannot be handed pictures, but its Read tool
    /// opens image files; Orb's own engine sends them with the message (the paths are for tools that need a file).
    nonisolated static func pictureNote(_ pictures: [ImageAttachment], forClaudeCode: Bool, modelSees: Bool?) -> String {
        let list = pictures.map { "- \($0.path)" }.joined(separator: "\n")
        if forClaudeCode { return "\n\nImagens anexadas — use a ferramenta Read para vê-las:\n" + list }
        // A model that cannot see them gets the paths from the engine; one that can gets them for tools. When it is
        // not known whether it sees (`modelSees` nil), the engine decides and adds its own line if it sent paths only.
        guard modelSees != false else { return "" }
        return (modelSees == true ? "\n\nAttached images (resized copies, shown to you with this message):\n"
                : "\n\nAttached images (resized copies):\n") + list
    }

    /// A turn run by the user's Claude Code, continuing the conversation's Claude Code session.
    private func runClaudeCode(_ bot: Bot, model: String, prompt: String, images pictures: [ImageAttachment], message: String, turnGrants: [PermissionRule]) {
        let botID = bot.id
        let session = session(botID)
        let conversation = session.conversation ?? Conversation()
        let folder = bot.workingURL.standardizedFileURL.path
        // Claude Code keeps sessions per folder: once the Orb's folder changed, the old one can't be resumed, so a
        // new session starts and gets the conversation so far as catch-up.
        let sessionID = conversation.claudeSession(forFolder: folder)
        // New session: hand it the whole conversation so far. Resumed: only what other models did since.
        // (Sessions from before this was tracked count as up to date.)
        let seen = sessionID == nil ? 0 : min(conversation.claudeSeenCount ?? conversation.messages.count, conversation.messages.count)
        let catchUp = ClaudeCodePrompt.catchUp(conversation, seen: seen)
        let skills = self.skills(for: botID)
        let bank = memory.bank(for: botID)
        // The app knows whether it has Accessibility; the server (a child process) is told rather than left to ask.
        let usesMac = bot.capabilities.contains(.computerUse)
        let accessibility = usesMac ? accessibilityProbe() : nil
        let connectors = connectorServers(for: bot)
        let servers = [OrbToolsMCPServer.config(directory: bank.directory, mac: usesMac, files: bot.capabilities.contains(.terminal),
                                                folder: bot.workingURL, accessibilityGranted: accessibility)]
            + connectors
        let connectorIDs = Set(connectors.map(\.id))
        let cliNames = ClaudeCodeTurn.mcpNames(servers) // what the CLI will call each server
        let isNew = conversation.messages.isEmpty
        let userTurns = session.userTurnCount()
        session.isClaudeTurn = true
        session.claudeTurnDelivered = false
        session.claudeTurnFolder = folder
        let turn = session.beginTurn()
        session.turnTask = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: message, conversationIsNew: isNew, userTurns: userTurns,
                                         tools: ClaudeCodePrompt.memoryTools, canSave: bot.permissionMode != .readOnly,
                                         alreadySent: sessionID == nil ? [] : (conversation.claudeRelatedSent ?? []).flatMap { $0 })
            // A resumed session sends the same system prompt again (rebuilt only when its identity, preferences or rules change); the rest rides with the message.
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard session.isCurrent(turn) else { return } // stopped while preparing
            let built = TurnPrompt.claudeCode(inputs, session: .init(isNewSession: sessionID == nil,
                                                                     workspaceHash: conversation.claudeWorkspaceHash,
                                                                     pinned: conversation.claudeMemoryPinned,
                                                                     standingHash: conversation.claudeStandingHash,
                                                                     workspace: conversation.claudeWorkspaceSeen,
                                                                     system: conversation.claudeSystem))
            let context = [built.context, catchUp].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let found = await ClaudeCode.shared.installation()
            guard session.isCurrent(turn) else { return }
            guard let installation = found else {
                session.failSetup("O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos.", turn: turn)
                return
            }
            let environment = await ClaudeCode.shared.environment(for: installation)
            // What the connectors mark destructive, from the app's own connections: the CLI's never reach the Orb. A
            // connector still starting gets a few seconds; one the app could not list is asked about tool by tool.
            let (destructive, unverified) = await connectorAnnotations(for: connectorIDs, cliNames: cliNames)
            guard session.isCurrent(turn) else { return }
            let claudeTurn = ClaudeCodeTurn(bot: bot, executable: installation.executable, model: model,
                                            system: ClaudeCodePrompt.withAccessibilityNote(built.system, accessibilityGranted: accessibility),
                                            prompt: prompt, images: pictures, context: context, sessionID: sessionID, connectors: servers,
                                            environment: environment, destructiveConnectors: destructive,
                                            unverifiedConnectors: unverified, turnGrants: turnGrants,
                                            permissions: permissionSource(for: bot))
            // Recorded when the session answers (see `apply`): a turn that fails before that sent nothing.
            session.pendingMarks = built.marks
            await session.play(claudeEngine.run(claudeTurn), turn: turn)
        }
    }

    /// The tools of `ids` that the connectors mark destructive, and the connectors whose tools the app's own connection
    /// could not list (so nothing is known about them), for a Claude Code turn.
    func connectorAnnotations(for ids: Set<UUID>, cliNames: [UUID: String], timeout: Duration = .seconds(5)) async
        -> (destructive: [String: String], unverified: Set<String>) {
        guard !ids.isEmpty else { return ([:], []) }
        await waitForConnectors(ids, timeout: timeout)
        let tools = await mcp.tools(allowing: ids)
        return (ClaudeCodeTurn.destructiveConnectors(tools, cliNames: cliNames),
                ClaudeCodeTurn.unverifiedConnectors(ids, tools: tools, cliNames: cliNames))
    }

    func stop(_ botID: UUID, startsQueuedRoutines: Bool = true) { sessions[botID]?.stop(startsQueuedRoutines: startsQueuedRoutines) }

    func apply(_ event: TurnEvent, to botID: UUID) { session(botID).apply(event) } // internal for tests

    /// Closes the turn `turn`; a turn that is no longer the Orb's current one (stopped, then replaced) is ignored.
    func finishTurn(_ botID: UUID, turn: UUID, succeeded: Bool = true) {
        sessions[botID]?.finishTurn(turn, succeeded: succeeded)
    }

    func flushText(_ botID: UUID) { session(botID).flushText() } // internal for tests (they flush when they want, not after a delay)

    func closeStreaming(_ botID: UUID) { session(botID).closeStreaming() }

    func append(_ kind: TranscriptItem.Kind, to botID: UUID) { session(botID).append(kind) }

    /// The Orb's conversation, read from disk first if it was not in memory. For the transcript's "Tentar de novo".
    func loadedConversation(_ botID: UUID) -> Conversation? {
        ensureLoaded(botID)
        return sessions[botID]?.conversation
    }

    /// Changes an Orb's conversation (read first if needed) and schedules it to be saved. The one way another file
    /// of the app edits a conversation, so a change is never left unsaved.
    func editConversation(_ botID: UUID, _ change: (inout Conversation) -> Void) {
        ensureLoaded(botID)
        guard let session = sessions[botID], var conversation = session.conversation else { return }
        change(&conversation)
        session.conversation = conversation
        scheduleConversationSave(botID, delay: 0.3)
    }

    /// Puts a conversation in memory without saving it (`Orb --snapshot transcript…`).
    func seedConversation(_ conversation: Conversation, for botID: UUID) {
        session(botID).conversation = conversation
    }

    // MARK: Routines

    /// Runs the routine now, or, when its Orb is busy, as soon as the Orb is free (a routine waits at most once).
    /// A run has a conversation of its own (`conversations/<Orb>/routine-<routine>.json`): your chat gets one line
    /// when it ends, nothing else.
    func runRoutine(_ routineID: UUID) {
        guard let routine = routines.first(where: { $0.id == routineID }), bot(routine.botID) != nil else { return }
        if sessions[routine.botID]?.isUnloaded == true { // its chat is read off the main thread first
            Task {
                await loadedConversation(routine.botID)
                ensureLoaded(routine.botID)
                runRoutine(routineID)
            }
            return
        }
        guard sessions[routine.botID]?.routineID != routineID, !startingRoutines.values.contains(routineID) else { return }
        guard !queuedRoutines.contains(routineID) else {
            startIdleQueuedRoutines() // waiting, but its Orb may be free by now (the routine was moved to another Orb)
            return
        }
        guard !isWorking(routine.botID), startingRoutines[routine.botID] == nil else {
            queuedRoutines.append(routineID)
            return
        }
        startRoutine(routine)
    }

    /// Reads the list of Orbs, then each one's session: a view that asks is told when any Orb starts or ends a run,
    /// and when an Orb is added (whose session it did not read yet).
    func isRoutineRunning(_ routineID: UUID) -> Bool {
        botIDs.contains { sessions[$0]?.routineID == routineID }
    }

    func isRoutineQueued(_ routineID: UUID) -> Bool { queuedRoutines.contains(routineID) }

    /// The transcript of a routine that is running right now (nil when it is not).
    func liveRoutineItems(_ routineID: UUID) -> [TranscriptItem]? {
        guard let botID = botIDs.first(where: { sessions[$0]?.routineID == routineID }) else { return nil }
        return sessions[botID]?.conversation?.items
    }

    /// The routine's conversation as saved: its last runs.
    func routineTranscript(_ routineID: UUID) async -> [TranscriptItem] {
        guard let routine = routines.first(where: { $0.id == routineID }) else { return [] }
        let read = await store.readRoutineConversationAsync(routine: routineID, for: routine.botID)
        addNotice(Self.labeled(read.notice, for: bot(routine.botID)))
        return read.value?.items ?? []
    }

    func deleteRoutine(_ routineID: UUID) {
        guard let routine = routines.first(where: { $0.id == routineID }) else { return }
        queuedRoutines.removeAll { $0 == routineID }
        routines.removeAll { $0.id == routineID }
        if sessions[routine.botID]?.routineID == routineID { stop(routine.botID) }
        store.deleteRoutineConversation(routine: routineID, for: routine.botID)
    }

    /// Starts the routine once its own conversation (the last runs) has been read, off the main thread. Until then the
    /// Orb takes no other routine (`startingRoutines`); a message sent meanwhile gets the Orb first.
    private func startRoutine(_ routine: Routine) {
        let botID = routine.botID
        guard session(botID).turnTask == nil, startingRoutines[botID] == nil, bot(botID) != nil,
              routines.contains(where: { $0.id == routine.id }) else { return }
        ensureLoaded(botID)
        startingRoutines[botID] = routine.id
        Task {
            let read = await store.readRoutineConversationAsync(routine: routine.id, for: botID)
            startingRoutines[botID] = nil
            beginRoutine(routine.id, of: botID, read: read)
        }
    }

    private func beginRoutine(_ routineID: UUID, of botID: UUID, read: StoreRead<Conversation>) {
        // The Orb or the routine is gone, or the routine was moved to another Orb: its file here is not the one to run.
        guard bot(botID) != nil, let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        guard routines[index].botID == botID else {
            if !queuedRoutines.contains(routineID) { queuedRoutines.append(routineID) }
            startIdleQueuedRoutines() // it runs when its new Orb is free
            return
        }
        let session = session(botID)
        // A message (or a routine of its own) took the Orb meanwhile: this one waits for the turn to end, as any other.
        guard session.turnTask == nil else {
            if !queuedRoutines.contains(routineID) { queuedRoutines.append(routineID) }
            return
        }
        let routine = routines[index]
        ensureLoaded(botID)
        let started = Date.now
        routines[index].lastRun = started
        addNotice(Self.labeled(read.notice, for: bot(botID)))

        // The routine's own conversation takes the chat's place while it runs (the chat is written and parked).
        session.startRoutineRun(routine.id, conversation: (read.value?.closingInterruptedTurn() ?? Conversation()).startingRoutineRun(at: started),
                                at: started)
        let hasPrompt = !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPrompt, send(routine.prompt, to: botID) {
            setStatus(routineStatus("Pensando", for: botID), of: botID)
            return
        }
        // Nothing was sent (no model connected, nothing to do): the run did not happen. It is only in the history.
        session.routineID = nil
        session.routineStart = nil
        session.unparkChat()
        let reason = hasPrompt ? "Não rodou: conecte um modelo em Ajustes." : "Não rodou: a rotina está sem instruções."
        routines[index].lastResult = reason
        recordRun(RoutineRun(date: started, finishedAt: started, succeeded: false, summary: reason), routineID: routine.id)
    }

    /// Runs the routines that were waiting for this Orb, one at a time, as it becomes free.
    func startNextQueuedRoutine(for botID: UUID) {
        while sessions[botID]?.turnTask == nil, startingRoutines[botID] == nil,
              let next = queuedRoutines.first(where: { id in routines.first { $0.id == id }?.botID == botID }) {
            queuedRoutines.removeAll { $0 == next }
            if let routine = routines.first(where: { $0.id == next }) { startRoutine(routine) }
        }
    }

    /// Starts the queued routines whose Orb is free (see `runRoutine`, `queueFollowsEdits`).
    private func startIdleQueuedRoutines() {
        for id in queuedRoutines {
            guard let botID = routines.first(where: { $0.id == id })?.botID, sessions[botID]?.turnTask == nil, !isWorking(botID) else { continue }
            startNextQueuedRoutine(for: botID)
        }
    }

    /// A routine that waits follows its edits: switched off, it does not run; moved to another Orb, it runs when
    /// that one is free (the old Orb finishing would not start it any more).
    private func queueFollowsEdits(from old: [Routine]) {
        guard !queuedRoutines.isEmpty else { return }
        var moved = false
        for id in queuedRoutines {
            guard let before = old.first(where: { $0.id == id }), let now = routines.first(where: { $0.id == id }) else { continue }
            if before.isEnabled && !now.isEnabled { queuedRoutines.removeAll { $0 == id } }
            else if before.botID != now.botID { moved = true }
        }
        if moved { Task { startIdleQueuedRoutines() } }
    }

    /// The end of a routine's run: its conversation is saved, the chat comes back, the run goes into the routine's
    /// history (and, for an Orb with a folder of its own, its report into `Rotinas/`), and the chat gets one line.
    func finishRoutineRun(_ botID: UUID, routineID: UUID, succeeded: Bool, reply: String?) {
        let finished = Date.now
        let session = session(botID)
        let started = session.routineStart ?? finished
        session.routineStart = nil
        let own = session.conversation ?? Conversation()
        let routine = routines.first { $0.id == routineID }
        if routine != nil { store.saveRoutineConversation(own, routine: routineID, for: botID) }
        session.unparkChat()
        if session.hasUnsavedStretch() { session.scheduleMemorySave() } // the run cancelled the chat's pending save
        guard let routine, let bot = bot(botID) else { return }

        var run = RoutineRun(date: started, finishedAt: finished, succeeded: succeeded, summary: "")
        if succeeded {
            run.summary = RoutineRun.firstLine(of: reply) ?? "Terminou sem relatório."
            run.report = reply.map { Conversation.clipped($0, to: RoutineRun.reportLimit) }
            if let reply, let folder = PermissionPolicy.ownFolder(bot.workingURL, home: homeFolder), Self.isFolder(folder) {
                run.reportFile = RoutineReport.write(reply, routine: routine.name, orb: bot.name, date: started, in: folder)
            }
        } else {
            let why = own.items.reversed().lazy.compactMap { item -> String? in
                if case .notice(let text) = item.kind, !text.hasPrefix(Conversation.routineRunMarker) { text } else { nil }
            }.first
            run.summary = Conversation.clipped(why ?? "Não terminou.", to: RoutineRun.summaryLimit)
        }
        recordRun(run, routineID: routineID)
        if let index = routines.firstIndex(where: { $0.id == routineID }) {
            routines[index].lastResult = succeeded ? reply.map { String($0.prefix(160)) } : "Não terminou: veja a conversa."
        }
        let outcome = succeeded ? "terminou: \(run.summary)" : "não terminou: \(run.summary)"
        append(.notice("Rotina “\(routine.name)” \(outcome)" + (run.reportFile.map { " (relatório em \($0))" } ?? "")), to: botID)
    }

    private func recordRun(_ run: RoutineRun, routineID: UUID) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[index].runs.insert(run, at: 0)
        if routines[index].runs.count > Routine.keptRuns { routines[index].runs.removeLast(routines[index].runs.count - Routine.keptRuns) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What the model gets for a turn: a routine's run is told that nobody is there.
    private func unattendedPrompt(_ prompt: String, for botID: UUID) -> String {
        guard let routineID = sessions[botID]?.routineID, let routine = routines.first(where: { $0.id == routineID }) else { return prompt }
        return RoutinePrompt.unattended(prompt, routine: routine.name, previous: routine.runs.first { $0.report != nil })
    }

    /// The status line says which routine the Orb is busy with.
    func routineStatus(_ text: String, for botID: UUID) -> String {
        guard let routineID = sessions[botID]?.routineID, let routine = routines.first(where: { $0.id == routineID }) else { return text }
        return "Rotina “\(routine.name)”: \(text)"
    }

    private func runDueRoutines(now: Date = .now) {
        for routine in routines where routine.isEnabled && routine.nextRun <= now {
            runRoutine(routine.id)
        }
    }

    // MARK: Catalogs

    func installedSkill(_ catalogID: String) -> Skill? { skills.first { $0.source == catalogID } }

    /// Adds a catalog skill; its slug gets a numeric suffix if one is already taken.
    @discardableResult
    func install(_ document: SkillDocument, from entry: CatalogSkill) -> Skill? {
        if let existing = installedSkill(entry.id) { return existing }
        let base = Skill.slugify(entry.skillId)
        var slug = base, suffix = 2
        while skills.contains(where: { $0.slug == slug }) {
            slug = "\(base)-\(suffix)"
            suffix += 1
        }
        let skill = Skill(slug: slug, name: document.name, summary: document.description,
                          instructions: document.instructions, source: entry.id, folderURL: document.folderURL)
        skills.append(skill)
        return skill
    }

    func installedConnector(_ registryName: String) -> MCPServerConfig? { connectors.first { $0.source == registryName } }

    // MARK: Connectors

    func syncConnectors() {
        guard !isDevRun else { return } // their servers are programs (`npx …`) of whoever wrote the data folder
        let configs = connectors
        let previous = connectorSync
        connectorSyncGeneration += 1
        let generation = connectorSyncGeneration
        pendingConnectorSyncs += 1
        settledConnectors = [:]
        connectorSync = Task {
            await previous?.value
            // `sync` waits for servers to start; show "Conectando…" meanwhile.
            let syncing = Task {
                await mcp.sync(configs) { [weak self] id, status in await self?.connectorSettled(id, status, generation: generation) }
            }
            try? await Task.sleep(for: .milliseconds(150))
            connectorStatus = await mcp.status()
            await syncing.value
            connectorStatus = await mcp.status()
            if generation == connectorSyncGeneration {
                // Whatever did not need to start (already running, off) is settled too.
                for (id, status) in connectorStatus where settledConnectors[id] == nil { settledConnectors[id] = status }
            }
            pendingConnectorSyncs -= 1
        }
    }

    private func connectorSettled(_ id: UUID, _ status: MCPStatus, generation: Int) {
        connectorStatus[id] = status
        if generation == connectorSyncGeneration { settledConnectors[id] = status }
    }

    /// Waits until connector `id` has started or failed in the sync that a change to `connectors` began, and gives
    /// its status. Other connectors that are slow to start or retrying do not hold it back.
    func connectAndWait(_ id: UUID) async -> MCPStatus? {
        while settledConnectors[id] == nil, pendingConnectorSyncs > 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
        }
        return settledConnectors[id] ?? connectorStatus[id]
    }

    /// Waits until every connector in `ids` has started or failed in the sync under way, but no longer than `timeout`
    /// (an `npx` server can take many seconds).
    func waitForConnectors(_ ids: Set<UUID>, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while pendingConnectorSyncs > 0, ids.contains(where: { settledConnectors[$0] == nil }),
              ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    // MARK: Notifications

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true
    }

    /// Posts a banner when the app is in the background (bundled app only).
    func notify(_ title: String, _ body: String) {
        guard !(NSApp?.isActive ?? false), Self.notificationsEnabled, ApprovalNotifications.isAvailable else { return }
        let content = ApprovalNotifications.plainContent(title: title, body: body)
        Task { await ApprovalNotifications.send(content) }
    }

    // MARK: Saving

    private var state: AppState {
        var unread: [String: Int] = [:]
        for (id, live) in lives where live.unread > 0 { unread[id.uuidString] = live.unread }
        return AppState(bots: bots, routines: routines, skills: skills, connectors: connectorSecrets.redact(connectors),
                        providers: providers, defaultModel: defaultModel, unread: unread, contextMemory: contextMemory,
                        learnedContexts: learnedContexts)
    }

    private func scheduleStateSave() {
        stateSave?.cancel()
        stateSave = Task { [store] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save(state)
        }
    }

    /// Saves the Orb's conversation `delay` seconds after the first unsaved change (see `BotSession.scheduleSave`).
    func scheduleConversationSave(_ botID: UUID, delay: Double) { sessions[botID]?.scheduleSave(delay: delay) }

    /// Writes everything that changed and waits for the disk (on quit).
    func saveNow() {
        store.save(state)
        for session in sessions.values { session.saveNow() }
        store.flush()
    }
}
