import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one selection background slides between the rows through this namespace.
    @Namespace private var selectionSpace
    /// The Orbs the rows were last laid out for (nil until the first appearance): an update that changes this list
    /// together with the selection is a row coming or going, and its layout must not animate.
    @State private var settledBotIDs: [UUID]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SectionTitle("Orbs")
                if model.botIDs.isEmpty {
                    // No Orbs: an invitation in the list's own place. It shows the welcome screen (what you get with
                    // nothing selected); when that is already on screen, the click opens the New Orb sheet instead.
                    SidebarRow(isSelected: model.selection == nil, selectionSpace: selectionSpace, isDashed: true) {
                        if model.selection == nil {
                            model.startNewOrb(from: nil)
                        } else {
                            model.selection = nil
                        }
                    } content: { _ in
                        FirstOrbInvitation(isSelected: model.selection == nil, title: model.welcomeCopy.invitationTitle)
                    }
                }
                ForEach(Array(model.botIDs.enumerated()), id: \.element) { index, id in
                    SidebarBotRow(botID: id, index: index, selectionSpace: selectionSpace)
                }

                SectionTitle("Espaço de trabalho")
                    .padding(.top, 16)
                SidebarRow(isSelected: model.selection == .routines, selectionSpace: selectionSpace) {
                    model.selection = .routines
                } content: { hovering in
                    NavLabel(title: "Rotinas", isSelected: model.selection == .routines, symbol: "clock.arrow.circlepath", hint: hovering ? "⌥⌘R" : nil)
                }
                SidebarRow(isSelected: model.selection == .connectors, selectionSpace: selectionSpace) {
                    model.selection = .connectors
                } content: { hovering in
                    NavLabel(title: "Conectores", isSelected: model.selection == .connectors, symbol: "point.3.filled.connected.trianglepath.dotted", hint: hovering ? "⌥⌘C" : nil)
                }
                SidebarRow(isSelected: model.selection == .skills, selectionSpace: selectionSpace) {
                    model.selection = .skills
                } content: { hovering in
                    NavLabel(title: "Skills", isSelected: model.selection == .skills, symbol: "wand.and.stars", hint: hovering ? "⌥⌘K" : nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // Bound to the selection alone: the background slides to the new row and the title changes color with it,
            // while a status or an unread count that changes in a row does not animate along (no animation per Orb).
            // Not when the list itself changed in the same update (a new or a deleted Orb): then only the rows' own
            // transitions apply and the ones below do not slide.
            .animation(Motion.selection(reduceMotion: reduceMotion, listChanged: settledBotIDs.map { $0 != model.botIDs } ?? false),
                       value: model.selection)
            .onChange(of: model.botIDs, initial: true) { settledBotIDs = model.botIDs }
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

/// Full-width row with a rounded ghost highlight on hover and selection. The content learns whether the pointer is on
/// the row (the Orbs' rows show their ⌘1…⌘9 then). Only the selected row paints the selection background, and it is
/// the same view for every row (`matchedGeometryEffect`): when the selection changes it slides from one row to the
/// other instead of vanishing and reappearing. Hover is per row, in fast and out slow.
private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let selectionSpace: Namespace.ID
    /// A dashed outline: the row that invites you to make the first Orb.
    var isDashed = false
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content(isHovering)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: 10))
                .overlay {
                    if isDashed {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Palette.ghostSelected)
                            .matchedGeometryEffect(id: SidebarSelection.id, in: selectionSpace)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What the sidebar's selection is made of, as plain values the tests can read.
enum SidebarSelection {
    /// The id the selected background carries in the namespace.
    static let id = "selecao"
}

private struct SidebarIconStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .frame(width: 32, height: 32)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .circle,
                       color: Palette.ghostSelected)
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
    let selectionSpace: Namespace.ID

    var body: some View {
        let live = model.live(botID)
        let isSelected = model.selection == .bot(botID)
        SidebarRow(isSelected: isSelected, selectionSpace: selectionSpace) {
            model.selection = .bot(botID)
        } content: { isHovering in
            BotRowContent(row: BotRow(look: live.look, workText: live.shownWork?.text, shimmers: live.shownWork?.shimmers ?? false, activity: live.activity, isSelected: isSelected,
                                      poke: live.poke, glance: live.glance, needsYou: live.needsYou, unread: live.unread,
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
    /// The row is the selected one: its title goes from `secondary` to `ink` along with the background.
    let isSelected: Bool
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
                .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
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

/// The row that stands where the Orbs go when there are none: a dashed circle with a plus, what it is for and where
/// the Orbs will be. Selected while the welcome screen shows.
private struct FirstOrbInvitation: View {
    let isSelected: Bool
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
                Text("Seus Orbs aparecem aqui")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(isSelected ? "Abre a folha Novo Orb" : "Mostra a tela de boas-vindas")
    }
}

/// What a row shows, as one small value: a row whose value did not change is not rendered again.
private struct BotRow: Equatable {
    let look: BotLook
    /// What the Orb is doing ("Rodando swift build", "Pensando…"); nil when no turn runs.
    let workText: String?
    /// The text shimmers: the Orb works, it is not waiting (for you or to try again).
    let shimmers: Bool
    let activity: OrbActivity
    let isSelected: Bool
    let poke: Int
    /// Changes when the Orb is selected: it glances toward the chat.
    let glance: Int
    /// An approval card is open: the Orb is stopped until the user answers.
    let needsYou: Bool
    let unread: Int
    /// The shortcut shown while the pointer is on the row.
    var hint: String?
}

private struct BotRowContent: View, Equatable {
    let row: BotRow

    var body: some View {
        let (look, workText, activity, needsYou) = (row.look, row.workText, row.activity, row.needsYou)
        HStack(spacing: 8) {
            // Only the selected bot and bots with something going on move; the rest rest (no frames at all).
            BotAvatar(orb: look.orb, size: 30, activity: activity, paused: !row.isSelected && activity == .idle, poke: row.poke,
                      glance: row.glance)
            VStack(alignment: .leading, spacing: 1) {
                Text(look.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Group {
                    if needsYou {
                        Text("Precisa de você").foregroundStyle(Palette.warn)
                    } else if let workText {
                        if row.shimmers {
                            Text(workText).shimmer()
                        } else {
                            Text(workText).foregroundStyle(Palette.faint)
                        }
                    } else {
                        Text(look.role).foregroundStyle(Palette.faint)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            .animateChanges(of: workText)
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
                        .accessibilityLabel("Precisa da sua permissão")
                } else if row.unread > 0 {
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel(SidebarText.unread(row.unread))
                }
            }
            .animateChanges(of: needsYou || row.unread > 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sentences the sidebar's rows say aloud.
enum SidebarText {
    static func unread(_ count: Int) -> String { count == 1 ? "1 não lida" : "\(count) não lidas" }
}
