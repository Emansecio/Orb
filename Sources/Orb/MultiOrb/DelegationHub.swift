import Foundation

/// The runtime of Orbs asking each other for work. A request (`orbs` ask or tell) waits in the target's queue and runs on the
/// target's own `BotSession` as a side run: the chat is parked, a conversation of its own (`pedido-<id>.json`) takes its place, the
/// permissions and mode are the target's. When the turn ends, the last thing the target said goes back to the asker as a reply
/// that wakes it (a new turn of its chat, or the continuation of the request it was serving when it asked). Nothing here is
/// saved but those conversations: requests in flight die with the app (`Conversation.closingInterruptedTurn`), and the next launch sends again the ones the `WorkJournal` kept (`resubmit`).
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
    static let keptRequests = 300
    static let chainRetention: TimeInterval = 2 * 3600

    init(model: AppModel? = nil) { self.model = model }

    func isStarting(_ botID: UUID) -> Bool { starting.contains(botID) }

    /// The folder a request's turns work in when it is not the Orb's own (a worktree, or a group's project folder); it outlives
    /// the first turn so the turn that resumes the request after its children answered works in the same place.
    private var workFolders: [UUID: URL] = [:]
    /// The project of each request that works in a worktree of its own (`ask` with a `folder`), until the worktree is cleaned up.
    private var folderRuns: [UUID: URL] = [:]
    /// When each sender last asked each target the same text from its own chat (no chain to hold it), pruned on write.
    private var recentFromChat: [UUID: [String: Date]] = [:]

    /// Some request between Orbs is open (not a group's: groups do not depend on the switch).
    var hasActiveChains: Bool { requests.values.contains { Self.isOpen($0.state) && $0.envelope.groupID == nil } || inbox.values.contains { !$0.isEmpty } }

    // MARK: Asking

    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?) throws -> OrbEnvelope {
        try submit(from: from, to: name, text: text, kind: kind, messageID: messageID, groupID: groupID, folder: nil)
    }

    /// `folder`: a project folder the receiver of an `ask` works in (a worktree of it when it is a git repository).
    func submit(from: UUID, to name: String, text: String, kind: OrbEnvelope.Kind, messageID: UUID,
                groupID: UUID?, folder: String?) throws -> OrbEnvelope {
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
        if kind == .tell { return leaveNotice(envelope, session: session) }
        envelope.folder = folder
        // A routine's run that asks is resumed by the answer (`holdRoutine`), so the answer must say which run it is for.
        if session.routineID != nil, session.sideKind == nil { envelope.servingRoutine = session.routineID }
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
        var envelope = original
        envelope.text = Self.resumedPrefix + original.text
        envelope.sentAt = .now
        var chain = chainStates[envelope.chainID]
            ?? ChainState(origin: .chat(envelope.from.id), originBot: envelope.from.id, groupID: nil, chat: envelope.chat)
        chain.touched = .now
        chainStates[envelope.chainID] = chain
        requests[envelope.id] = DelegationRequest(envelope: envelope, state: .queued)
        queues[envelope.to.id, default: []].append(envelope.id)
        refresh(envelope.from.id, envelope.to.id)
        schedulePump(envelope.to.id)
        return true
    }

    static let resumedPrefix = "(Resumed after the app closed: check what is already done before repeating anything.)\n\n"

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
            model.appendToChat(.orbMessage(received), of: envelope.to.id, in: chat)
            model.live(envelope.to.id).poked()
        }
        model.live(envelope.from.id).poked()
        return envelope
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
        guard model != nil, target != nil, !isShuttingDown else { return DelegationRequest(envelope: envelope, state: .failed) }
        // A group the pulse starts from its Orb's pulse run is charged to the pulse (`AppModel.pulseCharge`).
        let pulseRun = fromChat ? askedBy.flatMap { model?.sessions[$0] }.flatMap { $0.sideKind == .pulse ? $0.routineID : nil } : nil
        var chain = chainStates[context.chainID] ?? ChainState(origin: pulseRun.map { .pulse($0) } ?? .group(context.chainID),
                                                               originBot: askedBy ?? member, groupID: groupID)
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
        let work = await WorkFolders.prepare(project: project, member: member.name, run: request.envelope.chainID, root: root)
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
    private func startRun(_ request: DelegationRequest, conversation: Conversation, text: String, origin: SendOrigin,
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
        case .routine, .pulse: break // the pulse writes its own file (`AppModel.finishPulse`)
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
        reply.chat = envelope.chat
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
                && envelope.servingRequest == reply.servingRequest && envelope.servingRoutine == reply.servingRoutine
                && envelope.chat == reply.chat
        }
    }

    static let failedLead = "Não consegui: "

    /// Hands the Orb the answers waiting for it, when it is free: up to `wakeBatch` of the same continuation at once. An answer to
    /// a request the Orb was serving resumes that request's conversation; any other wakes the conversation that asked (the
    /// latest, when that one was deleted), behind the one on show when that is another. True when a turn began.
    func deliverInbox(for botID: UUID) -> Bool {
        guard let model, !isShuttingDown else { return false }
        var waiting = (inbox[botID] ?? []).filter { chainStates[$0.chainID]?.cancelled != true }
        // The answers of work whose other answers are still to come stay in the box: the Orb is woken once, with all of them.
        var held: [OrbEnvelope] = []
        while let first = waiting.first {
            let sameWork = waiting.filter {
                $0.servingRequest == first.servingRequest && $0.servingRoutine == first.servingRoutine && $0.chat == first.chat
            }
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
                if leftItsGroup(request) {
                    dropLeftMember(request) // taken out of the group while it waited: it must not speak again
                    continue
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
                    if ready, wanted, self.wake(botID, with: batch) { return }
                    if ready { session.endWorkElsewhere() } // nothing began there: the one on show takes the turn machinery back
                    if !ready, wanted { self.inbox[botID, default: []].insert(contentsOf: batch, at: 0) }
                    self.schedulePump(botID)
                }
                return true
            }
            if wake(botID, with: batch) { return true }
        }
        inbox[botID] = held.isEmpty ? nil : held
        return false
    }

    /// The answers wake the conversation the turn machinery has: it goes on with them, as a turn of its own.
    private func wake(_ botID: UUID, with batch: [OrbEnvelope]) -> Bool {
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
        if model.send(OrbEnvelopeText.reply(batch), to: botID, origin: .orbReply(batch)) {
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
        // Their requests are marked first, so the end of each turn finds nothing to answer.
        for botID in running {
            model.session(botID).stop(startsQueuedRoutines: false,
                                      notice: isShuttingDown ? BotSession.quitSideNotice
                                          : reason == .gaveUp ? ApprovalWait.gaveUpNotice
                                          : reason == .budget ? AppModel.pulseCappedNotice : BotSession.stoppedNotice)
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
        if reason == .user || reason == .budget, !isShuttingDown, chain.groupID != nil, !alreadyCancelled { groupHooks?.chainStopped(id, by: reason) }
        settleWaitingRoutines()
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
        // A request the group took from this Orb's chat has no one left to answer: the whole group request stops (and says so
        // in its thread), instead of only the orchestrator's turn while the members go on.
        for chain in Set(groupChains) { cancelChain(chain, by: .user) }
        for botID in running { model?.session(botID).stop(startsQueuedRoutines: false) }
        for (routineID, wait) in waitingRoutines where wait.botID == id { waitingRoutines[routineID] = nil }
        refresh(Array(Set(affected.flatMap { [$0.envelope.from.id, $0.envelope.to.id] })))
        settleWaitingRoutines()
    }

    /// A group request whose target is no longer a member (removed while the request waited or queued).
    private func leftItsGroup(_ request: DelegationRequest) -> Bool {
        guard let groupID = request.envelope.groupID else { return false }
        return model?.group(groupID)?.memberIDs.contains(request.envelope.to.id) != true
    }

    /// Ends such a request as failed without resuming it. Its kept conversation is thrown away, not closed on disk: writing it
    /// would recreate the side file that leaving the group deleted.
    private func dropLeftMember(_ request: DelegationRequest) {
        suspended[request.id] = nil
        fail(request, "Esse Orb saiu do grupo")
        groupHooks?.turnFinished(requests[request.id] ?? request, reply: nil, outcome: .failed)
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

    /// Drops the duplicate-window records of requests that will not answer (failed or stopped), so the same ask can be redone.
    private func forgetRepeats(of chain: ChainState) {
        guard !chain.recent.isEmpty else { return }
        for key in chain.recent.keys { recentFromChat[chain.originBot]?[key] = nil }
    }

    private func forgetRepeat(_ request: DelegationRequest) {
        let envelope = request.envelope
        let key = DelegationRules.repeatKey(to: envelope.to.id, text: envelope.text)
        chainStates[envelope.chainID]?.recent[key] = nil
        recentFromChat[envelope.from.id]?[key] = nil
    }

    /// A request that cannot go on (the target cannot start, time ran out): it ends `failed` and its asker is told.
    private func fail(_ request: DelegationRequest, _ reason: String) {
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
        refresh(request.envelope.from.id, request.envelope.to.id)
    }

    /// Stretches the Mac slept through. Nobody worked or answered while it slept, so that time must not count toward the
    /// waits of `sweep`: a request sent in the evening would otherwise be "timed out" the moment the lid opens.
    private var sleeps: [DateInterval] = []

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
        case "edit_group_plan":
            // For the tool: what the user must confirm first, "" when the edit needs nobody.
            do { return try planGroupEdit(arguments, by: botID).confirmation ?? "" } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "edit_group":
            do { return try await editGroup(arguments, by: botID) } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "delete_orb_plan":
            // For the tool: the text of the user's card.
            return try planOrbDelete(arguments, by: botID).confirmation
        case "delete_orb":
            return try deleteOrb(arguments, by: botID)
        case "ask", "tell":
            let kind: OrbEnvelope.Kind = arguments["action"]?.string?.lowercased() == "tell" ? .tell : .ask
            let name = arguments["to"]?.string ?? "", text = arguments["message"]?.string ?? ""
            do {
                // Outside a group's turn, a group's name (that no Orb has) is a request to that group.
                // In a group's turn too, with "Orbs agem por conta própria" (an orchestrator asking another group).
                if groupID == nil || model.orbsActOnOwn, let group = group(named: name) {
                    let envelope = try submitToGroup(group, from: botID, text: text, kind: kind, messageID: messageID)
                    return "Pedido enviado ao grupo \(group.name) (id \(envelope.shortID)): \(envelope.to.name) orquestra, o grupo "
                        + "trabalha no fio dele e a resposta final chega sozinha como mensagem; não espere nem repita o pedido. "
                        + "O usuário acompanha na tela do grupo."
                }
                // A project folder is for a plain request: a group's turns use the group's own (`OrbGroup.projectFolder`).
                var folder: String?
                if kind == .ask, groupID == nil, let path = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    folder = try AccessRequest.checkedFolder(path, home: model.homeFolder)
                }
                let envelope = try submit(from: botID, to: name, text: text, kind: kind, messageID: messageID, groupID: groupID,
                                          folder: folder)
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
    /// groups the Orb is in come after them; in one, the other groups its orchestrator may ask.
    func teammatesText(for botID: UUID, groupID: UUID?) -> String {
        guard let model else { return "" }
        let team = roster(for: botID, groupID: groupID).compactMap { model.bot($0.id) }
        let teammates = team.isEmpty ? "Não há outros Orbs." : team.prefix(DelegationLimits.rosterLimit * 4).map { orb in
            let role = MemoryText.clip(MemoryText.flatten(orb.role), DelegationLimits.roleClip)
            let state = groupID.map { groupStatus(of: orb.id, in: $0) } ?? status(of: orb.id)
            return "- \(orb.name)\(role.isEmpty ? "" : ": " + role) (\(state))"
        }.joined(separator: "\n")
        let lines = groupID == nil ? model.groupLines(for: botID) : model.otherGroupLines(for: botID, inTurnOf: groupID)
        let groups = lines.prefix(OrbsPrompt.groupLimit).map { group in
            let lead = group.youOrchestrate ? "você orquestra" : "\(group.orchestrator) orquestra"
            return "- \(group.name): \(lead)" + (group.others.isEmpty ? "" : "; outros membros: " + group.others.joined(separator: ", "))
        }
        guard !groups.isEmpty else { return teammates }
        // Outside a group's turn the Orb may start a group's work only with both switches on; else the user does it on the group's screen.
        let mayAsk = groupID != nil || (model.orbsActOnOwn && model.orbsCanStartGroups)
        let note = mayAsk ? "você pode acionar estes com ask, pelo nome"
            : "o usuário inicia o trabalho de um grupo na tela dele; você não escreve no fio"
        return teammates + "\n\nSeus grupos (\(note)):\n" + groups.joined(separator: "\n")
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
        // Every change of a request passes here: the journal forgets the ones that ended (answered, failed, stopped).
        if model.workJournal.tracksRequests {
            // A reply still in an inbox is kept too: the inbox lives in memory only, so if the app closes before the asker
            // takes it, the request is redone on reopening instead of the answer being lost.
            let undelivered = inbox.values.flatMap { $0.compactMap(\.replyTo) }
            model.workJournal.syncRequests(open: Set(requests.values.filter { Self.isOpen($0.state) }.map(\.id)).union(undelivered))
        }
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

    /// `orbs ask` with the name of a group the Orb is in, from its own chat and in a turn the person started (any turn with "Orbs agem por conta própria"): a new request of
    /// the group (`GroupHub.postOrbRequest`), marked as the Orb's and handed to the orchestrator as data. The refusals say what
    /// to do instead; nothing changes when one is thrown.
    private func submitToGroup(_ group: OrbGroup, from botID: UUID, text raw: String, kind: OrbEnvelope.Kind,
                               messageID: UUID) throws -> OrbEnvelope {
        guard let model, !isShuttingDown, let sender = model.bot(botID) else { throw DelegationRefusal.switchedOff }
        let name = group.name
        guard kind == .ask else { throw DelegationRefusal.groupDoor(name, .tell) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupDoor(name, .switchedOff) }
        guard group.memberIDs.contains(botID) else { throw DelegationRefusal.groupDoor(name, .notMember) }
        // Groups already behind the asking turn: its own group and the ones that led to it.
        var visited: Set<UUID> = []
        if model.orbsActOnOwn {
            if let running = model.session(botID).chain, let current = running.groupID {
                guard group.id != current else { throw DelegationRefusal.ownGroup(name) }
                guard model.group(current)?.orchestratorID == botID else { throw DelegationRefusal.groupDoor(name, .notOrchestrator) }
                visited = (chainStates[running.chainID]?.groupsVisited ?? []).union([current])
                guard !visited.contains(group.id) else { throw DelegationRefusal.groupDoor(name, .inChain) }
            }
        } else {
            guard model.isOwnChat(botID) else { throw DelegationRefusal.groupDoor(name, .notFromHere) }
            guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupDoor(name, .notAsked) }
        }
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
        // The target group's turns start on a later pass of the main actor, so this lands before any of them can ask back.
        if !visited.isEmpty { chainStates[envelope.chainID]?.groupsVisited.formUnion(visited) }
        // The asker's chat: "Atlas pediu ao Estúdio" (the group's name, the orchestrator's color).
        model.session(botID).append(.orbMessage(OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: OrbRef(sender),
                                                               to: OrbRef(id: envelope.to.id, name: name), text: text,
                                                               requestID: envelope.id, chainID: envelope.chainID,
                                                               groupID: group.id, fromChat: true)))
        model.live(botID).poked()
        refresh(botID)
        return envelope
    }

    /// `group_create`: a group of the user's Orbs, made from the Orb's own chat in a turn the person started (any turn with "Orbs agem por conta própria"). The refusals say
    /// what to do instead; nothing is created when one is thrown.
    private func createGroup(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model, !isShuttingDown else { throw DelegationRefusal.groupSetup(.unavailable) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupSetup(.switchedOff) }
        if model.orbsActOnOwn {
            if let current = model.session(botID).chain?.groupID, model.group(current)?.orchestratorID != botID {
                throw DelegationRefusal.groupSetup(.notOrchestrator)
            }
        } else {
            guard model.isOwnChat(botID) else { throw DelegationRefusal.groupSetup(.notFromHere) }
            guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupSetup(.notAsked) }
        }
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
        var project = ""
        if let path = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            project = try AccessRequest.checkedFolder(path, home: model.homeFolder)
        }
        guard let group = model.createGroup(name: name, members: members.map(\.id), orchestrator: lead.id,
                                            objective: arguments["objective"]?.string ?? "", projectFolder: project,
                                            createdBy: botID) else {
            throw DelegationRefusal.groupSetup(.unavailable)
        }
        let others = members.filter { $0.id != lead.id }.map(\.name)
        let next = members.contains(where: { $0.id == botID })
            ? "Para mandar o primeiro pedido, use orbs ask com to “\(group.name)”."
            : "Você não é membro: o usuário manda os pedidos na tela do grupo."
        return "Grupo \(group.name) criado: \(lead.name) orquestra; os outros membros são \(Self.list(others)). O usuário vê o grupo "
            + "na lateral. " + (project.isEmpty ? "" : "Pasta do projeto: \(project); os membros (menos o orquestrador) trabalham cada um no seu ramo. ") + next
    }

    /// One checked `group_edit`: the group, the Orb it is about and what the user is asked first (nil when nobody is).
    private struct GroupEditPlan {
        enum Edit: String { case add, remove, orchestrator, rename, objective, delete }
        var edit: Edit
        var group: OrbGroup
        var orb: OrbRef?
        var text = ""
        var confirmation: String?
    }

    /// Checks a `group_edit` against the groups as they are now, changing nothing. Deleting a group, or taking out a member of a group
    /// of two (which dissolves it), carries the text of the user's card.
    private func planGroupEdit(_ arguments: JSONValue, by botID: UUID) throws -> GroupEditPlan {
        guard let model, !isShuttingDown else { throw DelegationRefusal.groupEdit(.unavailable) }
        guard model.orbsCanManageGroups else { throw DelegationRefusal.groupEdit(.switchedOff) }
        let typedGroup = (arguments["group"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = DelegationRules.fold(typedGroup)
        guard !wanted.isEmpty, let group = model.groups.first(where: { DelegationRules.fold($0.name) == wanted }) else {
            throw DelegationRefusal.groupEdit(.noGroup(typedGroup, model.groups.prefix(OrbsPrompt.groupLimit).map(\.name)))
        }
        let typedEdit = (arguments["edit"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let edit = GroupEditPlan.Edit(rawValue: typedEdit) else { throw DelegationRefusal.groupEdit(.unknownEdit(typedEdit)) }
        var plan = GroupEditPlan(edit: edit, group: group)
        let orbs = model.bots.map(OrbRef.init)
        switch edit {
        case .add, .remove, .orchestrator:
            let typed = (arguments["orb"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { throw DelegationRefusal.groupEdit(.missing("orb")) }
            guard let orb = DelegationRules.resolve(typed, among: orbs) else { throw DelegationRefusal.unknownOrb(typed) }
            plan.orb = orb
            let isMember = group.memberIDs.contains(orb.id)
            switch edit {
            case .add:
                guard !isMember else { throw DelegationRefusal.groupEdit(.alreadyMember(orb: orb.name, group: group.name)) }
                guard group.memberIDs.count < OrbGroup.memberLimits.upperBound else { throw DelegationRefusal.groupEdit(.full(group.name)) }
            case .remove:
                guard isMember else { throw DelegationRefusal.groupEdit(.notMember(orb: orb.name, group: group.name)) }
                if group.memberIDs.count <= OrbGroup.memberLimits.lowerBound {
                    plan.confirmation = "\(model.bot(botID)?.name ?? "Um Orb") quer tirar \(orb.name) do grupo “\(group.name)”. "
                        + "Com isso o grupo acaba (precisa de \(OrbGroup.memberLimits.lowerBound) Orbs, no mínimo); os Orbs ficam."
                }
            default:
                guard isMember else { throw DelegationRefusal.groupEdit(.notMember(orb: orb.name, group: group.name)) }
            }
        case .rename:
            let name = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw DelegationRefusal.groupEdit(.missing("name")) }
            // The same rule as `group_create`: a name an Orb or another group has would make `orbs ask` ambiguous.
            guard DelegationRules.resolve(name, among: orbs) == nil,
                  !model.groups.contains(where: { $0.id != group.id && DelegationRules.fold($0.name) == DelegationRules.fold(name) }) else {
                throw DelegationRefusal.groupEdit(.nameTaken(name))
            }
            plan.text = name
        case .objective:
            let text = (arguments["objective"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DelegationRefusal.groupEdit(.missing("objective")) }
            plan.text = text
        case .delete:
            plan.confirmation = "\(model.bot(botID)?.name ?? "Um Orb") quer apagar o grupo “\(group.name)”: o fio, o quadro e as conversas dos "
                + "membros nele vão embora. Os Orbs ficam."
        }
        return plan
    }

    /// `group_edit`: changes one of the user's groups. The refusals say what to do instead; nothing changes when one is thrown.
    /// `confirmed` comes from the tool after the user's card; an edit that needs it is refused without.
    private func editGroup(_ arguments: JSONValue, by botID: UUID) async throws -> String {
        guard let model else { throw DelegationRefusal.groupEdit(.unavailable) }
        let plan = try planGroupEdit(arguments, by: botID)
        if plan.confirmation != nil, arguments["confirmed"]?.bool != true { throw DelegationRefusal.groupEdit(.needsConfirmation) }
        let group = plan.group
        switch plan.edit {
        case .add:
            guard let orb = plan.orb, model.addMember(orb.id, to: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "\(orb.name) entrou no grupo \(group.name)."
        case .remove:
            guard let orb = plan.orb, model.removeMember(orb.id, from: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            guard let left = model.group(group.id) else { return "\(orb.name) saiu e o grupo \(group.name) acabou (precisa de 2 Orbs, no mínimo)." }
            let lead = left.orchestratorID != group.orchestratorID ? " \(model.bot(left.orchestratorID)?.name ?? "Outro Orb") passou a orquestrar." : ""
            return "\(orb.name) saiu do grupo \(group.name)." + lead
        case .orchestrator:
            guard let orb = plan.orb, model.setOrchestrator(orb.id, of: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "\(orb.name) agora orquestra o grupo \(group.name)."
        case .rename:
            model.renameGroup(group.id, to: plan.text)
            guard let renamed = model.group(group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "O grupo \(group.name) agora se chama \(renamed.name)."
        case .objective:
            guard await model.setGroupObjective(plan.text, of: group.id) else { throw DelegationRefusal.groupEdit(.objectiveRefused) }
            return "Objetivo do grupo \(group.name) gravado."
        case .delete:
            model.deleteGroup(group.id)
            return "Grupo \(group.name) apagado; os Orbs continuam."
        }
    }

    /// Checks an `orb_delete` against the Orbs as they are now, changing nothing: the Orb to delete (by its whole name, never a
    /// prefix) and the text of the user's card. A refusal says what to do instead.
    private func planOrbDelete(_ arguments: JSONValue, by botID: UUID) throws -> (orb: OrbRef, confirmation: String) {
        guard let model, !isShuttingDown else { throw ToolError("The app is closing.") }
        guard model.orbsCanManageGroups else {
            throw ToolError("The user switched off \"Orbs organizam o time\": tell them which Orb you would delete and why.")
        }
        let typed = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = DelegationRules.fold(typed)
        let matches = model.bots.filter { DelegationRules.fold($0.name) == wanted }
        guard !wanted.isEmpty, matches.count == 1, let target = matches.first else {
            throw ToolError(matches.count > 1 ? "More than one Orb is named \"\(typed)\": the user can delete it on their screen."
                            : "No Orb is named \"\(typed)\" (use the whole name; orbs list shows them).")
        }
        guard target.id != botID else { throw ToolError("You cannot delete yourself: ask the user if you should go.") }
        guard model.liveBot(target.id)?.isWorking != true, model.sessions[target.id]?.turnTask == nil else {
            throw ToolError("\(target.name) is working right now: try again when it is free.")
        }
        let reason = String(MemoryText.flatten(MemorySanitizer.scrub(arguments["reason"]?.string ?? "")).prefix(200))
        let who = model.bot(botID)?.name ?? "Um Orb"
        let because = reason.isEmpty ? "" : " Motivo: \(reason)"
        return (OrbRef(target), "\(who) quer apagar \(PortugueseArticle.article(for: target.name)) \(target.name).\(because) "
            + "A conversa, a memória e as rotinas dele vão embora, e ele sai dos grupos.")
    }

    /// `orb_delete` once the user confirmed in the tool's card (`confirmed` is set by the tool alone).
    private func deleteOrb(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model else { throw ToolError("The app is closing.") }
        let plan = try planOrbDelete(arguments, by: botID)
        guard arguments["confirmed"]?.bool == true else { throw ToolError("The user did not confirm. Nothing changed.") }
        model.deleteBot(plan.orb.id)
        return "\(plan.orb.name) was deleted."
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
            else if session.sideKind == .pulse, let run = session.routineID { .pulse(run) }
            else { .chat(sender.id) }
        return ChainState(origin: origin, originBot: sender.id, groupID: groupID, chat: session.conversationChat)
    }

    /// Wakes the Orb's queue on the next turn of the main actor, never inside the call that changed it.
    private func schedulePump(_ botID: UUID) {
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

