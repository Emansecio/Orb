import Foundation

/// The runtime of Orbs asking each other for work. A request (`orbs` ask or tell) waits in the target's queue and runs on the
/// target's own `BotSession` as a side run: the chat is parked, a conversation of its own (`pedido-<id>.json`) takes its place, the
/// permissions and mode are the target's. When the turn ends, the last thing the target said goes back to the asker as a reply
/// that wakes it (a new turn of its chat, or the continuation of the request it was serving when it asked). Nothing here is
/// saved but those conversations: requests in flight die with the app (`Conversation.closingInterruptedTurn`).
///
/// Without an `AppModel` it is the quiet shell the contract describes: it refuses everything and holds nothing.
@MainActor
final class DelegationHub: DelegationService {
    weak var groupHooks: GroupTurnHooks?
    private(set) weak var model: AppModel?
    /// Set while the app quits: the turns that end then are cut short and leave nobody to wake.
    var isShuttingDown = false

    /// A chain of requests: where it began, whether the person stopped it and what was just sent (to tell a repeat). It outlives
    /// its last request (a woken asker that asks again is still in it).
    struct ChainState {
        enum Origin: Equatable { case chat(UUID), routine(UUID), group(UUID) }

        var origin: Origin
        /// The Orb that began the chain: where "Você parou a conversa" is written.
        var originBot: UUID
        var groupID: UUID?
        var cancelled = false
        var recent: [String: Date] = [:]
        var touched = Date.now
    }

    private(set) var requests: [UUID: DelegationRequest] = [:]
    /// Per target: the requests waiting for it, oldest first.
    private(set) var queues: [UUID: [UUID]] = [:]
    /// Per Orb: the answers waiting to be handed to it.
    private(set) var inbox: [UUID: [OrbEnvelope]] = [:]
    /// Per Orb: the notices (`tell`) other Orbs left it outside a group, oldest first. A notice wakes nobody: it goes on top of
    /// the next message the Orb gets, whatever starts its next turn (`takeNotices`).
    private(set) var notices: [UUID: [OrbEnvelope]] = [:]
    private(set) var chainStates: [UUID: ChainState] = [:]
    /// The last `seenLimit` message ids, to tell a repeat from a new message.
    private(set) var seenMessageIDs: [UUID] = []
    /// The side conversation of a request that waits for its children, kept in memory so it resumes without a read.
    private var suspended: [UUID: Conversation] = [:]
    private var waitingSince: [UUID: Date] = [:]
    /// Orbs whose group turn is being prepared (its opening text is asked of the group, which may take a moment).
    private var starting: Set<UUID> = []
    /// Requests at work past `workTimeout` whose banner went out (once each).
    private(set) var toldStillRunning: Set<UUID> = []

    /// A routine's run that asked other Orbs and waits for their answers: its conversation, kept to resume from, and when the
    /// run began (its history counts the whole run). By routine id.
    struct RoutineWait {
        var botID: UUID
        var conversation: Conversation
        var started: Date
    }
    private(set) var waitingRoutines: [UUID: RoutineWait] = [:]

    static let seenLimit = 500
    /// Notices kept per Orb until its next turn (the oldest go first).
    static let noticeLimit = 10
    static let keptRequests = 300
    static let chainRetention: TimeInterval = 2 * 3600

    init(model: AppModel? = nil) { self.model = model }

    func isStarting(_ botID: UUID) -> Bool { starting.contains(botID) }

    /// Some request between Orbs is open (not a group's: groups do not depend on the switch).
    var hasActiveChains: Bool { requests.values.contains { Self.isOpen($0.state) && $0.envelope.groupID == nil } || inbox.values.contains { !$0.isEmpty } }

    // MARK: Asking

    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?) throws -> OrbEnvelope {
        guard let model, !isShuttingDown, let sender = model.bot(from) else { throw DelegationRefusal.switchedOff }
        let session = model.session(from)
        let context = session.chain
        let now = Date.now
        let group = groupID.flatMap { id in model.groups.first { $0.id == id } }
        let orbs = model.bots.map(OrbRef.init)
        var input = DelegationRules.Input(
            switchOn: model.orbsCanTalk, groupID: groupID, groupMembers: group.map { Set($0.memberIDs) }, orbs: orbs,
            sender: OrbRef(sender), targetName: name, text: text, kind: kind, messageID: messageID, context: context)
        input.groupNames = model.groups.map(\.name)
        input.groupName = (groupID ?? context?.groupID).flatMap { id in model.groups.first { $0.id == id }?.name }
        input.seenMessage = seenMessageIDs.contains(messageID)
        if let context, let state = chainStates[context.chainID] {
            input.chainStopped = state.cancelled
            input.waitingInPath = Set(context.path.filter { waiting($0, inChain: context.chainID) })
        }
        // The repeat needs the target, which the rules resolve: resolve it the same way here.
        if let target = DelegationRules.resolve(name, among: orbs), let context, let state = chainStates[context.chainID] {
            let key = DelegationRules.repeatKey(to: target.id, text: text)
            if let when = state.recent[key], now.timeIntervalSince(when) < DelegationRules.duplicateWindow { input.recentSameText = true }
        }
        let plan = try DelegationRules.validate(input)
        // MARK: MultiOrb (WP5): a request inside a group's chain also answers to the group's policy.
        if groupID ?? context?.groupID != nil,
           let refusal = groupHooks?.refusal(forRequestFrom: from, to: plan.target.id, chain: plan.chainID) { throw refusal }
        // MARK: end MultiOrb (WP5)

        var chain = chainStates[plan.chainID] ?? newChain(startedBy: sender, session: session, groupID: groupID ?? context?.groupID)
        chain.recent[DelegationRules.repeatKey(to: plan.target.id, text: plan.text)] = now
        chain.touched = now
        chainStates[plan.chainID] = chain
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.seenLimit { seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit) }

        var envelope = OrbEnvelope(id: messageID, chainID: plan.chainID, kind: kind, from: OrbRef(sender), to: plan.target,
                                   text: plan.text, hop: plan.hop, path: plan.path, servingRequest: session.servingRequest,
                                   groupID: groupID ?? context?.groupID, sentAt: now)
        if kind == .tell { return leaveNotice(envelope, session: session) }
        // A routine's run that asks is resumed by the answer (`holdRoutine`), so the answer must say which run it is for.
        if session.routineID != nil, session.sideKind == nil { envelope.servingRoutine = session.routineID }
        requests[envelope.id] = DelegationRequest(envelope: envelope, state: .queued)
        if let serving = envelope.servingRequest { requests[serving]?.openChildren.insert(envelope.id) }
        queues[plan.target.id, default: []].append(envelope.id)
        // What the asker's chat shows: "Atlas pediu ajuda ao Revisor" (the exchange lives in the lines, not in a card).
        session.append(.orbMessage(OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: envelope.from, to: plan.target,
                                                  text: plan.text, requestID: envelope.id, chainID: plan.chainID,
                                                  groupID: envelope.groupID)))
        model.live(from).poked()
        refresh(from, plan.target.id)
        schedulePump(plan.target.id)
        return envelope
    }

    /// A notice (`tell`) runs no turn. In a group it is a post in the thread, which the member's next turn reads with the rest
    /// of the thread; elsewhere it waits in the target's box for its next turn, and the target's chat shows it at once.
    private func leaveNotice(_ envelope: OrbEnvelope, session: BotSession) -> OrbEnvelope {
        guard let model else { return envelope }
        let line = OrbMessageItem(direction: .sent, kind: .tell, state: .replied, from: envelope.from, to: envelope.to,
                                  text: envelope.text, requestID: envelope.id, chainID: envelope.chainID, groupID: envelope.groupID)
        session.append(.orbMessage(line))
        if envelope.groupID != nil {
            groupHooks?.noticePosted(envelope)
        } else {
            var box = notices[envelope.to.id] ?? []
            box.append(envelope)
            notices[envelope.to.id] = Array(box.suffix(Self.noticeLimit))
            var received = line
            received.direction = .received
            appendToChat(of: envelope.to.id, .orbMessage(received))
            model.live(envelope.to.id).poked()
        }
        model.live(envelope.from.id).poked()
        return envelope
    }

    /// The notices waiting for the Orb, as the top of the message that starts its turn; nil when there are none. They are
    /// handed once. A group's turn takes none: they belong to the Orb's own work, not to the group's thread.
    func takeNotices(for botID: UUID) -> String? {
        let waiting = (notices.removeValue(forKey: botID) ?? []).filter { chainStates[$0.chainID]?.cancelled != true }
        return waiting.isEmpty ? nil : OrbEnvelopeText.notices(waiting)
    }

    /// A turn of a member of a group: the group's runtime asks the hub for it so the target's queue, its own conversation and the
    /// limits are the same as for any request. `askedBy` nil: the person asked (nobody gets a reply).
    func submitGroupTurn(member: UUID, text: String, chain context: ChainContext, groupID: UUID,
                         askedBy: UUID?) -> DelegationRequest {
        queueGroupTurn(member: member, text: text, chain: context, groupID: groupID, askedBy: askedBy, id: UUID(), fromChat: false)
    }

    func submitGroupRequest(from asker: UUID, text: String, chain context: ChainContext, groupID: UUID, orchestrator: UUID,
                            id: UUID) -> DelegationRequest {
        queueGroupTurn(member: orchestrator, text: text, chain: context, groupID: groupID, askedBy: asker, id: id, fromChat: true)
    }

    private func queueGroupTurn(member: UUID, text: String, chain context: ChainContext, groupID: UUID, askedBy: UUID?, id: UUID,
                                fromChat: Bool) -> DelegationRequest {
        let from = askedBy.flatMap { model?.bot($0) } ?? model?.bot(member)
        let target = model?.bot(member)
        // From the asker's own chat there is no request it serves: the answer wakes that chat.
        let serving = fromChat ? nil : context.serving ?? askedBy.flatMap { model?.session($0).servingRequest }
        var envelope = OrbEnvelope(
            id: id, chainID: context.chainID, kind: .ask, from: from.map(OrbRef.init) ?? OrbRef(id: askedBy ?? member, name: ""),
            to: target.map(OrbRef.init) ?? OrbRef(id: member, name: ""), text: text, hop: context.hop + 1,
            path: context.path.isEmpty ? [(askedBy ?? member)] : context.path,
            servingRequest: serving, groupID: groupID)
        envelope.fromChat = fromChat
        guard model != nil, target != nil, !isShuttingDown else { return DelegationRequest(envelope: envelope, state: .failed) }
        var chain = chainStates[context.chainID] ?? ChainState(origin: .group(context.chainID), originBot: askedBy ?? member,
                                                               groupID: groupID)
        chain.touched = .now
        chainStates[context.chainID] = chain
        guard !chain.cancelled else { return DelegationRequest(envelope: envelope, state: .cancelled) }
        let request = DelegationRequest(envelope: envelope, state: .queued)
        requests[envelope.id] = request
        if let serving = envelope.servingRequest { requests[serving]?.openChildren.insert(envelope.id) }
        queues[member, default: []].append(envelope.id)
        refresh(member)
        schedulePump(member)
        return request
    }

    func joinQueuedGroupTurn(member: UUID, chainID: UUID, text: String) -> DelegationRequest? {
        // Only the last in the member's queue: what others asked it in between keeps its place.
        guard let id = queues[member]?.last, let request = requests[id], request.state == .queued,
              request.envelope.chainID == chainID, request.envelope.groupID != nil, request.envelope.from.id == member,
              !request.envelope.fromChat else { return nil }
        requests[id]?.envelope.text = request.envelope.text + "\n\n" + text
        return requests[id]
    }

    // MARK: Running

    /// The Orb is free: takes the next request in its queue and runs it. True when a run began.
    func startNextRequest(for botID: UUID) -> Bool {
        guard let model, !isShuttingDown else { return false }
        while let id = queues[botID]?.first {
            queues[botID]?.removeFirst()
            guard let request = requests[id], request.state == .queued else { continue }
            if chainStates[request.envelope.chainID]?.cancelled == true {
                requests[id]?.state = .cancelled
                continue
            }
            guard model.bot(botID) != nil else { fail(request, "Esse Orb foi apagado"); continue }
            if request.envelope.groupID != nil {
                startGroupRun(request)
                return true
            }
            let ready = startRun(request, conversation: Conversation(), text: OrbEnvelopeText.request(request.envelope),
                                 origin: .orb(request.envelope), resuming: false)
            if ready { return true }
        }
        if queues[botID]?.isEmpty == true { queues[botID] = nil }
        return false
    }

    /// A group turn opens with the text the group's runtime writes (the thread since the member last spoke, the board), asked
    /// first; the Orb is held meanwhile so nothing else takes it.
    private func startGroupRun(_ request: DelegationRequest) {
        guard let model else { return }
        let botID = request.envelope.to.id
        starting.insert(botID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The group's runtime writes the preface (the group, the thread since this Orb last spoke, the board); the request follows:
            // an assignment from another Orb as a request, the person's own message as it was typed.
            let preface = await self.groupHooks?.prompt(for: request, member: botID) ?? ""
            let envelope = request.envelope
            let body = envelope.from.id == envelope.to.id && !envelope.fromChat ? envelope.text : OrbEnvelopeText.request(envelope)
            let prompt = preface.isEmpty ? body : preface + "\n\n" + body
            // Read off the main thread while `starting` still holds the Orb, so nothing else takes it meanwhile.
            let read = await model.store.readSideConversationAsync(prefix: Store.grupoPrefix, id: envelope.groupID ?? request.id, for: botID)
            self.starting.remove(botID)
            guard let current = self.requests[request.id], current.state == .queued else { return self.schedulePump(botID) }
            if self.chainStates[current.envelope.chainID]?.cancelled == true {
                self.requests[current.id]?.state = .cancelled
                self.groupHooks?.turnFinished(current, reply: nil, outcome: .cancelled)
                return self.schedulePump(botID)
            }
            guard model.canTakeSideWork(botID) else { // another turn took the Orb while the text was written: it waits its turn
                self.queues[botID, default: []].insert(current.id, at: 0)
                return
            }
            model.addNotice(AppModel.labeled(read.notice, for: model.bot(botID)))
            let conversation = read.value?.closingInterruptedTurn(notice: BotSession.quitSideNotice) ?? Conversation()
            if !self.startRun(current, conversation: conversation, text: prompt, origin: .orb(current.envelope), resuming: false) {
                self.schedulePump(botID)
            }
        }
    }

    /// Starts (or resumes) a side run for `request` on its target: `text` is what the model is sent, `origin` how the
    /// conversation shows it. False when the turn could not begin (the request then failed and its asker was told).
    @discardableResult
    private func startRun(_ request: DelegationRequest, conversation: Conversation, text: String, origin: SendOrigin,
                          resuming: Bool) -> Bool {
        guard let model else { return false }
        let envelope = request.envelope
        let botID = envelope.to.id
        let session = model.session(botID)
        let kind: SideRunKind = envelope.groupID != nil ? .group : .delegation
        let runID = envelope.groupID ?? envelope.id
        let path = envelope.path.last == botID ? envelope.path : envelope.path + [botID]
        let context = ChainContext(chainID: envelope.chainID, hop: envelope.hop, path: path, groupID: envelope.groupID,
                                   serving: envelope.id)
        session.ensureLoaded() // the chat that is parked must be the whole chat
        session.startRoutineRun(runID, conversation: conversation, at: .now, kind: kind, chain: context, serving: envelope.id)
        var running = request
        running.state = .running
        running.startedAt = request.startedAt ?? .now
        requests[envelope.id] = running
        waitingSince[envelope.id] = nil
        chainStates[envelope.chainID]?.touched = .now
        if kind == .group { groupHooks?.turnStarted(running) }
        guard model.send(text, to: botID, origin: origin) else {
            session.endSideRun()
            session.scheduleSave(delay: 0)
            fail(running, "Não consegui começar: confira o modelo em Ajustes")
            return false
        }
        if !resuming {
            let item = TranscriptItem(.event(OrbEvent(kind: .delegationReceived, actor: envelope.from, subject: envelope.to,
                                                      requestID: envelope.id, chainID: envelope.chainID, groupID: envelope.groupID)))
            if envelope.from.id != envelope.to.id, envelope.groupID == nil {
                session.parkedChat?.items.append(item)
                if let chat = session.parkedChat { model.store.save(chat, for: botID) }
            }
        }
        let live = model.live(botID)
        live.poked()
        refresh(botID, envelope.from.id)
        return true
    }

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
                let said = reply.map { OrbEnvelopeText.sanitize($0) } ?? ""
                outcome = succeeded ? (.ok, said.isEmpty ? "Concluí, sem nada a relatar." : said)
                    // What it got to say (a task stopped at the step limit says how far it went) goes with the reason.
                    : (.failed, Self.failedLead + Self.reason(in: own) + (said.isEmpty ? "" : "\n\n" + said))
            }
        }
        own.items.settingReceived(requestID, to: !finished ? .cancelled : waits ? .open : (outcome?.status == .ok ? .replied : .failed))
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
                let said = reply.map { OrbEnvelopeText.sanitize($0) } ?? ""
                groupHooks?.turnFinished(waiting, reply: succeeded && !said.isEmpty ? said : nil, outcome: succeeded ? .ok : .failed)
            }
        } else if let outcome, finished {
            var done = current
            done.state = outcome.status == .ok ? .replied : .failed
            done.finishedAt = .now
            requests[requestID] = done
            answer(done, status: outcome.status, text: outcome.text)
            if kind == .group { groupHooks?.turnFinished(done, reply: outcome.status == .ok ? outcome.text : nil, outcome: outcome.status) }
        } else if kind == .group, current.state == .cancelled || current.state == .failed {
            groupHooks?.turnFinished(current, reply: nil, outcome: current.state == .cancelled ? .cancelled : .failed)
        }
        pruneRequests()
        refresh(botID, current.envelope.from.id, current.envelope.to.id)
    }

    private func write(_ conversation: Conversation, kind: SideRunKind, runID: UUID, for botID: UUID) {
        guard let model else { return }
        switch kind {
        case .delegation: model.store.saveSideConversation(conversation, prefix: Store.pedidoPrefix, id: runID, for: botID)
        case .group: model.store.saveSideConversation(conversation, prefix: Store.grupoPrefix, id: runID, for: botID)
        case .routine: break
        }
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

    /// The reply of `request` goes to the asker's inbox (a `tell`, a group turn the person asked for and a chain that was stopped
    /// have nobody to answer). A request a member sent its group from its chat is answered by the group, in that chat, even when
    /// the member is the orchestrator itself.
    private func answer(_ request: DelegationRequest, status: OrbEnvelope.ReplyStatus, text: String) {
        let envelope = request.envelope
        guard envelope.kind == .ask, envelope.from.id != envelope.to.id || envelope.fromChat, let model, !isShuttingDown,
              model.bot(envelope.from.id) != nil, chainStates[envelope.chainID]?.cancelled != true else { return }
        let name = displayName(of: envelope)
        var reply = OrbEnvelope(chainID: envelope.chainID, kind: .reply, from: OrbRef(id: envelope.to.id, name: name),
                                to: envelope.from, text: Conversation.clipped(text, to: DelegationLimits.replyLimit),
                                hop: envelope.hop, path: envelope.path, replyTo: envelope.id,
                                servingRequest: envelope.servingRequest, status: status, groupID: envelope.groupID)
        reply.servingRoutine = envelope.servingRoutine
        reply.fromChat = envelope.fromChat // the chat's line names the group that answered
        inbox[envelope.from.id, default: []].append(reply)
        markArrived(reply)
        refresh(envelope.from.id)
        schedulePump(envelope.from.id)
    }

    /// The asker's line for the request reads answered as soon as the answer arrives, even when the asker is woken only once the
    /// rest of what it asked is in (`deliverInbox`): in its chat, in the conversation a request keeps while it waits, or in a
    /// routine's run that waits.
    private func markArrived(_ reply: OrbEnvelope) {
        let requestID = reply.replyTo ?? reply.id, state = SendOrigin.state(of: reply.status)
        if let serving = reply.servingRequest {
            suspended[serving]?.items.settingSent(requestID, to: state)
        } else if let routine = reply.servingRoutine {
            waitingRoutines[routine]?.conversation.items.settingSent(requestID, to: state)
        } else {
            markSent(requestID, asker: reply.to.id, as: state)
        }
    }

    /// Something the Orb asked for the same work as `reply` (the same request it serves, routine run or chat) is still open.
    private func stillAwaited(like reply: OrbEnvelope, by botID: UUID) -> Bool {
        requests.values.contains { request in
            let envelope = request.envelope
            return Self.isOpen(request.state) && envelope.kind == .ask && envelope.from.id == botID
                && (envelope.from.id != envelope.to.id || envelope.fromChat)
                && envelope.servingRequest == reply.servingRequest && envelope.servingRoutine == reply.servingRoutine
        }
    }

    static let failedLead = "Não consegui: "

    /// Hands the Orb the answers waiting for it, when it is free: up to `wakeBatch` of the same continuation at once. An answer to
    /// a request the Orb was serving resumes that request's conversation; any other wakes the chat. True when a turn began.
    func deliverInbox(for botID: UUID) -> Bool {
        guard let model, !isShuttingDown else { return false }
        var waiting = (inbox[botID] ?? []).filter { chainStates[$0.chainID]?.cancelled != true }
        // The answers of work whose other answers are still to come stay in the box: the Orb is woken once, with all of them.
        var held: [OrbEnvelope] = []
        while let first = waiting.first {
            let sameWork = waiting.filter { $0.servingRequest == first.servingRequest && $0.servingRoutine == first.servingRoutine }
            let ids = Set(sameWork.map(\.id))
            waiting.removeAll { ids.contains($0.id) }
            if stillAwaited(like: first, by: botID) {
                held += sameWork
                continue
            }
            let batch = Array(sameWork.prefix(DelegationLimits.wakeBatch))
            held += sameWork.dropFirst(DelegationLimits.wakeBatch)
            let rest = held + waiting
            inbox[botID] = rest.isEmpty ? nil : rest
            if let serving = first.servingRequest {
                guard var request = requests[serving], request.state == .awaitingChildren, var conversation = suspended[serving] else {
                    continue // the request it belonged to is gone (stopped, timed out): nobody waits for this answer
                }
                suspended[serving] = nil
                request.openChildren.subtract(batch.compactMap(\.replyTo))
                for reply in batch { conversation.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
                if startRun(request, conversation: conversation, text: OrbEnvelopeText.reply(batch), origin: .orbReply(batch),
                            resuming: true) { return true }
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
                                       text: OrbEnvelopeText.reply(batch, inRoutine: true), origin: .orbReply(batch)) {
                    refresh(botID)
                    return true
                }
                continue
            }
            let session = model.session(botID)
            session.ensureLoaded()
            let hop = max(0, first.hop - 1)
            // A group's answer to the chat (`OrbEnvelope.fromChat`) does not make the chat a turn of the group: what it asks next
            // begins a chain of its own.
            session.chain = first.groupID != nil ? nil : ChainContext(chainID: first.chainID, hop: hop, path: first.path, groupID: nil)
            session.servingRequest = nil
            for reply in batch {
                session.changeConversation { $0.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
            }
            chainStates[first.chainID]?.touched = .now
            if model.send(OrbEnvelopeText.reply(batch), to: botID, origin: .orbReply(batch)) {
                model.live(botID).glanced()
                refresh(botID)
                return true
            }
            session.chain = nil // no model: the notice says so, and the answers have nobody to wake
            continue
        }
        inbox[botID] = held.isEmpty ? nil : held
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

    /// The run of `routineID` asked something that is still open, or has an answer waiting to be handed to it.
    private func routineAwaits(_ routineID: UUID, of botID: UUID) -> Bool {
        requests.values.contains { Self.isOpen($0.state) && $0.envelope.servingRoutine == routineID && $0.envelope.from.id == botID }
            || (inbox[botID] ?? []).contains { $0.servingRoutine == routineID && chainStates[$0.chainID]?.cancelled != true }
    }

    /// The routine's run waits for answers from other Orbs (`holdRoutine`).
    func isWaiting(routine routineID: UUID) -> Bool { waitingRoutines[routineID] != nil }

    /// A waiting run whose answers will no longer come (its chain was stopped, the Orb it asked was deleted) ends now, with
    /// what it has; the app records it (`AppModel.closeRoutineRun`).
    private func settleWaitingRoutines() {
        guard let model, !isShuttingDown else { return }
        for (routineID, wait) in waitingRoutines where !routineAwaits(routineID, of: wait.botID) {
            waitingRoutines[routineID] = nil
            model.closeRoutineRun(routineID, of: wait.botID, conversation: wait.conversation, started: wait.started,
                                  why: "A resposta do outro Orb não veio: a conversa entre Orbs foi interrompida.")
        }
    }

    /// The routine was deleted, or the app quits: its waiting run is let go of. Returns what was kept, if anything.
    @discardableResult
    func forgetWaitingRoutine(_ routineID: UUID) -> RoutineWait? { waitingRoutines.removeValue(forKey: routineID) }

    // MARK: Stopping

    func cancelChain(_ id: UUID, by reason: CancelReason) {
        guard let model else { return }
        var chain = chainStates[id] ?? ChainState(origin: .group(id), originBot: UUID(), groupID: nil)
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
            if envelope.kind == .ask { markSent(envelope.id, asker: envelope.from.id, as: .cancelled) }
            if was == .running {
                running.append(envelope.to.id)
            } else if envelope.groupID != nil {
                groupHooks?.turnFinished(requests[envelope.id] ?? request, reply: nil, outcome: .cancelled)
            }
        }
        for botID in Array(notices.keys) {
            notices[botID]?.removeAll { $0.chainID == id }
            if notices[botID]?.isEmpty == true { notices[botID] = nil }
        }
        for botID in Array(inbox.keys) {
            let before = inbox[botID]?.count ?? 0
            inbox[botID]?.removeAll { $0.chainID == id }
            if inbox[botID]?.isEmpty == true { inbox[botID] = nil }
            if (inbox[botID]?.count ?? 0) != before { touched.insert(botID) }
        }
        // Their requests are marked first, so the end of each turn finds nothing to answer.
        for botID in running {
            model.session(botID).stop(startsQueuedRoutines: false,
                                      notice: isShuttingDown ? BotSession.quitSideNotice
                                          : reason == .gaveUp ? ApprovalWait.gaveUpNotice : BotSession.stoppedNotice)
        }
        refresh(Array(touched))
        // A group's chain says it stopped in the group's own thread (`groupStopped`), never in its orchestrator's private chat.
        if reason == .user, chain.groupID == nil, !isShuttingDown, !alreadyCancelled, !open.isEmpty || hadInbox, model.bot(chain.originBot) != nil {
            appendToChat(of: chain.originBot, .event(OrbEvent(kind: .chainStopped, actor: model.bot(chain.originBot).map(OrbRef.init),
                                                              chainID: id)))
        }
        for botID in touched { schedulePump(botID) }
        // A group's chain stopped by the person from elsewhere (the Parar of whoever waits for it) stops the group.
        if reason == .user, chain.groupID != nil, !alreadyCancelled { groupHooks?.chainStopped(id) }
        settleWaitingRoutines()
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
                requests[envelope.id]?.state = .cancelled
                requests[envelope.id]?.finishedAt = .now
                queues[envelope.to.id]?.removeAll { $0 == envelope.id }
                suspended[envelope.id] = nil
                waitingSince[envelope.id] = nil
                if was == .running { running.append(envelope.to.id) }
                else if envelope.groupID != nil { groupHooks?.turnFinished(requests[envelope.id] ?? request, reply: nil, outcome: .cancelled) }
            }
        }
        inbox[id] = nil
        queues[id] = nil
        notices[id] = nil
        for botID in Array(notices.keys) { notices[botID]?.removeAll { $0.from.id == id } }
        for botID in running { model?.session(botID).stop(startsQueuedRoutines: false) }
        for (routineID, wait) in waitingRoutines where wait.botID == id { waitingRoutines[routineID] = nil }
        refresh(Array(Set(affected.flatMap { [$0.envelope.from.id, $0.envelope.to.id] })))
        settleWaitingRoutines()
    }

    /// The request waited for its children and will not resume: the conversation kept in memory for it is closed on disk, its
    /// open lines (the request itself and what it asked) now read `state`, so "Ver o trabalho" does not wait for an answer forever.
    private func closeSuspended(_ request: DelegationRequest, as state: OrbMessageItem.State) {
        let id = request.id
        guard var conversation = suspended.removeValue(forKey: id) else { return }
        for child in request.openChildren { conversation.items.settingSent(child, to: state) }
        conversation.items.settingReceived(id, to: state)
        let envelope = request.envelope
        write(conversation, kind: envelope.groupID != nil ? .group : .delegation, runID: envelope.groupID ?? id, for: envelope.to.id)
    }

    /// A request that cannot go on (the target cannot start, time ran out): it ends `failed` and its asker is told.
    private func fail(_ request: DelegationRequest, _ reason: String) {
        var failed = request
        failed.state = .failed
        failed.finishedAt = .now
        requests[request.id] = failed
        queues[request.envelope.to.id]?.removeAll { $0 == request.id }
        closeSuspended(request, as: .failed)
        waitingSince[request.id] = nil
        answer(failed, status: .failed, text: reason)
        if request.envelope.groupID != nil { groupHooks?.turnFinished(failed, reply: nil, outcome: .failed) }
        refresh(request.envelope.from.id, request.envelope.to.id)
    }

    /// Run by the scheduler every 30 seconds: a request that waited too long ends `failed`, and what is old and idle is forgotten.
    /// Waiting for work that goes on (a target busy with a turn, a child still at work) is not waiting too long: only
    /// `workTimeout` ends it. A request at work past `workTimeout` is not ended (turns have no limit): you are told, once,
    /// with a banner that can stop it.
    func sweep(now: Date = .now) {
        for request in requests.values where request.state == .running && !toldStillRunning.contains(request.id) {
            guard let started = request.startedAt, now.timeIntervalSince(started) > DelegationLimits.workTimeout else { continue }
            toldStillRunning.insert(request.id)
            model?.notifyAboutTurn(of: request.envelope.to.id, Self.stillRunningNotice(request, after: now.timeIntervalSince(started)))
        }
        toldStillRunning = toldStillRunning.filter { requests[$0]?.state == .running }
        for request in requests.values where request.state == .queued {
            let waited = now.timeIntervalSince(request.envelope.sentAt)
            guard waited > DelegationLimits.requestTimeout else { continue }
            if waited <= DelegationLimits.workTimeout, isInTurn(request.envelope.to.id) { continue }
            fail(request, "Tempo esgotado")
        }
        let answered = Set(inbox.values.flatMap { $0.compactMap(\.servingRequest) })
        for (id, since) in waitingSince where now.timeIntervalSince(since) > DelegationLimits.requestTimeout {
            guard let request = requests[id], request.state == .awaitingChildren else { continue }
            if answered.contains(id) { continue }
            let working = request.openChildren.contains { requests[$0].map { Self.isOpen($0.state) } ?? false }
            if working, now.timeIntervalSince(since) <= DelegationLimits.workTimeout { continue }
            fail(request, "Tempo esgotado")
        }
        let busy = Set(requests.values.filter { Self.isOpen($0.state) }.map(\.envelope.chainID))
            .union(inbox.values.flatMap { $0.map(\.chainID) })
        for (id, chain) in chainStates where !busy.contains(id) && now.timeIntervalSince(chain.touched) > Self.chainRetention {
            chainStates[id] = nil
        }
        pruneRequests()
    }

    /// The banner of a request still at work after `elapsed` seconds.
    static func stillRunningNotice(_ request: DelegationRequest, after elapsed: TimeInterval) -> String {
        let envelope = request.envelope
        return "\(envelope.to.name) está há \(Int(elapsed / 3600)) h no pedido de \(envelope.from.name) e continua trabalhando. "
            + "Se não era para isso, use Parar."
    }

    /// The finished requests are kept for the chains' sake and for the tests, but not forever.
    private func pruneRequests() {
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

    /// The Orb waits for this one (it asked and nobody answered yet).
    /// Whether the Orb waits for an answer in the chain. A request a member sent its group from its chat does not count: what
    /// waits is its chat, so inside the group the orchestrator may still hand it work.
    private func waiting(_ botID: UUID, inChain chainID: UUID) -> Bool {
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

    // MARK: The tool

    /// One call of the `orbs` tool for `botID` (both engines end up here). `ask` returns at once: the answer wakes the Orb later.
    func handleTool(_ arguments: JSONValue, orb botID: UUID, messageID: UUID = UUID()) async throws -> String {
        guard let model, model.bot(botID) != nil else { throw ToolError("Este Orb não existe mais.") }
        let groupID = model.session(botID).chain?.groupID
        switch arguments["action"]?.string?.lowercased() {
        case "list":
            guard model.orbsCanTalk || groupID != nil else { throw DelegationRefusal.switchedOff.toolError }
            return teammatesText(for: botID, groupID: groupID)
        case "create_group":
            do { return try createGroup(arguments, by: botID) } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "ask", "tell":
            let kind: OrbEnvelope.Kind = arguments["action"]?.string?.lowercased() == "tell" ? .tell : .ask
            let name = arguments["to"]?.string ?? "", text = arguments["message"]?.string ?? ""
            do {
                // Outside a group's turn, a group's name (that no Orb has) is a request to that group.
                if groupID == nil, let group = group(named: name) {
                    let envelope = try submitToGroup(group, from: botID, text: text, kind: kind, messageID: messageID)
                    return "Pedido enviado ao grupo \(group.name) (id \(envelope.shortID)): \(envelope.to.name) orquestra, o grupo "
                        + "trabalha no fio dele e a resposta final chega sozinha como mensagem; não espere nem repita o pedido. "
                        + "O usuário acompanha na tela do grupo."
                }
                let envelope = try submit(from: botID, to: name, text: text, kind: kind, messageID: messageID, groupID: groupID)
                return kind == .ask
                    ? "Pedido enviado a \(envelope.to.name) (id \(envelope.shortID)). A resposta chega sozinha como mensagem"
                        + (envelope.servingRoutine != nil ? " e retoma esta execução da rotina" : "")
                        + "; não espere nem repita o pedido. Termine o que puder sem ela."
                    : "Aviso deixado para \(envelope.to.name): \(envelope.groupID == nil ? "ele lê na próxima mensagem que receber" : "fica no fio do grupo, que ele lê no próximo turno"). tell não acorda; para acordar e ter resposta, use ask."
            } catch let refusal as DelegationRefusal {
                throw refusal.toolError
            }
        default:
            throw ToolError("Use action list, ask ou tell.")
        }
    }

    /// "- Pesquisador: Pesquisa na web e resume (livre)": the teammates, without ids or folders. Outside a group's turn, the
    /// groups the Orb is in come after them.
    func teammatesText(for botID: UUID, groupID: UUID?) -> String {
        guard let model else { return "" }
        let team = roster(for: botID, groupID: groupID).compactMap { model.bot($0.id) }
        let teammates = team.isEmpty ? "Não há outros Orbs." : team.prefix(DelegationLimits.rosterLimit * 4).map { orb in
            let role = MemoryText.clip(MemoryText.flatten(orb.role), DelegationLimits.roleClip)
            let state = groupID.map { groupStatus(of: orb.id, in: $0) } ?? status(of: orb.id)
            return "- \(orb.name)\(role.isEmpty ? "" : ": " + role) (\(state))"
        }.joined(separator: "\n")
        guard groupID == nil else { return teammates }
        let groups = model.groupLines(for: botID).prefix(OrbsPrompt.groupLimit).map { group in
            let lead = group.youOrchestrate ? "você orquestra" : "\(group.orchestrator) orquestra"
            return "- \(group.name): \(lead)" + (group.others.isEmpty ? "" : "; outros membros: " + group.others.joined(separator: ", "))
        }
        guard !groups.isEmpty else { return teammates }
        return teammates + "\n\nSeus grupos (o usuário inicia o trabalho de um grupo na tela dele; você não escreve no fio):\n"
            + groups.joined(separator: "\n")
    }

    /// "livre", "ocupado", or "espera aprovação do usuário": a card of its turn is open, so whoever waits for it waits for the
    /// person, not for the work.
    private func status(of botID: UUID) -> String {
        if model?.liveBot(botID)?.needsYou == true { return "espera aprovação do usuário" }
        return isBusy(botID) ? "ocupado" : "livre"
    }

    /// In a group's turn, what the member is doing for the group: each open assignment ("trabalhando em “…” (pedido de Atlas,
    /// há 4 min)"), and whether it waits for the person. With none, `status(of:)`.
    private func groupStatus(of botID: UUID, in groupID: UUID, now: Date = .now) -> String {
        var parts: [String] = []
        if model?.liveBot(botID)?.needsYou == true { parts.append("espera aprovação do usuário") }
        let open = requests.values.filter { $0.envelope.groupID == groupID && $0.envelope.to.id == botID && Self.isOpen($0.state) }
            .sorted(by: Self.older)
        parts += open.prefix(3).map { assignmentText($0, now: now) }
        if open.count > 3 { parts.append("e mais \(open.count - 3)") }
        return parts.isEmpty ? status(of: botID) : parts.joined(separator: "; ")
    }

    /// One open request as `list` tells it: what, for whom, since when.
    private func assignmentText(_ request: DelegationRequest, now: Date) -> String {
        let envelope = request.envelope
        let what = "“" + MemoryText.clip(MemoryText.flatten(envelope.text), 60) + "”"
        let who = envelope.from.id == envelope.to.id && !envelope.fromChat ? "pedido do usuário" : "pedido de \(currentName(envelope.from))"
        switch request.state {
        case .queued:
            return "na fila: \(what) (\(who))"
        case .awaitingChildren:
            let names = request.openChildren.compactMap { requests[$0].map { currentName($0.envelope.to) } }
            let waits = names.isEmpty ? "esperando respostas" : "esperando " + Self.list(Array(Set(names)).sorted())
            return "\(waits) em \(what) (\(who))"
        default:
            return "trabalhando em \(what) (\(who), \(Self.ago(request.startedAt ?? envelope.sentAt, now: now)))"
        }
    }

    /// "há menos de 1 min", "há 4 min", "há 2 h".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "há menos de 1 min" }
        return minutes < 120 ? "há \(minutes) min" : "há \(minutes / 60) h"
    }

    /// "A", "A e B", "A, B e C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " e " + last
    }

    private func isBusy(_ botID: UUID) -> Bool {
        isInTurn(botID) || !(queues[botID] ?? []).isEmpty
    }

    /// The Orb is in a turn (its own chat, a routine, a request), or one is starting.
    private func isInTurn(_ botID: UUID) -> Bool {
        guard let model else { return false }
        return model.isWorking(botID) || model.sessions[botID]?.turnTask != nil || starting.contains(botID)
    }

    // MARK: What the person sees

    /// A request between Orbs outside groups still open, as Ajustes lists it (a group's are on the group's screen).
    struct OpenTalk: Identifiable, Equatable {
        var id: UUID
        var chainID: UUID
        /// "Atlas → Pesquisador".
        var title: String
        /// "“Revise o texto” · trabalhando · há 4 min".
        var detail: String
    }

    /// The open requests outside groups, oldest first: who asked whom, what, where it stands and since when.
    func openTalks(now: Date = .now) -> [OpenTalk] {
        requests.values
            .filter { $0.envelope.groupID == nil && $0.envelope.kind == .ask && Self.isOpen($0.state)
                && chainStates[$0.envelope.chainID]?.cancelled != true }
            .sorted(by: Self.older)
            .map { request in
                let envelope = request.envelope
                let from = currentName(envelope.from) + (envelope.servingRoutine != nil ? " (rotina)" : "")
                let state: String = switch request.state {
                case .queued: "na fila"
                case .awaitingChildren:
                    "esperando " + Self.list(Array(Set(request.openChildren.compactMap { requests[$0].map { currentName($0.envelope.to) } })).sorted())
                default: "trabalhando"
                }
                let what = "“" + MemoryText.clip(MemoryText.flatten(envelope.text), 80) + "”"
                return OpenTalk(id: envelope.id, chainID: envelope.chainID, title: "\(from) → \(currentName(envelope.to))",
                                detail: "\(what) · \(state) · \(Self.ago(envelope.sentAt, now: now))")
            }
    }

    /// Writes the Orb's wait ("Esperando Pesquisador") and its partner to its live state (only what changed is written).
    func refresh(_ ids: UUID...) { refresh(ids) }

    func refresh(_ ids: [UUID]) {
        guard let model else { return }
        for id in Set(ids) {
            guard let live = model.liveBot(id) else { continue }
            let asks = openRequests(from: id)
            var names: [String] = []
            for request in asks {
                let name = displayName(of: request.envelope)
                if !names.contains(name) { names.append(name) }
            }
            live.setChainWork(Self.waitLine(names))
            live.isConversing = !asks.isEmpty
            live.setPartner(partner(of: id))
        }
    }

    /// The phrase of an Orb that waits: one name, two names, or a count.
    static func waitLine(_ names: [String]) -> WorkLine? {
        switch names.count {
        case 0: nil
        case 1: WorkLine(verb: "Esperando", target: names[0])
        case 2: WorkLine(verb: "Esperando", target: "\(names[0]) e \(names[1])")
        default: WorkLine(verb: "Esperando", target: "\(names.count) Orbs")
        }
    }

    private func partner(of botID: UUID) -> PartnerTint? {
        guard let model else { return nil }
        if let asked = openRequests(from: botID).first, let orb = model.bot(asked.envelope.to.id) {
            return PartnerTint(botID: orb.id, color: orb.orb.color)
        }
        let serving = requests.values.filter { $0.state == .running && $0.envelope.to.id == botID && $0.envelope.from.id != botID }
            .sorted(by: Self.older)
        if let first = serving.first, let orb = model.bot(first.envelope.from.id) {
            return PartnerTint(botID: orb.id, color: orb.orb.color)
        }
        return nil
    }

    // MARK: A group asked from a chat

    /// The group whose name this is, when no Orb has it.
    private func group(named name: String) -> OrbGroup? {
        guard let model, DelegationRules.resolve(name, among: model.bots.map(OrbRef.init)) == nil else { return nil }
        let wanted = DelegationRules.fold(name)
        guard !wanted.isEmpty else { return nil }
        return model.groups.first { DelegationRules.fold($0.name) == wanted }
    }

    /// `orbs ask` with the name of a group the Orb is in, from its own chat and in a turn the person started: a new request of
    /// the group (`GroupHub.postOrbRequest`), marked as the Orb's and handed to the orchestrator as data. The refusals say what
    /// to do instead; nothing changes when one is thrown.
    private func submitToGroup(_ group: OrbGroup, from botID: UUID, text raw: String, kind: OrbEnvelope.Kind,
                               messageID: UUID) throws -> OrbEnvelope {
        guard let model, !isShuttingDown, let sender = model.bot(botID) else { throw DelegationRefusal.switchedOff }
        let name = group.name
        guard kind == .ask else { throw DelegationRefusal.groupDoor(name, .tell) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupDoor(name, .switchedOff) }
        guard group.memberIDs.contains(botID) else { throw DelegationRefusal.groupDoor(name, .notMember) }
        guard model.isOwnChat(botID) else { throw DelegationRefusal.groupDoor(name, .notFromHere) }
        guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupDoor(name, .notAsked) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal.emptyMessage }
        guard text.count <= DelegationLimits.messageLimit else { throw DelegationRefusal.tooLong }
        guard !seenMessageIDs.contains(messageID) else { throw DelegationRefusal.duplicate }
        guard let request = model.groupHub.postOrbRequest(from: botID, text: text, to: group.id, messageID: messageID) else {
            throw DelegationRefusal.groupDoor(name, .unavailable)
        }
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.seenLimit { seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit) }
        let envelope = request.envelope
        // The asker's chat: "Atlas pediu ao Estúdio" (the group's name, the orchestrator's color).
        model.session(botID).append(.orbMessage(OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: OrbRef(sender),
                                                               to: OrbRef(id: envelope.to.id, name: name), text: text,
                                                               requestID: envelope.id, chainID: envelope.chainID,
                                                               groupID: group.id, fromChat: true)))
        model.live(botID).poked()
        refresh(botID)
        return envelope
    }

    /// `group_create`: a group of the user's Orbs, made from the Orb's own chat in a turn the person started. The refusals say
    /// what to do instead; nothing is created when one is thrown.
    private func createGroup(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model, !isShuttingDown else { throw DelegationRefusal.groupSetup(.unavailable) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupSetup(.switchedOff) }
        guard model.isOwnChat(botID) else { throw DelegationRefusal.groupSetup(.notFromHere) }
        guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupSetup(.notAsked) }
        let name = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DelegationRefusal.groupSetup(.noName) }
        let orbs = model.bots.map(OrbRef.init)
        // A name that an Orb or another group has would make `orbs ask` ambiguous.
        guard DelegationRules.resolve(name, among: orbs) == nil,
              !model.groups.contains(where: { DelegationRules.fold($0.name) == DelegationRules.fold(name) }) else {
            throw DelegationRefusal.groupSetup(.nameTaken(name))
        }
        var members: [OrbRef] = []
        for typed in arguments["members"]?.array?.compactMap(\.string) ?? [] {
            guard let orb = DelegationRules.resolve(typed, among: orbs) else { throw DelegationRefusal.unknownOrb(typed) }
            if !members.contains(where: { $0.id == orb.id }) { members.append(orb) }
        }
        guard OrbGroup.memberLimits.contains(members.count), var lead = members.first else {
            throw DelegationRefusal.groupSetup(.memberCount)
        }
        if let typed = arguments["orchestrator"]?.string, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let orb = DelegationRules.resolve(typed, among: members) else {
                throw DelegationRefusal.groupSetup(.orchestratorNotMember(typed))
            }
            lead = orb
        }
        guard let group = model.createGroup(name: name, members: members.map(\.id), orchestrator: lead.id,
                                            objective: arguments["objective"]?.string ?? "", createdBy: botID) else {
            throw DelegationRefusal.groupSetup(.unavailable)
        }
        let others = members.filter { $0.id != lead.id }.map(\.name)
        let next = members.contains(where: { $0.id == botID })
            ? "Para mandar o primeiro pedido, use orbs ask com to “\(group.name)”."
            : "Você não é membro: o usuário manda os pedidos na tela do grupo."
        return "Grupo \(group.name) criado: \(lead.name) orquestra; os outros membros são \(Self.list(others)). O usuário vê o grupo "
            + "na lateral. " + next
    }

    /// Who a request went to, as the asker reads it: the Orb, or the group for a request sent to one from a chat.
    private func displayName(of envelope: OrbEnvelope) -> String {
        if envelope.fromChat, let group = envelope.groupID.flatMap({ id in model?.groups.first { $0.id == id } }) { return group.name }
        return model?.bot(envelope.to.id)?.name ?? envelope.to.name
    }

    // MARK: Helpers

    /// The Orb's name now (it may have been renamed since the envelope was written).
    private func currentName(_ ref: OrbRef) -> String { model?.bot(ref.id)?.name ?? ref.name }

    private func newChain(startedBy sender: Bot, session: BotSession, groupID: UUID?) -> ChainState {
        let origin: ChainState.Origin = if let groupID { .group(groupID) }
            else if session.sideKind == .routine, let routine = session.routineID { .routine(routine) }
            else { .chat(sender.id) }
        return ChainState(origin: origin, originBot: sender.id, groupID: groupID)
    }

    /// Wakes the Orb's queue on the next turn of the main actor, never inside the call that changed it.
    private func schedulePump(_ botID: UUID) {
        Task { @MainActor [weak self] in self?.model?.startNextQueuedWork(for: botID) }
    }

    /// The asker's lines about `requestID` now read `state`, in the chat or in the chat a side run parked.
    private func markSent(_ requestID: UUID, asker: UUID, as state: OrbMessageItem.State) {
        guard let model, model.bot(asker) != nil else { return }
        let session = model.session(asker)
        func has(_ items: [TranscriptItem]) -> Bool {
            items.contains { if case .orbMessage(let m) = $0.kind { m.direction == .sent && m.requestID == requestID && m.state == .open } else { false } }
        }
        if session.isUnloaded { session.ensureLoaded() }
        if let conversation = session.conversation, has(conversation.items) {
            session.mutateItems { $0.settingSent(requestID, to: state) }
        }
        if let parked = session.parkedChat, has(parked.items) {
            session.parkedChat?.items.settingSent(requestID, to: state)
            if let chat = session.parkedChat { model.store.save(chat, for: asker) }
        }
    }

    /// Writes a line to the person's chat of `botID` (the parked one when a side run holds the Orb).
    private func appendToChat(of botID: UUID, _ kind: TranscriptItem.Kind) {
        guard let model else { return }
        let session = model.session(botID)
        if session.parkedChat != nil {
            session.parkedChat?.items.append(TranscriptItem(kind))
            if let chat = session.parkedChat { model.store.save(chat, for: botID) }
        } else {
            session.append(kind)
        }
    }
}

extension DelegationRequest {
    /// A request is its envelope's message: the id it is kept, queued and answered by.
    var id: UUID { envelope.id }
}

