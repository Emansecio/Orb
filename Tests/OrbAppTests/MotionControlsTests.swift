import AppKit
import SwiftUI
import Testing
@testable import Orb

/// The pure parts of the controls' motion (docs/MOVIMENTO.md §2.1, §2.5, §2.7): which curve a fill, the composer's
/// focus or the sidebar's selection gets, what changes under Reduce Motion, and what the round button is in each state.
struct MotionControlsTests {
    // MARK: Hover (§2.7)

    @Test func aFillComesInFastAndGoesOutSlowly() {
        #expect(Motion.hover(true) == Motion.hoverIn)
        #expect(Motion.hover(false) == Motion.hoverOut)
        #expect(Motion.fill(visible: true) == Motion.hoverIn)
        #expect(Motion.fill(visible: false) == Motion.hoverOut)
    }

    @Test func aPressedFillAnswersWithThePressCurveAndReleasesSlowly() {
        #expect(Motion.fill(visible: true, pressed: true) == Motion.press)
        // A press that ends with the pointer away lets go like a hover.
        #expect(Motion.fill(visible: false, pressed: false) == Motion.hoverOut)
    }

    // MARK: Composer focus (§2.5)

    @Test func theComposerBorderAnswersTheFocusLikeAHover() {
        #expect(Motion.focus(true, reduceMotion: false) == Motion.hoverIn)
        #expect(Motion.focus(false, reduceMotion: false) == Motion.hoverOut)
    }

    @Test func underReduceMotionTheFocusChangesColorsAtOnce() {
        #expect(Motion.focus(true, reduceMotion: true) == nil)
        #expect(Motion.focus(false, reduceMotion: true) == nil)
    }

    @Test func theFocusedCardHasTheStrongBorderAndASlightlyLighterFill() {
        #expect(ComposerSurface.stroke(isFocused: false, isDropTargeted: false) == Palette.line)
        #expect(ComposerSurface.stroke(isFocused: true, isDropTargeted: false) == Palette.lineStrong)
        // A file being dragged over wins over the focus.
        #expect(ComposerSurface.stroke(isFocused: true, isDropTargeted: true) == Palette.accentText)
        #expect(ComposerSurface.stroke(isFocused: false, isDropTargeted: true) == Palette.accentText)
        #expect(ComposerSurface.fill(isFocused: false) == Palette.surface)
        #expect(ComposerSurface.fill(isFocused: true) == Palette.surfaceFocused)
    }

    @Test func theCardCastsABlackShadowBelowAndAnAccentGlowWhileAFileIsDraggedOver() {
        let rest = ComposerSurface.shadow(isDropTargeted: false)
        #expect(rest.color == Color.black.opacity(0.35) && rest.y == 8)
        let drop = ComposerSurface.shadow(isDropTargeted: true)
        #expect(drop.color == Palette.accent.opacity(0.35) && drop.y == 0)
    }

    @Test func theFocusedFillIsAboutTwoPercentLighter() throws {
        let rest = try #require(NSColor(Palette.surface).usingColorSpace(.sRGB))
        let focused = try #require(NSColor(Palette.surfaceFocused).usingColorSpace(.sRGB))
        for (a, b) in [(rest.redComponent, focused.redComponent), (rest.greenComponent, focused.greenComponent),
                       (rest.blueComponent, focused.blueComponent)] {
            #expect(b > a)
            // `surface` with 2 % white over it, give or take the rounding to a hex byte.
            #expect(abs(b - (a + (1 - a) * 0.02)) < 1.0 / 255)
        }
    }

    // MARK: Sidebar selection (§2.1)

    @Test func theSelectionSlidesWithTheContentCurveAndJumpsUnderReduceMotion() {
        #expect(Motion.selection(reduceMotion: false) == Motion.content)
        #expect(Motion.selection(reduceMotion: true) == nil)
    }

    @Test func theSelectionDoesNotAnimateTheListWhenAnOrbComesOrGoesWithIt() {
        // ⌘N and delete change the list and the selection in the same update: no slide, so the rows below stay put.
        #expect(Motion.selection(reduceMotion: false, listChanged: true) == nil)
        #expect(Motion.selection(reduceMotion: false, listChanged: false) == Motion.content)
    }

    @Test func theSelectedBackgroundIsOneNamedElement() {
        #expect(SidebarSelection.id == "selecao")
    }

    // MARK: Send / Stop (§2.5)

    @Test func theRoundButtonIsSendWhenTheOrbIsFree() {
        #expect(ComposerAction.current(isWorking: false, canSend: false) == .send)
        #expect(ComposerAction.current(isWorking: false, canSend: true) == .send)
    }

    @Test func whileTheOrbWorksTheButtonStopsOrQueues() {
        #expect(ComposerAction.current(isWorking: true, canSend: false) == .stop)
        #expect(ComposerAction.current(isWorking: true, canSend: true) == .queue)
    }

    /// MultiOrb (WP2): an Orb idle on a chain of requests to other Orbs can still be stopped from the composer and with ⌘.
    @Test @MainActor func anOrbWaitingOnAChainCanBeStopped() throws {
        #expect(ComposerAction.current(isWorking: false, canSend: false, waitsOnChain: true) == .stop)
        #expect(ComposerAction.current(isWorking: false, canSend: true, waitsOnChain: true) == .send)
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbStop-\(UUID().uuidString)")
        defer { removeTestFolder(folder) }
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false, secretVault: MemoryVault())
        let bot = model.createBot(name: "Atlas", role: "", orb: OrbConfig(), model: "", mode: .ask, identity: "",
                                  interview: false, folder: .home)
        model.selection = .bot(bot.id)
        #expect(!model.canStopCurrent)
        model.live(bot.id).setChainWork(WorkPhrase.waiting(for: ["Lia"]))
        #expect(model.canStopCurrent)
    }

    @Test func theSymbolSwapsOnlyBetweenSendingAndStopping() {
        #expect(ComposerAction.send.symbol == "arrow.up")
        #expect(ComposerAction.queue.symbol == "arrow.up")
        #expect(ComposerAction.stop.symbol == "stop.fill")
    }

    @Test func eachStateKeepsItsLabelAndItsHelp() {
        #expect(ComposerAction.send.title == "Enviar")
        #expect(ComposerAction.send.help == "Enviar (↩)")
        #expect(ComposerAction.queue.title == "Colocar na fila")
        #expect(ComposerAction.queue.help == "Colocar na fila (↩)")
        #expect(ComposerAction.stop.title == "Parar")
        #expect(ComposerAction.stop.help == "\(CommandName.stop) (\(AppShortcut.stop.label))")
        #expect(ComposerAction.stop.help.contains("⌘."))
    }

    @Test func stopKeepsItsOwnButtonOnlyWhileAMessageIsQueued() {
        #expect(ComposerAction.queue.showsSecondaryStop)
        #expect(!ComposerAction.send.showsSecondaryStop)
        #expect(!ComposerAction.stop.showsSecondaryStop)
    }

    @Test func aPressShrinksTheButtonToNinetyTwoPercent() {
        #expect(ComposerAction.pressedScale == 0.92)
        let pressed = ComposerAction.pressVisual(pressed: true, reduceMotion: false)
        #expect(pressed.scale == 0.92 && pressed.opacity == 1)
        let released = ComposerAction.pressVisual(pressed: false, reduceMotion: false)
        #expect(released.scale == 1 && released.opacity == 1)
    }

    @Test func underReduceMotionAPressOnlyDimsTheButton() {
        let pressed = ComposerAction.pressVisual(pressed: true, reduceMotion: true)
        #expect(pressed.scale == 1 && pressed.opacity == 0.8)
        let released = ComposerAction.pressVisual(pressed: false, reduceMotion: true)
        #expect(released.scale == 1 && released.opacity == 1)
    }

    @Test func theButtonFadesWhenItBecomesAvailableAndSwitchesAtOnceUnderReduceMotion() {
        #expect(Motion.availability(reduceMotion: false) == Motion.content)
        #expect(Motion.availability(reduceMotion: true) == nil)
    }
}
