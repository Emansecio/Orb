import Foundation

// Reply handling, inbox batching, artifact collection, long-reply spill, routine/pulse waits, and pendingReply recovery.
extension DelegationHub {
    /// The turn of a side run ended (`BotSession.finishTurn`). The side conversation is saved and the chat comes back; then, in
    /// this order: a chain that was stopped only cleans up; a request whose children are still open waits for them; anything
    /// else answers the asker with the last thing the Orb said.
    func finishSideRun(_ botID: UUID, runID: UUID, kind: SideRunKind, serving: UUID?, succeeded: Bool, userStopped: Bool,
                       reply: String?) {
        guard let model else { return }
        let session = model.session(botID)
        let requestID = serving ?? runID
        var own = session.conversation ?? Conversation()
        let request = requests[requestID]
        if userStopped, let request, request.state == .running, chainStates[request.envelope.chainID]?.cancelled != true {
            cancelChain(request.envelope.chainID, by: .user)
        }
        let current = requests[requestID]
        let finished = current.map { [.running, .awaitingChildren].contains($0.state) && chainStates[$0.envelope.chainID]?.cancelled != true } ?? false
        var outcome: (status: OrbEnvelope.ReplyStatus, text: String)?
        var waits = false
        if finished, let current {
            if !current.openChildren.isEmpty || inbox[botID]?.contains(where: { $0.servingRequest == requestID }) == true {
                waits = true
            } else {
                let said = reply.map { OrbEnvelopeText.plain($0) } ?? ""
                outcome = succeeded ? (.ok, said.isEmpty ? "Concluí, sem nada a relatar." : said)
                    // What it got to say (a task stopped at the step limit says how far it went) goes with the reason.
                    : (.failed, Self.failedLead + Self.reason(in: own) + (said.isEmpty ? "" : "\n\n" + said))
            }
        }
        let produced = Self.producedArtifacts(in: own)
        own.items.settingReceived(requestID, to: !finished ? .cancelled : waits ? .open : (outcome?.status == .ok ? .replied : .failed))
        if !waits { workFolders[requestID] = nil } // a request that waits for its children resumes in the same folder
        // The conversation of the run goes to its file; the chat comes back.
        write(own, kind: kind, runID: runID, for: botID)
        if waits { suspended[requestID] = own }
        // A member has one conversation per group, which every turn of it in the group shares: a request of the member that
        // waits there keeps a copy to resume from, and this turn, which began from the file, holds that copy and more. The copy
        // follows, so the turn that resumes later does not write this one away.
        if kind == .group {
            for (id, _) in suspended where id != requestID {
                guard let waiting = requests[id], waiting.envelope.to.id == botID, waiting.envelope.groupID == runID else { continue }
                suspended[id] = own
            }
        }
        session.unparkChat()
        session.scheduleSave(delay: 0)
        if session.hasUnsavedStretch() { session.scheduleMemorySave() }
        // A request that is answered is over, and so is its tab in the Orb's browser (one that waits for its children keeps it).
        if kind == .delegation, !waits { model.endBrowserConversation(own, of: botID) }
        if kind == .delegation { model.store.prunePedidos(for: botID, keeping: DelegationLimits.keptPedidos) }

        guard let current else { refresh(botID); return }
        if waits {
            var waiting = current
            waiting.state = .awaitingChildren
            requests[requestID] = waiting
            waitingSince[requestID] = .now
            if kind == .group { // MultiOrb (WP5): what it said before waiting is interim speech (the request is `awaitingChildren`)
                let said = reply.map { OrbEnvelopeText.plain($0) } ?? ""
                groupHooks?.turnFinished(waiting, reply: succeeded && !said.isEmpty ? said : nil, outcome: succeeded ? .ok : .failed)
            }
        } else if let outcome, finished {
            var done = current
            done.state = outcome.status == .ok ? .replied : .failed
            done.finishedAt = .now
            requests[requestID] = done
            answer(done, status: outcome.status, text: outcome.text, artifacts: produced)
            if kind == .group { groupHooks?.turnFinished(done, reply: outcome.status == .ok ? outcome.text : nil, outcome: outcome.status) }
        } else if kind == .group, current.state == .cancelled || current.state == .failed {
            groupHooks?.turnFinished(current, reply: nil, outcome: current.state == .cancelled ? .cancelled : .failed)
        }
        pruneRequests()
        refresh(botID, current.envelope.from.id, current.envelope.to.id)
    }

    /// Unique file paths produced by tool calls during a side-run, capped at `DelegationLimits.maxArtifacts`.
    static func producedArtifacts(in conversation: Conversation) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for item in conversation.items {
            guard case .tool(let call) = item.kind else { continue }
            for file in call.files ?? [] where !file.path.isEmpty && seen.insert(file.path).inserted {
                paths.append(file.path)
                if paths.count >= DelegationLimits.maxArtifacts { return paths }
            }
        }
        return paths
    }

    /// Why a run failed, in the words the conversation already has ("Não deu certo: …" without its lead).
    static func reason(in conversation: Conversation) -> String {
        for item in conversation.items.reversed() {
            guard case .notice(let text) = item.kind, !text.hasPrefix(Conversation.routineRunMarker) else { continue }
            let lead = "Não deu certo: "
            let why = text.replacing(AgentEngine.continueHint, with: "")
            return why.hasPrefix(lead) ? String(why.dropFirst(lead.count)) : why
        }
        return "o pedido não terminou."
    }

    // MARK: Answering

    /// Spills an oversized reply to `saidas/<receiverID>/resposta-<requestID>.md` so the receiver can read the full text on demand
    /// and `ToolOutputCap.cleanUp` automatically prunes it after 14 days. The whole id: the four characters the tags show
    /// repeat among the replies kept there, and the later one would overwrite the earlier.
    private func spillReplyIfNeeded(_ text: String, requestID: UUID, receiverID: UUID) -> String? {
        guard text.count > DelegationLimits.replyLimit, let model else { return nil }
        let folder = ToolOutputCap.directory(inDataFolder: model.store.directory)
            .appending(path: receiverID.uuidString)
        let fileURL = folder.appending(path: "resposta-\(requestID.uuidString.lowercased()).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    /// The reply of `request` goes to the asker's inbox (a `tell`, a group turn the person asked for and a chain that was stopped
    /// have nobody to answer). A request a member sent its group from its chat is answered by the group, in that chat, even when
    /// the member is the orchestrator itself.
    func answer(_ request: DelegationRequest, status: OrbEnvelope.ReplyStatus, text: String, artifacts: [String] = []) {
        let envelope = request.envelope
        guard envelope.kind == .ask, envelope.from.id != envelope.to.id || envelope.fromChat, let model, !isShuttingDown,
              model.bot(envelope.from.id) != nil, chainStates[envelope.chainID]?.cancelled != true else { return }
        let name = displayName(of: envelope)
        let fullPath = spillReplyIfNeeded(text, requestID: envelope.id, receiverID: envelope.from.id)
        var reply = OrbEnvelope(chainID: envelope.chainID, kind: .reply, from: OrbRef(id: envelope.to.id, name: name),
                                to: envelope.from, text: DelegationRules.clippedReply(text, fullPath: fullPath),
                                hop: envelope.hop, path: envelope.path, replyTo: envelope.id,
                                servingRequest: envelope.servingRequest, status: status, groupID: envelope.groupID)
        reply.servingRoutine = envelope.servingRoutine
        reply.servingPulse = envelope.servingPulse
        reply.fromChat = envelope.fromChat // the chat's line names the group that answered
        reply.chat = envelope.chat
        reply.artifacts = Array(artifacts.prefix(DelegationLimits.maxArtifacts))
        reply.fullReplyPath = fullPath
        inbox[envelope.from.id, default: []].append(reply)
        // Persist top-level chat replies so a restart during fan-out does not discard already-completed teammate work.
        model.workJournal.replyPending(reply)
        markArrived(reply)
        refresh(envelope.from.id)
        schedulePump(envelope.from.id)
    }

    /// Restores a top-level reply that was waiting in `inbox` when the app closed (`WorkJournal` `.pendingReply`).
    /// Returns false when the receiver is gone or delegation is switched off.
    @discardableResult
    func restorePendingReply(_ reply: OrbEnvelope) -> Bool {
        guard let model, !isShuttingDown, model.orbsCanTalk, reply.kind == .reply,
              model.bot(reply.to.id) != nil else { return false }
        if reply.pulseRun != nil, !model.pulseIsOn || model.pulseBudgetSpent { return false }
        if inbox[reply.to.id]?.contains(where: { $0.id == reply.id }) == true { return true }
        var chain = chainStates[reply.chainID]
            ?? ChainState(origin: reply.pulseRun.map { .pulse($0) } ?? .chat(reply.to.id), originBot: reply.to.id,
                          groupID: nil, chat: reply.chat)
        chain.touched = .now
        chainStates[reply.chainID] = chain
        inbox[reply.to.id, default: []].append(reply)
        markArrived(reply)
        refresh(reply.to.id)
        schedulePump(reply.to.id)
        return true
    }

    /// The asker's line for the request reads answered as soon as the answer arrives, even when the asker is woken only once the
    /// rest of what it asked is in (`deliverInbox`): in its chat, in the conversation a request keeps while it waits, or in a
    /// routine's run that waits.
    private func markArrived(_ reply: OrbEnvelope) {
        let requestID = reply.replyTo ?? reply.id, state = SendOrigin.state(of: reply.status)
        if let serving = reply.servingRequest {
            suspended[serving]?.items.settingSent(requestID, to: state)
        } else if let run = reply.servingRun, waitingRoutines[run] != nil {
            waitingRoutines[run]?.conversation.items.settingSent(requestID, to: state)
        } else {
            markSent(requestID, asker: reply.to.id, as: state, in: reply.chat)
        }
    }

    /// Something the Orb asked for the same work as `reply` (the same request it serves, routine run or conversation) is
    /// still open.
    private func stillAwaited(like reply: OrbEnvelope, by botID: UUID) -> Bool {
        requests.values.contains { request in
            let envelope = request.envelope
            return Self.isOpen(request.state) && envelope.kind == .ask && envelope.from.id == botID
                && (envelope.from.id != envelope.to.id || envelope.fromChat)
                && envelope.servingRequest == reply.servingRequest && envelope.servingRun == reply.servingRun
                && envelope.chat == reply.chat
        }
    }

    /// Hands the Orb the answers waiting for it, when it is free: up to `wakeBatch` of the same continuation at once. An answer to
    /// a request the Orb was serving resumes that request's conversation; any other wakes the conversation that asked (the
    /// latest, when that one was deleted), behind the one on show when that is another. True when a turn began.
    func deliverInbox(for botID: UUID) -> Bool {
        guard let model, !isShuttingDown else { return false }
        let raw = inbox[botID] ?? []
        var waiting: [OrbEnvelope] = []
        for item in raw {
            if chainStates[item.chainID]?.cancelled == true {
                model.workJournal.dropPendingReply(item.id)
            } else {
                waiting.append(item)
            }
        }
        // The answers of work whose other answers are still to come stay in the box: the Orb is woken once, with all of them.
        var held: [OrbEnvelope] = []
        while let first = waiting.first {
            let sameWork = waiting.filter {
                $0.servingRequest == first.servingRequest && $0.servingRun == first.servingRun && $0.chat == first.chat
            }
            let ids = Set(sameWork.map(\.id))
            waiting.removeAll { ids.contains($0.id) }
            if stillAwaited(like: first, by: botID) {
                held += sameWork
                continue
            }
            let batch = Array(sameWork.prefix(DelegationLimits.wakeBatch))
            let more = sameWork.count - batch.count // told with the batch, so the Orb does not conclude on part of the answers
            held += sameWork.dropFirst(DelegationLimits.wakeBatch)
            let rest = held + waiting
            inbox[botID] = rest.isEmpty ? nil : rest
            if let serving = first.servingRequest {
                guard var request = requests[serving], request.state == .awaitingChildren, var conversation = suspended[serving] else {
                    continue // the request it belonged to is gone (stopped, timed out): nobody waits for this answer
                }
                if leftItsGroup(request) {
                    dropLeftMember(request) // taken out of the group while it waited: it must not speak again
                    continue
                }
                suspended[serving] = nil
                request.openChildren.subtract(batch.compactMap(\.replyTo))
                for reply in batch { conversation.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
                if startRun(request, conversation: conversation, text: OrbEnvelopeText.reply(batch, more: more), origin: .orbReply(batch),
                            resuming: true) {
                    if let group = request.envelope.groupID { groupHooks?.repliesHanded(batch.compactMap(\.replyTo), to: botID, in: group) }
                    return true
                }
                continue
            }
            if let routine = first.servingRoutine {
                // The run of a routine that waits for these answers goes on in its own conversation; with no run waiting (it
                // ended, was deleted or stopped) nobody wants them.
                guard var wait = waitingRoutines.removeValue(forKey: routine) else { continue }
                for reply in batch { wait.conversation.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
                let chain = ChainContext(chainID: first.chainID, hop: max(0, first.hop - 1), path: first.path, groupID: nil)
                chainStates[first.chainID]?.touched = .now
                if model.resumeRoutine(routine, of: botID, conversation: wait.conversation, started: wait.started, chain: chain,
                                       text: OrbEnvelopeText.reply(batch, more: more, inRoutine: true), origin: .orbReply(batch)) {
                    refresh(botID)
                    return true
                }
                continue
            }
            // A pulse's run that waits goes on in the pulse's conversation. With none waiting (it was stopped, the app
            // reopened), the answer is not lost: it wakes the chat, as before the pulse could wait.
            if let pulse = first.servingPulse, var wait = waitingRoutines[pulse], let run = wait.pulse {
                waitingRoutines[pulse] = nil
                for reply in batch { wait.conversation.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
                let chain = ChainContext(chainID: first.chainID, hop: max(0, first.hop - 1), path: first.path, groupID: nil)
                chainStates[first.chainID]?.touched = .now
                if model.resumePulse(run, of: botID, conversation: wait.conversation, chain: chain,
                                     text: OrbEnvelopeText.reply(batch, more: more, inPulse: true), origin: .orbReply(batch)) {
                    refresh(botID)
                    return true
                }
                continue
            }
            let session = model.session(botID), chat = model.chatOrLatest(first.chat, of: botID)
            if chat != session.conversationChat {
                // Another conversation asked: it is read off the main thread while the Orb is held, then woken behind the one
                // on show. Taken by other work meanwhile, the answers wait in the box again.
                starting.insert(botID)
                Task { @MainActor [weak self] in
                    let ready = await model.prepareTurn(in: chat, of: botID)
                    guard let self else { return }
                    self.starting.remove(botID)
                    let wanted = !self.isShuttingDown && model.bot(botID) != nil && self.chainStates[first.chainID]?.cancelled != true
                    if ready, wanted, self.wake(botID, with: batch, more: more) {
                        for reply in batch { model.workJournal.dropPendingReply(reply.id) }
                        return
                    }
                    if ready { session.endWorkElsewhere() } // nothing began there: the one on show takes the turn machinery back
                    if !ready, wanted {
                        self.inbox[botID, default: []].insert(contentsOf: batch, at: 0)
                    } else if !wanted {
                        for reply in batch { model.workJournal.dropPendingReply(reply.id) }
                    }
                    self.schedulePump(botID)
                }
                return true
            }
            if wake(botID, with: batch, more: more) {
                for reply in batch { model.workJournal.dropPendingReply(reply.id) }
                return true
            }
            for reply in batch { model.workJournal.dropPendingReply(reply.id) }
        }
        inbox[botID] = held.isEmpty ? nil : held
        return false
    }

    /// The answers wake the conversation the turn machinery has: it goes on with them, as a turn of its own.
    private func wake(_ botID: UUID, with batch: [OrbEnvelope], more: Int) -> Bool {
        guard let model, let first = batch.first else { return false }
        let session = model.session(botID)
        session.ensureLoaded()
        let hop = max(0, first.hop - 1)
        // A group's answer to the chat (`OrbEnvelope.fromChat`) does not make the chat a turn of the group: what it asks next
        // begins a chain of its own.
        session.chain = first.groupID != nil ? nil : ChainContext(chainID: first.chainID, hop: hop, path: first.path, groupID: nil)
        session.usageChain = first.chainID
        session.servingRequest = nil
        for reply in batch {
            session.changeConversation { $0.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
        }
        chainStates[first.chainID]?.touched = .now
        if model.send(OrbEnvelopeText.reply(batch, more: more), to: botID, origin: .orbReply(batch)) {
            model.live(botID).glanced()
            refresh(botID)
            return true
        }
        session.chain = nil // no model: the notice says so, and the answers have nobody to wake
        session.usageChain = nil
        return false
    }

    // MARK: A routine that waits

    /// The run of `routineID` ended its turn having asked other Orbs: if an answer is still to come (or waits in the box), the
    /// run is not over. Its conversation is kept to resume from when the answers arrive (`deliverInbox`), and true is returned:
    /// the app does not record the run yet.
    func holdRoutine(_ routineID: UUID, of botID: UUID, conversation: Conversation, started: Date) -> Bool {
        guard !isShuttingDown, routineAwaits(routineID, of: botID) else { return false }
        waitingRoutines[routineID] = RoutineWait(botID: botID, conversation: conversation, started: started)
        schedulePump(botID)
        return true
    }

    /// The pulse's run ended its turn having asked other Orbs: as a routine's (`holdRoutine`), it waits for the answers in its
    /// own conversation, and they resume it (`AppModel.resumePulse`). True: the app does not close the run yet.
    func holdPulse(_ run: PulseRun, of botID: UUID, conversation: Conversation) -> Bool {
        guard !isShuttingDown, routineAwaits(run.id, of: botID) else { return false }
        waitingRoutines[run.id] = RoutineWait(botID: botID, conversation: conversation, started: run.startedAt, pulse: run)
        schedulePump(botID)
        return true
    }

    /// A turn of the chain of a waiting pulse used the model: its line shows the whole run's cost.
    func chargeWaitingPulse(_ runID: UUID, tokens: Int) {
        guard waitingRoutines[runID]?.pulse != nil else { return }
        waitingRoutines[runID]?.pulse?.tokens += tokens
    }

    /// A pulse of the Orb waits for answers: no other pulse may begin on it meanwhile.
    func hasWaitingPulse(of botID: UUID) -> Bool { waitingRoutines.values.contains { $0.botID == botID && $0.pulse != nil } }

    /// The run (a routine's or a pulse's) asked something that is still open, or has an answer waiting to be handed to it.
    private func routineAwaits(_ runID: UUID, of botID: UUID) -> Bool {
        requests.values.contains { Self.isOpen($0.state) && $0.envelope.servingRun == runID && $0.envelope.from.id == botID }
            || (inbox[botID] ?? []).contains { $0.servingRun == runID && chainStates[$0.chainID]?.cancelled != true }
    }

    /// The routine's run waits for answers from other Orbs (`holdRoutine`).
    func isWaiting(routine routineID: UUID) -> Bool { waitingRoutines[routineID] != nil }

    /// A waiting run whose answers will no longer come (its chain was stopped, the Orb it asked was deleted) ends now, with
    /// what it has; the app records it (`AppModel.closeRoutineRun`).
    func settleWaitingRoutines() {
        guard let model, !isShuttingDown else { return }
        for (routineID, wait) in waitingRoutines where !routineAwaits(routineID, of: wait.botID) {
            waitingRoutines[routineID] = nil
            let why = "A resposta do outro Orb não veio: a conversa entre Orbs foi interrompida."
            if let run = wait.pulse {
                model.closePulseWait(run, of: wait.botID, conversation: wait.conversation, why: why)
            } else {
                model.closeRoutineRun(routineID, of: wait.botID, conversation: wait.conversation, started: wait.started, why: why)
            }
        }
    }

    /// The routine was deleted, or the app quits: its waiting run is let go of. Returns what was kept, if anything.
    @discardableResult
    func forgetWaitingRoutine(_ routineID: UUID) -> RoutineWait? { waitingRoutines.removeValue(forKey: routineID) }

    /// The routine was deleted: what its run asked of other Orbs stops too (open requests and answers in the box), so the
    /// target does not spend a turn on an answer nobody will read. Only the chains the routine's run started.
    func cancelChains(servingRoutine routineID: UUID) {
        var ids: [UUID] = []
        for request in requests.values where Self.isOpen(request.state) && request.envelope.servingRoutine == routineID {
            if !ids.contains(request.envelope.chainID) { ids.append(request.envelope.chainID) }
        }
        for envelope in inbox.values.joined() where envelope.servingRoutine == routineID && !ids.contains(envelope.chainID) {
            ids.append(envelope.chainID)
        }
        for id in ids { cancelChain(id, by: .user) }
    }
}
