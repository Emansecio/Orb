import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one selection background slides between the rows through this namespace.
    @Namespace private var selectionSpace
    /// An Orb's row slides from where it was to where it went (into a category, out of one) through this one.
    @Namespace private var rowSpace
    /// The Orbs the rows were last laid out for (nil until the first appearance): an update that adds or removes one
    /// together with the selection is a row coming or going, and its layout must not animate (an Orb that only moved in
    /// the list is neither).
    @State private var settledBotIDs: [UUID]?
    /// The height of the window's toolbar over the sidebar (its top safe area), applied once by hand: left to the scroll
    /// view, it is applied twice and "Orbs" starts a whole toolbar below the window's buttons.
    @State private var toolbarHeight: CGFloat = 0
    /// For snapshots: the words of the invitation when the screen beside it forces its own (the app reads them from the model).
    var invitationCopy: WelcomeCopy?
    /// For snapshots: the dragged Orb (`AppModel.draggedBotID`) held at this height over the Orbs, so the rows part where
    /// it would land.
    var previewDropY: CGFloat?

    /// The Orb being dragged over the list and the gap the rows open for it, and the rows' frames it is worked out from.
    @State private var drag: SidebarDragPreview?
    /// Held in a box nobody observes: the frames change at every frame of a slide or a resize, and only a drop reads them.
    @State private var dropFrames = SidebarDropFrameBox()
    /// "Orbs" and "Outros" fold their lists: session-only, so nothing stays hidden across launches.
    @State private var orbsUnfolded = true
    @State private var looseUnfolded = true

    var body: some View {
        let order = model.sidebarBotIDs
        // Worked out once per body: each of these is a computed property or a set comparison, and the drop delegate,
        // the preference callback and the two modifiers below all need them.
        let looseIDs = model.looseBotIDs
        let sections = SidebarDrop.sections(loose: looseIDs, categories: model.categories, botIDs: model.botIDs)
        let listChanged = settledBotIDs.map { Set($0) != Set(model.botIDs) } ?? false
        let isNamingNewCategory = if case .new = model.categoryNaming { true } else { false }
        let nestedLoose = !model.categories.isEmpty && !looseIDs.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarFeatureRow(item: .inicio, name: "Início", symbol: "house",
                                  tip: "Mostra as novidades e os acompanhamentos dos Orbs", selectionSpace: selectionSpace)
                    .accessibilityIdentifier("sidebar-inicio")
                    .padding(.bottom, 16)
                // The Orbs, loose and in categories, as one place to drop on: the gap opens anywhere among them.
                VStack(alignment: .leading, spacing: 1) {
                    // "Orbs" folds the whole list; "Outros" gathers the loose ones once a category exists to sort them
                    // from, so every list under "Orbs" is a foldable group.
                    SidebarFoldHeader(title: "Orbs", unfolded: orbsUnfolded, ids: model.botIDs, selectionSpace: selectionSpace) {
                        NewOrbMenu().padding(.trailing, 2)
                    } action: {
                        withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { orbsUnfolded.toggle() }
                    }
                    .sidebarDropFrame(.looseTitle)
                    if orbsUnfolded {
                        if model.botIDs.isEmpty {
                            // No Orbs: an invitation in the list's own place. It shows the welcome screen (what you get with
                            // nothing selected); when that is already on screen, the click opens the New Orb sheet instead.
                            SidebarRow(isSelected: model.selection == nil, selectionSpace: selectionSpace, isDashed: true,
                                       help: model.selection == nil ? Tip.createFirstOrb : Tip.showWelcome) {
                                if model.selection == nil {
                                    model.startNewOrb(from: nil)
                                } else {
                                    model.selection = nil
                                }
                            } content: { _ in
                                FirstOrbInvitation(isSelected: model.selection == nil, title: (invitationCopy ?? model.welcomeCopy).invitationTitle)
                            }
                            .transition(.opacity)
                        }
                        if nestedLoose {
                            SidebarFoldHeader(title: "Outros", unfolded: looseUnfolded, ids: looseIDs,
                                              isTargeted: !looseUnfolded && drag?.slot.categoryID == nil, sub: true,
                                              selectionSpace: selectionSpace) { EmptyView() } action: {
                                withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { looseUnfolded.toggle() }
                            }
                            .padding(.leading, SidebarCategoryLayout.subIndent)
                            .sidebarDropItem(.othersTitle, drag)
                        }
                        if !nestedLoose || looseUnfolded {
                            ForEach(looseIDs, id: \.self) { id in
                                SidebarBotRow(botID: id, index: order.firstIndex(of: id) ?? order.count, selectionSpace: selectionSpace, rowSpace: rowSpace)
                                    .padding(.leading, nestedLoose ? SidebarCategoryLayout.indent : 0)
                                    .sidebarDropItem(.row(id), drag)
                                    .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                            }
                        }
                        // The categories, after the loose Orbs: only how the list is laid out.
                        ForEach(model.categories) { category in
                            SidebarCategorySection(category: category, order: order, drag: drag, selectionSpace: selectionSpace, rowSpace: rowSpace)
                                .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                        }
                    }
                }
                .coordinateSpace(.named(SidebarDrop.space))
                .onPreferenceChange(SidebarDropFrames.self) { frames in
                    dropFrames.frames = frames
                    if let previewDropY, let held = model.draggedBotID {
                        drag = SidebarDrop.preview(dragging: held, at: previewDropY, in: sections, frames: frames)
                    }
                }
                .onDrop(of: [.plainText], delegate: SidebarDropDelegate(
                    model: model, sections: sections,
                    frames: dropFrames, drag: $drag, reduceMotion: reduceMotion))
                .background(alignment: .topLeading) { SidebarDropGap(gap: drag?.gap) }

                // The name field of a category being made (the "+" of the Orbs, an Orb's "Mover para", the palette).
                if isNamingNewCategory {
                    NewCategoryRow(selectionSpace: selectionSpace)
                        .padding(.leading, SidebarCategoryLayout.subIndent)
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                }

                // MARK: MultiOrb (WP6): the groups, below the Orbs; the section shows once there are two Orbs to put together
                // (or a group already), and its "+" makes a new one.
                if !model.groups.isEmpty || model.botIDs.count >= 2 {
                    SidebarGroupsSection(selectionSpace: selectionSpace)
                        .padding(.top, 16)
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                }
                // MARK: end MultiOrb (WP6)

                // The workspace pages, as rows after the lists: same look and selection as "Início".
                SidebarFeatureRow(item: .routines, name: "Rotinas", symbol: "clock.arrow.circlepath",
                                  tip: Tip.allRoutines, shortcut: AppShortcut.routines.label, selectionSpace: selectionSpace)
                    .accessibilityIdentifier("sidebar-routines")
                    .padding(.top, 16)
                SidebarFeatureRow(item: .connectors, name: "Conectores", symbol: "point.3.filled.connected.trianglepath.dotted",
                                  tip: Tip.manageConnectors, shortcut: AppShortcut.connectors.label, selectionSpace: selectionSpace)
                    .accessibilityIdentifier("sidebar-connectors")
                SidebarFeatureRow(item: .skills, name: "Skills", symbol: "wand.and.stars",
                                  tip: Tip.skillsPage, shortcut: AppShortcut.skills.label, selectionSpace: selectionSpace)
                    .accessibilityIdentifier("sidebar-skills")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .padding(.top, toolbarHeight)
            // A new or a deleted Orb: the row comes (rises 6 pt) or goes (fades) and the others slide, bound to the ids, so a
            // status or an unread count moves nothing. Written before the selection's modifier below, which is the outer
            // one: the animation of the list wins when both change in one update, and the highlight (which would slide
            // with it) holds still then, see `SidebarRow`.
            .animateChanges(of: model.botIDs)
            // A category made, folded, unfolded or deleted, an Orb moved into one: the rows below slide in the content curve.
            .animateChanges(of: model.categories)
            .environment(\.sidebarListChanged, listChanged)
            // Bound to the selection alone: the background slides to the new row and the title changes color with it,
            // while a status or an unread count that changes in a row does not animate along (no animation per Orb).
            // Not when the list itself changed in the same update (a new or a deleted Orb): then only the rows' own
            // transitions apply and the ones below do not slide.
            .animation(Motion.selection(reduceMotion: reduceMotion, listChanged: listChanged),
                       value: model.selection)
            .onChange(of: model.botIDs, initial: true) { settledBotIDs = model.botIDs }
            // A name field opens for a new category while "Orbs" is folded: it has to be seen, so the section unfolds.
            .onChange(of: model.categoryNaming) { if case .new = model.categoryNaming { orbsUnfolded = true } }
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
        .background(Palette.chrome)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                KeptMemoryBanner()
                HStack(spacing: 6) {
                    ProfileRowButton()
                    Button("Ajustes", systemImage: "gearshape") { SettingsRouter.show(using: openSettings) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(CircleGhostStyle(side: 28, fontSize: 15))
                        .foregroundStyle(Palette.muted)
                        .iconTip(Tip.settings(), label: "Ajustes")
                }
                // The profile's highlight on the rows' 8 pt (its picture on the Orbs' avatars, 16 pt from the edge) and
                // the gear's center under the titles' "+" (20 pt from the edge), so the foot hangs on the list's lines.
                .padding(.leading, 8)
                .padding(.trailing, 6)
            }
            // A little more air under the picture than above the titles: at 8 pt it sat on the window's edge.
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Palette.chrome)
        }
    }
}

/// A section's title, with what sits at its right edge (a "+" that makes a new one).
struct SectionTitle<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).sectionTitleStyle()
            Spacer(minLength: 4)
            trailing
        }
        // The text starts on the rows' content edge (the Orbs' avatars), 8 pt inside the list's own 8 pt.
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }
}

/// The small "+" at the right of a section title: dim at rest, lighter under the pointer, a 20 pt target. The Orbs'
/// title wraps it in a `Menu`, the groups' in a `Button`.
struct SectionPlus: View {
    /// The target's side: 20 pt beside a title, 16 pt in an Orb's row (its name's line height).
    var size: CGFloat = 20
    /// The one "+" the sidebar draws, in a button or as a decoration (an invitation, a name field, "Nova conversa").
    static let glyph = Font.system(size: 11, weight: .medium)
    /// The small arrow beside it (a folded list's chevron, a category's, a close mark): one step lighter than the "+" in
    /// size, heavier in weight, so a 10 pt stroke reads as much as an 11 pt one.
    static let chevron = Font.system(size: 10, weight: .semibold)
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(Self.glyph)
            // `hint` is decorative only (about 3:1); the "+" is a control, so it rests at `faint`.
            .foregroundStyle(isHovering ? Palette.secondary : Palette.faint)
            .frame(width: size, height: size)
            .hoverFill(isHovering, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .animation(Motion.fade, value: isHovering)
    }
}

/// The "+" of "Orbs": a new Orb, or a new category when there are Orbs to sort.
private struct NewOrbMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Novo Orb  \(AppShortcut.newBot.label)") { model.showNewBot = true }
            // Nothing to sort with a single Orb and no category (the same rule the palette follows): the item stays, dimmed.
            Button("Nova categoria") { model.categoryNaming = .new(moving: nil) }
                .disabled(!SidebarOrder.showsNewCategory(botCount: model.botIDs.count, categoryCount: model.categories.count))
        } label: {
            SectionPlus()
        }
        // `.button` with a plain style keeps the label a SwiftUI view, so the "+" keeps its own color and matches the
        // groups' `Button`; `.borderlessButton` draws the label through AppKit, which showed it lighter.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Tip.newOrbOrCategory)
        .accessibilityLabel("Novo Orb ou categoria")
        .accessibilityIdentifier("sidebar-new-orb")
    }
}

/// One of the sidebar's page rows — "Início" at the top, the workspace pages (Rotinas, Conectores, Skills) after the
/// lists: icon and name, the selection's background sliding between them through the rows' own namespace.
private struct SidebarFeatureRow: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let name: String
    let symbol: String
    let tip: String
    var shortcut = ""
    let selectionSpace: Namespace.ID

    var body: some View {
        let isSelected = model.selection == item
        SidebarRow(isSelected: isSelected, selectionSpace: selectionSpace,
                   help: shortcut.isEmpty ? tip : "\(tip) (\(shortcut))") {
            model.selection = item
        } content: { _ in
            Label(name, systemImage: symbol)
                .font(Typography.text.weight(.medium))
                .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
        }
    }
}

/// A heading that folds its list — "Orbs" over the whole section, "Outros" over the loose Orbs once a category exists.
/// Folded, it carries the selection when the open Orb hides in it, the marks of what it hides and the count. The
/// trailing edge is free for "Orbs"' "+" (a separate target, never a nested button). `sub` draws the heading as a
/// sub-section: smaller and quieter, so it reads under "Orbs", not beside it.
private struct SidebarFoldHeader<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let unfolded: Bool
    /// The Orbs the heading hides when folded (all of them for "Orbs", the loose ones for "Outros").
    let ids: [UUID]
    /// An Orb is being dragged over the folded heading.
    var isTargeted = false
    /// A sub-section heading ("Outros"): smaller and quieter than "Orbs".
    var sub = false
    let selectionSpace: Namespace.ID
    @ViewBuilder let trailing: Trailing
    let action: () -> Void

    var body: some View {
        let collapsed = !unfolded
        let holdsSelection = collapsed && ids.contains { model.selection == .bot($0) }
        let waiting = ids.contains { model.live($0).needsYou }
        let unread = ids.contains { model.live($0).unread > 0 }
        let hidden = title == "Orbs" ? "os Orbs" : "os Orbs soltos"
        HStack(spacing: 0) {
            SidebarRow(isSelected: holdsSelection, selectionSpace: selectionSpace,
                       help: collapsed ? "Mostra \(hidden)" : "Recolhe \(hidden)") { action() } content: { _ in
                HStack(spacing: SidebarCategoryLayout.iconGap) {
                    Image(systemName: "chevron.right")
                        .font(SectionPlus.chevron)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        // The arrow turns in the content curve; under Reduce Motion it just takes its new direction.
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: collapsed)
                        .frame(width: SidebarCategoryLayout.iconColumn)
                        .foregroundStyle(Palette.faint)
                    Text(title)
                        .font(sub ? Typography.label.weight(.medium) : Typography.text.weight(.medium))
                        .foregroundStyle(collapsed && holdsSelection ? Palette.ink : sub ? Palette.faint : Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ZStack {
                        if collapsed && waiting {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(Typography.label)
                                .foregroundStyle(Palette.warn)
                                .transition(.adapted(.mark, reduceMotion: reduceMotion))
                        } else if collapsed && unread {
                            Circle()
                                .fill(Palette.accentText)
                                .frame(width: 7, height: 7)
                                .transition(.adapted(.mark, reduceMotion: reduceMotion))
                        }
                    }
                    .motion(value: collapsed && (waiting || unread))
                    // The number only stands in for the hidden Orbs: unfolded, the Orbs themselves are there to count.
                    if collapsed {
                        Text("\(ids.count)")
                            .font(Typography.small)
                            .foregroundStyle(Palette.faint)
                            .monospacedDigit()
                            .help(CategoryText.orbs(ids.count))
                    }
                }
                .frame(minHeight: SidebarCategoryLayout.headerContentHeight)
                .hoverFill(isTargeted, in: .rect(cornerRadius: Radius.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityLabel(title: title, orbCount: ids.count, collapsed: collapsed, waiting: waiting, unread: unread))
            }
            trailing
        }
    }

    /// What VoiceOver reads for the heading: "Orbs, 3 Orbs, recolhidos, precisa de você".
    private static func accessibilityLabel(title: String, orbCount: Int, collapsed: Bool, waiting: Bool, unread: Bool) -> String {
        var parts = [title, CategoryText.orbs(orbCount), collapsed ? "recolhidos" : "expandidos"]
        if collapsed && waiting { parts.append("precisa de você") }
        if collapsed && unread { parts.append("não lido") }
        return parts.joined(separator: ", ")
    }
}

/// Full-width row with a rounded ghost highlight on hover and selection. The content learns whether the pointer is on
/// the row (the Orbs' rows show their ⌘1…⌘9 then). Only the selected row paints the selection background, and it is
/// the same view for every row (`matchedGeometryEffect`): when the selection changes it slides from one row to the
/// other instead of vanishing and reappearing. Hover is per row, in fast and out slow.
struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let selectionSpace: Namespace.ID
    /// A dashed outline: the row that invites you to make the first Orb.
    var isDashed = false
    /// False when something around the row paints the selection instead (the open Orb's card with its conversations).
    var paintsSelection = true
    var help = ""
    /// What the row carries when it is dragged (an Orb's row, onto a category); nil for a row that is not dragged.
    var dragPayload: String?
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    /// Runs as the drag starts, before the row is over anything.
    var dragBegan: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        let row = content(isHovering)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: Radius.medium))
                .overlay {
                    if isDashed {
                        RoundedRectangle(cornerRadius: Radius.medium)
                            .strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .background {
                    if isSelected, paintsSelection { SidebarSelectionFill(selectionSpace: selectionSpace) }
                }
                .contentShape(.rect)
        Group {
            if let dragPayload {
                // On macOS a `Button` takes the mouse down for itself and a drag never starts from it: a row that can be
                // dragged answers the click with a tap, and is still a button for VoiceOver.
                row
                    .onTapGesture(perform: action)
                    .onDrag {
                        dragBegan()
                        return NSItemProvider(object: dragPayload as NSString)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, action)
            } else {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            }
        }
        .help(help)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selection's background, one view for every row (`matchedGeometryEffect`), so it slides from one to the other.
private struct SidebarSelectionFill: View {
    let selectionSpace: Namespace.ID
    @Environment(\.sidebarListChanged) private var listChanged

    var body: some View {
        SlidingSelectionFill(space: selectionSpace, radius: Radius.medium)
            // The list changed in this update (a new Orb that is chosen, a deleted one): the rows come and go, and the
            // highlight does not slide to a row that is still arriving.
            .transaction { if listChanged { $0.animation = nil } }
    }
}

/// A selection's background in the sidebar (rows, footer pages, conversations, each set in its own namespace): it slides
/// to the one chosen (the same view in every place, `matchedGeometryEffect`), and under Reduce Motion fades out of one and
/// into the other instead.
struct SlidingSelectionFill: View {
    let space: Namespace.ID
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius).fill(Palette.ghostSelected)
        if reduceMotion {
            shape.transition(.opacity)
        } else {
            shape.matchedGeometryEffect(id: SidebarSelection.id, in: space)
        }
    }
}

extension EnvironmentValues {
    /// The list of Orbs changed in the update being drawn (the rows are arriving or leaving).
    @Entry fileprivate var sidebarListChanged = false
}

/// What the sidebar's selection is made of, as plain values the tests can read.
enum SidebarSelection {
    /// The id the selected background carries in the namespace.
    static let id = "selecao"
}

/// The user's picture and name at the foot of the sidebar, highlighted like a row: it opens "Você" in Ajustes (with
/// "Seu perfil" in place of the name, an invitation to fill it in while it is empty). A small view of its own, so
/// typing in the profile redraws only it.
private struct ProfileRowButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isHovering = false

    var body: some View {
        let profile = model.profile
        let name = profile.shownName
        Button { SettingsRouter.open(.general, using: openSettings) } label: {
            // The Orbs' rows' geometry (a 30 pt picture, 8 pt to the text), so the name starts on the Orbs' names.
            HStack(spacing: 8) {
                ProfileAvatar(photoPath: model.profilePhotoPath, initial: profile.initial, size: 30)
                Text(name ?? "Seu perfil")
                    .font(Typography.text.weight(.medium))
                    .foregroundStyle(name == nil ? Palette.muted : Palette.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, Spacing.xs + Spacing.hairline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering, in: .rect(cornerRadius: Radius.medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Tip.profile(callName: profile.callName))
        .accessibilityLabel(name.map { "Seu perfil, \($0)" } ?? "Seu perfil")
        .accessibilityHint("Abre os Ajustes")
    }
}

/// One Orb's row. Reads only its own Orb's state, so a tool call, a status or a new unread message in another Orb
/// re-renders that Orb's row and nothing here.
struct SidebarBotRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    /// Position in the list: the first nine answer ⌘1…⌘9.
    let index: Int
    let selectionSpace: Namespace.ID
    /// Moved into or out of a category, the row slides from where it was to where it went.
    let rowSpace: Namespace.ID

    var body: some View {
        let live = model.live(botID)
        let isSelected = model.selection == .bot(botID)
        // The open Orb with more than one conversation is one card: the selection wraps its row and its conversations.
        // Folded, the conversations are out of sight and the row alone is the card.
        let chats = isSelected ? live.chats : nil
        let folded = chats?.collapsed == true
        // The name and the reply under it are cut to one line each: the hover text has the name whole.
        VStack(alignment: .leading, spacing: 0) {
            SidebarRow(isSelected: isSelected, selectionSpace: selectionSpace, paintsSelection: chats == nil || folded, help: live.look.name,
                       dragPayload: SidebarOrder.dragPayload(botID)) {
                model.selection = .bot(botID)
            } content: { isHovering in
                BotRowContent(row: BotRow(look: live.look, workText: live.shownWork?.headline, shimmers: live.shownWork?.shimmers ?? false, activity: live.activity, isSelected: isSelected,
                                          celebration: live.celebration, ack: live.poke, cue: live.cue, glance: live.glance, needsYou: live.needsYou, unread: live.unread, reply: live.lastReply, replyTime: BotRow.time(of: live.lastReply),
                                          // MARK: MultiOrb (WP2): the ring of the Orb it is exchanging messages with
                                          partner: live.partner,
                                          hint: isHovering && index < 9 ? AppShortcut.bot(at: index).label : nil,
                                          landing: live.landing, botID: botID, chatsFolded: chats == nil ? nil : folded,
                                          showsNewChat: isHovering))
                    .equatable()
            } dragBegan: {
                model.draggedBotID = botID
            }
            // The row is one element for VoiceOver: what its own buttons do is offered as actions on it.
            .accessibilityActions {
                Button(CommandName.newChat) { model.newChat(for: botID) }
                if chats != nil {
                    Button(folded ? SidebarText.unfoldChats : SidebarText.foldChats) { setFolded(!folded) }
                }
            }
            .contextMenu {
                Button(CommandName.newChat, systemImage: "square.and.pencil") { model.newChat(for: botID) }
                if chats != nil {
                    Button(folded ? SidebarText.unfoldChats : SidebarText.foldChats, systemImage: folded ? "chevron.down" : "chevron.right") {
                        setFolded(!folded)
                    }
                }
                Button(CommandName.openFolder, systemImage: "folder") { model.openFolder(of: botID) }
                Button("Renomear…", systemImage: "pencil") { model.showNameEditor(of: botID) }
                Button("Personalizar…", systemImage: "paintpalette") { model.showLookEditor(of: botID) }
                MoveToCategoryMenu(botID: botID)
                // MARK: MultiOrb (WP6)
                Button("Criar grupo com…", systemImage: "person.3") {
                    model.newGroupStart = botID
                    model.showNewGroup = true
                }
                .disabled(model.botIDs.count < 2)
                Button("Ver todas as rotinas", systemImage: "clock.arrow.circlepath") { model.selection = .routines }
                Divider()
                Button("Apagar \(live.look.name)…", systemImage: "trash", role: .destructive) { model.askToDelete(botID) }
            }
            // The open Orb's conversations, once it has more than one and they are not folded under its row.
            if let chats, !folded {
                SidebarChatList(botID: botID, chats: chats)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .background { if chats != nil, !folded { SidebarSelectionFill(selectionSpace: selectionSpace) } }
        .matchedGeometryEffect(id: botID, in: rowSpace)
    }

    /// Folds or unfolds the conversations under the row: the list unfolds (a fade under Reduce Motion) and the rows below follow.
    private func setFolded(_ folded: Bool) {
        withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { model.setChatsCollapsed(folded, for: botID) }
    }
}

/// "Mover para" in an Orb's menu: the categories (a check on the one it is in), a new one, and out of its category.
private struct MoveToCategoryMenu: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let current = model.category(of: botID)?.id
        Menu("Mover para", systemImage: "rectangle.stack") {
            ForEach(model.categories) { category in
                Toggle(category.name, isOn: Binding(get: { current == category.id },
                                                    set: { model.moveBot(botID, to: $0 ? category.id : nil) }))
            }
            if !model.categories.isEmpty { Divider() }
            Button("Nova categoria…") { model.categoryNaming = .new(moving: botID) }
            if current != nil {
                Divider()
                Button("Tirar da categoria") { model.moveBot(botID, to: nil) }
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
                    .font(SectionPlus.glyph)
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.text.weight(.medium))
                    .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
                Text("Seus Orbs aparecem aqui")
                    .font(Typography.small)
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
struct BotRow: Equatable {
    let look: BotLook
    /// What the Orb is doing ("Rodando swift build", "Pensando…"); nil when no turn runs.
    let workText: String?
    /// The text shimmers: the Orb works, it is not waiting (for you or to try again).
    let shimmers: Bool
    let activity: OrbActivity
    let isSelected: Bool
    /// How big its joy is while it is happy.
    let celebration: OrbCelebration
    /// Changes when a prompt is sent: the Orb gives its small "got it" jump.
    let ack: Int
    /// A new cue makes the Orb blink or sigh once.
    let cue: OrbCueSignal
    /// Changes when the Orb is selected: it glances toward the chat.
    let glance: Int
    /// An approval card is open: the Orb is stopped until the user answers.
    let needsYou: Bool
    let unread: Int
    /// Its latest reply and when it ended: the second line while it rests, and the time beside its name.
    let reply: ReplyPreview?
    /// The time beside its name, as the row writes it. In the compared value because the label depends on the day, not only
    /// on the reply: "14:30" has to become "Ontem" at midnight, and a row whose value did not change is not rendered again.
    let replyTime: String?
    /// The Orb it is exchanging messages with now: its avatar gets a ring in that Orb's color.
    var partner: PartnerTint?
    /// The shortcut shown while the pointer is on the row.
    var hint: String?
    /// Changes once when the Orb was just born from another Orb's proposal: its avatar gives the birth hop (MultiOrb, WP3).
    var landing = 0
    /// Whose row it is: what its "+" and its chevron act on.
    let botID: UUID
    /// The open Orb's conversations under the row are folded (true) or listed (false); nil when there are none to list.
    var chatsFolded: Bool?
    /// The pointer is on the row: the "+" that opens a new conversation shows beside the shortcut.
    var showsNewChat = false

    static func time(of reply: ReplyPreview?, now: Date = .now, calendar: Calendar = .current) -> String? {
        reply.map { ReplyTime.label($0.date, now: now, calendar: calendar) }
    }
}

private struct SelectionRest: Hashable {
    var selected: Bool
    var idle: Bool
    var glance: Int
}

private struct BotRowContent: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: BotRow
    /// The selected row has looked at the chat and nothing has happened since: it rests like the others.
    @State private var selectionSettled = false

    nonisolated static func == (a: BotRowContent, b: BotRowContent) -> Bool { a.row == b.row }

    /// The ring around the avatar: amber while the Orb waits for you (even mid-exchange: you come first), the partner's
    /// color while two Orbs exchange messages (MultiOrb, WP2), blue while it works.
    private var ring: Color? {
        if row.needsYou { return Palette.warn }
        if let partner = row.partner { return OrbCatalog.shared.palette(partner.color).core }
        return row.workText != nil ? Palette.accent : nil
    }

    var body: some View {
        let (look, workText, activity, needsYou) = (row.look, row.workText, row.activity, row.needsYou)
        HStack(spacing: 8) {
            // Only the selected bot and bots with something going on move; the rest rest (no frames at all).
            BotAvatar(orb: look.orb, size: 30, activity: activity, celebration: row.celebration,
                      paused: activity == .idle && (!row.isSelected || selectionSettled), ack: row.ack, landing: row.landing, glance: row.glance, cue: row.cue)
                // A 1.5 pt ring that says what is going on at a glance. It fades in and out (opacity only, so it is the same
                // under Reduce Motion).
                .overlay {
                    if let ring {
                        Circle()
                            .strokeBorder(ring.opacity(0.55), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.fade, value: ring)
                // The selected Orb stays awake for its glance, then rests too (an idle Orb that never stops costs frames forever).
                .task(id: SelectionRest(selected: row.isSelected, idle: activity == .idle, glance: row.glance)) {
                    selectionSettled = false
                    guard row.isSelected, activity == .idle else { return }
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled { selectionSettled = true }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    let name = Text(look.name)
                        .font(Typography.text.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    // The shortcut takes the time's place while the pointer is on the row. The name comes first: the time
                    // shows only where both fit.
                    if let hint = row.hint {
                        name
                        Spacer(minLength: 4)
                        Text(hint)
                            .font(Typography.small)
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    } else if let replyTime = row.replyTime {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                name.fixedSize()
                                Spacer(minLength: 4)
                                Text(replyTime)
                                    .font(Typography.small.monospacedDigit())
                                    .foregroundStyle(Palette.faint)
                            }
                            HStack(spacing: 4) {
                                name
                                Spacer(minLength: 0)
                            }
                        }
                    } else {
                        name
                        Spacer(minLength: 4)
                    }
                    // A strip of fixed width at the right: the "+" that opens a new conversation (under the pointer only) and the
                    // chevron that folds the open Orb's list. Both 16 pt high, the name's line. The "+" is always in the layout and
                    // only fades, so the pointer passing over the row never shortens a long name.
                    HStack(spacing: 0) {
                        Button { model.newChat(for: row.botID) } label: { SectionPlus(size: 16) }
                            .buttonStyle(.plain)
                            .help("\(CommandName.newChat) (\(AppShortcut.newChat.label))")
                            .opacity(row.showsNewChat ? 1 : 0)
                            .allowsHitTesting(row.showsNewChat)
                            // Nor a stop for the keyboard while it is not seen.
                            .disabled(!row.showsNewChat)
                            .animation(Motion.fade, value: row.showsNewChat)
                            .accessibilityHidden(true)
                        if let folded = row.chatsFolded {
                            Button {
                                withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { model.setChatsCollapsed(!folded, for: row.botID) }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(SectionPlus.chevron)
                                    .rotationEffect(.degrees(folded ? 0 : 90))
                                    .animation(Motion.panel(reduceMotion: reduceMotion), value: folded)
                                    .foregroundStyle(Palette.faint)
                                    .frame(width: 16, height: 16)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(folded ? "Mostra as conversas deste Orb" : "Recolhe as conversas deste Orb")
                            .accessibilityHidden(true)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Group {
                        if needsYou {
                            Text("Precisa de você").foregroundStyle(Palette.warn)
                        } else if let workText {
                            if row.shimmers {
                                Text(workText).shimmer()
                            } else {
                                Text(workText).foregroundStyle(Palette.faint)
                            }
                        } else if let reply = row.reply {
                            Text(reply.text).foregroundStyle(Palette.faint)
                        } else {
                            Text(look.role).foregroundStyle(Palette.faint)
                        }
                    }
                    .font(Typography.small)
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    ZStack {
                        // While it waits for you, the amber ring and the amber "Precisa de você" already say so (VoiceOver
                        // reads that text, the row is one element): no third sign here, and no count over it.
                        if !needsYou, row.unread > 0 {
                            // One unread is a dot; from two on the count is worth its width.
                            Group {
                                if row.unread >= 2 {
                                    Text(row.unread > 99 ? "99+" : "\(row.unread)")
                                        .font(Typography.small.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Palette.onInk)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(Capsule().fill(Palette.accentText))
                                } else {
                                    Circle()
                                        .fill(Palette.accentText)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                            .accessibilityLabel(SidebarText.unread(row.unread))
                        }
                    }
                    .animateChanges(of: needsYou || row.unread > 0)
                }
            }
            // The same height with or without a second line (an Orb with no role), so the rows keep one rhythm.
            .frame(minHeight: 32, alignment: .leading)
            .animateChanges(of: workText)
            .animateChanges(of: needsYou)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The sentences the sidebar's rows say aloud.
enum SidebarText {
    static func unread(_ count: Int) -> String { count == 1 ? "1 não lida" : "\(count) não lidas" }
    static let foldChats = "Recolher conversas"
    static let unfoldChats = "Mostrar conversas"
}
