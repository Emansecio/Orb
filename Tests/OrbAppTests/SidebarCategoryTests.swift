import Foundation
import Testing
@testable import Orb

// The sidebar's categories (`SidebarCategory`): only how the list of Orbs is laid out. Above all, deleting a category
// never deletes an Orb: its Orbs come back loose, with their conversation, memory and routines.

/// An app with a few Orbs saved in a folder of its own, each with a conversation on disk, a memory file and a routine.
@MainActor
private final class CategoryWorld {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbCategories-\(UUID().uuidString)")
    var store: Store { Store(directory: root) }
    private(set) var model: AppModel
    let ids: [UUID]

    init(names: [String] = ["Atlas", "Atendente", "Gestor LP", "Pesquisador"]) {
        var state = AppState(bots: names.map { Bot(name: $0, role: "Papel de \($0)", orb: OrbConfig()) })
        for index in state.bots.indices { state.bots[index].workingDirectory = FileManager.default.temporaryDirectory.path }
        state.routines = state.bots.map { Routine(name: "Rotina de \($0.name)", botID: $0.id, prompt: "pedido", schedule: .everyHours(1)) }
        let store = Store(directory: root)
        store.save(state)
        for bot in state.bots {
            store.save(Conversation(items: [TranscriptItem(.user(text: "oi, \(bot.name)", attachments: [])),
                                            TranscriptItem(.bot(text: "Olá!", isStreaming: false))],
                                    messages: [.user("oi, \(bot.name)"), ChatMessage(role: .assistant, content: "Olá!")]), for: bot.id)
        }
        store.flush()
        ids = state.bots.map(\.id)
        model = AppModel(store: store, runsBackgroundWork: false)
        for id in ids {
            let folder = model.memory.directory(for: id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "Gosta de respostas curtas.".write(to: folder.appending(path: "nota.md"), atomically: true, encoding: .utf8)
        }
    }

    deinit { removeTestFolder(root) }

    /// Writes everything and opens the app again over the same folder.
    func relaunch() {
        model.saveNow()
        model = AppModel(store: store, runsBackgroundWork: false)
    }

    /// What each Orb has on disk and in the app, to compare before and after.
    func footprint(_ id: UUID) -> String {
        let bot = model.bot(id)
        let messages = store.readConversation(id).value?.messages.map(\.content) ?? []
        let note = try? String(contentsOf: model.memory.directory(for: id).appending(path: "nota.md"), encoding: .utf8)
        let routines = model.routines.filter { $0.botID == id }.map(\.name)
        return "\(bot?.name ?? "-")|\(bot?.role ?? "-")|\(messages)|\(note ?? "-")|\(routines)"
    }
}

struct SidebarCategoryDeletingTests {
    @Test @MainActor func deletingACategoryKeepsEveryOrbWholeAndPutsThemBackLoose() throws {
        let world = CategoryWorld()
        let model = world.model
        let before = world.ids.map(world.footprint)
        let bots = model.bots
        let category = try #require(model.createCategory(named: "Atendimento da empresa X"))
        for id in world.ids.prefix(3) { model.moveBot(id, to: category.id) }
        model.setCategory(category.id, collapsed: true)
        #expect(model.looseBotIDs == [world.ids[3]])

        model.deleteCategory(category.id)

        #expect(model.categories.isEmpty)
        #expect(model.bots == bots) // the same Orbs, in the same order, with the same settings
        #expect(model.botIDs == world.ids)
        #expect(model.looseBotIDs == world.ids) // all loose again
        #expect(model.deletingBotID == nil) // no Orb's delete sheet was asked for
        #expect(world.ids.map(world.footprint) == before) // conversation, memory and routines untouched

        // And so it stays once the app is opened again.
        world.relaunch()
        #expect(world.model.bots == bots)
        #expect(world.model.categories.isEmpty)
        #expect(world.model.looseBotIDs == world.ids)
        #expect(world.ids.map(world.footprint) == before)
    }

    @Test @MainActor func deletingOneCategoryLeavesTheOthersAsTheyWere() throws {
        let world = CategoryWorld()
        let model = world.model
        let support = try #require(model.createCategory(named: "Atendimento", moving: world.ids[1]))
        let research = try #require(model.createCategory(named: "Pesquisa", moving: world.ids[3]))
        model.deleteCategory(support.id)
        #expect(model.categories.map(\.id) == [research.id])
        #expect(model.category(of: world.ids[3])?.id == research.id)
        #expect(model.looseBotIDs == [world.ids[0], world.ids[1], world.ids[2]])
        #expect(model.bots.count == 4)
    }

    @Test @MainActor func movingACategoryChangesOnlyTheOrderAndStopsAtTheEnds() throws {
        let world = CategoryWorld()
        let model = world.model
        let a = try #require(model.createCategory(named: "A", moving: world.ids[0]))
        let b = try #require(model.createCategory(named: "B", moving: world.ids[1]))
        let c = try #require(model.createCategory(named: "C", moving: world.ids[2]))
        #expect(!model.canMoveCategory(a.id, by: -1))
        #expect(model.canMoveCategory(a.id, by: 1))
        #expect(!model.canMoveCategory(c.id, by: 1))

        model.moveCategory(c.id, by: -1)
        #expect(model.categories.map(\.id) == [a.id, c.id, b.id])
        model.moveCategory(a.id, by: -1) // already first: nothing happens
        #expect(model.categories.map(\.id) == [a.id, c.id, b.id])
        model.moveCategory(a.id, by: 1)
        #expect(model.categories.map(\.id) == [c.id, a.id, b.id])
        model.moveCategory(UUID(), by: 1) // unknown id
        #expect(model.categories.map(\.id) == [c.id, a.id, b.id])
        #expect(!model.canMoveCategory(UUID(), by: 1))
        #expect(model.category(of: world.ids[0])?.id == a.id) // the Orbs stay where they were
        #expect(model.botIDs == world.ids)

        // The order is the persisted one.
        world.relaunch()
        #expect(world.model.categories.map(\.id) == [c.id, a.id, b.id])
    }

    /// No path of this feature can reach the deletion of an Orb: its code never names it.
    @Test func theCategoryCodeNeverCallsTheDeletionOfAnOrb() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Orb", directoryHint: .isDirectory)
        for file in ["SidebarCategories.swift", "Views/SidebarCategoryViews.swift"] {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            for forbidden in ["deleteBot", "askToDelete", "confirmDelete", "deletingBotID", "bots.remove", "bots =", "bots[",
                              "removeData", "deleteConversation", "memory.delete"] {
                #expect(!text.contains(forbidden), "\(file) contains \(forbidden)")
            }
        }
    }

    @Test @MainActor func deletingAnOrbTakesItOutOfItsCategoryAndTheCategoryStays() throws {
        let world = CategoryWorld()
        let model = world.model
        let category = try #require(model.createCategory(named: "Pesquisa", moving: world.ids[3]))
        _ = model.deleteBot(world.ids[3])
        #expect(model.category(category.id)?.botIDs == [])
        #expect(model.sidebarBotIDs == Array(world.ids.prefix(3)))
    }

    @Test func theHeadingCountsItsOrbsOnlyWhileFolded() {
        #expect(CategoryHeaderText.orbCount(1, collapsed: true) == "1 Orb")
        #expect(CategoryHeaderText.orbCount(3, collapsed: true) == "3 Orbs")
        #expect(CategoryHeaderText.orbCount(0, collapsed: true) == "0 Orbs")
        #expect(CategoryHeaderText.orbCount(3, collapsed: false) == nil)
    }

    @Test func theConfirmationSaysTheOrbsStay() {
        #expect(CategoryText.deleteMessage(orbCount: 1) == "O Orb dela volta solto para a lista, com conversa, memória e rotinas. Nenhum Orb é apagado.")
        #expect(CategoryText.deleteMessage(orbCount: 3) == "Os 3 Orbs dela voltam soltos para a lista, com conversa, memória e rotinas. Nenhum Orb é apagado.")
    }
}

struct SidebarCategoryOrganizingTests {
    @Test @MainActor func anOrbIsInOneCategoryAtMostAndCanComeOut() throws {
        let world = CategoryWorld()
        let model = world.model
        let a = try #require(model.createCategory(named: "A"))
        let b = try #require(model.createCategory(named: "B"))
        let id = world.ids[0]
        model.moveBot(id, to: a.id)
        model.moveBot(id, to: b.id)
        #expect(model.category(a.id)?.botIDs == [])
        #expect(model.category(b.id)?.botIDs == [id])
        model.moveBot(id, to: nil)
        #expect(model.category(of: id) == nil)
        #expect(model.looseBotIDs == world.ids)
        model.moveBot(UUID(), to: a.id) // not an Orb
        model.moveBot(id, to: UUID()) // not a category
        #expect(model.category(a.id)?.botIDs == [] && model.category(of: id) == nil)
    }

    @Test @MainActor func namesAreTrimmedCutAndNeverBlank() throws {
        let world = CategoryWorld()
        let model = world.model
        #expect(model.createCategory(named: "   ") == nil)
        let category = try #require(model.createCategory(named: "  Pesquisa  "))
        #expect(category.name == "Pesquisa")
        model.renameCategory(category.id, to: " ")
        #expect(model.category(category.id)?.name == "Pesquisa")
        model.renameCategory(category.id, to: String(repeating: "x", count: 200))
        #expect(model.category(category.id)?.name.count == SidebarCategory.nameLimit)
    }

    @Test @MainActor func aNewCategoryFromAnOrbsMenuTakesTheOrbIn() throws {
        let world = CategoryWorld()
        let model = world.model
        let category = try #require(model.createCategory(named: "Pesquisa", moving: world.ids[2]))
        #expect(category.botIDs == [world.ids[2]])
        #expect(model.categories.map(\.name) == ["Pesquisa"])
    }

    @Test @MainActor func theSidebarListsTheLooseOrbsThenEachCategoryFoldedOrNot() throws {
        let world = CategoryWorld()
        let model = world.model
        let ids = world.ids
        let support = try #require(model.createCategory(named: "Atendimento"))
        let research = try #require(model.createCategory(named: "Pesquisa"))
        model.moveBot(ids[2], to: support.id)
        model.moveBot(ids[1], to: support.id)
        model.moveBot(ids[0], to: research.id)
        model.setCategory(support.id, collapsed: true)
        #expect(model.looseBotIDs == [ids[3]])
        #expect(model.sidebarBotIDs == [ids[3], ids[2], ids[1], ids[0]])
        // ⌘1…⌘9 count in the same order, folded categories included.
        #expect(model.botID(atShortcut: 0) == ids[3])
        #expect(model.botID(atShortcut: 1) == ids[2])
        #expect(model.botID(atShortcut: 3) == ids[0])
        #expect(model.botID(atShortcut: 4) == nil)
    }

    @Test @MainActor func aDroppedOrbLandsInTheGapAndNoOrbIsLost() throws {
        let world = CategoryWorld() // Atlas, Atendente, Gestor LP, Pesquisador
        let model = world.model
        let ids = world.ids
        let everyone = model.bots.map(\.id)
        let category = try #require(model.createCategory(named: "AcessosFit"))
        // Into the empty category, then one above it and one under them.
        model.placeBot(ids[1], in: category.id, at: 0)
        model.placeBot(ids[2], in: category.id, at: 0)
        model.placeBot(ids[3], in: category.id, at: 2)
        #expect(model.category(category.id)?.botIDs == [ids[2], ids[1], ids[3]])
        // Down inside the category: the gap under the last of the others.
        model.placeBot(ids[2], in: category.id, at: 2)
        #expect(model.category(category.id)?.botIDs == [ids[1], ids[3], ids[2]])
        // Dropped in the gap it left: nothing moves.
        model.placeBot(ids[3], in: category.id, at: 1)
        #expect(model.category(category.id)?.botIDs == [ids[1], ids[3], ids[2]])
        // Out, above Atlas: loose again and first in the sidebar (and on ⌘1).
        model.placeBot(ids[3], in: nil, at: 0)
        #expect(model.looseBotIDs == [ids[3], ids[0]])
        #expect(model.sidebarBotIDs == [ids[3], ids[0], ids[1], ids[2]])
        #expect(model.botID(atShortcut: 0) == ids[3])
        // And under Atlas.
        model.placeBot(ids[3], in: nil, at: 1)
        #expect(model.looseBotIDs == [ids[0], ids[3]])
        // Every Orb is still there: only places changed.
        #expect(Set(model.bots.map(\.id)) == Set(everyone) && model.bots.count == everyone.count)
        // Not an Orb, not a category, not an Orb's payload: nothing happens.
        model.placeBot(UUID(), in: category.id, at: 0)
        model.placeBot(ids[0], in: UUID(), at: 0)
        #expect(SidebarOrder.botID(fromPayload: "um texto qualquer") == nil)
        #expect(SidebarOrder.botID(fromPayload: SidebarOrder.dragPayload(ids[1])) == ids[1])
        #expect(model.category(category.id)?.botIDs == [ids[1], ids[2]])
        #expect(model.looseBotIDs == [ids[0], ids[3]])
    }

    /// Two loose Orbs, an open category with one, a folded one, an open empty one and a folded one after it; rows 44 pt
    /// tall, 1 pt apart.
    private struct DragList {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let open = UUID(), folded = UUID(), empty = UUID(), later = UUID()
        var sections: [SidebarDrop.Section] {
            [SidebarDrop.Section(categoryID: nil, botIDs: [a, b]),
             SidebarDrop.Section(categoryID: open, botIDs: [c]),
             SidebarDrop.Section(categoryID: folded, botIDs: [d], isCollapsed: true),
             SidebarDrop.Section(categoryID: empty, botIDs: []),
             SidebarDrop.Section(categoryID: later, botIDs: [], isCollapsed: true)]
        }
        var frames: [SidebarDropKey: CGRect] {
            func rect(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 264, height: height) }
            return [.looseTitle: rect(0, 18), .row(a): rect(19, 44), .row(b): rect(64, 44),
                    .header(open): rect(109, 28), .row(c): rect(138, 44),
                    .header(folded): rect(183, 28),
                    .header(empty): rect(212, 28), .placeholder(empty): rect(241, 22),
                    .header(later): rect(264, 28)]
        }
        func holding(_ id: UUID, at y: CGFloat) -> SidebarDragPreview? {
            SidebarDrop.preview(dragging: id, at: y, in: sections, frames: frames)
        }
    }

    @Test func theRowsPartWhereTheOrbWouldLandAndCloseWhereItWas() throws {
        let list = DragList()
        // Held over its own place: the gap is where it was and nothing moves.
        let still = try #require(list.holding(list.b, at: 86))
        #expect(still.slot == SidebarDropSlot(categoryID: nil, index: 1))
        #expect(still.shifts.isEmpty && still.heldOffset == .zero)
        #expect(still.gap == CGRect(x: 0, y: 64, width: 264, height: 44))
        #expect(still.hides(.row(list.b)) && !still.hides(.row(list.a)))
        // Up over Atlas: it moves down one row (44 pt and the spacing) and the held row waits where it stood.
        let up = try #require(list.holding(list.b, at: 30))
        #expect(up.slot == SidebarDropSlot(categoryID: nil, index: 0))
        #expect(up.shifts == [.row(list.a): 45])
        #expect(up.offset(of: .row(list.b)) == CGSize(width: 0, height: -45))
        // Down into the open category: its heading comes up into the place left, and the gap stands in, under it.
        let into = try #require(list.holding(list.b, at: 120))
        #expect(into.slot == SidebarDropSlot(categoryID: list.open, index: 0))
        #expect(into.shifts == [.header(list.open): -45])
        #expect(into.gap == CGRect(x: SidebarCategoryLayout.indent, y: 93, width: 264 - SidebarCategoryLayout.indent, height: 44))
        #expect(into.heldOffset == CGSize(width: SidebarCategoryLayout.indent, height: 29))
        // A folded category takes it at its end, with the gap under its heading.
        let folded = try #require(list.holding(list.b, at: 190))
        #expect(folded.slot == SidebarDropSlot(categoryID: list.folded, index: 1))
        #expect(folded.gap.minY == 167)
        #expect(folded.offset(of: .header(list.folded)).height == -45 && folded.offset(of: .header(list.empty)).height == 0)
        // An open empty category: the gap takes the place of its hint, and what follows makes room for the row less the hint.
        let empty = try #require(list.holding(list.b, at: 220))
        #expect(empty.slot == SidebarDropSlot(categoryID: list.empty, index: 0))
        #expect(empty.coveredHint == list.empty && empty.hides(.placeholder(list.empty)))
        #expect(empty.offset(of: .placeholder(list.empty)).height == -45)
        #expect(empty.offset(of: .header(list.later)) == CGSize(width: 0, height: -45 + (45 - 23)))
        // Out of a category, the held row comes back from its indent.
        let out = try #require(list.holding(list.c, at: 30))
        #expect(out.slot == SidebarDropSlot(categoryID: nil, index: 0))
        #expect(out.heldOffset.width == -SidebarCategoryLayout.indent)
        #expect(out.shifts == [.row(list.a): 45, .row(list.b): 45, .header(list.open): 45])
        // Not a row of the list: nothing parts.
        #expect(list.holding(UUID(), at: 30) == nil)
    }

    @Test func draggedDownTheGapVisitsEveryPlaceOnceInOrder() {
        let list = DragList()
        var visited: [SidebarDropSlot] = []
        for y in stride(from: CGFloat(-40), through: 340, by: 1) {
            guard let slot = list.holding(list.b, at: y)?.slot else { continue }
            if visited.last != slot { visited.append(slot) }
        }
        // The frames do not move while dragging, so the gap never goes back and forth.
        #expect(visited == [SidebarDropSlot(categoryID: nil, index: 0), SidebarDropSlot(categoryID: nil, index: 1),
                            SidebarDropSlot(categoryID: list.open, index: 0), SidebarDropSlot(categoryID: list.open, index: 1),
                            SidebarDropSlot(categoryID: list.folded, index: 1), SidebarDropSlot(categoryID: list.empty, index: 0),
                            SidebarDropSlot(categoryID: list.later, index: 0)])
    }

    @Test func withNoOtherLooseOrbTheGapOpensUnderTheTitle() throws {
        let (category, a) = (UUID(), UUID())
        let sections = [SidebarDrop.Section(categoryID: nil, botIDs: []), SidebarDrop.Section(categoryID: category, botIDs: [a])]
        let frames: [SidebarDropKey: CGRect] = [.looseTitle: CGRect(x: 0, y: 0, width: 264, height: 18),
                                                .header(category): CGRect(x: 0, y: 19, width: 264, height: 28),
                                                .row(a): CGRect(x: 0, y: 48, width: 264, height: 44)]
        let out = try #require(SidebarDrop.preview(dragging: a, at: 5, in: sections, frames: frames))
        #expect(out.slot == SidebarDropSlot(categoryID: nil, index: 0))
        #expect(out.gap.minY == 19 && out.shifts == [.header(category): 45])
        let home = try #require(SidebarDrop.preview(dragging: a, at: 70, in: sections, frames: frames))
        #expect(home.slot == SidebarDropSlot(categoryID: category, index: 0) && home.shifts.isEmpty)
    }

    @Test func newCategoryShowsOnceThereAreOrbsToSort() {
        #expect(!SidebarOrder.showsNewCategory(botCount: 0, categoryCount: 0))
        #expect(!SidebarOrder.showsNewCategory(botCount: 1, categoryCount: 0))
        #expect(SidebarOrder.showsNewCategory(botCount: 2, categoryCount: 0))
        #expect(SidebarOrder.showsNewCategory(botCount: 1, categoryCount: 1))
    }

    @Test func normalizingDropsGoneOrbsAndKeepsAnOrbInOnePlace() {
        let (a, b, gone) = (UUID(), UUID(), UUID())
        let first = SidebarCategory(name: "1", botIDs: [a, gone, a])
        let second = SidebarCategory(name: "2", botIDs: [a, b])
        let normalized = SidebarOrder.normalized([first, second], botIDs: [a, b])
        #expect(normalized.map(\.botIDs) == [[a], [b]])
    }
}

struct SidebarCategoryPersistenceTests {
    @Test @MainActor func categoriesTheirOrbsAndFoldingSurviveClosingTheApp() throws {
        let world = CategoryWorld()
        let model = world.model
        let ids = world.ids
        let support = try #require(model.createCategory(named: "Atendimento", moving: ids[1]))
        model.moveBot(ids[2], to: support.id)
        let research = try #require(model.createCategory(named: "Pesquisa", moving: ids[3]))
        model.setCategory(research.id, collapsed: true)
        let saved = model.categories

        world.relaunch()

        #expect(world.model.categories == saved)
        #expect(world.model.category(research.id)?.isCollapsed == true)
        #expect(world.model.category(support.id)?.isCollapsed == false)
        #expect(world.model.looseBotIDs == [ids[0]])
        #expect(world.model.category(of: ids[2])?.id == support.id)
    }

    @Test @MainActor func theAppOpensOnTheOrbAtTheTopOfTheSidebar() throws {
        let world = CategoryWorld()
        world.model.createCategory(named: "Primeiro", moving: world.ids[0])
        world.relaunch()
        #expect(world.model.selection == .bot(world.ids[1])) // the first loose Orb, not the first in the category
    }

    @Test @MainActor func nextAndPreviousOrbWalkTheSidebarNotTheOrderOfCreation() throws {
        let world = CategoryWorld()
        let model = world.model
        let ids = world.ids
        model.createCategory(named: "Pesquisa", moving: ids[1])
        #expect(model.sidebarBotIDs == [ids[0], ids[2], ids[3], ids[1]])
        model.selection = .bot(ids[0])
        model.selectAdjacentBot(offset: 1)
        #expect(model.selection == .bot(ids[2]))
        model.selectAdjacentBot(offset: 1)
        model.selectAdjacentBot(offset: 1)
        #expect(model.selection == .bot(ids[1])) // the one in the category is the last shown
        model.selectAdjacentBot(offset: 1)
        #expect(model.selection == .bot(ids[0])) // and it wraps to the first
        model.selectAdjacentBot(offset: -1)
        #expect(model.selection == .bot(ids[1]))
    }

    @Test @MainActor func deletingTheSelectedOrbSelectsTheOneAtTheTopOfTheSidebar() throws {
        let world = CategoryWorld()
        let model = world.model
        let ids = world.ids
        model.createCategory(named: "Pesquisa", moving: ids[0])
        model.selection = .bot(ids[1])
        _ = model.deleteBot(ids[1])
        #expect(model.selection == .bot(ids[2])) // not ids[0], the first created, which sits in the category
    }

    @Test func anOlderStateFileOpensWithNoCategories() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any])
        object["categories"] = nil
        let state = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(state.categories.isEmpty)
        #expect(state.bots.count == 1)
    }

    @Test func aDamagedCategoryIsSkippedAndTheOthersOpen() throws {
        let id = UUID()
        let json = #"{"bots":[],"categories":[{"name":"Boa","botIDs":["\#(id.uuidString)"],"isCollapsed":true},{"name":7}]}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.categories.map(\.name) == ["Boa"])
        #expect(state.categories.first?.isCollapsed == true)
        #expect(state.categories.first?.botIDs == [id])
    }
}
