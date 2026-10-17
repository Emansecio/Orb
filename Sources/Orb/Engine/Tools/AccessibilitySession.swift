import Foundation
import os

// Where the calls into another app's Accessibility run (docs/USO-DO-COMPUTADOR.md §3). Every call is IPC that blocks
// until the app answers, and a hung app answers only when the messaging timeout runs out: so the calls of one app go
// one after another on a serial dispatch queue of its own (a blocked GCD thread, never one of the cooperative pool's),
// at most four apps at a time, and the tool stops waiting at a deadline instead of hanging with the app.

// MARK: - Deadlines

/// How long the tools wait for an app before saying it did not answer.
struct AXDeadlines: Sendable {
    /// A reading without `query`.
    var read: Duration = .seconds(4)
    /// A reading with `query`, which may walk the whole window.
    var readWithQuery: Duration = .seconds(8)
    /// One action, with the checks before and after it.
    var action: Duration = .seconds(2)
    /// Added to a `wait`'s own timeout.
    var waitGrace: Duration = .milliseconds(500)

    static let standard = AXDeadlines()
}

enum AXSessionMessage {
    static func timedOut(_ app: AccessibilityApp, after deadline: Duration) -> String {
        "\(app.name) não respondeu em \(UIClock.seconds(deadline)). Ele pode estar travado ou com um diálogo aberto; "
            + "espere um pouco ou peça ao usuário para olhar a tela."
    }

    static func busy(_ app: AccessibilityApp) -> String {
        "\(app.name) ainda está ocupado com a chamada anterior, que não voltou (o app não responde). Espere alguns segundos e tente de novo."
    }
}

/// Durations as the model reads them: "1,2 s", "5 s".
enum UIClock {
    static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        let value = Double(whole) + Double(fraction) / 1e18
        let tenths = (value * 10).rounded() / 10
        if tenths == tenths.rounded() { return "\(Int(tenths)) s" }
        return String(format: "%.1f s", tenths).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - One app

/// One app's line to the Accessibility API. Its executor is a serial dispatch queue, so the work it runs (blocking IPC)
/// holds a GCD thread while it waits, and the calls of one app never overlap.
actor AXAppSession {
    nonisolated let pid: Int32
    private nonisolated let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    struct State: Sendable {
        /// Calls that ran past their deadline and have not come back yet: while there is one, new calls fail at once.
        var overdue = 0
        var lastUsed = ContinuousClock.now
        /// Whether the app took `AXManualAccessibility` (Electron, Chromium); nil until asked.
        var manualAccessibility: Bool?
        /// The app brought itself to the front after an action: focusing or typing in it needs the screen.
        var stealsFocus = false
    }

    /// State read without waiting for the queue (which may be blocked in a call to a hung app).
    nonisolated let state = OSAllocatedUnfairLock(initialState: State())

    init(pid: Int32) {
        self.pid = pid
        queue = DispatchSerialQueue(label: "Orb.AX.\(pid)", qos: .userInitiated)
    }

    nonisolated var isStuck: Bool { state.withLock { $0.overdue > 0 } }

    /// Puts `work` straight on the session's queue (the actor's own executor, so it is still one call at a time): starting
    /// it never waits for a thread of the cooperative pool, which a busy process may keep full.
    nonisolated func submit(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

/// Cancellation of the work running on an app's queue, which runs outside any task: the walk checks it between
/// elements (`AXWork.isCancelled`).
final class AXWorkToken: Sendable {
    @TaskLocal static var current: AXWorkToken?
    private let flag = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

enum AXWork {
    /// Whether the work in progress was cancelled: the task's own flag, or the token of the session call it runs for.
    static var isCancelled: Bool { Task.isCancelled || AXWorkToken.current?.isCancelled == true }

    static func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}

// MARK: - All apps

/// The sessions of this process, one per app, and the limit on how many work at the same time.
final class AXSessions: @unchecked Sendable {
    static let shared = AXSessions()

    let deadlines: AXDeadlines
    let maxInFlight: Int
    private let lock = NSLock()
    private var sessions: [Int32: AXAppSession] = [:]
    private var inFlight = 0
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter: UInt64 = 0

    init(deadlines: AXDeadlines = .standard, maxInFlight: Int = 4) {
        self.deadlines = deadlines
        self.maxInFlight = max(1, maxInFlight)
    }

    func session(for pid: Int32) -> AXAppSession {
        lock.withLock {
            if let session = sessions[pid] { return session }
            if sessions.count >= 64 {
                // Forget apps not used for a while (their queues hold nothing).
                let idle = sessions.filter { !$0.value.isStuck && $0.value.state.withLock { $0.lastUsed.duration(to: .now) > .seconds(300) } }
                for pid in idle.keys { sessions[pid] = nil }
            }
            let session = AXAppSession(pid: pid)
            sessions[pid] = session
            return session
        }
    }

    /// Calls running now (also the ones past their deadline that have not come back).
    var runningCount: Int { lock.withLock { inFlight } }

    /// Runs `work` on the app's queue and returns its result, or throws when the app does not answer within
    /// `deadline` (the call keeps the session busy until it comes back, and new calls fail at once meanwhile). A
    /// cancelled task stops waiting at once; the work sees the cancellation through `AXWork.isCancelled`. Starting the
    /// work and timing it out use GCD, not the cooperative pool, so a busy process does not turn into a false timeout.
    func run<T: Sendable>(_ app: AccessibilityApp, within deadline: Duration,
                          _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let started = ContinuousClock.now
        let session = session(for: app.pid)
        if session.isStuck { throw ToolError(AXSessionMessage.busy(app)) }
        try Task.checkCancellation()
        guard await acquire(until: started + deadline) else {
            throw ToolError(AXSessionMessage.timedOut(app, after: deadline))
        }
        // Stopped while it waited for a slot: the slot passes on and nothing reaches the app.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
        session.state.withLock { $0.lastUsed = .now }

        let call = CallGate<T>()
        let token = AXWorkToken()
        // Submitted from inside the handler, so a stop that came first has cancelled the token before the work is queued,
        // and work still waiting in the app's queue when Stop comes does nothing once its turn arrives.
        return try await withTaskCancellationHandler {
            session.submit {
                let result: Result<T, any Error>
                if token.isCancelled {
                    result = .failure(CancellationError())
                } else {
                    do { result = .success(try AXWorkToken.$current.withValue(token) { try work() }) } catch { result = .failure(error) }
                }
                session.state.withLock { state in
                    if call.finish() { state.overdue -= 1 }
                    state.lastUsed = .now
                }
                self.release()
                call.resolve(result)
            }
            // The deadline; a no-op when the work came back first (the gate is resolved once). Past it nobody is waiting for
            // the work any more, so it is cancelled: it stops at the next element it would read, and an action it had not
            // yet sent never goes out after the model was told the call timed out (the model would repeat it).
            let wait = Self.interval(ContinuousClock.now.duration(to: started + deadline))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) {
                session.state.withLock { state in
                    if call.markOverdue() { state.overdue += 1 }
                }
                if call.resolve(.failure(ToolError(AXSessionMessage.timedOut(app, after: deadline)))) { token.cancel() }
            }
            return try await call.value()
        } onCancel: {
            token.cancel()
            call.resolve(.failure(CancellationError()))
        }
    }

    static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(max(0, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)))
    }

    private func acquire(until deadline: ContinuousClock.Instant) async -> Bool {
        let id: UInt64? = lock.withLock {
            if inFlight < maxInFlight { inFlight += 1; return nil }
            nextWaiter += 1
            return nextWaiter
        }
        guard let id else { return true }
        return await withCheckedContinuation { continuation in
            let granted: Bool = lock.withLock {
                if inFlight < maxInFlight { inFlight += 1; return true }
                waiting.append((id, continuation))
                return false
            }
            if granted { continuation.resume(returning: true); return }
            let wait = Self.interval(ContinuousClock.now.duration(to: deadline))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) {
                let expired = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard let index = self.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                    return self.waiting.remove(at: index).continuation
                }
                expired?.resume(returning: false)
            }
        }
    }

    private func release() {
        let next: CheckedContinuation<Bool, Never>? = lock.withLock {
            if !waiting.isEmpty { return waiting.removeFirst().continuation } // the slot passes on
            inFlight -= 1
            return nil
        }
        next?.resume(returning: true)
    }
}

/// The outcome of one call, resolved once by whichever comes first: the work, the deadline or cancellation.
private final class CallGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?
    private var finished = false
    private var overdue = false

    /// Marks the call overdue unless its work already came back; true when it did mark it.
    func markOverdue() -> Bool {
        lock.withLock {
            guard !finished, !overdue else { return false }
            overdue = true
            return true
        }
    }

    /// Marks the work as come back; true when it had been marked overdue.
    func finish() -> Bool {
        lock.withLock {
            finished = true
            return overdue
        }
    }

    /// Settles the call with `outcome` unless something settled it first; true when this one did.
    @discardableResult
    func resolve(_ outcome: Result<T, any Error>) -> Bool {
        let (settled, waiter): (Bool, CheckedContinuation<T, any Error>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = outcome
            defer { continuation = nil }
            return (true, continuation)
        }
        waiter?.resume(with: outcome)
        return settled
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, any Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

// MARK: - Live references

/// The live Accessibility references behind the ids of the latest readings, so an action reaches its element without
/// walking the path again (a cheap check that it is still what the reading saw replaces the walk). Kept in memory per
/// Orb and app: at most 6 readings each, 4,000 references in all, 10 minutes.
final class UILiveElements: @unchecked Sendable {
    static let shared = UILiveElements()

    struct Found {
        var element: any AccessibilityElement
        /// The window the reading came from; nil for menus.
        var window: (any AccessibilityElement)?
    }

    private struct Key: Hashable {
        var bot: UUID?
        var pid: Int32
    }

    private struct Reading {
        var generation: Int
        var takenAt: Date
        var window: (any AccessibilityElement)?
        var elements: [String: any AccessibilityElement]
        var stored: ContinuousClock.Instant
        var used: ContinuousClock.Instant
    }

    let maxReferences: Int
    let readingsPerApp: Int
    let lifetime: Duration
    private let lock = NSLock()
    private var readings: [Key: [Reading]] = [:]
    private var generation = 0

    init(maxReferences: Int = 4_000, readingsPerApp: Int = 6, lifetime: Duration = .seconds(600)) {
        self.maxReferences = maxReferences
        self.readingsPerApp = readingsPerApp
        self.lifetime = lifetime
    }

    /// A number no other reading of this process has.
    func nextGeneration() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    /// References kept now, in all readings.
    var count: Int { lock.withLock { readings.values.joined().reduce(0) { $0 + $1.elements.count } } }

    func remember(bot: UUID?, pid: Int32, generation: Int, takenAt: Date, window: (any AccessibilityElement)?,
                  elements: [String: any AccessibilityElement]) {
        let now = ContinuousClock.now
        lock.withLock {
            let key = Key(bot: bot, pid: pid)
            var list = readings[key] ?? []
            list.append(Reading(generation: generation, takenAt: takenAt, window: window, elements: elements, stored: now, used: now))
            if list.count > readingsPerApp { list.removeFirst(list.count - readingsPerApp) }
            readings[key] = list
            prune(now: now)
        }
    }

    /// The reference behind `id` in the reading `generation` (taken at `takenAt`, so another reading
    /// that happens to carry the same number is not mistaken for it).
    func element(bot: UUID?, pid: Int32, generation: Int, takenAt: Date, id: String) -> Found? {
        let now = ContinuousClock.now
        return lock.withLock {
            let key = Key(bot: bot, pid: pid)
            guard var list = readings[key],
                  let index = list.lastIndex(where: { $0.generation == generation && abs($0.takenAt.timeIntervalSince(takenAt)) < 0.001 })
            else { return nil }
            guard list[index].stored.duration(to: now) <= lifetime else {
                list.remove(at: index)
                readings[key] = list.isEmpty ? nil : list
                return nil
            }
            list[index].used = now
            readings[key] = list
            return list[index].elements[id].map { Found(element: $0, window: id.hasPrefix("m") ? nil : list[index].window) }
        }
    }

    func forget(bot: UUID?, pid: Int32) {
        _ = lock.withLock { readings.removeValue(forKey: Key(bot: bot, pid: pid)) }
    }

    /// Drops expired readings, then the least recently used ones until the references fit.
    private func prune(now: ContinuousClock.Instant) {
        for (key, list) in readings {
            let fresh = list.filter { $0.stored.duration(to: now) <= lifetime }
            readings[key] = fresh.isEmpty ? nil : fresh
        }
        var total = readings.values.joined().reduce(0) { $0 + $1.elements.count }
        while total > maxReferences {
            guard let (key, index) = readings.flatMap({ key, list in list.indices.map { (key, $0) } })
                .min(by: { readings[$0.0]![$0.1].used < readings[$1.0]![$1.1].used }) else { break }
            total -= readings[key]![index].elements.count
            readings[key]!.remove(at: index)
            if readings[key]!.isEmpty { readings[key] = nil }
        }
    }
}
