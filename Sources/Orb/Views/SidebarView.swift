import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SectionTitle("Orbs")
                ForEach(Array(model.botIDs.enumerated()), id: \.element) { index, id in
                    SidebarBotRow(botID: id, index: index)
                }

                SectionTitle("Espaço de trabalho")
                    .padding(.top, 16)
                SidebarRow(isSelected: model.selection == .routines) {
                    model.selection = .routines
                } content: { hovering in
                    NavLabel(title: "Rotinas", symbol: "clock.arrow.circlepath", hint: hovering ? "⌥⌘R" : nil)
                }
                SidebarRow(isSelected: model.selection == .connectors) {
                    model.selection = .connectors
                } content: { hovering in
                    NavLabel(title: "Conectores", symbol: "point.3.filled.connected.trianglepath.dotted", hint: hovering ? "⌥⌘C" : nil)
                }
                SidebarRow(isSelected: model.selection == .skills) {
                    model.selection = .skills
                } content: { hovering in
                    NavLabel(title: "Skills", symbol: "wand.and.stars", hint: hovering ? "⌥⌘K" : nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .background(Palette.chrome)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                KeptMemoryBanner()
                HStack(spacing: 6) {
                    Button { model.showNewBot = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Novo Orb")
                            Spacer(minLength: 4)
                            Text("⌘N")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryPillStyle())
                    .help("Criar um novo Orb (⌘N)")
                    Button("Ajustes", systemImage: "gearshape") { openSettings() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(SidebarIconStyle())
                        .foregroundStyle(Palette.muted)
                        .help("Ajustes (⌘,)")
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 8)
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

/// Full-width row with a rounded ghost highlight on hover/selection. The content learns whether the pointer is on
/// the row (the Orbs' rows show their ⌘1…⌘9 then).
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content(isHovering)
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

private struct SidebarIconStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .frame(width: 32, height: 32)
            .background(configuration.isPressed || isHovering ? Palette.ghostSelected : .clear, in: .circle)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}

/// One Orb's row. Reads only its own Orb's state, so a tool call, a status or a new unread message in another Orb
/// re-renders that Orb's row and nothing here.
private struct SidebarBotRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    /// Position in the list: the first nine answer ⌘1…⌘9.
    let index: Int

    var body: some View {
        let live = model.live(botID)
        let isSelected = model.selection == .bot(botID)
        SidebarRow(isSelected: isSelected) {
            model.selection = .bot(botID)
        } content: { isHovering in
            BotRowContent(row: BotRow(look: live.look, status: live.status, activity: live.activity, isSelected: isSelected,
                                      poke: live.poke, needsYou: live.needsYou, unread: live.unread,
                                      hint: isHovering && index < 9 ? "⌘\(index + 1)" : nil))
                .equatable()
        }
        .contextMenu {
            Button(CommandName.newConversation, systemImage: "square.and.pencil") {
                model.selection = .bot(botID)
                model.newConversation(botID)
            }
            Button(CommandName.conversations, systemImage: "clock.arrow.circlepath") {
                model.showConversations(of: botID)
            }
            Button(CommandName.openFolder, systemImage: "folder") { model.openFolder(of: botID) }
            Button("Personalizar…", systemImage: "paintpalette") { model.showLookEditor(of: botID) }
            Button("Ver todas as rotinas", systemImage: "clock") { model.selection = .routines }
            Divider()
            Button("Apagar \(live.look.name)…", systemImage: "trash", role: .destructive) { model.askToDelete(botID) }
        }
    }
}

private struct NavLabel: View {
    let title: String
    let symbol: String
    var hint: String?

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
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
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
    /// The shortcut shown while the pointer is on the row.
    var hint: String?
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
            if let hint = row.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
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
