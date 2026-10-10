import AppKit
import ApplicationServices

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
}

extension AccessibilityElement {
    var pid: Int32? { nil }

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
    /// The top of an app's interface (`AXUIElementCreateApplication`).
    func root(of app: AccessibilityApp) -> any AccessibilityElement
    /// Asks the app to build its interface tree if it does so only on demand. May wait on the app: call it off the main actor.
    func prepare(_ root: any AccessibilityElement)
    /// The deepest element of the app at a point in screen coordinates (`AXUIElementCopyElementAtPosition`, z-ordered:
    /// nil for a covered window).
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)?
    /// The process in front, if any.
    func frontmostPID() async -> Int32?
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
    func prepare(_ root: any AccessibilityElement) {}
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)? { nil }
    func frontmostPID() async -> Int32? { nil }
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

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func runningApps() async -> [RunningAppInfo] {
        await MainActor.run { RunningAppInfo.current(includeBackground: true) }
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
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
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
            return Dictionary(uniqueKeysWithValues: names.compactMap { name in attribute(name).map { (name, $0) } })
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
            var result: [String: AXAttributeValue] = [:]
            for name in names {
                var single: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(ref, name as CFString, &single)
                if let failure = Self.fatal(error) { return .failed(failure) }
                if error == .success, let single { result[name] = Self.convert(single) }
            }
            return .values(result)
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

    /// The errors that mean the app, not the attribute, is the problem.
    private static func fatal(_ error: AXError) -> AXFailure? {
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

    private static func convert(_ raw: CFTypeRef) -> AXAttributeValue {
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
