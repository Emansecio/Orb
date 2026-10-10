import AppKit
import Foundation

/// The runtime of the groups: the loop of docs/MULTI-ORBS.md 7.3. The person's message goes to the orchestrator (or to the members
/// it @mentions); the orchestrator plans and assigns with `orbs ask`; the members work in turns of their own, in parallel, and talk
/// to each other when they need to; every answer wakes whoever asked, until the orchestrator closes the round with the final
/// answer and nothing is left to do. A request has a budget (turns and tokens); when it is spent the group pauses and the
/// person decides (Continuar / Encerrar). Parar grupo cancels everything.
///
/// The hub does not run the turns. It asks the delegation service for them (`submitGroupTurn`) and is told, through
/// `GroupTurnHooks`, when each one is about to start (`prompt`), starts and ends. What it needs from the delegation hub, besides
/// the WP0 interfaces: `canStartTurn` before a queued turn or a wake-up starts and `refusal(forRequestFrom:…)` before a member's
/// `orbs ask` is accepted (both default to "yes"), and `resumeHeldWork` after "Continuar".
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

    /// The request of the group that is going on (running or paused).
    func activeRun(_ groupID: UUID) -> GroupRun? { runs[groupID].flatMap { $0.isOpen ? $0 : nil } }

    func isActive(_ groupID: UUID) -> Bool { activeRun(groupID) != nil }

    /// The group an Orb is working for right now, if any.
    func activeGroup(of botID: UUID) -> UUID? { activeTurns[botID]?.groupID }

    func turn(of botID: UUID) -> ActiveTurn? { activeTurns[botID] }

    // MARK: The person's messages

    /// The person writes to the group. The message always goes into the thread; it reaches the orchestrator, or the members it
    /// @mentions, unless the group is paused (then it waits for the person's decision on the card). Returns false when nothing
    /// was sent (no such group, an empty message, the app is resetting).
    @discardableResult
    func postUserMessage(_ raw: String, to groupID: UUID) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isResetting, !text.isEmpty, let group = model.group(groupID),
              let session = model.groupSession(groupID) else { return false }
        let isNew = activeRun(groupID) == nil
        if isNew { runs[groupID] = .new(group: group, request: text, now: now()) }
        session.append(.user(text: text, attachments: []))
        markRead(groupID)
        var targets = Mentions.parse(text, members: group.memberIDs.map { reference($0) })
        if targets.isEmpty { targets = [group.orchestratorID] }
        let live = model.groupLive(groupID)
        if isNew {
            live.setRunState(.running)
            refreshLive(groupID)
        }
        for member in targets {
            if runs[groupID]?.isPaused == true {
                runs[groupID]?.held.append(.init(member: member, text: text))
            } else {
                enqueue(member, text: text, in: groupID)
            }
        }
        return true
    }

    /// Asks `member` for a turn on behalf of the person.
    private func enqueue(_ member: UUID, text: String, in groupID: UUID) {
        guard let model, let run = activeRun(groupID), model.group(groupID)?.memberIDs.contains(member) == true else { return }
        guard run.budgetAllows else {
            runs[groupID]?.held.append(.init(member: member, text: text))
            pause(groupID)
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
        let thread = GroupThread.lines(from: slice, member: member, request: request.envelope.id,
                                       userText: fromUser ? request.envelope.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        let board = await GroupBoard.brief(bank: model.memory.groupBank(for: group.id), message: request.envelope.text)
        let current = runs[group.id] ?? run
        let members = group.memberIDs.map { id in
            GroupPrompt.Member(name: name(of: id), role: model.bot(id)?.role ?? "", isOrchestrator: id == group.orchestratorID)
        }
        return GroupPrompt.preface(.init(groupName: group.name, you: name(of: member),
                                         role: member == group.orchestratorID ? .orchestrator : .member,
                                         turnsUsed: current.turnsUsed, turnLimit: current.turnLimit, members: members,
                                         thread: thread, board: board))
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
        if activeTurns[member]?.requestID == request.envelope.id { activeTurns[member] = nil }
        update(group.id) { run in
            run.running.removeAll { $0.request == request.envelope.id }
            if !interim { run.asked[request.envelope.id] = nil }
        }
        let text = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .ok:
            if !text.isEmpty {
                let asker = fromUser ? nil : reference(request.envelope.from.id)
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

    func canStartTurn(_ request: DelegationRequest) -> Bool {
        guard let (group, run) = lookup(request) else { return true }
        if run.isPaused { return false }
        guard run.budgetAllows else {
            pause(group.id)
            return false
        }
        return true
    }

    func refusal(forRequestFrom asker: UUID, to member: UUID, chain: UUID) -> DelegationRefusal? {
        guard let entry = runs.first(where: { $0.value.id == chain }), let group = model?.group(entry.key) else { return nil }
        guard group.memberIDs.contains(member), group.memberIDs.contains(asker) else { return .notInGroup }
        if entry.value.isPaused || !entry.value.budgetAllows {
            pause(group.id)
            return .budgetSpent
        }
        if !group.policy.membersMayTalk, asker != group.orchestratorID { return .notInGroup }
        return nil
    }

    // MARK: Tokens

    /// Tokens a member's turn used (from the usage record of the turn): they count against the request's budget. The request is
    /// not paused here; the next turn that wants to start finds the budget spent (`canStartTurn`), so a request that was about to
    /// end anyway does not stop to ask.
    func noteTokens(_ tokens: Int, botID: UUID) {
        guard tokens > 0, let turn = activeTurns[botID] else { return }
        addTokens(tokens, group: turn.groupID, run: turn.runID)
    }

    /// The same, by chain (the delegation hub's `tokensUsed(_:chain:)`).
    func tokensUsed(_ tokens: Int, chain: UUID) {
        guard tokens > 0, let entry = runs.first(where: { $0.value.id == chain }) else { return }
        addTokens(tokens, group: entry.key, run: chain)
    }

    private func addTokens(_ tokens: Int, group groupID: UUID, run runID: UUID) {
        guard runs[groupID]?.id == runID else { return }
        update(groupID) { $0.tokensUsed += tokens }
        refreshLive(groupID)
    }

    // MARK: Budget: pause, continue, end

    /// Pauses the request: no new turn starts (the ones running finish), and a card in the thread asks the person.
    func pause(_ groupID: UUID) {
        guard let model, let run = runs[groupID], run.phase == .active, let reason = run.exhausted,
              let session = model.groupSession(groupID) else { return }
        update(groupID) { $0.phase = .paused(reason) }
        session.append(.groupPause(GroupPauseItem(groupID: groupID, runID: run.id, reason: reason, state: .open,
                                                  turnsUsed: run.turnsUsed, tokensUsed: run.tokensUsed,
                                                  turnLimit: run.turnLimit, tokenLimit: run.tokenLimit)))
        addUnread(groupID)
        refreshLive(groupID)
        notifyAway(groupID, title: model.group(groupID)?.name ?? "Grupo", body: "O grupo pausou: continuar?")
    }

    /// "Continuar": another window of the budget on top of what was spent; the turns held back go out.
    func continueRun(_ groupID: UUID) {
        guard let model, let group = model.group(groupID), let run = runs[groupID], run.isPaused else { return }
        update(groupID) { run in
            run.extend(by: group.budget)
            run.phase = .active
        }
        resolvePauseCards(groupID, run: run.id, to: .continued)
        let held = runs[groupID]?.held ?? []
        runs[groupID]?.held = []
        refreshLive(groupID)
        for turn in held { enqueue(turn.member, text: turn.text, in: groupID) }
        delegation.resumeHeldWork(chain: run.id)
        scheduleIdleCheck(groupID)
    }

    /// "Encerrar": the queue is cancelled and the request is over.
    func endRun(_ groupID: UUID) { terminate(groupID, by: .budget) }

    /// "Parar grupo" and ⌘.: everything the group is doing stops.
    func stopGroup(_ groupID: UUID) { terminate(groupID, by: .user) }

    private func terminate(_ groupID: UUID, by reason: CancelReason, writesEvent: Bool = true) {
        guard let model, let run = activeRun(groupID) else { return }
        let members = Set(run.running.map(\.member)).union(activeTurns.filter { $0.value.runID == run.id }.keys)
        runs[groupID]?.phase = .stopped
        runs[groupID]?.held = []
        runs[groupID]?.asked = [:]
        delegation.cancelChain(run.id, by: reason)
        for member in members {
            activeTurns[member] = nil
            model.stop(member, startsQueuedRoutines: false)
        }
        resolvePauseCards(groupID, run: run.id, to: .ended)
        if writesEvent {
            model.groupSession(groupID)?.append(.event(OrbEvent(kind: .groupStopped, chainID: run.id, groupID: groupID)))
        }
        runs[groupID] = nil
        refreshLive(groupID)
    }

    private func resolvePauseCards(_ groupID: UUID, run runID: UUID, to state: GroupPauseItem.State) {
        model?.groupSession(groupID)?.updateAll(where: { kind in
            if case .groupPause(let pause) = kind { return pause.runID == runID && pause.state == .open }
            return false
        }, { kind in
            if case .groupPause(var pause) = kind {
                pause.state = state
                kind = .groupPause(pause)
            }
        })
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
        guard run.phase == .active, run.running.isEmpty, run.asked.isEmpty, run.held.isEmpty else { return false }
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
        let bank = model.memory.groupBank(for: groupID)
        Task { await bank.saveSession(page) }
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
            live.setBudget(nil)
            return
        }
        switch run.phase {
        case .active: live.setRunState(.running)
        case .paused(let reason): live.setRunState(.paused(reason))
        case .done, .stopped: live.setRunState(.idle)
        }
        var typing: [UUID] = []
        for turn in run.running where !typing.contains(turn.member) { typing.append(turn.member) }
        live.setTyping(typing)
        let waiting = typing.filter { model.liveBot($0)?.needsYou == true }
        live.setWaiting(waiting)
        live.setBudget(run.usage)
        live.setWork(GroupPresence.line(typing: typing.map { name(of: $0) }, waiting: waiting.map { name(of: $0) },
                                        orchestratorOnly: !typing.isEmpty && typing.allSatisfy { $0 == group.orchestratorID },
                                        orchestrator: name(of: group.orchestratorID), paused: run.isPaused))
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

/// What the group says it is doing, in the words the sidebar and the header use.
enum GroupPresence {
    /// "Atlas coordena…", "Pesquisador trabalhando…", "Pesquisador e Revisor trabalhando…", "Pesquisador espera você", "Pausado:
    /// continuar?"; nil when no one is in a turn.
    static func line(typing: [String], waiting: [String], orchestratorOnly: Bool, orchestrator: String, paused: Bool) -> WorkLine? {
        if paused { return WorkLine(verb: "Pausado: continuar?", tone: .waiting) }
        if !waiting.isEmpty { return WorkLine(verb: "\(list(waiting)) \(waiting.count == 1 ? "espera" : "esperam") você", tone: .waiting) }
        guard !typing.isEmpty else { return nil }
        if orchestratorOnly { return WorkLine(verb: "\(orchestrator) coordena") }
        return WorkLine(verb: "\(list(typing)) trabalhando")
    }

    /// "A", "A e B", "A, B e C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1]
        }
    }
}
