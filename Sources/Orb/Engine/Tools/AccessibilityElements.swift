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
    /// A kind of value this tool does not use (dates, URLs, ranges…).
    case other
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
    func attribute(_ name: String) -> AXAttributeValue?
    /// Several attributes at once (one round trip to the app in the real implementation).
    func attributes(_ names: [String]) -> [String: AXAttributeValue]
    func actionNames() -> [String]
    func isSettable(_ name: String) -> Bool
    func perform(_ action: String) throws
    func setValue(_ value: AXAttributeValue, for name: String) throws
}

extension AccessibilityElement {
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
    /// Brings the app to the front (menus of an app in the background can ignore a click).
    func activate(_ app: AccessibilityApp)
}

extension AccessibilitySystem {
    func prepare(_ root: any AccessibilityElement) {}
}

// MARK: - The real thing

struct LiveAccessibilitySystem: AccessibilitySystem {
    /// How long one call may wait for the app before failing instead of hanging the tool.
    static let messagingTimeout: Float = 2

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func runningApps() async -> [RunningAppInfo] {
        await MainActor.run { RunningAppInfo.current(includeBackground: true) }
    }

    func root(of app: AccessibilityApp) -> any AccessibilityElement {
        let ref = AXUIElementCreateApplication(app.pid)
        // The timeout set on the application element holds for the calls on its children too.
        AXUIElementSetMessagingTimeout(ref, Self.messagingTimeout)
        return LiveAccessibilityElement(ref)
    }

    func prepare(_ root: any AccessibilityElement) {
        // Electron and Chromium apps build their accessibility tree only for a client that asks (VoiceOver does it
        // through this attribute); other apps ignore it.
        try? root.setValue(.bool(true), for: "AXManualAccessibility")
    }

    func activate(_ app: AccessibilityApp) {
        _ = NSRunningApplication(processIdentifier: app.pid)?.activate()
    }
}

/// An `AXUIElement`. The reference is only a handle, and the API may be called from any thread (one call sequence at a
/// time per tool run, which the tools keep), hence `@unchecked`.
struct LiveAccessibilityElement: AccessibilityElement, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    func attribute(_ name: String) -> AXAttributeValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &raw) == .success, let raw else { return nil }
        return Self.convert(raw)
    }

    func attributes(_ names: [String]) -> [String: AXAttributeValue] {
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

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, name as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: String) throws {
        try Self.check(AXUIElementPerformAction(ref, action as CFString))
    }

    func setValue(_ value: AXAttributeValue, for name: String) throws {
        let converted: CFTypeRef
        switch value {
        case .string(let text): converted = text as CFString
        case .number(let number): converted = NSNumber(value: number)
        case .bool(let flag): converted = NSNumber(value: flag)
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
            default:
                break
            }
        }
        return .other
    }
}
