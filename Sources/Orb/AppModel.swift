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
    /// Conversations in memory. At launch only the selected Orb's is read (off the main thread, `beginLoading`);
    /// the others are read when they are needed (`unloadedConversations`): when you switch to the Orb, or something
    /// has to change its conversation (`ensureLoaded`). One nobody has looked at for a while and that has nothing
    /// left to save goes back to disk (`unloadIdleConversations`).
    private(set) var conversations: [UUID: Conversation] { didSet { showTranscripts() } }
    /// While a routine runs, `conversations[botID]` is the routine's own conversation (the turn machinery works on
    /// it) and the user's chat waits here, untouched. Every turn of an Orb works on one conversation at a time, so
    /// a routine and a chat turn of the same Orb cannot run together yet (the routine waits in `queuedRoutines`).
    private(set) var parkedChats: [UUID: Conversation] = [:] { didSet { showTranscripts() } }
    /// Earlier conversations of each Orb as last listed (see `loadArchive`).
    private(set) var archives: [UUID: [ConversationSummary]] = [:]
    /// Routines that came due while their Orb was busy; each runs when the Orb is free. One entry per routine.
    private(set) var queuedRoutines: [UUID] = []
    /// Things the user should hear about the data files (an unreadable file and where its copy is, a failed save).
    /// The first one is shown as an alert; `dismissDataNotice` moves on to the next.
    private(set) var dataNotices: [StoreNotice] = []

    // MARK: UI state

    var drafts: [UUID: String] = [:]
    var showInspector = true
    var showNewBot = false
    var connectorStatus: [UUID: MCPStatus] = [:]
    /// Tokens each Orb's last turn used, summed over its model calls (for a context meter; nothing shows it yet).
    private(set) var usage: [UUID: TokenUsage] = [:]
    /// Tokens of each Orb's latest model call alone: `promptTokens` is how full the context is now and
    /// `cacheHitRatio` how much of it the provider's cache served (native engine only; for the context meter).
    private(set) var requestUsage: [UUID: TokenUsage] = [:]
    /// Providers with a key in the Keychain (or, for ChatGPT and Claude Code, a sign-in).
    private(set) var connected: Set<ProviderKind> = []
    /// What the local Claude Code reports (checked while that provider is set up).
    private(set) var claudeCode = ClaudeCodeStatus()

    // MARK: Per-Orb live state

    /// The Orbs in sidebar order. Changes only when an Orb is added, deleted or moved, so a list that shows one
    /// view per Orb (sidebar, menu bar, Orbs menu) re-renders then and not when an Orb's own state changes.
    private(set) var botIDs: [UUID] = []
    /// The Orbs working right now and the ones waiting for an answer, in sidebar order (the menu bar lists them).
    private(set) var workingIDs: [UUID] = []
    private(set) var waitingIDs: [UUID] = []
    /// One observable object per Orb (see `BotLive`). Not observed itself: the Orbs it holds change with `bots`.
    @ObservationIgnored private var lives: [UUID: BotLive] = [:]
    /// Until when each Orb keeps talking (it stops when no text arrived for `speakingQuiet`).
    @ObservationIgnored private var speakingUntil: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var speakingWatch: [UUID: Task<Void, Never>] = [:]
    private static let speakingQuiet = Duration.milliseconds(600)
    var selection: SidebarItem? {
        didSet {
            if case .bot(let old) = oldValue, conversations[old] != nil { lastUsed[old] = .now } // leaving it: the clock starts now
            if case .bot(let id) = selection {
                beginLoading(id)
                lastUsed[id] = .now
                setUnread(0, for: id)
            }
        }
    }

    // MARK: Services

    @ObservationIgnored private var store: Store
    /// Pictures attached to messages and returned by tools (`anexos/<id>/` in the data folder).
    @ObservationIgnored let images: ImageStore
    /// Models ("provider/model") that answered that they cannot read pictures, so later turns do not try again.
    @ObservationIgnored private var visionRejected: Set<String> = []
    /// Context windows learned from refusals ("provider/model"); they shrink the history budget of that model.
    @ObservationIgnored private(set) var learnedContexts: [String: LearnedContext]
    /// Tokens of system prompt and tool specs the engine measured on each Orb's last turn (not kept across launches).
    @ObservationIgnored private var measuredOverhead: [UUID: Int] = [:]
    /// Where outputs too big for a conversation are saved for the model to read back (`saidas/<id>/` in the data folder).
    @ObservationIgnored let outputsDirectory: URL
    /// Every Orb's own memory bank (`memoria/<id>/` in the data folder).
    @ObservationIgnored let memory: MemoryLibrary
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
    private var routineTurns: [UUID: UUID] = [:]
    /// When each running routine's run began.
    @ObservationIgnored private var routineStarts: [UUID: Date] = [:]
    /// Stands in for the provider's client (tests).
    /// Where "the home folder" is, for deciding whether an Orb's folder is its own (tests point it elsewhere).
    @ObservationIgnored var homeFolder = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored var clientOverride: (@MainActor () -> (any LLMClient)?)?
    /// Whether macOS trusts the app for Accessibility, read when a turn starts (tests replace it).
    @ObservationIgnored var accessibilityProbe: @Sendable () -> Bool = { LiveMacPermissionSystem().isAccessibilityTrusted() }
    @ObservationIgnored private var stateSave: Task<Void, Never>?
    @ObservationIgnored private var conversationSaves: [UUID: Task<Void, Never>] = [:]
    /// Orbs whose conversation changed since it was last written; quitting saves only these.
    @ObservationIgnored private var dirtyConversations: Set<UUID> = []
    /// Orbs whose conversation isn't in memory (never in `conversations`): not read yet, or let go of again.
    @ObservationIgnored private var unloadedConversations: Set<UUID> = []
    /// Orbs whose conversation is being read off the main thread right now: the chat shows a placeholder.
    private(set) var loadingConversations: Set<UUID> = []
    @ObservationIgnored private var conversationLoads: [UUID: Task<Void, Never>] = [:]
    /// Bumped when an Orb's conversation is read synchronously or let go of, so a read that was already under way
    /// (and may be older than what is in memory now) is not installed.
    @ObservationIgnored private var loadEpoch: [UUID: Int] = [:]
    /// When each conversation in memory was last shown, read or changed.
    @ObservationIgnored private var lastUsed: [UUID: ContinuousClock.Instant] = [:]
    /// How long a conversation nobody is looking at stays in memory (tests shorten it).
    @ObservationIgnored var conversationKeepAlive = Duration.seconds(300)
    @ObservationIgnored private var didReportSaveFailure = false
    /// The Keychain reads of a `refreshConnections` under way, and which state of the Keychain they started from
    /// (`keychainGeneration` changes when the app itself changes a key).
    @ObservationIgnored private var keyReads: (generation: Int, task: Task<Set<ProviderKind>, Never>)?
    @ObservationIgnored private var keychainGeneration = 0
    /// A conversation that keeps changing (a streaming reply) is written at most this often.
    private static let streamingSaveInterval = 5.0
    /// What each Orb's chat view reads (see `transcript(_:)`), made when first asked for.
    @ObservationIgnored private var transcripts: [UUID: OrbTranscript] = [:]
    /// The reply each Orb is streaming right now. Its text lives here, not in the conversation, until the reply
    /// is closed (`closeStreaming`), so a flush does not touch the list of items.
    @ObservationIgnored private var liveTexts: [UUID: LiveText] = [:]
    /// Streamed text not shown yet: deltas are published at most every `textFlushInterval`.
    @ObservationIgnored private var pendingText: [UUID: String] = [:]
    @ObservationIgnored private var textFlushes: [UUID: Task<Void, Never>] = [:]
    private static let textFlushInterval = Duration.milliseconds(33)
    @ObservationIgnored private var scheduler: Task<Void, Never>?

    /// `runsBackgroundWork: false` skips the scheduler, Keychain checks and app-wide observers (tests).
    /// `asyncLoading` says whether the first Orb's conversation is read off the main thread after `init` returns
    /// (the window does not wait for it; the app) or before it returns (what tests rely on); it follows
    /// `runsBackgroundWork` unless given.
    init(store: Store = .standard, runsBackgroundWork: Bool = true, asyncLoading: Bool? = nil) {
        self.store = store
        images = ImageStore(dataFolder: store.directory)
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
        contextMemory = state.contextMemory
        learnedContexts = state.learnedContexts
        outputsDirectory = ToolOutputCap.directory(inDataFolder: store.directory)
        // Only the Orb shown first is read at launch, and the window does not wait for it (`beginLoading` below).
        let readsFirstLater = asyncLoading ?? runsBackgroundWork
        var firstConversations: [UUID: Conversation] = [:]
        if !readsFirstLater, let first = state.bots.first {
            let read = store.readConversation(first.id)
            notices += Self.labeled(read.notice, for: first).map { [$0] } ?? []
            firstConversations[first.id] = read.value?.closingInterruptedTurn() ?? Conversation()
            lastUsed[first.id] = .now
        }
        conversations = firstConversations
        unloadedConversations = Set(state.bots.map(\.id)).subtracting(firstConversations.keys)
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
        if readsFirstLater, let first = state.bots.first { beginLoading(first.id) }
        guard runsBackgroundWork else { return }
        let outputs = outputsDirectory
        Task.detached(priority: .utility) { ToolOutputCap.cleanUp(directory: outputs) }
        ApprovalNotifications.clearStale()
        ApprovalNotifications.install { [weak self] route in self?.handle(route) }
        Task { [weak self] in await self?.prepareMemory() }
        scheduler = Task { [weak self] in
            await self?.refreshConnections()
            while !Task.isCancelled {
                self?.runDueRoutines()
                await self?.refreshAllModels()
                await self?.unloadIdleConversations()
                try? await Task.sleep(for: .seconds(30))
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
        dataNotices.append(notice)
    }

    /// Reads the conversation of an Orb that isn't in memory, right now, on the main thread. The way in for anything
    /// that has to read or change a conversation and cannot wait (a message sent, a card answered from a banner), so
    /// an unloaded one is never mistaken for an empty one (and then saved over its file). What can wait goes through
    /// `beginLoading` or `loadedConversation` instead (the composer and the approval banners wait for a read that is
    /// already under way rather than come here: this one cannot use that read, so it would wait for it and then read
    /// the file again, on the main thread).
    private func ensureLoaded(_ botID: UUID) {
        guard unloadedConversations.remove(botID) != nil else { return }
        loadingConversations.remove(botID)
        conversationLoads.removeValue(forKey: botID)?.cancel() // superseded: it must not be handed out again if this one is let go
        loadEpoch[botID, default: 0] += 1 // a read under way is older than this one
        let read = store.readConversation(botID)
        addNotice(Self.labeled(read.notice, for: bot(botID)))
        install(read, for: botID)
    }

    /// Starts reading the conversation of an Orb that isn't in memory, off the main thread, unless that is already
    /// under way. Until it arrives the Orb counts as `loadingConversations` (the chat shows a placeholder) and
    /// nothing may change its conversation: whatever needs it earlier goes through `ensureLoaded`, which wins.
    @discardableResult
    private func beginLoading(_ botID: UUID) -> Task<Void, Never>? {
        guard unloadedConversations.contains(botID) else { return nil }
        if let running = conversationLoads[botID] { return running }
        loadingConversations.insert(botID)
        let epoch = loadEpoch[botID, default: 0], store = store
        let task = Task { [weak self] in
            let read = await store.readConversationAsync(botID)
            self?.finishLoading(botID, epoch: epoch, read)
        }
        conversationLoads[botID] = task
        return task
    }

    private func finishLoading(_ botID: UUID, epoch: Int, _ read: StoreRead<Conversation>) {
        // A read that `ensureLoaded` superseded leaves the bookkeeping alone: it may belong to a newer read by now.
        if loadEpoch[botID, default: 0] == epoch {
            conversationLoads[botID] = nil
            loadingConversations.remove(botID)
        }
        guard let owner = bot(botID) else { // deleted meanwhile
            unloadedConversations.remove(botID)
            return
        }
        // Loaded on demand (`ensureLoaded`) while this was reading: that result wins. Its notice still stands when the
        // file was moved aside (the on-demand read then found nothing), but not when the on-demand read already
        // reported the same lost items.
        guard loadEpoch[botID, default: 0] == epoch, unloadedConversations.remove(botID) != nil else {
            if read.value == nil { addNotice(Self.labeled(read.notice, for: owner)) }
            return
        }
        addNotice(Self.labeled(read.notice, for: owner))
        install(read, for: botID) // the chat scrolls to the end of what just arrived when loading ends
    }

    private func install(_ read: StoreRead<Conversation>, for botID: UUID) {
        conversations[botID] = read.value?.closingInterruptedTurn() ?? Conversation()
        lastUsed[botID] = .now
        rewriteIfItLostItems(botID, read)
    }

    /// Waits until the Orb's conversation is in memory, reading it off the main thread if it is not.
    func loadedConversation(_ botID: UUID) async {
        guard bot(botID) != nil, let task = beginLoading(botID) ?? conversationLoads[botID] else { return }
        await task.value
    }

    /// Whether the chat should show that the conversation is still on its way.
    func isLoadingConversation(_ botID: UUID) -> Bool { loadingConversations.contains(botID) }

    /// Reads every conversation not in memory now. Testing only: the app reads them when they are needed.
    func loadRemainingConversations() async {
        for bot in bots where unloadedConversations.contains(bot.id) { await loadedConversation(bot.id) }
    }

    /// Lets go of conversations nobody is looking at: not the selected Orb's, not one that is working, parked by a
    /// routine, or waiting to be saved, and not one used within `conversationKeepAlive`. Only when the file on disk
    /// is known to hold what is in memory (the note beside it says so), and never after a failed save, when memory
    /// may be the only copy. A conversation that comes back is read again from its file, off the main thread.
    func unloadIdleConversations(now: ContinuousClock.Instant = .now, only: UUID? = nil) async {
        guard !didReportSaveFailure else { return }
        let candidates = conversations.keys.filter { (only == nil || $0 == only) && isIdle($0, now: now) }
        for botID in candidates {
            guard let meta = await store.readMetaAsync(botID) else { continue }
            // Looked at again after waiting: it may have been used, changed or started a turn meanwhile.
            guard isIdle(botID, now: now), let conversation = conversations[botID], meta.matches(conversation) else { continue }
            conversations[botID] = nil
            unloadedConversations.insert(botID)
            loadEpoch[botID, default: 0] += 1
            lastUsed[botID] = nil
            store.releaseCache(for: botID)
        }
    }

    private func isIdle(_ botID: UUID, now: ContinuousClock.Instant) -> Bool {
        guard conversations[botID] != nil, selection != .bot(botID), turns[botID] == nil, routineTurns[botID] == nil,
              parkedChats[botID] == nil, live(botID).status == nil, !live(botID).isAwaitingApproval,
              !dirtyConversations.contains(botID), conversationSaves[botID] == nil else { return false }
        return lastUsed[botID].map { $0.duration(to: now) >= conversationKeepAlive } ?? true
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

    // MARK: Queries

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    var selectedBot: Bot? {
        if case .bot(let id) = selection { bot(id) } else { nil }
    }

    /// The user's chat (not a running routine's conversation, which `conversations` holds meanwhile). The reply
    /// being streamed is in it as it began; `liveText(for:of:)` has its text.
    func transcript(_ botID: UUID) -> [TranscriptItem] { transcripts[botID]?.items ?? shownItems(of: botID) }

    /// The chat of one Orb as its view reads it. Observed on its own: a change in another Orb's conversation, or
    /// in this one's streamed text, does not touch it.
    func orbTranscript(_ botID: UUID) -> OrbTranscript {
        if let transcript = transcripts[botID] { return transcript }
        let transcript = OrbTranscript(items: shownItems(of: botID))
        transcripts[botID] = transcript
        return transcript
    }

    private func shownItems(of botID: UUID) -> [TranscriptItem] {
        (parkedChats[botID] ?? conversations[botID])?.items ?? []
    }

    /// Hands every Orb's chat view its items after `conversations` or `parkedChats` changed. Cheap for the ones
    /// whose items were not touched (`OrbTranscript.show` compares storage, not elements).
    private func showTranscripts() {
        for (botID, transcript) in transcripts { transcript.show(shownItems(of: botID)) }
    }

    /// The text of `itemID` while it streams (nil for any other item, and once the reply is closed).
    func liveText(for itemID: UUID, of botID: UUID) -> LiveText? {
        guard let live = liveTexts[botID], live.itemID == itemID else { return nil }
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

    private func setStatus(_ text: String?, of botID: UUID) {
        let live = live(botID)
        let was = live.isWorking
        live.setStatus(text)
        if live.isWorking != was { refreshPresence() }
    }

    private func setAwaitingApproval(_ isWaiting: Bool, of botID: UUID) {
        let live = live(botID)
        let was = live.needsYou
        live.setAwaitingApproval(isWaiting)
        if live.needsYou != was { refreshPresence() }
    }

    /// The unread count is saved with the app's state, so a change schedules a save.
    private func setUnread(_ count: Int, for botID: UUID) {
        let live = live(botID)
        guard live.unread != count else { return }
        live.setUnread(count)
        scheduleStateSave()
    }

    /// The draft in the composer, kept per Orb. Writing what is already there does nothing (no draft counts as "").
    func setDraft(_ text: String, for botID: UUID) {
        guard drafts[botID, default: ""] != text else { return }
        drafts[botID] = text
    }

    /// Keeps the bot `speaking` until no text arrived for `speakingQuiet`.
    private func markSpeaking(_ botID: UUID) {
        guard let live = lives[botID] else { return } // a late event of a deleted Orb starts no watcher
        speakingUntil[botID] = .now + Self.speakingQuiet
        guard !live.isSpeaking else { return }
        live.isSpeaking = true
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
        lives[botID]?.isSpeaking = false
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
        if account(.claudeCode) != nil {
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
        conversations[bot.id] = Conversation()
        lastUsed[bot.id] = .now
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
        routineTurns[botID].flatMap { id in routines.first { $0.id == id }?.permissionMode }
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
        guard turns[botID] != nil, routineModeOverride(botID) == nil else { return } // the routine's own mode stands
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
        ApprovalNotifications.clear(answered.map(\.approvalID))
        updateAwaitingApproval(botID)
    }

    /// The Orb waits for you exactly while one of its cards is open.
    private func updateAwaitingApproval(_ botID: UUID) {
        let stillOpen = (conversations[botID]?.items ?? []).contains {
            if case .approval(let request) = $0.kind { request.decision == nil } else { false }
        }
        if !stillOpen { setAwaitingApproval(false, of: botID) }
    }

    /// Deletes the Orb with its conversation and routines. Its memory goes too, unless `keepMemory`: then the
    /// last conversation stretch is saved and the folder moves to `memoria/_guardadas/`.
    func deleteBot(_ botID: UUID, keepMemory: Bool = false) {
        let name = bot(botID)?.name ?? "Orb"
        memoryRequests[botID] = nil
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
        bots.removeAll { $0.id == botID }
        liveTexts[botID] = nil
        conversations[botID] = nil
        parkedChats[botID] = nil
        transcripts[botID] = nil
        writeIfChanged(nil, at: botID, in: \.archives)
        unloadedConversations.remove(botID)
        loadingConversations.remove(botID)
        conversationLoads.removeValue(forKey: botID)?.cancel()
        lastUsed[botID] = nil
        dirtyConversations.remove(botID)
        conversationSaves.removeValue(forKey: botID)?.cancel()
        store.deleteConversation(botID)
        store.deleteArchive(botID) // the earlier conversations and the routines' ones
        if selection == .bot(botID) { selection = bots.first.map { .bot($0.id) } }
    }

    func selectAdjacentBot(offset: Int) {
        guard !bots.isEmpty else { return }
        let current = selectedBot.flatMap { bot in bots.firstIndex { $0.id == bot.id } } ?? -offset
        let next = (current + offset + bots.count) % bots.count
        selection = .bot(bots[next].id)
    }

    // MARK: Conversation history

    /// Starts a new conversation. The current one is archived (when you said anything in it), not thrown away.
    func newConversation(_ botID: UUID) {
        guard bot(botID) != nil else { return }
        leaveChat(botID)
        archiveChat(botID)
        installChat(Conversation(), for: botID)
        setDraft("", for: botID)
    }

    /// Makes an archived conversation the current one. The current one is archived first (if you said anything in
    /// it), so nothing is lost either way. The conversation keeps its Claude Code session and its memory
    /// bookkeeping (how much of it is already saved as memory), so reopening it saves nothing twice.
    @discardableResult
    func reopenConversation(_ id: UUID, of botID: UUID) -> Bool {
        guard let owner = bot(botID) else { return false }
        let read = store.readArchived(id, for: botID)
        addNotice(Self.labeled(read.notice, for: owner))
        guard let chosen = read.value else {
            archives[botID]?.removeAll { $0.id == id }
            return false
        }
        leaveChat(botID)
        archiveChat(botID)
        installChat(chosen.closingInterruptedTurn(), for: botID)
        setDraft("", for: botID)
        store.deleteArchived(id, for: botID) // after the reopened chat is written (`installChat`, same queue): a crash in between keeps both
        archives[botID]?.removeAll { $0.id == id }
        return true
    }

    /// Permanently deletes an archived conversation.
    func deleteArchivedConversation(_ id: UUID, of botID: UUID) {
        store.deleteArchived(id, for: botID)
        archives[botID]?.removeAll { $0.id == id }
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
        if routineTurns[botID] == nil { stop(botID) }
        memoryIdle.removeValue(forKey: botID)?.cancel()
        ensureLoaded(botID)
    }

    /// Archives the chat if you said anything in it. Whatever of it is not yet in memory is saved first, once: the
    /// mark of how much is saved goes into the archive with the conversation.
    private func archiveChat(_ botID: UUID) {
        guard var chat = parkedChats[botID] ?? conversations[botID] else { return }
        let start = min(chat.memorySavedCount ?? 0, chat.items.count)
        let stretch = Array(chat.items[start...])
        if !stretch.isEmpty {
            chat.memorySavedCount = chat.items.count
            persistStretch(stretch, of: botID)
        }
        guard chat.hasUserMessages else { return }
        let summary = store.archive(chat, for: botID)
        if archives[botID] != nil {
            archives[botID]?.append(summary)
            archives[botID]?.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Replaces the chat (which a running routine may have parked) and writes it at once, on the store's queue,
    /// so whatever is queued after it (deleting the archived copy of a reopened conversation) comes after it.
    private func installChat(_ chat: Conversation, for botID: UUID) {
        if parkedChats[botID] != nil {
            parkedChats[botID] = chat
        } else {
            conversations[botID] = chat
            conversationSaves.removeValue(forKey: botID)?.cancel()
            dirtyConversations.remove(botID)
        }
        store.save(chat, for: botID)
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
                let wasInMemory = conversations[bot.id] != nil
                await loadedConversation(bot.id)
                if !saveMemory(of: bot.id, ifIdleFor: SessionSummary.idleGap), hasUnsavedStretch(bot.id) {
                    scheduleMemorySave(bot.id)
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
        if unloadedConversations.contains(botID), let meta = await store.readMetaAsync(botID) {
            return meta.hasUnsavedStretch || unloadedConversations.contains(botID) == false
        }
        return true
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
        persistStretch(stretch, of: botID)
        return true
    }

    private func persistStretch(_ stretch: [TranscriptItem], of botID: UUID) {
        let bank = memory.bank(for: botID)
        Task.detached(priority: .utility) { [weak self] in
            if let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
            await self?.refreshMemory(botID)
        }
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
            if self?.turns[botID] != nil { // a routine is running: the chat is saved once the Orb is free
                self?.scheduleMemorySave(botID)
                return
            }
            await self?.loadedConversation(botID) // it may have been let go of while the Orb was idle
            guard !Task.isCancelled else { return }
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
            sendWhenLoaded(text, to: id)
        }
    }

    /// `send` for callers that do not use its result: when the Orb's conversation is not in memory it is read off the
    /// main thread first, instead of making the window wait for it.
    func sendWhenLoaded(_ text: String, to botID: UUID) {
        guard unloadedConversations.contains(botID) else {
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
        guard !typed.isEmpty || !pictures.isEmpty, turns[botID] == nil, let bot = effectiveBot(botID) else { return false }
        ensureLoaded(botID)
        guard let ref = modelRef(for: bot), let account = account(ref.provider), account.isEnabled, isUsable(account) else {
            append(.notice("Conecte um modelo em Ajustes → Modelos para começar."), to: botID)
            return false
        }
        let modelInfo = account.models.first { $0.id == ref.model }
        let sees: Bool? = visionRejected.contains(ref.text) ? false : modelInfo?.supportsImages

        memoryIdle.removeValue(forKey: botID)?.cancel()
        // Full paths: the bubble shows thumbnails of the pictures (a name alone, as older conversations have, still renders).
        append(.user(text: typed, attachments: attachments.map(\.path) + pictures.map(\.path)), to: botID)
        if fromUser { setDraft("", for: botID) }
        setStatus("Pensando", of: botID)
        live(botID).poked()
        flash(\.isListening, botID, seconds: 1.4)

        let intent = routineTurns[botID] == nil ? MemoryIntent.detect(typed) : nil // a routine's prompt is not a request to remember
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
        if !pictures.isEmpty {
            prompt += Self.pictureNote(pictures, forClaudeCode: ref.provider == .claudeCode, modelSees: sees)
        }
        prompt = unattendedPrompt(prompt, for: botID)
        if intent != nil {
            prompt += "\n\n(The user is asking you to remember something. Save it now with the \(rememberTool) tool, picking the "
                + "right tipo; if it refers to something said earlier, save that. Then confirm in one short sentence.)"
        }
        if ref.provider == .claudeCode {
            runClaudeCode(bot, model: ref.model, prompt: prompt, images: pictures, message: typed, turnGrants: turnGrants)
            return true
        }
        let skills = enabledSkills
        let budget = contextBudget(ref: ref, account: account, botID: botID)
        // Read before this turn's own messages are recorded: it is whether the last task is waiting for "continua".
        let paused = conversations[botID]?.isTaskPaused ?? false
        let prepared = conversations[botID, default: Conversation()].prepareHistory(budget: budget)
        let history = prepared.history
        if prepared.firstCompaction { append(.notice("Conversa compactada: o começo virou um resumo."), to: botID) }
        let bank = memory.bank(for: botID)
        let context = ToolContext(workingDirectory: bot.workingURL, memory: bank, botID: botID, jobs: jobs,
                                  imageStore: images, acceptsImages: sees != false)
        let userTurns = userTurnCount(botID)
        let maxSteps = routineTurns[botID] != nil ? AgentEngine.routineMaxSteps : AgentEngine.defaultMaxSteps
        let lastWorkspaceHash = conversations[botID]?.workspaceHash
        let sessionID = gatewaySessionID(for: botID)
        let lastWorkspace = conversations[botID]?.workspaceSeen
        let sentMemories = TurnPreface.relatedLines(in: history)

        let turn = beginTurn(botID)
        turns[botID] = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: typed, conversationIsNew: history.isEmpty, userTurns: userTurns,
                                         canSave: bot.permissionMode != .readOnly, alreadySent: sentMemories)
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard isCurrent(turn, of: botID) else { return } // stopped while preparing
            let built = TurnPrompt.native(inputs, history: history, lastWorkspaceHash: lastWorkspaceHash, lastWorkspace: lastWorkspace)
            let client: any LLMClient
            do {
                guard let made = clientOverride?() ?? account.client(for: modelInfo, credentials: Self.credentials(for: ref.provider),
                                                                      conversationID: sessionID) else { throw LLMError.notConfigured }
                client = made
            } catch {
                failSetup(error, of: botID, turn: turn)
                return
            }
            let accessibilityGranted = !bot.capabilities.contains(.computerUse) || accessibilityProbe()
            var tools = ToolBox.offered(for: bot.capabilities, accessibilityGranted: accessibilityGranted)
            if bot.capabilities.contains(.connectors) { tools += await mcp.tools() }
            guard isCurrent(turn, of: botID) else { return }
            // Recorded when the prompt with the snapshot is stored (see `apply`), not before.
            pendingMarks[botID] = built.marks
            // The system prompt tells the Orb when the interface tools are held back (see `ToolBox.offered`).
            let system = accessibilityGranted ? built.system : built.system + "\n\n" + ToolBox.accessibilityUnavailableNote
            let request = TurnRequest(bot: bot, model: ref.model, system: system, history: history,
                                      prompt: TurnPreface.prepend(built.preface, to: prompt),
                                      client: client, tools: tools, context: context, budget: budget, maxSteps: maxSteps,
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
                                      picksUpTask: paused)
            await play(engine.run(request), for: botID, turn: turn)
        }
        return true
    }

    // MARK: Context

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
        return measuredOverhead[botID].map { budget.refined(overheadTokens: $0) } ?? budget
    }

    /// How full the context of the Orb's conversation is, for the meter. nil for Claude Code or while the Orb has no
    /// usable model.
    func contextFill(for botID: UUID) -> ContextFill? {
        guard let bot = bot(botID), let budget = contextBudget(for: bot) else { return nil }
        return (conversations[botID] ?? Conversation()).contextFill(budget: budget)
    }

    /// Remembers what the system prompt and tool specs of the Orb's last turn took, to plan the next history by.
    func noteMeasuredOverhead(_ tokens: Int, of botID: UUID) {
        measuredOverhead[botID] = tokens
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
        // The app knows whether it has Accessibility; the server (a child process) is told rather than left to ask.
        let usesMac = bot.capabilities.contains(.computerUse)
        let servers = [OrbToolsMCPServer.config(directory: bank.directory, mac: usesMac, folder: bot.workingURL,
                                                accessibilityGranted: usesMac ? accessibilityProbe() : nil)]
            + (bot.capabilities.contains(.connectors) ? connectors.filter(\.isEnabled) : [])
        let isNew = conversation.messages.isEmpty
        let userTurns = userTurnCount(botID)
        claudeTurns.insert(botID)
        claudeTurnFolders[botID] = folder
        let turn = beginTurn(botID)
        turns[botID] = Task {
            guard !Task.isCancelled else { return } // stopped before it began
            let brief = await bank.brief(for: message, conversationIsNew: isNew, userTurns: userTurns,
                                         tools: ClaudeCodePrompt.memoryTools, canSave: bot.permissionMode != .readOnly,
                                         alreadySent: sessionID == nil ? [] : (conversation.claudeRelatedSent ?? []).flatMap { $0 })
            // A resumed session sends the same system prompt again (rebuilt only when its identity, preferences or rules change); the rest rides with the message.
            let inputs = await TurnPromptInputs.gather(bot: bot, skills: skills, brief: brief)
            guard isCurrent(turn, of: botID) else { return } // stopped while preparing
            let built = TurnPrompt.claudeCode(inputs, session: .init(isNewSession: sessionID == nil,
                                                                     workspaceHash: conversation.claudeWorkspaceHash,
                                                                     pinned: conversation.claudeMemoryPinned,
                                                                     standingHash: conversation.claudeStandingHash,
                                                                     workspace: conversation.claudeWorkspaceSeen,
                                                                     system: conversation.claudeSystem))
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
                                            prompt: prompt, images: pictures, context: context, sessionID: sessionID, connectors: servers,
                                            environment: environment, turnGrants: turnGrants,
                                            permissions: permissionSource(for: bot))
            // Recorded when the session answers (see `apply`): a turn that fails before that sent nothing.
            pendingMarks[botID] = built.marks
            await play(claudeEngine.run(claudeTurn), for: botID, turn: turn)
        }
    }

    /// Your messages in the current conversation (the interview lasts the first few).
    private func userTurnCount(_ botID: UUID) -> Int {
        if routineTurns[botID] != nil { return 99 } // a routine's run is not the first conversation: no interview
        return (conversations[botID]?.items ?? []).reduce(0) { count, item in
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

    /// The id this conversation sends gateways that key routing and caching to a session; made on first use and
    /// kept with the conversation (a cleared chat or a routine run starts from a new `Conversation`).
    private func gatewaySessionID(for botID: UUID) -> String {
        if let id = conversations[botID]?.gatewaySessionID { return id }
        let id = UUID().uuidString
        conversations[botID]?.gatewaySessionID = id
        return id
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
        ApprovalNotifications.clear(pendingApprovals(of: botID).map(\.id))
        Task { await gate.cancelApprovals(for: botID) }
        closeStreaming(botID)
        setAwaitingApproval(false, of: botID)
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
    /// takes the card's first suggestion, and "Só nesta tarefa" grants that rule until the turn ends. `note` is what
    /// you told the Orb to do instead of what it asked, on a denial. A card already answered stays as it was (a
    /// banner can be tapped after the card was answered in the app or the app was closed).
    func decide(_ decision: ApprovalDecision, rule: PermissionRule? = nil, note: String? = nil, approvalID: UUID, botID: UUID) {
        // Loaded first: a banner can arrive before this Orb's conversation was read, and a card left open by a run that
        // closed is already denied once it is. Only an open card is answered.
        guard bot(botID) != nil else { return }
        if loadingConversations.contains(botID) { // a read is under way: wait for it instead of reading the file again here
            Task {
                await loadedConversation(botID)
                decide(decision, rule: rule, note: note, approvalID: approvalID, botID: botID)
            }
            return
        }
        ensureLoaded(botID)
        guard isPending(approvalID, of: botID) else { return }
        var chosen = rule
        let note = decision == .deny ? ApprovalNote.clean(note) : nil
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    request.note = note
                    // A grouped card's "Só nesta tarefa" grants every rule it offered (the engine reads them from the card).
                    if decision == .always || (decision == .task && !request.isBatch) { chosen = chosen ?? request.suggestions.first }
                    items[index].kind = .approval(request)
                }
            }
        }
        updateAwaitingApproval(botID)
        ApprovalNotifications.clear([approvalID])
        // Saved before the engine is answered, so its next tool call already sees the rule.
        if decision == .always, let chosen, chosen.isValid {
            update(botID) { if !$0.permissionRules.contains(chosen) { $0.permissionRules.append(chosen) } }
        }
        let answer = ApprovalAnswer(decision: decision, rule: chosen, note: note)
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
            setStatus(routineStatus(text, for: botID), of: botID)
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
            live(botID).runningTool = call.kind
        case .toolFinished(let id, let state, let output):
            live(botID).runningTool = nil
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
            setAwaitingApproval(true, of: botID)
            announceApproval(request, of: botID)
        case .message(let message):
            ensureLoaded(botID)
            conversations[botID, default: Conversation()].messages.append(message)
            if message.role == .user {
                conversations[botID]?.taskPaused = false
                recordMarks(botID, native: true)
            }
            scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
        case .failed(let message):
            closeStreaming(botID)
            append(.notice("Não deu certo: \(message)"), to: botID)
        case .notice(let text):
            // The cache warning is said once per conversation, not at every turn that still has the problem.
            if text == CacheHealth.notice, conversations[botID]?.items.contains(where: { $0.kind == .notice(text) }) == true { break }
            closeStreaming(botID)
            append(.notice(text), to: botID)
        case .usage(let total):
            writeIfChanged(total, at: botID, in: \.usage)
        case .requestUsage(let used):
            writeIfChanged(used, at: botID, in: \.requestUsage)
        case .taskPaused:
            ensureLoaded(botID)
            conversations[botID, default: Conversation()].taskPaused = true
            scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
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
        setStatus(nil, of: botID)
        if routineTurns[botID] != nil {
            // A routine's run isn't a conversation with you: it stays out of the memory's sessions.
            let count = conversations[botID]?.items.count
            conversations[botID]?.memorySavedCount = count
        } else {
            keepRequestedMemory(botID, succeeded: succeeded)
            scheduleMemorySave(botID)
        }
        Task { await refreshMemory(botID) }
        live(botID).runningTool = nil
        setAwaitingApproval(false, of: botID)
        let reply = lastReply(botID)
        let routineID = routineTurns.removeValue(forKey: botID)
        if let routineID { finishRoutineRun(botID, routineID: routineID, succeeded: succeeded, reply: reply) }
        if succeeded {
            flash(\.isCelebrating, botID, seconds: 3)
            if let bot = bot(botID), let reply { notify(bot.name, String(reply.prefix(180))) }
        } else {
            flash(\.hasFailed, botID, seconds: 2.5)
        }
        if selection != .bot(botID) || !(NSApp?.isActive ?? false) {
            setUnread(live(botID).unread + 1, for: botID)
        }
        if routineID == nil { scheduleConversationSave(botID, delay: 0) } // a routine's was written by `finishRoutineRun`
        startNextQueuedRoutine(for: botID)
    }

    /// The last thing the turn's conversation says (a routine's, while it runs; `transcript` is always the chat).
    private func lastReply(_ botID: UUID) -> String? {
        for item in (conversations[botID]?.items ?? []).reversed() {
            if case .bot(let text, _) = item.kind { return text }
            if case .user = item.kind { return nil }
        }
        return nil
    }

    /// Puts the bot in a transient state set for a few seconds.
    private func flash(_ flag: ReferenceWritableKeyPath<BotLive, Bool>, _ botID: UUID, seconds: Double) {
        let live = live(botID)
        live[keyPath: flag] = true
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            live[keyPath: flag] = false
        }
    }

    /// Shows the streamed text received since the last flush (one update for many tokens). The reply's item joins
    /// the transcript with the first flush; after that only its `LiveText` changes, so a flush costs the same
    /// whatever the length of the reply or of the conversation.
    func flushText(_ botID: UUID) { // internal for tests (they flush when they want, not after a delay)
        textFlushes.removeValue(forKey: botID)?.cancel()
        guard let delta = pendingText.removeValue(forKey: botID) else { return }
        if let live = liveTexts[botID] {
            live.append(delta)
            scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
            return
        }
        ensureLoaded(botID)
        if let last = conversations[botID]?.items.last, case .bot(let text, true) = last.kind {
            // A streaming message nobody is writing to yet (not expected). Its row was drawn without a `LiveText`
            // and would not look at one that appears later, so the text carries on in a new item, which gets a new row.
            let item = TranscriptItem(.bot(text: text, isStreaming: true))
            let live = LiveText(itemID: item.id, text: text)
            live.append(delta)
            liveTexts[botID] = live
            mutateItems(of: botID) { items in
                items.removeLast()
                items.append(item)
            }
            return
        }
        let item = TranscriptItem(.bot(text: delta.trimmingCharacters(in: .newlines), isStreaming: true))
        if case .bot(let text, _) = item.kind { liveTexts[botID] = LiveText(itemID: item.id, text: text) } // before the row exists
        mutateItems(of: botID) { $0.append(item) }
    }

    private func closeStreaming(_ botID: UUID) {
        flushText(botID)
        if let live = liveTexts.removeValue(forKey: botID) {
            let text = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
            mutateItems(of: botID) { items in
                guard let index = items.lastIndex(where: { $0.id == live.itemID }) else { return }
                items[index].kind = .bot(text: text, isStreaming: false)
            }
        } else if let last = conversations[botID]?.items.last, case .bot(let text, true) = last.kind {
            mutateItems(of: botID) { items in
                items[items.count - 1].kind = .bot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isStreaming: false)
            }
        }
    }

    private func append(_ kind: TranscriptItem.Kind, to botID: UUID) {
        mutateItems(of: botID) { $0.append(TranscriptItem(kind)) }
    }

    private func mutateItems(of botID: UUID, _ change: (inout [TranscriptItem]) -> Void) {
        ensureLoaded(botID)
        change(&conversations[botID, default: Conversation()].items)
        scheduleConversationSave(botID, delay: Self.streamingSaveInterval)
    }

    /// The conversation as it reads now: the reply being streamed has the text received so far (what is written to
    /// disk), where `conversations` still has the text the reply began with.
    private func withLiveText(_ conversation: Conversation, of botID: UUID) -> Conversation {
        guard let live = liveTexts[botID], let index = conversation.items.lastIndex(where: { $0.id == live.itemID }) else {
            return conversation
        }
        var written = conversation
        written.items[index].kind = .bot(text: live.text, isStreaming: true)
        return written
    }

    // MARK: Routines

    /// Runs the routine now, or, when its Orb is busy, as soon as the Orb is free (a routine waits at most once).
    /// A run has a conversation of its own (`conversations/<Orb>/routine-<routine>.json`): your chat gets one line
    /// when it ends, nothing else.
    func runRoutine(_ routineID: UUID) {
        guard let routine = routines.first(where: { $0.id == routineID }), bot(routine.botID) != nil else { return }
        if unloadedConversations.contains(routine.botID) { // its chat is read off the main thread first
            Task {
                await loadedConversation(routine.botID)
                ensureLoaded(routine.botID)
                runRoutine(routineID)
            }
            return
        }
        guard routineTurns[routine.botID] != routineID else { return }
        guard !queuedRoutines.contains(routineID) else {
            startIdleQueuedRoutines() // waiting, but its Orb may be free by now (the routine was moved to another Orb)
            return
        }
        guard !isWorking(routine.botID) else {
            queuedRoutines.append(routineID)
            return
        }
        startRoutine(routine)
    }

    func isRoutineRunning(_ routineID: UUID) -> Bool { routineTurns.values.contains(routineID) }

    func isRoutineQueued(_ routineID: UUID) -> Bool { queuedRoutines.contains(routineID) }

    /// The transcript of a routine that is running right now (nil when it is not).
    func liveRoutineItems(_ routineID: UUID) -> [TranscriptItem]? {
        guard let botID = routineTurns.first(where: { $0.value == routineID })?.key else { return nil }
        return conversations[botID]?.items
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
        if routineTurns[routine.botID] == routineID { stop(routine.botID) }
        store.deleteRoutineConversation(routine: routineID, for: routine.botID)
    }

    private func startRoutine(_ routine: Routine) {
        let botID = routine.botID
        guard turns[botID] == nil, bot(botID) != nil, let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        ensureLoaded(botID)
        let started = Date.now
        routines[index].lastRun = started
        let read = store.readRoutineConversation(routine: routine.id, for: botID)
        addNotice(Self.labeled(read.notice, for: bot(botID)))

        // The turn machinery works on `conversations[botID]`: the routine's own goes there, the chat waits. The chat is
        // written first (its pending save would otherwise write the routine's conversation in its place): while the
        // routine runs, only the routine's file changes.
        let chat = conversations[botID] ?? Conversation()
        conversationSaves.removeValue(forKey: botID)?.cancel()
        dirtyConversations.remove(botID)
        if !chat.items.isEmpty { store.save(chat, for: botID) }
        parkedChats[botID] = chat
        conversations[botID] = (read.value?.closingInterruptedTurn() ?? Conversation()).startingRoutineRun(at: started)
        routineTurns[botID] = routine.id
        routineStarts[botID] = started
        let hasPrompt = !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPrompt, send(routine.prompt, to: botID) {
            setStatus(routineStatus("Pensando", for: botID), of: botID)
            return
        }
        // Nothing was sent (no model connected, nothing to do): the run did not happen. It is only in the history.
        routineTurns[botID] = nil
        routineStarts[botID] = nil
        if let chat = parkedChats.removeValue(forKey: botID) { conversations[botID] = chat }
        let reason = hasPrompt ? "Não rodou: conecte um modelo em Ajustes." : "Não rodou: a rotina está sem instruções."
        routines[index].lastResult = reason
        recordRun(RoutineRun(date: started, finishedAt: started, succeeded: false, summary: reason), routineID: routine.id)
    }

    /// Runs the routines that were waiting for this Orb, one at a time, as it becomes free.
    private func startNextQueuedRoutine(for botID: UUID) {
        while turns[botID] == nil,
              let next = queuedRoutines.first(where: { id in routines.first { $0.id == id }?.botID == botID }) {
            queuedRoutines.removeAll { $0 == next }
            if let routine = routines.first(where: { $0.id == next }) { startRoutine(routine) }
        }
    }

    /// Starts the queued routines whose Orb is free (see `runRoutine`, `queueFollowsEdits`).
    private func startIdleQueuedRoutines() {
        for id in queuedRoutines {
            guard let botID = routines.first(where: { $0.id == id })?.botID, turns[botID] == nil, !isWorking(botID) else { continue }
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
    private func finishRoutineRun(_ botID: UUID, routineID: UUID, succeeded: Bool, reply: String?) {
        let finished = Date.now
        let started = routineStarts.removeValue(forKey: botID) ?? finished
        let own = conversations[botID] ?? Conversation()
        let routine = routines.first { $0.id == routineID }
        if routine != nil { store.saveRoutineConversation(own, routine: routineID, for: botID) }
        if let chat = parkedChats.removeValue(forKey: botID) { conversations[botID] = chat }
        if hasUnsavedStretch(botID) { scheduleMemorySave(botID) } // the run cancelled the chat's pending save
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
        guard let routineID = routineTurns[botID], let routine = routines.first(where: { $0.id == routineID }) else { return prompt }
        return RoutinePrompt.unattended(prompt, routine: routine.name, previous: routine.runs.first { $0.report != nil })
    }

    /// The status line says which routine the Orb is busy with.
    private func routineStatus(_ text: String, for botID: UUID) -> String {
        guard let routineID = routineTurns[botID], let routine = routines.first(where: { $0.id == routineID }) else { return text }
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
        guard !(NSApp?.isActive ?? false), Self.notificationsEnabled, ApprovalNotifications.isAvailable else { return }
        let content = ApprovalNotifications.plainContent(title: title, body: body)
        Task { await ApprovalNotifications.send(content) }
    }

    // MARK: Saving

    private var state: AppState {
        var unread: [String: Int] = [:]
        for (id, live) in lives where live.unread > 0 { unread[id.uuidString] = live.unread }
        return AppState(bots: bots, routines: routines, skills: skills, connectors: connectors, providers: providers,
                        defaultModel: defaultModel, unread: unread, contextMemory: contextMemory,
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

    /// Saves `delay` seconds after the first unsaved change (a streaming reply is written at most every
    /// `streamingSaveInterval`, not rescheduled per token); `delay: 0` saves right away (end of a turn, new
    /// conversation). Encoding and pruning happen on the store's queue.
    private func scheduleConversationSave(_ botID: UUID, delay: Double) {
        guard let conversation = conversations[botID] else { return } // not loaded: nothing of ours to write
        dirtyConversations.insert(botID)
        if delay > 0, conversationSaves[botID] != nil { return }
        // A long conversation is a big file to replace: the pace of a streaming reply's saves slows with its size
        // (5 s up to 10 s at 2,000 items), and the turn's end writes at once whatever the pace.
        let wait = delay > 0 ? delay + min(5, Double(conversation.items.count) / 400) : 0
        conversationSaves[botID]?.cancel()
        conversationSaves[botID] = Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            conversationSaves[botID] = nil
            writeConversation(botID)
        }
    }

    private func writeConversation(_ botID: UUID) {
        guard let current = conversations[botID] else { return }
        let conversation = withLiveText(current, of: botID)
        dirtyConversations.remove(botID)
        guard let routineID = routineTurns[botID] else { return store.save(conversation, for: botID) }
        // A running routine's conversation goes to its own file, never over the chat's.
        if routines.contains(where: { $0.id == routineID }) {
            store.saveRoutineConversation(conversation, routine: routineID, for: botID)
        }
    }

    /// Writes everything that changed and waits for the disk (on quit).
    func saveNow() {
        store.save(state)
        for botID in dirtyConversations {
            conversationSaves.removeValue(forKey: botID)?.cancel() // written now: its timer has nothing left to do
            writeConversation(botID)
        }
        // A chat parked by a running routine is not `conversations[botID]`, so nothing above writes it.
        for (botID, chat) in parkedChats where !chat.items.isEmpty { store.save(chat, for: botID) }
        store.flush()
    }
}
