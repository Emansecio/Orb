import SwiftUI

/// The group on show, and what ⌘. stops. The views read these; the group's runtime is behind them.
extension AppModel {
    /// The group the selection shows, when it still exists.
    var selectedGroupID: UUID? {
        if case .group(let id)? = selection, groups.contains(where: { $0.id == id }) { return id }
        return nil
    }

    /// ⌘. stops the group on show while it has a request; otherwise the Orb's answer, as before.
    var canStopSelection: Bool {
        if let id = selectedGroupID { return groupLive(id).runState != .idle }
        return canStopCurrent
    }

    func stopSelection() {
        if let id = selectedGroupID { stopGroup(id) } else { stopCurrent() }
    }

    /// The members of a group as the Orbs are now; an Orb that was deleted is left out.
    func groupLooks(_ group: OrbGroup) -> [BotLook] {
        group.memberIDs.compactMap { liveBot($0)?.look }
    }

    /// The members in a turn right now, in the group's order, with what each one does (the presence line and the sidebar).
    func groupPresence(_ group: OrbGroup, live groupState: GroupLive) -> [GroupPresenceItem] {
        group.memberIDs.filter { groupState.typing.contains($0) }.compactMap { id in
            guard let look = liveBot(id)?.look else { return nil }
            let bot = live(id)
            return GroupPresenceItem(id: id, name: look.name, orb: look.orb,
                                     state: GroupPresence.state(of: bot.activity, needsYou: bot.needsYou,
                                                                isOrchestrator: id == group.orchestratorID))
        }
    }
}

/// A group's chat: the thread of what the person and the members said, the header with what the request has spent while it runs,
/// the presence line and the composer. Reads the group, its thread and its live state; the Orbs' own rows are not drawn here.
struct GroupChatView: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    /// The thread once it is read; set by the task, so the body never touches the disk.
    @State private var loaded: GroupSession?

    var body: some View {
        if let group = model.groups.first(where: { $0.id == groupID }) {
            Group {
                if let session = model.loadedGroupSession(groupID) ?? loaded {
                    GroupConversation(group: group, session: session, live: model.groupLive(groupID))
                } else {
                    LoadingTranscript()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Palette.canvas)
                }
            }
            .navigationTitle(group.name)
            .task(id: groupID) {
                loaded = nil
                loaded = await model.loadGroupSession(groupID)
            }
        }
    }
}

private struct GroupConversation: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    let session: GroupSession
    let live: GroupLive
    /// Pictures are being dragged over the chat: anywhere on it, they join the next message.
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let looks = model.groupLooks(group)
        VStack(spacing: 0) {
            GroupHeaderBar(group: group, live: live)
            GroupThreadView(group: group, transcript: session.transcript)
            GroupApprovalBar(live: live)
            GroupPresenceBar(group: group, live: live)
            GroupComposer(groupID: group.id, lane: model.groupLane(group.id), names: looks.map(\.name), looks: looks,
                          text: Binding(get: { model.draftText(group.id) },
                                        set: { model.setDraft($0, for: group.id) })) { message in
                model.postUserMessage(message, to: group.id)
            }
            .id(group.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .overlay {
            ZStack { if isDropTargeted { ChatDropOverlay(detail: "Imagens vão com a sua próxima mensagem") } }
                .animation(reduceMotion ? nil : Motion.hover(isDropTargeted), value: isDropTargeted)
        }
        .onDrop(of: AppModel.droppableTypes, isTargeted: $isDropTargeted) { model.attachDropped($0, toGroup: group.id) }
    }
}

/// The header reads the Orbs' activity (for the avatars that move), so only it is drawn again when they change.
private struct GroupHeaderBar: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    let live: GroupLive

    var body: some View {
        let looks = model.groupLooks(group)
        GroupHeader(name: group.name,
                    members: looks.map { StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: model.live($0.id).activity) },
                    orbCount: looks.count, usage: live.usage, isActive: live.runState != .idle,
                    onStop: { model.stopGroup(group.id) }, onPanel: { model.toggleInspector() })
    }
}

/// The open cards of the members that wait for you. A member runs on a side conversation, so its card is not in the group's
/// thread nor in its own chat: this is where it is answered (`decide` writes to the same side conversation).
private struct GroupApprovalBar: View {
    @Environment(AppModel.self) private var model
    let live: GroupLive

    private struct Entry {
        var look: BotLook
        var request: ApprovalRequest
    }

    var body: some View {
        let entries = openCards()
        // The `onChange` stays on the root, which is always there: on the bar it would only exist once a member waited already.
        Group {
            if !entries.isEmpty {
                // Scrolls past a height, so several waiting members do not push the thread off the screen.
                ViewThatFits(in: .vertical) {
                    cards(entries)
                    ScrollView { cards(entries) }
                        .frame(maxHeight: 300)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .transition(.quiet)
            }
        }
        .onChange(of: live.waiting) { old, new in announce(new.filter { !old.contains($0) }) }
    }

    /// The open cards of the members that wait. The conversations are read only while one does, so a group at work is not
    /// drawn again for every token.
    private func openCards() -> [Entry] {
        var entries: [Entry] = []
        for id in live.waiting {
            guard let look = model.liveBot(id)?.look else { continue }
            // A proposal of a new Orb is not offered to a group's members, so there is no card for it here.
            for request in model.pendingApprovals(of: id) where request.proposal == nil {
                entries.append(Entry(look: look, request: request))
            }
        }
        return entries
    }

    private func cards(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries, id: \.request.id) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    // The question card already says who asks; the permission card does not.
                    if !entry.request.isQuestion {
                        Text(entry.look.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.leading, gutter)
                    }
                    // The keys (⌘↩, esc) answer the card of the Orb that is selected, and here the group is: no hint of them.
                    if let question = entry.request.question {
                        QuestionCard(request: entry.request, question: question, botID: entry.look.id, showsKeyHints: false)
                    } else {
                        ApprovalCard(request: entry.request, botID: entry.look.id, showsKeyHints: false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    BotAvatar(orb: entry.look.orb, size: 28, activity: .waiting)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// For VoiceOver: the banner does not speak while the group is open, and `announceApproval` only does for a selected Orb.
    private func announce(_ added: [UUID]) {
        let names = added.compactMap { model.liveBot($0)?.look.name }
        guard !names.isEmpty else { return }
        model.announceForAccessibility("\(PortugueseList.join(names)) \(names.count == 1 ? "precisa" : "precisam") de você")
    }
}

/// The presence line: the members in a turn right now, each with what it does.
private struct GroupPresenceBar: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    let live: GroupLive

    var body: some View {
        GroupPresenceStrip(items: model.groupPresence(group, live: live))
    }
}

/// The thread: the person's messages, the members' answers, the assignments, the events and, in an old conversation, the card of a budget's pause.
private struct GroupThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrbGroup
    let transcript: OrbTranscript
    private let bottomID = "group-bottom"
    /// Whether new words take the thread to its end: not while you read further up (see `BottomFollowing`).
    @State private var followsBottom = true

    var body: some View {
        let items = transcript.items
        let lastSpeaker = items.last { Self.answerer($0) != nil }?.id
        let continuing = Self.continuingAnswers(items)
        let lastSentID = items.last { if case .user = $0.kind { true } else { false } }?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        GroupEmptyState(group: group)
                            .transition(.opacity)
                    }
                    ForEach(items) { item in
                        GroupRow(item: item, orchestratorID: group.orchestratorID, isLastSpeaker: item.id == lastSpeaker,
                                 continuesPrevious: continuing.contains(item.id), look: look(of: item),
                                 toLook: toLook(of: item))
                            .equatable()
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .animation(Motion.adapted(Motion.exit, reduceMotion: reduceMotion), value: items.isEmpty)
            }
            .modifier(KeepsBottom(follows: followsBottom))
            .modifier(BottomFollowing(isFollowing: $followsBottom, resumed: { proxy.scrollTo(bottomID, anchor: .bottom) }))
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) } // macOS 14 has no scroll anchor to open at the end
            .onChange(of: transcript.revision) {
                if followsBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: lastSentID) {
                // What you just sent always shows, and brings the thread back to following its end.
                followsBottom = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    /// The Orb that spoke an answer (a reply, a post in the thread), nil for anything else.
    private static func answerer(_ item: TranscriptItem) -> UUID? {
        if case .orbMessage(let message) = item.kind, message.direction == .post, message.kind == .reply { return message.from.id }
        return nil
    }

    /// The ids of the answers that continue the previous item's Orb (one pass, no copy of the items).
    private static func continuingAnswers(_ items: [TranscriptItem]) -> Set<UUID> {
        var result = Set<UUID>()
        var previous: UUID?
        for item in items {
            let speaker = answerer(item)
            if speaker != nil, speaker == previous { result.insert(item.id) }
            previous = speaker
        }
        return result
    }

    /// The look of the Orb an Orb message comes from, as it is now (read here so a row is a plain value).
    private func look(of item: TranscriptItem) -> BotLook? {
        guard case .orbMessage(let message) = item.kind else { return nil }
        return model.liveBot(message.from.id)?.look
    }

    private func toLook(of item: TranscriptItem) -> BotLook? {
        guard case .orbMessage(let message) = item.kind, Self.answerer(item) == nil else { return nil }
        return message.to.flatMap { model.liveBot($0.id)?.look }
    }
}

/// One row of the group's thread, a plain value: a new item or a change of look redraws only the rows it touches.
private struct GroupRow: View, Equatable {
    let item: TranscriptItem
    let orchestratorID: UUID?
    let isLastSpeaker: Bool
    let continuesPrevious: Bool
    /// The look of the Orb that spoke (or assigned); nil for other rows and for a deleted Orb.
    let look: BotLook?
    /// The look of the Orb an assignment goes to.
    let toLook: BotLook?

    nonisolated static func == (a: GroupRow, b: GroupRow) -> Bool {
        a.item == b.item && a.orchestratorID == b.orchestratorID && a.isLastSpeaker == b.isLastSpeaker
            && a.continuesPrevious == b.continuesPrevious && a.look == b.look && a.toLook == b.toLook
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            GroupUserBubble(text: text, attachments: attachments)
        case .orbMessage(let message):
            if GroupRow.isAnswer(message) {
                GroupMessageBubble(message: message, look: look,
                                   isOrchestrator: message.from.id == orchestratorID, isLastSpeaker: isLastSpeaker,
                                   showsHeader: !continuesPrevious)
                // Words of the same Orb that follow each other sit under the first, 6 pt apart (the list gives 14).
                .padding(.top, continuesPrevious ? -8 : 0)
            } else {
                GroupAssignmentLine(message: message, from: look, to: toLook)
            }
        case .event(let event):
            EventLineView(event: event, centered: true)
        case .groupPause(let pause):
            GroupPauseCard(pause: pause)
        case .notice(let text):
            Text(text)
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .bot, .tool, .approval, .greeting, .browserView:
            // A group's thread holds none of these: the Orbs' own work stays in their side conversations.
            EmptyView()
        }
    }

    private static func isAnswer(_ message: OrbMessageItem) -> Bool { message.direction == .post && message.kind == .reply }
}

/// The first view of a group: its Orbs standing together on one stage like the welcome screen's. The orchestrator stands
/// exactly on the middle line; the others split to both sides with the same room, so the group is centered on it. A soft
/// glow in the orchestrator's color lies under them (a gradient that fades to nothing, so it has no edge). Under Reduce
/// Motion they stand still.
struct GroupEmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrbGroup

    /// The space each Orb takes beside the next, and the gap between the Orbs and the title.
    private static let step: CGFloat = 66
    private static let titleGap: CGFloat = 38

    var body: some View {
        let looks = model.groupLooks(group)
        let orchestrator = looks.first { $0.id == group.orchestratorID } ?? looks.first
        let others = looks.filter { $0.id != orchestrator?.id }
        let leftCount = (others.count + 1) / 2
        let left = Array(others.prefix(leftCount))
        let right = Array(others.dropFirst(leftCount))
        let side = CGFloat(max(left.count, right.count)) * Self.step
        VStack(spacing: Self.titleGap) {
            HStack(alignment: .bottom, spacing: 18) {
                // Both sides get the same width, so the orchestrator is exactly in the middle whatever the count.
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(left, id: \.id) { member in standing(member, size: 48) }
                }
                .frame(width: side, alignment: .trailing)
                if let orchestrator { standing(orchestrator, size: 72) }
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(right, id: \.id) { member in standing(member, size: 48) }
                }
                .frame(width: side, alignment: .leading)
            }
            .background {
                // The glow of the orchestrator's color, fading to nothing before the rectangle's edge.
                Rectangle()
                    .fill(EllipticalGradient(colors: [OrbColor.core(orchestrator?.orb).opacity(0.22),
                                                      OrbColor.core(orchestrator?.orb).opacity(0.08),
                                                      OrbColor.core(orchestrator?.orb).opacity(0)],
                                             center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: 560, height: 200)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text("Fale com o grupo.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(orchestrator?.name ?? "O orquestrador") coordena, divide o trabalho e chama os outros. Você pode entrar a qualquer momento.")
                    .font(Typography.text)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
    }

    private func standing(_ look: BotLook, size: CGFloat) -> some View {
        SettlingOrb(idle: true) { settled in
            BotAvatar(orb: look.orb, size: size, animated: !reduceMotion, paused: settled, interactive: !reduceMotion)
        }
            .frame(width: size, height: size)
            .accessibilityLabel(look.name)
    }
}
