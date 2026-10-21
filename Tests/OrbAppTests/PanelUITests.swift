import Foundation
import Testing
@testable import Orb

/// The Orb's panel: tabs, copy, memory grouping and search, forgetting with a way back, the new-Orb sheet's height.
@Suite final class PanelUITests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPanel-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func defaults() -> UserDefaults {
        let suite = "OrbPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func item(_ path: String, _ kind: MemoryKind, _ title: String, _ body: String = "", daysAgo: Double = 0) -> MemorySnapshot.Item {
        MemorySnapshot.Item(path: path, kind: kind, title: title, body: body.isEmpty ? title : body,
                            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400), compacted: false)
    }

    // MARK: Tabs

    @Test func tabsAreTheSectionsInOrder() {
        #expect(InspectorTab.allCases.map(\.title) == ["Geral", "Memória", "Pasta e acessos", "Rotinas", "Tela"])
    }

    @Test func theBarShowsEachTabOnOneShortLine() {
        #expect(InspectorTab.allCases.map(\.shortTitle) == ["Geral", "Memória", "Pasta", "Rotinas", "Tela"])
    }

    @Test func aRowLeavesOutTheListMarkTheTextWasWrittenWith() {
        #expect(MemoryRow.displayed("- Preço: R$ 50") == "Preço: R$ 50")
        #expect(MemoryRow.displayed("1. Cupom só com aprovação") == "Cupom só com aprovação")
        #expect(MemoryRow.displayed("12) Segunda regra") == "Segunda regra")
        #expect(MemoryRow.displayed("2026. Um ano") == "2026. Um ano")
        #expect(MemoryRow.displayed("-3 graus") == "-3 graus")
        #expect(MemoryRow.displayed("Sem marca") == "Sem marca")
    }

    @Test func eachOrbRemembersItsOwnTab() {
        let defaults = defaults()
        let a = UUID(), b = UUID()
        #expect(InspectorTabMemory.tab(for: a, defaults: defaults) == .general)
        InspectorTabMemory.remember(.memory, for: a, defaults: defaults)
        InspectorTabMemory.remember(.routines, for: b, defaults: defaults)
        #expect(InspectorTabMemory.tab(for: a, defaults: defaults) == .memory)
        #expect(InspectorTabMemory.tab(for: b, defaults: defaults) == .routines)
        InspectorTabMemory.remember(.general, for: a, defaults: defaults)
        #expect(InspectorTabMemory.tab(for: a, defaults: defaults) == .general)
        #expect(InspectorTabMemory.tab(for: b, defaults: defaults) == .routines)
    }

    @Test func anUnknownStoredTabFallsBackToGeneral() {
        let defaults = defaults()
        let id = UUID()
        defaults.set([id.uuidString: "tab-de-uma-versao-futura"], forKey: InspectorTabMemory.key)
        #expect(InspectorTabMemory.tab(for: id, defaults: defaults) == .general)
    }

    // MARK: Copy

    @Test func capabilitiesUseTheSharedVocabulary() {
        #expect(Capability.allCases.map(\.label) ==
                ["Terminal e arquivos", "Navegar na web", "Controlar apps do Mac", "Conectores"])
        for capability in Capability.allCases { #expect(!Tip.capability(capability).isEmpty) }
    }

    @Test func connectorsLineSaysHowManyAreOn() {
        #expect(CapabilityCopy.connectorsLine(enabled: 0, total: 0, anyInstalled: false) == "Nenhum conector instalado")
        // Connectors exist, but all are kept for other Orbs: not "none installed".
        #expect(CapabilityCopy.connectorsLine(enabled: 0, total: 0, anyInstalled: true) == "Nenhum conector para este Orb")
        #expect(CapabilityCopy.connectorsLine(enabled: 0, total: 2, anyInstalled: true) == "Nenhum ativo (2 instalados)")
        #expect(CapabilityCopy.connectorsLine(enabled: 1, total: 3, anyInstalled: true) == "1 conector ativo")
        #expect(CapabilityCopy.connectorsLine(enabled: 2, total: 3, anyInstalled: true) == "2 conectores ativos")
    }

    @MainActor @Test func theLookIsOneLine() {
        let text = AppearanceSummary.text(for: OrbConfig.random())
        #expect(text.components(separatedBy: " · ").count == 3)
    }

    // MARK: Memory groups and search

    @Test func memoryIsGroupedByKindKeepingTheSnapshotsNewestFirstOrder() {
        // The snapshot comes newest first from the index: grouping keeps that order instead of sorting again.
        let items = [item("preferencias/p.md", .preferencia, "Respostas curtas"),
                     item("sessoes/s.md", .sessao, "Conversa", daysAgo: 1),
                     item("fatos/b.md", .fato, "Gato Pixel", daysAgo: 2),
                     item("fatos/a.md", .fato, "Mora em SP", daysAgo: 5)]
        let groups = MemoryGroups.make(items)
        #expect(groups.map(\.title) == ["Preferências", "Fatos", "Resumos de conversas"])
        #expect(groups[1].items.map(\.path) == ["fatos/b.md", "fatos/a.md"])
    }

    @Test func searchIgnoresCaseAndAccentsAndNeedsEveryWord() {
        let items = [item("fatos/a.md", .fato, "Consulta médica", "Consulta toda terça às 17h."),
                     item("fatos/b.md", .fato, "Gato", "O gato se chama Pixel."),
                     item("procedimentos/c.md", .procedimento, "Publicar", "Rode pnpm build e depois deploy.")]
        #expect(MemoryGroups.make(items, matching: "MEDICA").flatMap(\.items).map(\.path) == ["fatos/a.md"])
        #expect(MemoryGroups.make(items, matching: "terca 17h").flatMap(\.items).map(\.path) == ["fatos/a.md"])
        #expect(MemoryGroups.make(items, matching: "terca gato").isEmpty)
        #expect(MemoryGroups.make(items, matching: "  ").flatMap(\.items).count == 3)
        #expect(MemoryGroups.make(items, matching: "pnpm").first?.title == "Procedimentos")
    }

    @Test func memoryCanBeLimitedToOneKindAndSearchedThroughACache() {
        let items = [item("fatos/a.md", .fato, "Consulta médica", "Terça às 17h."),
                     item("preferencias/p.md", .preferencia, "Consulta curta", "Respostas curtas."),
                     item("fatos/b.md", .fato, "Gato", "Pixel.")]
        #expect(MemoryGroups.make(items, kind: .fato).flatMap(\.items).map(\.path) == ["fatos/a.md", "fatos/b.md"])
        #expect(MemoryGroups.make(items, matching: "consulta", kind: .preferencia).flatMap(\.items).map(\.path) == ["preferencias/p.md"])
        let cache = FoldedTextCache()
        #expect(MemoryGroups.make(items, matching: "MEDICA", cache: cache).flatMap(\.items).map(\.path) == ["fatos/a.md"])
        // An item that changed is folded again, not served stale.
        var changed = items
        changed[2].body = "Médico do Pixel."
        #expect(MemoryGroups.make(changed, matching: "medic", cache: cache).flatMap(\.items).map(\.path) == ["fatos/a.md", "fatos/b.md"])
    }

    @Test func memorySummaryCountsNotesAndConversations() {
        #expect(MemoryGroups.summary([]) == "Nada guardado ainda")
        let items = [item("fatos/a.md", .fato, "A"), item("fatos/b.md", .fato, "B"), item("sessoes/s.md", .sessao, "S")]
        #expect(MemoryGroups.summary(items) == "2 lembranças · 1 resumo de conversa")
        #expect(MemoryGroups.summary([items[0]]) == "1 lembrança")
    }

    // MARK: Forgetting with a way back

    @Test func onlyListedPagesCanBeForgotten() {
        #expect(ForgottenMemory.isForgettable("fatos/mora-em-sp.md"))
        #expect(ForgottenMemory.isForgettable("sessoes/s1.md"))
        #expect(!ForgottenMemory.isForgettable("nucleo/identidade.md"))
        #expect(!ForgottenMemory.isForgettable("fatos/../nucleo/identidade.md"))
        #expect(!ForgottenMemory.isForgettable("fatos/.oculto.md"))
        #expect(!ForgottenMemory.isForgettable("/etc/passwd"))
    }

    @Test func aForgottenPageComesBackWithItsArchive() async throws {
        let bank = MemoryBank(directory: root.appending(path: "orb"))
        guard case .saved(let path) = await bank.remember("Mora em São Paulo, no bairro Pinheiros.", kind: .fato) else {
            Issue.record("the fact was not saved")
            return
        }
        let directory = bank.directory
        // An archived full text sits next to a compacted page.
        let archive = directory.appending(path: "_arquivo/" + path)
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "texto completo".write(to: archive, atomically: true, encoding: .utf8)

        let forgotten = try #require(ForgottenMemory.capture(path, title: "Mora", in: directory))
        await bank.forget(path)
        #expect(await bank.snapshot().items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: archive.path))

        #expect(forgotten.restore(in: directory))
        await bank.reconcile()
        let items = await bank.snapshot().items
        #expect(items.map(\.path) == [path])
        #expect(items.first?.body.contains("Pinheiros") == true)
        #expect(try String(contentsOf: archive, encoding: .utf8) == "texto completo")
    }

    @Test func restoringNeverOverwritesAPageThatIsThereAgain() throws {
        let directory = root.appending(path: "orb2")
        let path = "fatos/a.md"
        try FileManager.default.createDirectory(at: directory.appending(path: "fatos"), withIntermediateDirectories: true)
        try "novo".write(to: directory.appending(path: path), atomically: true, encoding: .utf8)
        let forgotten = ForgottenMemory(path: path, title: "A", text: "velho")
        #expect(!forgotten.restore(in: directory))
        #expect(try String(contentsOf: directory.appending(path: path), encoding: .utf8) == "novo")
    }

    @Test func capturingAMissingOrProtectedPageGivesNothing() {
        #expect(ForgottenMemory.capture("fatos/nao-existe.md", title: "x", in: root) == nil)
        #expect(ForgottenMemory.capture("nucleo/identidade.md", title: "x", in: root) == nil)
    }

    @MainActor @Test func theUndoToastExpiresAndCanBeDismissed() async throws {
        let undo = MemoryUndo(lifetime: .milliseconds(40))
        let entry = MemoryUndo.Entry(botID: UUID(), forgotten: ForgottenMemory(path: "fatos/a.md", title: "A", text: "x"))
        undo.show(entry)
        #expect(undo.entry == entry)
        // Under a loaded test run the main actor can be late: wait for the expiry instead of guessing a delay.
        for _ in 0..<100 where undo.entry != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(undo.entry == nil)
        undo.show(entry)
        undo.dismiss()
        #expect(undo.entry == nil)
    }

    @MainActor @Test func theCountdownWaitsWhileTheToastIsHeld() async throws {
        let undo = MemoryUndo(lifetime: .milliseconds(60))
        let entry = MemoryUndo.Entry(botID: UUID(), forgotten: ForgottenMemory(path: "fatos/a.md", title: "A", text: "x"))
        undo.show(entry)
        undo.hold(.hover, true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(undo.entry == entry)
        undo.hold(.hover, false)
        for _ in 0..<100 where undo.entry != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(undo.entry == nil)
    }

    @MainActor @Test func aToastThatLeavesTheScreenHeldDoesNotStayForever() async throws {
        let undo = MemoryUndo(lifetime: .milliseconds(60))
        let entry = MemoryUndo.Entry(botID: UUID(), forgotten: ForgottenMemory(path: "fatos/a.md", title: "A", text: "x"))
        undo.show(entry)
        undo.hold(.hover, true)
        undo.hold(.focus, true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(undo.entry == entry) // held
        undo.releaseHolds() // the view went away without a "pointer left"
        for _ in 0..<100 where undo.entry != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(undo.entry == nil)
        undo.releaseHolds() // nothing held, nothing shown: no effect
        #expect(undo.entry == nil)
    }

    // MARK: New Orb sheet

    @Test func theNewOrbSheetFitsTheWindow() {
        #expect(NewBotSheetLayout.height(windowHeight: nil) == NewBotSheetLayout.preferredHeight)
        #expect(NewBotSheetLayout.height(windowHeight: 1_000) == NewBotSheetLayout.preferredHeight)
        // The smallest window the app allows (620 pt) still holds the sheet.
        #expect(NewBotSheetLayout.height(windowHeight: 620) == 560)
        #expect(NewBotSheetLayout.height(windowHeight: 300) == NewBotSheetLayout.minimumHeight)
        #expect(NewBotSheetLayout.height(preferred: 720, windowHeight: 2_000) == 720)
    }

    @Test func theRoleOfANewOrbIsTrimmedAndOnlySpacesMeanTheDefault() {
        #expect(NewBotSheet.finalRole("   ") == "Assistente pessoal")
        #expect(NewBotSheet.finalRole("") == "Assistente pessoal")
        #expect(NewBotSheet.finalRole(" \n ") == "Assistente pessoal")
        #expect(NewBotSheet.finalRole(" Cuida da agenda ") == "Cuida da agenda")
    }
}
