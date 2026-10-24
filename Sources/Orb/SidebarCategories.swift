import SwiftUI

/// A heading of the sidebar that holds some of the Orbs ("Atendimento", "Pesquisa"), only to keep a long list in order.
/// Nothing else reads it: an Orb works the same in or out of one, and a category never owns its Orbs (deleting it puts
/// them back in the loose list). Not a group: a group is Orbs working together (`OrbGroup`).
struct SidebarCategory: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    /// Its Orbs, in sidebar order. An Orb is in one category at most (`SidebarOrder.normalized`).
    var botIDs: [UUID] = []
    /// Folded in the sidebar: its Orbs are hidden under the heading.
    var isCollapsed = false

    /// The longest name a category keeps.
    static let nameLimit = 80
}

extension SidebarCategory {
    /// Tolerant decoding: a category saved by another version still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.value(.name, default: "")
        botIDs = try c.lossyArray(.botIDs)
        isCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    }
}

/// The order of the sidebar's Orbs with categories, as plain values the tests can read.
enum SidebarOrder {
    /// The categories as they must be when only `botIDs` exist: Orbs that are gone leave, and an Orb listed twice stays
    /// only where it appears first. A category left empty stays (the person deletes it).
    static func normalized(_ categories: [SidebarCategory], botIDs: [UUID]) -> [SidebarCategory] {
        let alive = Set(botIDs)
        var placed = Set<UUID>()
        return categories.map { category in
            var category = category
            category.botIDs = category.botIDs.filter { alive.contains($0) && placed.insert($0).inserted }
            return category
        }
    }

    /// The Orbs in no category, in the order of `botIDs`.
    static func loose(_ botIDs: [UUID], categories: [SidebarCategory]) -> [UUID] {
        let placed = Set(categories.flatMap(\.botIDs))
        return botIDs.filter { !placed.contains($0) }
    }

    /// Every Orb in the order the sidebar shows them: the loose ones, then each category's. Folded categories count too,
    /// so an Orb keeps its ⌘ number when its category is folded.
    static func all(_ botIDs: [UUID], categories: [SidebarCategory]) -> [UUID] {
        let alive = Set(botIDs)
        return loose(botIDs, categories: categories) + categories.flatMap { $0.botIDs.filter { alive.contains($0) } }
    }

    /// "Nova categoria" shows at the end of the Orbs once there are two to sort (or a category already), as "Novo grupo" does.
    static func showsNewCategory(botCount: Int, categoryCount: Int) -> Bool { categoryCount > 0 || botCount >= 2 }

    /// The payload an Orb's row carries while it is dragged, and the Orb it names (nil for any other text).
    static func dragPayload(_ botID: UUID) -> String { botID.uuidString }
    static func botID(fromPayload payload: String) -> UUID? { UUID(uuidString: payload) }

    /// A name typed for a category: without the spaces around it and at most `nameLimit` long; nil when blank.
    static func name(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(SidebarCategory.nameLimit))
    }
}

/// What a row of the Orbs reports its frame as, for dragging (`SidebarDrop`).
enum SidebarDropKey: Hashable {
    /// The "Orbs" title, over the loose Orbs.
    case looseTitle
    case row(UUID)
    case header(UUID)
    /// "Arraste um Orb para cá" of an open empty category.
    case placeholder(UUID)
}

/// Where a dragged Orb lands: a list (a category, or the loose Orbs) and a place in it.
struct SidebarDropSlot: Equatable {
    /// nil: the loose Orbs.
    var categoryID: UUID?
    /// Before the `index`th of the other Orbs in that list (the dragged one is not counted).
    var index: Int
}

/// The list while an Orb is dragged over it: the rows part where it would land and close up where it was, and the Orb's
/// own row waits, hidden, in that gap.
struct SidebarDragPreview: Equatable {
    var botID: UUID
    var slot: SidebarDropSlot
    /// How far each row, heading or hint stands moved down (up when negative) to open the gap; missing means it stays.
    var shifts: [SidebarDropKey: CGFloat]
    /// The gap, in the Orbs' coordinate space: as tall as the Orb's row, indented in a category.
    var gap: CGRect
    /// Where the Orb's own row is moved to, hidden: into the gap, so on the drop it shows there and nothing slides.
    var heldOffset: CGSize
    /// The "Arraste um Orb para cá" the gap stands in for (an open empty category).
    var coveredHint: UUID?

    /// The held row goes to the gap; the others make room for it.
    func offset(of key: SidebarDropKey) -> CGSize {
        key == .row(botID) ? heldOffset : CGSize(width: 0, height: shifts[key] ?? 0)
    }

    /// The held row and the hint under the gap are not shown.
    func hides(_ key: SidebarDropKey) -> Bool {
        key == .row(botID) || coveredHint.map { key == .placeholder($0) } == true
    }
}

/// Where a dragged Orb lands and how the list makes room for it, from where the pointer is. Plain values, so the tests
/// read it without a window.
enum SidebarDrop {
    /// The coordinate space of the Orbs, loose and in categories.
    static let space = "sidebar-orbs"
    /// The room between two rows of the Orbs: the spacing of their stacks.
    static let spacing: CGFloat = 1

    /// One list of the sidebar as it is shown: the loose Orbs (no `categoryID`) or a category.
    struct Section: Equatable {
        var categoryID: UUID?
        var botIDs: [UUID]
        var isCollapsed = false
    }

    static func sections(loose: [UUID], categories: [SidebarCategory], botIDs: [UUID]) -> [Section] {
        let alive = Set(botIDs)
        return [Section(categoryID: nil, botIDs: loose)]
            + categories.map { Section(categoryID: $0.id, botIDs: $0.botIDs.filter { alive.contains($0) }, isCollapsed: $0.isCollapsed) }
    }

    /// The list with `botID` held at height `y`. The gap opens at the place whose middle is nearest the pointer, worked out
    /// on the list as it stands without the Orb: `frames` are the rows as laid out, which do not move while dragging, so
    /// the rows never chase the pointer. A folded category takes the Orb at its end, with the gap under its heading.
    static func preview(dragging botID: UUID, at y: CGFloat, in sections: [Section], frames: [SidebarDropKey: CGRect]) -> SidebarDragPreview? {
        guard let held = frames[.row(botID)] else { return nil }
        let room = held.height + spacing
        // What the list shows but the held Orb, top to bottom, and the places between them where it can land (`before`:
        // the index in `items` of what comes right after the place).
        var items: [(key: SidebarDropKey, frame: CGRect)] = []
        var places: [(before: Int, slot: SidebarDropSlot, coversHint: Bool)] = []
        func add(_ key: SidebarDropKey) { if let frame = frames[key] { items.append((key, frame)) } }
        add(.looseTitle)
        for section in sections {
            let others = section.botIDs.filter { $0 != botID }
            if let id = section.categoryID {
                guard frames[.header(id)] != nil else { continue }
                add(.header(id))
                if section.isCollapsed {
                    places.append((items.count, SidebarDropSlot(categoryID: id, index: others.count), false))
                    continue
                }
                if others.isEmpty, frames[.placeholder(id)] != nil {
                    places.append((items.count, SidebarDropSlot(categoryID: id, index: 0), true))
                    add(.placeholder(id))
                    continue
                }
            }
            for (index, other) in others.enumerated() where frames[.row(other)] != nil {
                places.append((items.count, SidebarDropSlot(categoryID: section.categoryID, index: index), false))
                add(.row(other))
            }
            places.append((items.count, SidebarDropSlot(categoryID: section.categoryID, index: others.count), false))
        }
        // Where something stands once the held Orb is taken out: what was under it moves up by its room.
        func top(_ frame: CGRect) -> CGFloat { frame.minY > held.minY ? frame.minY - room : frame.minY }
        func gapTop(_ before: Int) -> CGFloat {
            if items.indices.contains(before) { return top(items[before].frame) }
            return items.last.map { top($0.frame) + $0.frame.height + spacing } ?? held.minY
        }
        func distance(_ before: Int) -> CGFloat { abs(gapTop(before) + held.height / 2 - y) }
        guard let place = places.min(by: { distance($0.before) < distance($1.before) }) else { return nil }

        let gapY = gapTop(place.before)
        var shifts: [SidebarDropKey: CGFloat] = [:]
        for (index, item) in items.enumerated() {
            var shift: CGFloat = item.frame.minY > held.minY ? -room : 0
            if place.coversHint {
                // The hint stays under the gap: what follows it makes room for the row less the hint's own.
                if index > place.before { shift += room - (items[place.before].frame.height + spacing) }
            } else if index >= place.before {
                shift += room
            }
            if shift != 0 { shifts[item.key] = shift }
        }
        let indent = SidebarCategoryLayout.indent
        let gapX = held.minX + (place.slot.categoryID == nil ? 0 : indent)
        let heldIndent: CGFloat = sections.contains { $0.categoryID != nil && $0.botIDs.contains(botID) } ? indent : 0
        return SidebarDragPreview(botID: botID, slot: place.slot, shifts: shifts,
                                  gap: CGRect(x: gapX, y: gapY, width: held.maxX - gapX, height: held.height),
                                  heldOffset: CGSize(width: gapX - held.minX - heldIndent, height: gapY - held.minY),
                                  coveredHint: place.coversHint ? place.slot.categoryID : nil)
    }
}

/// The frames of the Orbs' rows as laid out, collected for dragging.
struct SidebarDropFrames: PreferenceKey {
    static let defaultValue: [SidebarDropKey: CGRect] = [:]
    static func reduce(value: inout [SidebarDropKey: CGRect], nextValue: () -> [SidebarDropKey: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The rows' frames as the drop delegate reads them, in a reference the views do not observe: writing it does not
/// re-evaluate the sidebar, so a slide or a resize costs nothing here.
final class SidebarDropFrameBox {
    var frames: [SidebarDropKey: CGRect] = [:]
}

/// What the sidebar's name field is open for.
enum CategoryNaming: Equatable {
    /// A new category; `moving` is the Orb that goes into it once it has a name ("Mover para → Nova categoria…").
    case new(moving: UUID?)
    case rename(UUID)
}

/// The sentences of the categories, as plain values the tests read.
enum CategoryText {
    /// What the delete confirmation says: the Orbs stay, whole.
    static func deleteMessage(orbCount: Int) -> String {
        let orbs = orbCount == 1 ? "O Orb dela volta solto" : "Os \(orbCount) Orbs dela voltam soltos"
        return "\(orbs) para a lista, com conversa, memória e rotinas. Nenhum Orb é apagado."
    }

    /// What VoiceOver reads for the heading: "Pesquisa, categoria, 3 Orbs, recolhida, precisa de você".
    static func accessibilityLabel(name: String, orbCount: Int, collapsed: Bool, waiting: Bool, unread: Bool) -> String {
        var parts = [name, "categoria", orbCount == 1 ? "1 Orb" : "\(orbCount) Orbs", collapsed ? "recolhida" : "expandida"]
        if collapsed && waiting { parts.append("precisa de você") }
        if collapsed && unread { parts.append("não lido") }
        return parts.joined(separator: ", ")
    }
}

extension AppModel {
    // MARK: Looking

    func category(_ id: UUID) -> SidebarCategory? { categories.first { $0.id == id } }

    /// The category the Orb is in; nil when it is loose.
    func category(of botID: UUID) -> SidebarCategory? { categories.first { $0.botIDs.contains(botID) } }

    /// The Orbs in no category, in sidebar order.
    var looseBotIDs: [UUID] { SidebarOrder.loose(botIDs, categories: categories) }

    /// Every Orb in the order the sidebar shows them (what ⌘1…⌘9, the Orbs menu and the palette count by).
    var sidebarBotIDs: [UUID] { SidebarOrder.all(botIDs, categories: categories) }

    // MARK: Changing

    /// Makes a category (at the end of the list) and puts `botID` in it, when given. Nil when the name is blank.
    @discardableResult
    func createCategory(named name: String, moving botID: UUID? = nil) -> SidebarCategory? {
        guard let title = SidebarOrder.name(name) else { return nil }
        let category = SidebarCategory(name: title)
        categories.append(category)
        if let botID { moveBot(botID, to: category.id) }
        return self.category(category.id)
    }

    /// A blank name is ignored.
    func renameCategory(_ id: UUID, to name: String) {
        guard let title = SidebarOrder.name(name), let index = categories.firstIndex(where: { $0.id == id }),
              categories[index].name != title else { return }
        categories[index].name = title
    }

    /// Puts the Orb at the end of the category, out of the one it was in; `nil` makes it loose again.
    func moveBot(_ botID: UUID, to categoryID: UUID?) {
        guard bot(botID) != nil, category(of: botID)?.id != categoryID else { return }
        var changed = categories
        for index in changed.indices { changed[index].botIDs.removeAll { $0 == botID } }
        if let categoryID {
            guard let index = changed.firstIndex(where: { $0.id == categoryID }) else { return }
            changed[index].botIDs.append(botID)
        }
        categories = changed
    }

    /// Puts the Orb where it was dropped: in `categoryID` (nil: the loose Orbs), before the `index`th of the other Orbs
    /// there (the gap the list opened while dragging). The loose Orbs keep the order of all the Orbs, so placing one
    /// among them moves it in that order: every Orb stays, only places change.
    func placeBot(_ botID: UUID, in categoryID: UUID?, at index: Int) {
        guard bot(botID) != nil else { return }
        let index = max(index, 0)
        if let categoryID {
            guard let target = categories.firstIndex(where: { $0.id == categoryID }) else { return }
            var changed = categories
            for other in changed.indices { changed[other].botIDs.removeAll { $0 == botID } }
            changed[target].botIDs.insert(botID, at: min(index, changed[target].botIDs.count))
            if changed != categories { categories = changed }
            return
        }
        moveBot(botID, to: nil)
        let others = looseBotIDs.filter { $0 != botID }
        guard let last = others.last, let from = bots.firstIndex(where: { $0.id == botID }) else { return }
        // Before the loose Orb now at `index`, or right after the last one.
        let neighbor = others.indices.contains(index) ? others[index] : last
        guard let anchor = bots.firstIndex(where: { $0.id == neighbor }) else { return }
        let offset = others.indices.contains(index) ? anchor : anchor + 1
        if offset != from && offset != from + 1 { bots.move(fromOffsets: IndexSet(integer: from), toOffset: offset) }
    }

    func setCategory(_ id: UUID, collapsed: Bool) {
        guard let index = categories.firstIndex(where: { $0.id == id }), categories[index].isCollapsed != collapsed else { return }
        categories[index].isCollapsed = collapsed
    }

    /// Moves the category one place up (-1) or down (+1) in the list. The array order is the persisted one, so there is
    /// nothing to migrate; at either end it does nothing.
    func moveCategory(_ id: UUID, by step: Int) {
        guard let index = categories.firstIndex(where: { $0.id == id }), step != 0 else { return }
        let target = index + (step < 0 ? -1 : 1)
        guard categories.indices.contains(target) else { return }
        categories.swapAt(index, target)
    }

    /// Whether `moveCategory` would move it: the menu dims its item at the ends.
    func canMoveCategory(_ id: UUID, by step: Int) -> Bool {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return false }
        return categories.indices.contains(index + (step < 0 ? -1 : 1))
    }

    /// Removes the category and nothing else: its Orbs go back to the loose list with everything they have. On purpose this
    /// touches `categories` only, never `bots`, a conversation or a memory.
    func deleteCategory(_ id: UUID) {
        if case .rename(id) = categoryNaming { categoryNaming = nil }
        categories.removeAll { $0.id == id }
    }

    // MARK: Keeping categories true to the Orbs

    /// Runs when the state is read and whenever the list of Orbs changes: a deleted Orb leaves its category.
    func normalizeCategories() {
        guard !categories.isEmpty else { return }
        let normalized = SidebarOrder.normalized(categories, botIDs: botIDs)
        if normalized != categories { categories = normalized }
    }
}
