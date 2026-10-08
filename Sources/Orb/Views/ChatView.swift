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
        TranscriptList(look: look)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !model.isProviderReady {
                    SetupBanner()
                }
                ComposerView(botID: botID)
            }
        }
        .background(Palette.canvas)
        .navigationTitle(look.name)
        .navigationSubtitle(model.modelName(forModel: live.modelID))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ConversationsMenuButton(botID: botID)
                Button("Nova conversa", systemImage: "square.and.pencil") {
                    model.newConversation(botID)
                }
                .help("Nova conversa (⇧⌘N). A atual fica guardada em Conversas.")
                Button("Painel do Orb", systemImage: "sidebar.right") {
                    model.showInspector.toggle()
                }
                .help("Mostrar/ocultar detalhes (⌥⌘B)")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            BotInspector(botID: botID)
                .inspectorColumnWidth(min: 244, ideal: 320, max: 420)
        }
    }
}

/// The conversation. Its own view so streaming re-renders only this list, not the toolbar, composer or
/// inspector. It reads the Orb's `OrbTranscript` and nothing of the streamed text (that is a `LiveText` the reply's
/// own views read), so it is redrawn when an item is added or changes, not on every flush, and not at all for
/// another Orb's work; rows are `Equatable`, so only the row that changed re-renders.
private struct TranscriptList: View {
    @Environment(AppModel.self) private var model
    let look: BotLook
    /// Off while the user has scrolled up to read, so new content doesn't pull the view down.
    @State private var followsBottom = true
    /// Scrolls for the lists that cannot keep the bottom in view themselves (macOS 14).
    @State private var follower = BottomFollower()

    var body: some View {
        let transcript = model.orbTranscript(look.id)
        let items = transcript.items
        let live = model.live(look.id)
        let status = live.status
        let isLoading = model.isLoadingConversation(look.id)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        LoadingTranscript()
                    } else if items.isEmpty {
                        EmptyChatView(look: look)
                    }
                    ForEach(items) { item in
                        TranscriptRow(item: item, botID: look.id, orb: look.orb)
                            .equatable()
                    }
                    if let status {
                        WorkingLine(look: look, text: status)
                    }
                    Color.clear.frame(height: 1).id(BottomAnchor.id)
                }
                .animateChanges(of: items.count)
                .animateChanges(of: status == nil)
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
                // The user just sent a message: always show it.
                followsBottom = true
                scrollToBottom(proxy)
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

private struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    let look: BotLook

    private let suggestions = [
        ("folder", "Organize minha pasta Downloads"),
        ("doc.text", "Resuma o arquivo mais recente da minha Mesa"),
        ("internaldrive", "Quanto espaço livre tenho no disco?"),
        ("terminal", "Veja o que está desatualizado no brew")
    ]

    var body: some View {
        let live = model.live(look.id)
        VStack(spacing: 16) {
            BotAvatar(orb: look.orb, size: 96, activity: live.activity, poke: live.poke, interactive: true)
                .padding(.top, 72)
            VStack(spacing: 4) {
                Text(look.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(look.role)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            VStack(spacing: 6) {
                if live.memory.interviewPending {
                    SuggestionButton(symbol: "questionmark.bubble", text: "Me conheça: faça perguntas para entender como me ajudar") {
                        model.send("Oi! Antes de começarmos, me faça algumas perguntas para entender como você pode me ajudar.",
                                   to: look.id)
                    }
                }
                ForEach(suggestions, id: \.1) { symbol, text in
                    SuggestionButton(symbol: symbol, text: text) {
                        model.send(text, to: look.id)
                    }
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
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
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .opacity(isHovering ? 1 : 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .card(radius: 12, fill: isHovering ? Palette.raised : Palette.surface)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Shown until a model provider is configured.
private struct SetupBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Conecte um modelo para começar")
                    .font(.system(size: 13, weight: .semibold))
                Text("xAI, OpenAI, OpenRouter ou um modelo local (Ollama, LM Studio).")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            SettingsLink { Text("Abrir Ajustes") }
                .buttonStyle(PrimaryPillStyle())
        }
        .padding(14)
        .card(radius: 14)
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
    }
}

/// Live status of a working bot: shimmering activity text next to its spinning orb.
private struct WorkingLine: View {
    @Environment(AppModel.self) private var model
    let look: BotLook
    let text: String

    var body: some View {
        let live = model.live(look.id)
        HStack(spacing: 10) {
            BotAvatar(orb: look.orb, size: 30, activity: live.activity, poke: live.poke)
            Text("\(text)…")
                .font(.system(size: 13))
                .shimmer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(look.name): \(text)")
    }
}
