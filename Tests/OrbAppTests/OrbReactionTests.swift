import Foundation
import Testing
@testable import Orb

/// What the Orb shows when a turn ends or goes on: stopping is not a failure, a flash is never cleared by an older one,
/// parallel tools keep the tool pose, and the celebration is as big as the turn.
@Suite(.serialized) struct OrbReactionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbReaction-\(UUID().uuidString)")

    @MainActor private func model() -> AppModel {
        AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    /// A running turn that does nothing (the tests play its events and end it by hand).
    @MainActor private func runningTurn(_ model: AppModel) -> (id: UUID, turn: UUID, live: BotLive) {
        let id = model.bots[0].id
        let session = model.session(id)
        let turn = session.beginTurn()
        session.turnTask = Task { try? await Task.sleep(for: .seconds(30)) }
        model.setStatus("Pensando", of: id)
        return (id, turn, model.live(id))
    }

    // MARK: Stopping is not an error

    @Test @MainActor func stoppingTheReplyBlinksInsteadOfShowingTheError() {
        let model = model()
        let (id, _, live) = runningTurn(model)
        #expect(live.cue.count == 0)
        model.stop(id)
        #expect(!live.hasFailed && live.activity != .error)
        #expect(live.cue == OrbCueSignal(count: 1, kind: .blink))
        #expect(!live.isCelebrating)
        removeTestFolder(root)
    }

    @Test @MainActor func aFailedTurnStillShowsTheError() {
        let model = model()
        let (id, turn, live) = runningTurn(model)
        model.apply(.failed("sem rede"), to: id)
        model.finishTurn(id, turn: turn, succeeded: false)
        #expect(live.hasFailed && live.activity == .error)
        #expect(live.cue.count == 0)
        removeTestFolder(root)
    }

    @Test @MainActor func aTurnThatCouldNotStartShowsTheError() {
        let model = model()
        let (id, turn, live) = runningTurn(model)
        model.session(id).failSetup("Sem cliente", turn: turn)
        #expect(live.hasFailed && live.activity == .error)
        removeTestFolder(root)
    }

    @Test @MainActor func sendingClearsTheLastTurnsErrorAndJoy() {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        let session = model.session(id)
        session.flash(\.hasFailed, seconds: 30)
        session.flash(\.isCelebrating, seconds: 30)
        #expect(live.activity == .error)
        session.clearBeats()
        #expect(!live.hasFailed && !live.isCelebrating && live.activity == .idle)
        // A new turn starts clean too.
        session.flash(\.hasFailed, seconds: 30)
        _ = session.beginTurn()
        #expect(!live.hasFailed)
        removeTestFolder(root)
    }

    // MARK: Flashes do not erase each other

    @Test @MainActor func aNewFlashOfAFlagReplacesTheOldOneInsteadOfBeingClearedByIt() async {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        let session = model.session(id)
        session.flash(\.isListening, seconds: 0.1)
        try? await Task.sleep(for: .milliseconds(50))
        // Long enough that a busy main actor cannot let it end on its own before it is checked.
        session.flash(\.isListening, seconds: 1)
        // The first one's time is over by now; it must not have turned the flag off.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(live.isListening)
        await waitUntil("the second flash ends") { !live.isListening }
        #expect(session.flashes.isEmpty)
        removeTestFolder(root)
    }

    @Test @MainActor func flashesOfDifferentFlagsAreIndependent() async {
        let model = model()
        let id = model.bots[0].id
        let live = model.live(id)
        let session = model.session(id)
        session.flash(\.isListening, seconds: 0.05)
        // Long enough that a busy main actor cannot let it end on its own before it is checked.
        session.flash(\.hasFailed, seconds: 30)
        await waitUntil("listening ends") { !live.isListening }
        #expect(live.hasFailed)
        session.cancelFlash(\.hasFailed)
        #expect(!live.hasFailed && session.flashes.isEmpty)
        removeTestFolder(root)
    }

    // MARK: Tools in parallel

    @Test @MainActor func theToolStaysWhileAnyCallIsStillRunning() {
        let model = model()
        let (id, _, live) = runningTurn(model)
        var shell = ToolCall(kind: .shell, title: "Rodando", detail: "make")
        shell.startedAt = Date(timeIntervalSinceNow: -2)
        let file = ToolCall(kind: .file, title: "Lendo", detail: "a.txt")
        model.apply(.toolStarted(shell), to: id)
        model.apply(.toolStarted(file), to: id)
        #expect(live.activity == .reading) // the last one started

        model.apply(.toolFinished(id: file.id, state: .done, output: "ok"), to: id)
        #expect(live.runningTool == .shell && live.activity == .typing) // not back to "pensando" with a call still open

        model.apply(.toolFinished(id: shell.id, state: .done, output: "ok"), to: id)
        #expect(live.runningTool == nil && live.activity == .thinking)
        removeTestFolder(root)
    }

    // MARK: The celebration is as big as the turn

    @Test func theCelebrationGrowsWithTheTurn() {
        func level(_ seconds: Double, _ actions: Int, routine: Bool = false, selected: Bool = true) -> OrbCelebration {
            OrbCelebration.level(seconds: seconds, actions: actions, ranRoutine: routine, selected: selected)
        }
        #expect(level(3, 0) == .light && level(7.9, 1) == .light)
        #expect(level(8, 1) == .normal && level(3, 2) == .normal && level(44, 7) == .normal)
        #expect(level(46, 0) == .big && level(10, 8) == .big && level(3, 30) == .big)
        // A routine seen finishing is a big moment; one finishing elsewhere is always light.
        #expect(level(3, 0, routine: true) == .big && level(100, 20, routine: true, selected: false) == .light)
        // Joy gets bigger in duration and height with the level.
        let levels: [OrbCelebration] = [.light, .normal, .big]
        #expect(levels.map(\.seconds) == [1.6, 2.2, 3])
        #expect(levels.map(\.hop) == [0.05, 0.08, 0.1])
        #expect(OrbCelebration.normal.calm == 1.6 && OrbCelebration.big.calm == OrbActivity.happyCalm)
        #expect(OrbCelebration.light.hops == 1 && OrbCelebration.big.hops == nil)
    }

    @Test @MainActor func aTurnThatEndsWellCelebratesAccordingToItsSize() {
        let model = model()
        let id = model.bots[0].id
        let session = model.session(id)
        let live = model.live(id)
        model.selection = .bot(id)

        func end(seconds: Double, actions: Int, events: [TurnEvent] = []) -> OrbCelebration? {
            let turn = session.beginTurn()
            session.turnTask = Task {}
            model.setStatus("Pensando", of: id)
            live.backdateWork(to: Date(timeIntervalSinceNow: -seconds))
            session.actionsThisTurn = actions
            for event in events { model.apply(event, to: id) }
            // (`apply` of a tool counts it too; keep the count the test asked for.)
            session.actionsThisTurn = actions
            model.finishTurn(id, turn: turn)
            return live.isCelebrating ? live.celebration : nil
        }
        #expect(end(seconds: 2, actions: 0) == .light)
        #expect(end(seconds: 20, actions: 3) == .normal)
        #expect(end(seconds: 90, actions: 3) == .big)
        #expect(live.cue.count == 0)
        removeTestFolder(root)
    }

    @Test @MainActor func aTaskLeftHalfWayOrACutReplySighsInsteadOfCelebrating() {
        let model = model()
        let id = model.bots[0].id
        let session = model.session(id)
        let live = model.live(id)

        func end(_ event: TurnEvent) {
            let turn = session.beginTurn()
            session.turnTask = Task {}
            model.setStatus("Pensando", of: id)
            model.apply(.message(.user("tarefa")), to: id)
            model.apply(.message(ChatMessage(role: .assistant, content: "parei")), to: id)
            model.apply(event, to: id)
            model.finishTurn(id, turn: turn)
        }
        end(.taskPaused)
        #expect(!live.isCelebrating && live.activity == .idle)
        #expect(live.cue == OrbCueSignal(count: 1, kind: .sigh))
        end(.notice(AgentEngine.cutShortNotice))
        #expect(!live.isCelebrating && live.cue == OrbCueSignal(count: 2, kind: .sigh))
        // A turn that went well afterwards celebrates again (the "paused" mark went away with the new message).
        end(.status("ok"))
        #expect(live.isCelebrating)
        removeTestFolder(root)
    }

    @Test @MainActor func aRoutineThatFinishesInAnotherOrbCelebratesLightly() {
        let level = OrbCelebration.level(seconds: 120, actions: 20, ranRoutine: true, selected: false)
        #expect(level == .light)
    }

    // MARK: Numbers of the beats

    @Test @MainActor func theOrbWaitsLongerBeforeCallingItQuietAndStopsWatchingLater() {
        #expect(BotSession.speakingQuiet == .milliseconds(1200))
        #expect(BotLive.composingQuiet == .milliseconds(3000))
    }
}
