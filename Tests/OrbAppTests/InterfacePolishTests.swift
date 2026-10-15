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

    // MARK: Catalog tabs

    @Test func onlyTheSelectedTabIsAnnouncedAsSelected() {
        #expect(CatalogTab.traits(isSelected: true) == .isSelected)
        #expect(CatalogTab.traits(isSelected: false) == [])
    }

    // MARK: Sheets

    @Test @MainActor func aDestructiveSheetCanKeepReturnFromItsPrimaryButton() {
        #expect(SheetFooter.primaryShortcut(isDefault: true) == .defaultAction)
        #expect(SheetFooter.primaryShortcut(isDefault: false) == nil)
    }

    @Test func theButtonsOfARowShareOneHeightPerControlSize() {
        // Primary, secondary and ghost pills read the same measures, so none is taller than its neighbour; the small
        // control size (the buttons inside cards) is the compact one.
        #expect(PillMetrics.of(.regular).height == ControlHeight.regular)
        #expect(PillMetrics.of(.large).height == ControlHeight.regular)
        #expect(PillMetrics.of(.small).height == ControlHeight.compact)
        #expect(PillMetrics.of(.mini).height == ControlHeight.compact)
        #expect(ControlHeight.compact < ControlHeight.regular && ControlHeight.regular < ControlHeight.hero)
    }

    @Test func theSpacingScaleStepsUpAndTheSheetUsesItsEdge() {
        let scale = [Spacing.hairline, Spacing.xs, Spacing.s, Spacing.m, Spacing.l, Spacing.xl, Spacing.xxl]
        #expect(scale == scale.sorted())
        #expect(Spacing.sheetEdge == Spacing.xl)
        // A ghost button at the start of a row hangs exactly its own side padding outside it.
        #expect(Spacing.ghostInset == 12)
    }

    // MARK: Permissions chip

    @Test @MainActor func manageInThePermissionsChipOpensTheFolderTabOfThatOrb() {
        let model = model()
        let luna = model.botIDs[1]
        model.showInspector = false
        model.selection = .bot(model.botIDs[0])
        model.showPermissions(of: luna)
        #expect(model.showInspector)
        #expect(model.selection == .bot(luna))
        #expect(model.takeTabRequest(of: model.botIDs[0]) == nil) // not for another Orb
        #expect(model.takeTabRequest(of: luna) == .folder)
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
