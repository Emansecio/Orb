import AppKit

// One Orb's turn as it runs: its id (a stopped turn may still be draining while the next one runs), the events the
// engine sends and what each changes, the streamed reply, the approval cards, and what happens when it ends. The turn
// is started by `AppModel.send`, which gathers what it needs from the whole app (model, skills, connectors, memory).
// What a turn's end touches beyond this Orb (its routine's history, the queue of routines, the unread count, a
// banner) goes back to the app model.

extension BotSession {
    /// A conversation that keeps changing (a streaming reply) is written at most this often.
    static let streamingSaveInterval = 5.0
    /// Streamed text is published at most this often.
    static let textFlushInterval = Duration.milliseconds(33)
    /// The Orb stops `speaking` when no text arrived for this long (the pause between two bursts of text is not the end of
    /// the speech).
    static let speakingQuiet = Duration.milliseconds(1200)

    // MARK: Lifecycle

    /// Keeps the request of a turn of Orb's own engine for the review that may follow it (see `reviewBase`).
    func keepForReview(_ request: TurnRequest) {
        var base = request
        base.prompt = ""
        base.images = []
        base.requestItem = nil
        base.turnGrants = []
        base.steering = nil
        base.context.release = nil
        reviewBase = base
        reviewFrom = conversation?.messages.count ?? 0
    }

    /// Registers a new turn of the Orb and returns its id.
    func beginTurn() -> UUID {
        let turn = UUID()
        turnID = turn
        reviewBase = nil
        clearBeats()
        resetWork()
        model?.workAnnouncer.reset()
        model?.live(id).setTurnSpend(nil)
        // Written at once, with the message that opened the turn: a crash in the next seconds no longer loses it.
        if conversation != nil {
            conversation?.turnOpen = true
            scheduleSave(delay: 0)
        }
        return turn
    }

    // MARK: What the working line says

    /// A new turn starts with no calls and no actions counted.
    func resetWork() {
        runningCalls = [:]
        actionsThisTurn = 0
        turnCutShort = false
    }

    /// Publishes a phrase of the working line, with this turn's routine and count of actions. Changed once per step of
    /// the turn (a tool, a status), never per token.
    func showWork(_ phrase: WorkLine, announcing: Bool = false) {
        guard let model else { return }
        var line = phrase
        line.routine = model.routineName(for: id)
        line.prefix = model.requesterName(of: id).map { "Pedido de \($0)" } // MultiOrb (WP2): whose request this turn answers
        line.actions = actionsThisTurn
        model.live(id).setWork(line)
        if announcing { model.announceWork(line, of: id) }
    }

    /// The tool the Orb shows: the call that started last among those still running (nil when none runs).
    var openTool: ToolCall.Kind? {
        runningCalls.values.max { $0.startedAt < $1.startedAt }?.kind
    }

    /// The phrase for a status line of the engine. One that repeats the title of a call that is running is that call's,
    /// shown already with its target.
    func showWork(forStatus text: String) {
        if runningCalls.values.contains(where: { $0.title == text }) { return }
        showWork(WorkPhrase.line(status: text))
    }

    /// Whether `turn` is still the Orb's running turn (not stopped, not replaced by a newer one).
    func isCurrent(_ turn: UUID) -> Bool {
        !Task.isCancelled && turnID == turn
    }

    /// A turn that could not even start (no client, no Claude Code). A stopped turn says nothing: the failure
    /// would be its own cancellation, or belong to a turn the user already left.
    func failSetup(_ error: Error, turn: UUID) {
        failSetup(error is CancellationError ? nil : error.localizedDescription, turn: turn)
    }

    func failSetup(_ message: String?, turn: UUID) {
        guard isCurrent(turn), let message else { return }
        apply(.failed(message))
        finishTurn(turn, succeeded: false)
    }

    func play(_ events: AsyncStream<TurnEvent>, turn: UUID) async {
        var succeeded = true
        // A call the provider already bills for (its input tokens are known) and that has not ended.
        // The model and source are kept with it: by the time the stream ends, a stop may already have started another turn.
        var unfinished: (usage: TokenUsage, label: UsageLabel?)?
        // Characters of the reply shown since that call began: the provider's first report says a token or two of output.
        var streamed = 0
        for await event in events {
            // A stopped stream still delivers queued events; `stop` already closed the turn.
            guard isCurrent(turn) else { break }
            switch event {
            case .failed: succeeded = false
            case .pendingUsage(let used):
                unfinished = (used, usageLabel)
                streamed = 0
            case .requestUsage: unfinished = nil
            case .text(let delta): streamed += delta.count
            default: break
            }
            apply(event)
        }
        // The user stopped the turn in the middle of a call: the engine can no longer report it, but the provider charges it,
        // for the input it announced and for the words it had already written.
        if let unfinished {
            recordUsage(UsageTotals(unfinished.usage.withOutput(atLeastCharacters: streamed)), label: unfinished.label)
        }
        if !Task.isCancelled { finishTurn(turn, succeeded: succeeded) }
    }

    /// Stops the running turn. `startsQueuedRoutines: false` keeps a routine that was waiting for the Orb from taking it
    /// at once: the caller has something to send first and starts the queue itself if it does not. `notice`: what the
    /// chat says about it.
    func stop(startsQueuedRoutines: Bool = true, notice: String = BotSession.stoppedNotice) {
        resumableSince = nil // a process left running after a stop does not bring the Orb back by itself
        guard let task = turnTask, let turn = turnID, let model else { return }
        task.cancel()
        ApprovalNotifications.clear(model.pendingApprovals(of: id).map(\.id))
        let gate = model.gate, botID = id
        Task { await gate.cancelApprovals(for: botID) }
        flushText()
        keepCutReply(liveText?.text)
        closeStreaming()
        model.setAwaitingApproval(false, of: id)
        mutateItems { items in
            for index in items.indices {
                switch items[index].kind {
                case .approval(var request) where request.decision == nil:
                    request.decision = .deny
                    items[index].kind = .approval(request)
                case .tool(var call) where call.state == .running:
                    // Its result is dropped (the turn is no longer current): it would stay "running" for good.
                    call.state = .failed
                    call.output = call.output ?? "Interrompido."
                    call.finishedAt = .now
                    items[index].kind = .tool(call)
                default:
                    break
                }
            }
        }
        append(.notice(notice))
        finishTurn(turn, succeeded: false, userStopped: true, startsQueuedRoutines: startsQueuedRoutines)
    }

    /// The reply you stopped while it was being written: what you read of it is part of the conversation, as a dropped
    /// connection leaves it (`AgentEngine.interruptedMarker`), so the next turn knows it. Only the part not recorded yet
    /// (a reply carried on after a cut already has its start in the history).
    private func keepCutReply(_ text: String?) {
        var said = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let last = conversation?.messages.last, last.role == .assistant {
            let recorded = last.content.replacingOccurrences(of: AgentEngine.interruptedMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if said.hasPrefix(recorded) { said = String(said.dropFirst(recorded.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !said.isEmpty else { return }
        changeConversation { $0.absorb(ChatMessage(role: .assistant, content: said + AgentEngine.interruptedMarker)) }
    }

    static let stoppedNotice = "Você interrompeu esta resposta"
    /// A task of your own chat that the app closed on (a quit, or a crash found at the next launch): "Continuar" picks it up.
    nonisolated static let quitNotice = "O app foi fechado no meio desta tarefa."
    /// The same for a routine's run, another Orb's request or a group's turn: nothing picks those up by itself, and running
    /// one again could repeat what it already did.
    nonisolated static let quitSideNotice = "Interrompido: o app foi fechado no meio desta tarefa. Confira o que já foi feito antes de repetir."

    /// The messages you sent into the task in progress that it has not acted on yet (see `TranscriptItem.unansweredSteered`).
    /// Read before the turn is stopped.
    func unansweredSteered() -> [SteeredMessage] {
        let items = conversation?.items ?? []
        let ids = Set(TranscriptItem.unansweredSteered(in: items))
        return items.compactMap { item in
            guard ids.contains(item.id), case .user(let text, _) = item.kind else { return nil }
            return SteeredMessage(id: item.id, text: text, files: [], pictures: [], prompt: text)
        }
    }

    /// Takes messages delivered into a stopped task back out of it (the chat's bubble and the model's copy), so they can go
    /// as a request of their own without showing twice.
    func withdrawSteered(_ ids: [UUID]) {
        let ids = Set(ids)
        changeConversation { conversation in
            conversation.items.removeAll { ids.contains($0.id) }
            conversation.messages.removeAll { $0.itemID.map(ids.contains) ?? false }
        }
        scheduleSave(delay: Self.streamingSaveInterval)
    }

    /// Records the marks of the turn's prompt when it has been delivered: when the user message (with the snapshot) is stored.
    func recordMarks() {
        guard let marks = pendingMarks else { return }
        pendingMarks = nil
        conversation?.record(marks)
    }

    func apply(_ event: TurnEvent) {
        guard let model else { return }
        switch event {
        case .status(let text):
            model.setStatus(model.routineStatus(text, for: id), of: id)
            showWork(forStatus: text)
        case .text(let delta):
            // Shown by `flushText`; anything that adds to the transcript flushes first (`closeStreaming`).
            pendingText = (pendingText ?? "") + delta
            if !delta.allSatisfy(\.isWhitespace) { markSpeaking() }
            if textFlush == nil {
                textFlush = Task { [weak self] in
                    try? await Task.sleep(for: Self.textFlushInterval)
                    if !Task.isCancelled { self?.flushText() }
                }
            }
        case .toolStarted(let call):
            stopSpeaking()
            closeStreaming()
            append(.tool(call))
            model.live(id).runningTool = call.kind
            runningCalls[call.id] = call
            actionsThisTurn += 1
            // A proposal starts the review's count over (its step, counted from the message, was the proposing one).
            if call.title == RememberTool.skillTitle { stepsSinceSkill = 0 }
            showWork(WorkPhrase.line(for: call), announcing: true)
        case .toolFinished(let id, let state, let output, let produced):
            runningCalls[id] = nil
            // Calls in parallel: the Orb keeps showing a tool while any is still running.
            model.live(self.id).runningTool = openTool
            mutateItems { items in
                let files = Self.takeOver(produced, in: &items)
                // Call ids are unique and the call is recent: search from the end and stop at the match.
                for index in items.indices.reversed() {
                    if case .tool(var call) = items[index].kind, call.id == id {
                        call.state = state
                        call.output = output
                        call.files = files.isEmpty ? nil : files
                        call.finishedAt = .now
                        items[index].kind = .tool(call)
                        break
                    }
                }
            }
        case .approval(let request):
            stopSpeaking()
            closeStreaming()
            append(.approval(request))
            model.setAwaitingApproval(true, of: id)
            model.announceApproval(request, of: id)
        case .message(let message):
            ensureLoaded()
            changeConversation {
                $0.absorb(message)
                if message.role == .assistant { $0.lastModelCall = .now }
            }
            // What the review counts, as Hermes does: steps of the model that ask for tools (ten reads at once are one),
            // in Orb's own engine and in conversations (a routine's run is nobody's lesson).
            if message.role == .assistant, !message.toolCalls.isEmpty, reviewBase != nil, routineID == nil { stepsSinceSkill += 1 }
            if message.role == .user {
                conversation?.taskPaused = false
                recordMarks()
                if let cursor = pendingContextCursor {
                    pendingContextCursor = nil
                    conversation?.contextHandedAt = cursor
                }
            }
            scheduleSave(delay: Self.streamingSaveInterval)
        case .failed(let message):
            closeStreaming()
            append(.notice("Não deu certo: \(message)"))
        case .notice(let text):
            if text == AgentEngine.cutShortNotice { turnCutShort = true }
            // The cache warning is said once per conversation, not at every turn that still has the problem.
            if text == CacheHealth.notice, conversation?.items.contains(where: { $0.kind == .notice(text) }) == true { break }
            // Going in circles: whoever is not looking at this Orb gets a banner with "Parar" (a routine's run, above all).
            if text == LoopWatch.userNotice { model.notifyAboutTurn(of: id, text) }
            closeStreaming()
            append(.notice(text))
        case .usage(let total):
            setUsage(total)
            model.live(id).setTurnSpend(TurnSpend(total, dollars: spentDollars(total)))
            // The model calls are counted one by one, as `.requestUsage` arrives.
        case .requestUsage(let used):
            setRequestUsage(used)
            model.live(id).setLastUsage(used)
            recordUsage(UsageTotals(used))
        case .pendingUsage:
            break // `play` keeps it for a call that is stopped
        case .compacted(var report):
            closeStreaming()
            // A fold of older turns is kept (the next turn starts from it), counted in the conversation's own messages.
            if let fold = report.fold {
                report.foldedMessages = keepFold(fold)
                report.foldedRequests = conversation.map { $0.requestCount(in: 0..<$0.coveredMessageCount) }
                if report.foldedMessages > 0 { foldedNotes += report.digests }
            }
            guard report.fold == nil || report.foldedMessages > 0 else { break }
            append(.notice(report.notice))
            lastCompaction = report
            model.live(id).setCompactedTo(report.tokensAfter)
        case .taskPaused:
            ensureLoaded()
            changeConversation { $0.taskPaused = true }
            scheduleSave(delay: Self.streamingSaveInterval)
        case .steered(let messageID):
            model.deliverSteered(messageID, to: id)
        }
    }

    /// Hands what the running turn used to the usage history (see `AppModel.recordUsage`).
    private func recordUsage(_ totals: UsageTotals, label: UsageLabel? = nil) {
        guard let model, let label = label ?? usageLabel else { return }
        model.recordUsage(totals, botID: id, model: label.model, source: label.source)
    }

    /// The model and source of the running turn, as the usage history files them.
    private var usageLabel: UsageLabel? {
        guard let model, let name = turnModel ?? model.bot(id).flatMap(model.modelRef(for:))?.text else { return nil }
        // MARK: MultiOrb (WP1, WP5)
        // A turn of a member in a group is filed as the group's, and so is one of the side runs of a group's chain.
        let source: UsageSource = switch (routineID, sideKind) {
        case _ where model.groupHub.activeGroup(of: id) != nil: .group
        case (nil, _): .chat
        case (_, .delegation): .delegation
        case (_, .group): .group
        default: .routine
        }
        return UsageLabel(model: name, source: source)
    }

    /// What `total` cost at the provider's prices, when the turn's model is billed by use and its price is known.
    private func spentDollars(_ total: TokenUsage) -> Double? {
        guard let model, let label = usageLabel else { return nil }
        if case .paid(let dollars) = model.priceBook.cost(of: UsageTotals(total), model: label.model) { return dollars }
        return nil
    }

    private struct UsageLabel {
        var model: String
        var source: UsageSource
    }

    /// Closes the turn `turn`; a turn that is no longer the Orb's current one (stopped, then replaced) is ignored.
    /// `userStopped`: you ended it (Parar, Parar e enviar). That is no failure: the Orb only blinks, where a failed turn
    /// shows the error.
    func finishTurn(_ turn: UUID, succeeded: Bool = true, userStopped: Bool = false, startsQueuedRoutines: Bool = true) {
        guard turnID == turn, turnTask != nil, let model else { return }
        conversation?.turnOpen = nil
        let botID = id
        let ranRoutine = routineID != nil
        // A task that stopped at the step limit is not done: a routine run or another Orb's request records that it did
        // not finish, and why (the engine's "Pausei depois de…", the run's last notice).
        let paused = conversation?.isTaskPaused ?? false
        let completed = succeeded && !paused
        if !completed { reviewBase = nil } // never reviewed: lets go of the client (and Claude Code's parked process)
        // What the celebration is measured by, before the end of the turn clears it.
        let turnSeconds = model.live(id).workingSince.map { Date.now.timeIntervalSince($0) } ?? 0
        let turnActions = actionsThisTurn
        let cutShort = turnCutShort
        turnTask = nil
        turnID = nil
        pendingMarks = nil
        ApprovalNotifications.clearStopBanner(of: botID) // its "Parar" would stop the next turn
        // The turn may have changed files: the next message reads the folder again.
        Task { await WorkspaceSnapshots.shared.invalidate(botID) }
        let compacted = compactedInTurn
        compactedInTurn = false
        let notes = foldedNotes
        foldedNotes = []
        stopSpeaking()
        closeStreaming()
        model.setStatus(nil, of: id)
        resetWork()
        if routineID != nil {
            // A routine's run isn't a conversation with you: it stays out of the memory's sessions.
            let count = conversation?.items.count
            conversation?.memorySavedCount = count
        } else {
            keepRequestedMemory(succeeded: succeeded)
            // Older turns left the model's view during this turn: what they held goes to the memory now, once.
            if compacted { saveMemory(notes: notes) }
            scheduleMemorySave()
            if succeeded { model.writeStretchNote(of: id) }
        }
        let bank = model.memory.bank(for: botID)
        Task {
            await bank.sweep() // once a day: the brief no longer waits for it
            await model.refreshMemory(botID, onlyIfChanged: true)
        }
        model.usageLog.flush() // what the turn used is written now, not after the batch's delay
        model.live(id).runningTool = nil
        model.setAwaitingApproval(false, of: id)
        let reply = lastReply()
        let routineID = routineID
        // MARK: MultiOrb (WP1)
        let kind = sideKind
        let isOrbRun = kind == .delegation || kind == .group // a request from another Orb or a group turn: nobody to tell
        sideKind = nil
        let serving = servingRequest
        servingRequest = nil
        chain = nil
        self.routineID = nil
        if let routineID {
            if isOrbRun {
                model.delegation.finishSideRun(id, runID: routineID, kind: kind ?? .delegation, serving: serving,
                                               succeeded: completed, userStopped: userStopped, reply: reply)
            } else {
                model.finishRoutineRun(id, routineID: routineID, succeeded: completed, reply: reply, userStopped: userStopped)
            }
        }
        // A routine that waits for other Orbs is not done: its banner and unread come with the run's end.
        let waits = routineID.map { model.delegation.isWaiting(routine: $0) } ?? false
        if userStopped {
            model.live(id).cued(.blink)
        } else if succeeded {
            if cutShort || paused {
                model.live(id).cued(.sigh) // left half way: no joy
            } else {
                celebrate(OrbCelebration.level(seconds: turnSeconds, actions: turnActions, ranRoutine: ranRoutine,
                                               selected: model.selection == .bot(id)))
            }
            if !isOrbRun, !waits, let bot = model.bot(id), let reply { model.notify(bot.name, RoutineRun.preview(of: reply)) }
        } else {
            flash(\.hasFailed, seconds: 2.5)
        }
        // The one who asked is told, not the one who did the work (its unread count goes to the asker when the answer arrives).
        if !isOrbRun, !waits, model.selection != .bot(id) || !(NSApp?.isActive ?? false) {
            model.setUnread(model.live(id).unread + 1, for: id)
        }
        if routineID == nil { scheduleSave(delay: 0) } // a routine's was written by `finishRoutineRun`
        if routineID == nil { model.settleSteering(id, succeeded: succeeded) } // what you said during the turn, if anything
        if startsQueuedRoutines { model.startNextQueuedWork(for: id) }
        // Last, so a message or a routine that took the Orb at once is not met by a review. A proposal the turn made
        // (you asked for a skill, or the Orb proposed one) is told now; the review comes in the background.
        if !ranRoutine {
            Task { await model.collectSkillProposals(botID) }
            if completed { model.reviewSkillsIfDue(self) } // a task left half way teaches little
            if completed { model.consolidateMemoryIfDue(self) }
            if completed { model.proposeMemoryMergeIfDue(self) }
        }
    }

    /// The last thing the turn's conversation says (a routine's, while it runs; the transcript is always the chat).
    func lastReply() -> String? {
        for item in (conversation?.items ?? []).reversed() {
            if case .bot(let text, _) = item.kind { return text }
            if case .user = item.kind { return nil }
        }
        return nil
    }

    /// Puts the Orb in a transient state set for a few seconds. Each flag has its own timer: a new flash of the same
    /// flag replaces the one running (the old one would clear it before its time).
    func flash(_ flag: ReferenceWritableKeyPath<BotLive, Bool>, seconds: Double) {
        guard let model else { return }
        let live = model.live(id)
        flashes[flag]?.cancel()
        live[keyPath: flag] = true
        flashes[flag] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            live[keyPath: flag] = false
            self?.flashes[flag] = nil
        }
    }

    /// Ends a flash now.
    func cancelFlash(_ flag: ReferenceWritableKeyPath<BotLive, Bool>) {
        flashes.removeValue(forKey: flag)?.cancel()
        if let live = model?.liveBot(id) { live[keyPath: flag] = false }
    }

    /// A new turn starts without the last one's joy or error.
    func clearBeats() {
        cancelFlash(\.isCelebrating)
        cancelFlash(\.hasFailed)
    }

    /// The Orb celebrates the end of a turn as much as the turn deserved.
    func celebrate(_ level: OrbCelebration) {
        guard let model else { return }
        model.live(id).setCelebration(level)
        flash(\.isCelebrating, seconds: level.seconds)
    }

    // MARK: Speaking

    /// Keeps the Orb `speaking` until no text arrived for `speakingQuiet`.
    func markSpeaking() {
        guard let live = model?.liveBot(id) else { return } // a late event of a deleted Orb starts no watcher
        speakingUntil = .now + Self.speakingQuiet
        guard !live.isSpeaking else { return }
        live.isSpeaking = true
        speakingWatch = Task { [weak self] in
            while !Task.isCancelled, let deadline = self?.speakingUntil {
                if deadline <= .now { self?.stopSpeaking(); return }
                try? await Task.sleep(until: deadline)
            }
        }
    }

    func stopSpeaking() {
        speakingUntil = nil
        speakingWatch?.cancel()
        speakingWatch = nil
        model?.liveBot(id)?.isSpeaking = false
    }

    // MARK: The streamed reply

    /// Shows the streamed text received since the last flush (one update for many tokens). The reply's item joins
    /// the transcript with the first flush; after that only its `LiveText` changes, so a flush costs the same
    /// whatever the length of the reply or of the conversation.
    func flushText() {
        textFlush?.cancel()
        textFlush = nil
        guard let delta = pendingText else { return }
        pendingText = nil
        if let live = liveText {
            live.append(delta)
            scheduleSave(delay: Self.streamingSaveInterval)
            return
        }
        ensureLoaded()
        if let last = conversation?.items.last, case .bot(let text, true) = last.kind {
            // A streaming message nobody is writing to yet (not expected). Its row was drawn without a `LiveText`
            // and would not look at one that appears later, so the text carries on in a new item, which gets a new row.
            let item = TranscriptItem(.bot(text: text, isStreaming: true))
            let live = LiveText(itemID: item.id, text: text)
            live.append(delta)
            liveText = live
            mutateItems { items in
                items.removeLast()
                items.append(item)
            }
            return
        }
        let item = TranscriptItem(.bot(text: delta.trimmingCharacters(in: .newlines), isStreaming: true))
        if case .bot(let text, _) = item.kind { liveText = LiveText(itemID: item.id, text: text) } // before the row exists
        mutateItems { $0.append(item) }
    }

    func closeStreaming() {
        flushText()
        if let live = liveText {
            liveText = nil
            let text = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
            mutateItems { items in
                guard let index = items.lastIndex(where: { $0.id == live.itemID }) else { return }
                items[index].kind = .bot(text: text, isStreaming: false)
            }
        } else if let last = conversation?.items.last, case .bot(let text, true) = last.kind {
            mutateItems { items in
                items[items.count - 1].kind = .bot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isStreaming: false)
            }
        }
    }

    /// The conversation as it reads now: the reply being streamed has the text received so far (what is written to
    /// disk), where `conversation` still has the text the reply began with.
    func withLiveText(_ conversation: Conversation) -> Conversation {
        guard let live = liveText, let index = conversation.items.lastIndex(where: { $0.id == live.itemID }) else {
            return conversation
        }
        var written = conversation
        written.items[index].kind = .bot(text: live.text, isStreaming: true)
        return written
    }

    // MARK: The transcript

    /// `id`: the new row takes this id (the bubble of an edited message keeps the one it had).
    func append(_ kind: TranscriptItem.Kind, duringTask: Bool = false, id: UUID? = nil) {
        var item = TranscriptItem(kind, duringTask: duringTask)
        if let id { item.id = id }
        mutateItems { $0.append(item) }
    }

    /// A file shows under the last call of the turn that touched it: the earlier calls give it up, and one that was
    /// made by an earlier call stays "novo" when a later one changes it. Returns `produced` as the new call keeps it.
    nonisolated static func takeOver(_ produced: [ProducedFile], in items: inout [TranscriptItem]) -> [ProducedFile] {
        guard !produced.isEmpty else { return [] }
        var files = produced
        for index in items.indices.reversed() {
            switch items[index].kind {
            case .user:
                return files
            case .tool(var call):
                guard let earlier = call.files, earlier.contains(where: { old in files.contains { $0.path == old.path } }) else { continue }
                for old in earlier where old.created {
                    if let position = files.firstIndex(where: { $0.path == old.path }) { files[position].created = true }
                }
                let kept = earlier.filter { old in !files.contains { $0.path == old.path } }
                call.files = kept.isEmpty ? nil : kept
                items[index].kind = .tool(call)
            default:
                continue
            }
        }
        return files
    }

    func mutateItems(_ change: (inout [TranscriptItem]) -> Void) {
        ensureLoaded()
        changeConversation { change(&$0.items) }
        scheduleSave(delay: Self.streamingSaveInterval)
    }

    // MARK: Approval cards

    /// Marks the cards the engine answered on its own (a change of permission mode) as decided.
    func markDecided(_ answered: [(approvalID: UUID, decision: ApprovalDecision)]) {
        guard !answered.isEmpty else { return }
        mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.decision == nil,
                   let match = answered.first(where: { $0.approvalID == request.id }) {
                    request.decision = match.decision
                    items[index].kind = .approval(request)
                }
            }
        }
        ApprovalNotifications.clear(answered.map(\.approvalID))
        updateAwaitingApproval()
    }

    /// The Orb waits for you exactly while one of its cards is open.
    func updateAwaitingApproval() {
        let stillOpen = (conversation?.items ?? []).contains {
            if case .approval(let request) = $0.kind { request.decision == nil } else { false }
        }
        if !stillOpen { model?.setAwaitingApproval(false, of: id) }
    }
}

extension TranscriptItem {
    /// The messages you sent into the task in progress that it has not acted on yet: the last ones the chat shows as
    /// "durante a tarefa", with nothing of the Orb after them (no reply, no step). Only text ones (a message with
    /// attachments stays where it is).
    static func unansweredSteered(in items: [TranscriptItem]) -> [UUID] {
        var found: [UUID] = []
        for item in items.reversed() {
            switch item.kind {
            case .user(_, let attachments):
                guard item.duringTask == true, attachments.isEmpty else { return found } // the start of the turn
                found.insert(item.id, at: 0)
            case .notice:
                continue
            default:
                return found // the Orb did something after it: it was read
            }
        }
        return found
    }
}
