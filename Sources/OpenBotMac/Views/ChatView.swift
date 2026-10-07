import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        @Bindable var model = model
        let items = model.transcript(bot.id)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        EmptyChatView(bot: bot)
                    }
                    ForEach(items) { item in
                        TranscriptRow(item: item, bot: bot)
                    }
                    if let status = model.statusLine[bot.id] {
                        WorkingLine(bot: bot, text: status)
                    }
                    Color.clear.frame(height: 1).id(BottomAnchor.id)
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.scrollTick[bot.id]) {
                proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
            }
            .onAppear { proxy.scrollTo(BottomAnchor.id, anchor: .bottom) }
        }
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

    private enum BottomAnchor { static let id = "bottom" }
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
