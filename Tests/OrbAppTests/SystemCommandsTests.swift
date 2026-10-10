import Foundation
import SwiftUI
import Testing
@testable import Orb

@Suite struct SystemCommandsTests {
    // MARK: Menu bar icon

    @Test func waitingOutranksWorkingAndIdle() {
        #expect(MenuBarState.resolve(waiting: 0, working: 0) == .idle)
        #expect(MenuBarState.resolve(waiting: 0, working: 2) == .working(2))
        #expect(MenuBarState.resolve(waiting: 1, working: 2) == .waiting(1))
        #expect(MenuBarState.waiting(1).hasBadge)
        #expect(!MenuBarState.working(1).hasBadge)
    }

    @Test func iconSpeaksInPortuguese() {
        #expect(MenuBarState.idle.accessibilityLabel == "Orb")
        #expect(MenuBarState.waiting(1).accessibilityLabel == "Orb: 1 Orb precisa da sua permissão")
        #expect(MenuBarState.waiting(3).accessibilityLabel == "Orb: 3 Orbs precisam da sua permissão")
        #expect(MenuBarState.working(1).accessibilityLabel == "Orb: 1 Orb trabalhando")
    }

    /// The Orb's icon is a template at 18 pt, so the menu bar tints it for a light or a dark bar.
    @MainActor @Test func menuBarIconIsATemplateOf18Points() {
        for state in [MenuBarState.idle, .working(1), .waiting(1)] {
            let image = MenuBarIcon.image(for: state)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
    }

    /// The three states are three pictures, and the count of working Orbs does not change the picture.
    @MainActor @Test func menuBarIconStatesDrawDifferentPictures() {
        let idle = menuBarAlphas(.idle), working = menuBarAlphas(.working(1)), waiting = menuBarAlphas(.waiting(1))
        #expect(idle != working)
        #expect(working != waiting)
        #expect(idle != waiting)
        #expect(menuBarAlphas(.working(2)) == working)
    }

    /// Idle is an outline (its middle is empty), working is the Orb filled (its middle is ink) with the face cut out of it.
    @MainActor @Test func menuBarIconIdleIsAnOutlineAndWorkingIsFilledWithAFace() {
        let idle = menuBarAlphas(.idle), working = menuBarAlphas(.working(1))
        let middle = CGPoint(x: 9, y: 9), leftEye = CGPoint(x: 6.3, y: 7.7)
        #expect(menuBarAlpha(idle, at: middle) < 64)
        #expect(menuBarAlpha(working, at: middle) > 200)
        #expect(menuBarAlpha(idle, at: leftEye) > 200)
        #expect(menuBarAlpha(working, at: leftEye) < 64)
    }

    /// Waiting for you is the filled Orb with a solid dot on its upper-right rim, outside the Orb, behind a clear ring.
    @MainActor @Test func menuBarIconWaitingHasADotOnTheRim() {
        let waiting = menuBarAlphas(.waiting(1)), working = menuBarAlphas(.working(1))
        let beyondTheRim = CGPoint(x: 16.2, y: 1.8)
        #expect(menuBarAlpha(waiting, at: beyondTheRim) > 200)
        #expect(menuBarAlpha(working, at: beyondTheRim) < 64)
    }

    /// Premultiplied alpha of the icon drawn on a 2x (36 px) bitmap, row by row from the top.
    @MainActor private func menuBarAlphas(_ state: MenuBarState, scale: Int = 2) -> [UInt8] {
        let pixels = 18 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        MenuBarIcon.image(for: state).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.bitmapData!
        // Rows are padded: each starts at `bytesPerRow`, not at 4 bytes per pixel.
        return (0..<pixels).flatMap { y in (0..<pixels).map { x in data[y * rep.bytesPerRow + x * 4 + 3] } }
    }

    /// The alpha of the pixel under a point (in points, from the top-left) of a 2x render.
    private func menuBarAlpha(_ alphas: [UInt8], at point: CGPoint) -> Int {
        Int(alphas[Int(point.y * 2) * 36 + Int(point.x * 2)])
    }

    // MARK: Shortcuts

    @Test func noTwoShortcutsOfAGroupShareAKey() {
        for group in ShortcutCatalog.groups {
            let keys = group.items.map(\.keys)
            #expect(Set(keys).count == keys.count, "\(group.title)")
        }
        #expect(Set(ShortcutCatalog.items.map(\.id)).count == ShortcutCatalog.items.count) // one item per command
    }

    /// ⌘↩ is answered by several views, each only while it is on screen; no other key is listed twice.
    @Test func onlyTheReturnKeyIsSharedBetweenGroups() {
        let keys = ShortcutCatalog.items.map(\.keys)
        let repeated = Set(keys.filter { key in keys.filter { $0 == key }.count > 1 })
        #expect(repeated == [AppShortcut.commandReturn.label])
    }

    @Test func theKeysTheMenusDeclareAreUniqueAndNotTheSystems() {
        let all = AppShortcut.all
        #expect(Set(all).count == all.count)
        // The ones every Mac app answers to are not taken over.
        for key in ["c", "v", "x", "z", "a", "q", "w", "h", "m", ","] {
            #expect(!all.contains(KeyboardShortcut(KeyEquivalent(Character(key)))), "⌘\(key) é do sistema")
        }
    }

    @Test func everyKeyOfTheMenusIsInTheCatalog() {
        let keys = ShortcutCatalog.groups.flatMap(\.items).map(\.keys)
        for shortcut in AppShortcut.all.prefix(AppShortcut.all.count - 9) {
            #expect(keys.contains(shortcut.label), "\(shortcut.label) falta no catálogo")
        }
        #expect(keys.contains("⌘1 – ⌘9"))
    }

    /// The sheet, Ajustes → Geral and the palette read one catalog: a key a view declares for itself is in it too.
    @Test func theKeysOfTheViewsAreInTheCatalogToo() {
        let keys = ShortcutCatalog.items.map(\.keys)
        for shortcut in AppShortcut.contextual { #expect(keys.contains(shortcut.label), "\(shortcut.label) falta no catálogo") }
        for key in ["⇧⌘M", "⌘↩", "⌘Z", "⌘,", "esc", "↩", "⌥↩", "⌃⌥Espaço"] { #expect(keys.contains(key), "\(key) falta no catálogo") }
        // Every command has a key, and each is listed once.
        for command in ShortcutCommand.allCases {
            #expect(ShortcutCatalog.items.filter { $0.command == command }.count == 1, "\(command)")
            #expect(!ShortcutCatalog.keys(for: command).isEmpty, "\(command)")
        }
    }

    @Test func theContextualKeysDoNotCollideWithTheMenus() {
        for shortcut in AppShortcut.contextual where shortcut != AppShortcut.settings && shortcut != AppShortcut.undoForget {
            #expect(!AppShortcut.all.contains(shortcut), "\(shortcut.label)")
        }
    }

    /// The palette does not write keys of its own: each action shows the catalog's key for its command.
    @Test func theKeysInThePaletteAreTheCatalogsKeys() {
        let expected: [String: ShortcutCommand] = [
            "new-conversation": .newConversation, "focus": .writeMessage, "history": .conversations, "folder": .openFolder,
            "inspector": .toggleInspector, "new-bot": .newBot, "page-routines": .routines, "page-connectors": .connectors,
            "page-skills": .skills,
        ]
        let entries = sample()
        for (id, command) in expected {
            let entry = entries.first { $0.id == id }
            #expect(entry?.shortcut == ShortcutCatalog.keys(for: command), "\(id)")
        }
        let catalogKeys = Set(ShortcutCatalog.items.map(\.keys))
        for entry in entries { if let key = entry.shortcut, entry.section != .orbs { #expect(catalogKeys.contains(key), "\(entry.id)") } }
    }

    @Test func shortcutsAreWrittenLikeTheMenusDo() {
        #expect(AppShortcut.toggleInspector.label == "⌥⌘B")
        #expect(AppShortcut.newConversation.label == "⇧⌘N")
        #expect(AppShortcut.previousBot.label == "⌥↑")
        #expect(AppShortcut.bot(at: 2).label == "⌘3")
        #expect(AppShortcut.stop.label == "⌘.")
    }

    /// In a multi-line field of macOS, Shift-Return sends; the line break is Option-Return. The hints say so.
    @Test func newLineHintIsOptionReturn() {
        #expect(CommandName.newLineKeys == "⌥↩")
        let items = ShortcutCatalog.groups.flatMap(\.items)
        #expect(items.contains { $0.keys == "⌥↩" && $0.title == "Nova linha na mensagem" })
        #expect(!items.contains { $0.keys.contains("⇧↩") })
    }

    @Test func catalogListsTheCommandsOfTheMenus() {
        let keys = Set(ShortcutCatalog.groups.flatMap(\.items).map(\.keys))
        for key in ["⌘N", "⇧⌘N", "⌘K", "⌘L", "⌘Y", "⇧⌘O", "⌘.", "⌥⌘B", "⌥⌘R", "⌥⌘C", "⌥⌘K", "⌥↑", "⌥↓"] {
            #expect(keys.contains(key), "\(key) falta no catálogo")
        }
    }

    // MARK: Palette

    private func sample() -> [PaletteEntry] {
        let atlas = BotLook(Bot(id: UUID(), name: "Atlas", role: "Assistente do seu Mac", orb: OrbConfig()))
        let luna = BotLook(Bot(id: UUID(), name: "Luna", role: "Agenda", orb: OrbConfig()))
        let archive = [ConversationSummary(title: "Organizar a pasta Downloads", createdAt: .now, updatedAt: .now, messageCount: 4)]
        return PaletteBuilder.entries(orbs: [atlas, luna], current: atlas.id, routines: [], skills: [], archive: archive)
    }

    @Test func emptyQueryKeepsTheGroupsInOrder() {
        let sections = PaletteSearch.rank(sample(), query: "").map(\.section)
        #expect(sections == sections.sorted())
        #expect(sections.first == .orbs)
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(PaletteSearch.rank(sample(), query: "INTEGRACOES").map(\.id) == ["page-connectors"]) // keyword "integrações"
        #expect(PaletteSearch.rank(sample(), query: "historico").contains { $0.id == "history" }) // keyword "histórico"
        #expect(PaletteSearch.rank(sample(), query: "luna").first?.title == "Luna")
    }

    @Test func titlePrefixBeatsContains() {
        let ranked = PaletteSearch.rank(sample(), query: "conversa")
        // "Conversas anteriores" (starts with it) comes before "Nova conversa" (a later word) and the archived one.
        let titles = ranked.map(\.title)
        #expect(titles.first == "Conversas anteriores")
        #expect(titles.contains("Nova conversa"))
    }

    @Test func everyWordMustMatch() {
        #expect(PaletteSearch.rank(sample(), query: "pasta finder").map(\.id) == ["folder"])
        #expect(PaletteSearch.rank(sample(), query: "pasta zzz").isEmpty)
    }

    @Test func orbsGetTheirNumberShortcut() {
        let orbs = sample().filter { $0.section == .orbs }
        #expect(orbs.map(\.shortcut) == ["⌘1", "⌘2"])
    }

    @Test func noOrbOpenMeansNoOrbActions() {
        let entries = PaletteBuilder.entries(orbs: [], current: nil, routines: [], skills: [], archive: [])
        #expect(!entries.contains { $0.id == "new-conversation" })
        #expect(entries.contains { $0.id == "new-bot" })
    }

    // MARK: Menu bar panel

    @Test func batchPreviewListsThreeActionsAndCountsTheRest() {
        let items = (1...5).map { ApprovalItem(toolName: "run_command", title: "Rodando \($0)", command: "cmd \($0)") }
        let request = ApprovalRequest(toolName: "batch", title: "5 ações", command: "", reason: "", items: items)
        let preview = ApprovalPreview.of(request)
        #expect(preview.rows.count == 3)
        #expect(preview.rows.first == .init(title: "Rodando 1", command: "cmd 1"))
        #expect(preview.extra == 2)
        #expect(preview.extraLabel == "+ 2 ações")
    }

    @Test func singlePreviewIsTheCommand() {
        let request = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade", reason: "")
        let preview = ApprovalPreview.of(request)
        #expect(preview.rows == [.init(title: nil, command: "brew upgrade")])
        #expect(preview.extraLabel == nil)
        #expect(ApprovalPreview(rows: [], extra: 1).extraLabel == "+ 1 ação")
    }

    @Test func returnInThePanelFollowsTheComposersRule() {
        func action(working: Bool, steer: Bool = false, ready: Bool = true, text: Bool = true) -> QuickAskSend {
            QuickAskSend.action(isWorking: working, canSteer: steer, isReady: ready, hasText: text)
        }
        #expect(action(working: false) == .send)
        #expect(action(working: true, steer: true) == .queue) // it was silent before
        #expect(action(working: true, steer: false) == .blocked) // a routine holds the Orb
        #expect(action(working: false, text: false) == .nothing && action(working: true, steer: true, text: false) == .nothing)
        #expect(action(working: false, ready: false) == .nothing)
        #expect(QuickAskSend.blockedNote(name: "Atlas") == "Atlas está rodando uma rotina. Envie quando terminar.")
        #expect(QuickAskSend.hint(isWorking: false, canSteer: false).hasPrefix("↩ envia"))
        #expect(QuickAskSend.hint(isWorking: true, canSteer: true).hasPrefix("↩ direciona"))
        #expect(QuickAskSend.hint(isWorking: true, canSteer: true, midTurn: false).hasPrefix("↩ fila")) // Claude Code
        #expect(QuickAskSend.hint(isWorking: true, canSteer: false).hasPrefix("Rotina rodando"))
    }

    @Test func theMenuBarPanelDoesNotSwitchTheScreenUnderAnOpenSheet() {
        let current = SidebarItem.bot(UUID()), target = UUID()
        #expect(QuickAskSend.selection(after: target, current: current, hasOpenSheet: true) == current)
        #expect(QuickAskSend.selection(after: target, current: current, hasOpenSheet: false) == .bot(target))
    }

    @Test func anOrbWhoseOwnModelIsNotConnectedKeepsWhatWasTyped() {
        #expect(QuickAskSend.action(isWorking: false, canSteer: false, isReady: true, hasText: true, orbHasModel: false) == .noModel)
        #expect(QuickAskSend.action(isWorking: false, canSteer: false, isReady: true, hasText: true, orbHasModel: true) == .send)
        #expect(QuickAskSend.noModelNote(name: "Atlas").contains("Atlas"))
    }

    @MainActor @Test func hasUsableModelFollowsTheOrbsOwnModelNotTheDefault() {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbQuickAsk-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .ollama)] // local: usable
        model.defaultModel = "ollama/llama"
        let id = model.bots[0].id
        #expect(model.hasUsableModel(id))
        model.bots[0].model = "openai/gpt" // its own model belongs to a provider that is not there
        #expect(!model.hasUsableModel(id))
    }

    @Test func replyIsTheNewestBotMessageAfterTheLastUserOne() {
        let user = TranscriptItem(.user(text: "oi", attachments: []))
        let old = TranscriptItem(.bot(text: "antiga", isStreaming: false))
        let tool = TranscriptItem(.notice("aviso"))
        let fresh = TranscriptItem(.bot(text: "nova", isStreaming: true))
        #expect(QuickAskReplyText.latestReply(in: [old, user, tool]) == nil)
        #expect(QuickAskReplyText.latestReply(in: [old, user, tool, fresh])?.text == "nova")
        #expect(QuickAskReplyText.latestReply(in: [old, user, tool, fresh])?.isStreaming == true)
    }

    @Test func excerptKeepsTheLastLines() {
        let text = (1...10).map { "linha \($0)" }.joined(separator: "\n\n")
        let cut = QuickAskReplyText.excerpt(text, maxLines: 3)
        #expect(cut.text == "linha 8\n\nlinha 9\n\nlinha 10")
        #expect(cut.isCut)
        let whole = QuickAskReplyText.excerpt("a\n\n\n\nb\n", maxLines: 6)
        #expect(whole.text == "a\n\nb")
        #expect(!whole.isCut)
    }

    @Test func excerptTurnsListMarkersIntoBullets() {
        let shown = QuickAskReplyText.excerpt("Pastas:\n- Biblioteca\n* Filmes\n  - Downloads")
        #expect(shown.text == "Pastas:\n• Biblioteca\n• Filmes\n• Downloads")
    }

    @Test func streamedExcerptReadsOnlyTheEndAndAgreesWithTheWholeText() {
        let closed = (1...500).map { "parágrafo \($0)\ncontinua \($0)" }
        let tail = "ainda escrevendo"
        let fast = QuickAskReplyText.excerpt(closed: closed, tail: tail, maxLines: 6)
        let slow = QuickAskReplyText.excerpt((closed + [tail]).joined(separator: "\n\n"), maxLines: 6)
        #expect(fast.text == slow.text)
        #expect(fast.isCut && slow.isCut)
        let short = QuickAskReplyText.excerpt(closed: ["um"], tail: "dois", maxLines: 6)
        #expect(short.text == "um\n\ndois")
        #expect(!short.isCut)
        #expect(QuickAskReplyText.excerpt(closed: [], tail: "", maxLines: 6).text.isEmpty)
    }

    // MARK: Delete dialog

    @Test func deleteSummaryNamesWhatGoesAndWhatStays() {
        let summary = DeleteOrbSummary(name: "Atlas", archivedCount: 12, routineCount: 2, folder: "~/Orbs/Atlas")
        #expect(summary.goes == "Some: a conversa atual, 12 conversas anteriores e 2 rotinas.")
        #expect(summary.stays == "Fica: a pasta ~/Orbs/Atlas e, se você quiser, a memória.")
    }

    @Test func deleteSummaryHandlesSingularsAndNothingElse() {
        #expect(DeleteOrbSummary(name: "A", archivedCount: 1, routineCount: 1, folder: nil).goes
                == "Some: a conversa atual, 1 conversa anterior e 1 rotina.")
        #expect(DeleteOrbSummary(name: "A", archivedCount: 0, routineCount: 0, folder: nil).goes == "Some: a conversa atual.")
        #expect(DeleteOrbSummary(name: "A", archivedCount: nil, routineCount: 0, folder: nil).goes
                == "Some: a conversa atual e as conversas anteriores.")
        #expect(DeleteOrbSummary(name: "A", archivedCount: 0, routineCount: 0, folder: nil).stays.hasPrefix("Fica: tudo o que está no seu Mac"))
    }

    @Test func keptMemoryFolderIsFoundByName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kept-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        for name in ["Atlas – 2026-10-01 09.00", "Atlas – 2026-10-07 18.30", "Luna – 2026-10-07 18.30"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        #expect(AppModel.newestKeptFolder(named: "Atlas", in: root)?.lastPathComponent == "Atlas – 2026-10-07 18.30")
        #expect(AppModel.newestKeptFolder(named: "Zeca", in: root) == nil)
    }
}

/// A command that opens an Orb's chat leaves a request the chat takes when it is on screen.
@Suite final class ChatRequestTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbRequests-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "Agenda", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    @Test @MainActor func requestForAnotherOrbOpensItAndWaitsForItsChat() {
        let model = model()
        let (first, second) = (model.botIDs[0], model.botIDs[1])
        model.selection = .bot(first)
        model.showConversations(of: second)
        #expect(model.selection == .bot(second))
        #expect(!model.takeChatRequest(.showConversations, of: first))
        #expect(!model.takeChatRequest(.focusComposer, of: second))
        #expect(model.takeChatRequest(.showConversations, of: second))
        #expect(!model.takeChatRequest(.showConversations, of: second)) // taken once
    }

    @Test @MainActor func commandsFromAWorkspacePageLandOnTheFirstOrb() {
        let model = model()
        model.selection = .routines
        model.focusComposer()
        #expect(model.selection == .bot(model.botIDs[0]))
        #expect(model.takeChatRequest(.focusComposer, of: model.botIDs[0]))
    }

    @Test @MainActor func lookEditorOpensThePanelOfThatOrb() {
        let model = model()
        model.showInspector = false
        model.showLookEditor(of: model.botIDs[1])
        #expect(model.showInspector)
        #expect(model.selection == .bot(model.botIDs[1]))
        #expect(model.takeChatRequest(.editLook, of: model.botIDs[1]))
    }

    @Test @MainActor func menuCommandsWaitWhileASheetIsOpen() {
        let model = model()
        #expect(!model.hasOpenSheet)
        model.showNewBot = true
        #expect(model.hasOpenSheet)
        model.showNewBot = false
        model.askToDelete(model.botIDs[0])
        #expect(model.hasOpenSheet)
    }

    @Test @MainActor func keptMemoryNoticeOnlyForAnOrbWithSomethingToKeep() {
        let model = model()
        let luna = model.botIDs[1]
        // Luna has not spoken and has no memory folder: nothing was kept, so nothing says it was.
        model.confirmDelete(luna, keepMemory: true)
        #expect(model.keptMemoryNotice == nil)
    }

    @Test @MainActor func theKeptMemoryNoticePointsAtTheExactFolderOnceItHasMoved() async throws {
        let model = model()
        let luna = model.botIDs[1]
        await model.memory.bank(for: luna).remember("Algo para guardar")

        model.confirmDelete(luna, keepMemory: true)
        // Until the move is done there is no folder to show, and the notice does not claim it was kept.
        let notice = try #require(model.keptMemoryNotice)
        #expect(!notice.isKept && notice.folder == nil && notice.message == "Guardando a memória de Luna…")

        await waitUntil("the memory to be kept") { model.keptMemoryNotice?.isKept == true }
        let kept = try #require(model.keptMemoryNotice)
        let folder = try #require(kept.folder)
        #expect(kept.message == "Memória de Luna guardada")
        #expect(folder.deletingLastPathComponent().lastPathComponent == "_guardadas" && folder.lastPathComponent.hasPrefix("Luna – "))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "fatos").path))
    }

    @Test @MainActor func aNoticeThatWasClosedIsNotBroughtBackByTheMove() async throws {
        let model = model()
        let luna = model.botIDs[1]
        await model.memory.bank(for: luna).remember("Algo para guardar")
        model.confirmDelete(luna, keepMemory: true)
        model.dismissKeptMemoryNotice()
        try await Task.sleep(for: .milliseconds(300)) // long enough for the move to finish
        #expect(model.keptMemoryNotice == nil)
    }
}
