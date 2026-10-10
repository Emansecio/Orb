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

/// A group's chat: the thread of what the person and the members said, the header with the budget while a request runs,
/// the presence line and the composer. Reads the group, its thread and its live state; the Orbs' own rows are not drawn here.
struct GroupChatView: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID

    var body: some View {
        if let group = model.groups.first(where: { $0.id == groupID }) {
            GroupConversation(group: group, session: model.groupSession(groupID), live: model.groupLive(groupID))
                .navigationTitle(group.name)
        }
    }
}

private struct GroupConversation: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    let session: GroupSession
    let live: GroupLive

    var body: some View {
        let names = model.groupLooks(group).map(\.name)
        VStack(spacing: 0) {
            GroupHeaderBar(group: group, live: live)
            GroupThread(group: group, transcript: session.transcript)
            GroupPresenceBar(group: group, live: live)
            GroupComposer(names: names) { message in
                model.postUserMessage(group.id, text: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
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

/// The presence line: the members in a turn right now, each with what it does.
private struct GroupPresenceBar: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    let live: GroupLive

    var body: some View {
        GroupPresenceStrip(items: model.groupPresence(group, live: live))
    }
}

/// The thread: the person's messages, the members' answers, the assignments, the events and the budget's pause.
private struct GroupThread: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrbGroup
    let transcript: OrbTranscript
    private let bottomID = "group-bottom"

    var body: some View {
        let items = transcript.items
        let lastSpeaker = items.last { Self.answerer($0) != nil }?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        GroupEmptyState(group: group)
                            .transition(.opacity)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let previous = index > 0 ? items[index - 1] : nil
                        row(item, isLastSpeaker: item.id == lastSpeaker, continuesPrevious: Self.answerer(item) != nil
                            && Self.answerer(item) == previous.flatMap(Self.answerer))
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
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.revision) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    /// The Orb that spoke an answer (a reply, a post in the thread), nil for anything else.
    private static func answerer(_ item: TranscriptItem) -> UUID? {
        if case .orbMessage(let message) = item.kind, message.direction == .post, message.kind == .reply { return message.from.id }
        return nil
    }

    @ViewBuilder private func row(_ item: TranscriptItem, isLastSpeaker: Bool, continuesPrevious: Bool) -> some View {
        switch item.kind {
        case .user(let text, let attachments):
            GroupUserBubble(text: text, attachmentCount: attachments.count)
        case .orbMessage(let message):
            if Self.answerer(item) != nil {
                GroupMessageBubble(message: message, look: model.liveBot(message.from.id)?.look,
                                   isOrchestrator: message.from.id == group.orchestratorID, isLastSpeaker: isLastSpeaker,
                                   showsHeader: !continuesPrevious)
                // Words of the same Orb that follow each other sit under the first, 6 pt apart (the list gives 14).
                .padding(.top, continuesPrevious ? -8 : 0)
            } else {
                GroupAssignmentLine(message: message, from: model.liveBot(message.from.id)?.look,
                                    to: message.to.flatMap { model.liveBot($0.id)?.look })
            }
        case .event(let event):
            EventLineView(event: event)
        case .groupPause(let pause):
            GroupPauseCard(pause: pause)
        case .notice(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .bot, .tool, .approval, .greeting:
            // A group's thread holds none of these: the Orbs' own work stays in their side conversations.
            EmptyView()
        }
    }
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
                    .font(.system(size: 13))
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
        BotAvatar(orb: look.orb, size: size, animated: !reduceMotion, interactive: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityLabel(look.name)
    }
}
