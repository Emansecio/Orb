import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// macOS privacy permissions (TCC) as the Orb sees them: what is granted, how to ask, how to explain a failure.
// Nothing here prompts unless a function is named `request…`; the blocking system calls always run off the main actor.

// MARK: - What can be granted

/// An app the Orb controls with Apple Events, as the user knows it.
struct AutomationTarget: Hashable, Sendable, Identifiable {
    /// The name shown to the user (pt-BR).
    var name: String
    var bundleID: String
    /// Other names a script may use for the same app (English, localized, abbreviated), compared ignoring case and accents.
    var aliases: [String] = []

    var id: String { bundleID }

    /// The apps the settings tab lists, in display order.
    static let known: [AutomationTarget] = [
        AutomationTarget(name: "Mail", bundleID: "com.apple.mail"),
        AutomationTarget(name: "Calendário", bundleID: "com.apple.iCal", aliases: ["Calendar", "iCal"]),
        AutomationTarget(name: "Notas", bundleID: "com.apple.Notes", aliases: ["Notes"]),
        AutomationTarget(name: "Lembretes", bundleID: "com.apple.reminders", aliases: ["Reminders"]),
        AutomationTarget(name: "Finder", bundleID: "com.apple.finder"),
        AutomationTarget(name: "System Events", bundleID: "com.apple.systemevents"),
        AutomationTarget(name: "Mensagens", bundleID: "com.apple.MobileSMS", aliases: ["Messages"]),
        AutomationTarget(name: "Safari", bundleID: "com.apple.Safari"),
        AutomationTarget(name: "Música", bundleID: "com.apple.Music", aliases: ["Music"]),
    ]

    /// Apps scripts name often that the tab does not list; they still get the pre-flight consent.
    private static let alsoKnown: [AutomationTarget] = [
        AutomationTarget(name: "Contatos", bundleID: "com.apple.AddressBook", aliases: ["Contacts"]),
        AutomationTarget(name: "Google Chrome", bundleID: "com.google.Chrome", aliases: ["Chrome"]),
        AutomationTarget(name: "Brave Browser", bundleID: "com.brave.Browser", aliases: ["Brave"]),
        AutomationTarget(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", aliases: ["Edge"]),
        AutomationTarget(name: "Arc", bundleID: "company.thebrowser.Browser"),
        AutomationTarget(name: "Fotos", bundleID: "com.apple.Photos", aliases: ["Photos"]),
        AutomationTarget(name: "Shortcuts Events", bundleID: "com.apple.shortcuts.events"),
        AutomationTarget(name: "Atalhos", bundleID: "com.apple.shortcuts", aliases: ["Shortcuts"]),
    ]

    /// The target a script's app name or bundle identifier stands for, when it is one of the well-known apps.
    static func known(named scriptName: String) -> AutomationTarget? {
        let wanted = fold(scriptName)
        return (known + alsoKnown).first { target in
            ([target.name, target.bundleID] + target.aliases).contains { fold($0) == wanted }
        }
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

enum MacPermissionKind: Hashable, Sendable {
    case automation(AutomationTarget)
    case accessibility
    case screenRecording
    case fullDiskAccess

    var title: String {
        switch self {
        case .automation(let target): target.name
        case .accessibility: "Acessibilidade"
        case .screenRecording: "Gravação de Tela"
        case .fullDiskAccess: "Acesso Total ao Disco"
        }
    }

    var detail: String {
        switch self {
        case .automation(let target):
            switch target.bundleID {
            case "com.apple.systemevents": "Teclado, cliques e janelas de outros apps"
            case "com.apple.finder": "Pastas, arquivos e Lixeira"
            default: "Controlar o \(target.name) quando você pede"
            }
        case .accessibility: "Digitar, clicar e ler a interface de outros apps"
        case .screenRecording: "Ver o que há na tela e nas janelas de outros apps"
        case .fullDiskAccess: "Ler pastas protegidas, como Mail e Mensagens (verificação aproximada)"
        }
    }

    var pane: MacPrivacyPane {
        switch self {
        case .automation: .automation
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .fullDiskAccess: .fullDiskAccess
        }
    }
}

/// The Privacy & Security panes of System Settings the Orb sends the user to.
enum MacPrivacyPane: String, Sendable, CaseIterable {
    case automation = "Privacy_Automation"
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case fullDiskAccess = "Privacy_AllFiles"

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
            ?? URL(filePath: "/System/Applications/System Settings.app")
    }

    @MainActor func open() { NSWorkspace.shared.open(url) }
}

enum MacPermissionStatus: Equatable, Sendable {
    case granted
    /// The user said no (Apple Events -1743).
    case denied
    /// macOS has never asked (Apple Events -1744): asking now shows the system dialog.
    case notDetermined
    /// A yes/no API (Accessibility, Screen Recording, Full Disk Access) said no; macOS does not tell "refused" from "never asked".
    case notGranted
    /// Automation cannot be checked while the target app is closed (-600): open it to know.
    case appNotRunning
    case unknown

    /// Maps what `AEDeterminePermissionToAutomateTarget` returns.
    init(automationStatus status: OSStatus) {
        switch status {
        case 0: self = .granted
        case -1743: self = .denied            // errAEEventNotPermitted
        case -1744: self = .notDetermined     // errAEEventWouldRequireUserConsent
        case -600: self = .appNotRunning      // procNotFound
        default: self = .unknown
        }
    }

    /// Whether asking can show the system dialog. A refusal never shows it again (only System Settings changes it), but the
    /// yes/no APIs cannot tell "refused" from "never asked", so `.notGranted` is offered and the first try tells.
    var canShowSystemPrompt: Bool { self == .notDetermined || self == .notGranted }
}

// MARK: - The system calls

enum MacFileProbe: Sendable { case readable, blocked, missing }

/// The calls into macOS, injectable so status mapping and pre-flight decisions are tested without touching TCC.
/// Every method blocks (the `request…` ones until the user answers), so callers use them off the main actor.
protocol MacPermissionSystem: Sendable {
    /// OSStatus of `AEDeterminePermissionToAutomateTarget`; with `askUserIfNeeded` it may show the consent dialog.
    func automationStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus
    func isAccessibilityTrusted() -> Bool
    /// Shows the system's Accessibility prompt (once per build), then reports whether the app is trusted.
    func requestAccessibility() -> Bool
    func hasScreenRecording() -> Bool
    func requestScreenRecording() -> Bool
    func probe(_ url: URL) -> MacFileProbe
    var homeDirectory: URL { get }
    /// The bundle identifier of a running app called `name` (localized name or file name), if there is one.
    func runningBundleID(named name: String) -> String?
    /// Opens the app without showing it or taking focus, and waits until it is running. False when it cannot be found or
    /// does not start. Automation consent can only be asked of a running app.
    func launchHidden(bundleID: String) -> Bool
}

struct LiveMacPermissionSystem: MacPermissionSystem {
    func launchHidden(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func automationStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
    }

    func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    func requestAccessibility() -> Bool {
        // The literal behind kAXTrustedCheckOptionPrompt (the C global is not usable under Swift 6 concurrency checking).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func hasScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    func probe(_ url: URL) -> MacFileProbe {
        // open(2) works on directories too, and reports the TCC refusal as EPERM.
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .readable
        }
        return errno == EPERM || errno == EACCES ? .blocked : .missing
    }

    var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    func runningBundleID(named name: String) -> String? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.bundleIdentifier != nil else { return false }
            let names = [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0 }
            return names.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted }
        }?.bundleIdentifier
    }
}

// MARK: - Checking

struct MacPermissionChecker: Sendable {
    var system: any MacPermissionSystem = LiveMacPermissionSystem()

    static let live = MacPermissionChecker()

    /// Everything the settings tab shows, in display order.
    static var allKinds: [MacPermissionKind] {
        AutomationTarget.known.map(MacPermissionKind.automation) + [.accessibility, .screenRecording, .fullDiskAccess]
    }

    /// Where the Full Disk Access heuristic looks, relative to the home folder. Both are protected by TCC and exist on
    /// nearly every Mac: the Mail data folder and Safari's bookmarks.
    static let fullDiskProbePaths = ["Library/Mail", "Library/Safari/Bookmarks.plist"]

    // MARK: Blocking checks (run off the main actor)

    /// Never prompts.
    func status(of kind: MacPermissionKind) -> MacPermissionStatus {
        switch kind {
        case .automation(let target):
            MacPermissionStatus(automationStatus: system.automationStatus(bundleID: target.bundleID, askUserIfNeeded: false))
        case .accessibility:
            system.isAccessibilityTrusted() ? .granted : .notGranted
        case .screenRecording:
            system.hasScreenRecording() ? .granted : .notGranted
        case .fullDiskAccess:
            fullDiskAccessStatus()
        }
    }

    /// A heuristic: macOS has no API to ask whether Full Disk Access is on, so this tries to open a protected item.
    /// The first of `fullDiskProbePaths` that exists decides (opened: granted, refused: not granted); when none exists
    /// (no Mail data, no Safari profile) the answer is unknown rather than a guess.
    func fullDiskAccessStatus() -> MacPermissionStatus {
        for path in Self.fullDiskProbePaths {
            switch system.probe(system.homeDirectory.appending(path: path)) {
            case .readable: return .granted
            case .blocked: return .notGranted
            case .missing: continue
            }
        }
        return .unknown
    }

    /// Asks macOS to show its dialog where it can, then reports the new status. Automation blocks until the user
    /// answers (there is no short timeout on purpose); a target that is not running or was already refused shows nothing.
    func request(_ kind: MacPermissionKind) -> MacPermissionStatus {
        switch kind {
        case .automation(let target):
            return MacPermissionStatus(automationStatus: system.automationStatus(bundleID: target.bundleID, askUserIfNeeded: true))
        case .accessibility:
            return system.requestAccessibility() ? .granted : .notGranted
        case .screenRecording:
            return system.requestScreenRecording() ? .granted : .notGranted
        case .fullDiskAccess:
            return status(of: kind)
        }
    }

    /// The target a script's app name stands for: a well-known app, a bundle identifier, or a running app of that name.
    func target(forScriptName name: String) -> AutomationTarget? {
        if let known = AutomationTarget.known(named: name) { return known }
        let bundleID = name.contains(".") && !name.contains(" ") ? name : system.runningBundleID(named: name)
        return bundleID.map { AutomationTarget(name: name, bundleID: $0) }
    }

    // MARK: Off the main actor

    func statuses(of kinds: [MacPermissionKind] = MacPermissionChecker.allKinds) async -> [MacPermissionKind: MacPermissionStatus] {
        await Blocking.run(fallback: [:]) {
            Dictionary(uniqueKeysWithValues: kinds.map { ($0, status(of: $0)) })
        }
    }

    func status(ofInBackground kind: MacPermissionKind) async -> MacPermissionStatus {
        await Blocking.run(fallback: .unknown) { status(of: kind) }
    }

    /// Waits for the user to answer the system dialog, but not forever: `patience` caps the wait.
    func requestInBackground(_ kind: MacPermissionKind, patience: Duration = .seconds(120)) async -> MacPermissionStatus {
        await Blocking.run(fallback: .unknown, timeout: patience) { request(kind) }
    }
}

/// Runs a blocking system call on a background thread and resumes when it returns, when the timeout passes, or when the
/// calling task is cancelled, whichever comes first. A call that outlives all three finishes unobserved on its thread.
enum Blocking {
    static func run<T: Sendable>(fallback: T, timeout: Duration? = nil, _ work: @escaping @Sendable () -> T) async -> T {
        let shot = OneShot<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                shot.install(continuation)
                // Already cancelled: nothing may start, or a system dialog could appear for a call nobody waits for.
                if shot.isFinished { return }
                DispatchQueue.global(qos: .userInitiated).async { shot.finish(work()) }
                if let timeout {
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { shot.finish(fallback) }
                }
            }
        } onCancel: {
            shot.finish(fallback)
        }
    }

    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var result: T?

        var isFinished: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ value: T) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }
    }
}

// MARK: - Failures

/// A privacy permission whose absence made a tool fail, recognized from error codes and messages.
enum MacPermissionProblem: Equatable, Sendable {
    case automation(app: String?)
    case accessibility
    case screenRecording
    case fullDiskAccess

    var pane: MacPrivacyPane {
        switch self {
        case .automation: .automation
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .fullDiskAccess: .fullDiskAccess
        }
    }

    /// The pane's name in System Settings (pt-BR), as the user will see it.
    var paneTitle: String {
        switch self {
        case .automation: "Automação"
        case .accessibility: "Acessibilidade"
        case .screenRecording: "Gravação de Tela"
        case .fullDiskAccess: "Acesso Total ao Disco"
        }
    }

    /// "Ajustes do Sistema → Privacidade e Segurança → Automação". Also how a translated message is recognized again.
    var settingsPath: String { "Privacidade e Segurança → \(paneTitle)" }

    /// What is missing, in English for the model.
    var summary: String {
        switch self {
        case .automation(let app):
            "macOS blocked Orb from controlling \(app ?? "that app"): the Automation permission for it is missing or was denied."
        case .accessibility:
            "macOS blocked Orb from controlling the interface (keystrokes, clicks, windows): the Accessibility permission is missing."
        case .screenRecording:
            "macOS did not let Orb capture the screen: the Screen Recording permission is missing."
        case .fullDiskAccess:
            "macOS blocked Orb from reading a protected folder (Mail, Messages, Safari…): the Full Disk Access permission is missing."
        }
    }

    /// What the model must do about it: tell the user, not retry or work around it.
    var instruction: String {
        let enable: String
        switch self {
        case .automation(let app):
            enable = "turn on \(app ?? "the app") under Orb"
        case .accessibility, .screenRecording, .fullDiskAccess:
            enable = "turn on Orb"
        }
        let restart = switch self {
        case .screenRecording, .fullDiskAccess: " and reopen Orb, because macOS only applies it to a restarted app"
        default: ""
        }
        return "Do not retry and do not try another way around it (another script, the shell, another tool). Tell the user to open "
            + "Ajustes do Sistema → \(settingsPath) and \(enable)\(restart); the Settings tab \"Permissões do Mac\" in Orb has a "
            + "button that opens that pane. Then ask them to request it again."
    }

    /// The whole message a tool returns to the model.
    var modelMessage: String { summary + " " + instruction }

    // MARK: Detection

    /// Recognizes a permission failure in osascript / screencapture / shell output, or in a message Orb itself wrote
    /// with `modelMessage`. Nil when the text is about something else.
    static func detect(in text: String) -> MacPermissionProblem? {
        let lower = text.lowercased()
        let code = AppleScript.errorCode(in: text)

        if code == -1743 || lower.contains("not authorized to send apple events") || text.contains(automation(app: nil).settingsPath) {
            return .automation(app: appName(inAutomationFailure: text))
        }
        if code == -25211 || (code == -1719 && mentionsAssistiveAccess(lower)) || lower.contains("not allowed assistive access")
            || text.contains(accessibility.settingsPath) {
            return .accessibility
        }
        if isProtectedFolderRefusal(text, lowercased: lower) || text.contains(fullDiskAccess.settingsPath) {
            return .fullDiskAccess
        }
        // "from window" is also what a window that closed mid-capture prints, with the permission granted: not a match.
        if lower.contains("could not create image from display") || text.contains(screenRecording.settingsPath) {
            return .screenRecording
        }
        return nil
    }

    /// Only the permission phrases: scripts repeat their own selectors (`whose accessibility description is …`) in -1719 errors.
    private static func mentionsAssistiveAccess(_ lower: String) -> Bool {
        ["assistive access", "acesso assistiv"].contains {
            lower.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Library folders macOS protects with Full Disk Access.
    private static let protectedLibraryFolders = [
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Calendars",
        "Library/Suggestions", "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Group Containers", "Library/HomeKit", "Library/IdentityServices",
        "Library/Metadata/CoreSpotlight", "Library/PersonalizationPortrait", "Library/Trial",
    ]

    /// "Operation not permitted" (EPERM) naming a protected folder under a Library. The same error elsewhere (a SIP-protected
    /// system file, a locked file) is not a permission the user can grant, so a path is required.
    private static func isProtectedFolderRefusal(_ text: String, lowercased lower: String) -> Bool {
        let refused = lower.contains("operation not permitted") || lower.contains("operação não permitida")
            || lower.contains("operacao nao permitida") || lower.contains("eperm")
        return refused && protectedLibraryFolders.contains { text.contains($0) }
    }

    /// The app named by "Not authorized to send Apple events to Mail." (or its Portuguese form), when the text has it.
    private static let appNameExpressions = [
        #"send Apple events to (.+?)\.(?:\s|\(|$)"#, #"eventos (?:da )?Apple (?:para|ao|à) (?:o |a )?(.+?)\.(?:\s|\(|$)"#,
        // Orb's own message (`summary`), when it comes back through a tool result.
        #"blocked Orb from controlling (.+?): the Automation"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func appName(inAutomationFailure text: String) -> String? {
        for regex in appNameExpressions {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let name = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != "that app" { return name }
        }
        return nil
    }
}

extension ToolCall {
    /// The permission to offer a button for. A failed call: whatever its output says. A call that finished: only a computer or
    /// browser tool that carries Orb's own permission text (a screenshot taken without Screen Recording, a browser that refused
    /// Automation while the rest was read), never page or file contents that happen to mention a setting.
    var permissionProblemToShow: MacPermissionProblem? {
        guard let output else { return nil }
        switch state {
        case .failed:
            return MacPermissionProblem.detect(in: output)
        case .done:
            guard kind == .computer || kind == .browser, output.contains("Ajustes do Sistema → Privacidade e Segurança") else { return nil }
            return MacPermissionProblem.detect(in: output)
        case .running:
            return nil
        }
    }
}

// MARK: - AppleScript pre-flight

/// Finds the apps a script talks to and settles their Automation consent before the script runs, so the system dialog
/// does not race the script's timeout.
enum AutomationPreflight {
    /// Names of the apps a script addresses: `tell application "X"`, `application id "…"`, or JXA's `Application("X")`.
    /// Full-line comments are ignored; the result keeps first-seen order without repeats.
    static func appNames(in script: String, language: AppleScript.Language) -> [String] {
        let code = script.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch language {
            case .applescript: return !(trimmed.hasPrefix("--") || trimmed.hasPrefix("#"))
            case .javascript: return !trimmed.hasPrefix("//")
            }
        }.joined(separator: "\n")

        let pattern = switch language {
        // `app`/`application`, optionally `id`, then a quoted name: covers tell blocks, one-liners and "of application".
        case .applescript: #"\bapp(?:lication)?\s+(?:id\s+)?"([^"\n]+)""#
        case .javascript: #"\bApplication\s*\(\s*(?:"([^"\n]+)"|'([^'\n]+)')\s*\)"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: language == .applescript ? [.caseInsensitive] : []) else { return [] }
        let range = NSRange(code.startIndex..., in: code)
        var seen = Set<String>()
        var names: [String] = []
        for match in regex.matches(in: code, range: range) {
            if language == .applescript, let whole = Range(match.range, in: code), sendsNoEvents(around: whole, in: code) { continue }
            for group in 1..<match.numberOfRanges {
                guard let captured = Range(match.range(at: group), in: code) else { continue }
                let name = String(code[captured]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, seen.insert(name.lowercased()).inserted { names.append(name) }
            }
        }
        return names
    }

    /// `application "X" is running` and `name/id/version of application "X"` are answered without talking to X, so they
    /// must not raise the consent dialog nor fail a script whose app is refused.
    private static func sendsNoEvents(around match: Range<String.Index>, in code: String) -> Bool {
        let before = String(code[..<match.lowerBound].suffix(24))
        let after = String(code[match.upperBound...].prefix(24))
        return before.range(of: #"\b(?:name|id|version)\s+of\s+(?:the\s+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || after.range(of: #"^\s+(?:is|is\s+not|isn't|isn’t)\s+running\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Asks for consent where macOS has never asked, and says which app is refused. Nil means the script may run.
    /// A well-known app that is closed (System Events usually is) is opened hidden first, because macOS only asks about a
    /// running app and the dialog would otherwise appear while the script's clock runs. Unknown closed apps and Orb itself
    /// are skipped, as the script may launch them.
    static func blockingProblem(for script: String, language: AppleScript.Language,
                                checker: MacPermissionChecker = .live,
                                patience: Duration = .seconds(120),
                                settle: Duration = .milliseconds(300)) async -> MacPermissionProblem? {
        let ownBundleID = Bundle.main.bundleIdentifier
        for name in appNames(in: script, language: language) {
            let target = await Blocking.run(fallback: nil) { checker.target(forScriptName: name) }
            guard let target, target.bundleID != ownBundleID else { continue }
            let kind = MacPermissionKind.automation(target)
            var status = await checker.status(ofInBackground: kind)
            if status == .appNotRunning, AutomationTarget.known(named: target.bundleID) != nil {
                status = await launchedStatus(of: kind, target: target, checker: checker, settle: settle)
            }
            switch status {
            case .denied:
                return .automation(app: target.name)
            case .notDetermined:
                // The dialog stays up until the user answers; only then does the script start its own clock.
                if await checker.requestInBackground(kind, patience: patience) == .denied { return .automation(app: target.name) }
            default:
                continue
            }
        }
        return nil
    }

    /// Opens a closed app hidden and gives it a moment to register with Apple Events before asking again.
    private static func launchedStatus(of kind: MacPermissionKind, target: AutomationTarget, checker: MacPermissionChecker,
                                       settle: Duration) async -> MacPermissionStatus {
        guard await Blocking.run(fallback: false, timeout: .seconds(15), { checker.system.launchHidden(bundleID: target.bundleID) }) else {
            return .appNotRunning
        }
        var status = MacPermissionStatus.appNotRunning
        for _ in 0..<10 {
            status = await checker.status(ofInBackground: kind)
            if status != .appNotRunning { break }
            try? await Task.sleep(for: settle)
        }
        return status
    }
}
