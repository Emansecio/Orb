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
    /// The Orb stops `speaking` when no text arrived for this long.
    static let speakingQuiet = Duration.milliseconds(600)

    // MARK: Lifecycle

    /// Registers a new turn of the Orb and returns its id.
    func beginTurn() -> UUID {
        let turn = UUID()
        turnID = turn
        return turn
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
        for await event in events {
            // A stopped stream still delivers queued events; `stop` already closed the turn.
            guard isCurrent(turn) else { break }
            if case .failed = event { succeeded = false }
            apply(event)
        }
        if !Task.isCancelled { finishTurn(turn, succeeded: succeeded) }
    }

    func stop() {
        guard let task = turnTask, let turn = turnID, let model else { return }
        task.cancel()
        ApprovalNotifications.clear(model.pendingApprovals(of: id).map(\.id))
        let gate = model.gate, botID = id
        Task { await gate.cancelApprovals(for: botID) }
        closeStreaming()
        model.setAwaitingApproval(false, of: id)
        mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.decision == nil {
                    request.decision = .deny
                    items[index].kind = .approval(request)
                }
            }
        }
        append(.notice("Você interrompeu esta resposta"))
        finishTurn(turn, succeeded: false)
    }

    /// Records the marks of the turn's prompt when it has been delivered: for Orb's own engine, when the user message (with
    /// the snapshot) is stored; for Claude Code, when its session answers.
    func recordMarks(native: Bool) {
        guard let marks = pendingMarks, marks.isNative == native else { return }
        pendingMarks = nil
        conversation?.record(marks)
    }

    func apply(_ event: TurnEvent) {
        guard let model else { return }
        switch event {
        case .status(let text):
            model.setStatus(model.routineStatus(text, for: id), of: id)
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
        case .toolFinished(let id, let state, let output):
            model.live(self.id).runningTool = nil
            mutateItems { items in
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
            stopSpeaking()
            closeStreaming()
            append(.approval(request))
            model.setAwaitingApproval(true, of: id)
            model.announceApproval(request, of: id)
        case .message(let message):
            ensureLoaded()
            changeConversation { $0.messages.append(message) }
            if message.role == .user {
                conversation?.taskPaused = false
                recordMarks(native: true)
            }
            scheduleSave(delay: Self.streamingSaveInterval)
        case .failed(let message):
            closeStreaming()
            append(.notice("Não deu certo: \(message)"))
        case .notice(let text):
            // The cache warning is said once per conversation, not at every turn that still has the problem.
            if text == CacheHealth.notice, conversation?.items.contains(where: { $0.kind == .notice(text) }) == true { break }
            closeStreaming()
            append(.notice(text))
        case .usage(let total):
            setUsage(total)
        case .requestUsage(let used):
            setRequestUsage(used)
            model.live(id).setLastUsage(used)
        case .compacted(var report):
            closeStreaming()
            // A fold of older turns is kept (the next turn starts from it), counted in the conversation's own messages.
            if let fold = report.fold { report.foldedMessages = keepFold(fold) }
            // Claude Code compacting its own session forgets details too: the memory is brought up to date after the turn.
            if report.kind == .claudeCode { compactedInTurn = true }
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
        case .session(let sessionID):
            ensureLoaded()
            let folder = claudeTurnFolder
            changeConversation { $0.claudeSessionReported(sessionID, folder: folder) }
            if !sessionID.isEmpty { recordMarks(native: false) }
            scheduleSave(delay: Self.streamingSaveInterval)
        }
    }

    /// Closes the turn `turn`; a turn that is no longer the Orb's current one (stopped, then replaced) is ignored.
    func finishTurn(_ turn: UUID, succeeded: Bool = true) {
        guard turnID == turn, turnTask != nil, let model else { return }
        let botID = id
        turnTask = nil
        turnID = nil
        pendingMarks = nil
        // The turn may have changed files: the next message reads the folder again.
        Task { await WorkspaceSnapshots.shared.invalidate(botID) }
        let compacted = compactedInTurn
        compactedInTurn = false
        let turnFolder = claudeTurnFolder
        claudeTurnFolder = nil
        if isClaudeTurn {
            isClaudeTurn = false
            conversation?.claudeTurnFinished(folder: turnFolder)
        }
        stopSpeaking()
        closeStreaming()
        model.setStatus(nil, of: id)
        if routineID != nil {
            // A routine's run isn't a conversation with you: it stays out of the memory's sessions.
            let count = conversation?.items.count
            conversation?.memorySavedCount = count
        } else {
            keepRequestedMemory(succeeded: succeeded)
            // Older turns left the model's view during this turn: what they held goes to the memory now, once.
            if compacted { saveMemory() }
            scheduleMemorySave()
        }
        Task { await model.refreshMemory(botID) }
        model.live(id).runningTool = nil
        model.setAwaitingApproval(false, of: id)
        let reply = lastReply()
        let routineID = routineID
        self.routineID = nil
        if let routineID { model.finishRoutineRun(id, routineID: routineID, succeeded: succeeded, reply: reply) }
        if succeeded {
            flash(\.isCelebrating, seconds: 3)
            if let bot = model.bot(id), let reply { model.notify(bot.name, String(reply.prefix(180))) }
        } else {
            flash(\.hasFailed, seconds: 2.5)
        }
        if model.selection != .bot(id) || !(NSApp?.isActive ?? false) {
            model.setUnread(model.live(id).unread + 1, for: id)
        }
        if routineID == nil { scheduleSave(delay: 0) } // a routine's was written by `finishRoutineRun`
        if routineID == nil { model.settleSteering(id, succeeded: succeeded) } // what you said during the turn, if anything
        model.startNextQueuedRoutine(for: id)
    }

    /// The last thing the turn's conversation says (a routine's, while it runs; the transcript is always the chat).
    func lastReply() -> String? {
        for item in (conversation?.items ?? []).reversed() {
            if case .bot(let text, _) = item.kind { return text }
            if case .user = item.kind { return nil }
        }
        return nil
    }

    /// Puts the Orb in a transient state set for a few seconds.
    func flash(_ flag: ReferenceWritableKeyPath<BotLive, Bool>, seconds: Double) {
        guard let model else { return }
        let live = model.live(id)
        live[keyPath: flag] = true
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            live[keyPath: flag] = false
        }
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

    func append(_ kind: TranscriptItem.Kind) {
        mutateItems { $0.append(TranscriptItem(kind)) }
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
