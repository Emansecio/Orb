import Foundation

// One Orb's conversation as the session keeps it: read from disk when it is needed (on the main thread when it cannot
// wait, off it otherwise), written after it changes (at a pace while a reply streams, at once when a turn ends), let
// go of when nobody looks at it, set aside while a routine of the Orb runs, and saved to the Orb's memory in stretches.
// The data files as a whole (which Orbs exist, the notices about them, the store) belong to the app model.

extension BotSession {
    // MARK: Loading

    /// Reads the conversation if it isn't in memory, right now, on the main thread. The way in for anything that has
    /// to read or change a conversation and cannot wait (a message sent, a card answered from a banner), so an
    /// unloaded one is never mistaken for an empty one (and then saved over its file). What can wait goes through
    /// `beginLoading` or `AppModel.loadedConversation` instead (the composer and the approval banners wait for a read
    /// that is already under way rather than come here: this one cannot use that read, so it would wait for it and
    /// then read the file again, on the main thread).
    func ensureLoaded() {
        guard let model, takeUnloaded() else { return }
        isLoading = false
        loadTask?.cancel() // superseded: it must not be handed out again if this one is let go
        loadTask = nil
        loadEpoch += 1 // a read under way is older than this one
        let read = model.store.readConversation(id)
        model.addNotice(AppModel.labeled(read.notice, for: model.bot(id)))
        install(read)
    }

    /// Starts reading the conversation if it isn't in memory, off the main thread, unless that is already under way.
    /// Until it arrives the session counts as `isLoading` (the chat shows a placeholder) and nothing may change its
    /// conversation: whatever needs it earlier goes through `ensureLoaded`, which wins.
    @discardableResult
    func beginLoading() -> Task<Void, Never>? {
        guard isUnloaded, let store = model?.store else { return nil }
        if let running = loadTask { return running }
        isLoading = true
        let epoch = loadEpoch, botID = id
        let task = Task { [weak self] in
            let read = await store.readConversationAsync(botID)
            self?.finishLoading(epoch: epoch, read)
        }
        loadTask = task
        return task
    }

    private func finishLoading(epoch: Int, _ read: StoreRead<Conversation>) {
        // A read that `ensureLoaded` superseded leaves the bookkeeping alone: it may belong to a newer read by now.
        if loadEpoch == epoch {
            loadTask = nil
            isLoading = false
        }
        guard let model, let owner = model.bot(id) else { // deleted meanwhile
            isUnloaded = false
            return
        }
        // Loaded on demand (`ensureLoaded`) while this was reading: that result wins. Its notice still stands when the
        // file was moved aside (the on-demand read then found nothing), but not when the on-demand read already
        // reported the same lost items.
        guard loadEpoch == epoch, takeUnloaded() else {
            if read.value == nil { model.addNotice(AppModel.labeled(read.notice, for: owner)) }
            return
        }
        model.addNotice(AppModel.labeled(read.notice, for: owner))
        install(read) // the chat scrolls to the end of what just arrived when loading ends
    }

    private func install(_ read: StoreRead<Conversation>) {
        conversation = read.value?.closingInterruptedTurn(notice: BotSession.quitNotice) ?? Conversation()
        lastUsed = .now
        rewriteIfItLostItems(read)
    }

    /// A file that lost items while decoding is rewritten once (its original is kept aside), so the loss is
    /// reported once instead of on every launch.
    private func rewriteIfItLostItems(_ read: StoreRead<Conversation>) {
        guard read.value != nil, read.notice?.copy != nil else { return }
        scheduleSave(delay: 0)
    }

    /// Whether the conversation can go back to disk: in memory, not the selected Orb's, not working, parked by a
    /// routine, waiting to be saved or for its stretch note (a local server's waits as long as the keep-alive), and not
    /// used within `keepAlive`.
    func isIdle(now: ContinuousClock.Instant, keepAlive: Duration) -> Bool {
        guard let model, conversation != nil, model.selection != .bot(id), turnTask == nil, routineID == nil, chunkTask == nil,
              parkedChat == nil, model.live(id).status == nil, !model.live(id).isAwaitingApproval,
              !isDirty, saveTask == nil else { return false }
        return lastUsed.map { $0.duration(to: now) >= keepAlive } ?? true
    }

    /// Lets go of the conversation (its file holds what was in memory); it is read again when it is needed.
    func unload() {
        cancelChunkNote()
        conversation = nil
        isUnloaded = true
        loadEpoch += 1
        lastUsed = nil
    }

    /// The Orb was deleted: its conversation, its streamed reply and the reads and writes that were pending go
    /// (nothing is written: its files are deleted next).
    func close() {
        cancelChunkNote()
        liveText = nil
        conversation = nil
        parkedChat = nil
        isUnloaded = false
        isLoading = false
        loadTask?.cancel()
        loadTask = nil
        lastUsed = nil
        isDirty = false
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: Saving

    /// Saves `delay` seconds after the first unsaved change (a streaming reply is written at most every
    /// `streamingSaveInterval`, not rescheduled per token); `delay: 0` saves right away (end of a turn, new
    /// conversation). Encoding and pruning happen on the store's queue.
    func scheduleSave(delay: Double) {
        guard let conversation else { return } // not loaded: nothing of ours to write
        isDirty = true
        if delay > 0, saveTask != nil { return }
        // A long conversation is a big file to replace: the pace of a streaming reply's saves slows with its size
        // (5 s up to 10 s at 2,000 items), and the turn's end writes at once whatever the pace.
        let wait = delay > 0 ? delay + min(5, Double(conversation.items.count) / 400) : 0
        saveTask?.cancel()
        saveTask = Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            saveTask = nil
            write()
        }
    }

    /// Writes the conversation now: the chat to its file, a running routine's to the routine's own.
    func write() {
        guard let current = conversation, let model else { return }
        let conversation = withLiveText(current)
        isDirty = false
        guard let routineID else { return model.store.save(conversation, for: id) }
        // A running side run's conversation goes to its own file, never over the chat's.
        switch sideKind ?? .routine {
        case .routine:
            if model.routines.contains(where: { $0.id == routineID }) {
                model.store.saveRoutineConversation(conversation, routine: routineID, for: id)
            }
        case .delegation:
            model.store.saveSideConversation(conversation, prefix: Store.pedidoPrefix, id: routineID, for: id)
        case .group:
            model.store.saveSideConversation(conversation, prefix: Store.grupoPrefix, id: routineID, for: id)
        }
    }

    /// Writes what changed now, on quit: the conversation if it is waiting to be saved, and the chat a running
    /// routine parked (it is not `conversation`, so nothing else writes it).
    func saveNow() {
        if isDirty {
            saveTask?.cancel() // written now: its timer has nothing left to do
            saveTask = nil
            write()
        }
        if let chat = parkedChat, !chat.items.isEmpty { model?.store.save(chat, for: id) }
    }

    // MARK: A routine's run

    /// The turn machinery works on `conversation`: the routine's own goes there, the chat waits. The chat is written
    /// first (its pending save would otherwise write the routine's conversation in its place): while the routine runs,
    /// only the routine's file changes.
    /// The same for a request from another Orb or a turn in a group (`kind`, `chain`, `serving`: see `sideKind`).
    func startRoutineRun(_ routineID: UUID, conversation own: Conversation, at started: Date, kind: SideRunKind? = nil,
                         chain: ChainContext? = nil, serving: UUID? = nil) {
        cancelChunkNote() // the note being written is about the chat that is parked now
        model?.cancelEditing(id) // the edit belongs to the chat that is parked now
        let chat = conversation ?? Conversation()
        saveTask?.cancel()
        saveTask = nil
        isDirty = false
        if !chat.items.isEmpty { model?.store.save(chat, for: id) }
        parkedChat = chat
        conversation = own
        sideKind = kind
        self.chain = chain
        servingRequest = serving
        self.routineID = routineID
        routineStart = started
    }

    /// The side run is over (or never began): nothing of it is left in the session, and the chat comes back.
    func endSideRun() {
        routineID = nil
        routineStart = nil
        sideKind = nil
        chain = nil
        servingRequest = nil
        unparkChat()
    }

    /// The chat comes back from where a routine's run parked it.
    func unparkChat() {
        guard let chat = parkedChat else { return }
        parkedChat = nil
        conversation = chat
    }

    // MARK: Memory

    func hasUnsavedStretch() -> Bool {
        ensureLoaded()
        guard let conversation else { return false }
        return conversation.items.count > (conversation.memorySavedCount ?? 0)
    }

    /// The conversation since the last saved stretch (nil when there is nothing new, or not yet idle for `gap`).
    /// Marks it saved. `end`: only the items before this index (a compaction at sending saves what came before the
    /// message being sent).
    func pendingStretch(ifIdleFor gap: TimeInterval? = nil, upTo end: Int? = nil) -> [TranscriptItem]? {
        ensureLoaded()
        guard turnTask == nil, let conversation else { return nil }
        let stop = min(end ?? conversation.items.count, conversation.items.count)
        let start = min(conversation.memorySavedCount ?? 0, stop)
        let stretch = Array(conversation.items[start..<stop])
        guard let last = stretch.last else { return nil }
        if let gap, Date.now.timeIntervalSince(last.date) < gap { return nil }
        self.conversation?.memorySavedCount = stop
        scheduleSave(delay: 0)
        return stretch
    }

    /// Saves the conversation since the last saved stretch as a session page, built off the main thread (a long
    /// conversation takes a moment). Returns whether there was a stretch to save.
    /// `notes`: what the model wrote about the stretches being folded (see `ChunkSummary`), for the page. When the
    /// stretch itself was saved already (a long pause saved it by rules before the fold), the notes go to the memory on
    /// a page of their own, so each one gets there exactly once.
    @discardableResult
    func saveMemory(ifIdleFor gap: TimeInterval? = nil, upTo end: Int? = nil, notes: [String] = []) -> Bool {
        let savedBefore = conversation?.memorySavedCount ?? 0
        guard let stretch = pendingStretch(ifIdleFor: gap, upTo: end) else {
            guard gap == nil, !notes.isEmpty else { return false }
            persistStretch([], notes: notes)
            return true
        }
        persistStretch(stretch, notes: notes, savedBefore: savedBefore)
        return true
    }

    /// `savedBefore`: where the saved mark was before `pendingStretch` moved it past `stretch`. When the page cannot be
    /// written the mark goes back there, so the next save (a pause, a compaction) takes the stretch again.
    func persistStretch(_ stretch: [TranscriptItem], notes: [String] = [], savedBefore: Int? = nil) {
        guard let model else { return }
        let bank = model.memory.bank(for: id), botID = id, mark = conversation?.memorySavedCount
        Task.detached(priority: .utility) { [weak model, weak self] in
            var written = true
            if let page = SessionSummary.page(from: stretch, notes: notes) { written = await bank.saveSession(page) }
            if !written, let savedBefore { await self?.unmarkStretch(at: mark, back: savedBefore) }
            await model?.refreshMemory(botID)
        }
    }

    /// The page of the stretch up to `mark` was not written: the stretch is not saved (unless the mark moved on meanwhile).
    func unmarkStretch(at mark: Int?, back earlier: Int) {
        guard let mark, conversation?.memorySavedCount == mark else { return }
        conversation?.memorySavedCount = earlier
        scheduleSave(delay: 0)
    }

    /// When you asked the Orb to remember something and the turn ended without it saving, the app keeps what you
    /// said (or tells you it couldn't tell what to keep). Not after a turn you stopped or that failed.
    func keepRequestedMemory(succeeded: Bool) {
        let request = memoryRequest
        memoryRequest = nil
        guard let request, succeeded, let model, model.bot(id) != nil else { return }
        let items = conversation?.items ?? []
        let saved = items.dropFirst(request.from).contains { item in
            if case .tool(let call) = item.kind { return call.kind == .memory && call.title.hasPrefix("Guardando") && call.state == .done }
            return false
        }
        guard !saved else { return }
        // You said no to the card for it ("remember" asks before keeping preferences): the app doesn't keep it anyway.
        let denied = items.dropFirst(request.from).contains { item in
            guard case .approval(let card) = item.kind, card.decision == .deny else { return false }
            return card.toolName.hasSuffix("remember") || card.items.contains { $0.toolName.hasSuffix("remember") }
        }
        if denied {
            append(.notice("Não guardei na memória: você negou."))
            return
        }
        guard let content = request.intent.content else {
            append(.notice("Não deu para saber o que guardar na memória. Diga, por exemplo: “memorize que …”."))
            return
        }
        let bank = model.memory.bank(for: id), botID = id
        Task { [weak self] in
            // The body is what you said, as when the model saves it (who asked stays in the origin), so the same fact
            // saved later is recognized as this one. The chat says it was kept once it was.
            let outcome = await bank.remember(content, kind: .fato, title: content, origin: .voce)
            self?.append(.notice(outcome == .failed ? "Não consegui guardar na memória: \(MemoryText.clip(content, 160))"
                                 : "\(NoticeAction.keptMemoryPrefix) \(MemoryText.clip(content, 160))"))
            await model.refreshMemory(botID)
        }
    }

    /// Saves the conversation to memory once the user has been away for `SessionSummary.idleGap`.
    func scheduleMemorySave() {
        memoryIdle?.cancel()
        let botID = id
        memoryIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SessionSummary.idleGap))
            guard !Task.isCancelled else { return }
            self?.memoryIdle = nil
            if self?.turnTask != nil { // a routine is running: the chat is saved once the Orb is free
                self?.scheduleMemorySave()
                return
            }
            await self?.model?.loadedConversation(botID) // it may have been let go of while the Orb was idle
            guard !Task.isCancelled else { return }
            self?.saveMemory()
        }
    }

    // MARK: Compaction

    /// Tells the user about a compaction (once, with numbers) and saves to the memory what the conversation held up
    /// to it, so nothing is lost only because it left the model's window. `items`: how many transcript items came
    /// before the message being sent, which the saved stretch stops at. Returns whether something was saved.
    @discardableResult
    func announce(_ report: CompactionReport, memoryUpTo items: Int? = nil) -> Bool {
        append(.notice(report.notice))
        lastCompaction = report
        model?.live(id).setCompactedTo(report.tokensAfter)
        // A routine's run is not a conversation with you: it stays out of the memory's sessions.
        guard routineID == nil else { return false }
        return saveMemory(upTo: items, notes: report.digests)
    }

    /// A fold of older turns made during a turn (see `TurnEvent.compacted`): the next turn starts from its summary,
    /// and the messages it covers are not sent again. Returns how many messages of the conversation it covers.
    @discardableResult
    func keepFold(_ fold: CompactionReport.Fold) -> Int {
        ensureLoaded()
        guard var conversation else { return 0 }
        let covered = conversation.coveredMessageCount
        // The engine counts what it was handed, which is not the message list (steps may have been set aside, a reply
        // made up for a call that never got one), so the fold is carried over in whole turns: that many turn starts on
        // from where the summary already stood, never past the start of the turn in progress.
        let starts = conversation.messages.indices.filter {
            $0 >= covered && conversation.messages[$0].role == .user && !conversation.messages[$0].content.hasPrefix(ContextSummary.marker)
        }
        guard let current = starts.last else { return 0 }
        let boundary = starts.indices.contains(fold.turns) ? min(starts[fold.turns], current) : current
        guard boundary > covered else { return 0 }
        conversation.summary = fold.summary
        conversation.ledger = fold.ledger
        conversation.summaryCoveredCount = boundary
        conversation.compactions = (conversation.compactions ?? 0) + 1
        self.conversation = conversation
        compactedInTurn = true
        scheduleSave(delay: Self.streamingSaveInterval)
        return boundary - covered
    }

    // MARK: What a turn starts from

    /// The id this conversation sends gateways that key routing and caching to a session; made on first use and
    /// kept with the conversation (a cleared chat or a routine run starts from a new `Conversation`).
    func gatewaySessionID() -> String {
        if let id = conversation?.gatewaySessionID { return id }
        let id = UUID().uuidString
        conversation?.gatewaySessionID = id
        return id
    }

    /// Your messages in the current conversation (the interview lasts the first few).
    func userTurnCount() -> Int {
        if routineID != nil { return 99 } // a routine's run is not the first conversation: no interview
        return (conversation?.items ?? []).reduce(0) { count, item in
            if case .user = item.kind { return count + 1 }
            return count
        }
    }
}
