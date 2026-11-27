import Foundation

// Chain cancellation, Orb deletion cleanup, timeouts (`sweep`), worktree cleanup, and read-only queries.
extension DelegationHub {
    // MARK: Stopping

    func cancelChain(_ id: UUID, by reason: CancelReason) {
        guard let model else { return }
        var chain = chainStates[id] ?? ChainState(origin: .group(id), originBot: UUID(), groupID: nil)
        // A stopped ask can be redone at once: its repeat keys no longer mean "already on the way".
        forgetRepeats(of: chain)
        chain.recent = [:]
        let open = requests.values.filter { $0.envelope.chainID == id && Self.isOpen($0.state) }
            .sorted(by: Self.older)
        let hadInbox = inbox.values.contains { $0.contains { $0.chainID == id } }
        let alreadyCancelled = chain.cancelled
        chain.cancelled = true
        chainStates[id] = chain
        var touched: Set<UUID> = []
        var running: [UUID] = []
        for request in open {
            let envelope = request.envelope
            let was = request.state
            requests[envelope.id]?.state = .cancelled
            requests[envelope.id]?.finishedAt = .now
            queues[envelope.to.id]?.removeAll { $0 == envelope.id }
            closeSuspended(request, as: .cancelled)
            waitingSince[envelope.id] = nil
            touched.formUnion([envelope.from.id, envelope.to.id])
            if envelope.kind == .ask { markSent(envelope.id, asker: envelope.from.id, as: .cancelled, in: envelope.chat) }
            if was == .running {
                running.append(envelope.to.id)
            } else if envelope.groupID != nil {
                groupHooks?.turnFinished(requests[envelope.id] ?? request, reply: nil, outcome: .cancelled)
            }
        }
        for (botID, chats) in chain.noticed {
            for chat in chats { dropUnreadNotices(of: id, for: botID, in: chat) }
        }
        for botID in Array(inbox.keys) {
            let before = inbox[botID]?.count ?? 0
            inbox[botID]?.removeAll { $0.chainID == id }
            if inbox[botID]?.isEmpty == true { inbox[botID] = nil }
            if (inbox[botID]?.count ?? 0) != before { touched.insert(botID) }
        }
        model.workJournal.dropPendingReplies(inChain: id)
        // Their requests are marked first, so the end of each turn finds nothing to answer.
        for botID in running {
            model.session(botID).stop(startsQueuedRoutines: false,
                                      notice: isShuttingDown ? BotSession.quitSideNotice
                                          : reason == .gaveUp ? ApprovalWait.gaveUpNotice
                                          : reason == .budget ? AppModel.pulseCappedNotice
                                          : reason == .pulseOff ? AppModel.pulseOffNotice : BotSession.stoppedNotice)
        }
        refresh(Array(touched))
        // A group's chain says it stopped in the group's own thread (`groupStopped`), never in its orchestrator's private chat.
        if reason == .user, chain.groupID == nil, !isShuttingDown, !alreadyCancelled, !open.isEmpty || hadInbox, model.bot(chain.originBot) != nil {
            model.appendToChat(.event(OrbEvent(kind: .chainStopped, actor: model.bot(chain.originBot).map(OrbRef.init), chainID: id)),
                               of: chain.originBot, in: chain.chat)
        }
        for botID in touched { schedulePump(botID) }
        // A group's chain stopped by the person from elsewhere (the Parar of whoever waits for it) stops the group.
        // Not while quitting: the run must stay in the journal and resume, not be written as stopped by the person.
        if reason == .user || reason == .budget || reason == .pulseOff, !isShuttingDown, chain.groupID != nil, !alreadyCancelled {
            groupHooks?.chainStopped(id, by: reason)
        }
        settleWaitingRoutines()
    }

    /// The chain still has work: a request open, or an answer not handed yet (a chain over is kept two hours for its repeats).
    func chainHasWork(_ id: UUID) -> Bool {
        requests.values.contains { $0.envelope.chainID == id && Self.isOpen($0.state) }
            || inbox.values.contains { $0.contains { $0.chainID == id } }
    }

    /// A conversation of the Orb was deleted: what it asked of other Orbs stops, so the answers do not wake some other
    /// conversation (`chatOrLatest`) with a subject the person threw away.
    func cancelChains(startedIn chat: UUID, of botID: UUID) {
        for (id, state) in chainStates where state.originBot == botID && state.chat == chat && !state.cancelled && state.groupID == nil {
            cancelChain(id, by: .user)
        }
    }

    /// Stops every chain (the switch of Ajustes was turned off, or the app is being reset). A group's chains do not depend on the
    /// switch, so they stay unless `includingGroups`.
    func cancelAll(by reason: CancelReason, includingGroups: Bool = false) {
        var ids = Array(chainStates.filter { includingGroups || $0.value.groupID == nil }.keys)
        for request in requests.values where Self.isOpen(request.state) && (includingGroups || request.envelope.groupID == nil) {
            if !ids.contains(request.envelope.chainID) { ids.append(request.envelope.chainID) }
        }
        for id in ids { cancelChain(id, by: reason) }
    }

    /// The Orb was deleted: what it was doing stops, what it asked is dropped, and whoever waited for it is told.
    func orbDeleted(_ id: UUID) {
        let affected = requests.values.filter { Self.isOpen($0.state) && ($0.envelope.to.id == id || $0.envelope.from.id == id) }
            .sorted(by: Self.older)
        var running: [UUID] = []
        var groupChains: [UUID] = []
        for request in affected {
            let envelope = request.envelope
            let was = request.state
            if envelope.to.id == id {
                // The target is gone: the asker is told.
                var failed = request
                failed.state = .failed
                failed.finishedAt = .now
                requests[envelope.id] = failed
                queues[id]?.removeAll { $0 == envelope.id }
                suspended[envelope.id] = nil
                waitingSince[envelope.id] = nil
                answer(failed, status: .failed, text: "Esse Orb foi apagado")
                if was != .running, envelope.groupID != nil { groupHooks?.turnFinished(failed, reply: nil, outcome: .failed) }
            } else {
                // The asker is gone: nobody wants the work.
                if envelope.groupID != nil, envelope.fromChat { groupChains.append(envelope.chainID) }
                requests[envelope.id]?.state = .cancelled
                requests[envelope.id]?.finishedAt = .now
                queues[envelope.to.id]?.removeAll { $0 == envelope.id }
                // A target that waited for its own helpers keeps its conversation in memory: its open lines close on disk too.
                closeSuspended(request, as: .cancelled)
                waitingSince[envelope.id] = nil
                if was == .running { running.append(envelope.to.id) }
                else if envelope.groupID != nil { groupHooks?.turnFinished(requests[envelope.id] ?? request, reply: nil, outcome: .cancelled) }
            }
        }
        inbox[id] = nil
        queues[id] = nil
        model?.workJournal.dropPendingReplies(forBot: id)
        // A request the group took from this Orb's chat has no one left to answer: the whole group request stops (and says so
        // in its thread), instead of only the orchestrator's turn while the members go on.
        for chain in Set(groupChains) { cancelChain(chain, by: .user) }
        for botID in running { model?.session(botID).stop(startsQueuedRoutines: false) }
        for (routineID, wait) in waitingRoutines where wait.botID == id { waitingRoutines[routineID] = nil }
        refresh(Array(Set(affected.flatMap { [$0.envelope.from.id, $0.envelope.to.id] })))
        settleWaitingRoutines()
    }

    /// A group request whose target is no longer a member (removed while the request waited or queued).
    func leftItsGroup(_ request: DelegationRequest) -> Bool {
        guard let groupID = request.envelope.groupID else { return false }
        return model?.group(groupID)?.memberIDs.contains(request.envelope.to.id) != true
    }

    /// Ends such a request as failed without resuming it. Its kept conversation is thrown away, not closed on disk: writing it
    /// would recreate the side file that leaving the group deleted.
    func dropLeftMember(_ request: DelegationRequest) {
        suspended[request.id] = nil
        fail(request, "Esse Orb saiu do grupo")
        groupHooks?.turnFinished(requests[request.id] ?? request, reply: nil, outcome: .failed)
    }

    /// The request waited for its children and will not resume: the conversation kept in memory for it is closed on disk, its
    /// open lines (the request itself and what it asked) now read `state`, so "Ver o trabalho" does not wait for an answer forever.
    func closeSuspended(_ request: DelegationRequest, as state: OrbMessageItem.State) {
        let id = request.id
        guard var conversation = suspended.removeValue(forKey: id) else { return }
        for child in request.openChildren { conversation.items.settingSent(child, to: state) }
        conversation.items.settingReceived(id, to: state)
        let envelope = request.envelope
        write(conversation, kind: envelope.groupID != nil ? .group : .delegation, runID: envelope.groupID ?? id, for: envelope.to.id)
    }

    /// Drops the duplicate-window records of requests that will not answer (failed or stopped), so the same ask can be redone.
    func forgetRepeats(of chain: ChainState) {
        guard !chain.recent.isEmpty else { return }
        for key in chain.recent.keys { recentFromChat[chain.originBot]?[key] = nil }
    }

    func forgetRepeat(_ request: DelegationRequest) {
        let envelope = request.envelope
        let key = DelegationRules.repeatKey(to: envelope.to.id, text: envelope.text, kind: envelope.kind)
        chainStates[envelope.chainID]?.recent[key] = nil
        recentFromChat[envelope.from.id]?[key] = nil
    }

    static let askerGoneReason = "Quem pediu não espera mais a resposta"

    /// A request that cannot go on (the target cannot start, time ran out): it ends `failed` and its asker is told.
    func fail(_ request: DelegationRequest, _ reason: String) {
        forgetRepeat(request)
        var failed = request
        failed.state = .failed
        failed.finishedAt = .now
        requests[request.id] = failed
        queues[request.envelope.to.id]?.removeAll { $0 == request.id }
        closeSuspended(request, as: .failed)
        waitingSince[request.id] = nil
        answer(failed, status: .failed, text: reason)
        if request.envelope.groupID != nil { groupHooks?.turnFinished(failed, reply: nil, outcome: .failed) }
        // What it asked and has not begun would work for nobody: those end with it (one already at work finishes its turn).
        for child in request.openChildren.compactMap({ requests[$0] }) where child.state == .queued {
            fail(child, Self.askerGoneReason)
        }
        refresh(request.envelope.from.id, request.envelope.to.id)
    }

    func noteSleep(from start: Date, to end: Date) {
        guard end > start else { return }
        sleeps.append(DateInterval(start: start, end: end))
    }

    /// Seconds from `date` to `now` that the Mac was awake for.
    func awake(since date: Date, now: Date) -> TimeInterval {
        let slept = sleeps.reduce(0) { total, sleep in
            let from = max(sleep.start, date), to = min(sleep.end, now)
            return to > from ? total + to.timeIntervalSince(from) : total
        }
        return max(0, now.timeIntervalSince(date) - slept)
    }

    /// Run by the scheduler every 30 seconds: a request that waited too long ends `failed`, and what is old and idle is forgotten.
    /// Waiting for work that goes on (a target busy with a turn, a child still at work) is not waiting too long: only
    /// `workTimeout` ends it. A request at work past `workTimeout` is not ended (turns have no limit): you are told, once,
    /// with a banner that can stop it.
    func sweep(now: Date = .now) {
        sleeps.removeAll { now.timeIntervalSince($0.end) > DelegationLimits.workTimeout + 3600 }
        for request in requests.values where request.state == .running && !toldStillRunning.contains(request.id) {
            guard let started = request.startedAt, awake(since: started, now: now) > DelegationLimits.workTimeout else { continue }
            toldStillRunning.insert(request.id)
            model?.notifyAboutTurn(of: request.envelope.to.id, Self.stillRunningNotice(request, after: awake(since: started, now: now)))
        }
        toldStillRunning = toldStillRunning.filter { requests[$0]?.state == .running }
        for request in requests.values where request.state == .queued {
            let waited = awake(since: request.envelope.sentAt, now: now)
            guard waited > DelegationLimits.requestTimeout else { continue }
            if waited <= DelegationLimits.workTimeout, isInTurn(request.envelope.to.id) { continue }
            fail(request, "Tempo esgotado")
        }
        let answered = Set(inbox.values.flatMap { $0.compactMap(\.servingRequest) })
        for (id, since) in waitingSince where awake(since: since, now: now) > DelegationLimits.requestTimeout {
            guard let request = requests[id], request.state == .awaitingChildren else { continue }
            if answered.contains(id) { continue }
            let working = request.openChildren.contains { requests[$0].map { Self.isOpen($0.state) } ?? false }
            if working, awake(since: since, now: now) <= DelegationLimits.workTimeout { continue }
            fail(request, "Tempo esgotado")
        }
        let busy = Set(requests.values.filter { Self.isOpen($0.state) }.map(\.envelope.chainID))
            .union(inbox.values.flatMap { $0.map(\.chainID) })
        for (id, chain) in chainStates where !busy.contains(id) && now.timeIntervalSince(chain.touched) > Self.chainRetention {
            chainStates[id] = nil
        }
        pruneRequests()
        cleanUpEndedFolderRuns()
    }

    /// A request that ended by any path (answered, cancelled, failed, timed out, target deleted) lets go of its folder and its
    /// worktree, like a group's run does: what is already in the project's HEAD is removed, the rest stays and the asker is told.
    func cleanUpEndedFolderRuns() {
        workFolders = workFolders.filter { requests[$0.key].map { Self.isOpen($0.state) } ?? false }
        guard let model else { return }
        let root = WorkFolders.root(in: model.store.directory)
        for (id, project) in folderRuns where !(requests[id].map { Self.isOpen($0.state) } ?? false) {
            folderRuns[id] = nil
            let asker = requests[id]?.envelope.from.id
            Task { @MainActor [weak model] in
                let report = await WorkFolders.cleanUp(project: project, run: id, root: root)
                guard let asker, !report.kept.isEmpty, let model else { return }
                let lines = report.kept.map { "\($0.branch) (\($0.path))" }.joined(separator: "; ")
                model.appendToChat(.notice("Ficaram ramos de trabalho sem merge em \(project.lastPathComponent): \(lines). "
                    + "Junte com git merge ou apague com git worktree remove."), of: asker)
            }
        }
    }

    /// The banner of a request still at work after `elapsed` seconds.
    static func stillRunningNotice(_ request: DelegationRequest, after elapsed: TimeInterval) -> String {
        let envelope = request.envelope
        return "\(envelope.to.name) está há \(Int(elapsed / 3600)) h no pedido de \(envelope.from.name) e continua trabalhando. "
            + "Se não era para isso, use Parar."
    }

    /// The finished requests are kept for the chains' sake and for the tests, but not forever.
    func pruneRequests() {
        guard requests.count > Self.keptRequests else { return }
        let done = requests.values.filter { !Self.isOpen($0.state) }.sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        for request in done.prefix(requests.count - Self.keptRequests) { requests[request.id] = nil }
    }

    // MARK: Questions

    func chains(involving botID: UUID) -> [UUID] {
        var result: [UUID] = []
        func add(_ id: UUID) { if !result.contains(id) { result.append(id) } }
        let mine = requests.values.filter { Self.isOpen($0.state) && ($0.envelope.from.id == botID || $0.envelope.to.id == botID) }
            .sorted(by: Self.older)
        for request in mine { add(request.envelope.chainID) }
        for reply in inbox[botID] ?? [] { add(reply.chainID) }
        return result
    }

    func openRequests(from botID: UUID) -> [DelegationRequest] {
        requests.values.filter { Self.isOpen($0.state) && $0.envelope.kind == .ask && $0.envelope.from.id == botID && $0.envelope.to.id != botID }
            .sorted(by: Self.older)
    }

    func roster(for botID: UUID, groupID: UUID?) -> [OrbRef] {
        guard let model else { return [] }
        if let groupID {
            guard let group = model.groups.first(where: { $0.id == groupID }) else { return [] }
            return group.memberIDs.filter { $0 != botID }.compactMap { model.bot($0).map(OrbRef.init) }
        }
        guard model.orbsCanTalk else { return [] }
        return model.bots.filter { $0.id != botID }.map(OrbRef.init)
    }

    /// Whether the Orb waits for an answer in the chain. A request a member sent its group from its chat does not count: what
    /// waits is its chat, so inside the group the orchestrator may still hand it work.
    func waiting(_ botID: UUID, inChain chainID: UUID) -> Bool {
        requests.values.contains {
            Self.isOpen($0.state) && $0.envelope.chainID == chainID && $0.envelope.from.id == botID && !$0.envelope.fromChat
        }
    }

    /// Whoever asked the request the Orb is serving, for the working line ("Pedido de Atlas").
    func requesterName(of botID: UUID) -> String? {
        guard let model, let serving = model.sessions[botID]?.servingRequest, model.sessions[botID]?.sideKind == .delegation,
              let envelope = requests[serving]?.envelope else { return nil }
        return model.bot(envelope.from.id)?.name ?? envelope.from.name
    }

    /// Oldest first (the id breaks a tie, so the order never depends on the dictionary).
    static func older(_ a: DelegationRequest, _ b: DelegationRequest) -> Bool {
        if a.envelope.sentAt != b.envelope.sentAt { return a.envelope.sentAt < b.envelope.sentAt }
        return a.id.uuidString < b.id.uuidString
    }

    static func isOpen(_ state: DelegationRequest.State) -> Bool {
        state == .queued || state == .running || state == .awaitingChildren
    }
}
