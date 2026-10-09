import Foundation
import Observation

/// One Orb's running machinery: its conversation in memory and how it is read and written, the turn it runs (and
/// the routine that started it), the reply being streamed, what that turn costs and what it must remember to do
/// when it ends. `AppModel` keeps one per Orb (`sessions`) and keeps the app-wide things (the list of Orbs, the
/// routines and their queue, providers, catalogs, settings, the data files as a whole).
///
/// Kept apart from `BotLive` on purpose: `BotLive` is the small surface the views of an Orb read (status, activity,
/// unread, settings), written only when a value changes; this is the engine room behind it, mostly state no view
/// reads. The few things views do read here (`conversation` through the transcript, `isLoading`, `routineID`, the
/// usage of the last turn) are observed per session, so a change in one Orb notifies nothing that shows another.
@MainActor
@Observable
final class BotSession {
    let id: UUID
    /// The app the Orb belongs to: what a turn needs beyond this Orb (the Orb's settings, its live state, the
    /// routines, the data files) is asked of it. Weak: the app owns its sessions.
    @ObservationIgnored private(set) weak var model: AppModel?

    init(id: UUID, model: AppModel?) {
        self.id = id
        self.model = model
    }

    // MARK: Conversation

    /// The conversation in memory (nil while it is on disk only). While a routine runs, the routine's own
    /// conversation: the turn machinery works on this one, and the user's chat waits in `parkedChat`.
    var conversation: Conversation? { didSet { showTranscript() } }
    /// The user's chat while a routine of this Orb runs, untouched. Every turn of an Orb works on one conversation at
    /// a time, so a routine and a chat turn of the same Orb cannot run together yet (the routine waits in the queue).
    var parkedChat: Conversation? { didSet { showTranscript() } }
    /// The conversation isn't in memory (never in `conversation`): not read yet, or let go of again.
    @ObservationIgnored var isUnloaded = false
    /// The conversation is being read off the main thread right now: the chat shows a placeholder.
    var isLoading = false
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// Bumped when the conversation is read synchronously or let go of, so a read that was already under way (and may
    /// be older than what is in memory now) is not installed.
    @ObservationIgnored var loadEpoch = 0
    /// When the conversation in memory was last shown, read or changed.
    @ObservationIgnored var lastUsed: ContinuousClock.Instant?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    /// The conversation changed since it was last written; quitting saves only the sessions with this set.
    @ObservationIgnored var isDirty = false

    /// Changes the conversation in place, starting an empty one when there is none (what writing through
    /// `conversations[botID, default: Conversation()]` did).
    @discardableResult
    func changeConversation<Result>(_ change: (inout Conversation) -> Result) -> Result {
        var outcome: Result?
        conversation?.changing { outcome = change(&$0) } // in place
        if let outcome { return outcome }
        // None in memory: an empty one, changed before it is installed (one write, as the dictionary's was).
        var fresh = Conversation()
        let result = change(&fresh)
        conversation = fresh
        return result
    }

    /// Whether the conversation was not in memory (and now counts as being in memory). The `remove(_:) != nil` of
    /// the set of unloaded conversations this replaced.
    func takeUnloaded() -> Bool {
        guard isUnloaded else { return false }
        isUnloaded = false
        return true
    }

    // MARK: What the chat view reads

    /// What the chat view reads (see `AppModel.orbTranscript`), made when first asked for.
    @ObservationIgnored private(set) var transcript: OrbTranscript?

    /// The user's chat: the parked one while a routine runs, otherwise the conversation.
    var shownItems: [TranscriptItem] { (parkedChat ?? conversation)?.items ?? [] }

    func makeTranscript() -> OrbTranscript {
        if let transcript { return transcript }
        let made = OrbTranscript(items: shownItems)
        transcript = made
        return made
    }

    /// Hands the chat view its items after the conversation or the parked chat changed. Cheap when the items were not
    /// touched (`OrbTranscript.show` compares storage, not elements).
    private func showTranscript() {
        transcript?.show(shownItems)
    }

    // MARK: Streaming

    /// The reply being streamed right now. Its text lives here, not in the conversation, until the reply is closed
    /// (`closeStreaming`), so a flush does not touch the list of items.
    @ObservationIgnored var liveText: LiveText?
    /// Streamed text not shown yet: deltas are published at most every `textFlushInterval`.
    @ObservationIgnored var pendingText: String?
    @ObservationIgnored var textFlush: Task<Void, Never>?
    /// Until when the Orb keeps talking (it stops when no text arrived for `speakingQuiet`).
    @ObservationIgnored var speakingUntil: ContinuousClock.Instant?
    @ObservationIgnored var speakingWatch: Task<Void, Never>?
    /// The tool calls of the running turn that have not finished: a status line that repeats one's title is that call's
    /// phrase, which already says its target.
    @ObservationIgnored var runningCalls: [UUID: ToolCall] = [:]
    /// How many tool calls the running turn has made (the working line's "3 ações").
    @ObservationIgnored var actionsThisTurn = 0

    // MARK: Turn

    @ObservationIgnored var turnTask: Task<Void, Never>?
    /// The running turn's id. A turn that was stopped can still be finishing its setup or draining events while the
    /// next one runs; only the current id may change the Orb's state.
    @ObservationIgnored var turnID: UUID?
    /// The running turn belongs to Claude Code (stop and approvals go there).
    @ObservationIgnored var isClaudeTurn = false
    /// The folder the running Claude Code turn started in; its session belongs to that folder.
    @ObservationIgnored var claudeTurnFolder: String?
    /// The running Claude Code turn reached the CLI (its session answered). One that failed before that, or was stopped
    /// while preparing, handed the session nothing: what other models said stays to be caught up on.
    @ObservationIgnored var claudeTurnDelivered = false
    /// The routine whose run is the running turn.
    var routineID: UUID?
    /// When the running routine's run began.
    @ObservationIgnored var routineStart: Date?
    /// The snapshot and rules marks of the running turn, recorded on its conversation once the model has been given them.
    @ObservationIgnored var pendingMarks: DeliveryMarks?
    /// The running turn folded older turns into the summary: the conversation is saved to memory when it ends.
    @ObservationIgnored var compactedInTurn = false
    /// The model's notes that folds made during this turn carried into the summary (they go to the memory at its end).
    @ObservationIgnored var foldedNotes: [String] = []
    /// The running turn is one where you asked the Orb to remember something, and where its transcript starts.
    @ObservationIgnored var memoryRequest: (intent: MemoryIntent, from: Int)?
    /// Saves a conversation stretch to memory once the user has been away for `SessionSummary.idleGap`.
    @ObservationIgnored var memoryIdle: Task<Void, Never>?
    /// Tokens of system prompt and tool specs the engine measured on the last turn (not kept across launches).
    @ObservationIgnored var measuredOverhead: Int?
    /// The model ("provider/model") the running turn uses, for the usage it records.
    @ObservationIgnored var turnModel: String?
    /// The note on a stretch of the conversation being written in the background (see `ChunkSummary`), and how many
    /// times each stretch (by the index of its first message) was asked for.
    @ObservationIgnored var chunkTask: Task<Void, Never>?
    @ObservationIgnored var chunkAttempts: [Int: Int] = [:]

    // MARK: Learning skills

    /// Steps with tools (model answers that ask for tools) of the turns Orb's own engine answered since the Orb last
    /// proposed a skill (not kept across launches, as in Hermes): at `SkillReview.threshold` the end of a turn starts a
    /// review of the conversation.
    @ObservationIgnored var stepsSinceSkill = 0
    /// The request of the latest turn of Orb's own engine, with the history it sent but not its message: what a review
    /// asks the model with, so the system prompt, the tools and the history are the ones the provider has in its cache.
    /// Nil for a turn of Claude Code.
    @ObservationIgnored var reviewBase: TurnRequest?
    /// Where in the conversation's messages the turn began: what the turn added is what follows `reviewBase.history`.
    @ObservationIgnored var reviewFrom = 0
    /// The review that runs now, in the background. It stops when you write.
    @ObservationIgnored var skillReview: Task<Void, Never>?
    /// The proposals the chat already told about (the command and when it was written), so each is told once.
    @ObservationIgnored var announcedProposals: [String: Date] = [:]

    // MARK: Composer

    /// What the composer holds that outlives its view (attachments not sent yet, messages queued during a turn,
    /// which the running turn's engine drains as its steering queue); see `AppModel+Steering.swift`.
    @ObservationIgnored private(set) var lane: ComposerLane?

    /// The composer state, made when first asked for.
    func composerLane() -> ComposerLane {
        if let lane { return lane }
        let made = ComposerLane()
        lane = made
        return made
    }

    // MARK: Usage

    /// Tokens the last turn used, summed over its model calls (for a context meter).
    private(set) var usage: TokenUsage?
    /// Tokens of the latest model call alone: `promptTokens` is how full the context is now and `cacheHitRatio` how
    /// much of it the provider's cache served (native engine only; for the context meter).
    private(set) var requestUsage: TokenUsage?
    /// What the latest compaction did (on its own, on request, or Claude Code's own), for the context meter.
    var lastCompaction: CompactionReport?

    func setUsage(_ total: TokenUsage) { assign(\.usage, to: total) }

    func setRequestUsage(_ used: TokenUsage) { assign(\.requestUsage, to: used) }
    func clearRequestUsage() { assign(\.requestUsage, to: nil) }
}

extension BotSession: WritesOnlyChanges {}

private extension Conversation {
    /// `change` applied to the conversation where it is (through optional chaining, so it is not copied first).
    mutating func changing(_ change: (inout Conversation) -> Void) { change(&self) }
}
