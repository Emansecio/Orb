import ApplicationServices
import Foundation

// Accessibility notifications from other apps (`AXObserver`), so the tools wait for what happened instead of sleeping a
// fixed time (docs/USO-DO-COMPUTADOR.md §3). One hub per process runs its own thread with a run loop (never the main
// one); each app has one observer, shared by every subscription to it and counted, so a notification is registered with
// the app once however many waits want it, and removed when the last one ends.

// MARK: - The observer behind a protocol

/// Where an app's observer hands what it receives.
protocol AXEventSink: AnyObject, Sendable {
    func deliver(_ name: String, element: (any AccessibilityElement)?)
}

/// What an app said to a notification being registered.
enum AXRegistration: Sendable, Equatable {
    case accepted
    case refused
    /// The app did not answer (`cannotComplete`): asking it anything more now only waits the timeout again.
    case hung
}

/// One app's observer: registers notifications with the app (IPC: call it off the main thread, from the app's queue) and
/// owns the run loop source the hub schedules.
protocol AXEventPort: AnyObject, Sendable {
    func add(_ notification: AXNotification) -> AXRegistration
    /// False when the app did not answer.
    @discardableResult func remove(_ notification: AXNotification) -> Bool
    /// Scheduled on the hub's run loop while the app is observed; nil for ports that deliver by other means (tests).
    var source: CFRunLoopSource? { get }
}

/// The real `AXObserver` of one process.
final class LiveAXEventPort: AXEventPort, @unchecked Sendable {
    private let observer: AXObserver
    private let app: AXUIElement
    /// The sink, retained for as long as the observer may call back with it; released by the hub after the source is off
    /// the run loop (`releaseSink`), on the hub's thread, so no callback can be running with it.
    private let refcon: UnsafeMutableRawPointer

    init?(pid: Int32, sink: any AXEventSink) {
        var created: AXObserver?
        guard AXObserverCreate(pid, liveAXObserverCallback, &created) == .success, let created else { return nil }
        observer = created
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, LiveAccessibilitySystem.messagingTimeout)
        refcon = Unmanaged.passRetained(SinkBox(sink)).toOpaque()
    }

    var source: CFRunLoopSource? { AXObserverGetRunLoopSource(observer) }

    func add(_ notification: AXNotification) -> AXRegistration {
        LiveAccessibilityElement.offMain()
        switch AXObserverAddNotification(observer, app, notification.rawValue as CFString, refcon) {
        case .success, .notificationAlreadyRegistered: return .accepted
        case .cannotComplete: return .hung
        default: return .refused
        }
    }

    @discardableResult func remove(_ notification: AXNotification) -> Bool {
        LiveAccessibilityElement.offMain()
        return AXObserverRemoveNotification(observer, app, notification.rawValue as CFString) != .cannotComplete
    }

    /// Called once, on the hub's thread, after the source was removed from the run loop.
    func releaseSink() {
        Unmanaged<SinkBox>.fromOpaque(refcon).release()
    }

    fileprivate final class SinkBox {
        weak var sink: (any AXEventSink)?
        init(_ sink: any AXEventSink) { self.sink = sink }
    }
}

private func liveAXObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let box = Unmanaged<LiveAXEventPort.SinkBox>.fromOpaque(refcon).takeUnretainedValue()
    box.sink?.deliver(name as String, element: LiveAccessibilityElement(element))
}

// MARK: - The hub

/// The process's `AccessibilityEvents`: at most `maxApps` apps observed at once; an app nobody listens to is forgotten
/// after `idle`; an app that quits ends its streams.
final class AXEventHub: AccessibilityEvents, @unchecked Sendable {
    static let shared = AXEventHub()

    typealias PortFactory = @Sendable (Int32, any AXEventSink) -> (any AXEventPort)?

    let maxApps: Int
    let idle: Duration
    private let makePort: PortFactory
    private let watchesExit: Bool
    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    private var nextID = 0
    private let loopLock = NSLock()
    private var runLoop: CFRunLoop?
    private let utility = DispatchQueue(label: "Orb.AXEvents.sync", qos: .utility)

    init(maxApps: Int = 16, idle: Duration = .seconds(30), watchesExit: Bool = true,
         makePort: @escaping PortFactory = { pid, sink in LiveAXEventPort(pid: pid, sink: sink) }) {
        self.maxApps = maxApps
        self.idle = idle
        self.watchesExit = watchesExit
        self.makePort = makePort
    }

    /// Apps observed now.
    var observedApps: Int { lock.withLock { entries.count } }
    /// Streams still open, over every app.
    var subscriptions: Int { lock.withLock { entries.values.reduce(0) { $0 + $1.subscribers.count } } }

    fileprivate struct Subscriber {
        var notifications: Set<AXNotification>
        var element: (any AccessibilityElement)?
        var continuation: AsyncStream<AXEvent>.Continuation
    }

    fileprivate final class Entry: AXEventSink, @unchecked Sendable {
        let pid: Int32
        weak var hub: AXEventHub?
        var port: (any AXEventPort)?
        var subscribers: [Int: Subscriber] = [:]
        /// Serializes registering and removing notifications with the app.
        let portLock = NSLock()
        /// What the app has registered, guarded by `portLock`.
        var registered: Set<AXNotification> = []
        var exitSource: (any DispatchSourceProcess)?
        var idleToken = 0
        var lastUsed = ContinuousClock.now

        init(pid: Int32, hub: AXEventHub) {
            self.pid = pid
            self.hub = hub
        }

        func deliver(_ name: String, element: (any AccessibilityElement)?) {
            guard let notification = AXNotification(rawValue: name) else { return }
            hub?.deliver(AXEvent(notification, pid: pid, element: element), to: self)
        }
    }

    func events(pid: Int32, _ notifications: Set<AXNotification>, on element: (any AccessibilityElement)?) -> AsyncStream<AXEvent> {
        guard !notifications.isEmpty, let (entry, id, stream) = subscribe(pid: pid, notifications, element) else {
            return AsyncStream { $0.finish() }
        }
        // Registered with the app before the stream is handed out, so an action taken right after cannot be missed.
        sync(entry)
        let accepted = entry.portLock.withLock { entry.registered }
        if accepted.isDisjoint(with: notifications) {
            unsubscribe(pid: pid, id: id, finish: true)
        }
        return stream
    }

    private func subscribe(pid: Int32, _ notifications: Set<AXNotification>,
                           _ element: (any AccessibilityElement)?) -> (Entry, Int, AsyncStream<AXEvent>)? {
        let (stream, continuation) = AsyncStream.makeStream(of: AXEvent.self, bufferingPolicy: .bufferingNewest(64))
        var evicted: Entry?
        let made: (Entry, Int)? = lock.withLock {
            let entry: Entry
            if let existing = entries[pid] {
                entry = existing
            } else {
                if entries.count >= maxApps {
                    guard let quiet = entries.values.filter({ $0.subscribers.isEmpty }).min(by: { $0.lastUsed < $1.lastUsed }) else { return nil }
                    entries[quiet.pid] = nil
                    evicted = quiet
                }
                entry = Entry(pid: pid, hub: self)
                guard let port = makePort(pid, entry) else { return nil }
                entry.port = port
                entries[pid] = entry
                start(entry)
            }
            nextID += 1
            entry.subscribers[nextID] = Subscriber(notifications: notifications, element: element, continuation: continuation)
            entry.idleToken += 1
            entry.lastUsed = .now
            return (entry, nextID)
        }
        if let evicted { tearDown(evicted) }
        guard let (entry, id) = made else {
            continuation.finish()
            return nil
        }
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(pid: pid, id: id, finish: false) }
        return (entry, id, stream)
    }

    private func unsubscribe(pid: Int32, id: Int, finish: Bool) {
        let removed: (Entry, Subscriber)? = lock.withLock {
            guard let entry = entries[pid], let subscriber = entry.subscribers.removeValue(forKey: id) else { return nil }
            entry.lastUsed = .now
            if entry.subscribers.isEmpty { scheduleIdle(entry) }
            return (entry, subscriber)
        }
        guard let (entry, subscriber) = removed else { return }
        if finish { subscriber.continuation.finish() }
        // Removing a notification is IPC too: off the caller's thread, which may be the stream's consumer.
        utility.async { [weak self] in self?.sync(entry) }
    }

    /// Makes what the app has registered match what the subscriptions want. A hung app stops it at the first call it does
    /// not answer: each further call would wait the whole messaging timeout again (14 of them hold the app's session for
    /// 14 s). What could not be removed is forgotten anyway (an unwanted notification reaches no subscriber).
    private func sync(_ entry: Entry) {
        entry.portLock.withLock {
            let (wanted, port): (Set<AXNotification>, (any AXEventPort)?) = lock.withLock {
                guard entries[entry.pid] === entry else { return ([], nil) }
                return (entry.subscribers.values.reduce(into: Set()) { $0.formUnion($1.notifications) }, entry.port)
            }
            guard let port else { return }
            var hung = false
            for notification in wanted.subtracting(entry.registered).sorted(by: { $0.rawValue < $1.rawValue }) {
                switch port.add(notification) {
                case .accepted: entry.registered.insert(notification)
                case .refused: continue
                case .hung: hung = true
                }
                if hung { break }
            }
            for notification in entry.registered.subtracting(wanted) {
                if !hung, !port.remove(notification) { hung = true }
                entry.registered.remove(notification)
            }
        }
    }

    fileprivate func deliver(_ event: AXEvent, to entry: Entry) {
        let targets: [AsyncStream<AXEvent>.Continuation] = lock.withLock {
            guard entries[entry.pid] === entry else { return [] }
            return entry.subscribers.values.filter { subscriber in
                guard subscriber.notifications.contains(event.notification) else { return false }
                guard let wanted = subscriber.element else { return true }
                return event.element.map { wanted.isSame(as: $0) } ?? false
            }.map(\.continuation)
        }
        for target in targets { target.yield(event) }
    }

    /// Ends every stream of the app, as when it quits.
    func appQuit(_ pid: Int32) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: pid) }) else { return }
        tearDown(entry, appGone: true)
    }

    // MARK: Lifetime of an entry

    /// Schedules the app's source and watches for the process to end. Called with `lock` held.
    private func start(_ entry: Entry) {
        if let source = entry.port?.source { CFRunLoopAddSource(hubRunLoop(), source, .defaultMode) }
        guard watchesExit else { return }
        let exit = DispatchSource.makeProcessSource(identifier: entry.pid, eventMask: .exit, queue: utility)
        exit.setEventHandler { [weak self] in self?.appQuit(entry.pid) }
        exit.resume()
        entry.exitSource = exit
    }

    /// Called with `lock` held when the last subscription of an app ends.
    private func scheduleIdle(_ entry: Entry) {
        let token = entry.idleToken
        let pid = entry.pid
        utility.asyncAfter(deadline: .now() + AXSessions.interval(idle)) { [weak self] in
            guard let self else { return }
            let stale: Entry? = lock.withLock {
                guard let current = entries[pid], current === entry, current.subscribers.isEmpty, current.idleToken == token else { return nil }
                entries[pid] = nil
                return current
            }
            if let stale { tearDown(stale) }
        }
    }

    /// Finishes the streams, stops watching the process and takes the source off the run loop on the hub's own thread
    /// (where callbacks run), and only then lets the observer and its sink go.
    private func tearDown(_ entry: Entry, appGone: Bool = false) {
        let (subscribers, port, exit): ([Subscriber], (any AXEventPort)?, (any DispatchSourceProcess)?) = lock.withLock {
            defer {
                entry.subscribers.removeAll()
                entry.port = nil
                entry.exitSource = nil
            }
            return (Array(entry.subscribers.values), entry.port, entry.exitSource)
        }
        exit?.cancel()
        for subscriber in subscribers { subscriber.continuation.finish() }
        entry.portLock.withLock {
            // An app still running is told to stop sending; one that quit has nobody to tell.
            if !appGone, let port {
                for notification in entry.registered where !port.remove(notification) { break } // a hung app is not waited on again
            }
            entry.registered.removeAll()
        }
        guard let port else { return }
        if let source = port.source {
            let loop = hubRunLoop()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopRemoveSource(loop, source, .defaultMode)
                (port as? LiveAXEventPort)?.releaseSink()
            }
            CFRunLoopWakeUp(loop)
        } else {
            (port as? LiveAXEventPort)?.releaseSink()
        }
    }

    /// The run loop of the hub's thread, started on first use.
    private func hubRunLoop() -> CFRunLoop {
        loopLock.withLock { startedRunLoop() }
    }

    private func startedRunLoop() -> CFRunLoop {
        if let runLoop { return runLoop }
        let ready = DispatchSemaphore(value: 0)
        let box = RunLoopBox()
        let thread = Thread {
            box.loop = CFRunLoopGetCurrent()
            // A source that never fires keeps the run loop running while no app is observed.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Orb.AXEvents"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        let loop = box.loop!
        runLoop = loop
        return loop
    }

    private final class RunLoopBox: @unchecked Sendable {
        var loop: CFRunLoop?
    }
}

// MARK: - Waiting on a stream

/// Collects a notification stream in the background so a caller can wait for "something new" with a timeout.
/// Cancel it when done: that ends the iteration and with it the subscription.
final class AXEventWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [AXEvent] = []
    private var ended = false
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextWaiter = 0
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AXEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                self?.record(event)
            }
            self?.end()
        }
    }

    deinit { task?.cancel() }

    /// Notifications received so far.
    var count: Int { lock.withLock { received.count } }
    var events: [AXEvent] { lock.withLock { received } }
    /// The stream ended: the app does not give notifications (or quit).
    var isFinished: Bool { lock.withLock { ended } }

    func cancel() { task?.cancel() }

    private func record(_ event: AXEvent) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            received.append(event)
            defer { waiter = nil }
            return waiter?.continuation
        }
        waiting?.resume()
    }

    private func end() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            ended = true
            defer { waiter = nil }
            return waiter?.continuation
        }
        waiting?.resume()
    }

    /// Waits until more than `seen` notifications arrived, the stream ended, or `timeout` passed. True when there are new
    /// notifications.
    @discardableResult
    func waitForMore(than seen: Int, timeout: Duration) async -> Bool {
        if lock.withLock({ received.count > seen || ended }) { return count > seen }
        guard timeout > .zero else { return false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id: Int? = lock.withLock {
                if received.count > seen || ended { return nil }
                nextWaiter += 1
                waiter = (nextWaiter, continuation)
                return nextWaiter
            }
            guard let id else { continuation.resume(); return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                let expired = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    guard let waiter, waiter.id == id else { return nil }
                    defer { self.waiter = nil }
                    return waiter.continuation
                }
                expired?.resume()
            }
        }
        return count > seen
    }
}

// MARK: - Settling after an action

/// How long to watch an app after acting before reading what changed: the first notification (up to `first`), then
/// until it has been quiet for `quiet`; an app without notifications gets `fallback`.
struct UISettle: Sendable {
    var first: Duration = .milliseconds(400)
    var quiet: Duration = .milliseconds(60)
    var fallback: Duration = .milliseconds(150)
    /// The longest a settle may take whatever keeps arriving.
    var cap: Duration = .seconds(1)

    static let standard = UISettle()
    /// No waiting at all (tests).
    static let none = UISettle(first: .zero, quiet: .zero, fallback: .zero, cap: .zero)

    /// The notifications that say an action did something.
    static let notifications: Set<AXNotification> = [
        .valueChanged, .elementDestroyed, .created, .windowCreated, .focusedElementChanged, .focusedWindowChanged,
        .titleChanged, .selectedChildrenChanged, .selectedRowsChanged, .selectedTextChanged, .layoutChanged, .sheetCreated,
        .rowCountChanged, .loadComplete,
    ]

    /// Waits as described; returns whether a notification came.
    @discardableResult
    func wait(on watcher: AXEventWatcher) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        if watcher.isFinished {
            if fallback > .zero { try? await Task.sleep(for: fallback) }
            return false
        }
        guard await watcher.waitForMore(than: 0, timeout: first) else {
            if watcher.isFinished, fallback > .zero { try? await Task.sleep(for: fallback) }
            return false
        }
        var seen = watcher.count
        while started.duration(to: clock.now) < cap, !Task.isCancelled {
            guard await watcher.waitForMore(than: seen, timeout: quiet) else { break }
            seen = watcher.count
        }
        return true
    }
}
