import Foundation
import SwiftUI
import Testing
@testable import Orb

/// Small interface fixes found in review: sheets and the menu, the skill delete copy, the catalog tabs, the footer,
/// the permissions chip and the palette.
@Suite final class InterfacePolishTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbInterface-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "Agenda", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    // MARK: Edit sheets and the menu

    @Test @MainActor func anEditSheetOpenMakesTheMenuCommandsWait() {
        let model = model()
        #expect(model.openSheets == 0)
        #expect(!model.hasOpenSheet)
        let token = UUID()
        model.sheetDidOpen(token)
        #expect(model.openSheets == 1)
        #expect(model.hasOpenSheet)
        model.sheetDidClose(token)
        #expect(model.openSheets == 0)
        #expect(!model.hasOpenSheet)
    }

    @Test @MainActor func aSheetThatReportsTwiceStillCountsOnceAndLeavesWhenItCloses() {
        let model = model()
        let (a, b) = (UUID(), UUID())
        model.sheetDidOpen(a)
        model.sheetDidOpen(a)
        #expect(model.openSheets == 1)
        model.sheetDidOpen(b)
        #expect(model.openSheets == 2)
        model.sheetDidClose(a)
        #expect(model.hasOpenSheet) // b is still open
        model.sheetDidClose(b)
        model.sheetDidClose(b) // closing what is gone changes nothing
        #expect(!model.hasOpenSheet)
    }

    // MARK: Skills

    @Test func deletingASkillPromisesOnlyWhatIsTrue() {
        let own = Skill(slug: "resumir", name: "Resumir", summary: "", instructions: "x")
        let catalog = Skill(slug: "pdf", name: "PDF", summary: "", instructions: "x", source: "anthropics/skills/pdf")
        let builtIn = Skill(slug: "revisar", name: "Revisar", summary: "", instructions: "x", source: Skill.builtInSource)
        let ownText = SkillDeleteCopy.message(for: own)
        #expect(ownText.contains("Não dá para desfazer"))
        #expect(!ownText.contains("catálogo"))
        #expect(SkillDeleteCopy.message(for: catalog).contains("instalar de novo pelo catálogo"))
        let builtInText = SkillDeleteCopy.message(for: builtIn)
        #expect(!builtInText.contains("catálogo"))
        #expect(builtInText.contains("vem com o app"))
        let learned = SkillDeleteCopy.message(for: Skill(slug: "publicar-site", name: "Publicar site", summary: "", instructions: "x",
                                                         source: Skill.learnedSource))
        #expect(learned.contains("Não dá para desfazer") && learned.contains("aprendeu") && !learned.contains("catálogo"))
    }

    @Test func aLearnedSkillSaysWhichOrbLearnedIt() {
        #expect(SkillBadge.learned(by: "Atlas") == "Aprendida por Atlas")
        #expect(SkillBadge.learned(by: nil) == "Aprendida")
    }

    @Test func savingTheEditorKeepsWhatMovedWhileItWasOpen() {
        var opened = Skill(slug: "resumir", name: "Resumir", summary: "", instructions: "x")
        opened.uses = 3
        var edited = opened // the editor's copy, taken when the sheet opened
        edited.name = "Resumir texto"
        edited.slug = "resumir-texto"
        edited.summary = "Resume"
        edited.instructions = "y"
        edited.orbIDs = [UUID()]
        var now = opened // a routine expanded the skill and the person switched it off meanwhile
        now.uses = 4
        now.isEnabled = false
        let saved = now.applyingEdits(from: edited)
        #expect(saved.uses == 4 && !saved.isEnabled)
        #expect(saved.id == opened.id && saved.name == "Resumir texto" && saved.slug == "resumir-texto" && saved.summary == "Resume")
        #expect(saved.instructions == "y" && saved.orbIDs == edited.orbIDs)
    }

    // MARK: Catalog search

    @Test func aSearchAnswerBelongsOnlyToTheTermStillInTheField() {
        #expect(!RegistryQuery.isCurrent("pdf", query: "pdfs"))
        #expect(RegistryQuery.isCurrent("pdf", query: " pdf"))
        // A cancelled request can finish after the next one starts, even for the same text: it cannot clear loading.
        #expect(!RegistryQuery.isCurrent("pdf", query: " pdf", cancelled: true))
        #expect(!RegistryQuery.isCurrent("pdf", query: "pdfs", cancelled: true))
    }

    // MARK: Permissions chip

    @Test @MainActor func manageInThePermissionsChipOpensTheGeneralTabOfThatOrb() {
        let model = model()
        let luna = model.botIDs[1]
        model.showInspector = false
        model.selection = .bot(model.botIDs[0])
        model.showPermissions(of: luna)
        #expect(model.showInspector)
        #expect(model.selection == .bot(luna))
        #expect(model.takeTabRequest(of: model.botIDs[0]) == nil) // not for another Orb
        #expect(model.takeTabRequest(of: luna) == .general)
        #expect(model.takeTabRequest(of: luna) == nil) // taken once
    }

    // MARK: Words

    @Test func theFirstRunCardUsesNoArticleBeforeTheName() {
        #expect(FirstRunStyle.chat(botName: "Lia").title == "Vamos preparar Lia")
        #expect(FirstRunStyle.chat(botName: "").title == "Vamos preparar seu Orb")
        #expect(!FirstRunStyle.chat(botName: "Lia").subtitle.contains("dele"))
    }

    // MARK: Plurals a screen reader says

    @Test func theUnreadCountAgreesInNumber() {
        #expect(SidebarText.unread(1) == "1 não lida")
        #expect(SidebarText.unread(3) == "3 não lidas")
    }
}

// MARK: - TestHygieneTests

/// Structural guardrails against build and test-speed regressions (TESTE-7).
@Suite struct TestHygieneTests {
    private static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    @Test func noTinyStandaloneTestFilesExist() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var tiny: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count
            if lines < 45 { tiny.append("\(file.lastPathComponent) (\(lines)L)") }
        }
        #expect(tiny.isEmpty, "Agrupe testes pequenos (< 45 linhas) em uma suíte temática existente: \(tiny.joined(separator: ", "))")
    }

    @Test func noNewThreadSleepIsIntroducedInTests() throws {
        let allowed: Set<String> = [
            "ScreenTakeoverTests.swift", "StoreIOTests.swift", "WebToolTests.swift",
            "MCPAuthTests.swift", "AccessibilityEngineTests.swift",
        ]
        let files = try FileManager.default.contentsOfDirectory(at: Self.testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        var offenders: [String] = []
        let needle = "Thread" + ".sleep("
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            if content.contains(needle) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Evite Thread.sleep em testes (use waitUntil, TestGate ou Task.sleep curto): \(offenders.joined(separator: ", "))")
    }
}

// MARK: - SavedKeyFieldTests

@Suite struct SavedKeyFieldTests {
    @Test func typedKeyOffersSaveEvenWhileReplacing() {
        #expect(SavedKeyField.Trailing.of(key: "sk-1", isReplacing: false, hasKeyPage: true) == .save)
        #expect(SavedKeyField.Trailing.of(key: "sk-1", isReplacing: true, hasKeyPage: false) == .save)
    }

    @Test func emptyFieldNeverOffersSave() {
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: true, hasKeyPage: true) == .cancel)
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: false, hasKeyPage: true) == .getKey)
        #expect(SavedKeyField.Trailing.of(key: "", isReplacing: false, hasKeyPage: false) == .none)
    }
}

// MARK: - InlineNameEditTests

// What ends an inline name edit (`InlineNameField`): the chat's title and the category's name share it.

@Suite("InlineNameEdit")
struct InlineNameEditTests {
    /// The category's rule: trimmed, blank is no name.
    private let categoryRule: (String) -> String? = SidebarOrder.name

    @Test func enterKeepsAChangedName() {
        #expect(InlineNameEdit.committed(typed: "  Vendas  ", initial: "Atlas", keeping: true, normalize: categoryRule) == "Vendas")
    }

    @Test func escapeSavesNothing() {
        #expect(InlineNameEdit.committed(typed: "Vendas", initial: "Atlas", keeping: false, normalize: categoryRule) == nil)
    }

    @Test func aBlankNameSavesNothing() {
        #expect(InlineNameEdit.committed(typed: " \n ", initial: "Atlas", keeping: true, normalize: categoryRule) == nil)
        #expect(InlineNameEdit.committed(typed: "", initial: "", keeping: true, normalize: categoryRule) == nil)
    }

    @Test func anUnchangedNameIsNotSavedAgain() {
        #expect(InlineNameEdit.committed(typed: "Atlas ", initial: "Atlas", keeping: true, normalize: categoryRule) == nil)
        #expect(InlineNameEdit.committed(typed: "Atlas", initial: "Atlas", keeping: true, normalize: { $0 }) == nil)
    }

    @Test func theChatsDefaultKeepsWhatWasTyped() {
        // The chat's field hands the text over as typed; `OrbChats.rename` trims it and refuses a blank one.
        #expect(InlineNameEdit.committed(typed: "  Plano  ", initial: "Conversa", keeping: true, normalize: { $0 }) == "  Plano  ")
    }

    @Test func theLimitCutsTheTextOnlyWhenThereIsOne() {
        #expect(InlineNameEdit.limited("abcdef", to: 3) == "abc")
        #expect(InlineNameEdit.limited("abc", to: 3) == "abc")
        #expect(InlineNameEdit.limited("abcdef", to: nil) == "abcdef")
    }
}

// MARK: - InterfaceTextTests

/// Small rules of how the interface writes times and cut texts.
@Suite struct InterfaceTextTests {
    @Test func aDateWithinAMinuteIsNow() {
        let now = Date()
        #expect(RelativeTime.text(now, now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(2), now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(-40), now: now) == "agora")
        #expect(RelativeTime.text(now.addingTimeInterval(-3_600), now: now) != "agora")
    }

    @Test func aRelativeTimeHasNoAbbreviationPeriod() {
        let now = Date()
        #expect(RelativeTime.text(now.addingTimeInterval(-39 * 60), now: now) == "há 39 min")
        #expect(RelativeTime.text(now.addingTimeInterval(-2 * 3_600 - 120), now: now) == "há 2 h")
        #expect(RelativeTime.text(now.addingTimeInterval(-26 * 3_600), now: now) == "há 1 dia")
        #expect(RelativeTime.text(now.addingTimeInterval(-9 * 86_400), now: now) == "há 1 semana")
        #expect(RelativeTime.text(now.addingTimeInterval(-70 * 86_400), now: now) == "há 2 meses")
        #expect(RelativeTime.text(now.addingTimeInterval(400 * 86_400), now: now) == "em 1 ano")
        #expect(RelativeTime.text(now.addingTimeInterval(3 * 3_600), now: now) == "em 3 h")
    }

    @Test func aCutEndsInOneEllipsisAfterTheWord() {
        let text = "Ask a few preference questions, write a tight persona. Then verify against the live profile."
        let cut = MemoryText.clip(text, 57)
        #expect(cut == "Ask a few preference questions, write a tight persona…")
        // A short text is not touched, its period included.
        #expect(MemoryText.clip("Resume um texto.", 40) == "Resume um texto.")
        // An opening bracket at the start stays; a closing one at the cut too.
        #expect(MemoryText.clip("(nota) um texto bem comprido (com parênteses) e mais palavras", 47) == "(nota) um texto bem comprido (com parênteses)…")
    }

    @Test func anOlderCutLosesItsDanglingPeriod() {
        #expect(MemoryText.tidyEllipsis("against the live profile.…") == "against the live profile…")
        #expect(MemoryText.tidyEllipsis("or running the standing…") == "or running the standing…")
        #expect(MemoryText.tidyEllipsis("Sem corte.") == "Sem corte.")
    }
}

// MARK: - ModelUnavailableNoteTests

/// The Orb's model picker when the chosen model's provider cannot answer: the model keeps its name, and a line says why.
@Suite final class ModelUnavailableNoteTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbModelNote-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    @MainActor private func model(connected: Set<ProviderKind>) -> AppModel {
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        var account = ProviderAccount(kind: .claudeCode)
        account.models = [ProviderModel(id: "sonnet", name: "Sonnet 5.5", format: .claudeCode)]
        model.providers = [account]
        model.publishConnections(connected)
        return model
    }

    @Test @MainActor func aModelOfAProviderNotConnectedYetIsStillSaidByItsName() {
        let model = model(connected: [])
        #expect(model.modelName("claudeCode/sonnet") == "Sonnet 5.5")
        #expect(model.modelName("claudeCode/outro") == "outro")
        #expect(model.modelName("ollama/llama") == "llama")
    }

    @Test @MainActor func theNoteSaysWhyTheModelCannotAnswer() {
        let off = model(connected: [])
        #expect(off.modelUnavailableNote("claudeCode/sonnet")
                == "Claude Code não está conectado. Conecte em Ajustes → Modelos ou escolha outro modelo.")
        #expect(off.modelUnavailableNote("ollama/llama")
                == "Ollama não está mais em Ajustes. Escolha outro modelo ou adicione o provedor de novo.")

        off.beginConnectionCheck()
        #expect(off.modelUnavailableNote("claudeCode/sonnet") == "Conferindo a conexão com Claude Code…")

        let on = model(connected: [.claudeCode])
        #expect(on.modelUnavailableNote("claudeCode/sonnet") == nil)
        #expect(on.modelUnavailableNote("") == nil)
        on.providers[0].isEnabled = false
        #expect(on.modelUnavailableNote("claudeCode/sonnet") == "Claude Code está desligado em Ajustes → Modelos.")
    }
}

// MARK: - NavigationLogicTests

/// The pure parts of the sidebar footer, Início's day groups and the menu bar panel's approvals.
@Suite struct NavigationLogicTests {
    @Test func profileNameShortensToFirstNameAndLastInitial() {
        #expect(ProfileNameText.short("Thiago Emanuel Velozo") == "Thiago V.")
        #expect(ProfileNameText.short("Ana Lima") == "Ana L.")
        #expect(ProfileNameText.short("Thiago") == "Thiago")
        #expect(ProfileNameText.short("  maria   souza ") == "maria S.")
        #expect(ProfileNameText.short("") == "")
    }

    @Test func inicioNewsGroupByDayInTheOrderTheyAppear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))!
        func news(daysAgo: Int, hour: Int = 10) -> InicioNews {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            let id = UUID()
            return InicioNews(entry: InicioEntry(id: id, sequence: 0, date: date,
                                                 origin: .chat(bot: UUID(), chat: UUID(), item: id), outcome: .completed, summary: ""))
        }
        let list = [news(daysAgo: 0, hour: 14), news(daysAgo: 0, hour: 9), news(daysAgo: 1), news(daysAgo: 3), news(daysAgo: 6), news(daysAgo: 7), news(daysAgo: 20)]
        let groups = InicioDays.group(list, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Hoje", "Ontem", "Esta semana", "Mais antigas"])
        #expect(groups.map(\.items.count) == [2, 1, 2, 2])
        #expect(groups[0].items.map(\.id) == [list[0].id, list[1].id]) // keeps the newest-first order inside a group
        #expect(InicioDays.group([], now: now, calendar: calendar).isEmpty)
        // Midnight is the boundary: 23:59 yesterday is "Ontem" even one minute before now crosses it.
        let lateNow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 1))!
        let lastNight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23, minute: 59))!
        #expect(InicioDays.title(of: lastNight, now: lateNow, calendar: calendar) == "Ontem")
    }

    @Test func inicioMoreLinkCountsWhatIsHidden() {
        #expect(InicioDays.moreLabel(hidden: 1) == "Ver mais 1 item")
        #expect(InicioDays.moreLabel(hidden: 9) == "Ver mais 9 itens")
    }

    @Test func quickAskGroupsApprovalsByOrbKeepingFirstAppearance() {
        let atlas = Bot(name: "Atlas", role: "", orb: OrbConfig()), luna = Bot(name: "Luna", role: "", orb: OrbConfig())
        func pending(_ bot: Bot) -> PendingApproval {
            PendingApproval(bot: bot, request: ApprovalRequest(toolName: "run_command", title: "x", command: "ls", reason: ""))
        }
        let a1 = pending(atlas), l1 = pending(luna), a2 = pending(atlas)
        let groups = QuickAskApprovalGroups.byOrb([a1, l1, a2])
        #expect(groups.map { $0.map(\.bot.name) } == [["Atlas", "Atlas"], ["Luna"]])
        #expect(groups[0].map(\.id) == [a1.id, a2.id])
        #expect(QuickAskApprovalGroups.byOrb([]).isEmpty)
    }
}
