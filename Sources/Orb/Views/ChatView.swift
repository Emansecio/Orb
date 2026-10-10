import SwiftUI

/// The chat of one Orb. Takes the Orb's id and reads only that Orb's state (`BotLive`), so what happens in
/// another Orb, or to this Orb's settings that the chat does not show, does not re-render it.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    /// The find bar (⌘F) of this chat. One for the view, which stays across Orbs: it is closed when the Orb changes.
    @State private var find = ConversationFind()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = model.live(botID)
        let look = live.look
        // Switching Orbs swaps the conversation for the other's with a cross-fade (§2.9) while the composer, the
        // toolbar and the panel, outside this container, change at once and never flash: the transcript is a view of
        // its own per Orb (`.id`), so SwiftUI fades the old one out and the new one in.
        ZStack {
            TranscriptList(look: look, find: find)
                .id(botID)
                .transition(.opacity)
        }
        .motion(Motion.crossFade, value: botID)
        .overlay(alignment: .top) {
            // Over the chat, not above it: opening the bar lays nothing out again (the list keeps its place).
            if find.isOpen {
                FindBar(find: find, botID: botID)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
        }
        .motion(Motion.content, value: find.isOpen)
        .onAppear { bindFind(); takeFindRequest() }
        .onChange(of: botID) {
            find.close()
            bindFind()
        }
        .onChange(of: model.pendingChatRequest) { takeFindRequest() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                FirstRunBanner(botID: botID)
                    .id(botID)
                ComposerView(botID: botID)
                    .id(botID)
            }
        }
        .background(Palette.canvas)
        .navigationTitle(look.name)
        .navigationSubtitle(model.modelName(forModel: live.modelID))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Buscar na conversa", systemImage: "magnifyingglass") { find.open() }
                    .keyboardShortcut(AppShortcut.find)
                    .help(Tip.findInConversation())
                ConversationsMenuButton(botID: botID)
                    .id(botID)
                Button("Nova conversa", systemImage: "square.and.pencil") {
                    model.newConversation(botID)
                }
                .help(Tip.newConversation())
                Button("Painel do Orb", systemImage: "sidebar.right") {
                    model.toggleInspector()
                }
                .help(Tip.inspector(isShowing: model.showInspector))
            }
        }
    }
}

extension ChatView {
    /// What the find bar searches (the stored items of this Orb's chat, never its rows) and how it speaks to VoiceOver.
    private func bindFind() {
        let model = model, botID = botID
        find.source = { model.orbTranscript(botID).items }
        find.announce = { text in
            if NSWorkspace.shared.isVoiceOverEnabled { model.announceForAccessibility(text, priority: .low) }
        }
    }

    /// ⌘F from the command palette or a menu: the bar opens (the chat may have just been created for it).
    private func takeFindRequest() {
        if model.takeChatRequest(.findInConversation, of: botID) { find.open() }
    }
}

/// The conversation. Its own view so streaming re-renders only this list, not the toolbar, composer or
/// inspector. It reads the Orb's `OrbTranscript` and nothing of the streamed text (that is a `LiveText` the reply's
/// own views read), so it is redrawn when an item is added or changes, not on every flush, and not at all for
/// another Orb's work; rows are `Equatable`, so only the row that changed re-renders.
private struct TranscriptList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentedEmptyChats) private var presentedEmptyChats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let look: BotLook
    /// The find bar's state: the list scrolls to the result it chooses and gives its row the marks.
    let find: ConversationFind
    /// Off while the user has scrolled up to read, so new content doesn't pull the view down.
    @State private var followsBottom = true
    /// Scrolls for the lists that cannot keep the bottom in view themselves (macOS 14).
    @State private var follower = BottomFollower()
    /// Which rows just arrived (they come in; the rest are simply there), and when the conversation itself was replaced.
    @State private var entrances = TranscriptEntrances()

    var body: some View {
        let transcript = model.orbTranscript(look.id)
        let items = transcript.items
        let live = model.live(look.id)
        let isWorking = live.isWorking
        let isLoading = model.isLoadingConversation(look.id)
        // Looked at before the rows are made, as many times as this is evaluated: the same items say the same thing.
        let generation = entrances.observe(items, isLoading: isLoading, swaps: transcript.swaps)
        // The Orb's reply at the end of the chat carries its living avatar; the working line below gives up its own
        // then, so there is one Orb in view at a time. Only the two rows whose answer changed are drawn again.
        let lastReplyID: UUID? = if let last = items.last, last.kind.isReply { last.id } else { nil }
        // "Refazer" belongs to the last finished reply of an idle chat; rows an edit or a redo is about to cut fade out.
        let redoID = RewindRows.redoTarget(in: items, isWorking: isWorking)
        let dropping = live.dropping
        let found = find.focus

        // A conversation swapped for another (a new one, one reopened from Conversas) cross-fades; the scroll view is
        // a new one then, as it was when the whole chat was rebuilt.
        ZStack {
            conversation(items: items, isWorking: isWorking, isLoading: isLoading, live: live, transcript: transcript,
                         lastReplyID: lastReplyID, redoID: redoID, dropping: dropping, found: found)
                .id(generation)
                .transition(.opacity)
        }
        .motion(Motion.crossFade, value: generation)
        .onChange(of: generation) { followsBottom = true; follower.follows = true }
    }

    private func conversation(items: [TranscriptItem], isWorking: Bool, isLoading: Bool, live: BotLive,
                              transcript: OrbTranscript, lastReplyID: UUID?, redoID: UUID?, dropping: Set<UUID>,
                              found: FindFocus?) -> some View {
        // A result on show holds the chat where it is: a reply that grows meanwhile does not take the view to the end.
        let follows = followsBottom && !find.pausesFollowing
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        LoadingTranscript()
                    } else if items.isEmpty {
                        EmptyChatView(look: look, presented: presentedEmptyChats)
                            .transition(.opacity)
                    }
                    // MARK: MultiOrb (WP2): a chat with exchanges between Orbs or repeated events is drawn from its folded rows.
                    if let rows = transcript.rows {
                        ForEach(rows) { row in
                            foldedRow(row, lastReplyID: lastReplyID, redoID: redoID, dropping: dropping, found: found)
                        }
                    } else {
                        ForEach(items) { item in
                            itemRow(item, lastReplyID: lastReplyID, redoID: redoID, dropping: dropping, found: found)
                        }
                    }
                    // end MultiOrb (WP2)
                    QueuedMessages(botID: look.id)
                    // A chain of requests the Orb waits on (`chainWork`) keeps its line too, with the button that stops it.
                    if isWorking || live.chainWork != nil {
                        WorkingLine(look: look, avatarHidden: lastReplyID != nil)
                            .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                    }
                    Color.clear.frame(height: 1).id(BottomAnchor.id)
                }
                // Only what changes rarely animates at the list: the Orb starting or ending a turn (its working line), and
                // the empty state leaving with the first message. Never the count of messages, never a streamed token.
                .motion(Motion.content, value: isWorking)
                .motion(Motion.exit, value: items.isEmpty)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                // A new identity once the conversation arrives, so its rows appear as they did when it was there from
                // the start, not as an animated insertion of every one of them.
                .id(isLoading)
            }
            .scrollIndicators(.automatic)
            // The bar floats over the chat (nothing is laid out again to open it), so a conversation at its top would sit
            // under it: while it is open the content starts below it. It glides in `Motion.content` (at once under
            // Reduce Motion), and the margin is only room: the scroll position is untouched.
            .contentMargins(.top, find.isOpen ? FindBar.clearance : 0, for: .scrollContent)
            .motion(Motion.content, value: find.isOpen)
            .modifier(BottomFollowing(isFollowing: $followsBottom, resumed: {
                // The list grew while a finger rested on it: glide to the end again.
                withAnimation(ScrollMotion.animation(reduceMotion: reduceMotion)) { scrollToBottom(proxy) }
            }))
            .modifier(KeepsBottom(follows: follows))
            .environment(\.replyGrew, replyGrew(proxy))
            .onChange(of: follows) { follower.follows = follows }
            .onChange(of: find.jump) { if let jump = find.jump { scrollToFound(jump, proxy) } }
            .onChange(of: transcript.revision) {
                find.itemsChanged()
                if !BottomFollower.anchorsItself { follower.follow { scrollToBottom(proxy) } }
            }
            .onChange(of: live.scrollNudge) { showSentMessage(proxy) }
            .onAppear {
                guard !BottomFollower.anchorsItself else { return }
                scrollToBottom(proxy)
                // The first scroll goes by estimated row heights; once the rows near the end are laid out it can fall short.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if follower.follows { scrollToBottom(proxy) }
                }
            }
            .onChange(of: isLoading) {
                find.itemsChanged() // a search typed while the conversation was being read
                // The conversation just arrived from disk: start at its end, as when it was there from the first frame.
                guard !isLoading else { return }
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                // Again after the new rows have been laid out: the bottom of a long lazy list is not measured yet now.
                Task {
                    await Task.yield()
                    if followsBottom { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
                }
            }
        }
    }

    /// What a growing reply calls: nothing where the scroll view keeps the bottom itself.
    /// One item of the chat as a row, entering by itself when it is new.
    @ViewBuilder
    private func itemRow(_ item: TranscriptItem, lastReplyID: UUID?, redoID: UUID?, dropping: Set<UUID>, found: FindFocus?) -> some View {
        let isNew = entrances.isNew(item.id)
        TranscriptRow(item: item, botID: look.id, orb: look.orb, entering: isNew,
                      isLastReply: item.id == lastReplyID, offersRedo: item.id == redoID,
                      isDropping: dropping.contains(item.id), find: item.id == found?.itemID ? found : nil)
            .equatable()
            // The row comes in by itself, not through an animation of the list (which would lay every row out again); the
            // list's own animation must not add a transition of its own.
            .modifier(RowEntrance(id: item.id, style: item.kind.entrance, isNew: isNew, entrances: entrances))
            .transition(.identity)
    }

    /// A folded row (MultiOrb, WP2): one item as it is, or a run of events or of messages between Orbs that folds into one
    /// line and unfolds into its items. Those items are drawn as rows of their own, without an entrance (the fold has one).
    @ViewBuilder
    private func foldedRow(_ row: TranscriptRowModel, lastReplyID: UUID?, redoID: UUID?, dropping: Set<UUID>,
                           found: FindFocus?) -> some View {
        switch row {
        case .single(let item):
            itemRow(item, lastReplyID: lastReplyID, redoID: redoID, dropping: dropping, found: found)
        case .events(let kind, let items):
            FoldedThread(items: items, summary: { EventsSummary(kind: kind, items: items, unfolded: $0) },
                         child: { plainRow($0) })
                .modifier(RowEntrance(id: row.id, style: items[0].kind.entrance, isNew: entrances.isNew(row.id), entrances: entrances))
                .transition(.identity)
        case .exchange(let items):
            FoldedThread(items: items, summary: { ExchangeSummary(items: items, botID: look.id, unfolded: $0) },
                         child: { plainRow($0) })
                .modifier(RowEntrance(id: row.id, style: items[0].kind.entrance, isNew: entrances.isNew(row.id), entrances: entrances))
                .transition(.identity)
        }
    }

    /// A row inside a folded one: no entrance of its own.
    private func plainRow(_ item: TranscriptItem) -> some View {
        TranscriptRow(item: item, botID: look.id, orb: look.orb)
            .equatable()
    }

    private func replyGrew(_ proxy: ScrollViewProxy) -> ReplyGrewAction? {
        guard !BottomFollower.anchorsItself else { return nil }
        let follower = follower
        return ReplyGrewAction(id: ObjectIdentifier(follower)) { follower.follow { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) } }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
    }

    /// The user just sent a message (or queued one): always show it. The list glides to it if it was at
    /// the end already; from higher up it goes there at once.
    private func showSentMessage(_ proxy: ScrollViewProxy) {
        let wasAtBottom = followsBottom
        find.resumeFollowing()
        followsBottom = true
        withAnimation(wasAtBottom ? ScrollMotion.animation(reduceMotion: reduceMotion) : nil) {
            scrollToBottom(proxy)
        }
    }

    /// Brings the message of the chosen result into view, with the match where `FindScroll` puts it. Scrolling to an id is
    /// all it takes: the list makes the rows around it as it arrives and none of the rest. Rows far from the last one shown
    /// are measured only by estimate until they exist, so the same scroll is made once more when they do.
    private func scrollToFound(_ jump: FindJump, _ proxy: ScrollViewProxy) {
        let anchor = UnitPoint(x: 0.5, y: jump.anchorY)
        // Under Reduce Motion nothing moves in a glide: the list is simply there.
        withAnimation(jump.glides ? ScrollMotion.animation(reduceMotion: reduceMotion) : nil) {
            proxy.scrollTo(jump.itemID, anchor: anchor)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard find.jump?.token == jump.token else { return }
            proxy.scrollTo(jump.itemID, anchor: anchor)
        }
    }

    private enum BottomAnchor { static let id = "bottom" }
}

/// Keeps the end of the conversation in view where the scroll view can do it itself (macOS 15): it opens at the
/// bottom, and stays there while content grows and the user has not scrolled up. A scroll to an id after every
/// change instead costs as much as the conversation is long, and on a long one it stops short of the end.
private struct KeepsBottom: ViewModifier {
    let follows: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(follows ? .bottom : nil, for: .sizeChanges)
        } else {
            content
        }
    }
}

/// Follows a growing conversation with scrolls to its end, at most one every 200 ms (the scroll is slow in a long
/// list), for the macOS versions whose scroll view cannot keep the bottom in view itself.
@MainActor
final class BottomFollower {
    /// Whether the scroll view keeps the bottom itself (`KeepsBottom`).
    static var anchorsItself: Bool {
        if #available(macOS 15, *) { true } else { false }
    }

    /// Mirrors the list's "the user has not scrolled up".
    var follows = true
    private var throttle = ScrollThrottle(interval: .milliseconds(200))
    private var scheduled: Task<Void, Never>?
    private var latest: (@MainActor () -> Void)?

    func follow(_ scroll: @escaping @MainActor () -> Void) {
        guard follows else { return }
        latest = scroll
        switch throttle.request(at: .now) {
        case .now:
            scheduled?.cancel()
            scheduled = nil
            scroll()
        case .after(let delay):
            scheduled = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                scheduled = nil
                throttle.ranScheduled(at: .now)
                if follows { latest?() }
            }
        case .wait:
            break
        }
    }
}

/// At most one run per `interval`: the first request runs at once; requests while the interval lasts become one
/// run when it ends.
struct ScrollThrottle {
    enum Decision: Equatable {
        case now
        case after(Duration)
        /// A run is already scheduled and will do.
        case wait
    }

    let interval: Duration
    private var lastRun: ContinuousClock.Instant?
    private var isScheduled = false

    init(interval: Duration) {
        self.interval = interval
    }

    mutating func request(at now: ContinuousClock.Instant) -> Decision {
        if isScheduled { return .wait }
        guard let lastRun, now - lastRun < interval else {
            lastRun = now
            return .now
        }
        isScheduled = true
        return .after(interval - (now - lastRun))
    }

    /// The scheduled run happened.
    mutating func ranScheduled(at now: ContinuousClock.Instant) {
        isScheduled = false
        lastRun = now
    }
}

/// Whether the chat keeps following the end after the user's own scroll ended. Away from the end by more than
/// `slack` it does not; near it, it does; and a touch that did not take the list up (the list was at the end when
/// the touch began and its top is where it was, give or take `jitter`) keeps following, so resting a finger on the
/// trackpad does not cost the chat its place at the end.
enum FollowRule {
    static let slack: CGFloat = 48
    static let jitter: CGFloat = 8

    /// `distance`: how far the end of the content is below the visible area. `minY`: the top of the visible area.
    static func follows(distance: CGFloat, minY: CGFloat, wasAtBottom: Bool, startMinY: CGFloat) -> Bool {
        distance < slack || touchLeftListInPlace(minY: minY, wasAtBottom: wasAtBottom, startMinY: startMinY)
    }

    /// The touch began at the end and did not take the list up.
    static func touchLeftListInPlace(minY: CGFloat, wasAtBottom: Bool, startMinY: CGFloat) -> Bool {
        wasAtBottom && minY >= startMinY - jitter
    }

    /// Whether to glide back to the end when the scroll ends: only for a touch that left the list in place while it
    /// grew (the end is out of reach and the user did not scroll away). Someone who scrolled up a little to reread
    /// something is left where they put the list, near the end or not.
    static func glides(distance: CGFloat, minY: CGFloat, wasAtBottom: Bool, startMinY: CGFloat) -> Bool {
        distance > 1 && touchLeftListInPlace(minY: minY, wasAtBottom: wasAtBottom, startMinY: startMinY)
    }
}

/// Where the list was when the user's scroll began. A reference, so noting it never redraws the list.
@MainActor
private final class ScrollTouch {
    var wasAtBottom = false
    var startMinY: CGFloat = 0
}

/// Stops following new content while the user scrolls away from the bottom and resumes once they
/// scroll back down (or only touched the trackpad: `FollowRule`). Needs scroll phases (macOS 15); on macOS 14 the chat
/// always follows. `resumed` is called when following resumes with the end out of reach (the list grew during the
/// touch), to glide back to it.
private struct BottomFollowing: ViewModifier {
    @Binding var isFollowing: Bool
    let resumed: @MainActor () -> Void
    /// Made on first appearance, not as an initial value (which would build one on every body of the list).
    @State private var touch: ScrollTouch?

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            let resumed = resumed
            content.onAppear {
                if touch == nil { touch = ScrollTouch() }
            }
            .onScrollPhaseChange { old, new, context in
                guard let touch else { return }
                // Only the user's own scrolling counts, not programmatic scrolls (`.animating`).
                let byUser: [ScrollPhase] = [.tracking, .interacting, .decelerating]
                let geometry = context.geometry
                let distance = geometry.contentSize.height - geometry.visibleRect.maxY
                if byUser.contains(new) {
                    if !byUser.contains(old) {
                        touch.wasAtBottom = distance < FollowRule.slack
                        touch.startMinY = geometry.visibleRect.minY
                    }
                    isFollowing = false
                } else if new == .idle, byUser.contains(old) {
                    let follows = FollowRule.follows(distance: distance, minY: geometry.visibleRect.minY,
                                                     wasAtBottom: touch.wasAtBottom, startMinY: touch.startMinY)
                    isFollowing = follows
                    if follows, FollowRule.glides(distance: distance, minY: geometry.visibleRect.minY,
                                                  wasAtBottom: touch.wasAtBottom, startMinY: touch.startMinY) {
                        MainActor.assumeIsolated { resumed() }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Stands in for the conversation while it is read from disk (a fraction of a second even for a long one). Blank at
/// first, so a quick read shows nothing at all, then a small spinner.
private struct LoadingTranscript: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.top, 72)
            .opacity(isVisible ? 1 : 0)
            .accessibilityLabel("Carregando a conversa")
            .task {
                try? await Task.sleep(for: Motion.spinnerDelay)
                withAnimation(Motion.fade) { isVisible = true }
            }
    }
}

/// An empty chat: who this Orb is, and either how to connect a first model (until one is) or what to ask it,
/// which depends on the folder it works in and what it may use. Everything it shows comes from small values of the
/// Orb's settings; nothing is read from disk while it draws.
private struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let look: BotLook
    /// Which Orbs' empty chat already came in this session (nil: no entrance, as in a snapshot).
    let presented: PresentedOrbs?
    @State private var firstRun = FirstRunModel()
    /// The first time this Orb's empty chat shows in the session it comes in (§2.8); never again after that.
    @State private var enters: Bool
    /// Set when the Orb lands (its own squash and wobble).
    @State private var landed = 0

    init(look: BotLook, presented: PresentedOrbs?) {
        self.look = look
        self.presented = presented
        // Decided when the view is made, from what was recorded before it: the record is written once it has appeared.
        _enters = State(initialValue: EmptyChatEntrance.plays(for: look.id, in: presented))
    }

    var body: some View {
        let live = model.live(look.id)
        let showsFirstRun = SetupPrompt.shows(connectionsChecked: model.hasCheckedConnections, orbHasModel: model.hasModelSetup(for: look.id),
                                              connectedName: firstRun.connectedName, hasItems: true)
        VStack(spacing: 16) {
            LiveBotAvatar(botID: look.id, orb: look.orb, size: 96, interactive: true, landing: landed)
                .padding(.top, 72)
                .entrance(.drop, enters: enters) {
                    // Touches the floor: the Orb's own landing. The Orb stays still under Reduce Motion.
                    if !reduceMotion { landed = 1 }
                }
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(look.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(look.role.isEmpty ? "Seu assistente" : look.role)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                }
                .entrance(.rise.delayed(EmptyChatEntrance.nameDelay), enters: enters)
                if showsFirstRun {
                    FirstRunCard(style: .chat(botName: look.name), run: firstRun)
                        .padding(.top, 8)
                        .entrance(.rise.delayed(EmptyChatEntrance.suggestionsStart), enters: enters)
                } else {
                    let bot = live.bot
                    OrbContextLine(folder: EmptyChatContent.folderText(for: bot),
                                   capabilities: EmptyChatContent.capabilityNames(for: bot))
                        .entrance(.rise.delayed(EmptyChatEntrance.contextDelay), enters: enters)
                    VStack(spacing: 6) {
                        let suggestions = EmptyChatContent.suggestions(for: bot, interviewPending: live.memory.interviewPending)
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            SuggestionButton(symbol: suggestion.symbol, text: suggestion.text) {
                                model.send(suggestion.symbol == "questionmark.bubble" ? EmptyChatContent.interviewRequest : suggestion.text,
                                           to: look.id)
                            }
                            .entrance(.staggered(index, start: EmptyChatEntrance.suggestionsStart), enters: enters)
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animateChanges(of: showsFirstRun)
        .onAppear { presented?.insert(look.id) }
    }
}

/// Where the Orb works and what it may use, in two quiet lines under its name.
private struct OrbContextLine: View {
    let folder: String?
    let capabilities: [String]

    var body: some View {
        VStack(spacing: 3) {
            if let folder { Label(folder, systemImage: "folder") }
            if !capabilities.isEmpty {
                Text(capabilities.joined(separator: "  ·  "))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.faint)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

struct SuggestionButton: View {
    let symbol: String
    let text: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.faint)
                    .frame(width: 18)
                Text(text)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.hint)
                    .opacity(isHovering ? 1 : 0)
                    .animation(Motion.hover(isHovering), value: isHovering)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .hoverFill(isHovering, in: .rect(cornerRadius: 12), color: Palette.raised, resting: Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Tip.suggestion)
        .onHover { isHovering = $0 }
    }
}

/// What the Orb is doing, at the end of the chat: its avatar, the phrase (a verb and what it works on, "Rodando
/// `swift build`") and a small meter (how long the turn has gone on, how many actions it made). The one place of
/// the "now": the transcript above only keeps the history. The phrase shimmers while the Orb works, stands still in
/// the warning color while it waits for you and in the quiet one while it waits to try again; when it changes
/// the new one rises into place and the old one fades (`Motion`, a step at a time, never a token). The clock ticks
/// once a second, and only while this line exists (a turn is running).
private struct WorkingLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let look: BotLook
    /// The reply just above is the last item of the chat and carries the living Orb: this one stays out of sight (its
    /// place stays, so the phrase does not move) and rests.
    let avatarHidden: Bool
    /// The last phrase there was: when the turn ends the line is still fading out for a moment, and must say the
    /// same words until it is gone instead of falling back to "Pensando".
    @State private var lastWork = WorkPhrase.line(status: "Pensando")

    var body: some View {
        let live = model.live(look.id)
        let work = live.shownWork ?? lastWork
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                LiveBotAvatar(botID: look.id, orb: look.orb, size: 30, paused: avatarHidden)
                    // Only opacity, so it is the same under Reduce Motion.
                    .opacity(avatarHidden ? 0 : 1)
                    .animation(Motion.fade, value: avatarHidden)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // MARK: MultiOrb (WP2): the two Orbs of an exchange, joined by an arrow, before the phrase.
                    if let partner = live.partner {
                        ExchangeGlyph(from: look.id, to: partner.botID)
                            .transition(.quiet)
                    }
                    ZStack(alignment: .leading) {
                        WorkPhraseView(work: work)
                            .id(work.phraseKey)
                            .transition(.adapted(.swap, reduceMotion: reduceMotion))
                    }
                    // The phrase gives way (it is cut with "…") before the clock and the button do.
                    .layoutPriority(-1)
                    .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: work.phraseKey)
                    // The phrase leaving follows its parent when the line is pushed down by a row coming in above it,
                    // instead of staying drawn where the line used to be.
                    .geometryGroup()
                    WorkMeterView(work: work, since: live.workingSince)
                    // MARK: MultiOrb (WP2): the Orb waits for other Orbs' answers: the line stops the conversation.
                    if live.chainWork != nil {
                        Button("Parar", systemImage: "stop.fill") { model.stop(look.id) }
                            .buttonStyle(GhostStyle(tint: nil))
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                            .help("Parar a conversa entre Orbs (\(AppShortcut.stop.label))")
                            .transition(.adapted(.swap, reduceMotion: reduceMotion))
                    }
                }
                // The meter slides along with the width of the phrase.
                .animation(reduceMotion ? nil : Motion.content, value: work.phraseKey)
            }
            .onChange(of: live.shownWork, initial: true) { _, new in if let new { lastWork = new } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(work.tone == .waiting ? "\(look.name) precisa de você" : "\(look.name) está trabalhando")
            .accessibilityValue(work.text)
            .accessibilityAddTraits(.updatesFrequently)
            if model.routineWaitingForYou(look.id) != nil {
                // The card is in the routine's conversation, not in this chat.
                Button("Ver pedido") { model.showRoutineRequest(of: look.id) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1) // never the part that is cut off: it is the way to the routine's card
                    .help(Tip.routineRequest)
            }
        }
    }
}

/// The words of a phrase: the verb, then what it works on (code in a monospaced face, cut in the middle when the
/// line is short of room), after the routine's name when it is a routine's run. The shimmer covers the whole
/// phrase (one mask), and only while the Orb works.
struct WorkPhraseView: View {
    let work: WorkLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let prefix = work.prefix, work.routine == nil {
                // MARK: MultiOrb (WP2): "Pedido de Atlas:" in front of what the Orb does for it.
                Text("\(prefix):")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if let routine = work.routine {
                Text("\(routine) ·")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .layoutPriority(-1) // a long routine name is cut before the phrase
            }
            phrase
                .shimmer(active: work.shimmers, pulses: work.runsCommand)
        }
    }

    private var phrase: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(work.shownTarget == nil ? work.phrase : work.verb)
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize(horizontal: work.shownTarget != nil, vertical: false) // the target is what gives way, not its verb
            if let target = work.shownTarget {
                Text(target)
                    // The command or path in a lighter monospace, a touch tighter, so it reads as part of the phrase.
                    .font(work.style == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .tracking(work.style == .code ? -0.2 : 0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
        }
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch work.tone {
        // The shimmer paints the working phrase (its mask only reads the alpha); under Reduce Motion it paints it
        // `Palette.muted`, and a color set inside would win over that, so the working tone sets the same one.
        case .working: Palette.muted
        case .waiting: Palette.warn
        case .retrying: Palette.secondary
        }
    }
}

/// "16 s · 3 ações" next to the phrase (or "em 8 s" counting down to a new try), redrawn once a second. Hidden from
/// VoiceOver, which would otherwise read every tick. The count rolls when it changes, which is once per tool.
private struct WorkMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let work: WorkLine
    let since: Date?
    /// Where the ticks start when there is no start time (the wait to try again): fixed when the meter appears, so a
    /// redraw of the line does not move the second marks (`.now` in the body would restart the clock at every one).
    @State private var anchor = Date()

    var body: some View {
        if since != nil || work.tone != .working {
            TimelineView(.periodic(from: since ?? anchor, by: 1)) { context in
                Text(text(at: context.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .fixedSize()
                    // Plain text on every tick: a clock that ticks every second must not be a recurring animation outside
                    // Core Animation (MOVIMENTO.md, principle 7). Rolling digits are for the count, which changes once.
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : Motion.content, value: work.actions)
            }
            .accessibilityHidden(true)
        }
    }

    private func text(at now: Date) -> String {
        if case .retrying(let until) = work.tone { return WorkMeter.countdown(until: until, now: now) }
        let elapsed = since.map { ElapsedFormat.working(since: $0, now: now) } ?? ""
        return WorkMeter.text(elapsed: elapsed, actions: work.actions)
    }
}
