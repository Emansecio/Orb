import SwiftUI
import UniformTypeIdentifiers

// The sidebar's categories (see `SidebarCategory`): a heading that folds its Orbs and the field that names one (opened
// from the "+" of "Orbs"). Only how the list is laid out: nothing here deletes an Orb.

/// A category in the sidebar: its heading and, unfolded, its Orbs indented under it. Where a dragged Orb lands is the
/// sidebar's (`SidebarDropDelegate`): this reports its rows' frames, moves them out of the gap's way and lights its
/// heading when folded and aimed at.
struct SidebarCategorySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: SidebarCategory
    /// Every Orb in sidebar order: the rows' ⌘ numbers.
    let order: [UUID]
    /// The Orb being dragged over the list, and where it would land now.
    let drag: SidebarDragPreview?
    let selectionSpace: Namespace.ID
    let rowSpace: Namespace.ID

    var body: some View {
        let ids = category.botIDs.filter { model.botIDs.contains($0) }
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if model.categoryNaming == .rename(category.id) {
                    CategoryNameField(initial: category.name, symbol: "chevron.right", turned: !category.isCollapsed) { name in
                        model.renameCategory(category.id, to: name)
                    }
                } else {
                    SidebarCategoryHeader(category: category, ids: ids,
                                          isTargeted: category.isCollapsed && drag?.slot.categoryID == category.id,
                                          selectionSpace: selectionSpace)
                }
            }
            .sidebarDropItem(.header(category.id), drag)
            if !category.isCollapsed {
                ForEach(ids, id: \.self) { id in
                    SidebarBotRow(botID: id, index: order.firstIndex(of: id) ?? order.count, selectionSpace: selectionSpace, rowSpace: rowSpace)
                        .padding(.leading, SidebarCategoryLayout.indent)
                        .sidebarDropItem(.row(id), drag)
                        .transition(.adapted(.unfold, reduceMotion: reduceMotion))
                }
                if ids.isEmpty {
                    Text("Arraste um Orb para cá")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, SidebarCategoryLayout.titleInset)
                        .padding(.vertical, 4)
                        .sidebarDropItem(.placeholder(category.id), drag)
                        .transition(.adapted(.unfold, reduceMotion: reduceMotion))
                }
            }
        }
    }
}

extension View {
    /// Reports this row's frame among the Orbs, as laid out, for dragging.
    func sidebarDropFrame(_ key: SidebarDropKey) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SidebarDropFrames.self, value: [key: proxy.frame(in: .named(SidebarDrop.space))])
        })
    }

    /// Something in the Orbs' list while an Orb is dragged over it: it moves out of the gap's way (the dragged Orb's own
    /// row waits in the gap, hidden). Its frame is reported as laid out, before that move, so the gap never chases the
    /// pointer.
    func sidebarDropItem(_ key: SidebarDropKey, _ drag: SidebarDragPreview?) -> some View {
        opacity(drag?.hides(key) == true ? 0 : 1)
            .offset(drag?.offset(of: key) ?? .zero)
            .sidebarDropFrame(key)
    }
}

/// The Orbs, loose and in categories, as one place to drop on: while an Orb is dragged over them the rows part where it
/// would land, following the pointer, and close up where it was; it lands in that gap.
struct SidebarDropDelegate: DropDelegate {
    let model: AppModel
    let sections: [SidebarDrop.Section]
    let frames: SidebarDropFrameBox
    @Binding var drag: SidebarDragPreview?
    let reduceMotion: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropEntered(info: DropInfo) {
        aim(info)
        // The row that started the drag said which Orb it is; text dragged in from elsewhere is no Orb and parts nothing.
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [model] object, _ in
            guard let text = object as? NSString else { return }
            let botID = SidebarOrder.botID(fromPayload: text as String)
            Task { @MainActor in if model.draggedBotID != botID { model.draggedBotID = botID } }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        aim(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { show(nil) }

    func performDrop(info: DropInfo) -> Bool {
        guard let landing = drag, model.draggedBotID == landing.botID else {
            show(nil)
            return false
        }
        // The Orb takes the gap and the rows settle where they already stand, in one move.
        withAnimation(reduceMotion ? nil : Motion.content) {
            model.placeBot(landing.botID, in: landing.slot.categoryID, at: landing.slot.index)
            drag = nil
        }
        model.draggedBotID = nil
        return true
    }

    private func aim(_ info: DropInfo) {
        show(model.draggedBotID.flatMap { SidebarDrop.preview(dragging: $0, at: info.location.y, in: sections, frames: frames.frames) })
    }

    /// The rows slide into their new places in the content curve; under Reduce Motion they jump.
    private func show(_ preview: SidebarDragPreview?) {
        guard preview != drag else { return }
        withAnimation(reduceMotion ? nil : Motion.content) { drag = preview }
    }
}

/// The gap a dragged Orb would land in: a dashed outline as tall as its row, as the invitation that makes the first Orb
/// (a place for an Orb). It moves with the rows; drawn under them.
struct SidebarDropGap: View {
    let gap: CGRect?

    var body: some View {
        if let gap {
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Palette.ghostHover)
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: gap.width, height: gap.height)
                .offset(x: gap.minX, y: gap.minY)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The heading: an arrow that turns, the name, and the number of Orbs. Folded, it also says what its hidden Orbs say
/// (one waiting for you, unread messages), and it carries the selection while the open Orb is hidden in it.
private struct SidebarCategoryHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: SidebarCategory
    let ids: [UUID]
    /// An Orb is being dragged over the category.
    let isTargeted: Bool
    let selectionSpace: Namespace.ID
    @State private var isConfirmingDelete = false

    var body: some View {
        let collapsed = category.isCollapsed
        let holdsSelection = ids.contains { model.selection == .bot($0) }
        let waiting = ids.contains { model.live($0).needsYou }
        let unread = ids.contains { model.live($0).unread > 0 }
        SidebarRow(isSelected: collapsed && holdsSelection, selectionSpace: selectionSpace,
                   help: collapsed ? "Mostra os Orbs desta categoria" : "Recolhe os Orbs desta categoria") {
            model.setCategory(category.id, collapsed: !collapsed)
        } content: { _ in
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    // The arrow turns in the content curve; under Reduce Motion it just takes its new direction.
                    .animation(Motion.panel(reduceMotion: reduceMotion), value: collapsed)
                    .frame(width: 26)
                    .foregroundStyle(Palette.muted)
                Text(category.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(collapsed && holdsSelection ? Palette.ink : Palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ZStack {
                    if collapsed && waiting {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warn)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    } else if collapsed && unread {
                        Circle()
                            .fill(Palette.accentText)
                            .frame(width: 7, height: 7)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: collapsed && (waiting || unread))
                Text("\(ids.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .monospacedDigit()
            }
            .hoverFill(isTargeted, in: .rect(cornerRadius: Radius.medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CategoryText.accessibilityLabel(name: category.name, orbCount: ids.count, collapsed: collapsed,
                                                                waiting: waiting, unread: unread))
        }
        .accessibilityHint(collapsed ? "Mostra os Orbs" : "Recolhe os Orbs")
        .contextMenu {
            Button(collapsed ? "Expandir" : "Recolher", systemImage: collapsed ? "chevron.down" : "chevron.right") {
                model.setCategory(category.id, collapsed: !collapsed)
            }
            Button("Renomear", systemImage: "pencil") { model.categoryNaming = .rename(category.id) }
            Button("Mover para cima", systemImage: "arrow.up") { model.moveCategory(category.id, by: -1) }
                .disabled(!model.canMoveCategory(category.id, by: -1))
            Button("Mover para baixo", systemImage: "arrow.down") { model.moveCategory(category.id, by: 1) }
                .disabled(!model.canMoveCategory(category.id, by: 1))
            Divider()
            // Not red: nothing is lost, the Orbs stay. An empty category goes without asking.
            if ids.isEmpty {
                Button("Apagar categoria", systemImage: "trash") { model.deleteCategory(category.id) }
            } else {
                Button("Apagar categoria…", systemImage: "trash") { isConfirmingDelete = true }
            }
        }
        .confirmationDialog("Apagar a categoria \(category.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Apagar categoria") { model.deleteCategory(category.id) }
        } message: {
            Text(CategoryText.deleteMessage(orbCount: ids.count))
        }
    }
}

/// The name field of a category being made, after the categories: it opens from the "+" of "Orbs", an Orb's
/// "Mover para → Nova categoria…" and the palette, and shows nothing otherwise.
struct NewCategoryRow: View {
    @Environment(AppModel.self) private var model
    let selectionSpace: Namespace.ID

    var body: some View {
        if case .new(let moving) = model.categoryNaming {
            CategoryNameField(initial: "", symbol: "plus") { name in
                model.createCategory(named: name, moving: moving)
            }
        }
    }
}

/// The name typed in the row itself, as in the Finder: ↩ keeps it, esc gives up, and clicking elsewhere keeps what was
/// typed. A blank name keeps nothing (the category is not made, or keeps its old name).
private struct CategoryNameField: View {
    @Environment(AppModel.self) private var model
    let initial: String
    /// The symbol in the row's icon column, so the field stands where the row it replaces stood.
    let symbol: String
    /// The arrow of an unfolded category points down, as on its heading.
    var turned = false
    let save: (String) -> Void
    @State private var text: String
    @State private var isDone = false
    @FocusState private var isFocused: Bool

    init(initial: String, symbol: String, turned: Bool = false, save: @escaping (String) -> Void) {
        self.initial = initial
        self.symbol = symbol
        self.turned = turned
        self.save = save
        _text = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "plus" ? 13 : 10, weight: symbol == "plus" ? .regular : .semibold))
                .rotationEffect(.degrees(turned ? 90 : 0))
                .frame(width: 26)
                .foregroundStyle(Palette.muted)
            TextField("Nome da categoria", text: $text, prompt: Text("Nome da categoria"))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .focused($isFocused)
                .onSubmit { finish(keeping: true) }
                .onExitCommand { finish(keeping: false) }
                .onChange(of: text) {
                    if text.count > SidebarCategory.nameLimit { text = String(text.prefix(SidebarCategory.nameLimit)) }
                }
                .accessibilityLabel("Nome da categoria")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: Radius.medium))
        // A hairline, so the field does not read as the selected row.
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.lineStrong))
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { if !isFocused { finish(keeping: true) } }
    }

    private func finish(keeping: Bool) {
        guard !isDone else { return }
        isDone = true
        if keeping, let name = SidebarOrder.name(text), name != initial { save(name) }
        model.categoryNaming = nil
    }
}

/// Where the rows of a category stand, as plain values.
enum SidebarCategoryLayout {
    /// How far a category's Orbs stand in from its heading.
    static let indent: CGFloat = 14
    /// Where the heading's name starts: the row's padding, the icon column and the space after it.
    static let titleInset: CGFloat = 8 + 26 + 10
}
