import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var deleting: Bot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SectionTitle("Orbs")
                ForEach(model.bots) { bot in
                    SidebarRow(isSelected: model.selection == .bot(bot.id)) {
                        model.selection = .bot(bot.id)
                    } content: {
                        BotRowContent(bot: bot, status: model.statusLine[bot.id], activity: model.activity(for: bot.id),
                                      isSelected: model.selection == .bot(bot.id), poke: model.pokes[bot.id, default: 0])
                    }
                    .contextMenu {
                        Button("Nova conversa") { model.newConversation(bot.id) }
                        Divider()
                        Button("Apagar \(bot.name)…", role: .destructive) { deleting = bot }
                    }
                }

                SectionTitle("Espaço de trabalho")
                    .padding(.top, 16)
                SidebarRow(isSelected: model.selection == .routines) {
                    model.selection = .routines
                } content: {
                    NavLabel(title: "Rotinas", symbol: "clock.arrow.circlepath")
                }
                SidebarRow(isSelected: model.selection == .connectors) {
                    model.selection = .connectors
                } content: {
                    NavLabel(title: "Conectores", symbol: "point.3.filled.connected.trianglepath.dotted")
                }
                SidebarRow(isSelected: model.selection == .skills) {
                    model.selection = .skills
                } content: {
                    NavLabel(title: "Skills", symbol: "wand.and.stars")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .background(Palette.chrome)
        .confirmationDialog("Apagar \(deleting?.name ?? "")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Apagar o Orb e a memória", role: .destructive) {
                if let bot = deleting { model.deleteBot(bot.id) }
            }
            Button("Apagar o Orb e guardar a memória") {
                if let bot = deleting { model.deleteBot(bot.id, keepMemory: true) }
            }
        } message: {
            Text(DeleteOrbText.message)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(isSelected: false) {
                    openSettings()
                } content: {
                    NavLabel(title: "Ajustes", symbol: "gearshape")
                }
                .help("Ajustes (⌘,)")
                SidebarRow(isSelected: false) {
                    model.showNewBot = true
                } content: {
                    NavLabel(title: "Novo Orb", symbol: "plus")
                }
                .help("Novo Orb (⌘N)")
            }
            .padding(8)
            .background(Palette.chrome)
        }
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-width row with a rounded ghost highlight on hover/selection.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Palette.ghostSelected : (isHovering ? Palette.ghostHover : .clear),
                            in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NavLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26)
                .foregroundStyle(Palette.muted)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 4)
        }
    }
}

private struct BotRowContent: View {
    let bot: Bot
    let status: String?
    let activity: OrbActivity
    let isSelected: Bool
    let poke: Int

    var body: some View {
        HStack(spacing: 8) {
            // Only the selected bot and bots with something going on move; the rest rest (no frames at all).
            BotAvatar(bot: bot, size: 30, activity: activity, paused: !isSelected && activity == .idle, poke: poke)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Group {
                    if let status {
                        Text("\(status)…").shimmer()
                    } else {
                        Text(bot.role).foregroundStyle(Palette.faint)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            .animateChanges(of: status)
            Spacer(minLength: 4)
            ZStack {
                if bot.unread > 0 {
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("\(bot.unread) não lidas")
                }
            }
            .animateChanges(of: bot.unread > 0)
        }
        .accessibilityElement(children: .combine)
    }
}
