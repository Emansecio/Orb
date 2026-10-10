import SwiftUI
import Observation
import os

@MainActor
@Observable
final class AppModel {
    // MARK: Persisted state

    var bots: [Bot] { didSet { scheduleStateSave(); syncLives() } }
    var routines: [Routine] { didSet { scheduleStateSave(); queueFollowsEdits(from: oldValue); syncActivities() } }
    var skills: [Skill] { didSet { scheduleStateSave() } }
    var connectors: [MCPServerConfig] { didSet { scheduleStateSave(); syncConnectors() } }
    /// Providers the user set up, with their last fetched model lists.
    var providers: [ProviderAccount] { didSet { scheduleStateSave() } }
    /// "provider/model" for bots without a model of their own.
    var defaultModel: String { didSet { scheduleStateSave() } }
    /// How much conversation the Orbs remember word for word before the start is folded into a summary.
    var contextMemory: ContextMemoryLevel { didSet { scheduleStateSave() } }
    var profile: UserProfile { didSet { scheduleStateSave() } }
    /// Prices the user corrected on the Uso page, by "provider/model".
    var priceCorrections: [String: ModelPrice] { didSet { scheduleStateSave() } }
    // MARK: MultiOrb (WP0)
    /// The groups of Orbs (`normalizeGroups` keeps them true to `bots`).
    var groups: [OrbGroup] { didSet { scheduleStateSave() } }
    /// Orbs asking each other for work.
    @ObservationIgnored lazy var delegation: DelegationHub = DelegationHub(model: self)
    /// A group's thread and its live state, made when the group is first opened.
    @ObservationIgnored var groupSessions: [UUID: GroupSession] = [:]
    @ObservationIgnored var groupLives: [UUID: GroupLive] = [:]
    /// The "Novo grupo" sheet is open, and the Orb it starts with ("Criar grupo com…", the Orb's menu). (WP6)
    var showNewGroup = false
    var newGroupStart: UUID?
    // MARK: end MultiOrb (WP0)
    // MARK: MultiOrb (WP1)
    /// Where Claude Code's tools server asks for `orbs` (and the creation assistant's `orb_draft`): see `OrbBridge`. It starts
    /// listening with the first Claude Code turn.
    @ObservationIgnored private(set) lazy var orbBridge = OrbBridge.Server(directory: store.directory.appending(path: "ponte")) {
        [weak self] orb, tool, arguments, callID in
        guard let self else { throw ToolError("O app está fechando.") }
        return try await self.bridgeCall(tool: tool, orb: orb, arguments: arguments, callID: callID)
    }
    // MARK: end MultiOrb (WP1)
    // MARK: MultiOrb (WP3)
    /// Where the Orbs an Orb proposes get their own folder (`~/Orbs`; tests point it at a temporary folder).
    @ObservationIgnored var proposedOrbFolderBase = OrbFolder.defaultBase
    // MARK: end MultiOrb (WP3)
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
    var isStartingRoutine: Bool { !startingRoutines.isEmpty } // internal for tests (`startingRoutines` is private to this file)
    /// Things the user should hear about the data files (an unreadable file and where its copy is, a failed save).
    /// The first one is shown as an alert; `dismissDataNotice` moves on to the next.
    private(set) var dataNotices: [StoreNotice] = []

    // MARK: UI state

    var drafts: [UUID: String] = [:]
    /// The drafts as last written to `rascunhos.json` (see `saveDraftsIfChanged`).
    @ObservationIgnored var savedDrafts: [UUID: ComposerDraft] = [:]
    var showInspector = true

    /// Opens or closes the Orb's panel the same way from every path: the column slides in the content curve, and not
    /// at all under Reduce Motion. (`showInspector` itself is state, not a token: nothing here is animated per change.)
    func setInspector(_ open: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(Motion.panel(reduceMotion: reduceMotion)) { showInspector = open }
    }

    func toggleInspector() { setInspector(!showInspector) }
    var showNewBot = false
    /// The kept memory the new-Orb sheet starts from when it opens from the welcome screen (nil: no memory chosen).
    var newBotStart: KeptMemory?
    /// The new-Orb sheet opens on "Importar de outro assistente" (from the welcome screen or the command palette).
    var newBotImporting = false
    /// Why the welcome screen is on (nil: it simply is the empty list). Cleared when the screen goes or an Orb is made.
    var welcomeReason: WelcomeReason?
    /// Where the welcome screen remembers that an Orb was made once (so an empty list reads "Hora de um Orb novo").
    /// The app's own preferences only in the running app; a developer run or a test keeps it in memory.
    @ObservationIgnored var welcomePreferences: any PreferenceStore = InMemoryPreferences()
    // Commands and shortcuts (see AppModel+Commands.swift).
    var showCommandPalette = false
    var showShortcuts = false
    /// The cursor is in the find field of a chat: Esc and ⌘↩ are the field's, not an approval card's.
    @ObservationIgnored var findFieldHasFocus = false
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
    /// The task the Orb just scheduled from the chat: its row in the panel is highlighted for a moment (`AppModel.schedule`).
    var freshRoutine: UUID?
    /// How long that highlight lasts.
    @ObservationIgnored var freshDuration = Duration.seconds(2.5)
    /// Where Claude Code's tools server asks for the same (see `ScheduleMailbox`); it starts listening with the first
    /// Claude Code turn.
    @ObservationIgnored private(set) lazy var scheduleMailbox = ScheduleMailbox.Server(
        directory: store.directory.appending(path: "agendamentos")) { [weak self] orb, arguments in
            guard let self else { throw ToolError("O app está fechando.") }
            return try self.schedule(arguments, orb: orb)
        }
    /// The "Esqueceu isso. Desfazer" of the memory screens: here so it outlives the panel being rebuilt (switching Orbs).
    @ObservationIgnored let memoryUndo = MemoryUndo()
    /// Which phrases of the working line VoiceOver is told (not more often than every 8 s).
    @ObservationIgnored var workAnnouncer = WorkAnnouncer()
    var connectorStatus: [UUID: MCPStatus] = [:]
    /// Where each installed local connector (Agenda, Lembretes, Gmail) stands with macOS: filled by `refreshLocalStates`.
    var localStates: [LocalConnectorKind: LocalConnectorState] = [:]
    /// Providers with a key in the Keychain (or, for ChatGPT and Claude Code, a sign-in).
    private(set) var connected: Set<ProviderKind> = []
    /// Providers with a key in the Keychain, the gateway's optional one included (`connected` has only the ones that
    /// need a key to work, so the gateway's row can say "Chave salva").
    private(set) var storedKeys: Set<ProviderKind> = []
    /// True once the first `refreshConnections` has finished (Keychain, ChatGPT, `claude auth status`): before that,
    /// `connected` is empty only because nobody has looked yet, and a screen that depends on it must not guess.
    private(set) var hasCheckedConnections = false {
        didSet { if hasCheckedConnections { releaseConnectionWaiters() } }
    }
    @ObservationIgnored private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Counts the memories that finished being kept after an Orb was deleted with `keepMemory` (the copy runs in the
    /// background, so the list of kept memories changes some time after the Orb is gone).
    private(set) var keptMemoriesVersion = 0
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
    /// The Orbs' browsers (`navegador/<id>/` in the data folder holds what each keeps, logins included).
    @ObservationIgnored var browserHub: BrowserHub
    /// Ajustes → Navegador: installs, updates and removes the browsers the Orbs drive (`navegador/bin`, `chrome`, `cloak`).
    @ObservationIgnored lazy var browserSetup: BrowserSetup = {
        let root = browserHub.profilesDirectory ?? store.directory.appending(path: "navegador")
        let installer = BrowserInstaller(layout: BrowserInstallLayout(root: root))
        return BrowserSetup(installer: installer, status: { [weak self] engine in
            await self?.browserHub.status(for: engine) ?? BrowserEngineStatus(engine: engine)
        }, closeBrowsers: { [weak self] engine in await self?.browserHub.close(engine: engine) })
    }()
    /// What the models are used for, kept by the hour (`uso/` in the data folder); see `recordUsage`.
    @ObservationIgnored let usageLog: UsageRecorder
    /// Every Orb's own memory bank (`memoria/<id>/` in the data folder).
    @ObservationIgnored let memory: MemoryLibrary
    /// Where Ajustes → Geral keeps the switches the app reads while it works (tests give it a suite of their own).
    @ObservationIgnored var preferences = UserDefaults.standard
    /// The approval cards open in any turn, whichever engine runs it (internal so tests can open cards).
    @ObservationIgnored let gate: ApprovalGate
    @ObservationIgnored let engine: AgentEngine
    @ObservationIgnored private let claudeEngine: ClaudeCodeEngine
    @ObservationIgnored let mcp: MCPManager
    /// The logins of the remote connectors (tokens in the vault, account `mcp.<id>.oauth`).
    @ObservationIgnored let connectorAuth: MCPAuth
    /// Opens the page a login continues on (the browser; tests put a stand-in).
    @ObservationIgnored var opensLoginPage: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    /// Keeps the tokens of connectors in the Keychain instead of the data file.
    @ObservationIgnored let connectorSecrets: ConnectorSecrets
    /// The registrations of connectors, one after another: waiting for the last one means `mcp` knows every connector.
    @ObservationIgnored private var connectorSync: Task<Void, Never>?
    /// Whether a Claude Code turn may renew an old connector catalog in the background (only the running app does), and
    /// when each connector was last tried, so one that fails is not started again at every message.
    @ObservationIgnored var renewsCatalogs: Bool // internal so tests can switch it on
    @ObservationIgnored private var catalogRenewals: [UUID: Date] = [:]
    /// The connectors being logged in through the browser now (their cards show it, whichever screen started it).
    var signingIn: Set<UUID> = []
    @ObservationIgnored var loginAttempts: [UUID: Task<String?, Never>] = [:]
    /// Processes the Orbs left running with `run_command(background: true)`.
    @ObservationIgnored let jobs = BackgroundJobs()
    /// Where the app keeps its secrets (the Keychain in the app, a dictionary in tests): "Redefinir o Orb" removes them.
    @ObservationIgnored let secretVault: any SecretVault
    /// "Redefinir o Orb" is under way: nothing is saved any more and the app quits when it is done (`resetEverything`;
    /// only the reset sets this).
    var isResetting = false
    /// Counts the changes of the profile photo, so a slow one that a later choice or a removal overtook is dropped.
    @ObservationIgnored var profilePhotoGeneration = 0
    /// What the reset needs from outside the app (tests lead it to a temporary folder and keep it from quitting).
    @ObservationIgnored var resetEnvironment = ResetEnvironment()
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
    /// When the Mac last woke from sleep: a routine that came due meanwhile waits for the network (see `runDueRoutines`).
    @ObservationIgnored private var wokeAt: Date?
    /// Since when the Mac is going to sleep or asleep: the scheduler's timer can resume before the wake notification arrives,
    /// so "asleep" is set beforehand. The wake clears it, or passes going on long after it (a wake that never came).
    @ObservationIgnored private var asleepSince: Date?
    /// When the scheduler last looked at the routines: a long gap since then means the Mac slept in between.
    @ObservationIgnored private var lastRoutinePass: Date?
    /// How long after waking the routines hold back: Wi-Fi and DNS are usually back by then.
    nonisolated static let wakeSettleTime: TimeInterval = 45
    /// A gap between two passes of the scheduler (30 s apart) beyond which the Mac must have slept.
    nonisolated static let sleepGap: TimeInterval = 90
    /// How long "going to sleep" holds the routines back without a wake.
    nonisolated static let sleepHold: TimeInterval = 120
    /// Orbs whose chat is being replaced (a new or a reopened conversation): the archive is written first, and a second
    /// request meanwhile would archive the same chat twice. Observed: the composer holds sending until it is over, or a
    /// message would land in the chat that is about to be replaced.
    private(set) var changingChat: Set<UUID> = []
    /// Conversations of finished routine runs whose file could not be written, by routine.
    @ObservationIgnored var unsavedRoutineConversations: [UUID: (botID: UUID, conversation: Conversation)] = [:]
    /// A change of the open chat ("Nova conversa", a reopened one) whose archive write is on the store's queue, by Orb:
    /// the step that installs the other chat comes later, and quitting in between must not leave both (`undoChatChangesForQuit`).
    @ObservationIgnored private var pendingChatChanges: [UUID: PendingChatChange] = [:]
    private struct PendingChatChange {
        var token = UUID()
        /// The archive entry of the chat that is leaving, once its write is queued.
        var summaryID: UUID?
    }
    /// The Keychain reads of a `refreshConnections` under way, and which state of the Keychain they started from
    /// (`keychainGeneration` changes when the app itself changes a key).
    @ObservationIgnored private var keyReads: (generation: Int, task: Task<Set<ProviderKind>, Never>)?
    @ObservationIgnored private var keychainGeneration = 0
    /// Counts the starts of `refreshConnections` and the sign-outs, in one sequence: a refresh only publishes its result if no
    /// newer one started meanwhile (`latestConnectionsRefresh`; one that is outdated waits for it, so its caller sees the result), and drops a provider that was signed out after it began.
    @ObservationIgnored private var connectionsEvents = 0
    @ObservationIgnored private var latestConnectionsRefresh: (run: Int, task: Task<Void, Never>)?
    @ObservationIgnored private var signedOutAt: [ProviderKind: Int] = [:]
    /// ChatGPT's sign-out runs apart from `signOut`; a refresh waits for it so it cannot read the credential it is erasing.
    @ObservationIgnored private var chatGPTSignOut: Task<Void, Never>?
    /// Where the sign-ins are read from and written to: the Keychain, ChatGPT's session and the `claude` CLI in the app; tests
    /// replace them.
    @ObservationIgnored var connectionSources = ConnectionSources.live
    @ObservationIgnored private(set) var scheduler: Task<Void, Never>?
    /// What the app asks of macOS for its routines (see `syncActivities`): the real thing in the running app, nothing elsewhere.
    @ObservationIgnored var activity: any ActivityAsserting = InertActivity()
    @ObservationIgnored var runningActivity: (any NSObjectProtocol)?
    @ObservationIgnored var waitingActivity: (any NSObjectProtocol)?
    /// Whether the app stays out of App Nap while a routine is switched on (the running app; not tests or developer runs).
    @ObservationIgnored var keepsAwakeForRoutines = false
    /// The model-list refresh the scheduler started, while it runs, and the providers whose last automatic attempt failed.
    @ObservationIgnored private var modelRefresh: Task<Void, Never>?
    @ObservationIgnored private var modelRefreshFailures: [ProviderKind: ModelRefreshBackoff.Failure] = [:]
    /// How a provider's model list is loaded: the live one asks the Keychain (or the sign-in) and the network; tests put a fake here.
    @ObservationIgnored var loadModels: (ProviderAccount) async throws -> [ProviderModel] = { account in
        try await ModelCatalog.fetch(account, token: try await AppModel.credentials(for: account.kind)(false))
    }
    /// Whether this is a developer mode (`--snapshot`, `--render-*`): it draws and exits, so nothing with an effect
    /// outside the process runs in it, not even over a data folder with routines or connectors (see `DevRun`).
    @ObservationIgnored let isDevRun: Bool
    /// Whether this run may look at the real Mac (the folders of other assistants): not a developer run.
    var readsRealMac: Bool { !isDevRun }
    /// Whether a turn's end may start a note on the stretch the next fold will take (see `ChunkSummary`): only in the
    /// running app. Tests that do not look at it do not want their fake model asked for more.
    @ObservationIgnored var writesStretchNotes: Bool
    /// How long a local server (one slot, one conversation in its cache) must have been left alone before a note is asked of
    /// it: the time its cache takes to go cold anyway (`ContextBudget.cacheColdAfter`). A message sent before cancels it.
    @ObservationIgnored var localNoteDelay: TimeInterval = ContextBudget.cacheColdAfter
    /// What the app's own connectors (Google Agenda, Lembretes, Gmail) talk to: the Mac. Tests and snapshots put fakes here,
    /// so no permission of macOS is asked outside the running app.
    @ObservationIgnored var localEnvironment = LocalConnectorEnvironment.live {
        didSet {
            let environment = localEnvironment
            Task { [mcp] in await mcp.setLocals(environment) }
        }
    }

    /// `runsBackgroundWork: false` skips the scheduler, Keychain checks and app-wide observers (tests).
    /// `devRun` (the process's own mode unless given) also skips the scheduler, the connectors' servers and the
    /// Claude Code check, whatever `runsBackgroundWork` says.
    /// `asyncLoading` says whether the first Orb's conversation is read off the main thread after `init` returns
    /// (the window does not wait for it; the app) or before it returns (what tests rely on); it follows
    /// `runsBackgroundWork` unless given.
    /// `firstUse` is the state when there is no data yet: the app passes `.firstUse` (no Orb, the welcome); tests and
    /// the developer modes keep `.initial`, with Atlas.
    init(store: Store = .standard, runsBackgroundWork: Bool = true, asyncLoading: Bool? = nil, secretVault: (any SecretVault)? = nil,
         connectorSession: URLSession? = nil, devRun: Bool = DevRun.isActive, firstUse: AppState = .initial) {
        self.store = store
        isDevRun = devRun
        if devRun { connectionSources.claudeCodeStatus = nil } // a developer run never runs the real `claude`
        renewsCatalogs = runsBackgroundWork && !devRun
        writesStretchNotes = runsBackgroundWork && !devRun
        let vault = secretVault ?? (runsBackgroundWork && !devRun ? KeychainVault() : MemoryVault())
        self.secretVault = vault
        let secrets = ConnectorSecrets(vault: vault)
        connectorSecrets = secrets
        connectorAuth = MCPAuth(vault: vault, session: connectorSession ?? MCPAuth.liveSession)
        mcp = MCPManager(store: store, auth: connectorAuth, session: connectorSession)
        images = ImageStore(dataFolder: store.directory)
        let gate = ApprovalGate()
        self.gate = gate
        engine = AgentEngine(gate: gate)
        claudeEngine = ClaudeCodeEngine(gate: gate)
        memory = MemoryLibrary.at(store.directory.appending(path: "memoria"))
        usageLog = UsageRecorder(store: store)
        var notices: [StoreNotice] = []
        let stateRead = store.readState()
        notices += stateRead.notice.map { [Self.described($0, bots: [], routines: [])] } ?? []
        let state = stateRead.value ?? firstUse
        bots = state.bots
        routines = state.routines
        skills = state.skills
        connectors = secrets.resolve(state.connectors)
        providers = state.providers
        defaultModel = state.defaultModel
        contextMemory = state.contextMemory
        profile = state.profile
        learnedContexts = state.learnedContexts
        priceCorrections = state.priceCorrections
        groups = state.groups
        outputsDirectory = ToolOutputCap.directory(inDataFolder: store.directory)
        browserHub = BrowserHub.live(dataFolder: store.directory)
        // Only the Orb shown first is read at launch, and the window does not wait for it (`beginLoading` below).
        let readsFirstLater = asyncLoading ?? runsBackgroundWork
        for bot in state.bots { session(bot.id).isUnloaded = true }
        restoreDrafts()
        if !readsFirstLater, let first = state.bots.first {
            let read = store.readConversation(first.id)
            notices += Self.labeled(read.notice, for: first).map { [$0] } ?? []
            let shown = session(first.id)
            shown.conversation = read.value?.closingInterruptedTurn() ?? Conversation()
            shown.isUnloaded = false
            shown.lastUsed = .now
        }
        dataNotices = notices
        if runsBackgroundWork && !devRun { welcomePreferences = UserDefaults.standard }
        // Nothing will ever look at the connections in a model that is not the running app (tests, developer runs).
        hasCheckedConnections = !runsBackgroundWork || devRun
        // Orbs made by an earlier version: if they are all deleted, the welcome screen says "Hora de um Orb novo".
        if !state.bots.isEmpty { noteOrbCreated() }
        if !runsBackgroundWork { resetEnvironment = .inert } // a model that is not the running app never resets the app's preferences
        selection = state.bots.first.map { .bot($0.id) }
        self.store.onSaveFailure = { [weak self] notice in
            Task { @MainActor in self?.reportSaveFailure(notice) }
        }
        self.store.onNotice = { [weak self] notice in
            Task { @MainActor in
                guard let self else { return }
                self.addNotice(Self.described(notice, bots: self.bots, routines: self.routines))
            }
        }
        usageLog.adoptCallbacks(of: self.store) // it holds its own copy of the store, made before these were set

        syncLives()
        for (id, count) in state.unread {
            if let id = UUID(uuidString: id) { live(id).setUnread(count) }
        }
        if !devRun { // a developer run starts no server, and its screens set the statuses themselves
            let manager = mcp
            Task { [weak self] in await manager.observe { statuses in Task { @MainActor in self?.connectorStatus = statuses } } }
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
            activity = SystemActivity()
            keepsAwakeForRoutines = true
            syncActivities()
            scheduler = Task { [weak self] in
                await self?.refreshConnections()
                while !Task.isCancelled {
                    self?.runDueRoutines()
                    self?.saveDraftsIfChanged()
                    self?.startModelRefresh() // apart: a provider that does not answer must not hold up the routines
                    await self?.unloadIdleConversations()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            // The settings offer "Entrar" again. Only the app's own login counts (never a copy made by a test), and a
            // developer run never reads the Keychain.
            NotificationCenter.default.addObserver(forName: .chatGPTSessionEnded, object: ChatGPTAuth.shared, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshConnections() }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                ApprovalNotifications.clear(self?.pendingApprovals.map(\.id) ?? [])
                self?.stopTurnsForQuit() // before the save: the cards close and "Você interrompeu" is written
                self?.undoChatChangesForQuit()
                self?.saveNow()
                // Commands and CLIs in the middle of a turn lead process groups of their own and would outlive the app.
                ChildProcessGroups.killAllNow(including: self?.jobs.runningGroups ?? [])
                self?.jobs.killAllNow()
                self?.browserHub.terminateAllNow(orbs: Set(self?.bots.map(\.id) ?? [])) // each Orb's browser lives in a background process of its own that would outlive the app
                StdioServerRegistry.shared.killAllNow() // a connector's server that stays open past EOF would outlive the app
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
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
        // The write already cleared the session's "unsaved" mark; memory holds the only copy, so quitting writes it again.
        // A run's conversation already finished is not the session's (the chat is back): `unsavedRoutineConversations` has it.
        if let file = notice.file, let session = sessions.values.first(where: { store.isConversationFile(file, of: $0.id) }),
           session.conversation != nil, session.routineID != nil || !Store.isSideConversationName(file.lastPathComponent) {
            session.isDirty = true
        }
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
        if folder == "uso" { return "o histórico de uso de \(stem)" }
        if folder == "conversations", let id = UUID(uuidString: stem) {
            return bots.first { $0.id == id }.map { "a conversa de \($0.name)" }
        }
        // Inside an Orb's folder of earlier conversations: `<conversationID>`, `routine-<routineID>` or `index`.
        guard let owner = UUID(uuidString: folder).flatMap({ id in bots.first { $0.id == id } }) else { return nil }
        if stem == "index" { return "a lista de conversas antigas de \(owner.name)" }
        if stem.hasPrefix("routine-"), let id = UUID(uuidString: String(stem.dropFirst("routine-".count))) {
            return routines.first { $0.id == id }.map { "o histórico da rotina \($0.name)" } ?? "o histórico de uma rotina de \(owner.name)"
        }
        if stem.hasPrefix(Store.pedidoPrefix + "-") { return "a conversa de um pedido de outro Orb a \(owner.name)" }
        if stem.hasPrefix(Store.grupoPrefix + "-") { return "a conversa de \(owner.name) num grupo" }
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

    /// Lets go of conversations nobody is looking at: not the selected Orb's, not one that is working, parked by a
    /// routine, or waiting to be saved, and not one used within `conversationKeepAlive`. Only when the file on disk
    /// is known to hold what is in memory (the note beside it says so), and never after a failed save, when memory
    /// may be the only copy. A conversation that comes back is read again from its file, off the main thread.
    func unloadIdleConversations(now: ContinuousClock.Instant = .now, only: UUID? = nil) async {
        guard !didReportSaveFailure else { return }
        let keepAlive = conversationKeepAlive
        let candidates = sessions.values.filter { (only == nil || $0.id == only) && !changingChat.contains($0.id) && $0.isIdle(now: now, keepAlive: keepAlive) }
        for session in candidates {
            let botID = session.id
            guard let meta = await store.readMetaAsync(botID) else { continue }
            // Looked at again after waiting: it may have been used, changed or started a turn meanwhile.
            guard sessions[botID] === session, !changingChat.contains(botID), session.isIdle(now: now, keepAlive: keepAlive),
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

    /// Returns once the first look at the connections is over (at once when it already is).
    func connectionsChecked() async {
        guard !hasCheckedConnections else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    /// How many callers wait for the first look at the connections (internal for tests).
    var connectionWaiterCount: Int { connectionWaiters.count }

    private func releaseConnectionWaiters() {
        let waiting = connectionWaiters
        connectionWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Puts the model back in the state of a launch whose connections nobody has looked at yet (internal for tests).
    func beginConnectionCheck() { hasCheckedConnections = false }

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
        if live.needsYou != was {
            refreshPresence()
            syncActivities()
        }
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
        // Orbs that used one of its models go back to the default model instead of asking to connect one.
        for id in Self.bots(using: kind, in: bots) { update(id) { $0.model = "" } }
    }

    /// The Orbs whose own model is one of `kind`'s.
    nonisolated static func bots(using kind: ProviderKind, in bots: [Bot]) -> [UUID] {
        bots.filter { ModelRef($0.model)?.provider == kind }.map(\.id)
    }

    /// Forgets the key or sign-in (the provider stays listed). Claude Code's own login is left alone:
    /// it belongs to the user's Claude Code, not to Orb (see `signOutOfClaudeCode`).
    func signOut(_ kind: ProviderKind) {
        keychainGeneration += 1
        connectionSources.storeKey("", kind)
        if kind == .chatgpt { chatGPTSignOut = Task { await connectionSources.signOutOfChatGPT() } }
        connectionsEvents += 1
        signedOutAt[kind] = connectionsEvents
        if connected.contains(kind) { connected.remove(kind) }
        storedKeys.remove(kind)
        updateProvider(kind) { $0.models = [] }
    }

    func updateProvider(_ kind: ProviderKind, _ change: (inout ProviderAccount) -> Void) {
        guard let index = providers.firstIndex(where: { $0.kind == kind }) else { return }
        change(&providers[index])
    }

    /// Saves (or, when empty, removes) the provider's key and reloads its models.
    func setKey(_ key: String, for kind: ProviderKind) async throws {
        keychainGeneration += 1
        connectionSources.storeKey(key.trimmingCharacters(in: .whitespacesAndNewlines), kind)
        await refreshConnections()
        try await refreshModels(kind)
        adoptDefaultModel(from: kind) // a default that cannot be used (its login was revoked) gives way to the key just saved
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
        adoptDefaultModel(from: kind)
    }

    /// A model of a custom gateway added by hand (the list may not have a `/models`): the first one also becomes the
    /// default when nothing usable is.
    func addManualModel(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        updateProvider(.custom) {
            if !$0.models.contains(where: { $0.id == id }) {
                $0.models.append(ProviderModel(id: id, name: id, format: $0.format, isManual: true))
                $0.modelsUpdatedAt = .now
            }
        }
        adoptDefaultModel(from: .custom, turningOn: false)
    }

    /// Runs `claude auth logout`: Claude Code signs out on this Mac (in the Terminal too).
    func signOutOfClaudeCode() async {
        await ClaudeCode.shared.logout()
        await refreshConnections()
    }

    func refreshConnections() async {
        connectionsEvents += 1
        let run = connectionsEvents
        let task = Task { await readConnections(run) }
        latestConnectionsRefresh = (run, task)
        await task.value
        // An outdated refresh published nothing: whoever asked reads the state once the newest has published it.
        while let newest = latestConnectionsRefresh, newest.run > run {
            await newest.task.value
            if latestConnectionsRefresh?.run == newest.run { break }
        }
    }

    private func readConnections(_ run: Int) async {
        guard !isResetting else { // a read of a key that was just removed could bring OpenBot's copy back
            hasCheckedConnections = true
            return
        }
        let keys = await keyedProviders()
        var found = keys.filter(\.needsKey)
        await chatGPTSignOut?.value
        if await connectionSources.hasChatGPTCredential() { found.insert(.chatgpt) }
        // A newer refresh started meanwhile publishes its own result; a provider signed out after this one began stays out.
        func current(_ kinds: Set<ProviderKind>) -> Set<ProviderKind> { kinds.filter { (signedOutAt[$0] ?? 0) < run } }
        guard run == latestConnectionsRefresh?.run else {
            hasCheckedConnections = true
            return
        }
        storedKeys = current(keys)
        // Keys and ChatGPT are known now, `claude auth status` may take a while: the Orbs that do not use Claude Code
        // can already send (its place stays as it was, so a refresh does not make it blink).
        connected = current(found).union(connected.intersection([.claudeCode]))
        var status: ClaudeCodeStatus?
        if let reader = connectionSources.claudeCodeStatus, account(.claudeCode) != nil { // the status runs the real `claude`
            status = await reader()
            if status?.isLoggedIn == true { found.insert(.claudeCode) }
        }
        hasCheckedConnections = true
        // The status took a while; what changed meanwhile wins over it (see above).
        guard run == latestConnectionsRefresh?.run else { return }
        if let status { claudeCode = status }
        publishConnections(current(found))
    }

    /// The end of a look at the connections (internal for tests, which never read the Keychain).
    func publishConnections(_ found: Set<ProviderKind>) {
        connected = found
        hasCheckedConnections = true
    }

    /// Whether ChatGPT has a login on this Mac (the first-run card asks before signing in again).
    func hasChatGPTLogin() async -> Bool { await connectionSources.hasChatGPTCredential() }

    /// Providers with a key in the Keychain. Each read takes milliseconds (and the system may ask permission for an
    /// item another app made), so they run off the main thread; a refresh asked for while another is under way
    /// (launch asks from more than one place) shares its reads instead of repeating them.
    private func keyedProviders() async -> Set<ProviderKind> {
        if let running = keyReads, running.generation == keychainGeneration { return await running.task.value }
        let generation = keychainGeneration
        let keyed = connectionSources.keyedProviders
        let task = Task.detached(priority: .userInitiated) { keyed() }
        keyReads = (generation, task)
        let found = await task.value
        if keyReads?.task == task { keyReads = nil }
        return found
    }

    /// Reloads the provider's live model list; picks a default model if there is none yet.
    func refreshModels(_ kind: ProviderKind) async throws {
        guard let current = account(kind) else { return }
        let fetched = try await loadModels(current)
        modelRefreshFailures[kind] = nil
        updateProvider(kind) {
            // Read inside the update, so a model added by hand while the list was loading is kept.
            $0.models = kind == .custom ? ModelCatalog.mergingManual(fetched: fetched, previous: $0.models) : fetched
            $0.modelsUpdatedAt = .now
        }
        if ModelRef(defaultModel).flatMap({ account($0.provider) }) == nil, let first = ModelCatalog.preferredDefault(fetched) {
            defaultModel = ModelRef(provider: kind, model: first.id).text
        }
    }

    /// After the user connected `kind` on purpose (the first-use card): when the default model cannot be used
    /// (its provider is signed out, has no key, or was turned off) the new provider's first model takes its place,
    /// and the provider is turned on if it was off. `refreshModels` alone only replaces a default whose provider is
    /// gone from the list, so a stale default would keep the new connection from ever counting as ready. Ajustes
    /// does the same when a key or a sign-in is saved, a gateway gets its first model by hand, or a refresh is asked for.
    @discardableResult
    func adoptDefaultModel(from kind: ProviderKind, turningOn: Bool = true) -> Bool {
        guard !isProviderReady, let account = account(kind), isUsable(account), let first = ModelCatalog.preferredDefault(account.models) else { return false }
        if !account.isEnabled {
            guard turningOn else { return false } // a refresh does not switch back on what the user switched off
            updateProvider(kind) { $0.isEnabled = true }
        }
        defaultModel = ModelRef(provider: kind, model: first.id).text
        return true
    }

    /// Keeps model lists current: on launch and then every few hours, for every usable provider. A list that fails to
    /// load is tried again after a growing wait (`ModelRefreshBackoff`), not at every tick of the scheduler; the
    /// refresh the user asks for (`refreshModels`) always tries.
    func refreshAllModels(olderThan age: TimeInterval = 6 * 3600, now: Date = .now) async {
        for account in providers where account.isEnabled && isUsable(account)
            && ModelRefreshBackoff.isDue(updatedAt: account.modelsUpdatedAt, failure: modelRefreshFailures[account.kind], now: now, age: age) {
            do {
                try await refreshModels(account.kind)
            } catch {
                guard !Task.isCancelled else { return }
                modelRefreshFailures[account.kind] = .init(
                    at: now, count: (modelRefreshFailures[account.kind]?.count ?? 0) + 1,
                    credentialRefused: (error as? LLMError)?.isCredentialRefusal == true)
            }
        }
    }

    /// Starts `refreshAllModels` beside the scheduler's other work: a host that does not answer holds this task for as
    /// long as its timeout, not the routines that are due. One at a time.
    private func startModelRefresh() {
        guard modelRefresh == nil else { return }
        modelRefresh = Task { [weak self] in
            await self?.refreshAllModels()
            self?.modelRefresh = nil
        }
    }

    /// Looked up again before every model request, so an expired sign-in is refreshed and a changed key is picked up.
    static func credentials(for kind: ProviderKind) -> CredentialsProvider {
        { forceRefresh in
            kind == .chatgpt ? try await ChatGPTAuth.shared.accessToken(forceRefresh: forceRefresh) : Keychain.get(kind.rawValue)
        }
    }

    // MARK: Bots

    /// A new Orb comes with its own memory, and says hello in its conversation (`OrbGreeting`). `identity` (how it should
    /// work, written by you) starts it; with `interview` it also asks about you in its first conversation and keeps the
    /// answers. Unless `folder` says otherwise it gets a folder of its own in `base` (`~/Orbs`); if that cannot be made it
    /// works in the home folder and says so in its conversation. `importing` (what another assistant knew, as the person
    /// confirmed it in the preview) is written into the new memory, and its skills are made for this Orb alone; it is
    /// ignored when the Orb starts from a kept memory. Nothing in it reaches the Orb's mode, capabilities or folder.
    @discardableResult
    func createBot(name: String, role: String, orb: OrbConfig, model: String, mode: PermissionMode,
                   identity: String = "", interview: Bool = true, folder: OrbFolderChoice = .own,
                   base: URL = OrbFolder.defaultBase, adopting kept: KeptMemory? = nil, importing imported: OrbImport? = nil) -> Bot {
        let name = Self.clippedName(name)
        let kept = isResetting ? nil : kept // a kept memory is not moved while the reset walks through the folder
        let plan = kept == nil ? imported?.plan() : nil
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
        welcomeReason = nil
        noteOrbCreated()
        if let folderProblem { append(.notice("\(folderProblem). \(bot.name) vai trabalhar na pasta pessoal."), to: bot.id) }
        // Starting from a kept memory: its folder becomes this Orb's (a rename, so it is as quick as making a folder).
        // When it cannot be moved the Orb starts with a memory of its own and says so.
        let adopted = kept.map { memory.adopt($0, as: bot.id) } ?? false
        if kept != nil, !adopted { append(.notice("Não foi possível usar a memória guardada. \(bot.name) começou com uma memória nova."), to: bot.id) }
        if let plan, !plan.isEmpty, let imported {
            for draft in plan.skills {
                addSkill(slug: draft.slug, name: draft.name, summary: draft.summary, instructions: draft.instructions,
                         source: Skill.importedSource, orbIDs: [bot.id])
            }
            append(.notice("Importei de \(imported.source): \(plan.sentence). Veja na aba Memória."), to: bot.id)
        }
        // The Orb's first words, last so its quick replies are what the chat ends with (see `GreetingReplies`).
        append(.greeting(OrbGreeting.text(name: bot.name, temperament: orb.temperament, returning: adopted)), to: bot.id)
        let bank = memory.bank(for: bot.id)
        // Imported instructions or preferences are what an interview would have asked for.
        let notes = [identity.trimmingCharacters(in: .whitespacesAndNewlines), plan?.identity ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let answered = !(plan?.identity.isEmpty ?? true) || plan?.pages.contains { $0.kind == .preferencia } == true
        Task {
            if adopted {
                await bank.startFromKept(notes: identity, interview: interview)
            } else {
                await bank.ensureIdentity(notes: notes, interview: interview && !answered)
                if let plan { await bank.importPages(plan.pages) }
            }
            await refreshMemory(bot.id)
        }
        return bot
    }

    func update(_ botID: UUID, _ change: (inout Bot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        var bot = bots[index]
        let mode = bot.permissionMode
        let engine = bot.browserEngine, hadBrowser = bot.capabilities.contains(.browser)
        change(&bot)
        if bot != bots[index] { bots[index] = bot }
        if bot.permissionMode != mode { permissionModeChanged(botID, to: bot.permissionMode) }
        // Another engine is another browser, and without "Navegar na web" there is none: the one that was open is closed now,
        // not when the Orb next needs a browser.
        if bot.browserEngine != engine || (hadBrowser && !bot.capabilities.contains(.browser)) {
            let hub = browserHub
            Task { await hub.close(botID: botID) }
        }
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
        let profile = bot(botID).map(KeptProfile.init)
        let session = session(botID)
        liveBot(botID)?.stopComposing() // its watcher task ends with it
        session.memoryRequest = nil
        session.lastCompaction = nil
        session.compactedInTurn = false
        session.foldedNotes = []
        // First, so that stopping a running routine does not start the next one waiting for this Orb.
        let ownRoutines = routines.filter { $0.botID == botID }.map(\.id)
        queuedRoutines.removeAll { ownRoutines.contains($0) }
        routines.removeAll { $0.botID == botID }
        delegation.orbDeleted(botID) // before the stop: whoever waited for this Orb is told, and what it asked is dropped
        stop(botID)
        let jobs = jobs
        Task { await jobs.forget(botID: botID) }
        let pictures = images, outputs = outputsDirectory
        Task.detached(priority: .utility) {
            pictures.deleteAll(for: botID)
            ToolOutputCap.removeAll(for: botID, in: outputs)
        }
        let browsers = browserHub
        Task { await browsers.deleteData(botID: botID) }
        session.memoryIdle?.cancel()
        session.memoryIdle = nil
        session.skillReview?.cancel()
        let library = memory
        var keeping: Task<URL?, Never>?
        if keepMemory {
            let stretch = session.pendingStretch()
            let bank = library.bank(for: botID)
            let copying = Task.detached(priority: .utility) {
                if let stretch, let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
                return library.keep(botID, name: name, profile: profile)
            }
            keeping = copying
            // The welcome screen lists the kept memories: it reads again when this one has arrived.
            Task { [weak self] in
                _ = await copying.value
                self?.keptMemoriesVersion += 1
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

    // MARK: Reset

    /// The first thing "Redefinir o Orb" does: stops everything the app is doing, so nothing writes while the data is
    /// removed and nothing starts again after: the scheduler, every Orb's turn (Claude Code's process included), the
    /// routines and their queue, the approval cards and banners, the connectors. Returns when the turns have ended, or
    /// after `wait` (a command that does not stop does not hold the reset). Writing is sealed before this is called.
    func stopForReset(wait: Duration = .seconds(3)) async {
        stateSave?.cancel()
        stateSave = nil
        let loop = scheduler
        loop?.cancel()
        scheduler = nil
        modelRefresh?.cancel()
        modelRefresh = nil
        queuedRoutines = []
        routines = [] // the end of a running routine finds nothing to record
        delegation.cancelAll(by: .switchOff, includingGroups: true) // no request between Orbs outlives the reset
        var ending: [Task<Void, Never>] = loop.map { [$0] } ?? []
        if let reads = keyReads?.task { ending.append(Task { _ = await reads.value }) }
        ending += sessions.values.compactMap(\.turnTask)
        for session in sessions.values {
            session.memoryIdle?.cancel()
            session.memoryIdle = nil
            session.memoryRequest = nil
            session.skillReview?.cancel()
            session.skillReview = nil
            session.saveTask?.cancel()
            session.saveTask = nil
            session.cancelChunkNote()
            stop(session.id)
        }
        for bot in bots { await gate.cancelApprovals(for: bot.id) }
        ApprovalNotifications.clearStale()
        // The connectors stop (a server still starting is stopped by it, not waited for), inside the same wait.
        connectorSync?.cancel()
        let mcp = mcp
        ending.append(Task { await mcp.sync([]) })
        let finished = OSAllocatedUnfairLock(initialState: false)
        Task {
            for task in ending { await task.value }
            finished.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + wait
        while !finished.withLock({ $0 }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    }

    // MARK: Conversation history

    /// Starts a new conversation. The current one is archived (when you said anything in it), not thrown away: it is
    /// replaced only once its archive file is on disk, so a full disk leaves it open instead of losing it. The draft
    /// belongs to the Orb, not to the conversation: it stays in the composer, with what was queued during a stopped
    /// turn (which `leaveChat` gave back to it, attachments and all). Returns the task that finishes the change
    /// (nil when there is nothing to wait for or one is already under way).
    @discardableResult
    func newConversation(_ botID: UUID) -> Task<Void, Never>? {
        guard bot(botID) != nil, !changingChat.contains(botID) else { return nil }
        // Before the turn stops: a routine waiting for this Orb would take it in between, over the chat being archived.
        changingChat.insert(botID)
        leaveChat(botID)
        guard let leaving = chatToArchive(botID) else {
            session(botID).installChat(Conversation())
            endChatChange(botID)
            return nil
        }
        guard leaving.chat.hasUserMessages else {
            leaving.keepStretch(in: session(botID))
            session(botID).installChat(Conversation())
            endChatChange(botID)
            return nil
        }
        let change = PendingChatChange()
        pendingChatChanges[botID] = change
        return Task { [weak self] in
            guard let self else { return }
            defer {
                if pendingChatChanges[botID]?.token == change.token { pendingChatChanges[botID] = nil }
                endChatChange(botID)
            }
            guard pendingChatChanges[botID]?.token == change.token else { return } // undone before it began
            guard let summary = await archiveForChange(leaving.chat, of: botID) else {
                addNotice(Self.couldNotArchive)
                return
            }
            guard pendingChatChanges[botID]?.token == change.token else { return } // the app was quitting: undone
            // Said something meanwhile: the new conversation would throw that away. The chat stays open, and the
            // copy just archived goes, or the next attempt would list the same conversation twice.
            guard bot(botID) != nil, isUnchanged(botID, since: leaving) else {
                store.deleteArchived(summary.id, for: botID)
                if bot(botID) != nil { addNotice(Self.changedMeanwhile) }
                return
            }
            noteArchived(summary, leaving, of: botID)
            session(botID).installChat(Conversation())
        }
    }

    /// Makes an archived conversation the current one. The current one is archived first (if you said anything in
    /// it), so nothing is lost either way. The conversation keeps its Claude Code session and its memory
    /// bookkeeping (how much of it is already saved as memory), so reopening it saves nothing twice. The file is read
    /// off the main thread; what changed meanwhile is looked at again before the chat is replaced. The archived copy
    /// goes only after both the current chat's archive and the reopened one are written: with a full disk the change
    /// is given up and nothing is lost.
    @discardableResult
    func reopenConversation(_ id: UUID, of botID: UUID) async -> Bool {
        guard bot(botID) != nil, !reopening.contains(id), !changingChat.contains(botID) else { return false }
        reopening.insert(id)
        changingChat.insert(botID)
        defer {
            reopening.remove(id)
            endChatChange(botID)
        }
        let read = await store.readArchivedAsync(id, for: botID)
        // The Orb was deleted, or the conversation was deleted from the list, while it was being read.
        guard let owner = bot(botID), archives[botID]?.contains(where: { $0.id == id }) ?? true else { return false }
        addNotice(Self.labeled(read.notice, for: owner))
        guard let chosen = read.value else {
            archives[botID]?.removeAll { $0.id == id }
            return false
        }
        leaveChat(botID)
        let leaving = chatToArchive(botID)
        let change = PendingChatChange()
        pendingChatChanges[botID] = change
        defer { if pendingChatChanges[botID]?.token == change.token { pendingChatChanges[botID] = nil } }
        var summary: ConversationSummary?
        if let leaving, leaving.chat.hasUserMessages {
            summary = await archiveForChange(leaving.chat, of: botID)
            guard summary != nil else {
                addNotice(Self.couldNotArchive)
                return false
            }
        }
        guard pendingChatChanges[botID]?.token == change.token else { return false } // the app was quitting: undone
        let reopened = chosen.closingInterruptedTurn()
        // Given up after the current chat was archived: that copy goes, the chat is still open and would be archived again.
        func giveUp() -> Bool {
            if let summary { store.deleteArchived(summary.id, for: botID) }
            return false
        }
        guard bot(botID) != nil, isUnchanged(botID, since: leaving) else {
            if bot(botID) != nil { addNotice(Self.changedMeanwhile) }
            return giveUp()
        }
        guard await store.saveAndWait(reopened, for: botID) else {
            addNotice(Self.couldNotReopen)
            return giveUp()
        }
        guard pendingChatChanges[botID]?.token == change.token else { return false } // the app was quitting: undone
        guard bot(botID) != nil, isUnchanged(botID, since: leaving) else {
            if bot(botID) != nil { addNotice(Self.changedMeanwhile) }
            // The file holds the reopened chat by now: the one still open goes back on disk before its archived copy goes.
            if let session = sessions[botID] {
                session.isDirty = true
                session.saveNow()
            }
            return giveUp()
        }
        if let leaving {
            if let summary { noteArchived(summary, leaving, of: botID) } else { leaving.keepStretch(in: session(botID)) }
        }
        session(botID).installChat(reopened)
        store.deleteArchived(id, for: botID) // the reopened chat is on disk by now: only then does its archived copy go
        archives[botID]?.removeAll { $0.id == id }
        return true
    }

    /// `archiveAndWait` for a change of the open chat: the entry is noted as soon as its write is queued, so that
    /// quitting before the change is finished can take it back.
    private func archiveForChange(_ chat: Conversation, of botID: UUID) async -> ConversationSummary? {
        let summary = ConversationSummary(of: chat)
        pendingChatChanges[botID]?.summaryID = summary.id
        let store = store
        let archived = await withCheckedContinuation { continuation in
            store.archive(chat, as: summary, for: botID) { continuation.resume(returning: $0) }
        }
        return archived ? summary : nil
    }

    /// Quitting while a new or reopened conversation waits for its archive write: the step that would finish the
    /// change (opening the other chat) will not run, and the file would still hold the old chat beside its archived
    /// copy. The change is given up instead: the open chat goes back on disk (the file may already hold the reopened
    /// one) and the entry just archived goes. Nothing is lost, nothing is listed twice.
    var hasQueuedChatArchive: Bool { pendingChatChanges.values.contains { $0.summaryID != nil } } // internal for tests

    func undoChatChangesForQuit() {
        guard !isResetting else { return }
        for (botID, change) in pendingChatChanges {
            if let session = sessions[botID] {
                session.isDirty = true
                session.saveNow()
            }
            if let id = change.summaryID { store.deleteArchived(id, for: botID) }
        }
        pendingChatChanges = [:]
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

    /// The chat that is about to leave, and what of it is not yet in memory (saved once, when it has left).
    private struct LeavingChat {
        var chat: Conversation
        var stretch: [TranscriptItem]
        var itemCount: Int

        @MainActor func keepStretch(in session: BotSession) {
            if !stretch.isEmpty { session.persistStretch(stretch) }
        }
    }

    private func chatToArchive(_ botID: UUID) -> LeavingChat? {
        guard let session = sessions[botID], var chat = session.parkedChat ?? session.conversation else { return nil }
        let count = chat.items.count
        let start = min(chat.memorySavedCount ?? 0, count)
        let stretch = Array(chat.items[start...])
        // The mark of how much is saved goes into the archive with the conversation.
        if !stretch.isEmpty { chat.memorySavedCount = count }
        return LeavingChat(chat: chat, stretch: stretch, itemCount: count)
    }

    /// Whether nothing was said in the chat since it was looked at (the awaits in between let the user go on typing).
    private func isUnchanged(_ botID: UUID, since leaving: LeavingChat?) -> Bool {
        guard let leaving else { return true }
        let session = sessions[botID]
        return (session?.parkedChat ?? session?.conversation)?.items.count == leaving.itemCount
    }

    /// The chat is in the archive: its menu entry, and the memory page of what was not yet kept.
    private func noteArchived(_ summary: ConversationSummary, _ leaving: LeavingChat, of botID: UUID) {
        leaving.keepStretch(in: session(botID))
        if archives[botID] != nil {
            archives[botID]?.append(summary)
            archives[botID]?.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    private static let couldNotArchive = StoreNotice(
        message: "Não foi possível guardar esta conversa em conversas anteriores (talvez falte espaço no disco). Ela continua aberta.")
    private static let changedMeanwhile = StoreNotice(
        message: "A conversa mudou enquanto era guardada, então a nova conversa não foi aberta. Ela continua aberta.")
    private static let couldNotReopen = StoreNotice(
        message: "Não foi possível reabrir a conversa: o disco não aceitou a gravação (talvez falte espaço). A conversa atual continua aberta e a outra segue em conversas anteriores.")

    // MARK: Memory

    /// `onlyIfChanged`: the end of every turn asks; the bank reads and sends every page again only when something
    /// changed since the last snapshot (the panel, the other callers, always get a fresh one).
    func refreshMemory(_ botID: UUID, onlyIfChanged: Bool = false) async {
        guard bot(botID) != nil else { return }
        let bank = memory.bank(for: botID)
        guard let snapshot = onlyIfChanged ? await bank.snapshotIfChanged() : await bank.snapshot() else { return }
        if bot(botID) != nil { live(botID).setMemory(snapshot) }
    }

    /// Saves your edit of the identity notes. False (with a notice) when they could not be written: the editor stays open.
    func setIdentity(_ text: String, of botID: UUID) async -> Bool {
        let bank = memory.bank(for: botID)
        let saved = await bank.setIdentity(text)
        if !saved && bot(botID) != nil { addNotice(Self.couldNotSaveIdentity) }
        await refreshMemory(botID)
        return saved
    }

    private static let couldNotSaveIdentity = StoreNotice(
        message: "Não foi possível salvar as notas do Orb (talvez falte espaço no disco, ou as notas sejam longas demais). O que você escreveu continua no editor.")

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
            if !send(text, to: botID) { returnToDraft(text, of: botID) }
            return
        }
        Task {
            await loadedConversation(botID)
            ensureLoaded(botID)
            if !send(text, to: botID) { returnToDraft(text, of: botID) }
        }
    }

    /// Refused after the caller let go of the text: it goes back to the Orb's draft instead of being lost. While a
    /// message is being edited it goes to what the composer held before (the edit's text is not a draft).
    private func returnToDraft(_ text: String, of botID: UUID) {
        if sessions[botID]?.lane?.editing != nil {
            sessions[botID]?.lane?.editing?.stash.putBack(text: text, separator: "\n")
            return
        }
        setDraft(drafts[botID].map { $0.isEmpty ? text : text + "\n" + $0 } ?? text, for: botID)
    }

    /// The model this Orb would use is connected and on (`send` refuses otherwise).
    func hasUsableModel(_ botID: UUID) -> Bool {
        guard let bot = bot(botID), let ref = modelRef(for: bot), let account = account(ref.provider) else { return false }
        return account.isEnabled && isUsable(account)
    }

    /// The card that connects a model has nothing to do for this Orb: its own model works, or the default one does
    /// (`send` then only reports the Orb's own model down, which the card cannot fix).
    func hasModelSetup(for botID: UUID) -> Bool { hasUsableModel(botID) || isProviderReady }

    /// What the model is asked when the message is only files.
    nonisolated static let attachmentsOnlyPrompt = "Veja o(s) arquivo(s) anexado(s)."

    /// Starts a turn. Returns false when nothing was sent (empty text, a turn already running, no usable model),
    /// so the composer keeps what you wrote. Only a message typed in the composer (`fromUser`) clears its draft:
    /// routines and quick ask must not wipe what you are typing for that Orb. `bubble` is the id of the message's row in
    /// the chat (an edited message keeps its row); `endsEdit: false` is for the send of the edit itself, which any other
    /// turn that starts while a message is being edited ends (see below).
    /// `origin`: where the text comes from. A request from another Orb or the answers to the Orb's own requests (`SendOrigin`)
    /// enter the conversation as `.orbMessage` lines, not as your bubble; they read no memory request, expand no skill, and
    /// the turn carries the grant for `orbs` (see `DelegationHub`).
    @discardableResult
    func send(_ text: String, attachments: [URL] = [], images pictures: [ImageAttachment] = [], to botID: UUID,
              fromUser: Bool = false, bubble: UUID = UUID(), endsEdit: Bool = true, origin: SendOrigin = .user) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = session(botID)
        // A routine's prompt goes to its own conversation (the chat is parked), so a chat being swapped is no obstacle to it.
        guard !isResetting, !typed.isEmpty || !pictures.isEmpty || !attachments.isEmpty, session.turnTask == nil,
              session.routineID != nil || !changingChat.contains(botID),
              let bot = effectiveBot(botID) else { return false }
        ensureLoaded(botID)
        // "/compactar [foco]" is a command of the composer, not a message for the model.
        if fromUser, attachments.isEmpty, pictures.isEmpty, let focus = CompactionCommand.parse(typed) {
            setDraft("", for: botID)
            runCompactionCommand(focus: focus, for: botID)
            return true
        }
        guard let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else {
            if !hasCheckedConnections {
                // `connected` is empty only because nobody has looked yet: no card, no notice. The composer waits for the
                // look and sends then (`ComposerView.send`); what was typed stays.
            } else if fromUser && !isProviderReady {
                // The first-use card or banner is on screen: it pulses, and what you typed stays in the composer.
                setupNudge += 1
            } else {
                append(.notice("Conecte um modelo em Ajustes → Modelos para começar."), to: botID)
            }
            return false
        }
        let modelInfo = account.models.first { $0.id == ref.model }
        let sees: Bool? = visionRejected.contains(ref.text) ? false : modelInfo?.supportsImages

        // A turn begins here. If a message of the chat is being edited, the turn is not the edit's own send (that one cuts the
        // chat first and passes `endsEdit: false`): a notice's "Continuar", a greeting's reply, the menu bar panel. The edit
        // would otherwise outlive a chat it no longer fits (the cut point moves with the new turn, and what comes back to the
        // composer would mix with the edit), so it is given up and the composer gets back what it held.
        if endsEdit { cancelEditing(botID) }
        session.memoryIdle?.cancel()
        session.memoryIdle = nil
        session.skillReview?.cancel() // a review gives way to anything the user or a routine sends
        session.skillReview = nil
        publishSkills(for: botID)
        // Full paths: the bubble shows thumbnails of the pictures (a name alone, as older conversations have, still renders).
        let itemsBeforeMessage = session.conversation?.items.count ?? 0
        if origin.isUser {
            append(.user(text: typed, attachments: attachments.map(\.path) + pictures.map(\.path)), to: botID, id: bubble)
        } else {
            // Another Orb's words are never your bubble: lines of their own (the first takes the id the model's message points to).
            for (index, item) in origin.items.enumerated() {
                append(.orbMessage(item), to: botID, id: index == 0 ? bubble : nil)
            }
        }
        if fromUser { setDraft("", for: botID) }
        setStatus("Pensando", of: botID)
        session.resetWork()
        session.showWork(WorkPhrase.line(status: "Pensando"))
        session.clearBeats() // the last turn's joy or error does not hide this one
        live(botID).poked()
        if fromUser { live(botID).scrolled() } // a routine or a quick ask must not drag a chat you are reading to its end
        if origin.isUser { session.flash(\.isListening, seconds: 1.4) }

        // A routine's prompt, and the words of another Orb, are not a request to remember.
        let intent = session.routineID == nil && origin.isUser ? MemoryIntent.detect(typed) : nil
        session.memoryRequest = intent.map { ($0, max(0, (session.conversation?.items.count ?? 1) - 1)) }
        // Your request is the approval: this turn saves to memory without asking (the Orb's saved settings don't change).
        let rememberTool = ref.provider == .claudeCode ? ClaudeCodeTools.memoryPrefix + "remember" : "remember"
        var turnGrants = intent == nil ? [] : [PermissionRule(family: .memory)]
        // MARK: MultiOrb (WP1)
        // Asking and telling other Orbs needs no card per message (a mode that reads only still refuses it): the turn grants it.
        let multi = multiOrbOffering(for: botID)
        if multi.orbs { turnGrants.append(PermissionRule(family: .delegation)) }
        // MARK: end MultiOrb (WP1)

        var prompt = typed.isEmpty && pictures.isEmpty ? Self.attachmentsOnlyPrompt : typed
        if origin.isUser, let expansion = SystemPrompt.expandSkill(in: typed, skills: skills(for: botID)) {
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
            runClaudeCode(bot, model: ref.model, prompt: prompt, images: pictures, message: typed, bubble: bubble, turnGrants: turnGrants,
                          multi: multi)
            return true
        }
        let skills = self.skills(for: botID)
        let allowedConnectors = connectors(for: botID)
        let budget = contextBudget(ref: ref, account: account, botID: botID)
        // Read before this turn's own messages are recorded: it is whether the last task is waiting for "continua".
        let paused = session.conversation?.isTaskPaused ?? false
        // The message and what goes before it (workspace snapshot, memory notes) take room too.
        let reserve = prompt.count + Self.prefaceAllowance
        yieldStretchNote(to: botID, provider: ref.provider)
        let prepared = session.changeConversation { $0.prepareHistory(budget: budget, reserving: reserve, now: .now) }
        let history = prepared.history
        let ledger = session.conversation?.currentLedger
        let chunks = session.conversation?.chunks(inHistory: history) ?? []
        if let report = prepared.compaction { session.announce(report, memoryUpTo: itemsBeforeMessage) }
        let bank = memory.bank(for: botID)
        var context = ToolContext(workingDirectory: bot.workingURL, memory: bank, botID: botID, jobs: jobs,
                                  schedule: scheduleHandler(for: botID), imageStore: images, acceptsImages: sees != false,
                                  outputsDirectory: outputsDirectory,
                                  canSaveFiles: bot.capabilities.contains(.terminal),
                                  computerUseAllowed: bot.capabilities.contains(.computerUse))
        let userTurns = session.userTurnCount()
        // MARK: MultiOrb (WP1)
        if multi.orbs { context.orbs = delegationHandler(for: botID) }
        context.sideRun = session.routineID.flatMap { id in session.sideKind.map { SideRunInfo(kind: $0, id: id, chain: session.chain) } }
        let teammates = multi.orbs ? orbsSection(for: bot, claudeCode: false) : ""
        let maxSteps = session.sideKind == .delegation || session.sideKind == .group ? DelegationLimits.sideRunMaxSteps
            : session.routineID != nil ? AgentEngine.routineMaxSteps : AgentEngine.defaultMaxSteps
        let baseContext = context
        // MARK: end MultiOrb (WP1)
        let lastWorkspaceHash = session.conversation?.workspaceHash
        let sessionID = session.gatewaySessionID()
        let lastWorkspace = session.conversation?.workspaceSeen
        let sentMemories = TurnPreface.relatedLines(in: history)

        session.turnModel = ref.text
        let turn = session.beginTurn()
        let steering = composerLane(botID).queue // messages sent during the turn reach the model between its steps
        session.turnTask = Task { [self] in
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: typed, conversationIsNew: history.isEmpty, userTurns: userTurns,
                                         canSave: bot.permissionMode != .readOnly, alreadySent: sentMemories,
                                         profile: profile.promptSection)
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
            // The Orb's own browser: its tools come only when the engine it chose is installed.
            let browserStatus = bot.capabilities.contains(.browser) && bot.browserEngine.drivesABrowser
                ? await browserHub.status(for: bot.browserEngine) : nil
            let browserAvailability = BrowserAvailability(capabilities: bot.capabilities, engine: bot.browserEngine, status: browserStatus)
            var context = baseContext
            context.browser = BrowserAccess(hub: browserHub, engine: browserAvailability == .browser ? bot.browserEngine : .simple,
                                            searchProvider: bot.searchProvider, searchKeys: SearchKeys(vault: secretVault))
            // MARK: MultiOrb (WP3)
            if multi.propose { context.orbCreation = orbCreationSupport(for: bot) }
            // MARK: end MultiOrb (WP3)
            var tools = ToolBox.offered(for: bot.capabilities, accessibilityGranted: accessibilityGranted, browser: browserAvailability,
                                        multi: multi)
            // The connectors' own tools do not travel with the request: the model lists and calls them through two fixed ones.
            if bot.capabilities.contains(.connectors), !allowedConnectors.isEmpty {
                await connectorSync?.value // one added a moment ago is known to `mcp` before the model may name it
                tools += ConnectorGateway.tools(for: allowedConnectors, manager: mcp)
            }
            guard session.isCurrent(turn) else { return }
            // Recorded when the prompt with the snapshot is stored (see `apply`), not before.
            session.pendingMarks = built.marks
            // The system prompt tells the Orb when the interface tools are held back (see `ToolBox.offered`).
            var system = accessibilityGranted ? built.system : built.system + "\n\n" + ToolBox.accessibilityUnavailableNote
            let browserSection = BrowserPrompt.section(bot: bot, availability: browserAvailability, status: browserStatus)
            if !browserSection.isEmpty { system += "\n\n" + browserSection }
            if !teammates.isEmpty { system += "\n\n" + teammates }
            let request = TurnRequest(bot: bot, model: ref.model, system: system, history: history,
                                      prompt: TurnPreface.prepend(built.preface, to: prompt),
                                      client: client, tools: tools, context: context, budget: budget, ledger: ledger,
                                      chunks: chunks, maxSteps: maxSteps,
                                      turnGrants: turnGrants, permissions: permissionSource(for: bot),
                                      images: pictures, requestItem: bubble, supportsImages: sees,
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
            session.keepForReview(request)
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
    private func runClaudeCode(_ bot: Bot, model: String, prompt: String, images pictures: [ImageAttachment], message: String, bubble: UUID, turnGrants: [PermissionRule],
                               multi: MultiOrbOffering) {
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
        scheduleMailbox.start()
        // MARK: MultiOrb (WP1)
        if multi.orbs { orbBridge.start() }
        let bridge = multi.orbs ? orbBridge.directory : nil
        let teammates = multi.orbs ? orbsSection(for: bot, claudeCode: true) : ""
        // MARK: end MultiOrb (WP1)
        let servers = [OrbToolsMCPServer.config(directory: bank.directory, mac: usesMac, files: bot.capabilities.contains(.terminal),
                                                folder: bot.workingURL, accessibilityGranted: accessibility,
                                                scheduleMailbox: scheduleMailbox.directory, orb: botID,
                                                bridge: bridge, orbs: multi.orbs)]
            + connectors
        let connectorIDs = Set(connectors.map(\.id))
        let cliNames = ClaudeCodeTurn.mcpNames(servers) // what the CLI will call each server
        let isNew = conversation.messages.isEmpty
        let userTurns = session.userTurnCount()
        session.isClaudeTurn = true
        session.claudeTurnDelivered = false
        session.claudeTurnFolder = folder
        session.turnModel = ModelRef(provider: .claudeCode, model: model).text
        let turn = session.beginTurn()
        session.turnTask = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: message, conversationIsNew: isNew, userTurns: userTurns,
                                         tools: ClaudeCodePrompt.memoryTools, canSave: bot.permissionMode != .readOnly,
                                         alreadySent: sessionID == nil ? [] : (conversation.claudeRelatedSent ?? []).flatMap { $0 },
                                         profile: profile.promptSection)
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
            // The Orb's web tools in the tools server: web_search with "Navegar na web", and the browse_* tools once the engine it
            // chose is installed (as in the native engine). The app asks what is installed and reads the TinyFish key here: the
            // server is another process and gets them in its flags and its (private, temporary) config.
            let browserStatus = bot.capabilities.contains(.browser) && bot.browserEngine.drivesABrowser
                ? await browserHub.status(for: bot.browserEngine) : nil
            let browserAvailability = BrowserAvailability(capabilities: bot.capabilities, engine: bot.browserEngine, status: browserStatus)
            let search = SearchKeys(vault: secretVault)
            let tinyFishKey = browserAvailability != .off && bot.searchProvider == .tinyfish ? (try? await runDetached { search.tinyFish }) ?? nil : nil
            var toolServers = servers
            toolServers[0] = OrbToolsMCPServer.config(directory: bank.directory, mac: usesMac, files: bot.capabilities.contains(.terminal),
                                                      folder: bot.workingURL, accessibilityGranted: accessibility,
                                                      scheduleMailbox: scheduleMailbox.directory, orb: botID, browser: browserAvailability,
                                                      engine: bot.browserEngine, searchProvider: bot.searchProvider,
                                                      browserProfiles: browserHub.profilesDirectory, tinyFishKey: tinyFishKey,
                                                      bridge: bridge, orbs: multi.orbs)
            // The CLI cannot renew a login in the middle of a turn: it gets a token with time left.
            let (servers, ended) = await connectorAuth.bearers(for: toolServers)
            // A login that could not be renewed is told to the cards now, not only when an Orb with the native engine meets it.
            for (id, reason) in ended { await mcp.loginEnded(id, reason: reason) }
            // What the connectors mark destructive, from their catalogs: the CLI's own connections never reach the Orb. A
            // connector with no catalog yet is asked about tool by tool.
            let annotations = await connectorAnnotations(for: connectorIDs, cliNames: cliNames)
            renewOldCatalogs(of: connectorIDs)
            guard session.isCurrent(turn) else { return }
            var system = ClaudeCodePrompt.withBrowserNote(ClaudeCodePrompt.withAccessibilityNote(built.system, accessibilityGranted: accessibility),
                                                          bot: bot, availability: browserAvailability, status: browserStatus)
            if !teammates.isEmpty { system += "\n\n" + teammates }
            var claudeTurn = ClaudeCodeTurn(bot: bot, executable: installation.executable, model: model,
                                            system: system,
                                            prompt: prompt, images: pictures, requestItem: bubble, context: context, sessionID: sessionID, connectors: servers,
                                            environment: environment, destructiveConnectors: annotations.destructive,
                                            knownConnectorTools: annotations.known, connectorPrefixes: annotations.prefixes,
                                            turnGrants: turnGrants,
                                            permissions: permissionSource(for: bot))
            claudeTurn.browser = BrowserAccess(hub: browserHub, engine: browserAvailability == .browser ? bot.browserEngine : .simple,
                                               searchProvider: bot.searchProvider)
            if multi.propose { claudeTurn.orbCreation = orbCreationSupport(for: bot) } // MultiOrb (WP3)
            // Recorded when the session answers (see `apply`): a turn that fails before that sent nothing.
            session.pendingMarks = built.marks
            await session.play(claudeEngine.run(claudeTurn), turn: turn)
        }
    }

    /// For a Claude Code turn: the tools of `ids` that the connectors mark destructive, the tools the catalogs know at all
    /// (any other tool of these connectors is asked about: it appeared after the catalog was made) and the prefix of each
    /// connector's tools. Read from the catalogs, so nothing is started.
    func connectorAnnotations(for ids: Set<UUID>, cliNames: [UUID: String]) async
        -> (destructive: [String: String], known: Set<String>, prefixes: Set<String>) {
        guard !ids.isEmpty else { return ([:], [], []) }
        var tools: [any AgentTool] = []
        for connector in connectors where ids.contains(connector.id) {
            if let catalog = await mcp.catalog(connector.id) {
                tools += catalog.mcpTools(serverName: connector.name, serverID: connector.id, manager: mcp)
            }
        }
        return (ClaudeCodeTurn.destructiveConnectors(tools, cliNames: cliNames),
                ClaudeCodeTurn.knownConnectorTools(tools, cliNames: cliNames),
                ClaudeCodeTurn.connectorPrefixes(ids, cliNames: cliNames))
    }

    /// Lists again, in the background, the connectors of a Claude Code turn whose catalog is missing or older than
    /// `maxAge`, so what the turn is told about their tools does not stay frozen (the CLI runs its own servers, which
    /// only this catalog describes). Never holds the turn; each connector is tried at most once an hour.
    func renewOldCatalogs(of ids: Set<UUID>, maxAge: TimeInterval = 24 * 3600) {
        guard renewsCatalogs else { return }
        let enabled = connectors.filter { ids.contains($0.id) && $0.isEnabled }
        Task {
            for connector in enabled where Date.now.timeIntervalSince(catalogRenewals[connector.id] ?? .distantPast) > 3600 {
                if let catalog = await mcp.catalog(connector.id), Date.now.timeIntervalSince(catalog.updatedAt) < maxAge { continue }
                catalogRenewals[connector.id] = .now
                _ = await testConnector(connector.id)
            }
        }
    }

    /// Quitting: stops every running turn, so nothing is left running unwatched (the app no longer answers permission
    /// requests) and the transcript says it was interrupted.
    func stopTurnsForQuit() {
        delegation.isShuttingDown = true // the turns that end now answer nobody and start nothing
        for id in sessions.keys where sessions[id]?.turnTask != nil { stop(id, startsQueuedRoutines: false) }
    }

    /// Stops the Orb's running turn. Stopping is for the whole conversation between Orbs it takes part in: whatever the Orb asked
    /// and is waiting for, and whatever it was asked and is working on, stops too (even when its own turn is over and it only waits).
    func stop(_ botID: UUID, startsQueuedRoutines: Bool = true) {
        for chain in delegation.chains(involving: botID) { delegation.cancelChain(chain, by: .user) }
        sessions[botID]?.stop(startsQueuedRoutines: startsQueuedRoutines)
    }

    func apply(_ event: TurnEvent, to botID: UUID) { session(botID).apply(event) } // internal for tests

    /// Closes the turn `turn`; a turn that is no longer the Orb's current one (stopped, then replaced) is ignored.
    func finishTurn(_ botID: UUID, turn: UUID, succeeded: Bool = true) {
        sessions[botID]?.finishTurn(turn, succeeded: succeeded)
    }

    func closeStreaming(_ botID: UUID) { session(botID).closeStreaming() }

    func append(_ kind: TranscriptItem.Kind, to botID: UUID, duringTask: Bool = false, id: UUID? = nil) {
        session(botID).append(kind, duringTask: duringTask, id: id)
    }

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
        guard !isResetting, let routine = routines.first(where: { $0.id == routineID }), bot(routine.botID) != nil else { return }
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
        guard !isWorking(routine.botID), startingRoutines[routine.botID] == nil, !changingChat.contains(routine.botID) else {
            queuedRoutines.append(routineID)
            return
        }
        startRoutine(routine)
    }

    /// The chat change is over: a routine that came due meanwhile runs now, over the chat that stayed (see `beginRoutine`).
    private func endChatChange(_ botID: UUID) {
        changingChat.remove(botID)
        startNextQueuedWork(for: botID)
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
        unsavedRoutineConversations[routineID] = nil
        if sessions[routine.botID]?.routineID == routineID { stop(routine.botID) }
        store.deleteRoutineConversation(routine: routineID, for: routine.botID)
    }

    /// Starts the routine once its own conversation (the last runs) has been read, off the main thread. Until then the
    /// Orb takes no other routine (`startingRoutines`); a message sent meanwhile gets the Orb first.
    private func startRoutine(_ routine: Routine) {
        let botID = routine.botID
        guard !isResetting, session(botID).turnTask == nil, startingRoutines[botID] == nil, bot(botID) != nil,
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
        guard !isResetting, bot(botID) != nil, let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        guard routines[index].botID == botID else {
            if !queuedRoutines.contains(routineID) { queuedRoutines.append(routineID) }
            startIdleQueuedRoutines() // it runs when its new Orb is free
            return
        }
        let session = session(botID)
        // A message (or a routine of its own) took the Orb meanwhile: this one waits for the turn to end, as any other.
        // So it does while the chat is being archived or reopened: its notice at the end would read as the chat having
        // changed, and the change would be given up.
        guard session.turnTask == nil, !changingChat.contains(botID) else {
            if !queuedRoutines.contains(routineID) { queuedRoutines.append(routineID) }
            return
        }
        let routine = routines[index]
        ensureLoaded(botID)
        let started = Date.now
        routines[index].lastRun = started
        addNotice(Self.labeled(read.notice, for: bot(botID)))

        // The routine's own conversation takes the chat's place while it runs (the chat is written and parked).
        // The previous run's conversation, when it could not be written, is only in memory: the file is older.
        let previous = unsavedRoutineConversations[routine.id]?.conversation ?? read.value
        session.startRoutineRun(routine.id, conversation: (previous?.closingInterruptedTurn() ?? Conversation()).startingRoutineRun(at: started),
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

    // MARK: MultiOrb (WP1)

    /// Whether nothing holds the Orb: no turn, no routine or request being started, no chat being swapped.
    func canTakeSideWork(_ botID: UUID) -> Bool {
        !isResetting && bot(botID) != nil && sessions[botID]?.turnTask == nil && startingRoutines[botID] == nil
            && !changingChat.contains(botID) && !delegation.isStarting(botID)
    }

    /// The Orb became free: what waits for it runs now, in this order: the answers to what it asked (they wake it), a request from
    /// another Orb, a routine. One at a time; each one's end comes back here.
    func startNextQueuedWork(for botID: UUID) {
        guard canTakeSideWork(botID) else { return }
        if delegation.deliverInbox(for: botID) { return }
        if delegation.startNextRequest(for: botID) { return }
        startNextQueuedRoutine(for: botID)
    }
    // MARK: end MultiOrb (WP1)

    /// Runs the routines that were waiting for this Orb, one at a time, as it becomes free.
    func startNextQueuedRoutine(for botID: UUID) {
        while sessions[botID]?.turnTask == nil, startingRoutines[botID] == nil, !changingChat.contains(botID),
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
        if routine != nil { saveRoutineConversation(own, routine: routineID, for: botID) }
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
            // A run that outlasted its slot (every 15 minutes, taking 20) must not start the next one at once: count from now.
            if routines[index].nextRun <= finished { routines[index].lastRun = finished }
        }
        let outcome = succeeded ? "terminou: \(run.summary)" : "não terminou: \(run.summary)"
        append(.notice("Rotina “\(routine.name)” \(outcome)" + (run.reportFile.map { " (relatório em \($0))" } ?? "")), to: botID)
    }

    /// Writes a finished run's conversation. One that could not be written (a full disk) is kept here, the only copy,
    /// and written again when the app quits.
    private func saveRoutineConversation(_ conversation: Conversation, routine routineID: UUID, for botID: UUID) {
        unsavedRoutineConversations[routineID] = nil // this one starts from the one that failed (`beginRoutine`), so it holds it
        store.saveRoutineConversation(conversation, routine: routineID, for: botID) { [weak self] saved in
            guard !saved else { return }
            Task { @MainActor in self?.unsavedRoutineConversations[routineID] = (botID, conversation) }
        }
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
        guard let name = routineName(for: botID) else { return text }
        return "Rotina “\(name)”: \(text)"
    }

    /// The name of the routine whose run is the Orb's turn, if it is one.
    func routineName(for botID: UUID) -> String? {
        guard let routineID = sessions[botID]?.routineID else { return nil }
        return routines.first(where: { $0.id == routineID })?.name
    }

    func systemWillSleep(at date: Date = .now) { asleepSince = date }

    func systemDidWake(at date: Date = .now) {
        asleepSince = nil
        wokeAt = date
    }

    /// Starts the routines that came due. Right after the Mac wakes it holds back: the scheduler's timer fires at once,
    /// before the network is up, and a run that fails then would lose its slot until the next day. It does not rely on
    /// the wake notification winning that race: it also holds back while the Mac is known to be asleep, and when the
    /// time since its last pass shows that it slept.
    func runDueRoutines(now: Date = .now) {
        delegation.sweep(now: now)
        if let last = lastRoutinePass, now.timeIntervalSince(last) > Self.sleepGap { wokeAt = max(wokeAt ?? now, now) }
        lastRoutinePass = now
        if let asleepSince {
            if now.timeIntervalSince(asleepSince) < Self.sleepHold { return }
            // A sleep whose wake was never announced (a dark wake, a cancelled sleep): the passes going on show the
            // Mac is up, so it counts as a wake instead of holding the routines back for good.
            self.asleepSince = nil
            wokeAt = max(wokeAt ?? now, now)
        }
        if let wokeAt, now < wokeAt.addingTimeInterval(Self.wakeSettleTime) { return }
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
        return addSkill(slug: Skill.slugify(entry.skillId), name: document.name, summary: document.description,
                        instructions: document.instructions, source: entry.id, folderURL: document.folderURL)
    }

    /// `slug` with a numeric suffix when another skill already has it.
    func uniqueSlug(_ slug: String) -> String {
        var unique = slug, suffix = 2
        while skills.contains(where: { $0.slug == unique }) {
            unique = "\(slug)-\(suffix)"
            suffix += 1
        }
        return unique
    }

    /// Adds a skill under a free slug; `orbIDs` limits it to those Orbs (nil: every Orb).
    @discardableResult
    func addSkill(slug: String, name: String, summary: String, instructions: String, source: String? = nil,
                  folderURL: URL? = nil, orbIDs: Set<UUID>? = nil) -> Skill {
        let skill = Skill(slug: uniqueSlug(slug), name: name, summary: summary, instructions: instructions,
                          source: source, folderURL: folderURL, orbIDs: orbIDs)
        skills.append(skill)
        return skill
    }

    func installedConnector(_ registryName: String) -> MCPServerConfig? { connectors.first { $0.source == registryName } }

    // MARK: Connectors

    /// Tells `mcp` which connectors there are. It starts none of them: a server starts when an Orb first needs it.
    func syncConnectors() {
        guard !isDevRun else { return } // their servers are programs (`npx …`) of whoever wrote the data folder
        let configs = connectors
        let previous = connectorSync
        connectorSync = Task {
            await previous?.value
            await mcp.sync(configs)
        }
    }

    /// Starts connector `id` now (a server that is already on lists its tools again) and gives how it went: what the
    /// editor does after saving and what "Testar conexão" and "Tentar de novo" do.
    func testConnector(_ id: UUID) async -> ConnectorTestOutcome {
        await connectorSync?.value
        let started = ContinuousClock.now
        do {
            let count = try await mcp.test(id)
            let elapsed = ContinuousClock.now - started
            return .connected(tools: count, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The status of connector `id` once it has been started (or failed to).
    func connectAndWait(_ id: UUID) async -> MCPStatus? {
        _ = await testConnector(id)
        return await mcp.status()[id]
    }

    /// "Reconectar": tries again the connectors that failed.
    func retryFailedConnectors() {
        for (id, status) in connectorStatus {
            if case .failed = status { Task { _ = await testConnector(id) } }
        }
    }

    // MARK: Notifications

    /// The preference behind "Me avisar quando um Orb terminar ou precisar de mim" (Ajustes → Geral).
    nonisolated static let notifyWhenDoneKey = "notifyWhenDone"

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notifyWhenDoneKey) as? Bool ?? true
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
                        learnedContexts: learnedContexts, profile: profile, priceCorrections: priceCorrections, groups: groups)
    }

    private func scheduleStateSave() {
        guard !isResetting else { return }
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
        guard !isResetting else { return } // quitting after a reset must not write the old state back
        store.save(state)
        saveDraftsIfChanged() // after the turns stopped for quitting gave their queued messages back
        for session in sessions.values { session.saveNow() }
        for (routineID, unsaved) in unsavedRoutineConversations {
            unsavedRoutineConversations[routineID] = nil
            saveRoutineConversation(unsaved.conversation, routine: routineID, for: unsaved.botID)
        }
        usageLog.flush()
        store.flush()
    }
}

/// Where `AppModel.refreshConnections` reads the sign-ins from.
struct ConnectionSources: Sendable {
    /// The providers with a key stored. Blocking (the Keychain), so it runs off the main thread.
    var keyedProviders: @Sendable () -> Set<ProviderKind>
    var storeKey: @Sendable (_ key: String, _ kind: ProviderKind) -> Void
    var hasChatGPTCredential: @Sendable () async -> Bool
    var signOutOfChatGPT: @Sendable () async -> Void
    /// `claude auth status`; nil where the real `claude` must not run.
    var claudeCodeStatus: (@Sendable () async -> ClaudeCodeStatus)?

    static let live = ConnectionSources(
        keyedProviders: { Set(ProviderKind.allCases.filter { $0.storesKey && Keychain.get($0.rawValue) != nil }) },
        storeKey: { Keychain.set($0, account: $1.rawValue) },
        hasChatGPTCredential: { await ChatGPTAuth.shared.credential != nil },
        signOutOfChatGPT: { await ChatGPTAuth.shared.signOut() },
        claudeCodeStatus: { await ClaudeCode.shared.status() })
}
