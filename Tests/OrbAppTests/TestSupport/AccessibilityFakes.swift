import CoreGraphics
import Foundation
@testable import Orb

// Fakes for everything background computer use touches, shared by the Accessibility, capture, input and takeover tests.
// The real Accessibility API, event posting and screen capture are never called from tests: no other app is read or
// clicked, nothing is captured and no permission prompt can appear.

// MARK: - A fake interface

final class FakeElement: AccessibilityElement, @unchecked Sendable {
    private let lock = NSLock()
    var attrs: [String: AXAttributeValue] = [:]
    var children: [FakeElement] = []
    var actions: [String] = []
    var settable: Set<String> = []
    var onPerform: (@Sendable (String) -> Void)?
    /// Called after an attribute is set (to make the app react, as one that comes forward when a field gets the focus).
    var onSet: (@Sendable (String, AXAttributeValue) -> Void)?
    /// The owning process reported by `pid`.
    var pid: Int32?
    /// How long every call into this element blocks, like an app that is hung or slow to answer.
    var stall: Duration = .zero
    /// Scripted failures, kept until removed. Keys: an attribute name (its reads fail), `"perform:AXPress"`,
    /// `"set:AXValue"`, or `"*"` for every call. `read(_:)` reports them as `.failed`; `attribute(_:)` and
    /// `attributes(_:)` swallow them like the live element does (nil / missing); `perform` and `setValue` throw.
    var failures: [String: AXFailure] = [:]
    private var log: [String] = []
    private var performedActions: [String] = []
    private var assigned: [String: AXAttributeValue] = [:]
    private var trips = 0

    /// Names of the attributes that were asked of this element.
    var reads: [String] { lock.withLock { log } }
    var performed: [String] { lock.withLock { performedActions } }
    func assignedValue(_ name: String) -> AXAttributeValue? { lock.withLock { assigned[name] } }

    /// Calls made into this element, each counting as one round trip to the app (`attributes(_:)` and `read(_:)` are one
    /// call however many names they ask for, like `AXUIElementCopyMultipleAttributeValues`).
    var roundTrips: Int { lock.withLock { trips } }
    /// This element and everything under it.
    var subtree: [FakeElement] { [self] + children.flatMap(\.subtree) }
    /// Round trips made into the whole tree below (and including) this element.
    var treeRoundTrips: Int { subtree.reduce(0) { $0 + $1.roundTrips } }
    func resetRoundTrips() { for element in subtree { element.lock.withLock { element.trips = 0 } } }

    /// Position and size in `AXPosition` / `AXSize`.
    var frame: CGRect? {
        get {
            guard case .point(let origin)? = attrs["AXPosition"], case .size(let size)? = attrs["AXSize"] else { return nil }
            return CGRect(origin: origin, size: size)
        }
        set {
            attrs["AXPosition"] = newValue.map { .point($0.origin) }
            attrs["AXSize"] = newValue.map { .size($0.size) }
        }
    }

    /// One call into the app: counts it and waits as long as `stall` says.
    private func enter() {
        lock.withLock { trips += 1 }
        let (seconds, attoseconds) = stall.components
        if seconds > 0 || attoseconds > 0 { Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18) }
    }

    private func failure(for key: String) -> AXFailure? { failures[key] ?? failures["*"] }

    private func lookup(_ name: String) -> AXAttributeValue? {
        lock.withLock { log.append(name) }
        if name == "AXChildren" { return .elements(children) }
        return attrs[name]
    }

    func attribute(_ name: String) -> AXAttributeValue? {
        enter()
        if failure(for: name) != nil { lock.withLock { log.append(name) }; return nil }
        return lookup(name)
    }

    func attributes(_ names: [String]) -> [String: AXAttributeValue] {
        enter()
        var result: [String: AXAttributeValue] = [:]
        for name in names {
            if failure(for: name) != nil { lock.withLock { log.append(name) }; continue }
            if let value = lookup(name) { result[name] = value }
        }
        return result
    }

    func read(_ names: [String]) -> AXRead {
        enter()
        for name in names { lock.withLock { log.append(name) } }
        if let failure = names.lazy.compactMap({ self.failures[$0] }).first ?? failures["*"] { return .failed(failure) }
        var result: [String: AXAttributeValue] = [:]
        for name in names {
            if name == "AXChildren" { result[name] = .elements(children) } else if let value = attrs[name] { result[name] = value }
        }
        return .values(result)
    }

    func actionNames() -> [String] {
        enter()
        return actions
    }

    func isSettable(_ name: String) -> Bool {
        enter()
        return settable.contains(name)
    }

    func perform(_ action: String) throws {
        enter()
        if let failure = failure(for: "perform:\(action)") { throw failure }
        guard actions.contains(action) else { throw AXFailure.notSupported }
        lock.withLock { performedActions.append(action) }
        onPerform?(action)
    }

    func setValue(_ value: AXAttributeValue, for name: String) throws {
        enter()
        if let failure = failure(for: "set:\(name)") { throw failure }
        guard settable.contains(name) else { throw AXFailure.notSupported }
        lock.withLock { assigned[name] = value }
        attrs[name] = value
        onSet?(name, value)
    }
}

func fake(_ role: String, title: String? = nil, description: String? = nil, value: AXAttributeValue? = nil, placeholder: String? = nil,
          size: CGSize? = CGSize(width: 80, height: 20), subrole: String? = nil, enabled: Bool? = nil, focused: Bool? = nil,
          selected: Bool? = nil, hidden: Bool? = nil, actions: [String] = [], _ children: [FakeElement] = []) -> FakeElement {
    let element = FakeElement()
    element.attrs["AXRole"] = .string(role)
    if let title { element.attrs["AXTitle"] = .string(title) }
    if let description { element.attrs["AXDescription"] = .string(description) }
    if let value { element.attrs["AXValue"] = value }
    if let placeholder { element.attrs["AXPlaceholderValue"] = .string(placeholder) }
    if let size { element.attrs["AXSize"] = .size(size) }
    if let subrole { element.attrs["AXSubrole"] = .string(subrole) }
    if let enabled { element.attrs["AXEnabled"] = .bool(enabled) }
    if let focused { element.attrs["AXFocused"] = .bool(focused) }
    if let selected { element.attrs["AXSelected"] = .bool(selected) }
    if let hidden { element.attrs["AXHidden"] = .bool(hidden) }
    element.actions = actions
    element.children = children
    return element
}

func fakeButton(_ title: String, actions: [String] = ["AXPress"]) -> FakeElement { fake("AXButton", title: title, actions: actions) }

/// An app with windows and a menu bar.
func fakeApp(windows: [FakeElement], menus: [FakeElement]? = nil) -> FakeElement {
    let root = fake("AXApplication", size: nil)
    root.attrs["AXWindows"] = .elements(windows)
    if let menus { root.attrs["AXMenuBar"] = .element(fake("AXMenuBar", size: nil, menus)) }
    if let first = windows.first { root.attrs["AXFocusedWindow"] = .element(first) }
    return root
}

/// `Arquivo > Exportar… > PDF…`, as the real tree nests it: bar item → AXMenu → items.
func fakeMenu(_ title: String, _ items: [FakeElement]) -> FakeElement {
    fake("AXMenuBarItem", title: title, actions: ["AXPress"], [fake("AXMenu", size: nil, items)])
}

func fakeMenuItem(_ title: String, enabled: Bool? = nil, submenu: [FakeElement]? = nil) -> FakeElement {
    fake("AXMenuItem", title: title, enabled: enabled, actions: ["AXPress"], submenu.map { [fake("AXMenu", size: nil, $0)] } ?? [])
}

// MARK: - The system

final class FakeAccessibility: AccessibilitySystem, @unchecked Sendable {
    private let lock = NSLock()
    var trusted = true
    var apps: [RunningAppInfo] = []
    var roots: [Int32: FakeElement] = [:]
    /// The process in front, as `frontmostPID()` reports it.
    var frontmost: Int32?
    /// What `secondsSinceUserInput()` reports: infinite means the user is idle.
    var userIdle: TimeInterval = .infinity
    /// Answers `hitTest`; nil result means nothing there.
    var hitHandler: (@Sendable (AccessibilityApp, CGPoint) -> FakeElement?)?
    /// What the window server lists per process (`windowList`); empty by default, like a list that has nothing for the app.
    var listedWindows: [Int32: [CapturableWindow]] = [:]
    private var rootRequests = 0
    private var activations: [Int32] = []
    private var hits: [CGPoint] = []

    let axEvents = FakeAccessibilityEvents()
    let syntheticInput = FakeSyntheticInput()
    let windowCapturer = FakeWindowCapturer()
    let screenOwner = FakeScreenOwner()

    var rootCalls: Int { lock.withLock { rootRequests } }
    var activated: [Int32] { lock.withLock { activations } }
    /// The points `hitTest` was asked about.
    var hitTests: [CGPoint] { lock.withLock { hits } }

    func isTrusted() -> Bool { trusted }
    func runningApps() async -> [RunningAppInfo] { apps }
    func root(of app: AccessibilityApp) -> any AccessibilityElement {
        lock.withLock { rootRequests += 1 }
        return roots[app.pid] ?? fake("AXApplication", size: nil)
    }
    func activate(_ app: AccessibilityApp) { lock.withLock { activations.append(app.pid) } }
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)? {
        lock.withLock { hits.append(point) }
        return hitHandler?(app, point)
    }
    func frontmostPID() async -> Int32? { frontmost }
    func windowList(pid: Int32) -> [CapturableWindow] { listedWindows[pid] ?? [] }
    func secondsSinceUserInput() -> TimeInterval { userIdle }

    var events: any AccessibilityEvents { axEvents }
    var input: any SyntheticInput { syntheticInput }
    var capturer: any WindowCapturer { windowCapturer }
    var screen: any ScreenOwner { screenOwner }

    static func app(_ name: String, _ bundleID: String, pid: Int32, active: Bool = false) -> RunningAppInfo {
        RunningAppInfo(name: name, bundleID: bundleID, pid: pid, isActive: active, isHidden: false, isRegular: true)
    }
}

// MARK: - Notifications

/// Notifications the test decides to send.
final class FakeAccessibilityEvents: AccessibilityEvents, @unchecked Sendable {
    private struct Subscription {
        var id: Int
        var pid: Int32
        var notifications: Set<AXNotification>
        var element: (any AccessibilityElement)?
        var continuation: AsyncStream<AXEvent>.Continuation
    }

    private let lock = NSLock()
    private var subscriptions: [Subscription] = []
    private var nextID = 0
    private var requested: [(pid: Int32, notifications: Set<AXNotification>)] = []
    /// When false the stream finishes at once, like an app that does not support notifications.
    var available = true

    /// Subscriptions whose stream is still being iterated.
    var activeSubscriptions: Int { lock.withLock { subscriptions.count } }
    /// Every call to `events(pid:_:on:)`, in order.
    var requests: [(pid: Int32, notifications: Set<AXNotification>)] { lock.withLock { requested } }

    func events(pid: Int32, _ notifications: Set<AXNotification>, on element: (any AccessibilityElement)?) -> AsyncStream<AXEvent> {
        lock.withLock { requested.append((pid, notifications)) }
        guard available else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream.makeStream(of: AXEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = lock.withLock { () -> Int in
            nextID += 1
            subscriptions.append(Subscription(id: nextID, pid: pid, notifications: notifications, element: element, continuation: continuation))
            return nextID
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock { subscriptions.removeAll { $0.id == id } }
        }
        return stream
    }

    /// Delivers `event` to every matching subscription.
    func emit(_ event: AXEvent) {
        let targets = lock.withLock { subscriptions }.filter { subscription in
            guard subscription.pid == event.pid, subscription.notifications.contains(event.notification) else { return false }
            guard let wanted = subscription.element else { return true }
            return event.element.map { wanted.isSame(as: $0) } ?? false
        }
        for target in targets { target.continuation.yield(event) }
    }

    func emit(_ notification: AXNotification, pid: Int32, element: (any AccessibilityElement)? = nil) {
        emit(AXEvent(notification, pid: pid, element: element))
    }

    /// Ends every stream, like the app quitting.
    func finishAll() {
        let all = lock.withLock { () -> [Subscription] in
            defer { subscriptions.removeAll() }
            return subscriptions
        }
        for subscription in all { subscription.continuation.finish() }
    }
}

// MARK: - Synthetic input

/// Records what would have been sent to an app.
final class FakeSyntheticInput: SyntheticInput, @unchecked Sendable {
    enum Event: Equatable {
        case keys([KeyStroke], pid: Int32)
        case text(String, pid: Int32)
        case click(CGPoint, window: UInt32, button: MouseButton, count: Int, pid: Int32)
        case scroll(dx: Int, dy: Int, at: CGPoint, window: UInt32, pid: Int32)
    }

    private let lock = NSLock()
    private var log: [Event] = []
    private var secure = false
    private var failure: (any Error)?
    /// Characters per chunk of `text`; the real implementation sends at most 20 UTF-16 units at a time.
    var chunkSize = 20
    /// Runs before every call is recorded (or fails), like the app reacting to the event as it arrives.
    var beforeEach: (@Sendable () -> Void)?

    var secureInputActive: Bool {
        get { lock.withLock { secure } }
        set { lock.withLock { secure = newValue } }
    }

    /// Every call after this throws `error` (and records nothing); nil to stop.
    var error: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var events: [Event] { lock.withLock { log } }
    /// Everything typed to `pid`, in order.
    func typed(to pid: Int32) -> String {
        events.compactMap { if case .text(let text, pid) = $0 { text } else { nil } }.joined()
    }

    private func record(_ event: Event) throws {
        beforeEach?()
        try lock.withLock {
            if let failure { throw failure }
            log.append(event)
        }
    }

    func keys(_ strokes: [KeyStroke], to pid: Int32) async throws { try record(.keys(strokes, pid: pid)) }

    func text(_ text: String, to pid: Int32) async throws -> Int {
        beforeEach?()
        if let failure = error { throw failure }
        var sent = 0
        var rest = Substring(text)
        while !rest.isEmpty {
            // Like the real thing: stop between chunks when cancelled, and say how much went out.
            if Task.isCancelled { break }
            let chunk = String(rest.prefix(chunkSize))
            try record(.text(chunk, pid: pid))
            sent += chunk.count
            rest = rest.dropFirst(chunk.count)
            await Task.yield()
        }
        return sent
    }

    func click(at point: CGPoint, window: UInt32, button: MouseButton, count: Int, to pid: Int32) async throws {
        try record(.click(point, window: window, button: button, count: count, pid: pid))
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint, window: UInt32, to pid: Int32) async throws {
        try record(.scroll(dx: dx, dy: dy, at: point, window: window, pid: pid))
    }
}

// MARK: - Window capture

/// Windows and images made up by the test.
final class FakeWindowCapturer: WindowCapturer, @unchecked Sendable {
    struct Capture: Equatable {
        var windowID: UInt32
        var maxSide: Int
    }

    private let lock = NSLock()
    private var byPID: [Int32: [CapturableWindow]] = [:]
    private var failure: (any Error)?
    private var taken: [Capture] = []
    /// Pixels per point of the images made.
    var scale: CGFloat = 2

    func setWindows(_ windows: [CapturableWindow], pid: Int32) { lock.withLock { byPID[pid] = windows } }
    var error: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var captures: [Capture] { lock.withLock { taken } }

    func windows(pid: Int32) async throws -> [CapturableWindow] {
        try lock.withLock {
            if let failure { throw failure }
            return byPID[pid] ?? []
        }
    }

    func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage {
        try lock.withLock {
            if let failure { throw failure }
            taken.append(Capture(windowID: window.windowID, maxSide: maxSide))
        }
        var width = max(1, Int((window.frame.width * scale).rounded()))
        var height = max(1, Int((window.frame.height * scale).rounded()))
        let longest = max(width, height)
        if longest > maxSide {
            width = max(1, width * maxSide / longest)
            height = max(1, height * maxSide / longest)
        }
        return try Self.image(width: width, height: height)
    }

    /// A diagonal gradient of the given pixel size: not blank, and the same every time.
    static func image(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1)]
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])
        else { throw ToolError("O teste não conseguiu criar a imagem.") }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        guard let image = context.makeImage() else { throw ToolError("O teste não conseguiu criar a imagem.") }
        return image
    }
}

// MARK: - Taking the screen over

/// The real mouse and keyboard of a takeover, recording what the body asked of them.
final class FakeTakeoverHand: TakeoverHand, @unchecked Sendable {
    enum Action: Equatable {
        case click(CGPoint, button: MouseButton, count: Int)
        case type(String)
        case key(KeyStroke)
        case drag(from: CGPoint, to: CGPoint)
    }

    private let lock = NSLock()
    private var log: [Action] = []
    var actions: [Action] { lock.withLock { log } }

    private func record(_ action: Action) { lock.withLock { log.append(action) } }
    func click(at point: CGPoint, button: MouseButton, count: Int) async throws { record(.click(point, button: button, count: count)) }
    func type(_ text: String) async throws { record(.type(text)) }
    func key(_ stroke: KeyStroke) async throws { record(.key(stroke)) }
    func drag(from start: CGPoint, to end: CGPoint) async throws { record(.drag(from: start, to: end)) }
}

/// Records taking the screen and giving it back, also when the body throws or the task is cancelled.
final class FakeScreenOwner: ScreenOwner, @unchecked Sendable {
    enum Step: Equatable {
        case took(pid: Int32, windowGiven: Bool, limit: Duration)
        /// Restoration ran; `cancelled` says whether the task was cancelled by then.
        case restored(cancelled: Bool)
    }

    private let lock = NSLock()
    private var log: [Step] = []
    private var failure: (any Error)?
    let hand = FakeTakeoverHand()
    /// What the report says was put back in front.
    var restoredApp: String? = "Safari"
    var cursorRestored = true
    /// The report says the person's app could not be put back in front.
    var restoreFailed = false

    var steps: [Step] { lock.withLock { log } }
    var takes: Int { steps.filter { if case .took = $0 { true } else { false } }.count }
    var restores: Int { steps.filter { if case .restored = $0 { true } else { false } }.count }
    /// Refuses every takeover with `error` (for example "another one is running"); nil to stop.
    var error: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    private func record(_ step: Step) { lock.withLock { log.append(step) } }

    func takeOver<Value: Sendable>(_ app: AccessibilityApp, window: (any AccessibilityElement)?, limit: Duration,
                                   _ body: @escaping @Sendable (any TakeoverHand) async throws -> Value) async throws -> TakeoverReport<Value> {
        if let failure = error { throw failure }
        record(.took(pid: app.pid, windowGiven: window != nil, limit: limit))
        let clock = ContinuousClock()
        let started = clock.now
        let outcome: Result<Value, any Error>
        do { outcome = .success(try await body(hand)) } catch { outcome = .failure(error) }
        let cancelled = Task.isCancelled
        // Restoration cannot be cancelled: it runs in its own task, which is awaited whatever happened to this one.
        await Task.detached { [self] in record(.restored(cancelled: cancelled)) }.value
        let value = try outcome.get()
        return TakeoverReport(value: value, duration: started.duration(to: clock.now), restoredApp: restoredApp, cursorRestored: cursorRestored,
                              restoreFailed: restoreFailed)
    }
}
