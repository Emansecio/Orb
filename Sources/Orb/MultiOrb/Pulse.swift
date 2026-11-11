import Foundation

// The pulse: from time to time an Orb wakes by itself when there is concrete work waiting for it (a plan dropped half way, a
// routine that failed, a request that failed, a group turn that failed, a notice nobody read) and acts if coordinating would help the person (ask a
// teammate, create Orbs or groups, move members). Nothing else wakes an Orb without a message or a routine. Three things keep
// it cheap: the demand is found without a model (a pure function over state already in memory, so an Orb with none is skipped
// for free and a demand is handed over once), one Orb per interval in turn, and a daily budget of tokens that counts the pulse
// turn and everything the chain it starts spends (requests to other Orbs, group turns). When the budget runs out the pulse
// waits for the next day and the chain that was working is stopped.

/// What the pulse remembers between launches (one small value in the preferences). Tolerant: a missing or unreadable field
/// reads as its default, and the whole value as a fresh one.
struct PulseState: Codable, Equatable, Sendable {
    /// When the interval last started over: a pulse began, or a whole pass found nothing to do. Nil: never (the first window
    /// opens when the pulse first looks, so a new install does not spend tokens at once).
    var lastPulse: Date?
    /// The Orb examined last: the next pass starts after it (turn-taking, robust to Orbs added and deleted).
    var lastOrb: UUID?
    /// By Orb id: the keys of the demands already handed to a pulse that ended (oldest first), so the same work never wakes the
    /// Orb twice. Only keys whose work is still there are kept (`AppModel.newPulseDemands`), `Pulse.deliveredLimit` at most.
    /// Older versions kept a `fingerprints` map here; it is ignored when read.
    var delivered: [String: [String]] = [:]
    /// By Orb id: the open plans of its conversations (`AppModel.notePlan`), newest first. Kept here, not read from the
    /// conversations: one off screen or not read since launch is not in memory, and its plan must still wake the Orb.
    var plans: [String: [PulsePlan]] = [:]
    /// By Orb id: notices (`tell`) its chats were not handed yet (`AppModel.notePulseNotice`), oldest first.
    var notices: [String: [PulseNotice]] = [:]
    /// By "Orb id|demand key": pulses that failed on that demand. A demand is handed over for good after `Pulse.failureLimit`.
    var failures: [String: Int] = [:]
    /// By Orb id: when its last pulse began.
    var lastRunByOrb: [String: Date] = [:]
    /// What the last pulse that did something said, and when.
    var lastSummary: String?
    var lastActed: Date?
    /// The first demand of the pulse that last did something.
    var lastReason: String?
    /// Passes over an Orb that were skipped because it had no new demand (they cost no token).
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
        delivered = (try? c.decodeIfPresent([String: [String]].self, forKey: .delivered)) ?? [:]
        plans = (try? c.decodeIfPresent([String: [PulsePlan]].self, forKey: .plans)) ?? [:]
        notices = (try? c.decodeIfPresent([String: [PulseNotice]].self, forKey: .notices)) ?? [:]
        failures = (try? c.decodeIfPresent([String: Int].self, forKey: .failures)) ?? [:]
        lastRunByOrb = (try? c.decodeIfPresent([String: Date].self, forKey: .lastRunByOrb)) ?? [:]
        lastSummary = (try? c.decodeIfPresent(String.self, forKey: .lastSummary)) ?? nil
        lastActed = (try? c.decodeIfPresent(Date.self, forKey: .lastActed)) ?? nil
        lastReason = (try? c.decodeIfPresent(String.self, forKey: .lastReason)) ?? nil
        skipped = (try? c.decodeIfPresent(Int.self, forKey: .skipped)) ?? 0
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        tokensToday = max(0, (try? c.decodeIfPresent(Int.self, forKey: .tokensToday)) ?? 0)
    }
}

/// The open plan of one of an Orb's conversations, as the pulse keeps it (`PulseState.plans`).
struct PulsePlan: Codable, Equatable, Sendable {
    var chat: UUID
    var goal: String
    var goalHash: String
    var done: Int
    var total: Int
    /// Steps still to do (pending or in progress; a blocked one waits for the person).
    var open: Int
    var next: String
    var updatedAt: Date
}

extension PulsePlan {
    /// nil when nothing is left for the Orb to do: no open step, or the task was paused to wait for the person.
    init?(_ plan: TaskPlan?, chat: UUID, paused: Bool) {
        guard let plan, !paused, let next = plan.openSteps.first else { return nil }
        self.init(chat: chat, goal: Pulse.clip(plan.goal, 80), goalHash: Pulse.hash(plan.goal), done: plan.doneCount,
                  total: plan.steps.count, open: plan.openSteps.count, next: Pulse.clip(plan.steps[next - 1].text, 80),
                  updatedAt: plan.updatedAt)
    }
}

/// A notice (`tell`) left in one of an Orb's chats, until that chat's turn is handed it (`PulseState.notices`).
struct PulseNotice: Codable, Equatable, Sendable {
    /// The envelope's id.
    var id: UUID
    var chat: UUID
    var chain: UUID
    var from: String
    var text: String
    var at: Date
}

/// A pulse run in progress, in memory only.
struct PulseRun {
    var id: UUID
    var startedAt: Date
    /// Tokens the run spent, its chain's turns included (a teammate's, a group's): the cost its line shows.
    var tokens = 0
    /// The first demand the run was woken for.
    var reason = ""
    /// The keys of the demands it was handed: marked delivered when it ends (`finishPulse`), not when it starts, so a run
    /// that fails or a quit in the middle leaves them for the next pulse.
    var keys: [String] = []
    /// In the chat (`beginPulseInChat`): how many items and messages it had before the run, to take the run out again when
    /// it found nothing to do.
    var chatMark: (items: Int, messages: Int, handedAt: Date?)?
}

/// Work waiting for an Orb, found without a model. `key` says which work and in what state (it changes when the work does), so
/// a demand is handed to one pulse only; `line` is what the model reads.
struct PulseDemand: Sendable, Equatable {
    var key: String
    var line: String
    /// The conversation the work belongs to (a plan's).
    var chat: UUID?
}

enum Pulse {
    /// How the prompt of a run opens: the app's words, not the user's.
    static let marker = "[Pulse] "
    /// What the model is sent: the demands (short, in English: it goes in every pulse).
    /// `inChat`: the run is in the conversation of the plan (the first demand), whose history it has.
    static func prompt(for demands: [PulseDemand], inChat: Bool = false) -> String {
        marker + "Nobody asked for this run" + (inChat ? ", and nobody reads it while it works" : "") + ". Open work you could move forward:\n"
            + demands.map { "- " + $0.line }.joined(separator: "\n")
            + (inChat ? "\nThis is the conversation of the plan: resume its next step from where it stopped (check what is already done)."
                + " Do not ask the user anything; if a step needs them, leave it blocked and say why." : "")
            + "\nAct only on these: resume, ask a teammate, create an Orb or group, or adjust members (a new Orb only when no "
            + "teammate can do it). If none needs anything now, reply only NOTHING."
    }

    static let defaultMinutes = 60
    static let minimumDailyTokens = 10_000
    static let defaultDailyTokens = 300_000
    /// Demands handed to one pulse, and keys remembered per Orb.
    static let demandsPerPulse = 5, deliveredLimit = 200, lineLimit = 160
    /// Plans and notices kept per Orb, and failed pulses after which a demand is handed over anyway.
    static let plansPerOrb = 3, noticesPerOrb = 10, failureLimit = 2
    /// A plan must have been left alone this long to count as dropped (the person may be about to answer), a routine run
    /// this recent to count as news, and a notice unread this long to wake the Orb (its chat may be about to read it).
    static let planIdle: TimeInterval = 10 * 60, runFreshness: TimeInterval = 24 * 3_600, noticeIdle: TimeInterval = 30 * 60

    /// The reply that means "nothing to do" (any case, with or without a full stop or markdown around it).
    static func isNothing(_ reply: String?) -> Bool {
        guard let reply else { return true }
        let letters = reply.filter(\.isLetter).uppercased()
        return letters.isEmpty || letters == "NOTHING"
    }

    /// A stable 64-bit FNV-1a, in hex: `Hasher` changes between launches, and the keys are kept.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }

    static func clip(_ text: String, _ limit: Int) -> String { MemoryText.clip(MemoryText.flatten(text), limit) }

    /// What a routine's run calls for: nil when nothing (it went well, or the person stopped it).
    private static func trouble(_ run: RoutineRun) -> (kind: String, text: String)? {
        if !run.succeeded, !run.wasStopped { return ("failed", run.summary) }
        if let check = run.check, check.status == .attention { return ("attention", check.note) }
        return nil
    }

    /// The work waiting for an Orb, from state already in memory (pure: no disk, no model).
    /// - `plans`: the open plans of the Orb's conversations (`PulsePlan`). Dropped = untouched for `planIdle`. The key has the
    ///   plan's last change, so a plan touched again and dropped again is new work.
    /// - `notices`: notices its chats were not handed yet; one waiting `noticeIdle` is work.
    /// - `routines`: any; only this Orb's enabled ones whose newest run failed (a stop is not a failure) or asked for attention.
    ///   The same trouble run after run is one demand: the key is the first run of the streak and the trouble's words
    ///   (numbers left out, which change from run to run).
    /// - `requests`: any; this Orb's requests that failed outside a group, and failed turns of groups it orchestrates. Chains the
    ///   pulse itself started are left out (the Orb was told inside the chain, and pulsing on its own failures would loop).
    static func demands(for botID: UUID, plans: [PulsePlan], notices: [PulseNotice] = [], routines: [Routine],
                        requests: [DelegationRequest], groups: [OrbGroup], pulseChains: Set<UUID>, now: Date) -> [PulseDemand] {
        var found: [PulseDemand] = []
        for plan in plans where now.timeIntervalSince(plan.updatedAt) >= planIdle && plan.open > 0 {
            let changed = Int(plan.updatedAt.timeIntervalSince1970)
            found.append(PulseDemand(key: "plan:\(plan.chat.uuidString):\(plan.goalHash):\(plan.open):\(changed)",
                                     line: "Unfinished plan \"\(plan.goal)\": \(plan.done)/\(plan.total) done, next \"\(plan.next)\".",
                                     chat: plan.chat))
        }
        for routine in routines where routine.botID == botID && routine.isEnabled {
            guard let run = routine.runs.first, now.timeIntervalSince(run.date) <= runFreshness, let trouble = trouble(run) else { continue }
            let streak = routine.runs.prefix { Self.trouble($0)?.kind == trouble.kind }
            // A streak as long as the runs kept has lost its start (`Routine.keptRuns`): a fixed mark, or every new run
            // would drop the oldest and make the same trouble new work again.
            let first = streak.count == routine.runs.count ? "kept" : (streak.last?.id ?? run.id).uuidString
            let words = hash(trouble.text.filter { !$0.isNumber })
            let why = trouble.kind == "failed" ? "failed: " + clip(trouble.text, 100)
                : "needs attention" + (trouble.text.isEmpty ? "" : ": " + clip(trouble.text, 100))
            found.append(PulseDemand(key: "routine:\(routine.id.uuidString):\(first):\(words)",
                                     line: "Routine \"\(clip(routine.name, 40))\" \(why)."))
        }
        for notice in notices where now.timeIntervalSince(notice.at) >= noticeIdle {
            found.append(PulseDemand(key: "notice:\(notice.id.uuidString)",
                                     line: "Unread notice from \(clip(notice.from, 40)): \"\(clip(notice.text, 100))\"."))
        }
        // The envelope says it was the pulse's (it outlives the chain's state); the set covers envelopes from older versions.
        let failed = requests.filter {
            $0.state == .failed && $0.envelope.kind != .reply && $0.envelope.pulseRun == nil && !pulseChains.contains($0.envelope.chainID)
        }
            .sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        for request in failed {
            let envelope = request.envelope
            if let groupID = envelope.groupID {
                guard let group = groups.first(where: { $0.id == groupID }), group.orchestratorID == botID else { continue }
                found.append(PulseDemand(key: "group:\(envelope.id.uuidString)",
                                         line: "In group \"\(clip(group.name, 40))\" the turn of \(envelope.to.name) failed: \"\(clip(envelope.text, 80))\"."))
            } else if envelope.from.id == botID {
                found.append(PulseDemand(key: "request:\(envelope.id.uuidString)",
                                         line: "Your request to \(envelope.to.name) failed: \"\(clip(envelope.text, 80))\"."))
            }
        }
        return found
    }
}

extension AppModel {
    // MARK: Settings

    static let pulseEnabledKey = "pulseEnabled", pulseMinutesKey = "pulseMinutes", pulseDailyTokensKey = "pulseDailyTokens"
    static let pulseStateKey = "pulseState"

    /// Ajustes → Orbs → "Pulso dos Orbs". On unless switched off.
    var pulseEnabled: Bool {
        get { preferences.object(forKey: Self.pulseEnabledKey) as? Bool ?? true }
        set {
            preferences.set(newValue, forKey: Self.pulseEnabledKey)
            syncActivities()
            if !newValue { stopPulseWork(switchedOff: true) } // what the pulse started does not go on after it was switched off
        }
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

    /// The day's budget is spent: work the pulse pays for asks for nothing more (`DelegationRefusal.pulseBudget`).
    var pulseBudgetSpent: Bool { pulseTokensToday(now: pulseNow()) >= pulseDailyTokens }

    // MARK: The lineage

    /// The pulse run the Orb's current turn is paid by, if any: its own pulse run; a request or a group's turn of a chain the
    /// pulse started; the chat an answer of such a chain woke; a request whose envelope says so (its chain's state may be
    /// forgotten). The one place that decides it: the budget (`pulseCharge`), the chains (`DelegationHub.newChain`,
    /// `queueGroupTurn`) and the stop (`stopPulseWork`) all ask here, so a new way for work to go on cannot leave the budget.
    func pulseLineage(of botID: UUID) -> UUID? {
        guard let session = sessions[botID] else { return nil }
        if session.sideKind == .pulse, let run = session.routineID { return run }
        if let run = session.pulseInChat { return run }
        if let chain = session.chain?.chainID ?? session.usageChain, let run = delegation.pulseRun(ofChain: chain) { return run }
        if let serving = session.servingRequest, let run = delegation.requests[serving]?.envelope.pulseRun { return run }
        return nil
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

    /// One pass: when the interval is up and the day's budget is not spent, looks at the Orbs in turn, skips the ones with no new
    /// demand (no model, no token) and starts a pulse on the first free one that has some, telling it which.
    func pulseTick(now: Date = .now) async {
        guard pulseIsOn, bots.count > 1, !isResetting else { return }
        pulseState.roll(to: now)
        defer { savePulseState() }
        guard let last = pulseState.lastPulse else { pulseState.lastPulse = now; return }
        if last > now { pulseState.lastPulse = now; return } // the clock went back: the interval counts from here
        guard now.timeIntervalSince(last) >= Double(pulseMinutes) * 60, pulseState.tokensToday < pulseDailyTokens else { return }

        var waiting = false // an Orb busy (it may have a demand: it is not looked at): the pass is tried again at the next tick
        for botID in pulseOrder() {
            guard !isResetting, pulseIsOn, bot(botID) != nil else { continue }
            guard isFreeForPulse(botID) else { waiting = true; continue }
            let demands = Array(newPulseDemands(for: botID, now: now).prefix(Pulse.demandsPerPulse))
            pulseState.lastOrb = botID
            if demands.isEmpty {
                pulseState.skipped += 1
                continue
            }
            switch await beginPulse(botID, demands: demands, now: now) {
            // Started: the demands are marked delivered when the run ends (`finishPulse`). No usable model: the window is
            // spent too, or the pass would repeat every 30 s.
            case .started, .unusable:
                pulseState.lastPulse = now
                pulseState.lastRunByOrb[botID.uuidString] = now
                return
            case .busy:
                waiting = true
            }
        }
        if !waiting { pulseState.lastPulse = now }
    }

    /// The Orb's demands that no earlier pulse was handed. The keys remembered are cut down to the work still there: a key
    /// is forgotten only once its work is gone, so no number of demands makes an old one wake the Orb again.
    func newPulseDemands(for botID: UUID, now: Date) -> [PulseDemand] {
        let id = botID.uuidString
        let chains = Set(delegation.chainStates.filter { $0.value.origin.isPulse }.keys)
        let all = Pulse.demands(for: botID, plans: pulsePlans(of: botID), notices: pulseState.notices[id] ?? [], routines: routines,
                                requests: Array(delegation.requests.values), groups: groups, pulseChains: chains, now: now)
        let current = Set(all.map(\.key))
        if let seen = pulseState.delivered[id] {
            let kept = Array(seen.filter(current.contains).suffix(Pulse.deliveredLimit))
            pulseState.delivered[id] = kept.isEmpty ? nil : kept
        }
        let prefix = id + "|"
        pulseState.failures = pulseState.failures.filter { !$0.key.hasPrefix(prefix) || current.contains(String($0.key.dropFirst(prefix.count))) }
        let seen = Set(pulseState.delivered[id] ?? [])
        return all.filter { !seen.contains($0.key) }
    }

    /// The Orb's open plans: the ones kept, with the conversation the turn machinery has in memory read as it is now.
    private func pulsePlans(of botID: UUID) -> [PulsePlan] {
        var plans = (pulseState.plans[botID.uuidString] ?? []).filter { isChat($0.chat, of: botID) } // a conversation gone wakes nothing
        if let session = sessions[botID], let chat = session.conversationChat, let conversation = session.conversation {
            plans.removeAll { $0.chat == chat }
            if let live = PulsePlan(conversation.activePlan, chat: chat, paused: conversation.taskPaused == true) { plans.insert(live, at: 0) }
        }
        return plans
    }

    /// The pulse ended: on success (or the person's stop) its demands are handed over; on failure each counts one more, and is
    /// handed over after `Pulse.failureLimit` (a demand the model always fails on must not spend the budget every interval).
    private func settleDemands(_ keys: [String], of botID: UUID, succeeded: Bool) {
        let id = botID.uuidString
        var done: [String] = []
        for key in keys {
            let counted = id + "|" + key
            if succeeded {
                done.append(key)
                pulseState.failures[counted] = nil
            } else {
                let failures = (pulseState.failures[counted] ?? 0) + 1
                if failures >= Pulse.failureLimit { done.append(key); pulseState.failures[counted] = nil } else { pulseState.failures[counted] = failures }
            }
        }
        guard !done.isEmpty else { return }
        pulseState.delivered[id] = Array(((pulseState.delivered[id] ?? []) + done).suffix(Pulse.deliveredLimit))
    }

    // MARK: What the pulse keeps of the Orb's conversations

    /// A conversation of the Orb was written (`BotSession.write`): its open plan is kept for the pulse, the newest
    /// `Pulse.plansPerOrb`. Saved only when it changed.
    func notePlan(_ conversation: Conversation, chat: UUID, of botID: UUID) {
        let id = botID.uuidString
        let before = pulseState.plans[id] ?? []
        var plans = before.filter { $0.chat != chat }
        if let plan = PulsePlan(conversation.activePlan, chat: chat, paused: conversation.taskPaused == true) { plans.append(plan) }
        plans = Array(plans.sorted { $0.updatedAt > $1.updatedAt }.prefix(Pulse.plansPerOrb))
        guard plans != before else { return }
        pulseState.plans[id] = plans.isEmpty ? nil : plans
        savePulseState()
    }

    /// A notice landed in a chat of the Orb (`DelegationHub.leaveNotice`). One the pulse's own work sent is not kept: a pulse
    /// woken by another pulse's notice would chain them.
    func notePulseNotice(_ envelope: OrbEnvelope, chat: UUID) {
        guard envelope.kind == .tell, envelope.groupID == nil, envelope.pulseRun == nil else { return }
        let id = envelope.to.id.uuidString
        let notice = PulseNotice(id: envelope.id, chat: chat, chain: envelope.chainID, from: envelope.from.name,
                                 text: Pulse.clip(envelope.text, 100), at: pulseNow())
        pulseState.notices[id] = Array(((pulseState.notices[id] ?? []) + [notice]).suffix(Pulse.noticesPerOrb))
        savePulseState()
    }

    /// Notices that no longer wait: the chat's turn was handed them (`chat`, those up to `upTo`), their chain was stopped
    /// (`chain` too), or their conversation is gone.
    func forgetPulseNotices(of botID: UUID, chat: UUID? = nil, chain: UUID? = nil, upTo: Date? = nil) {
        let id = botID.uuidString
        guard let notices = pulseState.notices[id] else { return }
        let left = notices.filter { notice in
            if let chat, notice.chat != chat { return true }
            if let chain, notice.chain != chain { return true }
            if let upTo, notice.at > upTo { return true } // landed after the turn's cut: the next turn is handed it
            return false
        }
        guard left != notices else { return }
        pulseState.notices[id] = left.isEmpty ? nil : left
        savePulseState()
    }

    /// A conversation of the Orb was deleted (`chat`), or the Orb itself (nil): nothing of it may wake a pulse.
    func forgetPulse(of botID: UUID, chat: UUID? = nil) {
        let id = botID.uuidString
        if let chat {
            pulseState.plans[id]?.removeAll { $0.chat == chat }
            if pulseState.plans[id]?.isEmpty == true { pulseState.plans[id] = nil }
            forgetPulseNotices(of: botID, chat: chat)
        } else {
            pulseState.delivered[id] = nil
            pulseState.plans[id] = nil
            pulseState.notices[id] = nil
            pulseState.lastRunByOrb[id] = nil
            pulseState.failures = pulseState.failures.filter { !$0.key.hasPrefix(id + "|") }
        }
        savePulseState()
    }

    /// The Orbs in the order of turns: the one after the last examined first.
    private func pulseOrder() -> [UUID] {
        let ids = botIDs
        guard let last = pulseState.lastOrb, let index = ids.firstIndex(of: last) else { return ids }
        return Array(ids[(index + 1)...] + ids[...index])
    }

    /// Nothing holds the Orb or waits for it: a pulse never takes the place of a message, a routine or another Orb's request.
    private func isFreeForPulse(_ botID: UUID) -> Bool {
        guard canTakeSideWork(botID), sessions[botID]?.parkedChat == nil, !isWorking(botID), !delegation.hasWaitingPulse(of: botID),
              !workJournal.awaitsChatResume(bot: botID), // the person's cut task goes on first, as its own turn
              delegation.queues[botID]?.isEmpty ?? true, delegation.inbox[botID]?.isEmpty ?? true else { return false }
        return !queuedRoutines.contains { id in routines.first { $0.id == id }?.botID == botID }
    }

    // MARK: A pulse run

    enum PulseStart { case started, busy, unusable }

    /// Parks the Orb's chat, runs the pulse prompt in the Orb's own pulse conversation and returns once it has begun. With a
    /// dropped plan among the demands, the pulse runs in that plan's conversation instead (`beginPulseInChat`).
    func beginPulse(_ botID: UUID, demands: [PulseDemand], now: Date = .now) async -> PulseStart {
        guard canTakeSideWork(botID), bot(botID) != nil else { return .busy }
        if let plan = demands.first(where: { $0.chat != nil }), let chat = plan.chat, isChat(chat, of: botID) {
            let ordered = [plan] + demands.filter { $0.key != plan.key }
            return await beginPulseInChat(botID, chat: chat, demands: ordered)
        }
        let session = session(botID)
        pulseStarting.insert(botID) // the Orb is held while its files are read
        if session.isUnloaded { await loadedConversation(botID) }
        let read = await store.readSideConversationAsync(prefix: Store.pulsoPrefix, id: botID, for: botID)
        pulseStarting.remove(botID)
        guard !isResetting, pulseIsOn, bot(botID) != nil, canTakeSideWork(botID), session.parkedChat == nil else {
            pumpAfterPulse(botID)
            return .busy
        }
        ensureLoaded(botID)
        addNotice(Self.labeled(read.notice, for: bot(botID)))
        let started = Date.now
        let own = (read.value?.closingInterruptedTurn(notice: BotSession.quitSideNotice) ?? Conversation())
            .forgettingContext().startingRoutineRun(at: started) // a pulse starts from scratch every time
        let runID = UUID()
        session.startRoutineRun(runID, conversation: own, at: started, kind: .pulse)
        pulseRuns[botID] = PulseRun(id: runID, startedAt: started, reason: demands.first?.line ?? "", keys: demands.map(\.key))
        guard send(Pulse.prompt(for: demands), to: botID) else {
            pulseRuns[botID] = nil
            session.endSideRun()
            session.scheduleSave(delay: 0)
            pumpAfterPulse(botID)
            return .unusable
        }
        workJournal.pulseBegan(bot: botID, at: started)
        setStatus("Pulso: pensando", of: botID)
        return .started
    }

    /// The pulse in the conversation of a dropped plan: the turn has its history, the plan and what happened since (`SinceLastTurn`),
    /// as the person's next message would. It is a turn nobody watches (no questions, no access cards) and paid by the pulse.
    private func beginPulseInChat(_ botID: UUID, chat: UUID, demands: [PulseDemand]) async -> PulseStart {
        let session = session(botID)
        pulseStarting.insert(botID) // the Orb is held while its conversation is read
        let ready = await prepareTurn(in: chat, of: botID)
        // The chat on show may be unloaded (an idle Orb not selected): the run's mark and the plan's goal are read from it.
        if ready, session.isUnloaded { await loadedConversation(botID) }
        pulseStarting.remove(botID)
        guard ready, !isResetting, pulseIsOn, let bot = bot(botID), session.turnTask == nil, session.routineID == nil,
              session.conversationChat == chat, session.conversation != nil else {
            if ready, session.turnTask == nil { session.endWorkElsewhere() }
            pumpAfterPulse(botID)
            return .busy
        }
        let runID = UUID(), started = Date.now
        let goal = session.conversation?.activePlan.map { Pulse.clip($0.goal, 80) } ?? ""
        let mark = (items: session.conversation?.items.count ?? 0, messages: session.conversation?.messages.count ?? 0,
                    handedAt: session.conversation?.contextHandedAt)
        session.pulseInChat = runID
        pulseRuns[botID] = PulseRun(id: runID, startedAt: started, reason: demands.first?.line ?? "", keys: demands.map(\.key),
                                    chatMark: mark)
        // No dot yet: a run that finds nothing to do takes the line back; one that acts leaves its `pulseRan`, which marks it.
        let line = appendToChat(.event(OrbEvent(kind: .pulseResumed, actor: OrbRef(bot), detail: goal, runID: runID)), of: botID, in: chat,
                                marksUnread: false)
        guard send(Pulse.prompt(for: demands, inChat: true), to: botID, origin: .pulse) else {
            session.pulseInChat = nil
            pulseRuns[botID] = nil
            // Nothing ran: the line saying it resumed goes, or every interval would add one to the person's chat.
            if let line {
                let item = line.item
                session.changeChat(line.chat) { $0.items.removeAll { $0.id == item } }
            }
            if session.workingChatID != nil { session.endWorkElsewhere() }
            pumpAfterPulse(botID)
            return .unusable
        }
        workJournal.pulseBegan(bot: botID, at: started)
        setStatus("Pulso: retomando o plano", of: botID)
        return .started
    }

    /// The pulse held the Orb while it read (`pulseStarting`) and then did not start: what queued for the Orb meanwhile (a
    /// request, an answer, a routine) found it held and waits for this, as after a routine that did not start.
    private func pumpAfterPulse(_ botID: UUID) {
        if sessions[botID]?.turnTask == nil { startNextQueuedWork(for: botID) }
    }

    /// The pulse turn ended (`BotSession.finishTurn`): its conversation is kept, the chat comes back, and when the pulse did
    /// something the chat and the home page say so. Whatever it asked of other Orbs goes on, and its answers wake the chat.
    /// True when the run left something to read (its line in the chat) or still waits for answers: the Orb's unread counts it.
    @discardableResult
    func finishPulse(_ botID: UUID, runID: UUID, succeeded: Bool, userStopped: Bool, reply: String?, inChat chat: UUID? = nil) -> Bool {
        let session = session(botID)
        let own = session.conversation ?? Conversation()
        if chat == nil {
            store.saveSideConversation(own, prefix: Store.pulsoPrefix, id: botID, for: botID)
            session.unparkChat()
            if session.hasUnsavedStretch() { session.scheduleMemorySave() } // the run cancelled the chat's pending save
        }
        workJournal.dropPulse(bot: botID)
        let run = pulseRuns.removeValue(forKey: botID)
        guard let bot = bot(botID), !isResetting else { return false }
        let failed = !succeeded && !userStopped
        // The app closing stops the turn as a person's stop would: its demands are not done, and wake the next pulse.
        if !delegation.isShuttingDown { settleDemands(run?.keys ?? [], of: botID, succeeded: !failed) }
        // It asked other Orbs from its own conversation: the run waits for the answers there, and they resume it. (In the chat
        // they come back to the chat, as any answer to it does.)
        if chat == nil, !failed, !userStopped, var waiting = run {
            waiting.keys = []
            if delegation.holdPulse(waiting, of: botID, conversation: own) {
                savePulseState()
                return true
            }
        }

        // This run's items: after the marker (or, in the chat, the line) that opens it.
        let start = chat == nil
            ? own.items.lastIndex { if case .notice(let text) = $0.kind { text.hasPrefix(Conversation.routineRunMarker) } else { false } } ?? 0
            : own.items.lastIndex { if case .event(let event) = $0.kind { event.kind == .pulseResumed && event.runID == runID } else { false } } ?? 0
        let usedTools = own.items[start...].contains { if case .tool = $0.kind { true } else { false } }
        let said = Pulse.isNothing(reply) ? "" : MemoryText.clip(MemoryText.flatten(reply ?? ""), 200)
        // A failure always leaves its line: the person sees that the pulse tried and why it did not go.
        let leavesLine = usedTools || !said.isEmpty || failed
        if leavesLine {
            var thisRun = own
            thisRun.items = Array(own.items[start...]) // the reason of this run, not of an earlier one in the same file
            let summary = failed ? "não deu certo: " + MemoryText.clip(DelegationHub.reason(in: thisRun), 160)
                : said.isEmpty ? "usou ferramentas" : said
            recordPulseLine(bot, runID: runID, tokens: run?.tokens ?? 0, summary: summary, failed: failed, reason: run?.reason, in: chat)
        } else if chat != nil, let mark = run?.chatMark {
            // Nothing to do after all: the chat keeps no trace of the run (its line, the NOTHING), as the pulse's own
            // conversation would. Only what the run added at the end goes; a fold during the run leaves the messages.
            session.changeConversation { conversation in
                // Only the run's own lines go: anything else that landed meanwhile (what the person wrote, another Orb's
                // notice, an event) keeps the whole run, or it would be lost with it.
                guard conversation.items.count >= mark.items,
                      conversation.items[mark.items...].allSatisfy({ item in
                          switch item.kind {
                          case .bot, .tool: true
                          case .event(let event): event.kind == .pulseResumed && event.runID == runID
                          default: false
                          }
                      }) else { return }
                conversation.items.removeSubrange(mark.items...)
                if conversation.messages.count >= mark.messages, (conversation.summaryCoveredCount ?? 0) <= mark.messages {
                    conversation.messages.removeSubrange(mark.messages...)
                }
                // What happened since the last turn was handed to the run that is gone: the next turn is handed it again.
                conversation.contextHandedAt = mark.handedAt
            }
        }
        savePulseState()
        return leavesLine
    }

    /// A pulse that waited for answers that will not come ends here, failed, with `why` (its conversation keeps what it did).
    func closePulseWait(_ run: PulseRun, of botID: UUID, conversation: Conversation, why: String) {
        var own = conversation
        own.items.append(TranscriptItem(.notice(why)))
        store.saveSideConversation(own, prefix: Store.pulsoPrefix, id: botID, for: botID)
        guard let bot = bot(botID), !isResetting else { return }
        recordPulseLine(bot, runID: run.id, tokens: run.tokens, summary: "não deu certo: " + why, failed: true, reason: run.reason, in: nil)
        savePulseState()
    }

    /// The answers a waiting pulse asked for came (`DelegationHub.deliverInbox`): the run goes on in the pulse's conversation.
    /// False when it cannot (the pulse was switched off, the budget is spent, no model): the run then ends with the reason.
    func resumePulse(_ run: PulseRun, of botID: UUID, conversation: Conversation, chain: ChainContext, text: String,
                     origin: SendOrigin) -> Bool {
        guard !isResetting, bot(botID) != nil else { return false }
        guard pulseIsOn, !pulseBudgetSpent else {
            closePulseWait(run, of: botID, conversation: conversation,
                           why: pulseIsOn ? Self.pulseCappedNotice : "O pulso foi desligado antes da resposta.")
            return false
        }
        let session = session(botID)
        ensureLoaded(botID)
        session.startRoutineRun(run.id, conversation: conversation, at: run.startedAt, kind: .pulse, chain: chain)
        pulseRuns[botID] = run
        if send(text, to: botID, origin: origin) {
            workJournal.pulseBegan(bot: botID, at: run.startedAt)
            setStatus("Pulso: pensando", of: botID)
            return true
        }
        pulseRuns[botID] = nil
        session.endSideRun()
        session.scheduleSave(delay: 0)
        closePulseWait(run, of: botID, conversation: conversation, why: "Não retomou com a resposta: conecte um modelo em Ajustes.")
        return false
    }

    /// The chat's line of a pulse that did something (or failed), and the home page's row.
    private func recordPulseLine(_ bot: Bot, runID: UUID, tokens: Int, summary: String, failed: Bool, reason: String?, in chat: UUID?) {
        let outcome: OrbEvent.Outcome = failed ? .failed : .finished
        let appended = appendToChat(.event(OrbEvent(kind: .pulseRan, actor: OrbRef(bot), detail: String(tokens), note: summary,
                                                    outcome: outcome, runID: runID)), of: bot.id, in: chat)
        pulseState.lastSummary = summary
        pulseState.lastActed = .now
        pulseState.lastReason = reason
        if let appended {
            recordInicioPulse(bot: bot.id, chat: appended.chat, item: appended.item, summary: "\(bot.name): \(summary)",
                              outcome: failed ? .failed : .completed)
        }
    }

    // MARK: The budget

    static let pulseCappedNotice = "O pulso parou: o teto diário de tokens foi atingido."
    static let pulseOffNotice = "O pulso parou: ele foi desligado nos Ajustes."

    /// Called by `recordUsage` for every use of a model: the pulse's own turn, and any turn of a chain the pulse started, add to
    /// the day's count. Over the budget, the chain stops (and the pulse turn, if it still runs).
    func pulseCharge(_ totals: UsageTotals, botID: UUID, source: UsageSource) {
        let tokens = totals.budgetTokens
        guard tokens > 0 else { return }
        let lineage = pulseLineage(of: botID)
        guard source == .pulse || lineage != nil else { return }
        pulseState.roll(to: pulseNow())
        pulseState.tokensToday += tokens
        // The run's own count has the whole chain's turns too (a teammate's, a group's), not only the Orb that pulsed.
        if let owner = pulseRuns.first(where: { $0.value.id == lineage || ($0.key == botID && source == .pulse) })?.key {
            pulseRuns[owner]?.tokens += tokens
        } else if let lineage {
            delegation.chargeWaitingPulse(lineage, tokens: tokens) // the run waits for these very answers
        }
        savePulseState()
        if pulseState.tokensToday >= pulseDailyTokens { Task { @MainActor [weak self] in self?.stopPulseWork() } }
    }

    /// The day's budget is spent, or the pulse (or "Orbs agem por conta própria") was switched off (`switchedOff`): every chain
    /// the pulse started stops, and so do a pulse turn still running and a pulse waiting for answers. Each Orb whose work was cut
    /// gets one line in its chat.
    func stopPulseWork(switchedOff: Bool = false) {
        guard switchedOff || pulseState.tokensToday >= pulseDailyTokens else { return }
        var told: Set<UUID> = []
        let why = switchedOff ? Self.pulseOffNotice : Self.pulseCappedNotice
        // First the pulses that wait, with the real reason: stopping their chains below would close them as "the answer did not come".
        for (runID, wait) in delegation.waitingRoutines {
            guard let run = wait.pulse else { continue }
            delegation.forgetWaitingRoutine(runID)
            closePulseWait(run, of: wait.botID, conversation: wait.conversation, why: why)
            told.insert(wait.botID)
        }
        for (id, chain) in delegation.chainStates where chain.origin.isPulse && !chain.cancelled {
            // A chain over (kept two hours) is closed quietly: only an Orb whose work was cut gets the line.
            if delegation.chainHasWork(id) { told.insert(chain.originBot) }
            delegation.cancelChain(id, by: switchedOff ? .pulseOff : .budget)
        }
        // The pulse's own turns, and the chat turns its answers woke (no request holds those, so no chain stops them).
        for (botID, session) in sessions where session.turnTask != nil
            && (session.sideKind == .pulse || (session.routineID == nil && pulseLineage(of: botID) != nil)) {
            // Stopped by the app, not by the person: its demands are neither done nor failed, and wake a later pulse.
            pulseRuns[botID]?.keys = []
            session.stop(startsQueuedRoutines: true, notice: why)
            told.insert(botID)
        }
        for botID in told where bot(botID) != nil {
            let detail = switchedOff ? OrbEvent.pulseOff : String(pulseDailyTokens)
            appendToChat(.event(OrbEvent(kind: .pulseStopped, actor: bot(botID).map(OrbRef.init), detail: detail)), of: botID)
        }
    }
}

extension DelegationHub.ChainState.Origin {
    var isPulse: Bool { pulseRun != nil }
    /// The pulse run a chain of this origin is charged to.
    var pulseRun: UUID? { if case .pulse(let run) = self { run } else { nil } }
}
