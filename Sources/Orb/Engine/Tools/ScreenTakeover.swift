import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import os

// Taking the screen over (docs/USO-DO-COMPUTADOR.md, "N2"): the only place that brings another app to the front, uses the
// real mouse and keyboard (`.cghidEventTap`) and gives everything back. Everything the system is asked for sits behind
// `TakeoverPlatform`, so lock contention, drift aborts, limits and restoration under cancellation are tested with fakes.

// MARK: - Failures

/// Why a takeover did not happen or stopped. Always shown to the model, so the text says what to do.
enum TakeoverFailure: Error, Equatable, LocalizedError {
    /// Another takeover holds the lock (another Orb).
    case busy
    /// The app did not come to the front within the wait.
    case couldNotBringToFront(String)
    /// The real cursor left the place the takeover put it: the person moved the mouse, so it stops.
    case userMovedMouse
    /// The cursor did not reach the place the takeover sent it to, nor did anybody move it: the system is too slow now.
    case cursorStuck
    /// Another app took the front while the takeover was using the mouse and keyboard: stopped so nothing lands in it.
    case lostFront(String)
    /// The whole takeover took longer than allowed.
    case timeLimit
    /// One click, key or typing took longer than allowed.
    case stepTimeout
    /// A key the current keyboard layout cannot produce.
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "Outro Orb está usando a tela agora; tente de novo em alguns segundos."
        case .couldNotBringToFront(let name):
            "Não consegui trazer \(name) para a frente. Nada foi feito; o app que estava na frente continua nele."
        case .userMovedMouse:
            "Parei de usar a tela porque o mouse se mexeu (a pessoa quis a tela de volta). Devolvi o app da frente; o cursor ficou onde a pessoa o pôs."
        case .cursorStuck:
            "O cursor não chegou aonde eu o mandei (o Mac está lento agora); parei de usar a tela e devolvi o app da frente e o cursor. Tente de novo em instantes."
        case .lostFront(let name):
            "\(name) saiu da frente enquanto eu usava a tela; parei para nada cair em outro app e devolvi a tela."
        case .timeLimit:
            "Usar a tela passou do limite de tempo e foi interrompido; devolvi a tela. O que já foi feito pode ter valido."
        case .stepTimeout:
            "Uma etapa de usar a tela passou de 2 s e foi interrompida; devolvi a tela."
        case .unknownKey(let text):
            "O teclado atual não tem a tecla \"\(text)\"."
        }
    }
}

// MARK: - The lock

/// One takeover at a time: two Orbs asking for the screen together share the one mouse and keyboard, so the second is
/// refused instead of waiting.
final class TakeoverLock: Sendable {
    static let shared = TakeoverLock()

    private let held = OSAllocatedUnfairLock(initialState: false)

    /// Takes the lock without waiting; `TakeoverFailure.busy` when somebody holds it.
    func acquire() throws {
        let wasHeld = held.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        if wasHeld { throw TakeoverFailure.busy }
    }

    func release() { held.withLock { $0 = false } }
}

// MARK: - Seams

/// The app in front.
struct TakeoverFront: Sendable, Equatable {
    var pid: Int32
    var name: String
    var bundleID: String?

    var app: AccessibilityApp { AccessibilityApp(name: name, bundleID: bundleID, pid: pid) }
}

enum TakeoverMouseEvent: Sendable, Equatable {
    case moved, down, up, dragged
}

/// Posts the real events of a takeover (`.cghidEventTap`, a private event source so the person's held keys and buttons
/// do not mix in).
protocol TakeoverEventPoster: Sendable {
    func mouse(_ event: TakeoverMouseEvent, at point: CGPoint, button: MouseButton, clickState: Int)
    func key(virtualKey: UInt16, down: Bool, modifiers: KeyStroke.Modifiers)
    /// Types the characters as one key press carrying the text.
    func text(_ units: [UInt16])
    /// The virtual key that types `character` on the current layout (nil if none does).
    func virtualKey(for character: Character) -> UInt16?
}

/// The calls a takeover makes on macOS, injectable. They block on the other app, so the owner calls them off the
/// cooperative pool.
protocol TakeoverPlatform: Sendable {
    func root(of app: AccessibilityApp) -> any AccessibilityElement
    /// The app in front now.
    func frontmost() -> TakeoverFront?
    func cursorLocation() -> CGPoint
    func warpCursor(to point: CGPoint)
    /// `CGAssociateMouseAndMouseCursorPosition(1)`: the mouse drives the cursor again.
    func associateCursor()
    func makePoster() -> any TakeoverEventPoster
    /// The second way to give the person's app back when `AXFrontmost` did not: `NSRunningApplication.activate()` (only
    /// here, in the takeover, does the Orb activate another app).
    func activate(_ pid: Int32)
}

/// Tells the person the Orb has the screen (a panel in the app); see `TakeoverHUD`.
protocol TakeoverIndicator: Sendable {
    func began() async
    func ended() async
}

// MARK: - The real hand

/// The mouse and keyboard of a takeover. It aborts when the cursor is not where it was put (the person grabbed the mouse)
/// and when a step or the whole takeover takes too long.
final class LiveTakeoverHand: TakeoverHand, @unchecked Sendable {
    /// Interpolated steps of a drag.
    static let dragSteps = 15
    /// How far (points) the real cursor may be from where the hand put it.
    static let driftTolerance: CGFloat = 3
    /// Longest chunk typed as one event, in UTF-16 units.
    static let typeChunk = 20

    private let platform: any TakeoverPlatform
    private let poster: any TakeoverEventPoster
    private let target: AccessibilityApp
    private let overall: ContinuousClock.Instant
    private let stepLimit: Duration
    private let pause: Duration
    private let lock = NSLock()
    private var expected: CGPoint
    private var drift = false

    /// Whether a drift stopped the takeover.
    var userMovedMouse: Bool { lock.withLock { drift } }

    init(platform: any TakeoverPlatform, poster: any TakeoverEventPoster, target: AccessibilityApp, startedAt cursor: CGPoint, overallDeadline: ContinuousClock.Instant,
         stepLimit: Duration = .seconds(2), pause: Duration = .milliseconds(8)) {
        self.platform = platform
        self.poster = poster
        self.target = target
        self.expected = cursor
        self.overall = overallDeadline
        self.stepLimit = stepLimit
        self.pause = pause
    }

    // MARK: Checks

    private func begin() -> ContinuousClock.Instant { min(ContinuousClock.now.advanced(by: stepLimit), overall) }

    private func tick(_ stepDeadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        if now >= overall { throw TakeoverFailure.timeLimit }
        if now >= stepDeadline { throw TakeoverFailure.stepTimeout }
        try checkCursor()
        // Real input goes to whatever is in front: if it is not the app, nothing is sent.
        if let front = platform.frontmost(), front.pid != target.pid { throw TakeoverFailure.lostFront(target.name) }
    }

    private func checkCursor() throws {
        let here = platform.cursorLocation()
        let target = lock.withLock { expected }
        if hypot(here.x - target.x, here.y - target.y) > Self.driftTolerance {
            lock.withLock { drift = true }
            throw TakeoverFailure.userMovedMouse
        }
    }

    private func pauseBriefly() async throws {
        if pause > .zero { try await Task.sleep(for: pause) }
    }

    /// How long a move may take to reach the cursor (the window server applies it a moment later, more under load).
    static let arrival: Duration = .milliseconds(400)
    /// When a move has not arrived by then, it is posted once more.
    static let repost: Duration = .milliseconds(120)
    /// The cursor is looked at at least this many times before a move counts as lost: a process starved by a loaded Mac
    /// (sleeps that last far longer than asked) must not take its own slowness for a cursor that did not move.
    static let minimumLooks = 60

    /// Posts a move and waits for the cursor to arrive. The window server moves the cursor in one jump, so while it has
    /// not arrived it is still where the hand left it: a cursor found anywhere else was moved by the person. One that stays
    /// put past `arrival` (posted twice) is a slow system, not the person: the takeover stops and the cursor is put back.
    private func place(_ point: CGPoint, _ event: TakeoverMouseEvent, button: MouseButton, deadline: ContinuousClock.Instant) async throws {
        let previous = lock.withLock { () -> CGPoint in
            defer { expected = point }
            return expected
        }
        poster.mouse(event, at: point, button: button, clickState: 0)
        let started = ContinuousClock.now
        let settleBy = min(started.advanced(by: Self.arrival), deadline)
        var posted = 1
        var looks = 0
        func near(_ one: CGPoint, _ other: CGPoint) -> Bool { hypot(one.x - other.x, one.y - other.y) <= Self.driftTolerance }
        while true {
            let here = platform.cursorLocation()
            looks += 1
            if near(here, point) { return }
            if !near(here, previous) {
                lock.withLock { drift = true }
                throw TakeoverFailure.userMovedMouse
            }
            let now = ContinuousClock.now
            if now >= deadline || (now >= settleBy && looks >= Self.minimumLooks) { break }
            if posted == 1, started.duration(to: .now) >= Self.repost {
                poster.mouse(event, at: point, button: button, clickState: 0)
                posted += 1
            }
            try await Task.sleep(for: .milliseconds(3))
        }
        throw TakeoverFailure.cursorStuck
    }

    // MARK: TakeoverHand

    func click(at point: CGPoint, button: MouseButton, count: Int) async throws {
        let deadline = begin()
        try tick(deadline)
        try await place(point, .moved, button: button, deadline: deadline)
        try await pauseBriefly()
        for state in 1...max(1, min(count, 3)) {
            try tick(deadline)
            poster.mouse(.down, at: point, button: button, clickState: state)
            poster.mouse(.up, at: point, button: button, clickState: state)
            if state < count { try await pauseBriefly() }
        }
    }

    func type(_ text: String) async throws {
        let deadline = begin()
        var chunk: [UInt16] = []
        func flush() async throws {
            guard !chunk.isEmpty else { return }
            try tick(deadline)
            poster.text(chunk)
            chunk.removeAll(keepingCapacity: true)
            try await Task.sleep(for: .milliseconds(4))
        }
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > Self.typeChunk { try await flush() }
            chunk += units
        }
        try await flush()
    }

    func key(_ stroke: KeyStroke) async throws {
        let deadline = begin()
        try tick(deadline)
        let code: UInt16
        switch stroke.key {
        case .named(let named): code = named.virtualKey
        case .character(let character):
            guard let found = poster.virtualKey(for: character) else { throw TakeoverFailure.unknownKey(String(character)) }
            code = found
        }
        poster.key(virtualKey: code, down: true, modifiers: stroke.modifiers)
        poster.key(virtualKey: code, down: false, modifiers: stroke.modifiers)
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        let deadline = begin()
        try tick(deadline)
        try await place(start, .moved, button: .left, deadline: deadline)
        try await pauseBriefly()
        try tick(deadline)
        poster.mouse(.down, at: start, button: .left, clickState: 1)
        var last = start
        do {
            for step in 1...Self.dragSteps {
                let progress = CGFloat(step) / CGFloat(Self.dragSteps)
                let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
                try tick(deadline)
                try await place(point, .dragged, button: .left, deadline: deadline)
                last = point
                try await pauseBriefly()
            }
        } catch {
            // Never leave the button held down in the other app.
            poster.mouse(.up, at: last, button: .left, clickState: 1)
            throw error
        }
        poster.mouse(.up, at: end, button: .left, clickState: 1)
    }
}

// MARK: - The owner

/// Lends the screen: brings the app up, runs the body with the real input, and always puts everything back.
struct LiveScreenOwner: ScreenOwner {
    var platform: any TakeoverPlatform
    var events: any AccessibilityEvents
    var indicator: (any TakeoverIndicator)?
    var lock: TakeoverLock
    /// How long the app has to become the active one (`AXApplicationActivated`).
    var activationTimeout: Duration = .milliseconds(500)
    var stepLimit: Duration = .seconds(2)
    var pause: Duration = .milliseconds(8)
    /// How long the person's app has to come back to the front.
    var restoreTimeout: Duration = .milliseconds(500)

    init(platform: any TakeoverPlatform = LiveTakeoverPlatform(), events: any AccessibilityEvents = UnavailableAccessibilityEvents(),
         indicator: (any TakeoverIndicator)? = TakeoverBroadcast(), lock: TakeoverLock = .shared) {
        self.platform = platform
        self.events = events
        self.indicator = indicator
        self.lock = lock
    }

    /// What was in front before.
    private struct Saved: Sendable {
        var front: TakeoverFront?
        var window: (any AccessibilityElement)?
        var cursor: CGPoint
    }

    func takeOver<Value: Sendable>(_ app: AccessibilityApp, window: (any AccessibilityElement)?, limit: Duration,
                                   _ body: @escaping @Sendable (any TakeoverHand) async throws -> Value) async throws -> TakeoverReport<Value> {
        try Task.checkCancellation()
        try lock.acquire()
        let clock = ContinuousClock()
        let started = clock.now
        let platform = platform

        let saved = await TakeoverQueue.run { () -> Saved in
            let front = platform.frontmost()
            let focused = front.flatMap { Self.focusedWindow(of: $0, platform: platform) }
            return Saved(front: front, window: focused, cursor: platform.cursorLocation())
        }
        await indicator?.began()

        let poster = platform.makePoster()
        let hand = LiveTakeoverHand(platform: platform, poster: poster, target: app, startedAt: saved.cursor, overallDeadline: started.advanced(by: limit),
                                    stepLimit: stepLimit, pause: pause)
        let outcome: Result<Value, any Error>
        do {
            try await bringToFront(app, window: window, was: saved.front)
            outcome = .success(try await Self.withLimit(limit) { try await body(hand) })
        } catch {
            outcome = .failure(error)
        }

        // Whatever happened above (an error, the task cancelled, the time up), the screen goes back, and this part is not
        // cancellable: it runs in its own task that is awaited whatever happens to this one.
        let userTookOver = hand.userMovedMouse
        let restored = await Task.detached(priority: .userInitiated) { [self] in
            let result = await restore(saved, target: app, keepCursor: userTookOver)
            await indicator?.ended()
            lock.release()
            return result
        }.value
        let value: Value
        do {
            value = try outcome.get()
        } catch {
            // The person must hear that their app is not back in front, whatever else went wrong.
            guard restored.failed, let name = saved.front?.name, !(error is CancellationError) else { throw error }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ToolError(reason + " " + Self.notRestored(name))
        }
        return TakeoverReport(value: value, duration: started.duration(to: clock.now), restoredApp: restored.app,
                              cursorRestored: restored.cursor, restoreFailed: restored.failed)
    }

    /// What the model is told (and tells the person) when the app that was in front could not be put back.
    static func notRestored(_ name: String) -> String {
        "Atenção: não consegui devolver \(name) para a frente (nem por Acessibilidade nem ativando o app); avise o usuário que ele pode precisar clicar em \(name)."
    }

    // MARK: Bringing the app up

    private func bringToFront(_ app: AccessibilityApp, window: (any AccessibilityElement)?, was front: TakeoverFront?) async throws {
        let platform = platform
        // Subscribe before acting so the notification cannot be missed.
        let activated = events.events(pid: app.pid, [.applicationActivated])
        await TakeoverQueue.run {
            // The API tells an app to come forward with AXFrontmost on its element (`activate()` is only a request).
            try? platform.root(of: app).setValue(.bool(true), for: "AXFrontmost")
        }
        if front?.pid != app.pid {
            guard await Self.waitUntil(activationTimeout, notifications: activated, { platform.frontmost()?.pid == app.pid }) else {
                throw TakeoverFailure.couldNotBringToFront(app.name)
            }
        }
        if let window {
            await TakeoverQueue.run {
                try? window.perform("AXRaise")
                try? window.setValue(.bool(true), for: "AXMain")
            }
        }
    }

    /// True as soon as `check` passes: it is looked at on every notification and every 15 ms; false after `timeout`.
    private static func waitUntil(_ timeout: Duration, notifications: AsyncStream<AXEvent>, _ check: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let wake = AsyncStream<Void>.makeStream()
        let watcher = Task { for await _ in notifications { wake.continuation.yield() } }
        defer { watcher.cancel() }
        var iterator = wake.stream.makeAsyncIterator()
        while true {
            if await TakeoverQueue.run(check) { return true }
            if ContinuousClock.now >= deadline { return false }
            let nap = Task {
                try? await Task.sleep(for: .milliseconds(15))
                if !Task.isCancelled { wake.continuation.yield() }
            }
            _ = await iterator.next()
            nap.cancel()
        }
    }

    /// Runs `work` for at most `limit`; past it the work is cancelled, and when it has wound down the takeover fails.
    private static func withLimit<Value: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            guard let first = try await group.next() else { throw CancellationError() }
            if let value = first {
                group.cancelAll()
                return value
            }
            group.cancelAll()
            _ = try? await group.next()
            throw TakeoverFailure.timeLimit
        }
    }

    // MARK: Giving it back

    private static func focusedWindow(of front: TakeoverFront, platform: any TakeoverPlatform) -> (any AccessibilityElement)? {
        let root = platform.root(of: front.app)
        return root.element("AXFocusedWindow") ?? root.element("AXMainWindow")
    }

    /// Puts the person's app, window and cursor back. `app`: the app put back in front (nil when nothing needed it);
    /// `failed`: it needed it and neither `AXFrontmost` (twice) nor activating the app brought it back; `cursor`: the
    /// cursor is where it was (false when the person took the mouse, which is left where they put it).
    private func restore(_ saved: Saved, target: AccessibilityApp, keepCursor: Bool) async -> (app: String?, failed: Bool, cursor: Bool) {
        let platform = platform
        var restoredApp: String?
        var failed = false
        if let front = saved.front {
            func putBack() async {
                await TakeoverQueue.run {
                    try? platform.root(of: front.app).setValue(.bool(true), for: "AXFrontmost")
                    if let window = saved.window { try? window.setValue(.bool(true), for: "AXMain") }
                }
            }
            func isBack() async -> Bool {
                let deadline = ContinuousClock.now.advanced(by: restoreTimeout)
                while true {
                    if await TakeoverQueue.run({ platform.frontmost()?.pid == front.pid }) { return true }
                    if ContinuousClock.now >= deadline { return false }
                    try? await Task.sleep(for: .milliseconds(15))
                }
            }
            await putBack()
            var back = await isBack()
            if !back {
                await putBack()
                back = await isBack()
            }
            if !back, front.pid != target.pid {
                // The second way: the app asked to activate (cooperative, but it does not depend on the app's AX answer).
                await TakeoverQueue.run { platform.activate(front.pid) }
                back = await isBack()
            }
            if front.pid != target.pid {
                if back { restoredApp = front.name } else { failed = true }
            }
        }
        // Where the cursor was. When the person grabbed the mouse to stop the takeover, it stays where they put it: then
        // it is not back, and the report says so.
        let cursor = saved.cursor
        guard !keepCursor else {
            await TakeoverQueue.run { platform.associateCursor() }
            return (restoredApp, failed, false)
        }
        let cursorRestored = await TakeoverQueue.run { () -> Bool in
            platform.warpCursor(to: cursor)
            platform.associateCursor()
            let here = platform.cursorLocation()
            return hypot(here.x - cursor.x, here.y - cursor.y) <= 2
        }
        return (restoredApp, failed, cursorRestored)
    }
}

/// A serial queue for the blocking calls of a takeover, so they never occupy the cooperative pool.
enum TakeoverQueue {
    private static let queue = DispatchQueue(label: "Orb.Takeover", qos: .userInitiated)

    static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - macOS

struct LiveTakeoverPlatform: TakeoverPlatform {
    /// One call may wait this long for an app (seconds).
    static let messagingTimeout: Float = 1

    init() {}

    func root(of app: AccessibilityApp) -> any AccessibilityElement {
        let ref = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(ref, Self.messagingTimeout)
        return LiveAccessibilityElement(ref)
    }

    /// The app in front, read like `ui_act` reads it (`LiveDesktop`: the window list checked against the apps' own
    /// `AXFrontmost`, never `NSWorkspace`).
    func frontmost() -> TakeoverFront? {
        LiveDesktop().frontmost().map(front)
    }

    private func front(_ pid: Int32) -> TakeoverFront {
        let running = NSRunningApplication(processIdentifier: pid)
        return TakeoverFront(pid: pid, name: running?.localizedName ?? "o app anterior", bundleID: running?.bundleIdentifier)
    }

    func activate(_ pid: Int32) {
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
    func warpCursor(to point: CGPoint) { CGWarpMouseCursorPosition(point) }
    func associateCursor() { CGAssociateMouseAndMouseCursorPosition(1) }
    func makePoster() -> any TakeoverEventPoster { LiveTakeoverPoster() }
}

final class LiveTakeoverPoster: TakeoverEventPoster, @unchecked Sendable {
    private let source = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var characterKeys: [Character: UInt16]?

    private static func flags(_ modifiers: KeyStroke.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    func mouse(_ event: TakeoverMouseEvent, at point: CGPoint, button: MouseButton, clickState: Int) {
        let cgButton: CGMouseButton
        let down: CGEventType, up: CGEventType, dragged: CGEventType
        switch button {
        case .left: (cgButton, down, up, dragged) = (.left, .leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: (cgButton, down, up, dragged) = (.right, .rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: (cgButton, down, up, dragged) = (.center, .otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
        let type: CGEventType = switch event {
        case .moved: .mouseMoved
        case .down: down
        case .up: up
        case .dragged: dragged
        }
        guard let cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        if event == .down || event == .up { cg.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickState))) }
        cg.post(tap: .cghidEventTap)
    }

    func key(virtualKey: UInt16, down: Bool, modifiers: KeyStroke.Modifiers) {
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { return }
        cg.flags = Self.flags(modifiers)
        cg.post(tap: .cghidEventTap)
    }

    func text(_ units: [UInt16]) {
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            cg.flags = []
            units.withUnsafeBufferPointer { cg.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            cg.post(tap: .cghidEventTap)
        }
    }

    func virtualKey(for character: Character) -> UInt16? {
        let map: [Character: UInt16] = lock.withLock { characterKeys } ?? {
            let built = Self.currentLayout()
            lock.withLock { characterKeys = built }
            return built
        }()
        return map[character]
    }

    /// Characters → key codes on the current (ASCII-capable) layout, by asking `UCKeyTranslate` for each key; the
    /// Text Services calls want the main thread. Falls back to the US layout if the layout cannot be read.
    private static func currentLayout() -> [Character: UInt16] {
        let read: @Sendable () -> [Character: UInt16]? = {
            guard let input = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(input, "TISPropertyUnicodeKeyLayoutData" as CFString) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var map: [Character: UInt16] = [:]
            // Keypad codes come last so a digit resolves to the main row.
            let order = (0..<128).filter { ![65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92].contains($0) }
                + [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
            for code in order {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]), map[Character(scalar)] == nil,
                      !scalar.properties.isWhitespace || scalar == " " else { continue }
                map[Character(scalar)] = UInt16(code)
            }
            return map.isEmpty ? nil : map
        }
        let layout = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
        return layout ?? usLayout
    }

    /// The unshifted US keys (from `USKeyLayout`), without the space bar.
    private static let usLayout: [Character: UInt16] = {
        var map: [Character: UInt16] = [:]
        for (code, pair) in USKeyLayout.keys where code != 49 { if let character = pair.0.first { map[character] = code } }
        return map
    }()
}

// MARK: - The panel that tells the person

/// The Orb tells the app it has the screen by a distributed notification, so the panel appears in the app whichever
/// process runs the takeover.
struct TakeoverBroadcast: TakeoverIndicator {
    static var beganName: Notification.Name { Notification.Name("\(Bundle.main.bundleIdentifier ?? "Orb").takeover.began") }
    static var endedName: Notification.Name { Notification.Name("\(Bundle.main.bundleIdentifier ?? "Orb").takeover.ended") }

    func began() async {
        DistributedNotificationCenter.default().postNotificationName(Self.beganName, object: nil, userInfo: ["pid": Int(getpid())],
                                                                     deliverImmediately: true)
    }

    func ended() async {
        DistributedNotificationCenter.default().postNotificationName(Self.endedName, object: nil, userInfo: ["pid": Int(getpid())],
                                                                     deliverImmediately: true)
    }
}

/// "Orb está usando a tela — mexa o mouse para parar": a small panel that never takes focus or clicks, shown by the app
/// while any process holds a takeover. Hides itself after 15 s without news, in case the process died.
@MainActor
final class TakeoverHUD {
    static let shared = TakeoverHUD()
    static let message = "Orb está usando a tela — mexa o mouse para parar"

    private var panel: NSPanel?
    private var holders: Set<Int> = []
    private var watchdog: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    /// Starts listening (once, from the app).
    func install() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: TakeoverBroadcast.beganName, object: nil, queue: .main) { note in
                let pid = note.userInfo?["pid"] as? Int ?? 0
                MainActor.assumeIsolated { TakeoverHUD.shared.began(pid: pid) }
            },
            center.addObserver(forName: TakeoverBroadcast.endedName, object: nil, queue: .main) { note in
                let pid = note.userInfo?["pid"] as? Int ?? 0
                MainActor.assumeIsolated { TakeoverHUD.shared.ended(pid: pid) }
            },
        ]
    }

    private func began(pid: Int) {
        holders.insert(pid)
        show()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.holders.removeAll()
            self?.hide()
        }
    }

    private func ended(pid: Int) {
        holders.remove(pid)
        guard holders.isEmpty else { return }
        watchdog?.cancel()
        hide()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 60))
        }
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let label = NSTextField(labelWithString: Self.message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let padding: CGFloat = 16
        let size = CGSize(width: label.frame.width + padding * 2, height: label.frame.height + 14)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = CGPoint(x: padding, y: 7)
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
