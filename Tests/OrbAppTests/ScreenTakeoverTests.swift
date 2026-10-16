import CoreGraphics
import Foundation
import Testing
@testable import Orb

// Taking the screen over, with the system behind it replaced by a small world: an app in front, a cursor, windows and
// the events posted. Nothing real is raised, moved or typed.

// MARK: - The fake world

/// A Mac with a front app and a cursor. Telling an app element `AXFrontmost` brings it to the front, unless `ignoresFrontmost`.
final class FakeTakeoverWorld: TakeoverPlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var frontApp: TakeoverFront?
    private var cursor: CGPoint
    private var calls: [String] = []
    /// Windows by process, as `AXFocusedWindow` reports them.
    var windows: [Int32: FakeElement] = [:]
    /// An app that never comes forward when told to.
    var ignoresFrontmost: Set<Int32> = []
    /// An app that does not come forward when activated either (the takeover's second way back).
    var ignoresActivation: Set<Int32> = []
    let poster = FakeTakeoverPoster()

    init(front: TakeoverFront?, cursor: CGPoint) {
        self.frontApp = front
        self.cursor = cursor
        poster.world = self
    }

    var front: TakeoverFront? { lock.withLock { frontApp } }
    var cursorNow: CGPoint {
        get { lock.withLock { cursor } }
        set { lock.withLock { cursor = newValue } }
    }
    /// What happened to the system, in order ("front:2", "warp", "associate").
    var log: [String] { lock.withLock { calls } }

    func setFront(_ pid: Int32, name: String) {
        lock.withLock {
            guard !ignoresFrontmost.contains(pid) else { return }
            frontApp = TakeoverFront(pid: pid, name: name, bundleID: nil)
            calls.append("front:\(pid)")
        }
    }

    func root(of app: AccessibilityApp) -> any AccessibilityElement { FakeApplicationElement(world: self, app: app) }
    func frontmost() -> TakeoverFront? { front }
    func cursorLocation() -> CGPoint {
        lock.withLock {
            if let (point, left) = pending {
                if left <= 1 { cursor = point; pending = nil } else { pending = (point, left - 1) }
            }
            return cursor
        }
    }
    /// A move that reaches the cursor only after it has been looked at `reads` times.
    func moveLater(to point: CGPoint, afterReads reads: Int) {
        lock.withLock {
            // The same move posted again does not start over.
            if let current = pending, current.0 == point { return }
            pending = (point, reads)
        }
    }
    private var pending: (CGPoint, Int)?
    func warpCursor(to point: CGPoint) { lock.withLock { cursor = point; calls.append("warp") } }
    func associateCursor() { lock.withLock { calls.append("associate") } }
    func makePoster() -> any TakeoverEventPoster { poster }
    func activate(_ pid: Int32) {
        lock.withLock {
            calls.append("activate:\(pid)")
            guard !ignoresActivation.contains(pid) else { return }
            frontApp = TakeoverFront(pid: pid, name: pid == 10 ? "Safari" : "App \(pid)", bundleID: nil)
        }
    }
}

/// The application element: `AXFrontmost` is writable and brings the app forward.
final class FakeApplicationElement: AccessibilityElement, @unchecked Sendable {
    let world: FakeTakeoverWorld
    let app: AccessibilityApp

    init(world: FakeTakeoverWorld, app: AccessibilityApp) {
        self.world = world
        self.app = app
    }

    var pid: Int32? { app.pid }
    func attribute(_ name: String) -> AXAttributeValue? {
        guard name == "AXFocusedWindow", let window = world.windows[app.pid] else { return nil }
        return .element(window)
    }
    func actionNames() -> [String] { [] }
    func isSettable(_ name: String) -> Bool { name == "AXFrontmost" }
    func perform(_ action: String) throws { throw AXFailure.notSupported }
    func setValue(_ value: AXAttributeValue, for name: String) throws {
        guard name == "AXFrontmost", value.bool == true else { throw AXFailure.notSupported }
        world.setFront(app.pid, name: app.name)
    }
}

/// The events a takeover posts. Like the real thing, a move or drag puts the cursor there.
final class FakeTakeoverPoster: TakeoverEventPoster, @unchecked Sendable {
    enum Event: Equatable {
        case mouse(TakeoverMouseEvent, CGPoint, MouseButton, clickState: Int)
        case key(UInt16, down: Bool, KeyStroke.Modifiers)
        case text([UInt16])
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    weak var world: FakeTakeoverWorld?
    /// Called after each event is recorded (to simulate the person grabbing the mouse at some moment).
    var afterEvent: (@Sendable (Int, FakeTakeoverWorld) -> Void)?
    /// When set, a move does not put the cursor anywhere.
    var cursorIgnoresEvents = false
    /// How long each event blocks, like a slow system.
    var delay: Duration = .zero
    /// A move reaches the cursor only after it has been read this many times, like a window server under load.
    var cursorArrivesAfterReads = 0

    var events: [Event] { lock.withLock { recorded } }

    private func record(_ event: Event) {
        let (seconds, atto) = delay.components
        if seconds > 0 || atto > 0 { Thread.sleep(forTimeInterval: Double(seconds) + Double(atto) / 1e18) }
        let count = lock.withLock { () -> Int in recorded.append(event); return recorded.count }
        afterEvent?(count, world!)
    }

    func mouse(_ event: TakeoverMouseEvent, at point: CGPoint, button: MouseButton, clickState: Int) {
        if (event == .moved || event == .dragged), !cursorIgnoresEvents {
            if cursorArrivesAfterReads > 0 {
                world?.moveLater(to: point, afterReads: cursorArrivesAfterReads)
            } else {
                world?.cursorNow = point
            }
        }
        record(.mouse(event, point, button, clickState: clickState))
    }
    func key(virtualKey: UInt16, down: Bool, modifiers: KeyStroke.Modifiers) { record(.key(virtualKey, down: down, modifiers)) }
    func text(_ units: [UInt16]) { record(.text(units)) }
    func virtualKey(for character: Character) -> UInt16? { ["s": 1, "a": 0][character] }
}

final class FakeIndicator: TakeoverIndicator, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    func began() async { lock.withLock { log.append("began") } }
    func ended() async { lock.withLock { log.append("ended") } }
}

// MARK: - Rig

private let safari = TakeoverFront(pid: 10, name: "Safari", bundleID: "com.apple.Safari")
private let notes = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 20)

private struct TakeoverRig {
    let world: FakeTakeoverWorld
    let owner: LiveScreenOwner
    let indicator = FakeIndicator()
    let events = FakeAccessibilityEvents()
    let lock: TakeoverLock
    let notesWindow = fake("AXWindow", title: "Nota", actions: ["AXRaise"])
    let safariWindow = fake("AXWindow", title: "Página")

    init(front: TakeoverFront? = safari, cursor: CGPoint = CGPoint(x: 500, y: 300), lock: TakeoverLock = TakeoverLock(),
         activationTimeout: Duration = .milliseconds(120), stepLimit: Duration = .seconds(30)) {
        world = FakeTakeoverWorld(front: front, cursor: cursor)
        notesWindow.settable = ["AXMain"]
        safariWindow.settable = ["AXMain"]
        world.windows = [10: safariWindow, 20: notesWindow]
        self.lock = lock
        var owner = LiveScreenOwner(platform: world, events: events, indicator: indicator, lock: lock)
        owner.activationTimeout = activationTimeout
        owner.restoreTimeout = .milliseconds(120)
        owner.stepLimit = stepLimit
        owner.pause = .zero
        self.owner = owner
    }

    func takeOver<Value: Sendable>(limit: Duration = .seconds(120), window: Bool = true,
                                   _ body: @escaping @Sendable (any TakeoverHand) async throws -> Value) async throws -> TakeoverReport<Value> {
        try await owner.takeOver(notes, window: window ? notesWindow : nil, limit: limit, body)
    }
}

// MARK: - Taking and giving back

struct ScreenTakeoverTests {
    @Test func theAppComesForwardTheBodyUsesTheRealInputAndEverythingGoesBack() async throws {
        let rig = TakeoverRig()
        let seen = TakeoverFrontSeen()
        let report = try await rig.takeOver { hand in
            seen.set(rig.world.front?.pid)
            try await hand.click(at: CGPoint(x: 100, y: 120), button: .left, count: 1)
            try await hand.type("oi")
            try await hand.key(try KeyStroke.parse("cmd+s"))
            return "feito"
        }
        #expect(seen.value == 20, "Notas was in front while the body ran")
        #expect(report.value == "feito")
        #expect(report.restoredApp == "Safari" && report.cursorRestored)
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.cursorNow == CGPoint(x: 500, y: 300))
        // Brought forward, then given back; the cursor warped back and the mouse re-associated.
        #expect(rig.world.log == ["front:20", "front:10", "warp", "associate"])
        #expect(rig.notesWindow.performed == ["AXRaise"] && rig.notesWindow.assignedValue("AXMain")?.bool == true)
        #expect(rig.safariWindow.assignedValue("AXMain")?.bool == true, "the window that was focused is made main again")
        #expect(rig.indicator.calls == ["began", "ended"])
        #expect(rig.events.requests.map(\.pid) == [20] && rig.events.requests.first?.notifications == [.applicationActivated])

        let events = rig.world.poster.events
        #expect(events == [
            .mouse(.moved, CGPoint(x: 100, y: 120), .left, clickState: 0),
            .mouse(.down, CGPoint(x: 100, y: 120), .left, clickState: 1),
            .mouse(.up, CGPoint(x: 100, y: 120), .left, clickState: 1),
            .text(Array("oi".utf16)),
            .key(1, down: true, .command), .key(1, down: false, .command),
        ])
    }

    @Test func aDoubleClickCountsEachPress() async throws {
        let rig = TakeoverRig()
        _ = try await rig.takeOver { hand in try await hand.click(at: CGPoint(x: 5, y: 6), button: .right, count: 2) }
        let states = rig.world.poster.events.compactMap { event -> Int? in
            if case .mouse(.down, _, .right, let state) = event { state } else { nil }
        }
        #expect(states == [1, 2])
    }

    @Test func aDragMovesInFifteenInterpolatedStepsAndReleasesAtTheEnd() async throws {
        let rig = TakeoverRig()
        _ = try await rig.takeOver { hand in try await hand.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 150, y: 300)) }
        let events = rig.world.poster.events
        let dragged = events.compactMap { event -> CGPoint? in
            if case .mouse(.dragged, let point, _, _) = event { point } else { nil }
        }
        #expect(dragged.count == 15)
        #expect(dragged.first == CGPoint(x: 10, y: 20) && dragged.last == CGPoint(x: 150, y: 300))
        #expect(events.first == .mouse(.moved, CGPoint(x: 0, y: 0), .left, clickState: 0))
        #expect(events[1] == .mouse(.down, CGPoint(x: 0, y: 0), .left, clickState: 1))
        #expect(events.last == .mouse(.up, CGPoint(x: 150, y: 300), .left, clickState: 1))
    }

    @Test func textGoesInChunksOfTwentyUnitsAndNeverSplitsACharacter() async throws {
        let rig = TakeoverRig()
        let text = String(repeating: "a", count: 19) + "😀" + String(repeating: "b", count: 25)
        _ = try await rig.takeOver { hand in try await hand.type(text) }
        let chunks = rig.world.poster.events.compactMap { event -> [UInt16]? in if case .text(let units) = event { units } else { nil } }
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.map(\.count) == [19, 20, 7], "the emoji (two units) starts the next chunk instead of being cut")
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    }

    @Test func aKeyTheLayoutLacksIsRefused() async throws {
        let rig = TakeoverRig()
        await #expect(throws: TakeoverFailure.unknownKey("ç")) {
            _ = try await rig.takeOver { hand in try await hand.key(KeyStroke(.character("ç"))) }
        }
        #expect(rig.world.front?.pid == 10)
    }

    @Test func whenTheAppIsAlreadyInFrontNothingIsWaitedForAndNoAppIsReportedBack() async throws {
        let rig = TakeoverRig(front: TakeoverFront(pid: 20, name: "Notas", bundleID: nil))
        let report = try await rig.takeOver { _ in 1 }
        #expect(report.restoredApp == nil && report.cursorRestored)
        #expect(rig.world.front?.pid == 20)
    }

    @Test func withNothingInFrontNothingIsRestored() async throws {
        let rig = TakeoverRig(front: nil)
        let report = try await rig.takeOver { _ in 1 }
        #expect(report.restoredApp == nil && report.cursorRestored)
    }

    // MARK: Restoration

    @Test func anErrorInTheBodyStillGivesTheScreenBack() async throws {
        struct Boom: Error {}
        let rig = TakeoverRig()
        await #expect(throws: Boom.self) {
            _ = try await rig.takeOver { hand in
                try await hand.click(at: CGPoint(x: 1, y: 1), button: .left, count: 1)
                throw Boom()
            }
        }
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.cursorNow == CGPoint(x: 500, y: 300))
        #expect(rig.indicator.calls == ["began", "ended"])
    }

    @Test func cancellingTheTaskStillGivesTheScreenBackBeforeItReturns() async throws {
        let rig = TakeoverRig()
        let started = TestGate()
        let task = Task {
            try await rig.takeOver { hand in
                try await hand.click(at: CGPoint(x: 40, y: 40), button: .left, count: 1)
                await started.open()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await started.wait()
        #expect(rig.world.front?.pid == 20 && rig.world.cursorNow == CGPoint(x: 40, y: 40))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // By the time the call has returned, the person has their screen back.
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.cursorNow == CGPoint(x: 500, y: 300))
        #expect(rig.world.log.suffix(2) == ["warp", "associate"])
        #expect(rig.indicator.calls == ["began", "ended"])
    }

    @Test func aTaskCancelledBeforeItStartsTakesNothing() async throws {
        let rig = TakeoverRig()
        let gate = TestGate()
        let task = Task {
            await gate.wait()
            return try await rig.takeOver { _ in 1 }
        }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(rig.world.log.isEmpty && rig.indicator.calls.isEmpty)
        // And the lock was not left held.
        let report = try await rig.takeOver { _ in 2 }
        #expect(report.value == 2)
    }

    @Test func anAppThatDoesNotComeForwardFailsWithNothingDone() async throws {
        let rig = TakeoverRig()
        rig.world.ignoresFrontmost = [20]
        await #expect(throws: TakeoverFailure.couldNotBringToFront("Notas")) {
            _ = try await rig.takeOver { _ in Issue.record("the body must not run"); return 1 }
        }
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.poster.events.isEmpty)
        #expect(rig.indicator.calls == ["began", "ended"])
        #expect(rig.world.cursorNow == CGPoint(x: 500, y: 300))
    }

    @Test func anAppThatWillNotComeBackIsNotReportedAsRestored() async throws {
        let rig = TakeoverRig()
        rig.world.ignoresFrontmost = [10]
        rig.world.ignoresActivation = [10]
        let report = try await rig.takeOver { _ in 1 }
        #expect(report.restoredApp == nil, "it could not be put back, so the report does not say it was")
        #expect(report.restoreFailed, "and the report says the person's app is not back")
        #expect(rig.world.log.contains("activate:10"), "the second way was tried")
        #expect(rig.world.front?.pid == 20)
    }

    @Test func whenAXFrontmostDoesNotBringTheAppBackActivatingItDoes() async throws {
        let rig = TakeoverRig()
        rig.world.ignoresFrontmost = [10]
        let report = try await rig.takeOver { _ in 1 }
        #expect(report.restoredApp == "Safari" && !report.restoreFailed)
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.log.filter { $0.hasPrefix("activate") } == ["activate:10"])
    }

    @Test func aFailedRestoreIsToldEvenWhenTheBodyFailed() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "Deu errado." } }
        let rig = TakeoverRig()
        rig.world.ignoresFrontmost = [10]
        rig.world.ignoresActivation = [10]
        do {
            _ = try await rig.takeOver { _ in throw Boom() }
            Issue.record("the body's error must come through")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Deu errado."))
            #expect(error.localizedDescription.contains("não consegui devolver Safari"))
        }
    }

    @Test func aRestoreThatWorkedTheFirstWayNeverActivates() async throws {
        let rig = TakeoverRig()
        let report = try await rig.takeOver { _ in 1 }
        #expect(!report.restoreFailed && !rig.world.log.contains { $0.hasPrefix("activate") })
    }

    // MARK: The lock

    @Test func onlyOneTakeoverRunsAtATimeAndTheOtherIsRefusedAtOnce() async throws {
        let lock = TakeoverLock()
        let first = TakeoverRig(lock: lock)
        let second = TakeoverRig(lock: lock)
        let inside = TestGate(), finish = TestGate()
        let running = Task {
            try await first.takeOver { _ in
                await inside.open()
                await finish.wait()
                return 1
            }
        }
        await inside.wait()
        await #expect(throws: TakeoverFailure.busy) { _ = try await second.takeOver { _ in 2 } }
        #expect(second.world.log.isEmpty && second.indicator.calls.isEmpty, "the refused one touched nothing")
        await finish.open()
        _ = try await running.value
        // The lock is free again.
        #expect(try await second.takeOver { _ in 3 }.value == 3)
    }

    @Test func theLockIsReleasedAfterAnErrorToo() async throws {
        struct Boom: Error {}
        let lock = TakeoverLock()
        let rig = TakeoverRig(lock: lock)
        _ = try? await rig.takeOver { _ in throw Boom() }
        try lock.acquire()
        lock.release()
    }

    // MARK: The person's mouse

    @Test func movingTheMouseStopsTheTakeoverAndLeavesTheCursorWhereThePersonPutIt() async throws {
        let rig = TakeoverRig()
        // The person grabs the mouse right after the first move.
        rig.world.poster.afterEvent = { count, world in if count == 1 { world.cursorNow = CGPoint(x: 900, y: 900) } }
        await #expect(throws: TakeoverFailure.userMovedMouse) {
            _ = try await rig.takeOver { hand in
                try await hand.click(at: CGPoint(x: 100, y: 100), button: .left, count: 1)
                return 1
            }
        }
        #expect(rig.world.poster.events.count == 1, "no press followed the move")
        #expect(rig.world.front?.pid == 10, "the app in front is still given back")
        #expect(rig.world.cursorNow == CGPoint(x: 900, y: 900), "the cursor is not dragged away from the person")
        #expect(rig.world.log.contains("associate") && !rig.world.log.contains("warp"))
    }

    @Test func aDragStopsMidwayWhenTheMouseIsGrabbed() async throws {
        let rig = TakeoverRig()
        rig.world.poster.afterEvent = { count, world in if count == 8 { world.cursorNow = CGPoint(x: -50, y: -50) } }
        await #expect(throws: TakeoverFailure.userMovedMouse) {
            _ = try await rig.takeOver { hand in try await hand.drag(from: .zero, to: CGPoint(x: 300, y: 300)) }
        }
        let events = rig.world.poster.events
        #expect(events.count == 9, "8 events, then the release")
        if case .mouse(.up, _, .left, _)? = events.last {} else { Issue.record("the button must be released when the drag stops") }
        #expect(events.filter { if case .mouse(.dragged, _, _, _) = $0 { true } else { false } }.count == 6)
    }

    @Test func ifAnotherAppTakesTheFrontNothingMoreIsSentAndTheButtonIsReleased() async throws {
        let rig = TakeoverRig()
        // Right after the button goes down, something else comes to the front.
        rig.world.poster.afterEvent = { count, world in if count == 4 { world.setFront(30, name: "Outro") } }
        await #expect(throws: TakeoverFailure.lostFront("Notas")) {
            _ = try await rig.takeOver { hand in try await hand.drag(from: .zero, to: CGPoint(x: 300, y: 300)) }
        }
        let events = rig.world.poster.events
        if case .mouse(.up, _, .left, _)? = events.last {} else { Issue.record("the button must be released when the drag stops") }
        #expect(events.count < 17, "the drag did not go on")
        #expect(rig.world.front?.pid == 10, "the person's app is put back all the same")
    }

    @Test func aCursorThatNeverArrivesStopsTheTakeoverWithoutBlamingThePerson() async throws {
        let rig = TakeoverRig()
        rig.world.poster.cursorIgnoresEvents = true
        // It stayed where the hand left it: a slow system, not the person (who would have put it somewhere else).
        await #expect(throws: TakeoverFailure.cursorStuck) {
            _ = try await rig.takeOver { hand in try await hand.click(at: CGPoint(x: 100, y: 100), button: .left, count: 1) }
        }
        #expect(rig.world.front?.pid == 10)
        let moves = rig.world.poster.events.filter { if case .mouse(.moved, _, _, _) = $0 { true } else { false } }
        #expect(moves.count == 2, "the move is posted once more before giving up")
        #expect(!rig.world.poster.events.contains { if case .mouse(.down, _, _, _) = $0 { true } else { false } }, "nothing was pressed")
        #expect(rig.world.log.contains("warp"), "the cursor is put back, since the person did not take it")
    }

    @Test func aCursorThatArrivesLateUnderLoadIsWaitedFor() async throws {
        // A window server that applies the move late (a loaded Mac) is not the person moving the mouse: here only after the
        // cursor was looked at 40 times, more than 60 ms of looking ever gave.
        let rig = TakeoverRig()
        rig.world.poster.cursorArrivesAfterReads = 40
        let report = try await rig.takeOver { hand in
            try await hand.click(at: CGPoint(x: 100, y: 100), button: .left, count: 1)
            return "feito"
        }
        #expect(report.value == "feito" && report.cursorRestored)
        #expect(rig.world.poster.events.contains(.mouse(.down, CGPoint(x: 100, y: 100), .left, clickState: 1)))
    }

    @Test func aSmallNudgeWithinThreePointsIsTolerated() async throws {
        let rig = TakeoverRig()
        rig.world.poster.afterEvent = { count, world in if count == 1 { world.cursorNow = CGPoint(x: 101.5, y: 101.5) } }
        _ = try await rig.takeOver { hand in try await hand.click(at: CGPoint(x: 100, y: 100), button: .left, count: 1) }
        #expect(rig.world.poster.events.count == 3)
    }

    // MARK: Time

    @Test func theWholeTakeoverIsCutAtItsLimit() async throws {
        let rig = TakeoverRig()
        await #expect(throws: TakeoverFailure.timeLimit) {
            _ = try await rig.takeOver(limit: .milliseconds(150)) { _ in try await Task.sleep(for: .seconds(30)) }
        }
        #expect(rig.world.front?.pid == 10)
        #expect(rig.world.cursorNow == CGPoint(x: 500, y: 300))
    }

    @Test func aBodyThatKeepsUsingTheHandIsStoppedByTheLimitToo() async throws {
        let rig = TakeoverRig()
        await #expect(throws: TakeoverFailure.timeLimit) {
            _ = try await rig.takeOver(limit: .milliseconds(150)) { hand in
                while true {
                    try await hand.key(KeyStroke(.named(.tab)))
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        #expect(rig.world.front?.pid == 10)
    }

    @Test func oneStepCannotTakeMoreThanItsOwnLimit() async throws {
        let rig = TakeoverRig(stepLimit: .milliseconds(80))
        rig.world.poster.delay = .milliseconds(150)
        await #expect(throws: TakeoverFailure.stepTimeout) {
            _ = try await rig.takeOver { hand in try await hand.type(String(repeating: "x", count: 4_000)) }
        }
        #expect(rig.world.front?.pid == 10)
    }

    @Test func aSlowLastChunkIsNotCalledAFailureOnceTheTextIsWhole() async throws {
        // The only chunk takes longer than the step limit, but it went out whole: failing now would make the model type it again.
        let rig = TakeoverRig(stepLimit: .milliseconds(80))
        rig.world.poster.delay = .milliseconds(150)
        _ = try await rig.takeOver { hand in try await hand.type("xxxxx") }
        #expect(rig.world.poster.events == [.text(Array("xxxxx".utf16))])
        #expect(rig.world.front?.pid == 10)
    }

    @Test func aLongTextIsNotCutHalfwayByTheLimitOfOneStep() async throws {
        // Each chunk is well within the step limit; only the text as a whole takes longer than it.
        let rig = TakeoverRig(stepLimit: .milliseconds(400))
        rig.world.poster.delay = .milliseconds(20)
        let text = String(repeating: "x", count: 400)
        _ = try await rig.takeOver { hand in try await hand.type(text) }
        let typed = rig.world.poster.events.compactMap { event -> Int? in if case .text(let units) = event { units.count } else { nil } }
        #expect(typed.reduce(0, +) == 400 && typed.count == 20, "\(typed.count) chunks")
        #expect(rig.world.front?.pid == 10)
    }

    @Test func theMessagesTellTheModelWhatToDo() {
        #expect(TakeoverFailure.busy.localizedDescription.contains("Outro Orb"))
        #expect(TakeoverFailure.userMovedMouse.localizedDescription.contains("mouse"))
        #expect(TakeoverFailure.couldNotBringToFront("Notas").localizedDescription.contains("Notas"))
        #expect(TakeoverFailure.timeLimit.localizedDescription.contains("limite"))
        #expect(TakeoverFailure.stepTimeout.localizedDescription.contains("2 s"))
        #expect(TakeoverFailure.lostFront("Notas").localizedDescription.contains("Notas"))
    }

    @Test func theLiveSystemHandsOutTheLiveOwner() {
        // Nothing is called; only that the live system's screen is the real one, not the "unavailable" stand-in.
        #expect(LiveAccessibilitySystem().screen is LiveScreenOwner)
    }

    @Test func theLiveSystemsFrontAppAndCursorAreReadableWithoutTouchingAnything() {
        let platform = LiveTakeoverPlatform()
        _ = platform.frontmost()
        _ = platform.cursorLocation()
        #expect(TakeoverBroadcast.beganName != TakeoverBroadcast.endedName)
    }
}

/// A value a `@Sendable` body can record.
final class TakeoverFrontSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? { lock.withLock { stored } }
    func set(_ value: Int32?) { lock.withLock { stored = value } }
}
