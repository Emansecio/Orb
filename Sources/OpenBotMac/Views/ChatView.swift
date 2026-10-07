import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        @Bindable var model = model
        TranscriptList(bot: bot)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !model.isProviderReady {
                    SetupBanner()
                }
                ComposerView(bot: bot)
            }
        }
        .background(Palette.canvas)
        .navigationTitle(bot.name)
        .navigationSubtitle(model.modelName(for: bot))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Nova conversa", systemImage: "square.and.pencil") {
                    model.newConversation(bot.id)
                }
                .help("Nova conversa (⇧⌘N)")
                Button("Painel do bot", systemImage: "sidebar.right") {
                    model.showInspector.toggle()
                }
                .help("Mostrar/ocultar detalhes (⌥⌘B)")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            BotInspector(botID: bot.id)
                .inspectorColumnWidth(min: 244, ideal: 320, max: 420)
        }
    }
}

/// The conversation. Its own view so streaming re-renders only this list, not the toolbar, composer or
/// inspector; rows are `Equatable`, so only the row that changed re-renders.
private struct TranscriptList: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    /// Off while the user has scrolled up to read, so new content doesn't pull the view down.
    @State private var followsBottom = true

    var body: some View {
        let items = model.transcript(bot.id)
        let status = model.statusLine[bot.id]

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        EmptyChatView(bot: bot)
                    }
                    ForEach(items) { item in
                        TranscriptRow(item: item, bot: bot)
                            .equatable()
                    }
                    if let status {
                        WorkingLine(bot: bot, text: status)
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
            }
            .scrollIndicators(.automatic)
            .modifier(BottomFollowing(isFollowing: $followsBottom))
            .onChange(of: model.scrollTick[bot.id]) {
                if followsBottom { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
            }
            .onChange(of: model.pokes[bot.id]) {
                // The user just sent a message: always show it.
                followsBottom = true
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onAppear { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
        }
    }

    private enum BottomAnchor { static let id = "bottom" }
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

private struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    private let suggestions = [
        ("folder", "Organize minha pasta Downloads"),
        ("doc.text", "Resuma o arquivo mais recente da minha Mesa"),
        ("internaldrive", "Quanto espaço livre tenho no disco?"),
        ("terminal", "Veja o que está desatualizado no brew")
    ]

    var body: some View {
        VStack(spacing: 16) {
            BotAvatar(bot: bot, size: 96, activity: model.activity(for: bot.id), poke: model.pokes[bot.id, default: 0],
                      interactive: true)
                .padding(.top, 72)
            VStack(spacing: 4) {
                Text(bot.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(bot.role)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.1) { symbol, text in
                    SuggestionButton(symbol: symbol, text: text) {
                        model.send(text, to: bot.id)
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
    let bot: Bot
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(bot: bot, size: 30, activity: model.activity(for: bot.id), poke: model.pokes[bot.id, default: 0])
            Text("\(text)…")
                .font(.system(size: 13))
                .shimmer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bot.name): \(text)")
    }
}
