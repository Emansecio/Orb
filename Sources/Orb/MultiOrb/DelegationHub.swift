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

    /// Who sent to whom, in one chain.
    struct PairKey: Hashable { var from: UUID; var to: UUID }

    /// What a chain of requests has spent. It outlives its last request (a woken asker that asks again is still in it), so the
    /// limits cannot be started over by answering.
    struct ChainState {
        enum Origin: Equatable { case chat(UUID), routine(UUID), group(UUID) }

        var origin: Origin
        /// The Orb that began the chain: where "Você parou a conversa" is written.
        var originBot: UUID
        var groupID: UUID?
        var messages = 0
        var turns = 0
        var tokens = 0
        var cancelled = false
        var pairs: [PairKey: Int] = [:]
        var recent: [String: Date] = [:]
        var touched = Date.now

        var facts: DelegationRules.ChainFacts {
            DelegationRules.ChainFacts(messages: messages, turns: turns, tokens: tokens, cancelled: cancelled)
        }
    }

    private(set) var requests: [UUID: DelegationRequest] = [:]
    /// Per target: the requests waiting for it, oldest first.
    private(set) var queues: [UUID: [UUID]] = [:]
    /// Per Orb: the answers waiting to be handed to it.
    private(set) var inbox: [UUID: [OrbEnvelope]] = [:]
    private(set) var chainStates: [UUID: ChainState] = [:]
    /// The last `seenLimit` message ids, to tell a repeat from a new message.
    private(set) var seenMessageIDs: [UUID] = []
    /// The side conversation of a request that waits for its children, kept in memory so it resumes without a read.
    private var suspended: [UUID: Conversation] = [:]
    private var waitingSince: [UUID: Date] = [:]
    // MARK: MultiOrb (WP5)
    /// Queued group turns the group's runtime said not to start yet (its budget is spent or it is paused), by request id. They go
    /// back to their targets' queues on `resumeHeldWork` ("Continuar"); a stopped chain cancels them where they stand.
    private var held: [UUID] = []
    // MARK: end MultiOrb (WP5)
    /// Orbs whose group turn is being prepared (its opening text is asked of the group, which may take a moment).
    private var starting: Set<UUID> = []

    static let seenLimit = 500
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
        input.seenMessage = seenMessageIDs.contains(messageID)
        input.openFromSender = openRequests(from: from).count
        if let context, let state = chainStates[context.chainID] {
            input.chain = state.facts
            input.waitingInPath = Set(context.path.filter { waiting($0, inChain: context.chainID) })
        }
        // The pair and the repeat need the target, which the rules resolve: resolve it the same way here.
        if let target = DelegationRules.resolve(name, among: orbs), let context, let state = chainStates[context.chainID] {
            input.chain.pairCount = state.pairs[PairKey(from: from, to: target.id)] ?? 0
            let key = DelegationRules.repeatKey(to: target.id, text: text)
            if let when = state.recent[key], now.timeIntervalSince(when) < DelegationRules.duplicateWindow { input.recentSameText = true }
        }
        let plan = try DelegationRules.validate(input)
        // MARK: MultiOrb (WP5): a request inside a group's chain also answers to the group's budget and policy.
        if groupID ?? context?.groupID != nil,
           let refusal = groupHooks?.refusal(forRequestFrom: from, to: plan.target.id, chain: plan.chainID) { throw refusal }
        // MARK: end MultiOrb (WP5)

        var chain = chainStates[plan.chainID] ?? newChain(startedBy: sender, session: session, groupID: groupID ?? context?.groupID)
        chain.messages += 1
        chain.pairs[PairKey(from: from, to: plan.target.id), default: 0] += 1
        chain.recent[DelegationRules.repeatKey(to: plan.target.id, text: plan.text)] = now
        chain.touched = now
        chainStates[plan.chainID] = chain
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.seenLimit { seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit) }

        let envelope = OrbEnvelope(id: messageID, chainID: plan.chainID, kind: kind, from: OrbRef(sender), to: plan.target,
                                   text: plan.text, hop: plan.hop, path: plan.path, servingRequest: session.servingRequest,
                                   groupID: groupID ?? context?.groupID, sentAt: now)
        requests[envelope.id] = DelegationRequest(envelope: envelope, state: .queued)
        if kind == .ask, let serving = envelope.servingRequest { requests[serving]?.openChildren.insert(envelope.id) }
        queues[plan.target.id, default: []].append(envelope.id)
        // What the asker's chat shows: "Atlas pediu ajuda ao Revisor" (the exchange lives in the lines, not in a card).
        session.append(.orbMessage(OrbMessageItem(direction: .sent, kind: kind == .ask ? .ask : .tell,
                                                  state: kind == .ask ? .open : .replied, from: envelope.from, to: plan.target,
                                                  text: plan.text, requestID: envelope.id, chainID: plan.chainID,
                                                  groupID: envelope.groupID)))
        model.live(from).poked()
        refresh(from, plan.target.id)
        schedulePump(plan.target.id)
        return envelope
    }

    /// A turn of a member of a group: the group's runtime asks the hub for it so the target's queue, its own conversation and the
    /// limits are the same as for any request. `askedBy` nil: the person asked (nobody gets a reply).
    func submitGroupTurn(member: UUID, text: String, chain context: ChainContext, groupID: UUID,
                         askedBy: UUID?) -> DelegationRequest {
        let from = askedBy.flatMap { model?.bot($0) } ?? model?.bot(member)
        let target = model?.bot(member)
        let envelope = OrbEnvelope(
            id: UUID(), chainID: context.chainID, kind: .ask, from: from.map(OrbRef.init) ?? OrbRef(id: askedBy ?? member, name: ""),
            to: target.map(OrbRef.init) ?? OrbRef(id: member, name: ""), text: text, hop: context.hop + 1,
            path: context.path.isEmpty ? [(askedBy ?? member)] : context.path,
            servingRequest: context.serving ?? askedBy.flatMap { model?.session($0).servingRequest }, groupID: groupID)
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
                // MultiOrb (WP5): the group's budget or pause may keep the turn waiting; it stays queued, off the queue, until "Continuar".
                if groupHooks?.canStartTurn(request) == false {
                    if !held.contains(id) { held.append(id) }
                    continue
                }
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
            let body = envelope.from.id == envelope.to.id ? envelope.text : OrbEnvelopeText.request(envelope)
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
            let conversation = read.value?.closingInterruptedTurn() ?? Conversation()
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
        chainStates[envelope.chainID]?.turns += 1
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
            } else if succeeded {
                let said = reply.map { OrbEnvelopeText.sanitize($0) } ?? ""
                outcome = (.ok, said.isEmpty ? "Concluí, sem nada a relatar." : said)
            } else {
                outcome = (.failed, "Não consegui: " + Self.reason(in: own))
            }
        }
        own.items.settingReceived(requestID, to: !finished ? .cancelled : waits ? .open : (outcome?.status == .ok ? .replied : .failed))
        // The conversation of the run goes to its file; the chat comes back.
        write(own, kind: kind, runID: runID, for: botID)
        if waits { suspended[requestID] = own }
        session.unparkChat()
        session.scheduleSave(delay: 0)
        if session.hasUnsavedStretch() { session.scheduleMemorySave() }
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
            return text.hasPrefix(lead) ? String(text.dropFirst(lead.count)) : text
        }
        return "o pedido não terminou."
    }

    // MARK: Answering

    /// The reply of `request` goes to the asker's inbox (a `tell`, a group turn the person asked for and a chain that was stopped
    /// have nobody to answer).
    private func answer(_ request: DelegationRequest, status: OrbEnvelope.ReplyStatus, text: String) {
        let envelope = request.envelope
        guard envelope.kind == .ask, envelope.from.id != envelope.to.id, let model, !isShuttingDown,
              model.bot(envelope.from.id) != nil, chainStates[envelope.chainID]?.cancelled != true else { return }
        let name = model.bot(envelope.to.id)?.name ?? envelope.to.name
        let reply = OrbEnvelope(chainID: envelope.chainID, kind: .reply, from: OrbRef(id: envelope.to.id, name: name),
                                to: envelope.from, text: Conversation.clipped(text, to: DelegationLimits.replyLimit),
                                hop: envelope.hop, path: envelope.path, replyTo: envelope.id,
                                servingRequest: envelope.servingRequest, status: status, groupID: envelope.groupID)
        inbox[envelope.from.id, default: []].append(reply)
        schedulePump(envelope.from.id)
    }

    /// Hands the Orb the answers waiting for it, when it is free: up to `wakeBatch` of the same continuation at once. An answer to
    /// a request the Orb was serving resumes that request's conversation; any other wakes the chat. True when a turn began.
    func deliverInbox(for botID: UUID) -> Bool {
        guard let model, !isShuttingDown else { return false }
        var waiting = (inbox[botID] ?? []).filter { chainStates[$0.chainID]?.cancelled != true }
        var heldBack: [OrbEnvelope] = [] // MultiOrb (WP5): answers inside a group's chain that the group does not let start a turn yet
        while let first = waiting.first {
            if let serving = first.servingRequest, first.groupID != nil, let request = requests[serving],
               groupHooks?.canStartTurn(request) == false {
                let same = waiting.filter { $0.servingRequest == serving }
                heldBack += same
                waiting.removeAll { reply in same.contains { $0.id == reply.id } }
                inbox[botID] = heldBack + waiting
                continue
            }
            let batch = Array(waiting.filter { $0.servingRequest == first.servingRequest }.prefix(DelegationLimits.wakeBatch))
            let taken = Set(batch.map(\.id))
            waiting.removeAll { taken.contains($0.id) }
            inbox[botID] = (heldBack + waiting).isEmpty ? nil : heldBack + waiting
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
            let session = model.session(botID)
            session.ensureLoaded()
            let hop = max(0, first.hop - 1)
            session.chain = ChainContext(chainID: first.chainID, hop: hop, path: first.path, groupID: first.groupID)
            session.servingRequest = nil
            for reply in batch {
                session.changeConversation { $0.items.settingSent(reply.replyTo ?? reply.id, to: SendOrigin.state(of: reply.status)) }
            }
            chainStates[first.chainID]?.turns += 1
            chainStates[first.chainID]?.touched = .now
            if model.send(OrbEnvelopeText.reply(batch), to: botID, origin: .orbReply(batch)) {
                model.live(botID).glanced()
                refresh(botID)
                return true
            }
            session.chain = nil // no model: the notice says so, and the answers have nobody to wake
            continue
        }
        inbox[botID] = heldBack.isEmpty ? nil : heldBack
        return false
    }

    // MARK: MultiOrb (WP5)

    /// The group's pause ended ("Continuar"): the turns it held back go to their targets' queues again, and the answers it held
    /// wake their Orbs.
    func resumeHeldWork(chain: UUID) {
        let ready = held.filter { requests[$0]?.envelope.chainID == chain }
        held.removeAll { id in ready.contains(id) || requests[id]?.state != .queued }
        var targets: [UUID] = []
        // The wait restarts: the time the group spent paused does not count against the requests it held.
        for id in requests.keys where requests[id]?.envelope.chainID == chain {
            if requests[id]?.state == .queued { requests[id]?.envelope.sentAt = .now }
            if requests[id]?.state == .awaitingChildren { waitingSince[id] = .now }
        }
        for id in ready {
            guard let request = requests[id], request.state == .queued else { continue }
            queues[request.envelope.to.id, default: []].insert(id, at: 0)
            if !targets.contains(request.envelope.to.id) { targets.append(request.envelope.to.id) }
        }
        for (botID, replies) in inbox where replies.contains(where: { $0.chainID == chain }) && !targets.contains(botID) { targets.append(botID) }
        for botID in targets { schedulePump(botID) }
    }
    // MARK: end MultiOrb (WP5)

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
        for botID in Array(inbox.keys) {
            let before = inbox[botID]?.count ?? 0
            inbox[botID]?.removeAll { $0.chainID == id }
            if inbox[botID]?.isEmpty == true { inbox[botID] = nil }
            if (inbox[botID]?.count ?? 0) != before { touched.insert(botID) }
        }
        // Their requests are marked first, so the end of each turn finds nothing to answer.
        for botID in running { model.session(botID).stop(startsQueuedRoutines: false) }
        refresh(Array(touched))
        // A group's chain says it stopped in the group's own thread (`groupStopped`), never in its orchestrator's private chat.
        if reason == .user, chain.groupID == nil, !isShuttingDown, !alreadyCancelled, !open.isEmpty || hadInbox, model.bot(chain.originBot) != nil {
            appendToChat(of: chain.originBot, .event(OrbEvent(kind: .chainStopped, actor: model.bot(chain.originBot).map(OrbRef.init),
                                                              chainID: id)))
        }
        for botID in touched { schedulePump(botID) }
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
        for botID in running { model?.session(botID).stop(startsQueuedRoutines: false) }
        refresh(Array(Set(affected.flatMap { [$0.envelope.from.id, $0.envelope.to.id] })))
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

    // MARK: Accounting

    /// Adds what a turn used to the budget of its chain (fresh tokens: what the provider charges in full or writes to its cache).
    func tokensUsed(_ n: Int, chain: UUID) {
        guard n > 0, chainStates[chain] != nil else { return }
        chainStates[chain]?.tokens += n
        chainStates[chain]?.touched = .now
    }

    /// Run by the scheduler every 30 seconds: a request that waited too long ends `failed`, and what is old and idle is forgotten.
    func sweep(now: Date = .now) {
        // A group's pause is not a timeout: what the group holds back (queued turns, answers in the inbox) waits for "Continuar".
        for request in requests.values where request.state == .queued && !held.contains(request.id)
            && now.timeIntervalSince(request.envelope.sentAt) > DelegationLimits.requestTimeout {
            fail(request, "Tempo esgotado")
        }
        let answered = Set(inbox.values.flatMap { $0.compactMap(\.servingRequest) })
        for (id, since) in waitingSince where now.timeIntervalSince(since) > DelegationLimits.requestTimeout {
            guard let request = requests[id], request.state == .awaitingChildren else { continue }
            if answered.contains(id) || !request.openChildren.isDisjoint(with: held) { continue }
            fail(request, "Tempo esgotado")
        }
        let busy = Set(requests.values.filter { Self.isOpen($0.state) }.map(\.envelope.chainID))
            .union(inbox.values.flatMap { $0.map(\.chainID) })
        for (id, chain) in chainStates where !busy.contains(id) && now.timeIntervalSince(chain.touched) > Self.chainRetention {
            chainStates[id] = nil
        }
        held.removeAll { requests[$0]?.state != .queued }
        pruneRequests()
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
    private func waiting(_ botID: UUID, inChain chainID: UUID) -> Bool {
        requests.values.contains { Self.isOpen($0.state) && $0.envelope.chainID == chainID && $0.envelope.from.id == botID }
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
        case "ask", "tell":
            let kind: OrbEnvelope.Kind = arguments["action"]?.string?.lowercased() == "tell" ? .tell : .ask
            do {
                let envelope = try submit(from: botID, to: arguments["to"]?.string ?? "", text: arguments["message"]?.string ?? "",
                                          kind: kind, messageID: messageID, groupID: groupID)
                return kind == .ask
                    ? "Pedido enviado a \(envelope.to.name) (id \(envelope.shortID)). A resposta chega sozinha como mensagem; "
                        + "não espere nem repita o pedido. Termine o que puder sem ela."
                    : "Aviso enviado a \(envelope.to.name)."
            } catch let refusal as DelegationRefusal {
                throw refusal.toolError
            }
        default:
            throw ToolError("Use action list, ask ou tell.")
        }
    }

    /// "- Pesquisador: Pesquisa na web e resume (livre)": the teammates, without ids or folders.
    func teammatesText(for botID: UUID, groupID: UUID?) -> String {
        guard let model else { return "" }
        let team = roster(for: botID, groupID: groupID).compactMap { model.bot($0.id) }
        guard !team.isEmpty else { return "Não há outros Orbs." }
        return team.prefix(DelegationLimits.rosterLimit * 4).map { orb in
            let role = MemoryText.clip(MemoryText.flatten(orb.role), DelegationLimits.roleClip)
            return "- \(orb.name)\(role.isEmpty ? "" : ": " + role) (\(isBusy(orb.id) ? "ocupado" : "livre"))"
        }.joined(separator: "\n")
    }

    private func isBusy(_ botID: UUID) -> Bool {
        guard let model else { return false }
        return model.isWorking(botID) || model.sessions[botID]?.turnTask != nil || starting.contains(botID)
            || !(queues[botID] ?? []).isEmpty
    }

    // MARK: What the person sees

    /// Writes the Orb's wait ("Esperando Pesquisador") and its partner to its live state (only what changed is written).
    func refresh(_ ids: UUID...) { refresh(ids) }

    func refresh(_ ids: [UUID]) {
        guard let model else { return }
        for id in Set(ids) {
            guard let live = model.liveBot(id) else { continue }
            let asks = openRequests(from: id)
            var names: [String] = []
            for request in asks {
                let name = model.bot(request.envelope.to.id)?.name ?? request.envelope.to.name
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

    // MARK: Helpers

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

