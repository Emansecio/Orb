import SwiftUI

/// The chat of one Orb. Takes the Orb's id and reads only that Orb's state (`BotLive`), so what happens in
/// another Orb, or to this Orb's settings that the chat does not show, does not re-render it.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        @Bindable var model = model
        let live = model.live(botID)
        let look = live.look
        // Switching Orbs swaps the conversation for the other's with a cross-fade (§2.9) while the composer, the
        // toolbar and the panel, outside this container, change at once and never flash: the transcript is a view of
        // its own per Orb (`.id`), so SwiftUI fades the old one out and the new one in.
        ZStack {
            TranscriptList(look: look)
                .id(botID)
                .transition(.opacity)
        }
        .motion(Motion.crossFade, value: botID)
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
                ConversationsMenuButton(botID: botID)
                    .id(botID)
                Button("Nova conversa", systemImage: "square.and.pencil") {
                    model.newConversation(botID)
                }
                .help("\(CommandName.newConversation) (\(AppShortcut.newConversation.label)). A atual fica guardada em Conversas.")
                Button("Painel do Orb", systemImage: "sidebar.right") {
                    model.showInspector.toggle()
                }
                .help("\(CommandName.toggleInspector) (\(AppShortcut.toggleInspector.label))")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            BotInspector(botID: botID)
                .id(botID)
                .inspectorColumnWidth(min: 244, ideal: 300, max: 420)
        }
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
        let status = live.status
        let isLoading = model.isLoadingConversation(look.id)
        // Looked at before the rows are made, as many times as this is evaluated: the same items say the same thing.
        let generation = entrances.observe(items, isLoading: isLoading, swaps: transcript.swaps)

        // A conversation swapped for another (a new one, one reopened from Conversas) cross-fades; the scroll view is
        // a new one then, as it was when the whole chat was rebuilt.
        ZStack {
            conversation(items: items, status: status, isLoading: isLoading, live: live, transcript: transcript)
                .id(generation)
                .transition(.opacity)
        }
        .motion(Motion.crossFade, value: generation)
        .onChange(of: generation) { followsBottom = true; follower.follows = true }
    }

    private func conversation(items: [TranscriptItem], status: String?, isLoading: Bool, live: BotLive,
                              transcript: OrbTranscript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        LoadingTranscript()
                    } else if items.isEmpty {
                        EmptyChatView(look: look, presented: presentedEmptyChats)
                            .transition(.opacity)
                    }
                    ForEach(items) { item in
                        let isNew = entrances.isNew(item.id)
                        TranscriptRow(item: item, botID: look.id, orb: look.orb, entering: isNew)
                            .equatable()
                            // The row comes in by itself, not through an animation of the list (which would lay every row
                            // out again); the list's own animation must not add a transition of its own.
                            .modifier(RowEntrance(id: item.id, style: item.kind.entrance, isNew: isNew, entrances: entrances))
                            .transition(.identity)
                    }
                    QueuedMessages(botID: look.id)
                    if let status {
                        WorkingLine(look: look, text: status)
                    }
                    Color.clear.frame(height: 1).id(BottomAnchor.id)
                }
                // Only what changes rarely animates at the list: the Orb starting or ending a turn (its working line), and
                // the empty state leaving with the first message. Never the count of messages, never a streamed token.
                .motion(Motion.content, value: status == nil)
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
            .modifier(BottomFollowing(isFollowing: $followsBottom))
            .modifier(KeepsBottom(follows: followsBottom))
            .environment(\.replyGrew, replyGrew(proxy))
            .onChange(of: followsBottom) { follower.follows = followsBottom }
            .onChange(of: transcript.revision) {
                if !BottomFollower.anchorsItself { follower.follow { scrollToBottom(proxy) } }
            }
            .onChange(of: live.poke) {
                // The user just sent a message: always show it. The list glides to it if it was at the end already;
                // from higher up it goes there at once.
                let wasAtBottom = followsBottom
                followsBottom = true
                withAnimation(wasAtBottom ? ScrollMotion.animation(reduceMotion: reduceMotion) : nil) {
                    scrollToBottom(proxy)
                }
            }
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
    private func replyGrew(_ proxy: ScrollViewProxy) -> (@MainActor () -> Void)? {
        guard !BottomFollower.anchorsItself else { return nil }
        let follower = follower
        return { follower.follow { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) } }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
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

/// Stops following new content while the user scrolls away from the bottom and resumes once they
/// scroll back down. Needs scroll phases (macOS 15); on macOS 14 the chat always follows.
private struct BottomFollowing: ViewModifier {
    @Binding var isFollowing: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { old, new, context in
                // Only the user's own scrolling counts, not programmatic scrolls (`.animating`).
                let byUser: [ScrollPhase] = [.tracking, .interacting, .decelerating]
                if byUser.contains(new) {
                    isFollowing = false
                } else if new == .idle, byUser.contains(old) {
                    let geometry = context.geometry
                    isFollowing = geometry.contentSize.height - geometry.visibleRect.maxY < 48
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
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeIn(duration: 0.2)) { isVisible = true }
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
    /// Set when the Orb lands, which is one poke of its own spring.
    @State private var landed = 0

    init(look: BotLook, presented: PresentedOrbs?) {
        self.look = look
        self.presented = presented
        // Decided when the view is made, from what was recorded before it: the record is written once it has appeared.
        _enters = State(initialValue: EmptyChatEntrance.plays(for: look.id, in: presented))
    }

    var body: some View {
        let live = model.live(look.id)
        let showsFirstRun = !model.isProviderReady || firstRun.connectedName != nil
        VStack(spacing: 16) {
            LiveBotAvatar(botID: look.id, orb: look.orb, size: 96, interactive: true, extraPoke: landed)
                .padding(.top, 72)
                .entrance(.drop, enters: enters) {
                    // Touches the floor: one poke (the Orb's own spring lands it). The Orb stays still under Reduce Motion.
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
                                model.send(suggestion.symbol == "questionmark.bubble"
                                           ? "Oi! Antes de começarmos, me faça algumas perguntas para entender como você pode me ajudar."
                                           : suggestion.text, to: look.id)
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

private struct SuggestionButton: View {
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
        .onHover { isHovering = $0 }
    }
}

/// Live status of a working bot: shimmering activity text next to its spinning orb, and how long the turn has
/// lasted. The clock ticks once a second, and only while this line exists (a turn is running).
private struct WorkingLine: View {
    @Environment(AppModel.self) private var model
    let look: BotLook
    let text: String

    var body: some View {
        let live = model.live(look.id)
        HStack(spacing: 10) {
            LiveBotAvatar(botID: look.id, orb: look.orb, size: 30)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(text)…")
                    .font(.system(size: 13))
                    .shimmer()
                if let since = live.workingSince {
                    ElapsedClock(since: since)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(look.name): \(text)")
    }
}

/// "12 s" next to the status, redrawn once a second. Hidden from VoiceOver, which would otherwise read every tick.
private struct ElapsedClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let text = ElapsedFormat.working(since: since, now: context.date)
            Text(text)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.faint)
                // Plain text, no animation: a clock that ticks every second must not be a recurring animation outside
                // Core Animation (MOVIMENTO.md, principle 7). Rolling digits are for counters that change once.
        }
        .accessibilityHidden(true)
    }
}
