import Foundation
import SwiftUI
import Testing
@testable import Orb

/// The transitions between pages, panels and sheets (docs/MOVIMENTO.md §2.13): which page a selection is, which curve
/// each kind of change uses, with and without Reduce Motion, and the panel opening the same way from every path. The
/// motion itself is SwiftUI's; what is decided here is tested without a screen.
@Suite("Transitions", .serialized) final class TransitionsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbTransitions-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    @MainActor private func makeModel() -> AppModel {
        AppModel(store: Store(directory: root.appending(path: "dados")), runsBackgroundWork: false)
    }

    // MARK: The page of the detail column

    @Test func everyOrbIsTheSamePageSoGoingFromOneToAnotherDoesNotCrossFadeThePage() {
        let ids = [UUID(), UUID()]
        let first = DetailPage.page(for: .bot(ids[0]), botIDs: ids)
        let second = DetailPage.page(for: .bot(ids[1]), botIDs: ids)
        #expect(first == .orb)
        #expect(first == second)
    }

    @Test func routinesConnectorsSkillsAndTheWelcomeAreEachTheirOwnPage() {
        let ids = [UUID()]
        let pages = [DetailPage.page(for: .bot(ids[0]), botIDs: ids),
                     DetailPage.page(for: .routines, botIDs: ids),
                     DetailPage.page(for: .connectors, botIDs: ids),
                     DetailPage.page(for: .skills, botIDs: ids),
                     DetailPage.page(for: nil, botIDs: [])]
        #expect(pages == [.orb, .routines, .connectors, .skills, .welcome])
        #expect(Set(pages).count == 5)
    }

    @Test func theMomentASelectionPointsAtNothingKeepsTheOrbsPage() {
        let ids = [UUID()]
        // A deleted Orb before the root view picks another, and nothing chosen while there are Orbs: no fade in between.
        #expect(DetailPage.page(for: .bot(UUID()), botIDs: ids) == .orb)
        #expect(DetailPage.page(for: nil, botIDs: ids) == .orb)
        // The last Orb deleted: the welcome screen.
        #expect(DetailPage.page(for: .bot(UUID()), botIDs: []) == .welcome)
        #expect(DetailPage.page(for: .routines, botIDs: []) == .routines)
    }

    // MARK: The Orb's panel

    @Test func thePanelSlidesInTheContentCurveAndNotAtAllUnderReduceMotion() {
        #expect(Motion.panel(reduceMotion: false) == Motion.content)
        #expect(Motion.panel(reduceMotion: true) == nil)
    }

    @Test @MainActor func everyPathThatOpensThePanelSetsTheSameState() {
        let model = makeModel()
        model.setInspector(false)
        #expect(!model.showInspector)
        model.toggleInspector()
        #expect(model.showInspector)
        model.toggleInspector()
        #expect(!model.showInspector)
        let id = model.botIDs[0]
        model.showMemory(of: id)
        #expect(model.showInspector)
        model.setInspector(false)
        model.showPermissions(of: id)
        #expect(model.showInspector)
        model.setInspector(false)
        model.showLookEditor(of: id)
        #expect(model.showInspector)
    }

    // MARK: The curves

    @Test func crossFadesAreEighteenHundredthsAndTheContentCurveIsAQuarterSecond() {
        #expect(Motion.crossFade == .easeInOut(duration: 0.18))
        #expect(Motion.content == .smooth(duration: 0.25))
        #expect(Motion.adapted(Motion.crossFade, reduceMotion: true) == Motion.fade)
        #expect(Motion.adapted(Motion.crossFade, reduceMotion: false) == Motion.crossFade)
    }

    // MARK: Sheets

    @Test func theEditorsPartsComeInInTurnStageThenOptionsThenFooter() {
        let delays = (0..<3).map { EntranceStyle.staggered($0, start: SheetEntrance.start).delay }
        #expect(delays[0] == SheetEntrance.start)
        #expect(abs(delays[1] - (SheetEntrance.start + Motion.stagger)) < 1e-9)
        #expect(abs(delays[2] - (SheetEntrance.start + 2 * Motion.stagger)) < 1e-9)
        // Under Reduce Motion all three fade in together, in place.
        for index in 0..<3 {
            let resolved = EntranceStyle.staggered(index, start: SheetEntrance.start).resolved(reduceMotion: true)
            #expect(resolved.distance == 0)
            #expect(resolved.animation == Motion.fade)
        }
    }

    // MARK: Explorar

    @Test func theExplorePageHasOnePhaseAndTypingIsNotOne() {
        typealias Phase = ExplorePhase
        #expect(Phase.of(isSearching: false, isLoading: false, error: nil, isEmpty: true) == .hint)
        // Not searching wins over everything left from before.
        #expect(Phase.of(isSearching: false, isLoading: true, error: "x", isEmpty: false) == .hint)
        #expect(Phase.of(isSearching: true, isLoading: true, error: nil, isEmpty: true) == .loading)
        #expect(Phase.of(isSearching: true, isLoading: true, error: "x", isEmpty: true) == .loading)
        #expect(Phase.of(isSearching: true, isLoading: false, error: "x", isEmpty: true) == .failed)
        #expect(Phase.of(isSearching: true, isLoading: false, error: nil, isEmpty: true) == .empty)
        #expect(Phase.of(isSearching: true, isLoading: false, error: nil, isEmpty: false) == .results)
    }

    @Test func aSearchRetriedBeforeTheTextChangedDoesNotAnswerForTheNewText() {
        #expect(RegistryQuery.isCurrent("banco", query: " banco "))
        #expect(!RegistryQuery.isCurrent("banco", query: "calendário"))
        #expect(!RegistryQuery.isCurrent("banco", query: ""))
    }

    // MARK: Small values

    @Test func aSpinnerWaitsOneHundredFiftyMilliseconds() {
        #expect(Motion.spinnerDelay == .milliseconds(150))
    }

    @Test func aCardsRunStateIsOneOfThreeAndOnlyChangesWithTheRun() {
        let idle = RoutineRunState(isRunning: false, isQueued: false)
        #expect(idle != RoutineRunState(isRunning: true, isQueued: false))
        #expect(idle != RoutineRunState(isRunning: false, isQueued: true))
        #expect(idle == RoutineRunState(isRunning: false, isQueued: false))
    }

    @Test func theFadeUnderReduceMotionIsTheShortOne() {
        #expect(Motion.fade == .easeOut(duration: 0.15))
        #expect(Motion.adapted(Motion.enter, reduceMotion: true) == Motion.fade)
        #expect(Motion.adapted(Motion.enter, reduceMotion: false) == Motion.enter)
    }
}
