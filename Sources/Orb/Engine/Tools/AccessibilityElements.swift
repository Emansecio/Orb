import AppKit
import ApplicationServices
import os

// The Accessibility API behind a small protocol, so `ui_read` and `ui_act` run against a fake tree in tests and the
// real calls live in one place. Attribute and action names are the API's own strings ("AXRole", "AXPress"): the
// `kAX…` globals are not usable under Swift 6 concurrency checking.

/// What an attribute holds.
enum AXAttributeValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case element(any AccessibilityElement)
    case elements([any AccessibilityElement])
    case point(CGPoint)
    case size(CGSize)
    /// A text range (`AXSelectedTextRange`, `AXVisibleCharacterRange`).
    case range(AXTextRange)
    /// A kind of value this tool does not use (dates, URLs…).
    case other
}

/// A span of characters in a text element: `location` is the offset of the first one (negative when the API says "none").
struct AXTextRange: Sendable, Equatable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Why an Accessibility call failed, reduced to what the tools tell the model.
enum AXFailure: Error, Equatable, Sendable {
    /// macOS says this process is not allowed to use the Accessibility API (the permission was turned off).
    case apiDisabled
    /// The app did not answer within the timeout, or is busy (a modal dialog, a hang).
    case cannotComplete
    /// The element has no such attribute or action, or the attribute cannot be set.
    case notSupported
    /// The element is gone (its window closed, the view was rebuilt).
    case invalidElement
    case other(Int32)
}

/// One node of an app's interface. Reads never throw: an attribute the element lacks is nil.
protocol AccessibilityElement: Sendable {
    /// The process that owns the element (`AXUIElementGetPid`); nil when it cannot be told.
    var pid: Int32? { get }
    func attribute(_ name: String) -> AXAttributeValue?
    /// Several attributes at once (one round trip to the app in the real implementation).
    func attributes(_ names: [String]) -> [String: AXAttributeValue]
    func actionNames() -> [String]
    func isSettable(_ name: String) -> Bool
    func perform(_ action: String) throws
    func setValue(_ value: AXAttributeValue, for name: String) throws
    /// Whether both handles are the same element (`CFEqual`), which the tools use to confirm an element is still the one
    /// a snapshot named.
    func isSame(as other: any AccessibilityElement) -> Bool
    /// Like `attributes(_:)`, but a call the app fails to answer is reported instead of looking like "no attributes".
    func read(_ names: [String]) -> AXRead
    /// For a window, its `CGWindowID` as the window server knows it (what ScreenCaptureKit and the window list use); nil
    /// for other elements, or when it cannot be told. Asks the Accessibility server only, not the app.
    var windowID: UInt32? { get }
}

extension AccessibilityElement {
    var pid: Int32? { nil }
    var windowID: UInt32? { nil }

    /// Identity for class-based elements; value types cannot be told apart without help.
    func isSame(as other: any AccessibilityElement) -> Bool {
        guard type(of: self) is AnyClass, type(of: other) is AnyClass else { return false }
        return (self as AnyObject) === (other as AnyObject)
    }

    func read(_ names: [String]) -> AXRead { .values(attributes(names)) }

    func attributes(_ names: [String]) -> [String: AXAttributeValue] {
        var result: [String: AXAttributeValue] = [:]
        for name in names { if let value = attribute(name) { result[name] = value } }
        return result
    }

    func string(_ name: String) -> String? { attribute(name)?.string }
    func bool(_ name: String) -> Bool? { attribute(name)?.bool }
    func element(_ name: String) -> (any AccessibilityElement)? { attribute(name)?.element }

    /// A list of elements (`AXChildren`, `AXWindows`); nil when the element has no such attribute, empty when it is empty.
    func elements(_ name: String) -> [any AccessibilityElement]? { attribute(name)?.elements }
}

extension AXAttributeValue {
    /// Text of a string attribute; nil for other kinds.
    var string: String? { if case .string(let text) = self { text } else { nil } }
    var bool: Bool? {
        switch self {
        case .bool(let flag): flag
        case .number(let number): number != 0
        default: nil
        }
    }
    var element: (any AccessibilityElement)? { if case .element(let element) = self { element } else { nil } }
    var range: AXTextRange? { if case .range(let range) = self { range } else { nil } }
    var elements: [any AccessibilityElement]? {
        switch self {
        case .elements(let list): list
        case .element(let single): [single]
        default: nil
        }
    }
}

/// A running app whose interface can be read.
struct AccessibilityApp: Sendable, Equatable, Codable {
    var name: String
    var bundleID: String?
    var pid: Int32
    /// When the process started: with the pid and bundle identifier it tells a running app from a new one that reused
    /// the pid. Nil when unknown (old snapshots).
    var launchDate: Date?

    init(name: String, bundleID: String?, pid: Int32, launchDate: Date? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.launchDate = launchDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: "")
        bundleID = try? c.decodeIfPresent(String.self, forKey: .bundleID)
        pid = try c.decode(Int32.self, forKey: .pid)
        launchDate = try? c.decodeIfPresent(Date.self, forKey: .launchDate)
    }
}

/// The calls into macOS, injectable so the tools are tested without touching the real Accessibility API.
protocol AccessibilitySystem: Sendable {
    /// Whether this process may use the Accessibility API. Never shows the system prompt.
    func isTrusted() -> Bool
    func runningApps() async -> [RunningAppInfo]
    /// The same list; with `withFrontmost` false, `isActive` is not filled in, which spares asking apps which one is in
    /// front (a hung app on top makes that wait). For finding an app by name.
    func runningApps(withFrontmost: Bool) async -> [RunningAppInfo]
    /// The top of an app's interface (`AXUIElementCreateApplication`).
    func root(of app: AccessibilityApp) -> any AccessibilityElement
    /// Asks the app to build its interface tree if it does so only on demand. May wait on the app: call it off the main actor.
    func prepare(_ root: any AccessibilityElement)
    /// The deepest element of the app at a point in screen coordinates (`AXUIElementCopyElementAtPosition`, z-ordered:
    /// nil for a covered window).
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)?
    /// The process in front, if any.
    func frontmostPID() async -> Int32?
    /// The windows of a process as the window server lists them (number, owner, frame; the title only with Screen
    /// Recording), in any Space. Needs no permission: N1 events find their window here.
    func windowList(pid: Int32) -> [CapturableWindow]
    /// Seconds since the user last pressed a key or a mouse button. Infinite when unknown.
    func secondsSinceUserInput() -> TimeInterval
    /// Notifications from an app (`AXObserver`).
    var events: any AccessibilityEvents { get }
    /// Keyboard, mouse and scroll events sent to one process.
    var input: any SyntheticInput { get }
    /// Window images.
    var capturer: any WindowCapturer { get }
    /// Taking the screen over for what only real input can do.
    var screen: any ScreenOwner { get }
}

extension AccessibilitySystem {
    func runningApps(withFrontmost: Bool) async -> [RunningAppInfo] { await runningApps() }
    func prepare(_ root: any AccessibilityElement) {}
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)? { nil }
    func frontmostPID() async -> Int32? { nil }
    func windowList(pid: Int32) -> [CapturableWindow] { [] }
    func secondsSinceUserInput() -> TimeInterval { .infinity }
    var events: any AccessibilityEvents { UnavailableAccessibilityEvents() }
    var input: any SyntheticInput { UnavailableSyntheticInput() }
    var capturer: any WindowCapturer { UnavailableWindowCapturer() }
    var screen: any ScreenOwner { UnavailableScreenOwner() }
}

// MARK: - The real thing

struct LiveAccessibilitySystem: AccessibilitySystem {
    /// How long one call may wait for the app before failing instead of hanging the tool, in seconds.
    static let messagingTimeout: Float = 1

    /// The timeout set on an element holds only for that element (`AXUIElement.h`); the one set on the system-wide
    /// element is the default for every other. Set once per process (the app and the tools server Claude Code starts).
    private static let globalTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    /// Which apps run and which is in front, read anew on every call (never NSWorkspace's lists: see `LiveDesktop`).
    var desktop = LiveDesktop()

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func runningApps() async -> [RunningAppInfo] {
        let desktop = desktop
        return await LiveDesktop.offPool { desktop.runningApps() }
    }

    func runningApps(withFrontmost: Bool) async -> [RunningAppInfo] {
        guard !withFrontmost else { return await runningApps() }
        let desktop = desktop
        return await LiveDesktop.offPool { desktop.processes() }
    }

    func root(of app: AccessibilityApp) -> any AccessibilityElement {
        _ = Self.globalTimeout
        let ref = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(ref, Self.messagingTimeout)
        return LiveAccessibilityElement(ref)
    }

    func prepare(_ root: any AccessibilityElement) {
        // Electron and Chromium apps build their accessibility tree only for a client that asks (VoiceOver does it
        // through this attribute); other apps ignore it. Never AXEnhancedUserInterface: it slows the app and animates.
        try? root.setValue(.bool(true), for: "AXManualAccessibility")
    }

    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)? {
        LiveAccessibilityElement.offMain()
        guard let root = root(of: app) as? LiveAccessibilityElement else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root.ref, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        return LiveAccessibilityElement(hit)
    }

    var events: any AccessibilityEvents { AXEventHub.shared }

    func frontmostPID() async -> Int32? {
        let desktop = desktop
        return await LiveDesktop.offPool { desktop.frontmost() }
    }

    func windowList(pid: Int32) -> [CapturableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self.windows(in: info, pid: pid)
    }

    /// The normal-layer windows of `pid` in a window-server listing.
    static func windows(in info: [[String: Any]], pid: Int32) -> [CapturableWindow] {
        WindowServerList.parse(info).filter { $0.pid == pid }
    }

    var screen: any ScreenOwner { LiveScreenOwner(events: events) }

    func secondsSinceUserInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    var input: any SyntheticInput { LiveSyntheticInput.shared }
    var capturer: any WindowCapturer { LiveWindowCapturer.shared }
}

/// An `AXUIElement`. The reference is only a handle, and the API may be called from any thread (one call sequence at a
/// time per tool run, which the tools keep), hence `@unchecked`.
struct LiveAccessibilityElement: AccessibilityElement, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    /// Every call below waits on another process: never on the main thread, where a hung app would freeze the Orb.
    @inline(__always) static func offMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    var pid: Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    /// `_AXUIElementGetWindow`: not in the public headers, but what every window manager uses to tie an Accessibility
    /// window to its `CGWindowID`. Looked up at run time, so a macOS without it only loses the shortcut (windows are then
    /// matched by frame and title).
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindowFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    var windowID: UInt32? {
        guard let getWindow = Self.getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(ref, &id) == .success && id != 0 ? id : nil
    }

    func isSame(as other: any AccessibilityElement) -> Bool {
        guard let other = other as? LiveAccessibilityElement else { return false }
        return CFEqual(ref, other.ref)
    }

    func attribute(_ name: String) -> AXAttributeValue? {
        Self.offMain()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &raw) == .success, let raw else { return nil }
        return Self.convert(raw)
    }

    func attributes(_ names: [String]) -> [String: AXAttributeValue] {
        Self.offMain()
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(ref, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard status == .success, let values = raw as? [AnyObject], values.count == names.count else {
            // A hung app is not asked again name by name (each would wait the whole timeout).
            if Self.fatal(status) != nil { return [:] }
            return Self.oneByOne(names) { name in
                var single: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(ref, name as CFString, &single)
                return (error, single.map(Self.convert))
            }.values
        }
        var result: [String: AXAttributeValue] = [:]
        for (name, item) in zip(names, values) {
            // An attribute the element lacks comes back as an AXValue of type "error", not as a missing entry.
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError { continue }
            result[name] = Self.convert(item)
        }
        return result
    }

    func read(_ names: [String]) -> AXRead {
        Self.offMain()
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(ref, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        if let failure = Self.fatal(status) { return .failed(failure) }
        guard status == .success, let items = raw as? [AnyObject], items.count == names.count else {
            // The batch call is not supported by this element: ask one by one, still reporting a dead or hung app.
            let found = Self.oneByOne(names) { name in
                var single: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(ref, name as CFString, &single)
                return (error, single.map(Self.convert))
            }
            if let failure = found.failure { return .failed(failure) }
            return .values(found.values)
        }
        var result: [String: AXAttributeValue] = [:]
        for (name, item) in zip(names, items) {
            if CFGetTypeID(item) == AXValueGetTypeID() {
                let value = unsafeDowncast(item, to: AXValue.self)
                if AXValueGetType(value) == .axError {
                    // A missing attribute is an error value in its slot; a hung or dead app is not "missing".
                    var error = AXError.success
                    if AXValueGetValue(value, .axError, &error), let failure = Self.fatal(error) { return .failed(failure) }
                    continue
                }
            }
            result[name] = Self.convert(item)
        }
        return .values(result)
    }

    /// Asks for each attribute in turn and stops at the first answer that says the app (not the attribute) is the problem:
    /// a hung app costs one timeout, not one per name.
    static func oneByOne(_ names: [String], _ ask: (String) -> (AXError, AXAttributeValue?)) -> (values: [String: AXAttributeValue], failure: AXFailure?) {
        var result: [String: AXAttributeValue] = [:]
        for name in names {
            let (error, value) = ask(name)
            if let failure = fatal(error) { return (result, failure) }
            if error == .success, let value { result[name] = value }
        }
        return (result, nil)
    }

    /// The errors that mean the app, not the attribute, is the problem.
    static func fatal(_ error: AXError) -> AXFailure? {
        switch error {
        case .apiDisabled: .apiDisabled
        case .cannotComplete: .cannotComplete
        case .invalidUIElement: .invalidElement
        default: nil
        }
    }

    func actionNames() -> [String] {
        Self.offMain()
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func isSettable(_ name: String) -> Bool {
        Self.offMain()
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, name as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: String) throws {
        Self.offMain()
        try Self.check(AXUIElementPerformAction(ref, action as CFString))
    }

    func setValue(_ value: AXAttributeValue, for name: String) throws {
        Self.offMain()
        let converted: CFTypeRef
        switch value {
        case .string(let text): converted = text as CFString
        case .number(let number): converted = NSNumber(value: number)
        case .bool(let flag): converted = NSNumber(value: flag)
        case .range(let range):
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let boxed = AXValueCreate(.cfRange, &cfRange) else { throw AXFailure.notSupported }
            converted = boxed
        case .elements(let list):
            converted = list.compactMap { ($0 as? LiveAccessibilityElement)?.ref } as CFArray
        case .element(let element):
            guard let live = element as? LiveAccessibilityElement else { throw AXFailure.notSupported }
            converted = live.ref
        default: throw AXFailure.notSupported
        }
        try Self.check(AXUIElementSetAttributeValue(ref, name as CFString, converted))
    }

    private static func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .apiDisabled: throw AXFailure.apiDisabled
        case .cannotComplete: throw AXFailure.cannotComplete
        case .actionUnsupported, .attributeUnsupported, .notImplemented, .illegalArgument: throw AXFailure.notSupported
        case .invalidUIElement: throw AXFailure.invalidElement
        default: throw AXFailure.other(error.rawValue)
        }
    }

    static func convert(_ raw: CFTypeRef) -> AXAttributeValue {
        let type = CFGetTypeID(raw)
        if type == CFStringGetTypeID() { return .string(unsafeDowncast(raw, to: CFString.self) as String) }
        if type == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue(unsafeDowncast(raw, to: CFBoolean.self))) }
        if type == CFNumberGetTypeID() { return .number((unsafeDowncast(raw, to: CFNumber.self) as NSNumber).doubleValue) }
        if type == AXUIElementGetTypeID() { return .element(LiveAccessibilityElement(unsafeDowncast(raw, to: AXUIElement.self))) }
        if type == CFArrayGetTypeID() {
            let items = (raw as? [AnyObject]) ?? []
            let elements = items.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
                .map { LiveAccessibilityElement(unsafeDowncast($0, to: AXUIElement.self)) }
            return .elements(elements)
        }
        if type == AXValueGetTypeID() {
            let value = unsafeDowncast(raw, to: AXValue.self)
            switch AXValueGetType(value) {
            case .cgPoint:
                var point = CGPoint.zero
                if AXValueGetValue(value, .cgPoint, &point) { return .point(point) }
            case .cgSize:
                var size = CGSize.zero
                if AXValueGetValue(value, .cgSize, &size) { return .size(size) }
            case .cfRange:
                var range = CFRange()
                if AXValueGetValue(value, .cfRange, &range) { return .range(AXTextRange(location: range.location, length: range.length)) }
            default:
                break
            }
        }
        return .other
    }
}

// MARK: - Which apps run, and which is in front

/// The running apps and the app in front, read anew on every call. Never `NSWorkspace`'s `runningApplications` or
/// `frontmostApplication`: they learn of changes only through the main run loop, which the Claude Code tools server (a
/// `dispatchMain()` process) does not run, so there they go stale. The app in front comes from the window list (the owner
/// of the top window of the normal layer: needs no answer from any app), checked against that app's own `AXFrontmost`, and
/// the other apps' `AXFrontmost` one by one when the top window is not the front app's; the system-wide
/// `AXFocusedApplication` is not used (it fails with "cannot complete" while an Electron app is in front). The same reading
/// serves `ui_act` (in both processes) and the takeover (`LiveTakeoverPlatform`).
struct LiveDesktop: Sendable {
    /// The owner of the top-most visible window of the normal layer.
    var topWindowOwner: @Sendable () -> Int32? = LiveDesktop.liveTopWindowOwner
    /// An app's own answer to "are you in front"; nil when it does not answer.
    var isFrontmost: @Sendable (Int32) -> Bool? = LiveDesktop.liveIsFrontmost
    /// The processes that are apps (`isActive` not filled in), enumerated anew.
    var processes: @Sendable () -> [RunningAppInfo] = LiveDesktop.liveProcesses

    /// The app in front. Blocking (it may ask apps): call it off the main thread and off the cooperative pool.
    func frontmost() -> Int32? { frontmost(among: nil) }

    /// Every app, with `isActive` set on the one in front.
    func runningApps() -> [RunningAppInfo] {
        var apps = processes()
        let front = frontmost(among: apps)
        for index in apps.indices { apps[index].isActive = apps[index].pid == front }
        return apps
    }

    private func frontmost(among known: [RunningAppInfo]?) -> Int32? {
        let candidate = topWindowOwner()
        if let candidate {
            switch isFrontmost(candidate) {
            case true?, nil: return candidate
            case false?: break
            }
        }
        for app in known ?? processes() where app.isRegular && app.pid != candidate {
            if isFrontmost(app.pid) == true { return app.pid }
        }
        return candidate
    }

    /// Runs blocking work on a GCD thread (never the main thread, never a thread of the cooperative pool).
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static let liveTopWindowOwner: @Sendable () -> Int32? = {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0, (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let pid = window[kCGWindowOwnerPID as String] as? Int else { continue }
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            if let bounds, bounds.width < 40 || bounds.height < 40 { continue }
            return Int32(pid)
        }
        return nil
    }

    /// Apps that let the question time out, and when: they are not asked again for `unresponsiveFor` (each asking would
    /// wait the half second again, on every action, while a hung app keeps its window on top).
    private static let unresponsive = OSAllocatedUnfairLock(initialState: [Int32: ContinuousClock.Instant]())
    static let unresponsiveFor: Duration = .seconds(5)

    static let liveIsFrontmost: @Sendable (Int32) -> Bool? = { pid in
        let now = ContinuousClock.now
        if unresponsive.withLock({ $0[pid].map { now - $0 < unresponsiveFor } ?? false }) { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXFrontmost" as CFString, &raw)
        unresponsive.withLock { $0[pid] = status == .cannotComplete ? ContinuousClock.now : nil }
        guard status == .success, let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(raw, to: CFBoolean.self))
    }

    /// Every process (`proc_listallpids`) that Launch Services knows as an app, each `NSRunningApplication` made fresh for
    /// this call (a few milliseconds for the whole Mac).
    static let liveProcesses: @Sendable () -> [RunningAppInfo] = {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid -> RunningAppInfo? in
            guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let name = app.localizedName else { return nil }
            return RunningAppInfo(name: name, bundleID: app.bundleIdentifier, pid: pid, isActive: false, isHidden: app.isHidden,
                                  isRegular: app.activationPolicy == .regular, launchDate: app.launchDate)
        }
    }
}
