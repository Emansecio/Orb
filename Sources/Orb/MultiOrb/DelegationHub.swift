import Foundation

/// The runtime of Orbs asking each other for work. A request (`orbs` ask or tell) waits in the target's queue and runs on the
/// target's own `BotSession` as a side run: the chat is parked, a conversation of its own (`pedido-<id>.json`) takes its place, the
/// permissions and mode are the target's. When the turn ends, the last thing the target said goes back to the asker as a reply
/// that wakes it (a new turn of its chat, or the continuation of the request it was serving when it asked). Nothing here is
/// saved but those conversations and top-level journal entries: requests in flight die with the app (`Conversation.closingInterruptedTurn`), and the next launch sends again the ones the `WorkJournal` kept (`resubmit`) while restoring any already-received replies (`restorePendingReply`).
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
        /// `pulse`: begun by an Orb's pulse run (its id); everything the chain spends counts against the pulse's daily budget.
        enum Origin: Equatable { case chat(UUID), routine(UUID), group(UUID), pulse(UUID) }

        var origin: Origin
        /// The Orb that began the chain: where "Você parou a conversa" is written.
        var originBot: UUID
        var groupID: UUID?
        /// The conversation of `originBot` that began it (nil for a routine's run): the line goes there.
        var chat: UUID?
        var cancelled = false
        var recent: [String: Date] = [:]
        var touched = Date.now
        /// The Orbs this chain left notices (`tell`), and in which of their conversations: stopping the chain takes back
        /// the ones not handed to a turn yet.
        var noticed: [UUID: Set<UUID>] = [:]
        /// The groups this chain already went through when a group's turn asked another group: asking one of them again would loop
        /// (A asks B, B asks A). Not persisted: it only outlives a request while the app runs.
        var groupsVisited: Set<UUID> = []
    }

    var requests: [UUID: DelegationRequest] = [:]
    /// Per target: the requests waiting for it, oldest first.
    var queues: [UUID: [UUID]] = [:]
    /// Per Orb: the answers waiting to be handed to it.
    var inbox: [UUID: [OrbEnvelope]] = [:]
    var chainStates: [UUID: ChainState] = [:]
    /// The last `seenLimit` message ids, to tell a repeat from a new message.
    var seenMessageIDs: [UUID] = []
    /// The side conversation of a request that waits for its children, kept in memory so it resumes without a read.
    var suspended: [UUID: Conversation] = [:]
    var waitingSince: [UUID: Date] = [:]
    /// Orbs whose group turn is being prepared (its opening text is asked of the group, which may take a moment).
    var starting: Set<UUID> = []
    /// Requests at work past `workTimeout` whose banner went out (once each).
    var toldStillRunning: Set<UUID> = []

    /// A routine's run that asked other Orbs and waits for their answers: its conversation, kept to resume from, and when the
    /// run began (its history counts the whole run). By routine id.
    struct RoutineWait {
        var botID: UUID
        var conversation: Conversation
        var started: Date
        /// A pulse's run waits (`holdPulse`), with what it had spent and why it woke; nil: a routine's.
        var pulse: PulseRun?
    }
    var waitingRoutines: [UUID: RoutineWait] = [:]

    /// The folder a request's turns work in when it is not the Orb's own (a worktree, or a group's project folder); it outlives
    /// the first turn so the turn that resumes the request after its children answered works in the same place.
    var workFolders: [UUID: URL] = [:]
    /// The name a member first worked under in a group run ("run/member" -> name): the worktree and branch are named after it, so
    /// renaming the Orb mid-run keeps working in the same worktree instead of orphaning the first one's commits.
    var workMemberNames: [String: String] = [:]
    /// The project of each request that works in a worktree of its own (`ask` with a `folder`), until the worktree is cleaned up.
    var folderRuns: [UUID: URL] = [:]
    /// When each sender last asked each target the same text from its own chat (no chain to hold it), pruned on write.
    var recentFromChat: [UUID: [String: Date]] = [:]
    /// Stretches the Mac slept through. Nobody worked or answered while it slept, so that time must not count toward the
    /// waits of `sweep`: a request sent in the evening would otherwise be "timed out" the moment the lid opens.
    var sleeps: [DateInterval] = []

    static let seenLimit = 500
    static let keptRequests = 300
    static let chainRetention: TimeInterval = 2 * 3600
    static let resumedPrefix = "(Resumed after the app closed: check what is already done before repeating anything.)\n\n"
    static let failedLead = "Não consegui: "

    init(model: AppModel? = nil) { self.model = model }

    func isStarting(_ botID: UUID) -> Bool { starting.contains(botID) }

    /// Some request between Orbs is open (not a group's: groups do not depend on the switch).
    var hasActiveChains: Bool { requests.values.contains { Self.isOpen($0.state) && $0.envelope.groupID == nil } || inbox.values.contains { !$0.isEmpty } }

    // MARK: Asking

    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?) throws -> OrbEnvelope {
        try submit(from: from, to: name, text: text, kind: kind, messageID: messageID, groupID: groupID, folder: nil, artifacts: [])
    }

    /// `folder`: a project folder the receiver of an `ask` works in (a worktree of it when it is a git repository).
    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?, folder: String?, artifacts: [String] = []) throws -> OrbEnvelope {
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
        if let target = DelegationRules.resolve(name, among: orbs) {
            let key = DelegationRules.repeatKey(to: target.id, text: text)
            // Outside a chain (the Orb's own chat) every ask opens a new chain, so the sender keeps its own record.
            let when = context.map { chainStates[$0.chainID]?.recent[key] } ?? recentFromChat[from]?[key]
            if let when, now.timeIntervalSince(when) < DelegationRules.duplicateWindow { input.recentSameText = true }
        }
        let plan = try DelegationRules.validate(input)
        // MARK: MultiOrb (WP5): a request inside a group's chain also answers to the group's policy.
        if groupID ?? context?.groupID != nil,
           let refusal = groupHooks?.refusal(forRequestFrom: from, to: plan.target.id, chain: plan.chainID) { throw refusal }
        // MARK: end MultiOrb (WP5)

        var chain = chainStates[plan.chainID] ?? newChain(startedBy: sender, session: session, groupID: groupID ?? context?.groupID)
        // Work the pulse pays for does not grow once the day's budget is spent: refused here, before it costs a turn.
        if kind == .ask, chain.origin.pulseRun != nil, model.pulseBudgetSpent { throw DelegationRefusal.pulseBudget }
        let repeatKey = DelegationRules.repeatKey(to: plan.target.id, text: plan.text)
        chain.recent[repeatKey] = now
        if context == nil {
            recentFromChat[from, default: [:]][repeatKey] = now
            recentFromChat[from] = recentFromChat[from]?.filter { now.timeIntervalSince($0.value) < DelegationRules.duplicateWindow }
        }
        chain.touched = now
        chainStates[plan.chainID] = chain
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.seenLimit { seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit) }

        var envelope = OrbEnvelope(id: messageID, chainID: plan.chainID, kind: kind, from: OrbRef(sender), to: plan.target,
                                   text: plan.text, hop: plan.hop, path: plan.path, servingRequest: session.servingRequest,
                                   groupID: groupID ?? context?.groupID, sentAt: now)
        envelope.chat = session.conversationChat
        envelope.pulseRun = chain.origin.pulseRun
        envelope.artifacts = Array(artifacts.prefix(DelegationLimits.maxArtifacts))
        if kind == .tell { return leaveNotice(envelope, session: session) }
        envelope.folder = folder
        // A routine's run that asks is resumed by the answer (`holdRoutine`), so the answer must say which run it is for.
        if session.routineID != nil, session.sideKind == nil { envelope.servingRoutine = session.routineID }
        // A pulse's run too (`holdPulse`): its answer must not wake the chat, which knows nothing of what the pulse asked.
        if session.sideKind == .pulse { envelope.servingPulse = session.routineID }
        requests[envelope.id] = DelegationRequest(envelope: envelope, state: .queued)
        model.workJournal.requestBegan(envelope) // a close of the app resumes it (`resubmit`)
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

    /// The app closed on this request (`WorkJournal`): it goes to the same target again, once, in the same chain, so the answer wakes
    /// the asker as it would have. The target is told to check what is already done. A request that was itself serving another
    /// is not kept (the one it served is redone and asks again). False when it cannot be sent anymore: an Orb is gone, or the
    /// switch is off.
    func resubmit(_ original: OrbEnvelope) -> Bool {
        guard let model, !isShuttingDown, model.orbsCanTalk, model.bot(original.from.id) != nil, model.bot(original.to.id) != nil,
              requests[original.id] == nil else { return false }
        // The pulse's, with the pulse off or the day's budget spent: nobody would pay for it, as `submit` refuses.
        if original.pulseRun != nil, !model.pulseIsOn || model.pulseBudgetSpent { return false }
        var envelope = original
        envelope.text = Self.resumedPrefix + original.text
        envelope.sentAt = .now
        // A request the pulse paid for is still the pulse's after the close: its envelope says so.
        var chain = chainStates[envelope.chainID]
            ?? ChainState(origin: envelope.pulseRun.map { .pulse($0) } ?? .chat(envelope.from.id), originBot: envelope.from.id,
                          groupID: nil, chat: envelope.chat)
        chain.touched = .now
        chainStates[envelope.chainID] = chain
        requests[envelope.id] = DelegationRequest(envelope: envelope, state: .queued)
        queues[envelope.to.id, default: []].append(envelope.id)
        refresh(envelope.from.id, envelope.to.id)
        schedulePump(envelope.to.id)
        return true
    }

    /// A notice (`tell`) runs no turn. In a group it is a post in the thread, which the member's next turn reads with the rest
    /// of the thread; elsewhere it is a line of the target's latest conversation (`AppModel.latestChat`), saved with it,
    /// which that conversation's next turn is handed (`SinceLastTurn`) and a request's run reads meanwhile (`RequestBackground`).
    private func leaveNotice(_ envelope: OrbEnvelope, session: BotSession) -> OrbEnvelope {
        guard let model else { return envelope }
        let line = OrbMessageItem(direction: .sent, kind: .tell, state: .replied, from: envelope.from, to: envelope.to,
                                  text: envelope.text, requestID: envelope.id, chainID: envelope.chainID, groupID: envelope.groupID)
        session.append(.orbMessage(line))
        if envelope.groupID != nil {
            groupHooks?.noticePosted(envelope)
        } else {
            let chat = model.latestChat(of: envelope.to.id)
            chainStates[envelope.chainID]?.noticed[envelope.to.id, default: []].insert(chat)
            var received = line
            received.direction = .received
            if let landed = model.appendToChat(.orbMessage(received), of: envelope.to.id, in: chat) {
                model.notePulseNotice(envelope, chat: landed.chat)
            }
            model.live(envelope.to.id).poked()
        }
        model.live(envelope.from.id).poked()
        return envelope
    }

    /// A turn of a member of a group: the group's runtime asks the hub for it so the target's queue, its own conversation and the
    /// limits are the same as for any request. `askedBy` nil: the person asked (nobody gets a reply).
    func submitGroupTurn(member: UUID, text: String, chain context: ChainContext, groupID: UUID,
                         askedBy: UUID?, fromPerson: Bool = true) -> DelegationRequest {
        queueGroupTurn(member: member, text: text, chain: context, groupID: groupID, askedBy: askedBy, id: UUID(), fromChat: false,
                       fromPerson: askedBy == nil && fromPerson)
    }

    func submitGroupRequest(from asker: UUID, text: String, chain context: ChainContext, groupID: UUID, orchestrator: UUID,
                            id: UUID) -> DelegationRequest {
        queueGroupTurn(member: orchestrator, text: text, chain: context, groupID: groupID, askedBy: asker, id: id, fromChat: true,
                       fromPerson: false)
    }

    private func queueGroupTurn(member: UUID, text: String, chain context: ChainContext, groupID: UUID, askedBy: UUID?, id: UUID,
                                fromChat: Bool, fromPerson: Bool) -> DelegationRequest {
        let from = askedBy.flatMap { model?.bot($0) } ?? model?.bot(member)
        let target = model?.bot(member)
        // From the asker's own chat there is no request it serves: the answer wakes that chat. An asker in a side run (a group's
        // turn, another Orb's request) is serving a request, and the answer resumes that one instead.
        let serving = context.serving ?? askedBy.flatMap { model?.session($0).servingRequest }
        var envelope = OrbEnvelope(
            id: id, chainID: context.chainID, kind: .ask, from: from.map(OrbRef.init) ?? OrbRef(id: askedBy ?? member, name: ""),
            to: target.map(OrbRef.init) ?? OrbRef(id: member, name: ""), text: text, hop: context.hop + 1,
            path: context.path.isEmpty ? [(askedBy ?? member)] : context.path,
            servingRequest: serving, groupID: groupID)
        envelope.fromChat = fromChat
        if fromChat { envelope.chat = askedBy.flatMap { model?.sessions[$0]?.conversationChat } }
        guard let model, target != nil, !isShuttingDown else { return DelegationRequest(envelope: envelope, state: .failed) }
        // A group started by work the pulse pays for (its own run, a teammate serving its request, the chat its answer woke)
        // is charged to the pulse too (`AppModel.pulseLineage`): the budget holds the whole chain, however far it goes.
        let lineage = askedBy.flatMap { model.pulseLineage(of: $0) }
        var chain = chainStates[context.chainID] ?? ChainState(origin: lineage.map { .pulse($0) } ?? .group(context.chainID),
                                                               originBot: askedBy ?? member, groupID: groupID)
        // The person wrote in a group the pulse set to work: from here the work is theirs, neither charged nor stopped by the budget.
        // Not the app resuming the pulse's run after a relaunch (`GroupHub.resume`): that stays the pulse's.
        if fromPerson, chain.origin.isPulse {
            chain.origin = .group(context.chainID)
            handToPerson(context.chainID)
        }
        chain.touched = .now
        chainStates[context.chainID] = chain
        envelope.pulseRun = chain.origin.pulseRun
        guard !chain.cancelled else { return DelegationRequest(envelope: envelope, state: .cancelled) }
        if chain.origin.pulseRun != nil, model.pulseBudgetSpent { return DelegationRequest(envelope: envelope, state: .cancelled) }
        let request = DelegationRequest(envelope: envelope, state: .queued)
        requests[envelope.id] = request
        if let serving = envelope.servingRequest { requests[serving]?.openChildren.insert(envelope.id) }
        queues[member, default: []].append(envelope.id)
        refresh(member)
        schedulePump(member)
        return request
    }

    /// A chain of the pulse became the person's: no request of it is charged to the pulse any more, the turns already running
    /// included (from the person's message on, the work is theirs), and the journal resumes the group's run as theirs.
    private func handToPerson(_ chainID: UUID) {
        for (id, request) in requests where request.envelope.chainID == chainID && request.envelope.pulseRun != nil {
            requests[id]?.envelope.pulseRun = nil
        }
        model?.workJournal.groupRunIsThePersons(chainID)
    }

    func joinQueuedGroupTurn(member: UUID, chainID: UUID, text: String) -> DelegationRequest? {
        // Only the last in the member's queue: what others asked it in between keeps its place.
        guard let id = queues[member]?.last, let request = requests[id], request.state == .queued,
              request.envelope.chainID == chainID, request.envelope.groupID != nil, request.envelope.from.id == member,
              !request.envelope.fromChat else { return nil }
        requests[id]?.envelope.text = request.envelope.text + "\n\n" + text
        // Only the person's messages join (`GroupHub.enqueue`): as in `queueGroupTurn`, the work becomes theirs.
        if chainStates[chainID]?.origin.isPulse == true {
            chainStates[chainID]?.origin = .group(chainID)
            handToPerson(chainID)
        }
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
            if let groupID = request.envelope.groupID {
                // A member removed while its request waited (busy, queued) must not speak for the group any more.
                guard model.group(groupID)?.memberIDs.contains(botID) == true else { fail(request, "Esse Orb saiu do grupo"); continue }
                startGroupRun(request)
                return true
            }
            if let folder = request.envelope.folder, !folder.isEmpty {
                startFolderRun(request, folder: folder)
                return true
            }
            let ready = startRun(request, conversation: interruptedRun(of: request), text: OrbEnvelopeText.request(request.envelope),
                                 origin: .orb(request.envelope), resuming: false)
            if ready { return true }
        }
        if queues[botID]?.isEmpty == true { queues[botID] = nil }
        return false
    }

    /// A request redone after the app closed (`resubmit`) goes on in the conversation the interrupted run saved instead of
    /// overwriting `pedido-<id>.json` with an empty one, so the work already done stays in it.
    private func interruptedRun(of request: DelegationRequest) -> Conversation {
        guard let model, request.envelope.text.hasPrefix(Self.resumedPrefix) else { return Conversation() }
        let read = model.store.readSideConversation(prefix: Store.pedidoPrefix, id: request.envelope.id, for: request.envelope.to.id)
        return read.value?.closingInterruptedTurn(notice: BotSession.quitSideNotice) ?? Conversation()
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
            let pictures = self.groupHooks?.images(for: request) ?? []
            let envelope = request.envelope
            let body = envelope.from.id == envelope.to.id && !envelope.fromChat ? envelope.text : OrbEnvelopeText.request(envelope)
            // Where the member works (its own worktree of the group's project) comes after the group's preface, before the request.
            let work = await self.groupWork(for: request)
            let prompt = [preface, work?.note ?? "", body].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
            if !self.startRun(current, conversation: conversation, text: prompt, origin: .orb(current.envelope), resuming: false,
                              images: pictures, workFolder: work?.folder) {
                self.schedulePump(botID)
            }
        }
    }

    /// Where a group turn works and what the model is told about it; nil when the group has no project folder (or it is gone).
    private func groupWork(for request: DelegationRequest) async -> (folder: URL, note: String)? {
        guard let model, let groupID = request.envelope.groupID, let group = model.group(groupID), !group.projectFolder.isEmpty else { return nil }
        let project = URL(fileURLWithPath: group.projectFolder)
        guard project.isExistingDirectory else { return nil }
        let root = WorkFolders.root(in: model.store.directory)
        let member = request.envelope.to
        // The orchestrator keeps the main checkout: it merges what the members commit.
        if member.id == group.orchestratorID {
            return (project, await WorkFolders.orchestratorNote(project: project, run: request.envelope.chainID, root: root))
        }
        let nameKey = "\(request.envelope.chainID)/\(member.id)"
        let name = workMemberNames[nameKey] ?? member.name
        workMemberNames[nameKey] = name
        let work = await WorkFolders.prepare(project: project, member: name, run: request.envelope.chainID, root: root)
        return (work.url, WorkFolders.memberNote(work))
    }

    /// A request that names a project `folder`: the receiver works in a worktree of it (read off the main thread, the Orb held
    /// meanwhile, like a group turn).
    private func startFolderRun(_ request: DelegationRequest, folder: String) {
        guard let model else { return }
        let botID = request.envelope.to.id
        starting.insert(botID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let project = URL(fileURLWithPath: folder)
            var work: WorkFolder?
            if project.isExistingDirectory {
                work = await WorkFolders.prepare(project: project, member: request.envelope.to.name, run: request.id,
                                                 root: WorkFolders.root(in: model.store.directory))
            }
            self.starting.remove(botID)
            // Registered before any early return: a request cancelled meanwhile still leaves its worktree to be cleaned.
            if work?.branch != nil { self.folderRuns[request.id] = project }
            guard let current = self.requests[request.id], current.state == .queued else { return self.schedulePump(botID) }
            if self.chainStates[current.envelope.chainID]?.cancelled == true {
                self.requests[current.id]?.state = .cancelled
                return self.schedulePump(botID)
            }
            guard model.canTakeSideWork(botID) else {
                self.queues[botID, default: []].insert(current.id, at: 0)
                return
            }
            let body = OrbEnvelopeText.request(current.envelope)
            let text = work.map { body + "\n\n" + WorkFolders.memberNote($0, asked: true) } ?? body
            if !self.startRun(current, conversation: self.interruptedRun(of: current), text: text, origin: .orb(current.envelope),
                              resuming: false, workFolder: work?.url) {
                self.schedulePump(botID)
            }
        }
    }

    /// Starts (or resumes) a side run for `request` on its target: `text` is what the model is sent, `origin` how the
    /// conversation shows it. False when the turn could not begin (the request then failed and its asker was told).
    @discardableResult
    func startRun(_ request: DelegationRequest, conversation: Conversation, text: String, origin: SendOrigin,
                  resuming: Bool, images: [ImageAttachment] = [], workFolder: URL? = nil) -> Bool {
        guard let model else { return false }
        if leftItsGroup(request) {
            dropLeftMember(request)
            return false
        }
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
        if let workFolder { workFolders[envelope.id] = workFolder }
        guard model.send(text, images: images, to: botID, origin: origin, workFolder: workFolders[envelope.id]) else {
            workFolders[envelope.id] = nil
            session.endSideRun()
            session.scheduleSave(delay: 0)
            fail(running, "Não consegui começar: confira o modelo em Ajustes")
            return false
        }
        if !resuming, envelope.from.id != envelope.to.id, envelope.groupID == nil {
            model.appendToChat(.event(OrbEvent(kind: .delegationReceived, actor: envelope.from, subject: envelope.to,
                                               requestID: envelope.id, chainID: envelope.chainID, groupID: envelope.groupID)), of: botID)
        }
        let live = model.live(botID)
        live.poked()
        refresh(botID, envelope.from.id)
        return true
    }

    func write(_ conversation: Conversation, kind: SideRunKind, runID: UUID, for botID: UUID) {
        guard let model else { return }
        switch kind {
        case .delegation: model.store.saveSideConversation(conversation, prefix: Store.pedidoPrefix, id: runID, for: botID)
        case .group: model.store.saveSideConversation(conversation, prefix: Store.grupoPrefix, id: runID, for: botID)
        case .routine, .pulse: break // the pulse writes its own file (`AppModel.finishPulse`)
        }
    }

    // MARK: Helpers

    /// The Orb's name now (it may have been renamed since the envelope was written).
    func currentName(_ ref: OrbRef) -> String { model?.bot(ref.id)?.name ?? ref.name }

    /// Who a request went to, as the asker reads it: the Orb, or the group for a request sent to one from a chat.
    func displayName(of envelope: OrbEnvelope) -> String {
        if envelope.fromChat, let group = envelope.groupID.flatMap({ id in model?.groups.first { $0.id == id } }) { return group.name }
        return model?.bot(envelope.to.id)?.name ?? envelope.to.name
    }

    func newChain(startedBy sender: Bot, session: BotSession, groupID: UUID?) -> ChainState {
        // The pulse's lineage first: whatever turn asks, work the pulse pays for stays on its budget.
        let origin: ChainState.Origin = if let run = model?.pulseLineage(of: sender.id) { .pulse(run) }
            else if let groupID { .group(groupID) }
            else if session.sideKind == .routine, let routine = session.routineID { .routine(routine) }
            else { .chat(sender.id) }
        return ChainState(origin: origin, originBot: sender.id, groupID: groupID, chat: session.conversationChat)
    }

    /// Wakes the Orb's queue on the next turn of the main actor, never inside the call that changed it.
    func schedulePump(_ botID: UUID) {
        Task { @MainActor [weak self] in self?.model?.startNextQueuedWork(for: botID) }
    }

    /// The asker's lines about `requestID` now read `state`: in the conversation that asked (`chat`), wherever it is; for a
    /// request asked elsewhere (a routine's run, another request), in the conversation the turn machinery has or the chat a
    /// side run parked.
    func markSent(_ requestID: UUID, asker: UUID, as state: OrbMessageItem.State, in chat: UUID? = nil) {
        guard let model, model.bot(asker) != nil else { return }
        let session = model.session(asker)
        if let chat {
            guard model.isChat(chat, of: asker) else { return } // deleted since
            return session.changeChat(chat) { $0.items.settingSent(requestID, to: state) }
        }
        func has(_ items: [TranscriptItem]) -> Bool {
            items.contains { if case .orbMessage(let m) = $0.kind { m.direction == .sent && m.requestID == requestID && m.state == .open } else { false } }
        }
        // An unloaded chat is not read here (on the main thread) for one line: the change waits for the read.
        if session.isUnloaded {
            session.changeOnceLoaded { if has($0.items) { $0.items.settingSent(requestID, to: state) } }
        } else if let conversation = session.conversation, has(conversation.items) {
            session.mutateItems { $0.settingSent(requestID, to: state) }
        }
        if let parked = session.parkedChat, has(parked.items) {
            session.parkedChat?.items.settingSent(requestID, to: state)
            if let chat = session.parkedChat { model.store.save(chat, for: asker, chat: session.chatID) }
        }
    }

    /// The notices of the chain that the conversation `chat` of `botID` (the one on show when nil) was not handed yet now
    /// read cancelled: its next turn does not get them (the line stays, as a stopped request's does). An unloaded one is
    /// not read here: the change waits for the read, or goes to its file.
    func dropUnreadNotices(of chainID: UUID, for botID: UUID, in chat: UUID? = nil) {
        guard let model, model.bot(botID) != nil else { return }
        let session = model.session(botID), target = chat ?? session.chatID
        guard model.isChat(target, of: botID) else { return }
        model.forgetPulseNotices(of: botID, chat: target, chain: chainID)
        session.changeChat(target) { conversation in
            for index in SinceLastTurn.pendingIndices(in: conversation.items, since: conversation.contextHandedAt) {
                guard case .orbMessage(var message) = conversation.items[index].kind, message.kind == .tell,
                      message.chainID == chainID else { continue }
                message.state = .cancelled
                conversation.items[index].kind = .orbMessage(message)
            }
        }
    }
}

extension DelegationRequest {
    /// A request is its envelope's message: the id it is kept, queued and answered by.
    var id: UUID { envelope.id }
}
