import Foundation

// The pulse: from time to time one Orb wakes by itself, looks at its team, its groups and its memory, and acts if coordinating
// would help the person (ask a teammate, create Orbs or groups, move members). Nothing else wakes an Orb without a message or a
// routine. Three things keep it cheap: a check with no model (the Orb's fingerprint did not change since its last pulse, so it
// is skipped for free), one Orb per interval in turn, and a daily budget of tokens that counts the pulse turn and everything
// the chain it starts spends (requests to other Orbs, group turns). When the budget runs out the pulse waits for the next day and
// the chain that was working is stopped.

/// What the pulse remembers between launches (one small value in the preferences). Tolerant: a missing or unreadable field
/// reads as its default, and the whole value as a fresh one.
struct PulseState: Codable, Equatable, Sendable {
    /// When the interval last started over: a pulse began, or a whole pass found nothing to do. Nil: never (the first window
    /// opens when the pulse first looks, so a new install does not spend tokens at once).
    var lastPulse: Date?
    /// The Orb examined last: the next pass starts after it (turn-taking, robust to Orbs added and deleted).
    var lastOrb: UUID?
    /// By Orb id: what the Orb could see when its last pulse ended. Equal again means nothing happened since.
    var fingerprints: [String: String] = [:]
    /// By Orb id: when its last pulse began.
    var lastRunByOrb: [String: Date] = [:]
    /// What the last pulse that did something said, and when.
    var lastSummary: String?
    var lastActed: Date?
    /// Passes over an Orb that were skipped because nothing changed (they cost no token).
    var skipped = 0
    /// The local day (`yyyy-MM-dd`) the counter is for, and the tokens the pulse and its chains spent in it.
    var day = ""
    var tokensToday = 0

    /// A new day starts the count over.
    mutating func roll(to date: Date, calendar: Calendar = .current) {
        let today = Self.dayKey(date, calendar: calendar)
        guard day != today else { return }
        day = today
        tokensToday = 0
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension PulseState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastPulse = (try? c.decodeIfPresent(Date.self, forKey: .lastPulse)) ?? nil
        lastOrb = (try? c.decodeIfPresent(UUID.self, forKey: .lastOrb)) ?? nil
        fingerprints = (try? c.decodeIfPresent([String: String].self, forKey: .fingerprints)) ?? [:]
        lastRunByOrb = (try? c.decodeIfPresent([String: Date].self, forKey: .lastRunByOrb)) ?? [:]
        lastSummary = (try? c.decodeIfPresent(String.self, forKey: .lastSummary)) ?? nil
        lastActed = (try? c.decodeIfPresent(Date.self, forKey: .lastActed)) ?? nil
        skipped = (try? c.decodeIfPresent(Int.self, forKey: .skipped)) ?? 0
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        tokensToday = max(0, (try? c.decodeIfPresent(Int.self, forKey: .tokensToday)) ?? 0)
    }
}

/// A pulse run in progress, in memory only.
struct PulseRun: Equatable {
    var id: UUID
    var startedAt: Date
    /// Tokens the pulse turn itself spent (the day's count also has its chain's).
    var tokens = 0
}

enum Pulse {
    /// What the model is sent. Short, in English: it goes in every pulse.
    static let prompt = "[Pulse] Nobody asked for this run. Check your team, your groups and your memory. If coordinating would "
        + "help the user's goals, act now: ask teammates, create Orbs or groups, adjust members. If nothing is worth doing, "
        + "reply only NOTHING."

    static let defaultMinutes = 60
    static let minimumDailyTokens = 10_000
    static let defaultDailyTokens = 300_000

    /// The reply that means "nothing to do" (any case, with or without a full stop or markdown around it).
    static func isNothing(_ reply: String?) -> Bool {
        guard let reply else { return true }
        let letters = reply.filter(\.isLetter).uppercased()
        return letters.isEmpty || letters == "NOTHING"
    }

    /// A stable 64-bit FNV-1a, in hex: `Hasher` changes between launches, and the fingerprints are kept.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }

    /// The files and folders an Orb's fingerprint reads, as one line each (size and modification time; a missing one is "-").
    /// Pure disk reads, so it runs off the main thread. `memory`: the Orb's memory folder, walked whole (a page edit changes the
    /// time of the page, not of the folder). `folder`: the Orb's other conversations and side runs, minus the pulse's own file
    /// (the pulse must not see itself).
    nonisolated static func disk(files: [URL], folder: URL, memory: URL) -> String {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func mark(_ url: URL) -> String {
            guard let values = try? url.resourceValues(forKeys: keys) else { return "-" }
            return "\(values.fileSize ?? 0)@\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
        var lines = files.map { $0.lastPathComponent + "=" + mark($0) }
        let own = Store.pulsoPrefix + "-"
        for url in ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter({ !$0.lastPathComponent.hasPrefix(own) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            lines.append(url.lastPathComponent + "=" + mark(url))
        }
        if let walk = manager.enumerator(at: memory, includingPropertiesForKeys: Array(keys)) {
            var pages: [String] = []
            for case let url as URL in walk { pages.append(url.path.replacingOccurrences(of: memory.path, with: "") + "=" + mark(url)) }
            lines += pages.sorted()
        }
        return lines.joined(separator: "\n")
    }
}

extension AppModel {
    // MARK: Settings

    static let pulseEnabledKey = "pulseEnabled", pulseMinutesKey = "pulseMinutes", pulseDailyTokensKey = "pulseDailyTokens"
    static let pulseStateKey = "pulseState"

    /// Ajustes → Orbs → "Pulso dos Orbs". On unless switched off.
    var pulseEnabled: Bool {
        get { preferences.object(forKey: Self.pulseEnabledKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: Self.pulseEnabledKey); syncActivities() }
    }

    /// Minutes between two pulses, `Schedule.minuteRange` like the routines' interval.
    var pulseMinutes: Int {
        get {
            let stored = preferences.object(forKey: Self.pulseMinutesKey) as? Int ?? Pulse.defaultMinutes
            return min(max(stored, Schedule.minuteRange.lowerBound), Schedule.minuteRange.upperBound)
        }
        set { preferences.set(min(max(newValue, Schedule.minuteRange.lowerBound), Schedule.minuteRange.upperBound), forKey: Self.pulseMinutesKey) }
    }

    /// The tokens per day the pulse and the chains it starts may spend (`UsageTotals.budgetTokens`).
    var pulseDailyTokens: Int {
        get { max(preferences.object(forKey: Self.pulseDailyTokensKey) as? Int ?? Pulse.defaultDailyTokens, Pulse.minimumDailyTokens) }
        set { preferences.set(max(newValue, Pulse.minimumDailyTokens), forKey: Self.pulseDailyTokensKey) }
    }

    /// The pulse runs: switched on, and "Orbs agem por conta própria" allows what it would do (it adds no permission of its own,
    /// so with that off there is nothing it may act on).
    var pulseIsOn: Bool { pulseEnabled && orbsActOnOwn }

    // MARK: State

    func loadPulseState() -> PulseState {
        preferences.data(forKey: Self.pulseStateKey).flatMap { try? JSONDecoder().decode(PulseState.self, from: $0) } ?? PulseState()
    }

    func savePulseState() {
        if let data = try? JSONEncoder().encode(pulseState) { preferences.set(data, forKey: Self.pulseStateKey) }
    }

    /// Tokens the pulse's work has spent today (for Ajustes).
    func pulseTokensToday(now: Date = .now) -> Int {
        pulseState.day == PulseState.dayKey(now) ? pulseState.tokensToday : 0
    }

    // MARK: The pass

    /// Called by the scheduler after the routines (so it keeps their wake-from-sleep hold). One pass at a time.
    func runPulseIfDue(now: Date = .now) {
        syncActivities() // the timer holds the app awake while the pulse is on (Orbs added or deleted change that)
        guard pulseTask == nil, pulseIsOn, bots.count > 1, !isResetting else { return }
        pulseTask = Task { [weak self] in
            await self?.pulseTick(now: now)
            self?.pulseTask = nil
        }
    }

    /// One pass: when the interval is up and the day's budget is not spent, looks at the Orbs in turn, skips the ones whose
    /// fingerprint did not change (no model, no token) and starts a pulse on the first free one that changed.
    func pulseTick(now: Date = .now) async {
        guard pulseIsOn, bots.count > 1, !isResetting else { return }
        pulseState.roll(to: now)
        defer { savePulseState() }
        guard let last = pulseState.lastPulse else { pulseState.lastPulse = now; return }
        if last > now { pulseState.lastPulse = now; return } // the clock went back: the interval counts from here
        guard now.timeIntervalSince(last) >= Double(pulseMinutes) * 60, pulseState.tokensToday < pulseDailyTokens else { return }

        var waiting = false // an Orb that changed but was busy: the pass is tried again at the next tick
        for botID in pulseOrder() {
            guard !isResetting, pulseIsOn, bot(botID) != nil else { continue }
            guard isFreeForPulse(botID) else { waiting = true; continue }
            let print = await pulseFingerprint(of: botID)
            pulseState.lastOrb = botID
            if pulseState.fingerprints[botID.uuidString] == print {
                pulseState.skipped += 1
                continue
            }
            switch await beginPulse(botID, now: now) {
            case .started, .unusable: // no usable model: the window is spent too, or the pass would repeat every 30 s
                pulseState.lastPulse = now
                pulseState.lastRunByOrb[botID.uuidString] = now
                return
            case .busy:
                waiting = true
            }
        }
        if !waiting { pulseState.lastPulse = now }
    }

    /// The Orbs in the order of turns: the one after the last examined first.
    private func pulseOrder() -> [UUID] {
        let ids = botIDs
        guard let last = pulseState.lastOrb, let index = ids.firstIndex(of: last) else { return ids }
        return Array(ids[(index + 1)...] + ids[...index])
    }

    /// Nothing holds the Orb or waits for it: a pulse never takes the place of a message, a routine or another Orb's request.
    private func isFreeForPulse(_ botID: UUID) -> Bool {
        guard canTakeSideWork(botID), sessions[botID]?.parkedChat == nil, !isWorking(botID),
              delegation.queues[botID]?.isEmpty ?? true, delegation.inbox[botID]?.isEmpty ?? true else { return false }
        return !queuedRoutines.contains { id in routines.first { $0.id == id }?.botID == botID }
    }

    // MARK: Fingerprint

    /// What the Orb could see now, as a short hash: how many Orbs and groups there are, its groups and who is in them, and the
    /// files of its conversations, its groups' threads and its memory (which carry its routines' runs and the requests it
    /// closed). Cheap: a few `stat` calls, off the main thread.
    func pulseFingerprint(of botID: UUID) async -> String {
        let mine = groups(containing: botID)
        let team = ["orbs=\(bots.count)", "groups=\(groups.count)"]
            + mine.map { "\($0.id.uuidString):\($0.name):\($0.orchestratorID.uuidString):" + $0.memberIDs.map(\.uuidString).joined(separator: ",") }
        let sources = store.pulseSources(of: botID, groups: mine.map(\.id))
        let memory = self.memory.bank(for: botID).directory
        let store = self.store
        let disk = await Task.detached {
            store.flush() // what was just saved is on disk before it is read
            return Pulse.disk(files: sources.files, folder: sources.folder, memory: memory)
        }.value
        return Pulse.hash((team + [disk]).joined(separator: "\n"))
    }

    // MARK: A pulse run

    enum PulseStart { case started, busy, unusable }

    /// Parks the Orb's chat, runs the pulse prompt in the Orb's own pulse conversation and returns once it has begun.
    func beginPulse(_ botID: UUID, now: Date = .now) async -> PulseStart {
        guard canTakeSideWork(botID), bot(botID) != nil else { return .busy }
        let session = session(botID)
        pulseStarting.insert(botID) // the Orb is held while its files are read
        if session.isUnloaded { await loadedConversation(botID) }
        let read = await store.readSideConversationAsync(prefix: Store.pulsoPrefix, id: botID, for: botID)
        pulseStarting.remove(botID)
        guard !isResetting, pulseIsOn, bot(botID) != nil, canTakeSideWork(botID), session.parkedChat == nil else { return .busy }
        ensureLoaded(botID)
        addNotice(Self.labeled(read.notice, for: bot(botID)))
        let started = Date.now
        let own = (read.value?.closingInterruptedTurn(notice: BotSession.quitSideNotice) ?? Conversation()).startingRoutineRun(at: started)
        let runID = UUID()
        session.startRoutineRun(runID, conversation: own, at: started, kind: .pulse)
        pulseRuns[botID] = PulseRun(id: runID, startedAt: started)
        guard send(Pulse.prompt, to: botID) else {
            pulseRuns[botID] = nil
            session.endSideRun()
            session.scheduleSave(delay: 0)
            return .unusable
        }
        workJournal.pulseBegan(bot: botID, at: started)
        setStatus("Pulso: pensando", of: botID)
        return .started
    }

    /// The pulse turn ended (`BotSession.finishTurn`): its conversation is kept, the chat comes back, and when the pulse did
    /// something the chat and the home page say so. Whatever it asked of other Orbs goes on, and its answers wake the chat.
    func finishPulse(_ botID: UUID, runID: UUID, succeeded: Bool, userStopped: Bool, reply: String?) {
        let session = session(botID)
        let own = session.conversation ?? Conversation()
        store.saveSideConversation(own, prefix: Store.pulsoPrefix, id: botID, for: botID)
        session.unparkChat()
        if session.hasUnsavedStretch() { session.scheduleMemorySave() } // the run cancelled the chat's pending save
        workJournal.dropPulse(bot: botID)
        let run = pulseRuns.removeValue(forKey: botID)
        guard let bot = bot(botID), !isResetting else { return }

        // This run's items: after the marker that opens it.
        let start = own.items.lastIndex { if case .notice(let text) = $0.kind { text.hasPrefix(Conversation.routineRunMarker) } else { false } } ?? 0
        let usedTools = own.items[start...].contains { if case .tool = $0.kind { true } else { false } }
        let said = Pulse.isNothing(reply) ? "" : MemoryText.clip(MemoryText.flatten(reply ?? ""), 200)
        if usedTools || !said.isEmpty {
            let summary = said.isEmpty ? "usou ferramentas" : said
            let tokens = run?.tokens ?? 0
            let outcome: OrbEvent.Outcome = succeeded || userStopped ? .finished : .failed
            let appended = appendToChat(.event(OrbEvent(kind: .pulseRan, actor: OrbRef(bot), detail: String(tokens), note: summary,
                                                        outcome: outcome, runID: runID)), of: botID)
            pulseState.lastSummary = summary
            pulseState.lastActed = .now
            if let appended {
                recordInicioPulse(bot: botID, chat: appended.chat, item: appended.item, summary: "\(bot.name): \(summary)",
                                  outcome: outcome == .failed ? .failed : .completed)
            }
        }
        savePulseState()
        // What the Orb could see when it ended (its own effects included) is the new baseline: only what changes from outside,
        // or the answers of the Orbs it asked, make the next pulse worth its tokens. A failed run keeps the old one and tries again.
        guard succeeded || userStopped else { return }
        Task { @MainActor [weak self] in
            guard let self, self.bot(botID) != nil else { return }
            self.sessions[botID]?.saveNow() // the line the pulse left in the chat is written before the baseline is read
            let print = await self.pulseFingerprint(of: botID)
            self.pulseState.fingerprints[botID.uuidString] = print
            self.savePulseState()
        }
    }

    // MARK: The budget

    static let pulseCappedNotice = "O pulso parou: o teto diário de tokens foi atingido."

    /// Called by `recordUsage` for every use of a model: the pulse's own turn, and any turn of a chain the pulse started, add to
    /// the day's count. Over the budget, the chain stops (and the pulse turn, if it still runs).
    func pulseCharge(_ totals: UsageTotals, botID: UUID, source: UsageSource) {
        let tokens = totals.budgetTokens
        guard tokens > 0 else { return }
        let session = sessions[botID]
        let chain = session?.chain?.chainID ?? session?.usageChain
        let inPulseChain = chain.flatMap { delegation.chainStates[$0]?.origin.isPulse } ?? false
        guard source == .pulse || inPulseChain else { return }
        pulseState.roll(to: pulseNow())
        pulseState.tokensToday += tokens
        if source == .pulse { pulseRuns[botID]?.tokens += tokens }
        savePulseState()
        if pulseState.tokensToday >= pulseDailyTokens { Task { @MainActor [weak self] in self?.stopPulseWork() } }
    }

    /// The day's budget is spent: every chain the pulse started stops, and so does a pulse turn still running. Each Orb whose
    /// work was cut gets one line in its chat.
    func stopPulseWork() {
        guard pulseState.tokensToday >= pulseDailyTokens else { return }
        var told: Set<UUID> = []
        for (id, chain) in delegation.chainStates where chain.origin.isPulse && !chain.cancelled {
            delegation.cancelChain(id, by: .budget)
            told.insert(chain.originBot)
        }
        for (botID, session) in sessions where session.sideKind == .pulse && session.turnTask != nil {
            session.stop(startsQueuedRoutines: true, notice: Self.pulseCappedNotice)
            told.insert(botID)
        }
        for botID in told where bot(botID) != nil {
            appendToChat(.event(OrbEvent(kind: .pulseStopped, actor: bot(botID).map(OrbRef.init), detail: String(pulseDailyTokens))), of: botID)
        }
    }
}

extension DelegationHub.ChainState.Origin {
    var isPulse: Bool { if case .pulse = self { true } else { false } }
}
