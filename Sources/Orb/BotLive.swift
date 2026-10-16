import SwiftUI
import Observation

/// What identifies an Orb on screen: enough for a sidebar row, a message avatar or a title. A small `Equatable`
/// value, so views that only show these do not depend on the whole `Bot` (permissions, folder, memory…).
struct BotLook: Equatable, Sendable {
    var id: UUID
    var name: String
    var role: String
    var orb: OrbConfig

    init(_ bot: Bot) {
        id = bot.id
        name = bot.name
        role = bot.role
        orb = bot.orb
    }
}

/// The other Orb in an exchange that is going on: the sidebar draws a ring around the avatar in its color. Small and
/// `Equatable`, written only when it changes.
struct PartnerTint: Equatable, Sendable {
    var botID: UUID
    /// The partner's `OrbConfig.color` (an id of `OrbCatalog`).
    var color: String
}

/// One Orb as the views see it: its settings and everything that changes while the app runs (what it is doing,
/// whether it waits for you, how many messages you have not read, its memory).
///
/// Views read the object of the Orb they show and nothing else, so an event in one Orb (a tool call, a status,
/// the end of a turn) re-renders only what shows that Orb, never another Orb's row, composer or inspector. The
/// dictionary of these objects lives in `AppModel` and is not observed: it changes only when an Orb is added
/// or deleted, and `AppModel.botIDs` says so. What runs behind it (the turn, the conversation, the streamed reply)
/// is the Orb's `BotSession`.
///
/// The properties views read are `private(set)` and assigned only when the value differs: writing an
/// `@Observable` property notifies its readers, and for a collection even a write that changes nothing does.
/// `AppModel` is the only writer.
@MainActor
@Observable
final class BotLive {
    let id: UUID

    // MARK: What views read

    /// The Orb's settings (a mirror of `AppModel.bots`, which stays the persisted source).
    private(set) var bot: Bot
    /// The parts of `bot` that rows, titles and avatars show, and the two the composer's menus show. Each is
    /// assigned only when it changes, so changing, say, the folder re-renders none of them.
    private(set) var look: BotLook
    private(set) var permission: PermissionState
    private(set) var modelID: String
    /// The line under the Orb's name while a turn runs; nil exactly when no turn runs.
    private(set) var status: String?
    /// What the working line, the sidebar row and the menu bar panel say the Orb is doing: a verb and its target. It
    /// follows `status` step by step (never per token), each phrase staying at least `workDwell` so none flickers;
    /// nil exactly when `status` is.
    private(set) var work: WorkLine?
    // MARK: MultiOrb (WP0)
    /// What the Orb says while it waits for other Orbs' answers after its own turn ended ("Esperando Pesquisador"); nil when
    /// it waits for none. Written by the delegation runtime.
    private(set) var chainWork: WorkLine?
    /// The Orb it is exchanging messages with now (the sidebar's ring).
    private(set) var partner: PartnerTint?
    // MARK: end MultiOrb (WP0)
    /// `status != nil`, kept apart so the composer does not re-render with every new status line.
    private(set) var isWorking = false
    /// When the running turn began (nil exactly when none runs); the working line counts from it.
    private(set) var workingSince: Date?
    /// What the Orb's avatar does (expression, gaze and motion follow this).
    private(set) var activity = OrbActivity.idle
    /// An approval card is open: the Orb is stopped until you answer.
    private(set) var needsYou = false
    /// Incremented when a prompt is sent; Orbs give their small "got it" jump when it changes.
    private(set) var poke = 0
    /// Incremented when the chat should scroll to the end because you sent something: the message you sent, or one queued
    /// while the Orb works (its bubble changes no transcript revision). Not for a routine's prompt or a queued message
    /// delivered to the model, which must not pull a chat you are reading. The Orb does not jump for it.
    private(set) var scrollNudge = 0
    /// Incremented when a turn starts by itself in this chat (the answers to the Orb's requests to other Orbs wake it): the
    /// chat follows the new rows only if it was following the end, and stays where it is when you scrolled up to read.
    /// `scrollNudge` is for what you sent and always takes the chat to the end.
    private(set) var followNudge = 0
    /// The rows of the chat that are about to leave because you edited a message or asked for a reply again: they fade
    /// out (`Motion.exit`) before the conversation is cut. Empty the rest of the time.
    private(set) var dropping: Set<UUID> = []
    /// Incremented when the Orb is selected; its sidebar Orb blinks and glances toward the chat when it changes.
    private(set) var glance = 0
    /// How much the Orb celebrates while `activity` is `happy`.
    private(set) var celebration = OrbCelebration.big
    /// A one-time reaction for the Orb's avatars (a blink when you stop the reply, a sigh when a task stopped half way).
    private(set) var cue = OrbCueSignal()
    /// Messages from turns that ended while you were elsewhere. Saved with the app's state.
    private(set) var unread = 0
    /// What the inspector's memory section shows, refreshed after changes.
    private(set) var memory = MemorySnapshot()
    /// The Orb's latest model call (what the context meter's cache hit reads) and what its latest compaction left
    /// the conversation at, in tokens. Mirrors of `AppModel.requestUsage` and `lastCompaction`, here so the meter
    /// depends on its own Orb only.
    private(set) var lastUsage: TokenUsage?
    private(set) var compactedTo: Int?
    /// What the running turn used so far, summed over its calls (the working line's meter says it); nil when no turn runs.
    private(set) var turnSpend: TurnSpend?
    /// The processes the Orb left running (`run_command` with background), shown above the message box until they end.
    private(set) var jobs: [BackgroundJobs.Snapshot] = []
    /// The turn waits for a command that can go on in the background (`CommandRelease`): the working line offers it.
    private(set) var commandWaited = false

    // MARK: What the activity follows

    // Inputs of `activity`, written by the model as a turn goes. Views read the result, not these, so each one
    // is ignored by observation and any change recomputes the observed values (which notify only if they differ).

    /// What the current tool does.
    @ObservationIgnored var runningTool: ToolCall.Kind? { didSet { refresh() } }
    /// Reply text is arriving right now (changes when a burst of text starts or ends, not per token).
    @ObservationIgnored var isSpeaking = false { didSet { refresh() } }
    /// Just received a prompt (a short "listening" beat before thinking).
    @ObservationIgnored var isListening = false { didSet { refresh() } }
    /// Just finished a turn; the Orb celebrates for a moment.
    @ObservationIgnored var isCelebrating = false { didSet { refresh() } }
    /// The last turn was interrupted or failed (a brief "error" expression).
    @ObservationIgnored var hasFailed = false { didSet { refresh() } }
    /// The Orb waits for the answer of another Orb it asked (`OrbActivity.conversing`).
    @ObservationIgnored var isConversing = false { didSet { refresh() } }
    @ObservationIgnored private(set) var isAwaitingApproval = false
    /// You are typing to the Orb: from the first keystroke until `composingQuiet` after the last (see `noteComposing`).
    @ObservationIgnored private(set) var isComposing = false
    @ObservationIgnored private var composing = ComposingDeadline(quiet: BotLive.composingQuiet)
    @ObservationIgnored private var composingWatch: Task<Void, Never>?
    static let composingQuiet = Duration.milliseconds(3000)
    /// How long each phrase of `work` stays before the next one replaces it.
    static let workDwell = Duration.milliseconds(700)
    @ObservationIgnored private var dwell = StatusDwell(minDwell: BotLive.workDwell)
    @ObservationIgnored private var dwellWatch: Task<Void, Never>?

    init(_ bot: Bot) {
        id = bot.id
        self.bot = bot
        look = BotLook(bot)
        permission = PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
        modelID = bot.model
    }

    // MARK: Writes (each does nothing when the value is the same)

    func update(_ bot: Bot) {
        guard bot != self.bot else { return }
        self.bot = bot
        assign(\.look, to: BotLook(bot))
        assign(\.permission, to: PermissionState(mode: bot.permissionMode, rules: bot.permissionRules))
        assign(\.modelID, to: bot.model)
    }

    func setStatus(_ text: String?) {
        if text == nil { // the end of a turn does not wait for the phrase on screen
            setWork(nil)
            assign(\.turnSpend, to: nil)
        }
        guard text != status else { return }
        status = text
        assign(\.workingSince, to: text == nil ? nil : (workingSince ?? .now))
        refresh()
    }

    /// The phrase for the working line. The first of a turn, a wait for you and the end of the turn (nil) show at once;
    /// any other waits until the one on screen has had `workDwell`, and only the newest of those that arrive meanwhile
    /// comes in (one task per Orb, alive only while a phrase waits).
    func setWork(_ line: WorkLine?, at now: ContinuousClock.Instant = .now) {
        switch dwell.offer(line, at: now) {
        case .now:
            dwellWatch?.cancel()
            dwellWatch = nil
            assign(\.work, to: line)
        case .at:
            guard dwellWatch == nil else { return }
            dwellWatch = Task { [weak self] in
                while !Task.isCancelled, let due = self?.dwell.due {
                    try? await Task.sleep(until: due)
                    if Task.isCancelled { return }
                    if let line = self?.dwell.release(at: .now) { self?.assign(\.work, to: line) }
                }
                // A task cancelled before it ran must not clear the reference to a newer one.
                if !Task.isCancelled { self?.dwellWatch = nil }
            }
        case .unchanged:
            break
        }
    }

    /// What views say the Orb is doing: its phrase, or (for a status no step gave a phrase to) the plain status. nil when
    /// no turn runs.
    var shownWork: WorkLine? { work ?? status.map { WorkPhrase.line(status: $0) } ?? chainWork }

    /// Tests shorten the time a phrase stays.
    func setWorkDwell(_ duration: Duration) { dwell.minDwell = duration }

    /// What the running turn has used so far (nil: a new turn starts from nothing).
    func setTurnSpend(_ spend: TurnSpend?) { assign(\.turnSpend, to: spend) }

    /// Moves the start of the running turn (tests and review snapshots show a turn that has gone on a while).
    func backdateWork(to date: Date) {
        if isWorking { workingSince = date }
    }

    func setAwaitingApproval(_ isWaiting: Bool) {
        guard isWaiting != isAwaitingApproval else { return }
        isAwaitingApproval = isWaiting
        refresh()
    }

    func setLastUsage(_ usage: TokenUsage?) { assign(\.lastUsage, to: usage) }

    func setCompactedTo(_ tokens: Int?) { assign(\.compactedTo, to: tokens) }

    func setJobs(_ list: [BackgroundJobs.Snapshot]) { assign(\.jobs, to: list) }

    func setCommandWaited(_ waited: Bool) { assign(\.commandWaited, to: waited) }


    func setUnread(_ count: Int) { assign(\.unread, to: count) }

    func setMemory(_ snapshot: MemorySnapshot) { assign(\.memory, to: snapshot) }

    func poked() { poke += 1 }

    func scrolled() { scrollNudge += 1 }

    func followed() { followNudge += 1 }

    func setDropping(_ ids: Set<UUID>) { assign(\.dropping, to: ids) }

    func cued(_ kind: OrbCue) { cue = OrbCueSignal(count: cue.count + 1, kind: kind) }

    func setCelebration(_ level: OrbCelebration) { assign(\.celebration, to: level) }

    func setChainWork(_ line: WorkLine?) { assign(\.chainWork, to: line) }

    func setPartner(_ tint: PartnerTint?) { assign(\.partner, to: tint) }

    func glanced() { glance += 1 }

    // MARK: MultiOrb (WP3)
    /// Incremented when the Orb was just born from another Orb's proposal: its sidebar avatar gives the birth hop.
    private(set) var landing = 0

    func landed() { landing += 1 }
    // MARK: end MultiOrb (WP3)

    // MARK: Composing

    /// The draft in the Orb's composer changed: the Orb watches you type (`attentive`) from the first keystroke
    /// until you pause for `quiet`, and stops at once when the field is emptied (deleted or sent). Like `speaking`,
    /// only the start and the end of a burst change what views read; a keystroke in between moves a deadline that
    /// nothing observes, checked by one task per Orb.
    func noteComposing(draftIsEmpty: Bool, quiet: Duration = BotLive.composingQuiet) {
        guard !draftIsEmpty else { stopComposing(); return }
        composing.quiet = quiet
        guard composing.keystroke(at: .now) else { return }
        isComposing = true
        refresh()
        composingWatch = Task { [weak self] in
            while !Task.isCancelled, let deadline = self?.composing.until {
                if self?.composing.isOver(at: .now) != false { self?.stopComposing(); return }
                try? await Task.sleep(until: deadline)
            }
        }
    }

    func stopComposing() {
        composing.end()
        composingWatch?.cancel()
        composingWatch = nil
        guard isComposing else { return }
        isComposing = false
        refresh()
    }

    private func refresh() {
        assign(\.needsYou, to: isAwaitingApproval)
        assign(\.isWorking, to: status != nil)
        assign(\.activity, to: Self.activity(awaitingApproval: isAwaitingApproval, failed: hasFailed, celebrating: isCelebrating,
                                              isWorking: status != nil, tool: runningTool, speaking: isSpeaking,
                                              listening: isListening, composing: isComposing, conversing: isConversing))
    }

    /// What the Orb does, most urgent first: waiting for you, the error and happy beats, then (while a turn
    /// runs) its tool, its speech, the listening beat or plain thinking. When nothing runs, it watches you type
    /// (`attentive`) or is idle: a working Orb keeps working while you write to it.
    nonisolated static func activity(awaitingApproval: Bool, failed: Bool, celebrating: Bool, isWorking: Bool,
                                     tool: ToolCall.Kind?, speaking: Bool, listening: Bool,
                                     composing: Bool = false, conversing: Bool = false) -> OrbActivity {
        if awaitingApproval { return .waiting }
        if failed { return .error }
        if celebrating { return .happy }
        guard isWorking else { return conversing ? .conversing : composing ? .attentive : .idle }
        if let tool {
            switch tool {
            case .shell: return .typing
            case .browser, .computer: return .browsing
            case .file: return .reading
            case .search: return .searching
            case .connector, .memory, .schedule, .plan: return .thinking
            case .orbs: return .conversing
            }
        }
        if speaking { return .speaking }
        return listening ? .listening : .thinking
    }
}

// MARK: - Composing

/// When you stop typing to an Orb: a deadline that every keystroke pushes back. Only the first keystroke of a burst
/// starts something; the end is up to whoever watches `until`.
struct ComposingDeadline: Sendable {
    var quiet: Duration
    /// When the burst ends if no other key comes (nil: no burst).
    private(set) var until: ContinuousClock.Instant?

    init(quiet: Duration) { self.quiet = quiet }

    /// A keystroke at `now`; true when it starts a burst.
    mutating func keystroke(at now: ContinuousClock.Instant) -> Bool {
        defer { until = now + quiet }
        return until == nil
    }

    /// The burst is over at `now` (no burst counts as over).
    func isOver(at now: ContinuousClock.Instant) -> Bool { until.map { $0 <= now } ?? true }

    mutating func end() { until = nil }
}

// MARK: - Writing observable state only when it changes

/// Marks the observable types (`AppModel`, `BotLive`, `BotSession`) that write through the helpers below, so they
/// do not spread to every `@Observable` type in the app.
@MainActor
protocol WritesOnlyChanges: AnyObject {}

extension BotLive: WritesOnlyChanges {}
extension AppModel: WritesOnlyChanges {}

extension WritesOnlyChanges {
    /// Writes `value` only when it differs from what is there. An `@Observable` property notifies its readers
    /// on every write that goes through `_modify` (a dictionary or set changed in place, `+=`), even when
    /// nothing changes, and each notification is a re-render. Reading first costs nothing.
    func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// `dictionary[key] = value` (or removal, with nil), skipped when it would change nothing.
    func writeIfChanged<Key: Hashable, Value: Equatable>(_ value: Value?, at key: Key,
                                                in keyPath: ReferenceWritableKeyPath<Self, [Key: Value]>) {
        if self[keyPath: keyPath][key] != value { self[keyPath: keyPath][key] = value }
    }
}
