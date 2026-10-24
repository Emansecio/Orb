import AppKit
import Foundation

/// The runtime of the groups: the loop of docs/historico/MULTI-ORBS.md 7.3. The person's message goes to the orchestrator (or to the members
/// it @mentions); the orchestrator plans and assigns with `orbs ask`; the members work in turns of their own, in parallel, and talk
/// to each other when they need to; every answer wakes whoever asked, until the orchestrator closes the round with the final
/// answer and nothing is left to do. Nothing limits a request's turns or tokens (the header counts them); Parar grupo cancels
/// everything.
///
/// The hub does not run the turns. It asks the delegation service for them (`submitGroupTurn`) and is told, through
/// `GroupTurnHooks`, when each one is about to start (`prompt`), starts and ends. What it needs from the delegation hub, besides
/// the WP0 interfaces: `refusal(forRequestFrom:…)` before a member's `orbs ask` is accepted (the group's policy).
@MainActor
final class GroupHub: GroupTurnHooks {
    /// The turn a member is in right now (the engine asks `AppModel.groupTurnExtras` which group it belongs to).
    struct ActiveTurn: Equatable, Sendable {
        var groupID: UUID
        var runID: UUID
        var requestID: UUID
    }

    private(set) weak var model: AppModel?
    var delegation: any DelegationService {
        didSet { delegation.groupHooks = self }
    }
    /// The requests in progress, by group.
    private(set) var runs: [UUID: GroupRun] = [:]
    private(set) var activeTurns: [UUID: ActiveTurn] = [:]
    /// Where each member's last turn in each group left the thread, so the next turn is handed only what came after.
    private var consumed: [UUID: [UUID: Int]] = [:]
    /// The person's messages a turn not yet started answers, by request (more than one when they wrote again before it began:
    /// `enqueue`). Its preface leaves them out of the thread.
    private var personTexts: [UUID: [String]] = [:]
    /// The pictures that came with those messages, by request (paths only: the bytes are read once, when the member's turn is sent).
    private var personImages: [UUID: [ImageAttachment]] = [:]
    /// How long after a turn ends the hub waits before deciding the request is over (the delegation hub may still be waking
    /// whoever asked).
    var settle: Duration = .milliseconds(80)
    /// Whether the person is looking at the group right now (its thread open in a window that is in front).
    var isFocused: @MainActor (UUID) -> Bool = { _ in false }
    /// Whether the app is in front (a banner is only for a person who is elsewhere).
    var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    /// Shows a banner (title, body, group). The app posts it through the Notification Center; tests record it.
    var postNotice: @MainActor (String, String, UUID) -> Void = { _, _, _ in }
    var now: @MainActor () -> Date = { .now }
    /// At most one banner per group in this interval.
    var noticeInterval: TimeInterval = 5
    private var lastNotice: [UUID: Date] = [:]

    init(model: AppModel, delegation: any DelegationService) {
        self.model = model
        self.delegation = delegation
        delegation.groupHooks = self
    }

    // MARK: Questions

    func run(_ groupID: UUID) -> GroupRun? { runs[groupID] }

    /// The request of the group that is going on.
    func activeRun(_ groupID: UUID) -> GroupRun? { runs[groupID].flatMap { $0.isOpen ? $0 : nil } }

    func isActive(_ groupID: UUID) -> Bool { activeRun(groupID) != nil }

    /// The group an Orb is working for right now, if any.
    func activeGroup(of botID: UUID) -> UUID? { activeTurns[botID]?.groupID }

    func turn(of botID: UUID) -> ActiveTurn? { activeTurns[botID] }

    // MARK: The person's messages

    /// The person writes to the group. The message goes into the thread and reaches the orchestrator, or the members it
    /// @mentions, with its pictures (the same ones to each, by path). Returns false when nothing was sent (no such group, a
    /// message with neither text nor picture, more pictures than a message may carry, the app is resetting).
    @discardableResult
    func postUserMessage(_ raw: String, images: [ImageAttachment] = [], to groupID: UUID) -> Bool {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isResetting, !typed.isEmpty || !images.isEmpty, images.count <= ImageProcessing.maxPerMessage,
              let group = model.group(groupID), let session = model.groupSession(groupID) else { return false }
        // What the members are asked when the message is only pictures, as in an Orb's chat.
        let text = typed.isEmpty ? AppModel.attachmentsOnlyPrompt : typed
        let isNew = activeRun(groupID) == nil
        if isNew { runs[groupID] = .new(group: group, request: text, now: now()) }
        session.append(.user(text: typed, attachments: images.map(\.path)))
        markRead(groupID)
        var targets = Mentions.parse(typed, members: group.memberIDs.map { reference($0) })
        if targets.isEmpty { targets = [group.orchestratorID] }
        let live = model.groupLive(groupID)
        if isNew {
            live.setRunState(.running)
            refreshLive(groupID)
        }
        for member in targets { enqueue(member, text: text, shown: typed, images: images, in: groupID) }
        return true
    }

    /// A member asks the group from its own chat, at the person's request (`orbs ask` with the group's name,
    /// `DelegationHub.submitToGroup`): a new request of the group, as if the person had typed it, but written in the thread as
    /// the member's ("a seu pedido") and handed to the orchestrator as data, not as the person's word. The group's final answer
    /// goes back to the member's chat. With the group already at work, it joins that request, like a message of the person
    /// would: the orchestrator takes it after its current turn. Nil when the group cannot take it.
    func postOrbRequest(from asker: UUID, text: String, to groupID: UUID, messageID: UUID) -> DelegationRequest? {
        guard let model, !model.isResetting, let group = model.group(groupID), group.memberIDs.contains(asker),
              let session = model.groupSession(groupID) else { return nil }
        let isNew = activeRun(groupID) == nil
        if isNew { runs[groupID] = .new(group: group, request: text, now: now()) }
        guard let run = runs[groupID] else { return nil }
        let chain = ChainContext(chainID: run.id, hop: 1, path: [asker], groupID: groupID, serving: nil)
        let request = delegation.submitGroupRequest(from: asker, text: text, chain: chain, groupID: groupID,
                                                    orchestrator: group.orchestratorID, id: messageID)
        guard request.state == .queued else {
            if isNew { runs[groupID] = nil }
            refreshLive(groupID)
            return nil
        }
        // The request is the run's own, as the person's would be: its answer is the final one, and it is written here once.
        runs[groupID]?.asked[request.envelope.id] = group.orchestratorID
        runs[groupID]?.posted.insert(request.envelope.id)
        session.append(.orbMessage(OrbMessageItem(direction: .post, kind: .ask, state: .open, from: reference(asker),
                                                  to: reference(group.orchestratorID), text: text, requestID: request.envelope.id,
                                                  chainID: run.id, groupID: groupID, fromChat: true)))
        addUnread(groupID)
        model.groupLive(groupID).setRunState(.running)
        refreshLive(groupID)
        scheduleIdleCheck(groupID)
        return request
    }

    /// Asks `member` for a turn on behalf of the person. `shown` is the message as typed (empty for pictures alone): what the
    /// thread has of it, so the preface can leave it out.
    private func enqueue(_ member: UUID, text: String, shown: String, images: [ImageAttachment], in groupID: UUID) {
        guard let model, let run = activeRun(groupID), model.group(groupID)?.memberIDs.contains(member) == true else { return }
        // A message right after another, before the member's turn for it began, goes with it: one turn reads both.
        if let joined = delegation.joinQueuedGroupTurn(member: member, chainID: run.id, text: text) {
            personTexts[joined.envelope.id, default: []].append(shown)
            if !images.isEmpty { personImages[joined.envelope.id, default: []] += images }
            return
        }
        let chain = ChainContext(chainID: run.id, hop: 1, path: [], groupID: groupID, serving: nil)
        let request = delegation.submitGroupTurn(member: member, text: text, chain: chain, groupID: groupID, askedBy: nil)
        switch request.state {
        case .failed, .cancelled:
            model.groupSession(groupID)?.append(.notice("\(name(of: member)) não pôde responder agora."))
        case .replied:
            break
        default:
            runs[groupID]?.asked[request.envelope.id] = member
            personTexts[request.envelope.id] = [shown]
            if !images.isEmpty { personImages[request.envelope.id] = images }
        }
        scheduleIdleCheck(groupID)
    }

    // MARK: GroupTurnHooks

    func prompt(for request: DelegationRequest, member: UUID) async -> String {
        guard let (group, run) = lookup(request), let model, let session = model.groupSession(group.id) else { return "" }
        noteActive(member, request: request, group: group.id, run: run.id)
        let fromUser = isFromUser(request, in: run)
        postAssignment(request, fromUser: fromUser, group: group, run: run)
        let from = min(consumed[group.id]?[member] ?? 0, session.items.count)
        let slice = session.items[from...]
        consumed[group.id, default: [:]][member] = session.items.count
        let asked = personTexts.removeValue(forKey: request.envelope.id) ?? [request.envelope.text]
        let thread = GroupThread.lines(from: slice, member: member, request: request.envelope.id,
                                       userTexts: fromUser ? asked.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : [])
        let board = await GroupBoard.brief(bank: model.memory.groupBank(for: group.id), message: request.envelope.text)
        let members = group.memberIDs.map { id in
            GroupPrompt.Member(name: name(of: id), role: model.bot(id)?.role ?? "", isOrchestrator: id == group.orchestratorID,
                               waitsForUser: id != member && model.liveBot(id)?.needsYou == true)
        }
        return GroupPrompt.preface(.init(groupName: group.name, you: name(of: member),
                                         role: member == group.orchestratorID ? .orchestrator : .member,
                                         members: members,
                                         thread: thread, board: board))
    }

    /// The pictures of the person's message(s) this turn answers. Not taken out: a turn put back in the queue because the
    /// Orb was busy asks again, and must not lose them (`turnFinished` lets go).
    func images(for request: DelegationRequest) -> [ImageAttachment] {
        personImages[request.envelope.id] ?? []
    }

    func turnStarted(_ request: DelegationRequest) {
        guard let (group, run) = lookup(request) else { return }
        let member = request.envelope.to.id
        postAssignment(request, fromUser: isFromUser(request, in: run), group: group, run: run)
        noteActive(member, request: request, group: group.id, run: run.id)
        update(group.id) { run in
            run.turnsUsed += 1
            run.running.removeAll { $0.request == request.envelope.id }
            run.running.append(.init(request: request.envelope.id, member: member))
            run.note(participant: member)
        }
        refreshLive(group.id)
    }

    func turnFinished(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus) {
        guard let (group, run) = lookup(request), let session = model?.groupSession(group.id) else { return }
        let member = request.envelope.to.id
        let fromUser = isFromUser(request, in: run)
        let interim = request.state == .awaitingChildren || !request.openChildren.isEmpty
        personImages[request.envelope.id] = nil // the turn is over (or was cancelled before it began)
        if activeTurns[member]?.requestID == request.envelope.id { activeTurns[member] = nil }
        update(group.id) { run in
            run.running.removeAll { $0.request == request.envelope.id }
            if !interim { run.asked[request.envelope.id] = nil }
        }
        let text = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .ok:
            if !text.isEmpty {
                // The answer to a member who asked from its chat says where it went ("Atlas → Gestor"), unless it is its own.
                let envelope = request.envelope
                let toAsker = envelope.from.id != member && (!fromUser || envelope.fromChat)
                let asker = toAsker ? reference(envelope.from.id) : nil
                let post = OrbMessageItem(direction: .post, kind: interim ? .tell : .reply, state: .replied, from: reference(member),
                                          to: asker, text: String(text.prefix(DelegationLimits.replyLimit)),
                                          requestID: request.envelope.id, chainID: run.id, groupID: group.id)
                session.append(.orbMessage(post))
                addUnread(group.id)
                update(group.id) { run in
                    run.lastText = text
                    if !interim, member == group.orchestratorID, fromUser { run.finalText = text }
                }
            }
            setAssignment(request.envelope.id, to: .replied, in: session)
        case .failed, .refused:
            let why = text.isEmpty ? "" : ": " + MemoryText.clip(MemoryText.flatten(text), 160)
            session.append(.notice("\(name(of: member)) não conseguiu responder\(why)"))
            setAssignment(request.envelope.id, to: outcome == .refused ? .refused : .failed, in: session)
            addUnread(group.id)
        case .cancelled:
            setAssignment(request.envelope.id, to: .cancelled, in: session)
        }
        refreshLive(group.id)
        scheduleIdleCheck(group.id)
    }

    func noticePosted(_ envelope: OrbEnvelope) {
        guard let groupID = envelope.groupID, let run = activeRun(groupID), run.id == envelope.chainID,
              let session = model?.groupSession(groupID) else { return }
        let post = OrbMessageItem(direction: .post, kind: .tell, state: .replied, from: reference(envelope.from.id),
                                  to: reference(envelope.to.id), text: String(envelope.text.prefix(DelegationLimits.messageLimit)),
                                  requestID: envelope.id, chainID: run.id, groupID: groupID)
        session.append(.orbMessage(post))
        addUnread(groupID)
    }

    func chainStopped(_ chainID: UUID) {
        guard let groupID = runs.first(where: { $0.value.id == chainID && $0.value.isOpen })?.key else { return }
        stopGroup(groupID)
    }

    func refusal(forRequestFrom asker: UUID, to member: UUID, chain: UUID) -> DelegationRefusal? {
        guard let entry = runs.first(where: { $0.value.id == chain }), let group = model?.group(entry.key) else { return nil }
        guard group.memberIDs.contains(member), group.memberIDs.contains(asker) else { return .notInGroup }
        if !group.policy.membersMayTalk, asker != group.orchestratorID { return .membersMayNotTalk }
        return nil
    }

    // MARK: Tokens

    /// Tokens a member's turn used (from the usage record of the turn), for the request's count.
    func noteTokens(_ tokens: Int, botID: UUID) {
        guard tokens > 0, let turn = activeTurns[botID] else { return }
        addTokens(tokens, group: turn.groupID, run: turn.runID)
    }

    private func addTokens(_ tokens: Int, group groupID: UUID, run runID: UUID) {
        guard runs[groupID]?.id == runID else { return }
        update(groupID) { $0.tokensUsed += tokens }
        refreshLive(groupID)
    }

    // MARK: Stopping

    /// "Parar grupo" and ⌘.: everything the group is doing stops.
    func stopGroup(_ groupID: UUID) { terminate(groupID, by: .user) }

    private func terminate(_ groupID: UUID, by reason: CancelReason, writesEvent: Bool = true) {
        guard let model, let run = activeRun(groupID) else { return }
        let members = Set(run.running.map(\.member)).union(activeTurns.filter { $0.value.runID == run.id }.keys)
        runs[groupID]?.phase = .stopped
        // The turns that did not begin will not.
        for id in run.asked.keys {
            personTexts[id] = nil
            personImages[id] = nil
        }
        runs[groupID]?.asked = [:]
        delegation.cancelChain(run.id, by: reason)
        for member in members {
            activeTurns[member] = nil
            model.stop(member, startsQueuedRoutines: false)
        }
        if writesEvent {
            model.groupSession(groupID)?.append(.event(OrbEvent(kind: .groupStopped, chainID: run.id, groupID: groupID)))
        }
        runs[groupID] = nil
        refreshLive(groupID)
    }

    // MARK: When the request is over

    private func scheduleIdleCheck(_ groupID: UUID) {
        guard let run = runs[groupID] else { return }
        let runID = run.id
        let wait = settle
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) } else { await Task.yield() }
            self?.finishIfIdle(groupID, run: runID)
        }
    }

    /// Whether the request has nothing left: no turn running, none asked and not started, no one waiting for an answer or
    /// holding one to deliver.
    private func isIdle(_ run: GroupRun, group: OrbGroup) -> Bool {
        guard run.phase == .active, run.running.isEmpty, run.asked.isEmpty else { return false }
        for member in group.memberIDs {
            if delegation.chains(involving: member).contains(run.id) { return false }
            let open = delegation.openRequests(from: member).contains {
                $0.envelope.chainID == run.id && [.queued, .running, .awaitingChildren].contains($0.state)
            }
            if open { return false }
        }
        return true
    }

    private func finishIfIdle(_ groupID: UUID, run runID: UUID) {
        guard let model, let run = runs[groupID], run.id == runID, let group = model.group(groupID), isIdle(run, group: group),
              let session = model.groupSession(groupID) else { return }
        // Nothing ran (the first turn could not even be asked): no "concluded" line for a request that did nothing.
        guard run.turnsUsed > 0 else {
            runs[groupID] = nil
            refreshLive(groupID)
            return
        }
        update(groupID) { $0.phase = .done }
        let summary = GroupUsageText.summary(turns: run.turnsUsed, tokens: run.tokensUsed)
        session.append(.event(OrbEvent(kind: .groupRunDone, detail: summary, chainID: run.id, groupID: groupID)))
        // The page of the board: what was asked and what the group came to (rules only, no model).
        let page = GroupBoard.sessionPage(request: run.request, result: run.finalText ?? run.lastText ?? "",
                                          members: run.participants.map { name(of: $0) }, turns: run.turnsUsed,
                                          tokens: run.tokensUsed, group: group.name, started: run.startedAt, ended: now())
        // Each member's own chat gets a line, and its next turn what the member did here (the thread is not its chat).
        for member in run.participants {
            let said = session.conversation.items.compactMap { item -> String? in
                guard case .orbMessage(let post) = item.kind, post.direction == .post, post.chainID == run.id,
                      post.from.id == member else { return nil }
                return post.text
            }
            let work = SinceLastTurn.groupWork(request: run.request, said: said, result: run.finalText ?? run.lastText)
            model.appendToChat(.event(OrbEvent(kind: .groupWorked, subject: model.orbRef(member), detail: group.name, chainID: run.id,
                                               groupID: groupID, context: work)), of: member)
        }
        let bank = model.memory.groupBank(for: groupID)
        Task {
            if await !bank.saveSession(page) {
                session.append(.notice("Não consegui guardar este pedido no quadro do grupo (falta espaço ou permissão na pasta)."))
            }
        }
        runs[groupID] = nil
        refreshLive(groupID)
        notifyAway(groupID, title: group.name, body: "O grupo terminou: " + summary)
    }

    // MARK: A member leaves, a group goes

    /// A group is deleted, dissolved or its member removed while its request is going: it ends without a trace in the thread
    /// (the thread goes with the group), or with the "parou" line if the group stays.
    func forget(_ groupID: UUID, writesEvent: Bool) {
        terminate(groupID, by: .user, writesEvent: writesEvent)
        runs[groupID] = nil
        consumed[groupID] = nil
        lastNotice[groupID] = nil
    }

    /// Whether the Orb is in a turn of the group's running request.
    func isWorking(_ botID: UUID, in groupID: UUID) -> Bool { activeTurns[botID]?.groupID == groupID }

    /// A member's approval card opened or closed: the group says it waits for you.
    func memberWaitChanged(_ botID: UUID) {
        guard let model else { return }
        let groups = model.groups.filter { $0.memberIDs.contains(botID) }.map(\.id)
        for groupID in groups { refreshLive(groupID) }
    }

    // MARK: Live state

    private func refreshLive(_ groupID: UUID) {
        guard let model else { return }
        let live = model.groupLive(groupID)
        guard let run = runs[groupID], let group = model.group(groupID) else {
            live.setRunState(.idle)
            live.setTyping([])
            live.setWaiting([])
            live.setWork(nil)
            live.setUsage(nil)
            return
        }
        live.setRunState(run.phase == .active ? .running : .idle)
        var typing: [UUID] = []
        for turn in run.running where !typing.contains(turn.member) { typing.append(turn.member) }
        live.setTyping(typing)
        let waiting = typing.filter { model.liveBot($0)?.needsYou == true }
        live.setWaiting(waiting)
        live.setUsage(run.usage)
        live.setWork(GroupPresence.line(typing: typing.map { name(of: $0) }, waiting: waiting.map { name(of: $0) },
                                        orchestratorOnly: !typing.isEmpty && typing.allSatisfy { $0 == group.orchestratorID },
                                        orchestrator: name(of: group.orchestratorID)))
    }

    // MARK: Unread and banners

    func addUnread(_ groupID: UUID) {
        guard let model, !isFocused(groupID), let session = model.groupSession(groupID) else { return }
        session.addUnread()
        model.groupLive(groupID).setUnread(session.unread)
    }

    func markRead(_ groupID: UUID) {
        guard let model else { return }
        model.groupSessions[groupID]?.clearUnread()
        model.groupLives[groupID]?.setUnread(0)
    }

    /// A banner, only while the app is not in front and not more than once in `noticeInterval` per group.
    private func notifyAway(_ groupID: UUID, title: String, body: String) {
        guard !isAppActive() else { return }
        let moment = now()
        if let last = lastNotice[groupID], moment.timeIntervalSince(last) < noticeInterval { return }
        lastNotice[groupID] = moment
        postNotice(title, body, groupID)
    }

    // MARK: Helpers

    private func lookup(_ request: DelegationRequest) -> (OrbGroup, GroupRun)? {
        guard let groupID = request.envelope.groupID, let run = runs[groupID], run.isOpen, run.id == request.envelope.chainID,
              let group = model?.group(groupID) else { return nil }
        return (group, run)
    }

    private func isFromUser(_ request: DelegationRequest, in run: GroupRun) -> Bool {
        run.asked[request.envelope.id] != nil || request.envelope.from.id == request.envelope.to.id
    }

    private func noteActive(_ member: UUID, request: DelegationRequest, group: UUID, run: UUID) {
        activeTurns[member] = ActiveTurn(groupID: group, runID: run, requestID: request.envelope.id)
    }

    private func update(_ groupID: UUID, _ change: (inout GroupRun) -> Void) {
        guard var run = runs[groupID] else { return }
        change(&run)
        runs[groupID] = run
    }

    /// The line of the thread that shows an Orb handing work to another ("Atlas → Pesquisador: …"), written the first time the
    /// request is seen.
    private func postAssignment(_ request: DelegationRequest, fromUser: Bool, group: OrbGroup, run: GroupRun) {
        guard !fromUser, request.envelope.kind != .reply, runs[group.id]?.posted.contains(request.envelope.id) == false,
              let session = model?.groupSession(group.id) else { return }
        runs[group.id]?.posted.insert(request.envelope.id)
        let item = OrbMessageItem(direction: .post, kind: request.envelope.kind == .tell ? .tell : .ask, state: .open,
                                  from: reference(request.envelope.from.id), to: reference(request.envelope.to.id),
                                  text: String(request.envelope.text.prefix(DelegationLimits.messageLimit)),
                                  requestID: request.envelope.id, chainID: run.id, groupID: group.id)
        session.append(.orbMessage(item))
    }

    private func setAssignment(_ requestID: UUID, to state: OrbMessageItem.State, in session: GroupSession) {
        session.updateAll(where: { kind in
            if case .orbMessage(let message) = kind { return message.requestID == requestID && message.direction == .post && message.kind != .reply }
            return false
        }, { kind in
            if case .orbMessage(var message) = kind {
                message.state = state
                kind = .orbMessage(message)
            }
        })
    }

    private func name(of botID: UUID) -> String { model?.bot(botID)?.name ?? "Orb" }

    private func reference(_ botID: UUID) -> OrbRef { OrbRef(id: botID, name: name(of: botID)) }
}

/// What the group says it is doing, in the words the sidebar and the header use (the presence strip's half is in
/// `GroupPresenceStrip.swift`).
extension GroupPresence {
    /// "Atlas coordena…", "Pesquisador trabalhando…", "Pesquisador e Revisor trabalhando…", "Pesquisador espera você"; nil
    /// when no one is in a turn.
    static func line(typing: [String], waiting: [String], orchestratorOnly: Bool, orchestrator: String) -> WorkLine? {
        if !waiting.isEmpty { return WorkLine(verb: "\(list(waiting)) \(waiting.count == 1 ? "espera" : "esperam") você", tone: .waiting) }
        guard !typing.isEmpty else { return nil }
        if orchestratorOnly { return WorkLine(verb: "\(orchestrator) coordena") }
        return WorkLine(verb: "\(list(typing)) trabalhando")
    }

    /// "A", "A e B", "A, B e C".
    static func list(_ names: [String]) -> String {
        PortugueseList.join(names)
    }
}
