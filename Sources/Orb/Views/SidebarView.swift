import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var deleting: BotLook?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SectionTitle("Orbs")
                ForEach(model.botIDs, id: \.self) { id in
                    SidebarBotRow(botID: id, deleting: $deleting)
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

/// One Orb's row. Reads only its own Orb's state, so a tool call, a status or a new unread message in another Orb
/// re-renders that Orb's row and nothing here.
private struct SidebarBotRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @Binding var deleting: BotLook?

    var body: some View {
        let live = model.live(botID)
        let isSelected = model.selection == .bot(botID)
        SidebarRow(isSelected: isSelected) {
            model.selection = .bot(botID)
        } content: {
            BotRowContent(row: BotRow(look: live.look, status: live.status, activity: live.activity, isSelected: isSelected,
                                      poke: live.poke, needsYou: live.needsYou, unread: live.unread))
                .equatable()
        }
        .contextMenu {
            Button("Nova conversa") { model.newConversation(botID) }
            Divider()
            Button("Apagar \(live.look.name)…", role: .destructive) { deleting = live.look }
        }
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

/// What a row shows, as one small value: a row whose value did not change is not rendered again.
private struct BotRow: Equatable {
    let look: BotLook
    let status: String?
    let activity: OrbActivity
    let isSelected: Bool
    let poke: Int
    /// An approval card is open: the Orb is stopped until the user answers.
    let needsYou: Bool
    let unread: Int
}

private struct BotRowContent: View, Equatable {
    let row: BotRow

    var body: some View {
        let (look, status, activity, needsYou) = (row.look, row.status, row.activity, row.needsYou)
        HStack(spacing: 8) {
            // Only the selected bot and bots with something going on move; the rest rest (no frames at all).
            BotAvatar(orb: look.orb, size: 30, activity: activity, paused: !row.isSelected && activity == .idle, poke: row.poke)
            VStack(alignment: .leading, spacing: 1) {
                Text(look.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Group {
                    if needsYou {
                        Text("Precisa de você").foregroundStyle(Palette.warn)
                    } else if let status {
                        Text("\(status)…").shimmer()
                    } else {
                        Text(look.role).foregroundStyle(Palette.faint)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            .animateChanges(of: status)
            .animateChanges(of: needsYou)
            Spacer(minLength: 4)
            ZStack {
                if needsYou {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warn)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Aguardando sua permissão")
                } else if row.unread > 0 {
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("\(row.unread) não lidas")
                }
            }
            .animateChanges(of: needsYou || row.unread > 0)
        }
        .accessibilityElement(children: .combine)
    }
}
