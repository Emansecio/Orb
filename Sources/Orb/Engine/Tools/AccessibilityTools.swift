import CoreGraphics
import Foundation
import os

// Reading and operating other apps' interface through the Accessibility API (`ui_read`, `ui_act`), for apps that have
// no AppleScript or Shortcuts support, in the background: no focus is taken, the cursor does not move and nothing is
// typed where the user is typing (docs/USO-DO-COMPUTADOR.md). An action climbs a ladder: Accessibility alone (N0), then
// events sent to the app's process (N1, `system.input`), and only with the user's consent the real mouse and keyboard
// (N2, `system.screen`). The API itself sits behind `AccessibilitySystem` (AccessibilityElements.swift); the calls run on
// the app's own queue (AccessibilitySession.swift); notifications come from AccessibilityEvents.swift; the outline and
// the snapshot that ties an id to the element it named are in AccessibilityOutline.swift.

// MARK: - Which app

enum UIAppResolver {
    enum Failure: Error, Equatable {
        case notRunning(String)
        case ambiguous([String])
        /// The app asked for is the Orb: it must not click its own approval buttons.
        case isOrb
        case frontmostIsOrb
        case noFrontmost

        var message: String {
            switch self {
            case .notRunning(let name):
                "O app \"\(name)\" não está aberto. Abra-o com open (abre em segundo plano, sem tirar a pessoa do que ela usa) e tente de novo; apps_list mostra o que está aberto."
            case .ambiguous(let names):
                "Mais de um app combina: \(names.joined(separator: ", ")). Diga o nome exato ou o bundle identifier."
            case .isOrb:
                "O Orb não opera a própria interface (isso passaria por cima dos pedidos de permissão)."
            case .frontmostIsOrb:
                "O app em primeiro plano é o próprio Orb. Diga qual app quer ler ou operar (argumento app; apps_list mostra os abertos)."
            case .noFrontmost:
                "Não há app em primeiro plano. Diga qual app quer ler ou operar (argumento app)."
            }
        }
    }

    /// The app a call is about: the named one (name or bundle identifier), or the frontmost app when none is named.
    static func resolve(_ query: String?, in apps: [RunningAppInfo], ownPID: Int32, ownBundleID: String?) -> Result<AccessibilityApp, Failure> {
        func isOrb(_ app: RunningAppInfo) -> Bool { app.pid == ownPID || (ownBundleID != nil && app.bundleID == ownBundleID) }
        func target(_ app: RunningAppInfo) -> AccessibilityApp {
            AccessibilityApp(name: app.name, bundleID: app.bundleID, pid: app.pid, launchDate: app.launchDate)
        }

        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            guard let front = apps.first(where: \.isActive) else { return .failure(.noFrontmost) }
            return isOrb(front) ? .failure(.frontmostIsOrb) : .success(target(front))
        }
        switch RunningAppMatcher.match(query, in: apps) {
        case .none:
            return .failure(.notRunning(query))
        case .ambiguous(let found):
            return .failure(.ambiguous(Set(found.map(\.name)).sorted()))
        case .found(let found):
            guard let app = found.first(where: { !isOrb($0) }) else { return .failure(.isOrb) }
            return .success(target(app))
        }
    }
}

enum UIAccess {
    /// Checks the permission and finds the app. Nothing else touches the Accessibility API before this passes.
    static func open(_ query: String?, system: any AccessibilitySystem, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                     ownBundleID: String? = Bundle.main.bundleIdentifier) async throws -> AccessibilityApp {
        guard system.isTrusted() else { throw ToolError(MacPermissionProblem.accessibility.modelMessage) }
        // Which app is in front matters only when none is named; finding that out asks apps, and a hung one on top makes
        // it wait (a call to it must fail at once, not after that wait).
        let named = !(query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let apps = await system.runningApps(withFrontmost: !named)
        switch UIAppResolver.resolve(query, in: apps, ownPID: ownPID, ownBundleID: ownBundleID) {
        case .success(let app): return app
        case .failure(let failure): throw ToolError(failure.message)
        }
    }

    /// The app a reading is about: the named one, else the app this Orb read last (the person may be using the one in
    /// front), else the one in front. "frontmost" asks for the app in front.
    static func forReading(_ query: String?, bot: UUID?, store: UISnapshotStore, system: any AccessibilitySystem) async throws -> AccessibilityApp {
        let named = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if named.caseInsensitiveCompare("frontmost") == .orderedSame { return try await open(nil, system: system) }
        guard named.isEmpty, system.isTrusted(), let latest = store.latest(bot: bot) else { return try await open(query, system: system) }
        // An app that closed since is no reason to fail: this call is how the Orb would recover.
        if let app = try? await verify(latest.app, system: system) { return app }
        return try await open(nil, system: system)
    }

    /// The app an action is about: the named one, else the app of this Orb's newest reading. Never the app in front,
    /// which is the one the user is using.
    static func forAction(_ query: String?, bot: UUID?, store: UISnapshotStore, system: any AccessibilitySystem, needsName: Bool,
                          ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                          ownBundleID: String? = Bundle.main.bundleIdentifier) async throws -> AccessibilityApp {
        guard system.isTrusted() else { throw ToolError(MacPermissionProblem.accessibility.modelMessage) }
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return try await open(query, system: system, ownPID: ownPID, ownBundleID: ownBundleID)
        }
        guard let latest = store.latest(bot: bot) else {
            throw ToolError(needsName
                ? "Diga em qual app (argumento app): sem uma leitura antes, o Orb não age no app da frente, que é o que o usuário está usando."
                : "Diga o app (argumento app) ou chame ui_read antes de agir: sem uma leitura, o Orb não age no app da frente.")
        }
        guard latest.app.pid != ownPID, ownBundleID == nil || latest.app.bundleID != ownBundleID else {
            throw ToolError(UIAppResolver.Failure.isOrb.message)
        }
        return try await verify(latest.app, system: system)
    }

    /// The app is still the one that was read: the same process (pid, bundle identifier and launch date).
    static func verify(_ app: AccessibilityApp, system: any AccessibilitySystem) async throws -> AccessibilityApp {
        let running = await system.runningApps(withFrontmost: false)
        guard let match = running.first(where: { $0.pid == app.pid }), match.bundleID == app.bundleID,
              sameLaunch(app.launchDate, match.launchDate) else {
            throw ToolError("\(app.name) fechou ou foi reaberto desde a última leitura; chame ui_read de novo.")
        }
        var app = app
        app.launchDate = app.launchDate ?? match.launchDate
        return app
    }

    static func sameLaunch(_ one: Date?, _ other: Date?) -> Bool {
        guard let one, let other else { return true }
        return abs(one.timeIntervalSince(other)) < 1
    }

    /// What the model is told when a call fails.
    static func error(for failure: AXFailure, app: AccessibilityApp) -> ToolError {
        switch failure {
        case .apiDisabled:
            return ToolError(MacPermissionProblem.accessibility.modelMessage)
        case .cannotComplete:
            return ToolError("\(app.name) não respondeu a tempo (\(Int(LiveAccessibilitySystem.messagingTimeout)) s). Ele pode estar ocupado "
                             + "ou com uma janela de diálogo aberta; espere um pouco ou peça ao usuário para olhar a tela.")
        case .notSupported:
            return ToolError("Esse elemento de \(app.name) não aceita essa ação.")
        case .invalidElement:
            return ToolError(UIResolver.staleMessage)
        case .other(let code):
            return ToolError("A API de Acessibilidade falhou em \(app.name) (código \(code)).")
        }
    }

    /// Runs `body`, turning what the API refused into the message the model gets.
    static func mapped<T>(_ app: AccessibilityApp, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let failure as AXFailure { throw error(for: failure, app: app) }
    }
}

// MARK: - Windows

enum UIWindowChooser {
    static func title(of window: any AccessibilityElement) -> String { window.string("AXTitle") ?? "" }

    /// The index (from 0) of the window to read. `selector` is a position from 1 or part of a title; without one, the
    /// focused window (the window's own flag, else the app's focused window), else the first.
    static func choose(from windows: [any AccessibilityElement], selector: String?, focused: (any AccessibilityElement)? = nil) throws -> Int {
        guard !windows.isEmpty else { throw ToolError("O app não tem janelas.") }
        let wanted = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            return windows.firstIndex { $0.bool("AXFocused") == true }
                ?? focused.flatMap { focused in windows.firstIndex { $0.isSame(as: focused) } } ?? 0
        }
        if let position = Int(wanted) {
            guard (1...windows.count).contains(position) else {
                throw ToolError("O app tem \(windows.count) janela\(windows.count == 1 ? "" : "s"); não há a janela \(position).\n" + list(windows, reading: nil))
            }
            return position - 1
        }
        let folded = UIText.fold(wanted)
        guard let index = windows.firstIndex(where: { UIText.fold(title(of: $0)).contains(folded) }) else {
            throw ToolError("Nenhuma janela tem \"\(wanted)\" no título.\n" + list(windows, reading: nil))
        }
        return index
    }

    /// `Janelas: 1 “A” (lida) · 2 “B”`.
    static func list(_ windows: [any AccessibilityElement], reading: Int?) -> String {
        "Janelas: " + windows.enumerated().map { index, window in
            let name = title(of: window)
            var text = "\(index + 1) " + (name.isEmpty ? "(sem título)" : UIText.quoted(UIText.clean(name, limit: 60)))
            if window.bool("AXMinimized") == true { text += " (minimizada)" }
            if index == reading { text += " (lida)" }
            return text
        }.joined(separator: " · ")
    }

    /// The window a snapshot came from: at the same position with the same title, else any window with that title
    /// (windows reorder as focus moves).
    static func window(of snapshot: UISnapshot, in windows: [any AccessibilityElement]) -> (any AccessibilityElement)? {
        guard let index = snapshot.windowIndex.map({ $0 - 1 }) else { return nil }
        let wanted = UIText.fold(snapshot.windowTitle)
        if windows.indices.contains(index), UIText.fold(title(of: windows[index])) == wanted { return windows[index] }
        return windows.first { UIText.fold(title(of: $0)) == wanted }
    }
}

// MARK: - ui_read

/// One reading of an app, before it is saved.
struct UIReading: Sendable {
    var text: String
    var snapshot: UISnapshot
    /// The live element behind each id.
    var elements: [String: any AccessibilityElement]
    var window: (any AccessibilityElement)?
    /// Elements listed from the window (an Electron app that has not built its tree yet lists almost none).
    var listed: Int
}

struct UIReadTool: AgentTool {
    let spec = ToolSpec(
        name: "ui_read",
        description: """
        Read an app's interface through Accessibility, in the background. Returns an outline of one window, a line \
        per element: id (w1.3.2 = window 1, 3rd child, its 2nd child; m2 = 2nd menu), role, title, value (passwords \
        never read) and flags. Stops at 400 lines. Ids are valid for this reading only. Needs Accessibility.
        """,
        parameters: .schema([
            "app": .property("string", "Name, bundle id or \"frontmost\" (default: the last read)."),
            "window": .property("string", "Number or part of the title."),
            "query": .property("string", "Only elements containing this text."),
            "max_depth": .property("integer", "1-12."),
            "include_menus": .property("boolean", "With x1… status items."),
            "regions": .property("boolean", "Dense app: regions only."),
            "root": .property("string", "Read under this id."),
            "wait": .object(["type": .string("string"), "enum": .array(["appears", "disappears", "changes"].map(JSONValue.string)),
                             "description": .string("Wait first: query appears/disappears, or id/window changes.")]),
            "id": .property("string"),
            "timeout": .property("integer", "Wait seconds, 1-30 (5)."),
        ]))

    let system: any AccessibilitySystem
    let store: UISnapshotStore
    var limits = UIOutlineLimits()
    let sessions: AXSessions
    let live: UILiveElements

    init(system: any AccessibilitySystem = LiveAccessibilitySystem(), store: UISnapshotStore = .shared, limits: UIOutlineLimits = UIOutlineLimits(),
         sessions: AXSessions = .shared, live: UILiveElements = .shared) {
        self.system = system
        self.store = store
        self.limits = limits
        self.sessions = sessions
        self.live = live
    }

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let app = arguments.nonEmptyString("app") ?? "o último app lido"
        let detail = [arguments.nonEmptyString("window").map { "janela \($0)" }, arguments.nonEmptyString("query").map { "busca: \($0)" },
                      arguments.nonEmptyString("wait").map { "esperando: \($0)" }]
        return ("Lendo a interface de \(app)", detail.compactMap { $0 }.joined(separator: " · "))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let app = try await UIAccess.forReading(arguments["app"]?.string, bot: context.botID, store: store, system: system)
        var limits = limits
        limits.maxDepth = arguments.integer("max_depth", default: limits.maxDepth, in: 1...limits.maxDepth)
        limits.regionsOnly = arguments.flag("regions")
        let rootID = arguments.nonEmptyString("root")
        if let rootID, UIResolver.parse(rootID)?.kind != "w" { throw ToolError("root \"\(rootID)\" inválido: use um id de janela de ui_read, como w1.3.") }
        // The root's id says its window, whatever `window` says.
        let window = rootID.flatMap { UIResolver.parse($0)?.numbers.first.map(String.init) } ?? arguments["window"]?.int.map(String.init) ?? arguments.nonEmptyString("window"), query = arguments.nonEmptyString("query")
        let menus = arguments.flag("include_menus")

        var waitNote: String?
        if let mode = arguments.nonEmptyString("wait") {
            let condition = try UIWaitCondition(mode: mode, query: query, id: arguments.nonEmptyString("id"))
            let timeout = Duration.seconds(arguments.integer("timeout", default: 5, in: 1...30))
            let waiter = UIWaiter(system: system, sessions: sessions, store: store, live: live)
            waitNote = try await waiter.wait(condition, app: app, window: window, bot: context.botID, timeout: timeout)
        }

        let deadline = query == nil ? sessions.deadlines.read : sessions.deadlines.readWithQuery
        // The walk stops by itself a little before the deadline, so a slow app gives a partial outline, not an error.
        if limits.seconds == nil { limits.seconds = max(0.1, Self.seconds(deadline) - 0.25) }
        let readLimits = limits
        let system = system
        let session = sessions.session(for: app.pid)
        let (first, justEnabled) = try await UIAccess.mapped(app) {
            try await sessions.run(app, within: deadline) {
                let root = system.root(of: app)
                // Electron and Chromium build their tree on demand: asked once per app, retried once if it came back bare.
                let enabled = session.enableManualAccessibilityOnce(root: root, system: system) ?? false
                return (try Self.reading(root: root, app: app, window: window, query: query, includeMenus: menus, limits: readLimits, rootID: rootID), enabled)
            }
        }
        var reading = first
        if justEnabled, reading.listed < 3 {
            try await Task.sleep(for: .milliseconds(300))
            reading = try await UIAccess.mapped(app) {
                try await sessions.run(app, within: deadline) {
                    try Self.reading(root: system.root(of: app), app: app, window: window, query: query, includeMenus: menus, limits: readLimits, rootID: rootID)
                }
            }
        }

        var snapshot = reading.snapshot
        snapshot.generation = live.nextGeneration()
        snapshot = snapshot.carryingOver(from: store.snapshot(bot: context.botID, app: app), partial: query != nil || rootID != nil || limits.regionsOnly)
        store.save(snapshot, bot: context.botID)
        live.remember(bot: context.botID, pid: app.pid, generation: snapshot.generation, takenAt: snapshot.takenAt,
                      window: reading.window, elements: reading.elements)
        return reading.text + (waitNote.map { "\n" + $0 } ?? "")
    }

    static func seconds(_ duration: Duration) -> Double {
        let (whole, fraction) = duration.components
        return Double(whole) + Double(fraction) / 1e18
    }

    /// Reads one window (and the menus when asked or when there is no window). Blocking: call it on the app's queue.
    static func reading(root: any AccessibilityElement, app: AccessibilityApp, window selector: String?, query: String?,
                        includeMenus: Bool, limits: UIOutlineLimits, rootID: String? = nil) throws -> UIReading {
        let top: [String: AXAttributeValue]
        switch root.read(["AXRole", "AXWindows", "AXFocusedWindow"]) {
        case .values(let values): top = values
        case .failed(.invalidElement): throw ToolError("\(app.name) não está mais aberto.")
        case .failed(let failure): throw UIAccess.error(for: failure, app: app)
        }
        let windows = top["AXWindows"]?.elements
        guard windows != nil || top["AXRole"] != nil else {
            throw ToolError("\(app.name) não respondeu. Ele pode estar travado, ocupado com um diálogo ou não expor a interface por acessibilidade.")
        }
        var text = "App: \(app.name)" + (app.bundleID.map { " (\($0))" } ?? "")
        var entries: [String: UISnapshot.Entry] = [:]
        var elements: [String: any AccessibilityElement] = [:]
        var windowIndex: Int?
        var windowTitle = ""
        var chosen: (any AccessibilityElement)?
        var listed = 0

        if let windows, !windows.isEmpty {
            let index = try UIWindowChooser.choose(from: windows, selector: selector, focused: top["AXFocusedWindow"]?.element)
            windowIndex = index + 1
            windowTitle = UIWindowChooser.title(of: windows[index])
            chosen = windows[index]
            var start = windows[index]
            var windowFrame: CGRect?
            if let rootID, let numbers = UIResolver.parse(rootID)?.numbers {
                for position in numbers.dropFirst() {
                    guard let children = start.elements("AXChildren"), children.indices.contains(position - 1) else {
                        throw UIResolver.stale("\(rootID) não existe mais")
                    }
                    start = children[position - 1]
                }
                let frame = windows[index].attributes(["AXPosition", "AXSize"])
                if case .point(let origin)? = frame["AXPosition"], case .size(let size)? = frame["AXSize"] { windowFrame = CGRect(origin: origin, size: size) }
            }
            let outline = UIOutlineBuilder.outline(of: start, prefix: rootID ?? "w\(index + 1)", query: query, limits: limits, windowFrame: windowFrame)
            try AXWork.checkCancellation()
            if let failure = outline.failure {
                if failure == .apiDisabled { throw UIAccess.error(for: failure, app: app) }
                if outline.lines.isEmpty {
                    if failure == .invalidElement { throw ToolError("A janela \(UIText.quoted(windowTitle)) fechou durante a leitura; chame ui_read de novo.") }
                    throw UIAccess.error(for: failure, app: app)
                }
            }
            entries = outline.entries
            elements = outline.elements
            listed = outline.total
            text += "\n" + UIWindowChooser.list(windows, reading: index)
            if outline.lines.isEmpty {
                text += query.map { "\nNenhum elemento combina com \(UIText.quoted($0)) nesta janela." } ?? "\nNão consegui ler elementos desta janela."
            } else {
                text += "\n" + outline.lines.joined(separator: "\n")
            }
            if let query, !outline.lines.isEmpty { text += "\n(\(outline.matched) elemento\(outline.matched == 1 ? "" : "s") combina\(outline.matched == 1 ? "" : "m") com \(UIText.quoted(query)))" }
            if let notice = cutNotice(outline, app: app, limits: limits) { text += "\n" + notice }
        } else {
            text += "\nO app está aberto mas não tem janelas visíveis. Dá para usar os menus (ui_act com pick_menu ou show_menu)."
        }

        if includeMenus || windowIndex == nil {
            if let menus = UIOutlineBuilder.menuBar(of: root) {
                entries.merge(menus.entries) { current, _ in current }
                elements.merge(menus.elements) { current, _ in current }
                text += "\nMenus da barra:\n" + menus.lines.joined(separator: "\n")
            } else {
                text += "\nNão consegui ler a barra de menus de \(app.name)."
            }
            if let extras = UIOutlineBuilder.menuBar(of: root, extras: true) {
                entries.merge(extras.entries) { current, _ in current }
                elements.merge(extras.elements) { current, _ in current }
                text += "\nItens de status:\n" + extras.lines.joined(separator: "\n")
            }
        }
        let snapshot = UISnapshot(app: app, windowIndex: windowIndex, windowTitle: windowTitle, entries: entries)
        return UIReading(text: text, snapshot: snapshot, elements: elements, window: chosen, listed: listed)
    }

    private static func cutNotice(_ outline: UIOutline, app: AccessibilityApp, limits: UIOutlineLimits) -> String? {
        var reasons: [String] = []
        if outline.cuts.contains(.hung) { reasons.append("\(app.name) parou de responder no meio da leitura") }
        if outline.cuts.contains(.lines) { reasons.append("mostrei \(outline.lines.count) de \(outline.total) elementos (limite de \(limits.maxLines) linhas)") }
        if outline.cuts.contains(.characters) { reasons.append("mostrei \(outline.lines.count) linhas (limite de \(limits.maxCharacters) caracteres)") }
        if outline.cuts.contains(.depth) { reasons.append("há elementos mais fundos que a profundidade \(limits.maxDepth)") }
        if outline.cuts.contains(.web) {
            reasons.append("a página web foi lida só até \(limits.webDepth) níveis (para páginas, prefira as ferramentas do navegador)")
        }
        if outline.cuts.contains(.visited) { reasons.append("a janela é grande: examinei só os primeiros \(limits.maxVisited) elementos") }
        if outline.cuts.contains(.time) { reasons.append("a leitura passou de \(UIClock.seconds(.milliseconds(Int((limits.seconds ?? 4) * 1000)))) e parou") }
        guard !reasons.isEmpty else { return nil }
        return "[Saída cortada: " + reasons.joined(separator: "; ") + ". Use query para achar um elemento ou window para outra janela.]"
    }
}

// MARK: - Waiting

/// What `wait` waits for.
enum UIWaitCondition: Sendable, Equatable {
    case appears(String)
    case disappears(String)
    /// The element (an id or "#n") or, without one, the window.
    case changes(String?)

    init(mode: String, query: String?, id: String?) throws {
        let normalized = mode.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "appears", "disappears":
            guard let query else { throw ToolError("wait \(mode) precisa de query: o texto que deve aparecer ou sumir.") }
            self = normalized == "appears" ? .appears(query) : .disappears(query)
        case "changes":
            self = .changes(id)
        default:
            throw ToolError("wait desconhecido \"\(mode)\": use appears, disappears ou changes.")
        }
    }

    var done: String {
        switch self {
        case .appears(let text): "apareceu \(UIText.quoted(text))"
        case .disappears(let text): "sumiu \(UIText.quoted(text))"
        case .changes: "mudou"
        }
    }
}

/// Waits for something to show in an app: re-checks as soon as a notification comes (also one that came while it was
/// looking), and every 250 ms when none does: an app may change what it shows without saying so (and not every element
/// says it changed), so the notifications only make the waiting shorter.
struct UIWaiter: Sendable {
    let system: any AccessibilitySystem
    let sessions: AXSessions
    let store: UISnapshotStore
    let live: UILiveElements
    /// The longest pause between two looks when no notification comes.
    var poll: Duration = .milliseconds(250)
    /// The pauses before that: short at first, when what was waited for most likely happens (a label that changes right
    /// after a press), then longer.
    static let ticks: [Duration] = [.milliseconds(50), .milliseconds(50), .milliseconds(75), .milliseconds(100), .milliseconds(150)]

    /// Told every pause before it is taken (tests).
    var onPause: (@Sendable (Duration) -> Void)?

    /// The pause after the `look`-th look (from 0).
    func tick(after look: Int) -> Duration {
        look < Self.ticks.count ? min(Self.ticks[look], poll) : poll
    }

    /// Whether a look that costs the app a lot of work is followed by a pause as long as the look itself (at most
    /// `maxBackoff`), so a wait never keeps a slow app busy more than about half the time. Off for tests that count pauses.
    var spacesLooksByCost = true
    /// A look shorter than this is not worth spacing out.
    static let cheapLook: Duration = .milliseconds(100)
    static let maxBackoff: Duration = .seconds(1)

    /// The pause that follows a look that took `took`: the usual tick, or the look's own length when it was expensive (walking a
    /// large window for a text that is not there yet).
    func pause(after look: Int, took: Duration) -> Duration {
        let usual = tick(after: look)
        guard spacesLooksByCost, took >= Self.cheapLook else { return usual }
        return max(usual, min(took, Self.maxBackoff))
    }

    /// Notifications that say the window changed (focus and layout alone do not).
    static let changeNotifications: Set<AXNotification> = [
        .valueChanged, .titleChanged, .created, .elementDestroyed, .windowCreated, .sheetCreated, .rowCountChanged,
        .selectedChildrenChanged, .selectedRowsChanged, .loadComplete,
    ]

    private struct Probe: Sendable {
        var matched = false
        var signature = ""
        var target: (any AccessibilityElement)?
    }

    /// Waits, and says how it went: "(esperei 1,2 s: apareceu “Salvo”)" or "(não aconteceu em 5 s)". `watcher` is a
    /// subscription already made (by an action, so the notifications it caused count).
    func wait(_ condition: UIWaitCondition, app: AccessibilityApp, window selector: String?, bot: UUID?, timeout: Duration,
              watcher given: AXEventWatcher? = nil) async throws -> String {
        let clock = ContinuousClock()
        let started = clock.now
        let end = started + timeout
        let snapshot = store.snapshot(bot: bot, app: app)
        let system = system
        let watcher: AXEventWatcher
        if let given {
            watcher = given
        } else {
            let stream = try await sessions.run(app, within: sessions.deadlines.action) {
                system.events.events(pid: app.pid, UISettle.notifications, on: nil)
            }
            watcher = AXEventWatcher(stream)
        }
        defer { if given == nil { watcher.cancel() } }

        let cached: UILiveElements.Found?
        if case .changes(let reference?) = condition, let snapshot,
           let id = try? UIResolver.id(for: reference, in: snapshot, app: app) {
            cached = live.element(bot: bot, pid: app.pid, generation: snapshot.generation, takenAt: snapshot.takenAt, id: id)
        } else {
            cached = nil
        }
        var baseline: Probe?
        var eventsAtBaseline = 0
        var looks = 0
        while true {
            try Task.checkCancellation()
            // Counted before looking: a notification that comes while the look runs makes the next look start at once.
            let seen = watcher.count
            let left = max(clock.now.duration(to: end + sessions.deadlines.waitGrace), .milliseconds(100))
            let lookStarted = clock.now
            let probe = try await UIAccess.mapped(app) {
                try await sessions.run(app, within: min(sessions.deadlines.action, left)) {
                    try Self.probe(condition, root: system.root(of: app), app: app, selector: selector, snapshot: snapshot, cached: cached)
                }
            }
            switch condition {
            case .appears:
                if probe.matched { return note(started, clock, condition) }
            case .disappears:
                if !probe.matched { return note(started, clock, condition) }
            case .changes:
                if let baseline {
                    if probe.signature != baseline.signature || changed(since: eventsAtBaseline, in: watcher, target: baseline.target) {
                        return note(started, clock, condition)
                    }
                } else {
                    baseline = probe
                    eventsAtBaseline = given == nil ? watcher.count : 0
                }
            }
            let remaining = clock.now.duration(to: end)
            guard remaining > .zero else { return "(não aconteceu em \(UIClock.seconds(timeout)))" }
            let pause = min(self.pause(after: looks, took: lookStarted.duration(to: clock.now)), remaining)
            looks += 1
            onPause?(pause)
            if watcher.isFinished {
                try await Task.sleep(for: pause)
            } else {
                await watcher.waitForMore(than: seen, timeout: pause)
            }
        }
    }

    private func note(_ started: ContinuousClock.Instant, _ clock: ContinuousClock, _ condition: UIWaitCondition) -> String {
        "(esperei \(UIClock.seconds(started.duration(to: clock.now))): \(condition.done))"
    }

    private func changed(since seen: Int, in watcher: AXEventWatcher, target: (any AccessibilityElement)?) -> Bool {
        watcher.events.dropFirst(seen).contains { event in
            guard Self.changeNotifications.contains(event.notification) else { return false }
            guard let target else { return true }
            return event.element.map { target.isSame(as: $0) } ?? false
        }
    }

    private static func probe(_ condition: UIWaitCondition, root: any AccessibilityElement, app: AccessibilityApp, selector: String?,
                              snapshot: UISnapshot?, cached: UILiveElements.Found?) throws -> Probe {
        switch condition {
        case .appears(let text), .disappears(let text):
            guard let (window, index) = try window(root: root, selector: selector, snapshot: snapshot) else { return Probe() }
            var limits = UIOutlineLimits()
            limits.maxLines = 40
            limits.seconds = 1.5
            // Whether it is there, not how many times: the walk ends at the first element that has the text.
            limits.stopAtFirstMatch = true
            let outline = UIOutlineBuilder.outline(of: window, prefix: "w\(index + 1)", query: text, limits: limits)
            if let failure = outline.failure, failure != .invalidElement { throw failure }
            return Probe(matched: outline.matched > 0)
        case .changes(let reference?):
            guard let snapshot else { throw ToolError("Ainda não li a interface de \(app.name); chame ui_read antes de esperar por um id.") }
            let id = try UIResolver.id(for: reference, in: snapshot, app: app)
            do {
                let found = try UIResolver.resolve(id: id, root: root, app: app, snapshot: snapshot, cached: cached)
                let info = found.live
                let value = UIElementInfo.readValue(of: found.element, info: info) ?? ""
                return Probe(signature: [info.identity, value, "\(info.selected)", "\(info.enabled)", "\(info.focused)"].joined(separator: "|"),
                             target: found.element)
            } catch {
                // The element went away (or became something else): that is a change too.
                return Probe(signature: "gone")
            }
        case .changes(nil):
            var state = UIState.capture(root: root, target: nil)
            if let (window, _) = try window(root: root, selector: selector, snapshot: snapshot) {
                state.target = "\(window.elements("AXChildren")?.count ?? 0)|" + UIWindowChooser.title(of: window)
            }
            return Probe(signature: String(describing: state))
        }
    }

    private static func window(root: any AccessibilityElement, selector: String?, snapshot: UISnapshot?) throws -> (any AccessibilityElement, Int)? {
        let windows: [any AccessibilityElement]
        switch root.read(["AXWindows", "AXFocusedWindow"]) {
        case .failed(let failure): throw failure
        case .values(let values):
            windows = values["AXWindows"]?.elements ?? []
            guard !windows.isEmpty else { return nil }
            if selector == nil, let snapshot, let window = UIWindowChooser.window(of: snapshot, in: windows),
               let index = windows.firstIndex(where: { $0.isSame(as: window) }) ?? snapshot.windowIndex.map({ $0 - 1 }) {
                return (window, index)
            }
            let index = try UIWindowChooser.choose(from: windows, selector: selector, focused: values["AXFocusedWindow"]?.element)
            return (windows[index], index)
        }
    }
}

// MARK: - Selecting rows

/// Selecting rows of a table, outline or list without a click, and reading back that it took.
enum UIRowSelection {
    static let containerRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXGrid"]
    static let rowRoles: Set<String> = ["AXRow"]

    /// The row `element` is (or is in, up to six levels up: a cell's text, the cell) and the container that holds it.
    static func context(of element: any AccessibilityElement, role: String) -> (row: any AccessibilityElement, container: (any AccessibilityElement)?)? {
        var current = element
        var currentRole = role
        for _ in 0...6 {
            if rowRoles.contains(currentRole) {
                var parent = current.element("AXParent")
                for _ in 0..<3 {
                    guard let above = parent else { break }
                    if containerRoles.contains(above.string("AXRole") ?? "") { return (current, above) }
                    parent = above.element("AXParent")
                }
                return (current, nil)
            }
            if containerRoles.contains(currentRole) { return nil }
            guard let parent = current.element("AXParent") else { return nil }
            current = parent
            currentRole = parent.string("AXRole") ?? ""
        }
        return nil
    }

    /// Tries, reading back after each: the container's `AXSelectedRows` (an NSTableView selects as a click would and
    /// tells its delegate), each row's `AXSelected`, the container's `AXSelectedChildren`, and for one row its `AXPress`
    /// (web and Electron lists). False when none of them was confirmed. Blocking: run it on the app's queue.
    static func select(_ rows: [any AccessibilityElement], in container: (any AccessibilityElement)?,
                       pause: TimeInterval = 0.05) -> Bool {
        guard !rows.isEmpty else { return false }
        func isSelected(_ row: any AccessibilityElement) -> Bool {
            if row.bool("AXSelected") == true { return true }
            guard let container else { return false }
            let listed = container.elements("AXSelectedRows") ?? container.elements("AXSelectedChildren") ?? []
            return listed.contains { $0.isSame(as: row) }
        }
        func confirmed() -> Bool {
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: pause) }
                if rows.allSatisfy(isSelected) { return true }
            }
            return false
        }
        if let container, container.isSettable("AXSelectedRows"), (try? container.setValue(.elements(rows), for: "AXSelectedRows")) != nil,
           confirmed() { return true }
        if rows.allSatisfy({ $0.isSettable("AXSelected") }),
           (try? rows.forEach { try $0.setValue(.bool(true), for: "AXSelected") }) != nil, confirmed() { return true }
        if let container, container.isSettable("AXSelectedChildren"),
           (try? container.setValue(.elements(rows), for: "AXSelectedChildren")) != nil, confirmed() { return true }
        if rows.count == 1, rows[0].actionNames().contains("AXPress"), (try? rows[0].perform("AXPress")) != nil, confirmed() { return true }
        return false
    }
}

// MARK: - Finding an element again

enum UIResolver {
    static let staleMessage = "A interface mudou; chame ui_read de novo."

    static func stale(_ detail: String) -> ToolError { ToolError("A interface mudou (\(detail)); chame ui_read de novo.") }

    /// `w1.3.2.5` → kind "w", numbers [1, 3, 2, 5]; `m2` → kind "m", numbers [2].
    static func parse(_ id: String) -> (kind: Character, numbers: [Int])? {
        guard id.range(of: #"^[wmx][0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil, let kind = id.first else { return nil }
        let numbers = id.dropFirst().split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : (kind, numbers)
    }

    /// The id an argument names: itself, or for `#12` the id under mark 12 of the last screenshot of that window.
    static func id(for reference: String, in snapshot: UISnapshot?, app: AccessibilityApp) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return trimmed }
        guard let number = Int(trimmed.dropFirst()) else { throw ToolError("Marca inválida \"\(trimmed)\": use o número de uma marca do screenshot, como #12.") }
        guard let snapshot, let id = snapshot.marks[number] else {
            throw ToolError("A marca #\(number) não está no último screenshot com marcas de \(app.name); tire outro screenshot ou use um id de ui_read.")
        }
        return id
    }

    /// The live element behind an id, and what it is now.
    struct Resolved: Sendable {
        var id: String
        var element: any AccessibilityElement
        var entry: UISnapshot.Entry
        var live: UIElementInfo
        var attributes: [String: AXAttributeValue]
        /// The window of the reading; nil for menus.
        var window: (any AccessibilityElement)?
        var windowFrame: CGRect?
        /// The element's frame on screen, when it says.
        var frame: CGRect?

        /// "button “Salvar”".
        var name: String {
            entry.label.isEmpty ? UIRole.short(entry.rawRole) : "\(UIRole.short(entry.rawRole)) \(UIText.quoted(entry.label))"
        }
    }

    /// Read from the element in one round trip: what identifies it, where it is and which window holds it.
    static let liveNames = UIElementInfo.attributeNames + ["AXPosition", "AXWindow"]

    private struct Gone: Error {}

    /// The live element behind an id of the last reading, checked against what that reading saw there (role and name,
    /// process, window): if they differ the interface moved and the caller must read again rather than click something
    /// else. The live reference kept from the reading is tried first; the path of the id is walked when there is none or
    /// it is gone.
    static func resolve(id: String, root: any AccessibilityElement, app: AccessibilityApp, snapshot: UISnapshot?,
                        cached: UILiveElements.Found? = nil) throws -> Resolved {
        guard let snapshot else { throw ToolError("Ainda não li a interface de \(app.name); chame ui_read antes de agir.") }
        guard snapshot.app.pid == app.pid, UIAccess.sameLaunch(snapshot.app.launchDate, app.launchDate) else { throw ToolError(staleMessage) }
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parse(id) else {
            throw ToolError("Id inválido \"\(id)\": use um id de ui_read, como w1.3.2 ou m2.")
        }
        guard let entry = snapshot.entries[id] else {
            throw ToolError("O id \"\(id)\" não está na última leitura de \(app.name); chame ui_read de novo (use query para achar o elemento).")
        }
        if let cached {
            do { return try check(cached.element, window: cached.window, id: id, entry: entry, snapshot: snapshot, app: app) } catch is Gone {}
        }

        var current: any AccessibilityElement
        var window: (any AccessibilityElement)?
        if parsed.kind != "w" {
            guard let items = root.element(parsed.kind == "x" ? "AXExtrasMenuBar" : "AXMenuBar")?.elements("AXChildren"), items.indices.contains(parsed.numbers[0] - 1) else {
                throw ToolError(staleMessage)
            }
            current = items[parsed.numbers[0] - 1]
        } else {
            guard snapshot.windowIndex == parsed.numbers[0], let windows = root.elements("AXWindows"),
                  let found = UIWindowChooser.window(of: snapshot, in: windows) else {
                throw stale("a janela \(UIText.quoted(snapshot.windowTitle)) não está mais aberta")
            }
            current = found
            window = found
        }
        for position in parsed.numbers.dropFirst() {
            guard let children = current.elements("AXChildren"), children.indices.contains(position - 1) else {
                throw stale("\(id) não existe mais")
            }
            current = children[position - 1]
        }
        do {
            return try check(current, window: window, id: id, entry: entry, snapshot: snapshot, app: app)
        } catch is Gone {
            throw stale("\(id) não existe mais")
        }
    }

    private static func check(_ element: any AccessibilityElement, window: (any AccessibilityElement)?, id: String, entry: UISnapshot.Entry,
                              snapshot: UISnapshot, app: AccessibilityApp) throws -> Resolved {
        let attributes: [String: AXAttributeValue]
        switch element.read(liveNames) {
        case .values(let values): attributes = values
        case .failed(.invalidElement): throw Gone()
        case .failed(let failure): throw failure
        }
        let live = UIElementInfo(attributes: attributes)
        guard live.rawRole == entry.rawRole else {
            throw stale("\(id) era \(UIRole.short(entry.rawRole)) e agora é \(live.role)")
        }
        // The app's own id, when both readings have one, says more than the label: a title may change, a button is the same.
        if let known = entry.identifier, let now = live.identifier {
            guard known == now else { throw stale("\(id) agora é outro elemento") }
        } else if !entry.label.isEmpty, UIText.fold(live.identity) != UIText.fold(entry.label) {
            throw stale("\(id) era \(UIText.quoted(entry.label)) e agora é " + (live.identity.isEmpty ? "sem nome" : UIText.quoted(live.identity)))
        }
        if let pid = element.pid, pid != app.pid { throw stale("\(id) é de outro processo agora") }
        var windowFrame: CGRect?
        if let window {
            if let owner = attributes["AXWindow"]?.element, !owner.isSame(as: window) { throw stale("\(id) agora está em outra janela") }
            switch window.read(["AXTitle", "AXPosition", "AXSize"]) {
            case .failed(.invalidElement): throw stale("a janela \(UIText.quoted(snapshot.windowTitle)) fechou")
            case .failed(let failure): throw failure
            case .values(let values):
                let title = values["AXTitle"]?.string ?? ""
                guard UIText.fold(title) == UIText.fold(snapshot.windowTitle) else {
                    throw stale("a janela agora se chama \(UIText.quoted(title))")
                }
                if case .point(let origin)? = values["AXPosition"], case .size(let size)? = values["AXSize"] {
                    windowFrame = CGRect(origin: origin, size: size)
                }
            }
        }
        var frame: CGRect?
        if case .point(let origin)? = attributes["AXPosition"], let size = live.size { frame = CGRect(origin: origin, size: size) }
        return Resolved(id: id, element: element, entry: entry, live: live, attributes: attributes, window: window,
                        windowFrame: windowFrame, frame: frame)
    }
}

// MARK: - Menus

enum UIMenu {
    static func title(of item: any AccessibilityElement) -> String { item.string("AXTitle") ?? "" }

    /// The items of the menu an item opens (`AXMenuBarItem` → `AXMenu` → items); empty when it has no menu.
    static func items(under item: any AccessibilityElement) -> [any AccessibilityElement] {
        let menu = item.elements("AXChildren")?.first { $0.string("AXRole") == "AXMenu" }
        return menu?.elements("AXChildren") ?? []
    }

    /// The item called `wanted` among `items`: the same title ignoring case and accents with "…" and "..." alike, else
    /// the same title ignoring a trailing ellipsis ("Exportar" finds "Exportar…").
    static func find(_ wanted: String, in items: [any AccessibilityElement]) -> (element: any AccessibilityElement, title: String)? {
        let titled = items.map { (element: $0, title: title(of: $0)) }.filter { !$0.title.isEmpty }
        let key = UIText.fold(wanted)
        if let exact = titled.first(where: { UIText.fold($0.title) == key }) { return exact }
        let loose = UIText.foldedWithoutEllipsis(wanted)
        return loose.isEmpty ? nil : titled.first { UIText.foldedWithoutEllipsis($0.title) == loose }
    }

    /// Walks `path` down the menu bar and returns the item it names.
    static func resolve(_ path: [String], root: any AccessibilityElement, app: AccessibilityApp) throws -> (element: any AccessibilityElement, titles: [String]) {
        guard let bar = root.element("AXMenuBar"), var level = bar.elements("AXChildren"), !level.isEmpty else {
            throw ToolError("Não consegui ler a barra de menus de \(app.name).")
        }
        var titles: [String] = []
        for (position, wanted) in path.enumerated() {
            guard let match = find(wanted, in: level) else {
                let options = level.map { title(of: $0) }.filter { !$0.isEmpty }
                let where_ = titles.isEmpty ? "na barra de menus" : "no menu \(titles.joined(separator: " → "))"
                throw ToolError("Não achei \(UIText.quoted(wanted)) \(where_) de \(app.name). Opções: "
                                + options.prefix(40).joined(separator: ", ") + (options.count > 40 ? ", …" : "") + ".")
            }
            titles.append(match.title)
            if position == path.count - 1 {
                if match.element.bool("AXEnabled") == false {
                    throw ToolError("O item de menu \(UIText.quoted(titles.joined(separator: " → "))) está desativado (cinza) agora.")
                }
                return (match.element, titles)
            }
            level = items(under: match.element)
            if level.isEmpty { throw ToolError("\(UIText.quoted(match.title)) não abre um submenu; o caminho termina nele.") }
        }
        throw ToolError("Faltou o caminho do menu.")
    }

    /// `- Novo`, `- Abrir recente ▸`, `- Salvar (desativado)` for the items of a menu or submenu.
    static func listing(of items: [any AccessibilityElement]) -> String {
        let lines = items.compactMap { entry -> String? in
            let name = title(of: entry)
            guard !name.isEmpty else { return nil }
            var line = "- " + UIText.clean(name, limit: 60)
            if !self.items(under: entry).isEmpty { line += " ▸" }
            if entry.bool("AXEnabled") == false { line += " (desativado)" }
            return line
        }
        return lines.prefix(40).joined(separator: "\n") + (lines.count > 40 ? "\n- …" : "")
    }

    /// The menu item whose keyboard shortcut is `stroke` (enabled, else a disabled one, which `enabled` tells), found without opening any menu (the shortcut then works
    /// whatever the keyboard layout and with the app in the background). Looks at most `limit` items deep in submenus, and
    /// gives up after `seconds` (each item is a round trip, and a big menu must not use up the call's deadline: the key
    /// then goes as an event) or when the call was cancelled.
    static func item(for stroke: KeyStroke, root: any AccessibilityElement, limit: Int = 800, seconds: Double = 1) -> (element: any AccessibilityElement, titles: [String], enabled: Bool)? {
        guard let bar = root.element("AXMenuBar"), let top = bar.elements("AXChildren") else { return nil }
        var budget = limit
        let started = Date()
        var disabled: (any AccessibilityElement, [String])?
        let names = ["AXTitle", "AXEnabled", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXChildren"]

        func search(_ items: [any AccessibilityElement], path: [String], depth: Int) -> (any AccessibilityElement, [String])? {
            for item in items {
                guard budget > 0, !AXWork.isCancelled, Date().timeIntervalSince(started) < seconds else { return nil }
                budget -= 1
                guard let values = item.read(names).attributes else { continue }
                let title = values["AXTitle"]?.string ?? ""
                if matches(stroke, values) {
                    if values["AXEnabled"]?.bool != false { return (item, path + [title]) }
                    if disabled == nil { disabled = (item, path + [title]) }
                }
                guard depth < 3, let menu = values["AXChildren"]?.elements?.first(where: { $0.string("AXRole") == "AXMenu" }),
                      let children = menu.elements("AXChildren") else { continue }
                if let found = search(children, path: path + [title], depth: depth + 1) { return found }
            }
            return nil
        }
        let found = search(top, path: [], depth: 0)
        return (found ?? disabled).map { (element: $0.0, titles: Array($0.1.filter { !$0.isEmpty }), enabled: found != nil) }
    }

    /// `AXMenuItemCmdModifiers`: shift 1, option 2, control 4, and 8 for "no command key".
    private static func matches(_ stroke: KeyStroke, _ values: [String: AXAttributeValue]) -> Bool {
        var bits = 0
        if case .number(let number)? = values["AXMenuItemCmdModifiers"] { bits = Int(number) }
        var modifiers: KeyStroke.Modifiers = []
        if bits & 8 == 0 { modifiers.insert(.command) }
        if bits & 1 != 0 { modifiers.insert(.shift) }
        if bits & 2 != 0 { modifiers.insert(.option) }
        if bits & 4 != 0 { modifiers.insert(.control) }
        switch stroke.key {
        case .character(let character):
            guard let char = values["AXMenuItemCmdChar"]?.string, !char.isEmpty else { return false }
            return modifiers == stroke.modifiers && char.lowercased() == String(character).lowercased()
        case .named(let named):
            guard case .number(let key)? = values["AXMenuItemCmdVirtualKey"] else { return false }
            return modifiers == stroke.modifiers && UInt16(key) == named.virtualKey
        }
    }
}

// MARK: - Keys that pull focus

/// Shortcuts an app takes as "the person wants to type here": sent to a pid in the background they still raise the window
/// or flip tabs in front of the person.
enum UIFocusKeys {
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
                                        "com.brave.Browser", "org.mozilla.firefox", "org.chromium.Chromium"]

    static func pulls(_ stroke: KeyStroke, bundleID: String?) -> Bool {
        guard stroke.modifiers.contains(.command), case .character(let raw) = stroke.key else { return false }
        let key = Character(raw.lowercased())
        if bundleID == "com.apple.finder" { return key == "g" && stroke.modifiers == [.command, .shift] }
        guard browsers.contains(bundleID ?? "") else { return false }
        if stroke.modifiers == [.command] { return key == "l" || "123456789[]".contains(key) }
        return stroke.modifiers == [.command, .shift] && "[]{}".contains(key)
    }
}

// MARK: - What changed

/// A few facts about an app's interface, taken before and after an action to tell the model what the action did.
struct UIState: Equatable, Sendable {
    var windows: [String] = []
    var focusedWindow: String?
    var focusedElement: String?
    var sheet = false
    /// The value or selection of the element that was acted on; nil when it has none.
    var target: String?
    /// The element was asked for but could not be read any more.
    var targetGone = false

    /// `known`: the target's attributes already read (they are not read again).
    static func capture(root: any AccessibilityElement, target: (any AccessibilityElement)?, known: [String: AXAttributeValue]? = nil) -> UIState {
        var state = UIState()
        let top = root.read(["AXWindows", "AXFocusedWindow", "AXFocusedUIElement"]).attributes ?? [:]
        let windows = top["AXWindows"]?.elements ?? []
        let titles = windows.map(UIWindowChooser.title(of:))
        state.windows = titles
        if let front = top["AXFocusedWindow"]?.element {
            state.focusedWindow = windows.firstIndex { $0.isSame(as: front) }.map { titles[$0] } ?? UIWindowChooser.title(of: front)
            // A sheet is the window's last child.
            state.sheet = front.elements("AXChildren")?.last?.string("AXRole") == "AXSheet"
        }
        if let focused = top["AXFocusedUIElement"]?.element {
            let info = UIElementInfo(attributes: focused.attributes(UIElementInfo.attributeNames))
            state.focusedElement = info.role + (info.identity.isEmpty ? "" : " " + UIText.quoted(info.identity))
        }
        if let target {
            // AXValue is asked for apart, once the element is known not to be a password field.
            let attributes = known ?? target.read(UIElementInfo.attributeNames).attributes ?? [:]
            if attributes.isEmpty {
                state.targetGone = true
            } else {
                let info = UIElementInfo(attributes: attributes)
                let value = UIElementInfo.readValue(of: target, info: info)
                var parts: [String] = []
                if let value { parts.append("valor \(UIText.quoted(value))") }
                if info.selected { parts.append("selecionado") }
                if !info.enabled { parts.append("desativado") }
                state.target = parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        }
        return state
    }

    /// One sentence about what differs; a note that nothing visible did when it is the same.
    static func describe(from before: UIState, to after: UIState) -> String {
        func name(_ title: String) -> String { title.isEmpty ? "(sem título)" : UIText.quoted(UIText.clean(title, limit: 60)) }
        var changes: [String] = []
        var remaining = before.windows
        var opened: [String] = []
        for title in after.windows {
            if let index = remaining.firstIndex(of: title) { remaining.remove(at: index) } else { opened.append(title) }
        }
        if !opened.isEmpty { changes.append("abriu \(opened.count == 1 ? "a janela" : "as janelas") " + opened.map(name).joined(separator: ", ")) }
        if !remaining.isEmpty { changes.append("fechou \(remaining.count == 1 ? "a janela" : "as janelas") " + remaining.map(name).joined(separator: ", ")) }
        if opened.isEmpty, remaining.isEmpty, before.focusedWindow != after.focusedWindow, let focused = after.focusedWindow {
            changes.append("janela em foco agora: \(name(focused))")
        }
        if after.sheet != before.sheet { changes.append(after.sheet ? "apareceu um painel (folha) na janela" : "o painel (folha) da janela fechou") }
        if after.targetGone, !before.targetGone {
            changes.append("o elemento não está mais na tela")
        } else if before.target != after.target {
            changes.append("o elemento agora tem " + (after.target ?? "nenhum valor") + (before.target.map { " (antes: \($0))" } ?? ""))
        }
        if before.focusedElement != after.focusedElement, let focused = after.focusedElement { changes.append("foco em \(focused)") }
        return changes.isEmpty
            ? "Nada visível mudou ainda; se esperava algo, espere um instante e chame ui_read para conferir."
            : "Mudou: " + changes.joined(separator: "; ") + "."
    }
}

// MARK: - Danger

/// Clicks and keys that cannot be taken back, recognized by the name of the element or menu item.
enum UIDanger {
    private struct Rule {
        var phrases: [String]
        var reason: String
        /// Only where the action leaves the Mac: mail and chat apps.
        var onlyInMessaging = false
    }

    private static let rules: [Rule] = [
        Rule(phrases: ["excluir", "apagar", "deletar", "delete", "remove", "remover", "eliminar"],
             reason: "apaga ou remove algo, e talvez não dê para desfazer"),
        Rule(phrases: ["esvaziar lixeira", "esvaziar a lixeira", "esvaziar lixo", "esvaziar o lixo", "empty trash", "empty the trash"],
             reason: "esvazia a Lixeira, o que não dá para desfazer"),
        Rule(phrases: ["enviar", "send"], reason: "envia uma mensagem ou e-mail, que não dá para desfazer", onlyInMessaging: true),
        Rule(phrases: ["comprar", "buy", "pagar", "pay", "purchase", "place order", "finalizar compra"],
             reason: "faz uma compra ou um pagamento"),
        Rule(phrases: ["sair sem salvar", "nao salvar", "don't save", "dont save", "descartar", "discard"],
             reason: "descarta mudanças que não foram salvas"),
        Rule(phrases: ["formatar", "erase", "apagar tudo"], reason: "apaga ou formata dados"),
    ]

    private static let messagingApps: Set<String> = [
        "mail", "mensagens", "messages", "com.apple.mail", "com.apple.mobilesms", "com.microsoft.outlook", "outlook",
        "slack", "com.tinyspeck.slackmacgap", "whatsapp", "net.whatsapp.whatsapp", "telegram", "ru.keepcoder.telegram",
        "discord", "com.hnc.discord", "signal", "org.whispersystems.signal-desktop", "teams", "com.microsoft.teams2",
    ]

    static func isMessagingApp(name: String?, bundleID: String?) -> Bool {
        [name, bundleID].compactMap { $0 }.contains { messagingApps.contains(UIText.fold($0)) }
    }

    static func isFinder(name: String?, bundleID: String?) -> Bool {
        [name, bundleID].compactMap { $0 }.contains { ["finder", "com.apple.finder"].contains(UIText.fold($0)) }
    }

    private static func words(_ text: String) -> [String] {
        UIText.fold(text).split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    /// Why pressing an element or menu item with this name is irreversible, or nil.
    /// `assumeMessaging` is for when the app is not known: the rules of mail and chat apps then apply too.
    static func reason(forLabel label: String, appName: String?, bundleID: String?, assumeMessaging: Bool = false) -> String? {
        let found = words(label)
        guard !found.isEmpty else { return nil }
        let messaging = assumeMessaging || isMessagingApp(name: appName, bundleID: bundleID)
        for rule in rules where !rule.onlyInMessaging || messaging {
            if rule.phrases.contains(where: { has($0, in: found) }) { return rule.reason }
        }
        return nil
    }

    /// Whether the words of `phrase` come one after the other in `found`.
    private static func has(_ phrase: String, in found: [String]) -> Bool {
        let wanted = words(phrase)
        guard !wanted.isEmpty, found.count >= wanted.count else { return false }
        return (0...(found.count - wanted.count)).contains { Array(found[$0..<($0 + wanted.count)]) == wanted }
    }

    /// Why letting something go on an element with this name is irreversible: what pressing it would do, or the Trash.
    static func reason(forDropOnto label: String, appName: String?, bundleID: String?) -> String? {
        if let reason = reason(forLabel: label, appName: appName, bundleID: bundleID) { return reason }
        let found = words(label)
        guard ["lixeira", "trash", "recycle bin", "itens excluidos", "deleted items"].contains(where: { has($0, in: found) }) else { return nil }
        return "move o que for solto para a Lixeira, e talvez não dê para desfazer"
    }

    /// Why pressing these keys is irreversible: Return sends in a mail or chat app, ⌘⌫ deletes in the Finder.
    static func reason(forKeys strokes: [KeyStroke], appName: String?, bundleID: String?, assumeMessaging: Bool = false) -> String? {
        let messaging = assumeMessaging || isMessagingApp(name: appName, bundleID: bundleID)
        let finder = isFinder(name: appName, bundleID: bundleID)
        for stroke in strokes {
            if messaging, stroke.key == .named(.return), !stroke.modifiers.contains(.shift), !stroke.modifiers.contains(.option) {
                return "Return envia a mensagem ou o e-mail, o que não dá para desfazer"
            }
            if finder, stroke.modifiers.contains(.command), stroke.key == .named(.delete) || stroke.key == .named(.forwardDelete) {
                return "no Finder, ⌘⌫ apaga (move para o Lixo) o que está selecionado"
            }
        }
        return nil
    }
}

// MARK: - ui_act

/// How an action reached the app, as the output says it.
enum UIMethod: Sendable {
    case accessibility
    case event

    var tag: String {
        switch self {
        case .accessibility: "[segundo plano · AX]"
        case .event: "[segundo plano · evento ao app]"
        }
    }
}

struct UIActTool: AgentTool {
    enum Action: String, CaseIterable, Sendable {
        case press, focus, setValue = "set_value", type, key, select, scroll, click, move, drag, draw, increment, decrement
        case showMenu = "show_menu", pickMenu = "pick_menu"
    }

    /// The stable marker of an error that only the real mouse and keyboard can get past.
    static let takeoverMarker = "[precisa_assumir_tela]"

    let spec = ToolSpec(
        name: "ui_act",
        description: """
        Operate an element found with ui_read, in the background (focus and cursor untouched): press, click (id, \
        "#n" mark or x,y screenshot pixels), focus, set_value, type (value into id or the focused field), key, select, \
        scroll, move (hover), drag (to `to`, or into to_app), draw (pen stroke along path), increment, decrement, \
        show_menu, pick_menu (menu_path ["Arquivo", "Exportar…"], no id). If the screen \
        changed it fails with "a interface mudou": read again. [precisa_assumir_tela] = only real input works: repeat \
        with takeover. Anything that deletes, sends, buys or discards always asks the user first. Needs Accessibility.
        """,
        parameters: .schema([
            "app": .property("string", "Default: the app you last read."),
            "action": .object(["type": .string("string"), "enum": .array(Action.allCases.map { JSONValue.string($0.rawValue) })]),
            "id": .property("string", "w1.3.2, m2 or #12."),
            "ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "value": .property("string"),
            "keys": .property("string", "cmd+s, return…"),
            "menu_path": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "x": .property("integer"),
            "y": .property("integer"),
            "button": .property("string", "left, right, middle"),
            "count": .property("integer", "Clicks, 1-3."),
            "modifiers": .property("string", "cmd+shift, option…"),
            "hold": .property("integer", "Press ms, max 3000."),
            "to": .property("string", "Drag end: id or x,y."),
            "to_app": .property("string", "App of `to`."),
            "duration": .property("integer", "ms, 150-5000."),
            "path": .property("string", "[[x,y,pressure?],…] or SVG, screenshot px."),
            "direction": .property("string", "up, down, left, right"),
            "amount": .property("integer", "Pages, 1-10."),
            "wait": .property("string", "Text to wait for after acting, or changes."),
            "timeout": .property("integer", "Wait seconds, 1-30 (5)."),
            "steps": .object(["type": .string("array"), "items": .object(["type": .string("object")]),
                              "description": .string("Up to 8 calls run in order; stops at the first failure.")]),
            "takeover": .property("boolean", "Real mouse and keyboard; the user confirms."),
        ], required: ["action"]))

    let system: any AccessibilitySystem
    let store: UISnapshotStore
    /// How long to watch the app after acting before looking at what changed.
    let settle: UISettle
    let sessions: AXSessions
    let live: UILiveElements

    init(system: any AccessibilitySystem = LiveAccessibilitySystem(), store: UISnapshotStore = .shared, settle: UISettle = .standard,
         sessions: AXSessions = .shared, live: UILiveElements = .shared) {
        self.system = system
        self.store = store
        self.settle = settle
        self.sessions = sessions
        self.live = live
    }

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    // MARK: Arguments

    /// One action, from the call or from one of its `steps`.
    struct Step: Sendable {
        var action: Action
        /// An id of ui_read or a screenshot mark ("#12").
        var reference: String?
        var ids: [String] = []
        var value: String?
        var keys: [KeyStroke] = []
        var keysText = ""
        var menuPath: [String] = []
        /// Pixels of the last screenshot of the window.
        var point: CGPoint?
        var button: MouseButton = .left
        var count = 1
        /// Keys held while clicking, dragging or scrolling.
        var modifiers: KeyStroke.Modifiers = []
        /// How long a click keeps the button down (a long press).
        var hold: Duration = .zero
        var direction: String?
        var amount = 1
        /// Where a drag lets go: an id or mark, or a pixel of the screenshot of the app it ends in (`toApp`, else this one).
        var destination: String?
        var destinationPoint: CGPoint?
        var toApp: String?
        /// A drag's or a stroke's duration; nil for the default.
        var duration: Duration?
        /// The points of a `draw`, in pixels of the screenshot.
        var stroke: [StrokePoint] = []

        var clicking: Clicking { Clicking(button: button, count: count, modifiers: modifiers, hold: hold) }

        /// Cuts "cmd+s, return" into its shortcuts at the commas, except the comma that is the key itself ("cmd+,", ",").
        /// A comma is the key when it comes right after a "+", or when it starts a piece that nothing follows but
        /// another comma; any other comma separates.
        static func splitKeys(_ text: String) -> [String] {
            var pieces: [String] = []
            var current = ""
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                guard character == "," else { current.append(character); continue }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix("+") {
                    current.append(character)
                } else if trimmed.isEmpty {
                    let next = characters[(index + 1)...].first { !$0.isWhitespace }
                    if next == nil || next == "," { current.append(character) }
                } else {
                    pieces.append(current)
                    current = ""
                }
            }
            pieces.append(current)
            return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// `x` and `y` as pixels of the last screenshot; models also send them as text.
        static func pixel(in arguments: JSONValue) -> CGPoint? {
            func coordinate(_ key: String) -> Int? {
                arguments[key]?.int ?? arguments[key]?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            guard let x = coordinate("x"), let y = coordinate("y") else { return nil }
            return CGPoint(x: x, y: y)
        }

        /// "cmd+shift", "cmd, option" or a list: the names `KeyStroke.parse` knows, read through it so there is one vocabulary.
        static func modifiers(in arguments: JSONValue) throws -> KeyStroke.Modifiers {
            let text = arguments["modifiers"]?.array.map { $0.compactMap(\.string).joined(separator: "+") } ?? arguments.nonEmptyString("modifiers") ?? ""
            let names = text.split { "+, ".contains($0) }
            guard !names.isEmpty else { return [] }
            do { return try KeyStroke.parse(names.joined(separator: "+") + "+a").modifiers } catch let error as KeyStroke.ParseError {
                throw ToolError(error.errorDescription ?? "Modificador inválido.")
            }
        }

        /// The duration asked for, clamped to 150 ms…5 s; nil (the default of the action) when not given.
        static func duration(in arguments: JSONValue) -> Duration? {
            let milliseconds = arguments.integer("duration", default: 0, in: 0...5000)
            return milliseconds == 0 ? nil : .milliseconds(max(150, milliseconds))
        }

        /// The Dock takes no drop from a drag sent in the background (it reads the real pointer), and is no app to read.
        static func isDock(_ app: String) -> Bool { ["dock", "com.apple.dock"].contains(UIText.fold(app)) }

        /// Where a drag ends: `to` (an id, or "x,y" pixels), else the older `value`; in the app `to_app` when given.
        static func parseEnd(of step: inout Step, in arguments: JSONValue) throws {
            let numbers = arguments["to"]?.array?.compactMap(\.number)
            let text = arguments.nonEmptyString("to") ?? arguments.nonEmptyString("value")
            let pair = numbers?.count == 2 ? numbers : text.map { $0.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            if let pair, pair.count == 2 {
                step.destinationPoint = CGPoint(x: pair[0].rounded(), y: pair[1].rounded())
            } else if let text {
                step.destination = text.trimmingCharacters(in: .whitespaces)
            } else {
                throw ToolError("Faltou o argumento \"to\": o id (ou x,y em pixels do screenshot) onde soltar.")
            }
            step.toApp = arguments.nonEmptyString("to_app")?.trimmingCharacters(in: .whitespaces)
            if let app = step.toApp, isDock(app) {
                throw ToolError("O Dock não recebe arrastar e soltar de um arrasto em segundo plano. Para a Lixeira use pick_menu "
                                + "[\"Arquivo\", \"Mover para o Lixo\"] ou a tecla cmd+delete no Finder.")
            }
        }

        static let strokeBounds = 2...500

        /// The points of a `draw`: [[x,y],…] or [[x,y,pressure],…] (a list, or the JSON text of one), else SVG path data.
        static func stroke(in arguments: JSONValue) throws -> [StrokePoint] {
            var list = arguments["path"]?.array
            if list == nil, let text = arguments.nonEmptyString("path")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if text.hasPrefix("["), let parsed = JSONValue.parse(text)?.array {
                    list = parsed
                } else {
                    guard text.count <= 20_000 else { throw ToolError("O caminho SVG de path é grande demais; mande um traço mais curto ou menos pontos.") }
                    let points = try SVGPath.parse(text)
                    guard points.count >= 2 else { throw ToolError("O caminho de path precisa de pelo menos 2 pontos.") }
                    return points.map { StrokePoint(point: $0) }
                }
            }
            guard let list else {
                throw ToolError("Faltou o argumento \"path\": pontos [[x,y],…] ou um caminho SVG, em pixels do último screenshot.")
            }
            guard strokeBounds.contains(list.count) else {
                throw ToolError("path precisa de \(strokeBounds.lowerBound) a \(strokeBounds.upperBound) pontos (vieram \(list.count)).")
            }
            return try list.enumerated().map { index, item in
                guard let numbers = item.array?.map(\.number), (2...3).contains(numbers.count), let x = numbers[0], let y = numbers[1] else {
                    throw ToolError("O ponto \(index + 1) de path precisa ser [x, y] ou [x, y, pressão].")
                }
                return StrokePoint(point: CGPoint(x: x, y: y), pressure: numbers.count == 3 ? numbers[2].map { min(1, max(0, $0)) } : nil)
            }
        }

        static func parse(_ arguments: JSONValue) throws -> Step {
            let actionName = try arguments.requiredString("action")
            guard let action = Action(rawValue: actionName) else {
                throw ToolError("Ação desconhecida \"\(actionName)\": use \(Action.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            var step = Step(action: action)
            step.reference = arguments.nonEmptyString("id")?.trimmingCharacters(in: .whitespaces)
            step.ids = (arguments["ids"]?.array ?? []).compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if step.reference == nil, step.ids.count == 1 { step.reference = step.ids.removeFirst() }
            let hasTarget = step.reference != nil || !step.ids.isEmpty
            /// What a click, hover, drag or scroll starts from: an element, or a pixel of the screenshot.
            func needSource() throws {
                step.point = Self.pixel(in: arguments)
                if step.point == nil, !hasTarget { throw ToolError("Faltou o argumento \"id\" (ou x e y, em pixels do último screenshot).") }
            }
            switch action {
            case .pickMenu:
                guard let path = UIActTool.menuPath(in: arguments) else {
                    throw ToolError("Faltou o argumento \"menu_path\", por exemplo [\"Arquivo\", \"Exportar…\"].")
                }
                step.menuPath = path
            case .setValue:
                if !hasTarget { _ = try arguments.requiredString("id") }
                step.value = try arguments.requiredString("value", allowEmpty: true)
            case .type:
                step.value = try arguments.requiredString("value")
            case .key:
                step.keysText = try arguments.requiredString("keys")
                step.keys = try Self.splitKeys(step.keysText).map { piece in
                    do { return try KeyStroke.parse(piece) } catch let error as KeyStroke.ParseError {
                        throw ToolError(error.errorDescription ?? "Atalho inválido.")
                    }
                }
                if step.keys.isEmpty { throw ToolError(KeyStroke.ParseError.empty.errorDescription ?? "Atalho vazio.") }
            case .click:
                try needSource()
                let buttonName = arguments.nonEmptyString("button")?.lowercased() ?? "left"
                // An unknown button is the model's to fix: a right click turned into a left one can act on the wrong thing.
                guard let button = MouseButton(rawValue: buttonName) else {
                    throw ToolError("Unknown button \"\(buttonName)\"; use left, right or middle.")
                }
                step.button = button
                step.count = arguments.integer("count", default: 1, in: 1...3)
                step.hold = .milliseconds(arguments.integer("hold", default: 0, in: 0...3000))
                step.modifiers = try Self.modifiers(in: arguments)
            case .move:
                try needSource()
            case .drag:
                try needSource()
                try Self.parseEnd(of: &step, in: arguments)
                step.modifiers = try Self.modifiers(in: arguments)
                step.duration = Self.duration(in: arguments)
            case .draw:
                step.stroke = try Self.stroke(in: arguments)
                step.duration = Self.duration(in: arguments)
            case .scroll:
                try needSource()
                if let direction = arguments.nonEmptyString("direction")?.lowercased() {
                    guard ["up", "down", "left", "right"].contains(direction) else {
                        throw ToolError("direction desconhecida \"\(direction)\": use up, down, left ou right.")
                    }
                    step.direction = direction
                }
                step.amount = arguments.integer("amount", default: 1, in: 1...10)
                step.modifiers = try Self.modifiers(in: arguments)
            case .select:
                if !hasTarget { _ = try arguments.requiredString("id") }
                step.value = arguments.nonEmptyString("value")
            default:
                if !hasTarget { _ = try arguments.requiredString("id") }
            }
            return step
        }

        /// The same action once per id of `ids` (a selection of several rows stays one step).
        var expanded: [Step] {
            guard !ids.isEmpty, action != .select else { return [self] }
            return ([reference].compactMap { $0 } + ids).map { id in
                var one = self
                one.reference = id
                one.ids = []
                return one
            }
        }
    }

    /// The steps of a call: its `steps` (at most 8), else the call itself.
    static func steps(in arguments: JSONValue) throws -> [Step] {
        if let list = arguments["steps"]?.array, !list.isEmpty {
            guard list.count <= 8 else { throw ToolError("No máximo 8 passos em steps (vieram \(list.count)).") }
            let steps = try list.flatMap { try Step.parse($0).expanded }
            guard steps.count <= 8 else { throw ToolError("No máximo 8 passos em steps (com ids, vieram \(steps.count)).") }
            return steps
        }
        let steps = try Step.parse(arguments).expanded
        guard steps.count <= 8 else { throw ToolError("No máximo 8 ids por chamada (vieram \(steps.count)).") }
        return steps
    }

    /// The menu titles of a `pick_menu`, from a list or from a text such as "Arquivo > Exportar…".
    static func menuPath(in arguments: JSONValue) -> [String]? {
        let path: [String]
        if let list = arguments["menu_path"]?.array {
            path = list.compactMap(\.string)
        } else if let text = arguments["menu_path"]?.string {
            path = text.split(whereSeparator: { ">→/".contains($0) }).map(String.init)
        } else {
            return nil
        }
        let clean = path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return clean.isEmpty ? nil : clean
    }

    // MARK: Judging a call before it runs

    /// Every reading that has the id (or mark) and may be what the call is about (the readings of the named app, or of
    /// any app when none is named), newest first. Which one `run` clicks depends on the Orb, so the danger check looks
    /// at all of them: it may ask too much, never too little.
    private func targets(_ reference: String?, app: String?) -> [(snapshot: UISnapshot, entry: UISnapshot.Entry)] {
        guard let reference = reference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else { return [] }
        return store.candidates(matching: app).compactMap { snapshot in
            guard let id = try? UIResolver.id(for: reference, in: snapshot, app: snapshot.app) else { return nil }
            return snapshot.entries[id].map { (snapshot, $0) }
        }
    }

    /// The entries a click at a screenshot point would land on, in every reading that has that screenshot.
    private func targets(at point: CGPoint, app: String?) -> [(snapshot: UISnapshot, entry: UISnapshot.Entry)] {
        store.candidates(matching: app).compactMap { snapshot in
            guard let id = UIActTool.localHit(point, in: snapshot)?.id else { return nil }
            return snapshot.entries[id].map { (snapshot, $0) }
        }
    }

    private func targets(of step: Step, app: String?) -> [(snapshot: UISnapshot, entry: UISnapshot.Entry)] {
        var found = ([step.reference].compactMap { $0 } + step.ids).flatMap { targets($0, app: app) }
        if let point = step.point { found += targets(at: point, app: app) }
        return found
    }

    /// The entries a drag would let go on, in the readings of the app it ends in (`to_app`, else the one it starts in).
    private func destinations(of step: Step, app: String?) -> [(snapshot: UISnapshot, entry: UISnapshot.Entry)] {
        let named = step.toApp ?? app
        var found = targets(step.destination, app: named)
        if let point = step.destinationPoint { found += targets(at: point, app: named) }
        return found
    }

    /// What the call would click, from the last readings: the approval card names it. When readings disagree, the one
    /// that makes the call dangerous is shown, so the card is not milder than the check.
    private func target(of step: Step, app: String?) -> (snapshot: UISnapshot, entry: UISnapshot.Entry)? {
        let found = targets(of: step, app: app)
        return found.first { UIDanger.reason(forLabel: $0.entry.label, appName: $0.snapshot.app.name, bundleID: $0.snapshot.app.bundleID) != nil }
            ?? found.first
    }

    /// Deleting, sending, buying and discarding stay asked even in "Automático": judged by the name of the element
    /// (from the last reading) or of the menu item, and by the keys. A password field is never filled without asking,
    /// and taking the screen over is always asked.
    func danger(_ arguments: JSONValue) -> String? {
        guard let steps = try? Self.steps(in: arguments) else { return nil }
        let app = arguments.nonEmptyString("app")
        let found = steps.lazy.compactMap { self.danger(of: $0, app: app) }.first
        if arguments.flag("takeover") {
            return "usa o mouse e o teclado reais por alguns segundos (assume a tela)" + (found.map { "; e \($0)" } ?? "")
        }
        return found
    }

    private func danger(of step: Step, app appArgument: String?) -> String? {
        switch step.action {
        case .pickMenu:
            guard let last = step.menuPath.last else { return nil }
            // Without an app the call is about a reading no check here can tell: assume a messaging app.
            guard let appArgument else { return UIDanger.reason(forLabel: last, appName: nil, bundleID: nil, assumeMessaging: true) }
            for snapshot in store.candidates(matching: appArgument) {
                if let reason = UIDanger.reason(forLabel: last, appName: snapshot.app.name, bundleID: snapshot.app.bundleID) { return reason }
            }
            return UIDanger.reason(forLabel: last, appName: appArgument, bundleID: appArgument)
        case .press, .click, .select, .showMenu:
            for found in targets(of: step, app: appArgument) {
                let app = found.snapshot.app
                if let reason = UIDanger.reason(forLabel: found.entry.label, appName: app.name, bundleID: app.bundleID) { return reason }
                if let value = step.value, let reason = UIDanger.reason(forLabel: value, appName: app.name, bundleID: app.bundleID) { return reason }
            }
            return nil
        case .drag:
            // What is dragged, and what it is let go on: dropping on the Trash or on a delete button cannot be taken back.
            for found in targets(of: step, app: appArgument) {
                let app = found.snapshot.app
                if let reason = UIDanger.reason(forLabel: found.entry.label, appName: app.name, bundleID: app.bundleID) { return reason }
            }
            for found in destinations(of: step, app: appArgument) {
                let app = found.snapshot.app
                if let reason = UIDanger.reason(forDropOnto: found.entry.label, appName: app.name, bundleID: app.bundleID) { return reason }
            }
            return nil
        case .setValue, .type:
            if targets(of: step, app: appArgument).contains(where: { $0.entry.secure }) { return "preenche um campo de senha" }
            // A line break is typed as Return, which sends in a mail or chat app.
            guard let value = step.value, Self.hasLineBreak(value) else { return nil }
            return danger(ofKeys: [Self.returnKey], app: appArgument).map(Self.lineBreakReason)
        case .key:
            if targets(of: step, app: appArgument).contains(where: { $0.entry.secure }) { return "digita num campo de senha" }
            return danger(ofKeys: step.keys, app: appArgument)
        default:
            return nil
        }
    }

    /// Keys judged against every reading the call may be about; with none, against the named app (or, unnamed, as if it
    /// were a messaging app).
    private func danger(ofKeys keys: [KeyStroke], app appArgument: String?) -> String? {
        let readings = store.candidates(matching: appArgument)
        if readings.isEmpty {
            return UIDanger.reason(forKeys: keys, appName: appArgument, bundleID: appArgument, assumeMessaging: appArgument == nil)
        }
        for snapshot in readings {
            if let reason = UIDanger.reason(forKeys: keys, appName: snapshot.app.name, bundleID: snapshot.app.bundleID) { return reason }
        }
        return appArgument.flatMap { UIDanger.reason(forKeys: keys, appName: $0, bundleID: $0) }
    }

    static let returnKey = KeyStroke(.named(.return))

    /// Text that `type` (and `set_value` when it falls back to typing) sends with Return in it: every line break is one.
    static func hasLineBreak(_ text: String) -> Bool { text.contains(where: \.isNewline) }

    static func lineBreakReason(_ reason: String) -> String { "o texto tem quebra de linha, que é digitada como Return: \(reason)" }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let appName = arguments.nonEmptyString("app") ?? "o app da última leitura"
        guard let steps = try? Self.steps(in: arguments), let first = steps.first else {
            return ("Operando a interface de \(appName)", arguments.nonEmptyString("id") ?? "")
        }
        var result: (title: String, detail: String)
        if steps.count == 1 {
            result = summary(of: first, app: arguments.nonEmptyString("app"), appName: appName)
        } else {
            let lines = steps.map { step -> String in
                let one = summary(of: step, app: arguments.nonEmptyString("app"), appName: appName)
                return one.title + (one.detail.isEmpty ? "" : " (\(one.detail))")
            }
            result = ("Fazendo \(steps.count) passos em \(appName)", lines.joined(separator: " → "))
        }
        if arguments.flag("takeover") { result.title = "Assumindo a tela: " + result.title }
        return result
    }

    private func summary(of step: Step, app: String?, appName: String) -> (title: String, detail: String) {
        if step.action == .pickMenu { return ("Escolhendo no menu de \(appName)", step.menuPath.joined(separator: " → ")) }
        let found = target(of: step, app: app)
        let reference = step.reference ?? step.point.map { "x \(Int($0.x)), y \(Int($0.y))" } ?? step.ids.joined(separator: ", ")
        let label = found.map { $0.entry.label }.flatMap { $0.isEmpty ? nil : UIText.quoted($0) } ?? "o elemento \(reference)"
        let role = found.map { UIRole.short($0.entry.rawRole) + " " } ?? ""
        let place = " · " + (found?.snapshot.app.name ?? appName)
        // Typing into "the focused field" names no element: the card cannot ask the app (no Accessibility call here), so
        // the text is hidden whenever the focus may be a password field, by the readings of the app (one has a password
        // field) or for want of any reading.
        let blind = step.reference == nil && step.ids.isEmpty && step.point == nil
        let mayBeSecret = blind && {
            let readings = store.candidates(matching: app)
            return readings.isEmpty || readings.contains { $0.entries.values.contains(where: \.secure) }
        }()
        func text(_ value: String?) -> String {
            guard let value else { return "" }
            if found?.entry.secure == true { return "(campo de senha)" }
            if mayBeSecret { return "(\(value.count) caractere\(value.count == 1 ? "" : "s"), ocultos: o campo em foco pode ser de senha)" }
            return value.count > 300 ? value.prefix(300) + "…" : value
        }
        switch step.action {
        case .press: return ("Clicando em \(label)", role + reference + place)
        case .drag: return ("Arrastando \(label)", role + reference + dragEnd(of: step, app: app) + place)
        case .click: return ("Clicando em \(label)", role + reference + Self.clickDetail(step) + place)
        case .move: return ("Passando o mouse sobre \(label)", role + reference + place)
        case .draw: return ("Desenhando em \(appName)", "traço de \(step.stroke.count) pontos")
        case .focus: return ("Focando em \(label)", role + reference + place)
        case .setValue: return ("Escrevendo em \(label)", text(step.value) + place)
        case .type: return (step.reference == nil ? "Digitando no campo em foco" : "Digitando em \(label)", text(step.value) + place)
        case .key: return ("Teclando \(step.keysText)", (step.reference == nil ? "" : role + reference) + place)
        case .select: return ("Selecionando \(step.value.map(UIText.quoted) ?? label)", role + reference + place)
        case .scroll:
            return ("Rolando \(label)", [step.direction, Self.scrollSize(amount: step.amount, modifiers: step.modifiers)].compactMap { $0 }.joined(separator: " ") + place)
        case .increment: return ("Aumentando \(label)", place)
        case .decrement: return ("Diminuindo \(label)", place)
        case .showMenu: return ("Abrindo o menu \(label)", place)
        case .pickMenu: return ("Escolhendo no menu de \(appName)", step.menuPath.joined(separator: " → "))
        }
    }

    /// " → “Pasta” em Finder": where a drag lets go, as the card says it (the element that makes the call dangerous first).
    private func dragEnd(of step: Step, app: String?) -> String {
        let ends = destinations(of: step, app: app)
        let found = ends.first { UIDanger.reason(forDropOnto: $0.entry.label, appName: $0.snapshot.app.name, bundleID: $0.snapshot.app.bundleID) != nil } ?? ends.first
        let named = found.flatMap { $0.entry.label.isEmpty ? nil : UIText.quoted($0.entry.label) }
        let raw = step.destination ?? step.destinationPoint.map { "x \(Int($0.x)), y \(Int($0.y))" } ?? ""
        return " → " + (named ?? raw) + (step.toApp.map { " em \($0)" } ?? "")
            + (step.modifiers.isEmpty ? "" : " (com \(Self.symbols(step.modifiers)))")
    }

    /// ⌃⌥⇧⌘, the way the menus write the keys held.
    static func symbols(_ modifiers: KeyStroke.Modifiers) -> String {
        [(KeyStroke.Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { modifiers.contains($0.0) }.map(\.1).joined()
    }

    /// How a click differs from a plain one, for the card: " (duplo, ⌘, segurando 1,2 s)".
    static func clickDetail(_ step: Step) -> String {
        var parts: [String] = []
        if step.count == 2 { parts.append("duplo") } else if step.count == 3 { parts.append("triplo") }
        if !step.modifiers.isEmpty { parts.append(symbols(step.modifiers)) }
        if step.hold > .zero { parts.append("segurando \(UIClock.seconds(step.hold))") }
        if step.button != .left { parts.append(step.button == .right ? "botão direito" : "botão do meio") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// What a click did, for the output: "Cliquei com ⌘ em", "Pressionei por 1,2 s em", "Dei três cliques em".
    static func clickVerb(_ click: Clicking) -> String {
        var verb = click.hold > .zero ? "Pressionei por \(UIClock.seconds(click.hold))" : click.count == 3 ? "Dei três cliques"
            : click.count == 2 ? "Dei dois cliques" : "Cliquei"
        var with: [String] = []
        if !click.modifiers.isEmpty { with.append(symbols(click.modifiers)) }
        if click.button != .left { with.append(click.button == .right ? "o botão direito" : "o botão do meio") }
        if !with.isEmpty { verb += " com " + with.joined(separator: " e ") }
        return verb + " em"
    }

    // MARK: Running

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let steps = try Self.steps(in: arguments)
        let needsName = steps.contains { $0.action == .pickMenu || $0.action == .key }
        let app = try await UIAccess.forAction(arguments["app"]?.string, bot: context.botID, store: store, system: system, needsName: needsName)
        // What the approval card judged: an action whose live target turns out dangerous runs only if the card said so. The
        // engine hands the card's own verdict over (`judgedDanger`); only a call no card was computed for judges itself here.
        let approved = context.judgedDanger ?? (danger(arguments, context: context) != nil)
        if arguments.flag("takeover") { return try await takeOver(steps, app: app, context: context, approved: approved) }

        var done: [String] = []
        var last: Performed?
        for (index, step) in steps.enumerated() {
            do {
                let performed = try await perform(step, app: app, context: context, approved: approved, waitsAfter: index == steps.count - 1 && arguments.nonEmptyString("wait") != nil)
                done.append(steps.count == 1 ? performed.text : "\(index + 1). \(performed.text)")
                last?.watcher.cancel()
                last = performed
            } catch {
                last?.watcher.cancel()
                guard steps.count > 1 else { throw error }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw ToolError("O passo \(index + 1) de \(steps.count) falhou: \(message)" + (done.isEmpty ? "" : "\nAntes dele:\n" + done.joined(separator: "\n")))
            }
        }
        var text = done.joined(separator: "\n")
        if let last {
            defer { last.watcher.cancel() }
            if let wanted = arguments.nonEmptyString("wait") {
                let timeout = Duration.seconds(arguments.integer("timeout", default: 5, in: 1...30))
                text += "\n" + (try await waitAfter(wanted, app: app, context: context, timeout: timeout, last: last))
            }
        }
        return text
    }

    /// One step done: what to tell the model, and the subscription made before acting (for a `wait` that follows).
    struct Performed: Sendable {
        var text: String
        var watcher: AXEventWatcher
        var before: UIState
        var target: (any AccessibilityElement)?
    }

    /// What one step needs, handed to the app's queue.
    struct Request: Sendable {
        var step: Step
        var snapshot: UISnapshot?
        var bot: UUID?
        var approved: Bool
        var stealsFocus: Bool
        /// Where a drag lets go when that is another app, found before the step runs.
        var remote: DropTarget?
    }

    /// How a click presses: the button, how many times, with which keys held and for how long each press stays down.
    struct Clicking: Sendable {
        var button: MouseButton = .left
        var count = 1
        var modifiers: KeyStroke.Modifiers = []
        var hold: Duration = .zero

        /// What an `AXPress` can stand for: it carries none of the rest.
        var isPlain: Bool { button == .left && count == 1 && modifiers.isEmpty && hold == .zero }
    }

    /// Where a drag lets go when that is a window of another app: the point on the screen, the window and what is there.
    struct DropTarget: Sendable {
        var app: AccessibilityApp
        var point: CGPoint
        var window: EventWindow
        /// How the output names it: `button “Pasta” em Finder`.
        var name: String
    }

    /// A drag or a pen stroke to send, with the points already on the screen.
    struct DragPlan: Sendable {
        var path: [StrokePoint]
        var window: WindowRef
        var drop: DropTarget?
        var modifiers: KeyStroke.Modifiers = []
        var duration: Duration
        /// What the output says when the drag turned into a system drag-and-drop that was let go.
        var droppedSummary = ""
        /// A pen stroke never becomes a drag-and-drop: it is stopped if it tries.
        var pen = false
    }

    /// Events still to send to the app after the Accessibility part (N1).
    enum InputPlan: Sendable {
        case click(CGPoint, window: WindowRef, Clicking)
        case move([CGPoint], window: WindowRef)
        case scroll(dx: Int, dy: Int, at: CGPoint, window: WindowRef, modifiers: KeyStroke.Modifiers)
        case drag(DragPlan)
        case keys([KeyStroke], target: (any AccessibilityElement)?)
        case text(String, target: any AccessibilityElement, replace: Bool)
    }

    /// The window an event goes to, as the reading and the screenshot knew it.
    struct WindowRef: Sendable {
        var frame: CGRect?
        var title: String
        var windowID: UInt32?
    }

    struct Acted: Sendable {
        var summary: String
        var target: (any AccessibilityElement)?
        var before: UIState
        var listing: String?
        var input: InputPlan?
        /// What the input is, for the error when it cannot be sent ("clicar em button “OK”").
        var inputWhat = ""
        var notes: [String] = []
    }

    private func perform(_ step: Step, app: AccessibilityApp, context: ToolContext, approved: Bool, waitsAfter: Bool) async throws -> Performed {
        let snapshot = store.snapshot(bot: context.botID, app: app)
        let session = sessions.session(for: app.pid)
        let remote = try await dropTarget(for: step, app: app, bot: context.botID, approved: approved)
        let request = Request(step: step, snapshot: snapshot, bot: context.botID, approved: approved,
                              stealsFocus: session.state.withLock { $0.stealsFocus }, remote: remote)
        let frontBefore = await system.frontmostPID()
        let system = system, live = live
        var watcher: AXEventWatcher?
        do {
            let (stream, first) = try await UIAccess.mapped(app) {
                try await sessions.run(app, within: sessions.deadlines.action) {
                    // Subscribed before acting, so the notifications the action causes are not missed.
                    let stream = system.events.events(pid: app.pid, UISettle.notifications, on: nil)
                    return (stream, try Self.act(request, root: system.root(of: app), system: system, live: live, app: app))
                }
            }
            let events = AXEventWatcher(stream)
            watcher = events
            var acted = first
            var method = UIMethod.accessibility
            if let plan = acted.input {
                let sent = try await send(plan, what: acted.inputWhat, app: app, snapshot: snapshot, frontBefore: frontBefore, session: session)
                acted.notes += sent.notes
                acted.summary = sent.summary ?? acted.summary
                method = .event
            }
            if !waitsAfter { await settle.wait(on: events) }
            let target = acted.target
            let after = (try? await sessions.run(app, within: sessions.deadlines.action) { UIState.capture(root: system.root(of: app), target: target) })
                ?? acted.before
            if let restoration = await restoreFront(frontBefore, app: app, session: session) { acted.notes.append(restoration.message(app: app)) }

            var text = acted.summary + " " + method.tag + " " + UIState.describe(from: acted.before, to: after).clipped(to: 600)
            if let listing = acted.listing, !listing.isEmpty { text += "\nItens do menu:\n" + listing }
            if !acted.notes.isEmpty { text += "\n" + acted.notes.joined(separator: "\n") }
            return Performed(text: text, watcher: events, before: acted.before, target: target)
        } catch {
            // Failing (or being cancelled) after acting does not leave the person with another app in front.
            watcher?.cancel()
            let restoration = await restoreFront(frontBefore, app: app, session: session)
            guard let restoration, !(error is CancellationError) else { throw error }
            throw ToolError(Self.reason(error) + ".\n" + restoration.message(app: app))
        }
    }

    /// Where a drag with `to_app` lets go: the other app's element or pixel, found in its latest reading of this Orb (the
    /// window server says where its window is now), with the window the system will drop into. Nil when the step is no
    /// such drag, or `to_app` is the app it starts in. Refuses a drop on something that cannot be taken back unless the card said so.
    private func dropTarget(for step: Step, app: AccessibilityApp, bot: UUID?, approved: Bool) async throws -> DropTarget? {
        guard step.action == .drag, let name = step.toApp else { return nil }
        let other = try await UIAccess.open(name, system: system)
        guard other.pid != app.pid else { return nil }
        guard let snapshot = store.snapshot(bot: bot, app: other) else {
            throw ToolError("Ainda não li a interface de \(other.name); chame ui_read (ou screenshot) dele antes de soltar lá.")
        }
        let system = system, live = live
        let reached = try await UIAccess.mapped(other) {
            try await sessions.run(other, within: sessions.deadlines.action) { () throws -> (point: CGPoint, ref: WindowRef, label: String, name: String) in
                let root = system.root(of: other)
                if let pixel = step.destinationPoint {
                    let spot = try Spot.read(snapshot, root: root, app: other)
                    try spot.check(pixel)
                    let label = Self.localHit(pixel, in: snapshot).flatMap { snapshot.entries[$0.id]?.label } ?? ""
                    return (spot.screen(pixel), spot.ref, label, "x \(Int(pixel.x)), y \(Int(pixel.y))")
                }
                let id = try UIResolver.id(for: step.destination ?? "", in: snapshot, app: other)
                let cached = live.element(bot: bot, pid: other.pid, generation: snapshot.generation, takenAt: snapshot.takenAt, id: id)
                let target = try UIResolver.resolve(id: id, root: root, app: other, snapshot: snapshot, cached: cached)
                guard let frame = target.frame, target.window != nil else { throw ToolError("\(target.name) não diz onde está na tela.") }
                return (CGPoint(x: frame.midX, y: frame.midY), Self.windowRef(of: target, in: snapshot), target.live.identity, target.name)
            }
        }
        if !approved, let reason = UIDanger.reason(forDropOnto: reached.label, appName: other.name, bundleID: other.bundleID) {
            throw Self.dropRefusal(reached.name, reason)
        }
        let window = try await eventWindow(reached.ref, app: other, snapshot: snapshot, what: "soltar em \(other.name)")
        return DropTarget(app: other, point: reached.point, window: window, name: "\(reached.name) em \(other.name)")
    }

    static func dropRefusal(_ name: String, _ reason: String) -> ToolError {
        ToolError("Não fiz: soltar em \(name) \(reason), e o pedido não passou pela confirmação do usuário. "
                  + "Leia de novo com ui_read e repita por id para que ele confirme.")
    }

    /// A key or a click of the person's this recent means it was the person who went to the app, not the app that came.
    static let personWentThere: TimeInterval = 2

    /// After every action, and after a failed or cancelled one, the app in front must be the one that was: an app that
    /// brought itself forward is sent back (`AXFrontmost` on the user's app, never `activate`) and remembered as one that
    /// steals focus. Unless the person pressed a key or a button in the last 2 s: then the person went to the app (to
    /// watch, say), and it stays in front and is not taken for one that steals focus. Not cancellable: it runs in its own
    /// task, awaited whatever happens to the caller's.
    private enum FrontRestoration: Sendable {
        case person, restored, changed, failed

        func message(app: AccessibilityApp) -> String {
            switch self {
            case .person: "Aviso: \(app.name) está na frente porque o usuário foi até ele agora; não devolvi o app anterior."
            case .restored: "Aviso: \(app.name) veio para a frente sozinho; devolvi o app que estava na frente. Focar ou digitar nele agora pede takeover."
            case .changed: "Aviso: \(app.name) veio para a frente sozinho, mas o foco mudou; preservei o app que ficou na frente. Focar ou digitar em \(app.name) agora pede takeover."
            case .failed: "Aviso: \(app.name) veio para a frente sozinho; não consegui confirmar a devolução do app anterior. O usuário pode precisar selecioná-lo. Focar ou digitar em \(app.name) agora pede takeover."
            }
        }
    }

    private func restoreFront(_ before: Int32?, app: AccessibilityApp, session: AXAppSession) async -> FrontRestoration? {
        let system = system, sessions = sessions
        return await Task.detached(priority: .userInitiated) {
            guard let before, before != app.pid, await system.frontmostPID() == app.pid else { return nil }
            if system.secondsSinceUserInput() < Self.personWentThere {
                return .person
            }
            session.state.withLock { $0.stealsFocus = true }
            let previous = AccessibilityApp(name: "", bundleID: nil, pid: before)
            guard await system.frontmostPID() == app.pid, system.secondsSinceUserInput() >= Self.personWentThere else { return .changed }
            do { try await sessions.run(previous, within: sessions.deadlines.action) {
                try system.root(of: previous).setValue(.bool(true), for: "AXFrontmost")
            } } catch { return .failed }
            let deadline = ContinuousClock.now + .milliseconds(200)
            while true {
                let front = await system.frontmostPID()
                if front == before { return .restored }
                if let front, front != app.pid { return .changed }
                if ContinuousClock.now >= deadline { return .failed }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }.value
    }

    /// Before keys or text go out: an app that came forward when it got the focus is sent back at once and nothing is sent
    /// (the person's own typing would now land in it).
    private func refuseIfBroughtForward(_ before: Int32?, app: AccessibilityApp, session: AXAppSession, what: String,
                                        front known: Int32?? = .none) async throws {
        guard let before, before != app.pid else { return }
        let front: Int32?
        if case .some(let given) = known { front = given } else { front = await system.frontmostPID() }
        guard front == app.pid else { return }
        // The person went to the app and may be typing in it: nothing is sent, and the app is not sent back.
        try await refuseIfUserIsActive(app, front: .some(front))
        let restoration = await restoreFront(before, app: app, session: session)
        throw Self.needsScreen(what, because: "\(app.name) veio para a frente ao receber o foco"
                               + (restoration.map { ". " + $0.message(app: app) } ?? ""))
    }

    /// The error that tells the model only the real mouse and keyboard can do it (with the user's consent).
    static func needsScreen(_ what: String, because reason: String) -> ToolError {
        ToolError("\(takeoverMarker) Não deu para \(what) em segundo plano: \(reason). Se for preciso, repita com takeover: true "
                  + "(o usuário confirma e o Orb usa o mouse e o teclado reais por alguns segundos); repetir pode duplicar o que já foi feito.")
    }

    // MARK: Events to the app (N1)

    /// What went out to the app: notes for the output, and the summary to use when the events show the action was something
    /// else than it looked (a drag that became a system drag-and-drop).
    struct Sent: Sendable {
        var notes: [String] = []
        var summary: String?
    }

    private func send(_ plan: InputPlan, what: String, app: AccessibilityApp, snapshot: UISnapshot?, frontBefore: Int32?,
                      session: AXAppSession) async throws -> Sent {
        try await refuseIfUserIsActive(app)
        var notes: [String] = []
        switch plan {
        case .drag(let drag):
            return try await send(drag, what: what, app: app, snapshot: snapshot)
        case .click(let point, let window, let click):
            let target = try await eventWindow(window, app: app, snapshot: snapshot, what: what)
            do {
                try await system.input.click(at: point, window: target, button: click.button, count: click.count, modifiers: click.modifiers,
                                             hold: click.hold, to: app.pid)
            } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .move(let points, let window):
            let target = try await eventWindow(window, app: app, snapshot: snapshot, what: what)
            do { try await system.input.move(along: points, window: target, to: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .scroll(let dx, let dy, let point, let window, let modifiers):
            let target = try await eventWindow(window, app: app, snapshot: snapshot, what: what)
            do { try await system.input.scroll(dx: dx, dy: dy, at: point, window: target, modifiers: modifiers, to: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .keys(let strokes, let target):
            if let target {
                try await focus(target, app: app)
                try await refuseIfBroughtForward(frontBefore, app: app, session: session, what: what)
            }
            try await refuseIfUserIsActive(app)
            if system.input.secureInputActive { notes.append(Self.secureInputNote) }
            do { try await system.input.keys(strokes, to: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .text(let text, let target, let replace):
            if system.input.secureInputActive { notes.append(Self.secureInputNote) }
            notes += try await type(text, into: target, replace: replace, app: app, what: what) { [self] front in
                try await refuseIfBroughtForward(frontBefore, app: app, session: session, what: what, front: .some(front))
            }
        }
        return Sent(notes: notes)
    }

    // MARK: Drags and strokes (N1)

    /// Remembers what the drop watch found on top, so the error can say it was that and not the person.
    private final class CoverLog: Sendable {
        private let found = OSAllocatedUnfairLock<String?>(initialState: nil)
        func note(_ owner: String) { found.withLock { $0 = owner } }
        var owner: String? { found.withLock { $0 } }
    }

    /// A drag or a pen stroke sent to the app. A drag that ends in another window or app is a system drag-and-drop, and
    /// the system lets go on whatever is on top at the end point: both ends must show the window the call is about
    /// before anything is pressed. Within one window nothing is checked first (an in-app drag works under a cover); the
    /// watch cancels a drop that starts under one.
    private func send(_ drag: DragPlan, what: String, app: AccessibilityApp, snapshot: UISnapshot?) async throws -> Sent {
        guard drag.path.count >= 2 else { throw ToolError("Não deu para \(what): faltaram pontos no caminho.") }
        let source = try await eventWindow(drag.window, app: app, snapshot: snapshot, what: what)
        let endWindow = drag.drop?.window ?? source
        let endApp = drag.drop?.app ?? app
        let start = drag.path[0].point, end = drag.path[drag.path.count - 1].point
        if drag.drop != nil {
            try await showing(source, at: start, of: app, end: "o arrasto começa")
            try await showing(endWindow, at: end, of: endApp, end: "o arrasto termina")
        }
        let system = system, covered = CoverLog()
        let people = [app] + (drag.drop.map { [$0.app] } ?? [])
        let watch = DragWatch(
            coverAtEnd: {
                // A pen stroke that turned into a drag-and-drop is cancelled whatever is at the end.
                if drag.pen { covered.note(""); return "" }
                guard let top = await system.windowOnTop(at: end), top.windowID != endWindow.id else { return nil }
                covered.note(top.owner)
                return top.owner
            },
            interruption: {
                guard system.secondsSinceUserInput() < 3, let front = await system.frontmostPID(),
                      let used = people.first(where: { $0.pid == front }) else { return nil }
                return "o usuário passou a usar \(used.name)"
            })
        if let reason = await watch.interruption() { throw ToolError("Não deu para \(what): \(reason); nada foi pressionado.") }
        do {
            let outcome = try await system.input.drag(along: drag.path, window: source, modifiers: drag.modifiers, duration: drag.duration,
                                                      watch: watch, to: app.pid)
            return Sent(summary: outcome == .dropped ? drag.droppedSummary : nil)
        } catch let stopped as DragStopped {
            throw Self.stopped(stopped, what: what, pen: drag.pen, coveredBy: covered.owner)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.needsScreen(what, because: Self.reason(error))
        }
    }

    /// Before pressing, the window of a drag's end must be the one on top at its point.
    private func showing(_ window: EventWindow, at point: CGPoint, of app: AccessibilityApp, end: String) async throws {
        guard let top = await system.windowOnTop(at: point), top.windowID != window.id else { return }
        let who = top.pid == app.pid ? "outra janela de \(app.name)" : (top.owner.isEmpty ? "outra janela" : top.owner)
        throw ToolError("Nada foi pressionado: \(who) está por cima de onde \(end) (\(app.name)), e um arrasto entre janelas ou apps "
                        + "segue o que está por cima. Traga a janela de \(app.name) para a vista, ou repita com takeover: true.")
    }

    /// A drag that stopped early. No marker for the person's sake, nor for a drop the watch cancelled; a pen stroke that
    /// started a drag-and-drop, or a drop under a cover, can be redone once the way is clear (or with the real mouse).
    private static func stopped(_ stopped: DragStopped, what: String, pen: Bool, coveredBy owner: String?) -> ToolError {
        if pen, owner != nil {
            return ToolError("Não deu para \(what): o traço começou um arrastar e soltar do app (o ponto de partida tem algo que se arrasta), "
                             + "e cancelei com Esc antes de soltar; nada foi solto. Comece o traço numa área livre do desenho, ou repita com takeover: true.")
        }
        if owner != nil {
            return ToolError("\(takeoverMarker) Não deu para \(what): \(reason(stopped)). Tire o que está por cima do ponto de soltar "
                             + "(ou traga a janela de destino para a vista) e repita, ou repita com takeover: true.")
        }
        return ToolError("Não deu para \(what): \(reason(stopped)).")
    }

    static let secureInputNote = "Aviso: a Entrada Segura do macOS está ligada (um campo de senha em algum app); teclas podem ter sido descartadas."

    private static func reason(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// Events go to the app's process, not to the keyboard focus; still, a person typing in that very app right now would
    /// be typed over.
    /// `front`: the app in front when the caller has just asked (each asking reads the window list and an app).
    private func refuseIfUserIsActive(_ app: AccessibilityApp, front known: Int32?? = .none) async throws {
        let front: Int32?
        if case .some(let given) = known { front = given } else { front = await system.frontmostPID() }
        guard front == app.pid, system.secondsSinceUserInput() < 3 else { return }
        throw ToolError("O usuário está usando \(app.name) agora (mexeu no teclado ou no mouse há menos de 3 s); não mandei nada para não atrapalhar. "
                        + "Espere um pouco e tente de novo, ou peça a ele.")
    }

    /// The window an event goes to, by its `CGWindowID` and where it is now: the one the screenshot captured when it is
    /// the same window, else the window the app has with the same frame (±2 pt) and title. Windows come from the window
    /// server's list, which needs no permission (the title may be missing without Screen Recording: then the frame
    /// decides); ScreenCaptureKit, which needs Screen Recording, only when that list has nothing for the app.
    private func eventWindow(_ window: WindowRef, app: AccessibilityApp, snapshot: UISnapshot?, what: String) async throws -> EventWindow {
        let known = window.windowID ?? snapshot?.shot.flatMap { shot in
            window.frame.map { Self.close(shot.windowFrame, $0) } == true ? shot.windowID : nil
        }
        let listed = system.windowList(pid: app.pid).sorted { $0.isOnScreen && !$1.isOnScreen }
        if let known {
            // The window of the screenshot must still exist (a new window can reuse the frame, not the number).
            let current = listed.isEmpty ? ((try? await system.capturer.refreshedWindows(pid: app.pid)) ?? []) : listed
            if !current.isEmpty, !current.contains(where: { $0.windowID == known }) {
                throw UIResolver.stale("a janela do screenshot não existe mais; tire outro")
            }
            let frame = current.first { $0.windowID == known }?.frame ?? window.frame ?? snapshot?.shot?.windowFrame
            guard let frame else { throw Self.needsScreen(what, because: "não sei onde está a janela \(UIText.quoted(window.title))") }
            return EventWindow(id: known, frame: frame)
        }
        let windows: [CapturableWindow]
        if !listed.isEmpty {
            windows = listed
        } else {
            do { windows = try await system.capturer.refreshedWindows(pid: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        }
        let match = windows.first { candidate in
            window.frame.map { Self.close(candidate.frame, $0) } ?? true && UIText.fold(candidate.title) == UIText.fold(window.title)
        } ?? windows.first { candidate in window.frame.map { Self.close(candidate.frame, $0) } ?? false }
        guard let match else { throw Self.needsScreen(what, because: "não achei a janela \(UIText.quoted(window.title)) para mandar o evento") }
        return EventWindow(id: match.windowID, frame: match.frame)
    }

    static func close(_ one: CGRect, _ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }

    /// Gives the element the app's keyboard focus (`AXFocused` on the element only, never on a window) and checks that
    /// the app's focused element is now it.
    private func focus(_ target: any AccessibilityElement, app: AccessibilityApp, replace: Bool = false) async throws {
        let system = system
        try await UIAccess.mapped(app) {
            try await sessions.run(app, within: sessions.deadlines.action) {
                if target.isSettable("AXFocused") { try? target.setValue(.bool(true), for: "AXFocused") }
                if replace, case .number(let length)? = target.attribute("AXNumberOfCharacters") {
                    try? target.setValue(.range(AXTextRange(location: 0, length: Int(length))), for: "AXSelectedTextRange")
                }
                try Self.confirmFocus(on: target, root: system.root(of: app), app: app)
            }
        }
    }

    static func confirmFocus(on target: any AccessibilityElement, root: any AccessibilityElement, app: AccessibilityApp) throws {
        guard let focused = root.element("AXFocusedUIElement"), focused.isSame(as: target) else { throw focusLost(app) }
    }

    static func focusLost(_ app: AccessibilityApp) -> ToolError {
        ToolError("O foco de \(app.name) não está no campo pedido; não mandei nada. Leia de novo com ui_read e diga o id do campo.")
    }

    /// In one round trip: whether the app's focus is still on `target`, and whether the app says it is in front (nil
    /// when it does not say).
    static func focusAndFront(of target: any AccessibilityElement, root: any AccessibilityElement) -> (focusHeld: Bool, inFront: Bool?) {
        let values = root.attributes(["AXFocusedUIElement", "AXFrontmost"])
        return (values["AXFocusedUIElement"]?.element.map { $0.isSame(as: target) } ?? false, values["AXFrontmost"]?.bool)
    }

    /// Types in chunks of at most 20 UTF-16 units, checking before each one that the focus is still on the field and the
    /// user is not using the app; stops between chunks when the task is cancelled and says how much went in.
    /// `checkFront` runs right after the focus is given and before every chunk, with the app in front then: it throws when
    /// the app came forward.
    private func type(_ text: String, into target: any AccessibilityElement, replace: Bool, app: AccessibilityApp, what: String,
                      checkFront: @Sendable (Int32?) async throws -> Void) async throws -> [String] {
        try await focus(target, app: app, replace: replace)
        let front = await system.frontmostPID()
        try await checkFront(front)
        try await refuseIfUserIsActive(app, front: .some(front))
        if text.isEmpty, replace {
            // Nothing to type: replacing with nothing is select all and delete (the selection `focus` made may not exist).
            do {
                try await system.input.keys([KeyStroke(.character("a"), modifiers: [.command]), KeyStroke(.named(.delete))], to: app.pid)
            } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
            return []
        }
        let chunks = Self.chunks(text)
        let total = text.count
        var sent = 0
        let system = system
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return ["Parei a pedido: digitei \(sent) de \(total) caracteres."] }
            if index > 0 {
                do {
                    // One question to the app per chunk: where its focus is and whether it is in front (only the app's own
                    // answer matters here: is it this app). Asking the whole desktop which app is in front, a hundred
                    // times for 2,000 characters, cost more than the typing.
                    let (focusHeld, inFront) = try await UIAccess.mapped(app) {
                        try await sessions.run(app, within: sessions.deadlines.action) {
                            Self.focusAndFront(of: target, root: system.root(of: app))
                        }
                    }
                    var front: Int32?
                    if let inFront { front = inFront ? app.pid : nil } else { front = await system.frontmostPID() }
                    try await checkFront(front)
                    try await refuseIfUserIsActive(app, front: .some(front))
                    if !focusHeld { throw Self.focusLost(app) }
                } catch is CancellationError {
                    return ["Parei a pedido: digitei \(sent) de \(total) caracteres."]
                } catch {
                    throw ToolError("Digitei \(sent) de \(total) caracteres e parei: \(Self.reason(error)).")
                }
            }
            do {
                sent += try await system.input.text(chunk, to: app.pid)
            } catch {
                if sent == 0 { throw Self.needsScreen(what, because: Self.reason(error)) }
                throw ToolError("Digitei \(sent) de \(total) caracteres e parei: \(Self.reason(error)).")
            }
        }
        return []
    }

    /// Pieces of at most `size` UTF-16 units, never splitting a character.
    static func chunks(_ text: String, size: Int = 20) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > size, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Waiting after acting

    private func waitAfter(_ wanted: String, app: AccessibilityApp, context: ToolContext, timeout: Duration, last: Performed) async throws -> String {
        if UIText.fold(wanted) == "changes" {
            let clock = ContinuousClock()
            let started = clock.now
            let system = system
            let target = last.target
            let ticks = UIWaiter(system: system, sessions: sessions, store: store, live: live)
            var looks = 0
            while started.duration(to: clock.now) < timeout {
                let seen = last.watcher.count
                if last.watcher.events.contains(where: { UIWaiter.changeNotifications.contains($0.notification) }) {
                    return "(esperei \(UIClock.seconds(started.duration(to: clock.now))): mudou)"
                }
                let now = try await sessions.run(app, within: sessions.deadlines.action) { UIState.capture(root: system.root(of: app), target: target) }
                if now != last.before { return "(esperei \(UIClock.seconds(started.duration(to: clock.now))): mudou)" }
                let left = timeout - started.duration(to: clock.now)
                guard left > .zero else { break }
                let pause = min(ticks.tick(after: looks), left)
                looks += 1
                if last.watcher.isFinished {
                    try await Task.sleep(for: pause)
                } else {
                    await last.watcher.waitForMore(than: seen, timeout: pause)
                }
            }
            return "(não aconteceu em \(UIClock.seconds(timeout)))"
        }
        let waiter = UIWaiter(system: system, sessions: sessions, store: store, live: live)
        return try await waiter.wait(.appears(wanted), app: app, window: nil, bot: context.botID, timeout: timeout, watcher: last.watcher)
    }

    // MARK: The Accessibility part, on the app's queue

    /// The action itself, as far as Accessibility goes; what still needs events sent to the app comes back in `input`.
    /// Blocking: runs on the app's queue. Throws `ToolError` for what the model can fix and `AXFailure` for what the API
    /// refused.
    static func act(_ request: Request, root: any AccessibilityElement, system: any AccessibilitySystem, live: UILiveElements,
                    app: AccessibilityApp) throws -> Acted {
        let step = request.step
        let snapshot = request.snapshot

        func resolve(_ reference: String) throws -> UIResolver.Resolved {
            let id = try UIResolver.id(for: reference, in: snapshot, app: app)
            let cached = snapshot.flatMap { live.element(bot: request.bot, pid: app.pid, generation: $0.generation, takenAt: $0.takenAt, id: id) }
            return try UIResolver.resolve(id: id, root: root, app: app, snapshot: snapshot, cached: cached)
        }

        /// A live name that turns out dangerous runs only if the approval card judged the call dangerous too.
        func checkDanger(_ label: String, _ name: String) throws {
            guard !request.approved, let reason = UIDanger.reason(forLabel: label, appName: app.name, bundleID: app.bundleID) else { return }
            throw ToolError("Não fiz: \(name) \(reason), e o pedido não passou pela confirmação do usuário. "
                            + "Leia de novo com ui_read e repita por id (ou use pick_menu) para que ele confirme.")
        }

        func checkSecure(_ target: UIResolver.Resolved?, focusedSecure: Bool = false) throws {
            guard !request.approved, target?.live.secure == true || focusedSecure else { return }
            throw ToolError("Não fiz: é um campo de senha, e preencher senha sempre passa pela confirmação do usuário. Repita por id para que ele confirme.")
        }

        /// Whether the focused element is a password field. An app that does not answer is not taken for "no": nothing is
        /// typed where it cannot be told.
        func isSecure(_ focused: any AccessibilityElement) throws -> Bool {
            switch focused.read(UIElementInfo.attributeNames) {
            case .values(let values): return UIElementInfo(attributes: values).secure
            case .failed(let failure): throw failure
            }
        }

        /// A line break is typed as Return: in a mail or chat app that sends, so it runs only if the card said so.
        func checkLineBreaks(_ value: String?) throws {
            guard !request.approved, let value, hasLineBreak(value),
                  let reason = UIDanger.reason(forKeys: [returnKey], appName: app.name, bundleID: app.bundleID) else { return }
            throw ToolError("Não fiz: \(lineBreakReason(reason)), e o pedido não passou pela confirmação do usuário. "
                            + "Repita dizendo o app (argumento app) para que ele confirme, ou mande o texto sem quebra de linha.")
        }

        func windowRef(_ target: UIResolver.Resolved) -> WindowRef { Self.windowRef(of: target, in: snapshot) }

        /// A place the call points at, on the screen: an element by id, or a pixel of the last screenshot.
        func place(_ reference: String?, _ pixel: CGPoint?) throws -> Place {
            if let pixel {
                let spot = try Spot.read(snapshot, root: root, app: app)
                try spot.check(pixel)
                let label = snapshot.flatMap { localHit(pixel, in: $0) }.flatMap { snapshot?.entries[$0.id]?.label } ?? ""
                return Place(point: spot.screen(pixel), window: spot.ref, name: "x \(Int(pixel.x)), y \(Int(pixel.y))", label: label, element: nil)
            }
            let target = try resolve(reference ?? "")
            guard let frame = target.frame, target.window != nil else { throw missing(target, "clique", target.element.actionNames()) }
            return Place(point: CGPoint(x: frame.midX, y: frame.midY), window: windowRef(target), name: target.name, label: target.live.identity,
                         element: target.element)
        }

        /// Letting go on something that cannot be taken back runs only if the approval card said so.
        func checkDrop(_ label: String, _ name: String) throws {
            guard !request.approved, let reason = UIDanger.reason(forDropOnto: label, appName: app.name, bundleID: app.bundleID) else { return }
            throw dropRefusal(name, reason)
        }

        func missing(_ target: UIResolver.Resolved, _ what: String, _ actions: [String]) -> ToolError {
            let known = actions.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
            let subject = target.name.prefix(1).uppercased() + target.name.dropFirst()
            return ToolError("\(subject) não aceita \(what)." + (known.isEmpty ? "" : " Ações dele: " + known.joined(separator: ", ") + "."))
        }

        func before(_ target: UIResolver.Resolved?) -> UIState {
            UIState.capture(root: root, target: target?.element, known: target?.attributes)
        }

        /// Press, confirm or pick; select a row; else a click sent to the app at the element's center.
        func press(_ target: UIResolver.Resolved, verb: String = "Cliquei em") throws -> Acted {
            try checkDanger(target.live.identity, target.name)
            let state = before(target)
            let actions = target.element.actionNames()
            if let action = ["AXPress", "AXConfirm", "AXPick", "AXOpen"].first(where: actions.contains) {
                try target.element.perform(action)
                return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            if target.element.isSettable("AXSelected") {
                let context = UIRowSelection.context(of: target.element, role: target.live.rawRole)
                if UIRowSelection.select([target.element], in: context?.container) {
                    return Acted(summary: "Selecionei \(target.name) (\(target.id)).", target: target.element, before: state)
                }
            }
            // A wrapper without actions around one control: pressing that control needs no event.
            let inner = (target.element.elements("AXChildren") ?? []).filter { !UIOutlineBuilder.clickActions.isDisjoint(with: $0.actionNames()) }
            if inner.count == 1, let action = ["AXPress", "AXConfirm", "AXPick", "AXOpen"].first(where: inner[0].actionNames().contains) {
                let label = UIElementInfo(attributes: inner[0].attributes(UIElementInfo.attributeNames)).identity
                try checkDanger(label, target.name)
                try inner[0].perform(action)
                return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            guard let frame = target.frame, target.window != nil else { throw missing(target, "clique", actions) }
            return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: state,
                         input: .click(CGPoint(x: frame.midX, y: frame.midY), window: windowRef(target), Clicking()),
                         inputWhat: "clicar em \(target.name)")
        }

        switch step.action {
        case .pickMenu:
            let state = UIState.capture(root: root, target: nil)
            let found = try UIMenu.resolve(step.menuPath, root: root, app: app)
            try checkDanger(found.titles.last ?? "", "o item \(UIText.quoted(found.titles.joined(separator: " → ")))")
            do { try found.element.perform("AXPress") } catch AXFailure.notSupported {
                throw ToolError("Esse item de menu de \(app.name) não aceita clique.")
            }
            return Acted(summary: "Escolhi \(found.titles.joined(separator: " → ")) em \(app.name).", target: nil, before: state)

        case .press:
            return try press(try resolve(step.reference ?? ""))

        case .click:
            if let point = step.point { return try click(at: point, request: request, root: root, system: system, app: app, resolve: resolve, press: press) }
            let target = try resolve(step.reference ?? "")
            if step.clicking.isPlain { return try press(target) }
            try checkDanger(target.live.identity, target.name)
            guard let frame = target.frame, target.window != nil else { throw missing(target, "clique", target.element.actionNames()) }
            return Acted(summary: "\(clickVerb(step.clicking)) \(target.name) (\(target.id)).", target: target.element, before: before(target),
                         input: .click(CGPoint(x: frame.midX, y: frame.midY), window: windowRef(target), step.clicking),
                         inputWhat: "clicar em \(target.name)")

        case .move:
            let spot = try place(step.reference, step.point)
            return Acted(summary: "Passei o mouse sobre \(spot.name).", target: spot.element, before: UIState.capture(root: root, target: spot.element),
                         input: .move(approach(to: spot.point, within: spot.window.frame), window: spot.window),
                         inputWhat: "passar o mouse sobre \(spot.name)", notes: [hoverNote])

        case .drag:
            let source = try place(step.reference, step.point)
            try checkDanger(source.label, source.name)
            let end: (point: CGPoint, name: String)
            if let remote = request.remote {
                end = (remote.point, remote.name)
            } else {
                let destination = try place(step.destination, step.destinationPoint)
                try checkDrop(destination.label, destination.name)
                end = (destination.point, destination.name)
            }
            let drag = DragPlan(path: DragPath.arc(from: source.point, to: end.point).map { StrokePoint(point: $0) }, window: source.window,
                                drop: request.remote, modifiers: step.modifiers, duration: step.duration ?? .milliseconds(500),
                                droppedSummary: "Arrastei \(source.name) e soltei em \(end.name) (arrastar e soltar do sistema).")
            return Acted(summary: "Arrastei \(source.name) até \(end.name).", target: nil, before: UIState.capture(root: root, target: source.element),
                         input: .drag(drag), inputWhat: "arrastar \(source.name)")

        case .draw:
            let spot = try Spot.read(snapshot, root: root, app: app)
            for (index, point) in step.stroke.enumerated() { try spot.check(point.point, number: index + 1) }
            let path = DragPath.stroke(step.stroke.map { StrokePoint(point: spot.screen($0.point), pressure: $0.pressure) })
            let drag = DragPlan(path: path, window: spot.ref, duration: step.duration ?? strokeDuration(path), pen: true)
            return Acted(summary: "Desenhei um traço de \(step.stroke.count) pontos em \(spot.ref.title.isEmpty ? app.name : UIText.quoted(spot.ref.title)).",
                         target: nil, before: UIState.capture(root: root, target: nil), input: .drag(drag), inputWhat: "desenhar")

        case .focus:
            let target = try resolve(step.reference ?? "")
            if request.stealsFocus {
                throw needsScreen("focar \(target.name)", because: "\(app.name) vem para a frente sozinho quando recebe foco")
            }
            let state = before(target)
            do { try target.element.setValue(.bool(true), for: "AXFocused") } catch AXFailure.notSupported {
                throw missing(target, "foco", target.element.actionNames())
            }
            return Acted(summary: "Dei foco a \(target.name) (\(target.id)).", target: target.element, before: state)

        case .setValue:
            let target = try resolve(step.reference ?? "")
            try checkSecure(target)
            try checkLineBreaks(step.value)
            let value = step.value ?? ""
            let state = before(target)
            let textRoles: Set<String> = ["field", "textarea", "searchfield", "combobox"]
            guard target.element.isSettable("AXValue") else {
                // An editable field in an app that steals focus is a takeover case, not a read-only one.
                if textRoles.contains(target.live.role), request.stealsFocus {
                    throw needsScreen("escrever em \(target.name)", because: "\(app.name) vem para a frente sozinho quando recebe foco")
                }
                guard textRoles.contains(target.live.role) else {
                    throw missing(target, "receber um valor (não é um campo editável)", target.element.actionNames())
                }
                return Acted(summary: value.isEmpty ? "Limpei \(target.name) (\(target.id))." : "Escrevi em \(target.name) (\(target.id)).",
                             target: target.element, before: state,
                             input: .text(value, target: target.element, replace: true), inputWhat: "escrever em \(target.name)")
            }
            let newValue = settableValue(value, current: target.live.secure ? nil : target.element.attribute("AXValue"))
            try target.element.setValue(newValue, for: "AXValue")
            // Fields driven by a page's script ignore AXValue: then the text is typed.
            if case .string(let wanted) = newValue, !target.live.secure, textRoles.contains(target.live.role),
               let back = target.element.attribute("AXValue")?.string, back != wanted {
                if request.stealsFocus {
                    throw needsScreen("escrever em \(target.name)", because: "o campo ignorou o valor por Acessibilidade e \(app.name) vem para a frente sozinho quando recebe foco")
                }
                return Acted(summary: value.isEmpty ? "Limpei \(target.name) (\(target.id))." : "Escrevi em \(target.name) (\(target.id)).",
                             target: target.element, before: state,
                             input: .text(value, target: target.element, replace: true), inputWhat: "escrever em \(target.name)",
                             notes: ["O campo ignorou o valor por Acessibilidade; " + (value.isEmpty ? "apaguei o texto com o teclado." : "digitei o texto.")])
            }
            return Acted(summary: "Escrevi em \(target.name) (\(target.id)).", target: target.element, before: state)

        case .type:
            let target: UIResolver.Resolved? = try step.reference.map(resolve)
            if request.stealsFocus { throw needsScreen("digitar em \(app.name)", because: "\(app.name) vem para a frente sozinho quando recebe foco") }
            let element: any AccessibilityElement
            var focusedSecure = false
            if let target {
                element = target.element
            } else {
                guard let focused = root.element("AXFocusedUIElement") else {
                    throw ToolError("Nenhum campo de \(app.name) tem o foco; diga o id do campo (de ui_read).")
                }
                element = focused
                focusedSecure = try isSecure(focused)
            }
            try checkSecure(target, focusedSecure: focusedSecure)
            try checkLineBreaks(step.value)
            let name = target.map { "\($0.name) (\($0.id))" } ?? "o campo em foco"
            return Acted(summary: "Digitei \(step.value?.count ?? 0) caractere\(step.value?.count == 1 ? "" : "s") em \(name).", target: element,
                         before: UIState.capture(root: root, target: element, known: target?.attributes),
                         input: .text(step.value ?? "", target: element, replace: false), inputWhat: "digitar em \(name)")

        case .key:
            let target: UIResolver.Resolved? = try step.reference.map(resolve)
            var focusedSecure = false
            if target == nil, let focused = root.element("AXFocusedUIElement") {
                focusedSecure = try isSecure(focused)
            }
            try checkSecure(target, focusedSecure: focusedSecure)
            if !request.approved, let reason = UIDanger.reason(forKeys: step.keys, appName: app.name, bundleID: app.bundleID) {
                throw ToolError("Não fiz: \(reason), e o pedido não passou pela confirmação do usuário. Repita dizendo o app (argumento app) para que ele confirme.")
            }
            if let stroke = step.keys.first(where: { UIFocusKeys.pulls($0, bundleID: app.bundleID) }) {
                throw needsScreen("teclar \(stroke) em \(app.name)", because: "esse atalho puxa o foco ou troca a aba à vista mesmo em segundo plano")
            }
            let state = UIState.capture(root: root, target: target?.element, known: target?.attributes)
            // A shortcut of the menu bar is pressed as its menu item: no keyboard layout involved, works in the background.
            if step.keys.count == 1, let stroke = step.keys.first, !stroke.modifiers.isDisjoint(with: [.command, .control]),
               let item = UIMenu.item(for: stroke, root: root) {
                // The key would die on the same disabled item, and macOS disables some (Save) just for being behind.
                guard item.enabled else {
                    throw needsScreen("usar \(stroke) em \(app.name)", because: "o item \(UIText.quoted(item.titles.joined(separator: " → "))) está desativado com o app em segundo plano; se ele tem AppleScript, tente por lá")
                }
                try checkDanger(item.titles.last ?? "", "o item \(UIText.quoted(item.titles.joined(separator: " → ")))")
                try item.element.perform("AXPress")
                return Acted(summary: "Usei \(stroke) pelo menu \(item.titles.joined(separator: " → ")) de \(app.name).", target: target?.element, before: state)
            }
            if request.stealsFocus, target != nil { throw needsScreen("teclar em \(app.name)", because: "\(app.name) vem para a frente sozinho quando recebe foco") }
            let name = target.map { " em \($0.name) (\($0.id))" } ?? ""
            return Acted(summary: "Teclei \(step.keys.map(\.description).joined(separator: ", "))\(name).", target: target?.element, before: state,
                         input: .keys(step.keys, target: target?.element), inputWhat: "teclar \(step.keysText)")

        case .select:
            return try select(step, resolve: resolve, root: root, app: app, before: before, press: press, checkDanger: checkDanger)

        case .scroll:
            if let pixel = step.point {
                guard let direction = step.direction else { throw ToolError("Diga direction (up, down, left ou right) para rolar em x \(Int(pixel.x)), y \(Int(pixel.y)).") }
                let spot = try place(nil, pixel)
                let delta = scrollDelta(direction, amount: step.amount, size: spot.window.frame?.size ?? .zero, modifiers: step.modifiers)
                return Acted(summary: "Rolei \(spot.name) \(scrollWords(direction, amount: step.amount, modifiers: step.modifiers)).", target: nil,
                             before: UIState.capture(root: root, target: nil),
                             input: .scroll(dx: delta.dx, dy: delta.dy, at: spot.point, window: spot.window, modifiers: step.modifiers),
                             inputWhat: "rolar em \(spot.name)")
            }
            let target = try resolve(step.reference ?? "")
            let state = before(target)
            let actions = target.element.actionNames()
            guard let direction = step.direction else {
                guard actions.contains("AXScrollToVisible") else {
                    throw ToolError("Diga direction (up, down, left ou right) para rolar \(target.name).")
                }
                try target.element.perform("AXScrollToVisible")
                return Acted(summary: "Rolei até \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            return try scroll(target, direction: direction, amount: step.amount, modifiers: step.modifiers, before: state, windowRef: windowRef(target))

        case .increment, .decrement:
            let target = try resolve(step.reference ?? "")
            let state = before(target)
            let actions = target.element.actionNames()
            let action = step.action == .increment ? "AXIncrement" : "AXDecrement"
            guard actions.contains(action) else { throw missing(target, step.action == .increment ? "aumentar" : "diminuir", actions) }
            try target.element.perform(action)
            return Acted(summary: "\(step.action == .increment ? "Aumentei" : "Diminuí") \(target.name) (\(target.id)).", target: target.element, before: state)

        case .showMenu:
            let target = try resolve(step.reference ?? "")
            let state = before(target)
            // Menus are read without opening them: an open menu is visible and modal.
            let items = UIMenu.items(under: target.element)
            guard !items.isEmpty else {
                throw needsScreen("abrir o menu de \(target.name)", because: "esse menu só existe aberto, e abrir um menu toma a tela")
            }
            return Acted(summary: "Abri o menu de \(target.name) (\(target.id)) por Acessibilidade, sem mostrá-lo na tela.", target: nil, before: state,
                         listing: UIMenu.listing(of: items))
        }
    }

    /// A click at a point of the last screenshot: the element there in the reading (the smallest that contains it, then
    /// its nearest actionable ancestor), confirmed by the app's own hit test when that finds something else on top.
    private static func click(at pixel: CGPoint, request: Request, root: any AccessibilityElement, system: any AccessibilitySystem,
                              app: AccessibilityApp, resolve: (String) throws -> UIResolver.Resolved,
                              press: (UIResolver.Resolved, String) throws -> Acted) throws -> Acted {
        let step = request.step
        let spot = try Spot.read(request.snapshot, root: root, app: app)
        try spot.check(pixel)
        guard let snapshot = request.snapshot else { throw Spot.missingShot(app) }
        let screen = spot.screen(pixel), window = spot.window, windowRef = spot.ref
        let description = "x \(Int(pixel.x)), y \(Int(pixel.y))"

        let local = localHit(pixel, in: snapshot)
        let target = try local.map { try resolve($0.id) }
        // The app's hit test sees what is really on top (a popover, a sheet); it is z-ordered, so a covered window answers
        // nothing and the reading decides. It sees every window of the app, though: what it finds in another window (one
        // over the screenshot's) is not what the click is about, and the reading decides then too.
        func atThePoint() -> Acted {
            Acted(summary: "\(clickVerb(step.clicking)) \(description) de \(snapshot.windowTitle.isEmpty ? app.name : UIText.quoted(snapshot.windowTitle)).",
                  target: nil, before: UIState.capture(root: root, target: nil),
                  input: .click(screen, window: windowRef, step.clicking), inputWhat: "clicar em \(description)")
        }
        if let hit = system.hitTest(app, at: screen), belongs(hit, to: window), !(target.map { related(hit, to: $0.element) } ?? false) {
            // The window itself: nothing Accessibility knows is there (a canvas), so whatever the reading has at the point (a
            // row scrolled out of view) is not it either.
            if hit.isSame(as: window) { return atThePoint() }
            var element: any AccessibilityElement = hit
            for _ in 0..<5 where clickable(element) == false {
                guard let parent = element.element("AXParent"), !parent.isSame(as: window) else { break }
                element = parent
            }
            let info = UIElementInfo(attributes: element.attributes(UIElementInfo.attributeNames))
            let name = info.role + (info.identity.isEmpty ? "" : " " + UIText.quoted(info.identity))
            if !request.approved, let reason = UIDanger.reason(forLabel: info.identity, appName: app.name, bundleID: app.bundleID) {
                throw ToolError("Não fiz: \(name) \(reason), e o pedido não passou pela confirmação do usuário. "
                                + "Leia de novo com ui_read e repita por id para que ele confirme.")
            }
            let state = UIState.capture(root: root, target: element)
            if step.clicking.isPlain, let action = ["AXPress", "AXConfirm", "AXPick", "AXOpen"].first(where: element.actionNames().contains) {
                try element.perform(action)
                return Acted(summary: "Cliquei em \(name) (\(description)).", target: element, before: state)
            }
            return Acted(summary: "\(clickVerb(step.clicking)) \(name) (\(description)).", target: element, before: state,
                         input: .click(screen, window: windowRef, step.clicking), inputWhat: "clicar em \(description)")
        }
        if let target {
            if step.clicking.isPlain, target.entry.actionable || local?.actionable == true {
                return try press(target, "Cliquei em")
            }
            let state = UIState.capture(root: root, target: target.element, known: target.attributes)
            return Acted(summary: "\(clickVerb(step.clicking)) \(target.name) (\(target.id), \(description)).", target: target.element, before: state,
                         input: .click(screen, window: windowRef, step.clicking), inputWhat: "clicar em \(target.name)")
        }
        return atThePoint()
    }

    /// Whether `element` is in `window`, or in a sheet or drawer of it: its `AXWindow` (or that window's parent) is the
    /// window, or, for an element that does not say, the window is among its ancestors.
    static func belongs(_ element: any AccessibilityElement, to window: any AccessibilityElement) -> Bool {
        if element.isSame(as: window) { return true }
        if let own = element.element("AXWindow") {
            return own.isSame(as: window) || own.element("AXParent")?.isSame(as: window) == true
        }
        var current = element.element("AXParent")
        for _ in 0..<16 {
            guard let node = current else { return false }
            if node.isSame(as: window) { return true }
            current = node.element("AXParent")
        }
        return false
    }

    private static func clickable(_ element: any AccessibilityElement) -> Bool {
        !UIOutlineBuilder.clickActions.isDisjoint(with: element.actionNames())
    }

    /// Whether `hit` is `element` or lies inside it.
    private static func related(_ hit: any AccessibilityElement, to element: any AccessibilityElement) -> Bool {
        var current: (any AccessibilityElement)? = hit
        for _ in 0..<8 {
            guard let node = current else { return false }
            if node.isSame(as: element) { return true }
            current = node.element("AXParent")
        }
        return false
    }

    /// The entry at a pixel of the snapshot's screenshot: the smallest frame that contains it, then the nearest
    /// actionable entry among it and its ancestors (at most 5 levels up). Nil when nothing in the reading is there.
    static func localHit(_ pixel: CGPoint, in snapshot: UISnapshot) -> (id: String, actionable: Bool)? {
        guard let shot = snapshot.shot, shot.scale > 0 else { return nil }
        let point = CGPoint(x: pixel.x / shot.scale, y: pixel.y / shot.scale)
        let containing = snapshot.entries.filter {
            $0.key.hasPrefix("w") && ($0.value.frame?.contains(point) ?? false) && !scrolledAway($0.key, at: point, in: snapshot.entries)
        }
        guard let smallest = containing.min(by: { area($0.value.frame) < area($1.value.frame) || (area($0.value.frame) == area($1.value.frame) && $0.key.count > $1.key.count) }) else {
            return nil
        }
        var id = smallest.key
        for _ in 0...5 {
            if snapshot.entries[id]?.actionable == true { return (id, true) }
            guard let dot = id.lastIndex(of: ".") else { break }
            id = String(id[..<dot])
        }
        return (smallest.key, false)
    }

    private static func area(_ frame: CGRect?) -> CGFloat { frame.map { $0.width * $0.height } ?? .infinity }

    /// Whether a scroll area around the entry leaves the point out: a row scrolled out of view keeps a frame, under whatever
    /// the window shows below the list.
    private static func scrolledAway(_ id: String, at point: CGPoint, in entries: [String: UISnapshot.Entry]) -> Bool {
        var id = Substring(id)
        while let dot = id.lastIndex(of: ".") {
            id = id[..<dot]
            if let entry = entries[String(id)], entry.rawRole == "AXScrollArea", let frame = entry.frame, !frame.contains(point) { return true }
        }
        return false
    }

    /// A place a call points at, on the screen.
    struct Place: Sendable {
        var point: CGPoint
        var window: WindowRef
        /// How the output names it: `button “Salvar”`, or `x 10, y 20` for a pixel.
        var name: String
        /// What the danger check reads: the element's name, empty when none is known.
        var label: String
        var element: (any AccessibilityElement)?
    }

    /// The pixels of an app's last screenshot, put on the screen: where its window is now, and how big the picture is.
    struct Spot: Sendable {
        var origin: CGPoint
        var size: CGSize
        var scale: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var window: any AccessibilityElement
        var ref: WindowRef

        static func missingShot(_ app: AccessibilityApp) -> ToolError {
            ToolError("x, y e path são pixels do último screenshot com marcas da janela; tire um screenshot de \(app.name) antes (ou use um id).")
        }

        /// Reads where the window is now. It must still have the size it had in the picture, or the pixels point elsewhere.
        /// Blocking: runs on the app's queue.
        static func read(_ snapshot: UISnapshot?, root: any AccessibilityElement, app: AccessibilityApp) throws -> Spot {
            guard let snapshot, let shot = snapshot.shot, shot.scale > 0 else { throw missingShot(app) }
            guard let windows = root.elements("AXWindows"), let window = UIWindowChooser.window(of: snapshot, in: windows) else {
                throw UIResolver.stale("a janela \(UIText.quoted(snapshot.windowTitle)) não está mais aberta")
            }
            let now = window.read(["AXPosition", "AXSize"]).attributes ?? [:]
            guard case .point(let origin)? = now["AXPosition"], case .size(let size)? = now["AXSize"] else {
                throw UIResolver.stale("não consegui ler onde está a janela")
            }
            guard abs(size.width - shot.windowFrame.width) <= 2, abs(size.height - shot.windowFrame.height) <= 2 else {
                throw UIResolver.stale("a janela mudou de tamanho desde o screenshot; tire outro")
            }
            return Spot(origin: origin, size: shot.windowFrame.size, scale: shot.scale, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight,
                        window: window, ref: WindowRef(frame: CGRect(origin: origin, size: size), title: snapshot.windowTitle, windowID: shot.windowID))
        }

        func screen(_ pixel: CGPoint) -> CGPoint { CGPoint(x: origin.x + pixel.x / scale, y: origin.y + pixel.y / scale) }

        /// The pixel must be inside the picture (`number`: which point of a path).
        func check(_ pixel: CGPoint, number: Int? = nil) throws {
            guard CGRect(origin: .zero, size: size).contains(CGPoint(x: pixel.x / scale, y: pixel.y / scale)) else {
                let which = number.map { "O ponto \($0) de path (x \(Int(pixel.x)), y \(Int(pixel.y)))" } ?? "O ponto x \(Int(pixel.x)), y \(Int(pixel.y))"
                throw ToolError("\(which) fica fora da imagem (\(pixelWidth)×\(pixelHeight) px).")
            }
        }
    }

    /// The window an element is in, as the reading and the screenshot knew it.
    static func windowRef(of target: UIResolver.Resolved, in snapshot: UISnapshot?) -> WindowRef {
        let shotID = snapshot?.shot.flatMap { shot in target.windowFrame.map { close(shot.windowFrame, $0) } == true ? shot.windowID : nil }
        return WindowRef(frame: target.windowFrame, title: snapshot?.windowTitle ?? "", windowID: shotID)
    }

    static let hoverNote = "Aviso: tooltips e realces que seguem o ponteiro real podem não aparecer em segundo plano (o movimento chega à janela, "
        + "mas as áreas de rastreio do AppKit não reagem). Para ler a dica use ui_read (AXHelp) ou repita com takeover: true."

    /// A short run-up to a hover that ends on the point, from the side that has room inside the window.
    static func approach(to point: CGPoint, within frame: CGRect?) -> [CGPoint] {
        let left = frame.map { point.x - $0.minX >= 24 } ?? true
        let above = frame.map { point.y - $0.minY >= 16 } ?? true
        let start = CGPoint(x: point.x + (left ? -24 : 24), y: point.y + (above ? -16 : 16))
        return [start, CGPoint(x: (start.x + point.x) / 2, y: (start.y + point.y) / 2), point]
    }

    /// A pen stroke takes longer the longer it is: about 2 ms a point of screen, between 300 ms and 5 s.
    static func strokeDuration(_ path: [StrokePoint]) -> Duration {
        var length = 0.0
        for (one, next) in zip(path, path.dropFirst()) { length += Double(hypot(next.point.x - one.point.x, next.point.y - one.point.y)) }
        return .milliseconds(Int(min(5000, max(300, 300 + length * 2))))
    }

    /// Lists and tables (`AXSelected`, `AXSelectedRows`), pop-up buttons (their menu, without opening it), combo boxes
    /// (`AXValue`), tab and radio groups.
    private static func select(_ step: Step, resolve: (String) throws -> UIResolver.Resolved, root: any AccessibilityElement, app: AccessibilityApp,
                               before: (UIResolver.Resolved?) -> UIState, press: (UIResolver.Resolved, String) throws -> Acted,
                               checkDanger: (String, String) throws -> Void) throws -> Acted {
        if !step.ids.isEmpty {
            let rows = try ([step.reference].compactMap { $0 } + step.ids).map(resolve)
            for row in rows { try checkDanger(row.live.identity, row.name) }
            let state = before(rows.first)
            // Each id stands for its row (a cell's text names the row it is in); a table selects them together.
            let contexts = rows.map { UIRowSelection.context(of: $0.element, role: $0.live.rawRole) }
            let container = contexts.lazy.compactMap { $0?.container }.first
            let elements = zip(rows, contexts).map { row, context in context?.row ?? row.element }
            guard UIRowSelection.select(elements, in: container) else {
                throw ToolError("Não consegui selecionar \(rows.map(\.id).joined(separator: ", ")): \(app.name) não confirmou a seleção por Acessibilidade.")
            }
            return Acted(summary: "Selecionei \(rows.count) itens: \(rows.map(\.id).joined(separator: ", ")).", target: elements.first, before: state)
        }
        let target = try resolve(step.reference ?? "")
        guard let value = step.value else {
            // The row the element is (or is in), selected the way its table takes it and read back.
            if let context = UIRowSelection.context(of: target.element, role: target.live.rawRole) {
                try checkDanger(target.live.identity, target.name)
                let state = before(target)
                if UIRowSelection.select([context.row], in: context.container) {
                    return Acted(summary: "Selecionei a linha de \(target.name) (\(target.id)).", target: context.row, before: state)
                }
                var acted: Acted
                do { acted = try press(target, "Cliquei em") } catch {
                    throw ToolError("\(app.name) não confirmou a seleção de \(target.name) (\(target.id)), e não há outro jeito de selecioná-la em segundo plano.")
                }
                acted.notes.append("Não confirmei a seleção: \(app.name) não a mostrou pela Acessibilidade. Leia de novo para conferir.")
                return acted
            }
            if target.element.isSettable("AXSelected") {
                try checkDanger(target.live.identity, target.name)
                let state = before(target)
                guard UIRowSelection.select([target.element], in: nil) else {
                    throw ToolError("\(app.name) não confirmou a seleção de \(target.name) (\(target.id)).")
                }
                return Acted(summary: "Selecionei \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            return try press(target, "Selecionei")
        }
        let state = before(target)
        switch target.live.role {
        case "popup", "menubutton":
            let items = UIMenu.items(under: target.element)
            guard !items.isEmpty else {
                throw needsScreen("escolher \(UIText.quoted(value)) em \(target.name)", because: "o menu desse botão só existe aberto")
            }
            guard let found = UIMenu.find(value, in: items) else {
                let options = items.map(UIMenu.title(of:)).filter { !$0.isEmpty }
                throw ToolError("Não achei \(UIText.quoted(value)) em \(target.name). Opções: " + options.prefix(40).joined(separator: ", ") + ".")
            }
            try checkDanger(found.title, "a opção \(UIText.quoted(found.title))")
            try found.element.perform("AXPress")
            return Acted(summary: "Escolhi \(UIText.quoted(found.title)) em \(target.name) (\(target.id)).", target: target.element, before: state)
        case "combobox":
            guard target.element.isSettable("AXValue") else { throw ToolError("\(target.name) não aceita um valor por Acessibilidade.") }
            try target.element.setValue(.string(value), for: "AXValue")
            return Acted(summary: "Escolhi \(UIText.quoted(value)) em \(target.name) (\(target.id)).", target: target.element, before: state)
        case "table", "outline", "list":
            let rows = target.element.elements("AXRows") ?? target.element.elements("AXChildren") ?? []
            let wanted = UIText.fold(value)
            let found = findRow(wanted, in: rows)
            guard let row = found.row else {
                throw ToolError("Nenhuma linha de \(target.name) tem \(UIText.quoted(value))"
                                + (found.examined < rows.count ? " entre as \(found.examined) primeiras de \(rows.count) (ui_read com query acha as outras)." : "."))
            }
            try checkDanger(rowText(row), "a linha \(UIText.quoted(value))")
            guard UIRowSelection.select([row], in: target.element) else {
                throw ToolError("As linhas de \(target.name) não puderam ser selecionadas por Acessibilidade (\(app.name) não confirmou a seleção).")
            }
            return Acted(summary: "Selecionei a linha \(UIText.quoted(value)) em \(target.name) (\(target.id)).", target: row, before: state)
        case "tabs", "radiogroup":
            let options = target.element.elements("AXTabs") ?? target.element.elements("AXChildren") ?? []
            guard let found = UIMenu.find(value, in: options) else {
                throw ToolError("Não achei \(UIText.quoted(value)) em \(target.name).")
            }
            try checkDanger(found.title, "a opção \(UIText.quoted(found.title))")
            try found.element.perform("AXPress")
            return Acted(summary: "Escolhi \(UIText.quoted(found.title)) em \(target.name) (\(target.id)).", target: target.element, before: state)
        default:
            throw ToolError("\(target.name) não tem opções para escolher; para texto use set_value.")
        }
    }

    /// The first row whose text has `wanted` (folded), looking at the first `limit` rows for at most `seconds`; each row costs
    /// several round trips, so a long table is not read to the end. `examined` is how many rows were looked at.
    static func findRow(_ wanted: String, in rows: [any AccessibilityElement], limit: Int = 500, seconds: Double = 1.2)
        -> (row: (any AccessibilityElement)?, examined: Int) {
        let started = Date()
        var examined = 0
        for row in rows.prefix(limit) {
            if AXWork.isCancelled || Date().timeIntervalSince(started) >= seconds { break }
            examined += 1
            if UIText.fold(rowText(row)).contains(wanted) { return (row, examined) }
        }
        return (nil, examined)
    }

    /// The words of a table row: its own name, else the text of its first cells.
    private static func rowText(_ row: any AccessibilityElement) -> String {
        let info = UIElementInfo(attributes: row.attributes(UIElementInfo.attributeNames + ["AXValue"]))
        if !info.identity.isEmpty { return info.identity }
        var words: [String] = []
        for cell in (row.elements("AXChildren") ?? []).prefix(4) {
            let values = cell.attributes(["AXTitle", "AXDescription", "AXValue", "AXRole", "AXSubrole", "AXRoleDescription"])
            let cellInfo = UIElementInfo(attributes: values)
            if cellInfo.secure { continue }
            if let text = cellInfo.title ?? values["AXValue"]?.string { words.append(text); continue }
            for inner in (cell.elements("AXChildren") ?? []).prefix(2) {
                let innerValues = inner.attributes(["AXTitle", "AXValue", "AXSubrole", "AXRoleDescription"])
                if UIElementInfo(attributes: innerValues).secure { continue }
                if let text = innerValues["AXTitle"]?.string ?? innerValues["AXValue"]?.string { words.append(text) }
            }
        }
        return words.joined(separator: " ")
    }

    /// The scroll bar's value (0…1) moved by pages; else a scroll event sent to the app over the area. Keys held (to zoom,
    /// say) can only go as an event.
    private static func scroll(_ target: UIResolver.Resolved, direction: String, amount: Int, modifiers: KeyStroke.Modifiers,
                               before state: UIState, windowRef: WindowRef) throws -> Acted {
        var area: (any AccessibilityElement)? = target.element
        var areaRole = target.live.rawRole
        for _ in 0..<5 where areaRole != "AXScrollArea" {
            area = area?.element("AXParent")
            areaRole = area?.string("AXRole") ?? ""
        }
        let vertical = direction == "up" || direction == "down"
        let sign: Double = direction == "up" || direction == "left" ? -1 : 1
        let words = scrollWords(direction, amount: amount, modifiers: modifiers)
        let scrollArea = areaRole == "AXScrollArea" ? area : nil
        if modifiers.isEmpty, let scrollArea, let bar = scrollArea.element(vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"),
           bar.isSettable("AXValue"), case .number(let current)? = bar.attribute("AXValue") {
            // A page is what the area shows; the bar's value runs over what is hidden.
            var page = 0.25
            if case .size(let visible)? = scrollArea.attribute("AXSize"),
               let content = scrollArea.elements("AXContents")?.first, case .size(let full)? = content.attribute("AXSize") {
                let shown = vertical ? visible.height : visible.width
                let total = vertical ? full.height : full.width
                if total > shown { page = Double(shown / (total - shown)) }
            }
            let next = min(1, max(0, current + sign * Double(amount) * page * 0.9))
            try bar.setValue(.number(next), for: "AXValue")
            return Acted(summary: "Rolei \(target.name) (\(target.id)) \(words).", target: target.element, before: state)
        }
        var frame = target.frame
        if let scrollArea, case .point(let origin)? = scrollArea.attribute("AXPosition"), case .size(let size)? = scrollArea.attribute("AXSize") {
            frame = CGRect(origin: origin, size: size)
        }
        guard let frame else { throw ToolError("\(target.name) não rola por Acessibilidade e não diz onde está na tela.") }
        let delta = scrollDelta(direction, amount: amount, size: frame.size, modifiers: modifiers)
        return Acted(summary: "Rolei \(target.name) (\(target.id)) \(words).", target: target.element, before: state,
                     input: .scroll(dx: delta.dx, dy: delta.dy, at: CGPoint(x: frame.midX, y: frame.midY), window: windowRef, modifiers: modifiers),
                     inputWhat: "rolar \(target.name)")
    }

    static func scrollWords(_ direction: String, amount: Int, modifiers: KeyStroke.Modifiers) -> String {
        let way = direction == "up" ? "para cima" : direction == "down" ? "para baixo" : direction == "left" ? "para a esquerda" : "para a direita"
        return "\(way) (\(scrollSize(amount: amount, modifiers: modifiers)))"
    }

    /// "2 pág." — or, with keys held, steps of 60 pixels: "2 passos, com ⌥".
    static func scrollSize(amount: Int, modifiers: KeyStroke.Modifiers) -> String {
        modifiers.isEmpty ? "\(amount) pág." : "\(amount) \(amount == 1 ? "passo" : "passos"), com \(symbols(modifiers))"
    }

    /// The pixels of a scroll event: a page is nine tenths of the area; with keys held (to zoom) a step is 60 pixels, so the
    /// model can stop short of the end of the zoom.
    static func scrollDelta(_ direction: String, amount: Int, size: CGSize, modifiers: KeyStroke.Modifiers) -> (dx: Int, dy: Int) {
        let vertical = direction == "up" || direction == "down"
        let sign = direction == "up" || direction == "left" ? -1 : 1
        let unit = modifiers.isEmpty ? Int(Double(vertical ? size.height : size.width) * 0.9) : 60
        // Positive values move the content down (the page goes up), like a trackpad.
        let delta = -sign * unit * amount
        return (vertical ? 0 : delta, vertical ? delta : 0)
    }

    /// A number or a yes/no for an element that holds one (sliders, checkboxes); text for everything else.
    static func settableValue(_ text: String, current: AXAttributeValue?) -> AXAttributeValue {
        switch current {
        case .number?:
            if let number = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) { return .number(number) }
        case .bool?:
            switch UIText.fold(text) {
            case "true", "sim", "yes", "1": return .bool(true)
            case "false", "nao", "no", "0": return .bool(false)
            default: break
            }
        default:
            break
        }
        return .string(text)
    }

    // MARK: Taking the screen over (N2)

    private enum Move: Sendable {
        case click(CGPoint, Clicking)
        case hover(CGPoint)
        case type(String)
        case key(KeyStroke)
        case drag([CGPoint], modifiers: KeyStroke.Modifiers)
    }

    /// Runs the steps with the real mouse and keyboard, only through `ScreenOwner` (which brings the app forward, and puts
    /// the user's app, window and cursor back whatever happens). Where each step lands is read in the background first.
    private func takeOver(_ steps: [Step], app: AccessibilityApp, context: ToolContext, approved: Bool) async throws -> String {
        let snapshot = store.snapshot(bot: context.botID, app: app)
        let system = system, live = live
        let bot = context.botID
        // Where a drag into another app lets go is read from that app first (its own queue).
        var drops: [Int: DropTarget] = [:]
        for (index, step) in steps.enumerated() { drops[index] = try await dropTarget(for: step, app: app, bot: bot, approved: approved) }
        let ends = drops
        let (moves, owners, window, before) = try await UIAccess.mapped(app) {
            try await sessions.run(app, within: sessions.deadlines.action) { () throws -> ([Move], [Int], (any AccessibilityElement)?, UIState) in
                let root = system.root(of: app)
                var moves: [Move] = []
                // Which step each flattened move came from, so a failure can say which step it stopped in.
                var owners: [Int] = []
                var window: (any AccessibilityElement)?
                func center(_ reference: String?, _ pixel: CGPoint?) throws -> CGPoint {
                    if let pixel {
                        let spot = try Spot.read(snapshot, root: root, app: app)
                        try spot.check(pixel)
                        window = window ?? spot.window
                        return spot.screen(pixel)
                    }
                    let id = try UIResolver.id(for: reference ?? "", in: snapshot, app: app)
                    let cached = snapshot.flatMap { live.element(bot: bot, pid: app.pid, generation: $0.generation, takenAt: $0.takenAt, id: id) }
                    let target = try UIResolver.resolve(id: id, root: root, app: app, snapshot: snapshot, cached: cached)
                    window = window ?? target.window
                    guard let frame = target.frame else { throw ToolError("\(target.name) não diz onde está na tela.") }
                    return CGPoint(x: frame.midX, y: frame.midY)
                }
                for (index, step) in steps.enumerated() {
                    switch step.action {
                    case .select where step.value != nil:
                        // A real click only opens the menu; the option is never picked and the app is handed back with it closed.
                        throw ToolError("select with a value does not work in takeover (the click would only open the menu). Click the control, then click the option by its reference or point, in the same takeover call.")
                    case .press, .focus, .select, .showMenu:
                        moves.append(.click(try center(step.reference, step.point), Clicking()))
                    case .click:
                        // The real mouse has no long press here: it is a background feature.
                        if step.hold > .zero { throw ToolError("Segurar o clique só funciona em segundo plano; repita sem takeover.") }
                        moves.append(.click(try center(step.reference, step.point), step.clicking))
                    case .move:
                        moves.append(.hover(try center(step.reference, step.point)))
                    case .drag:
                        let end = try ends[index]?.point ?? center(step.destination, step.destinationPoint)
                        moves.append(.drag(DragPath.arc(from: try center(step.reference, step.point), to: end), modifiers: step.modifiers))
                    case .draw:
                        let spot = try Spot.read(snapshot, root: root, app: app)
                        for (number, point) in step.stroke.enumerated() { try spot.check(point.point, number: number + 1) }
                        window = window ?? spot.window
                        let path = DragPath.stroke(step.stroke.map { StrokePoint(point: spot.screen($0.point), pressure: $0.pressure) })
                        moves.append(.drag(path.map(\.point), modifiers: []))
                    case .type:
                        if step.reference != nil { moves.append(.click(try center(step.reference, step.point), Clicking())) }
                        moves.append(.type(step.value ?? ""))
                    case .setValue:
                        moves.append(.click(try center(step.reference, step.point), Clicking()))
                        moves.append(.key(KeyStroke(.character("a"), modifiers: .command)))
                        // Typing "" sends nothing, so an empty value deletes the selection instead.
                        if let value = step.value, !value.isEmpty { moves.append(.type(value)) } else { moves.append(.key(KeyStroke(.named(.delete)))) }
                    case .key:
                        if step.reference != nil { moves.append(.click(try center(step.reference, step.point), Clicking())) }
                        moves += step.keys.map(Move.key)
                    case .scroll, .increment, .decrement, .pickMenu:
                        throw ToolError("\(step.action.rawValue) funciona em segundo plano; repita sem takeover.")
                    }
                    while owners.count < moves.count { owners.append(index) }
                }
                return (moves, owners, window, UIState.capture(root: root, target: nil))
            }
        }
        let report = try await system.screen.takeOver(app, window: window, limit: .seconds(10)) { hand in
            for (position, move) in moves.enumerated() {
                try Task.checkCancellation()
                do {
                    switch move {
                    case .click(let point, let click):
                        try await hand.click(at: point, button: click.button, count: click.count, modifiers: click.modifiers)
                    case .hover(let point): try await hand.move(to: point)
                    case .type(let text): try await hand.type(text)
                    case .key(let stroke): try await hand.key(stroke)
                    case .drag(let points, let modifiers): try await hand.drag(along: points, modifiers: modifiers)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The takeover is one call, so without this the model would not know how far it got and would repeat
                    // the clicks and the text that already landed.
                    let number = owners[position] + 1
                    var text = "Stopped at step \(number) of \(steps.count) (\(steps[owners[position]].action.rawValue)): \(error.localizedDescription) "
                        + (number > 1 ? "Steps 1-\(number - 1) were done." : "No earlier step was done.")
                    if case .type(let typed) = move, let live = hand as? LiveTakeoverHand {
                        text += " Typed \(live.typedCharacters) of \(typed.count) characters of this step; do not retype them."
                    }
                    throw ToolError(text)
                }
            }
        }
        let after = (try? await sessions.run(app, within: sessions.deadlines.action) { UIState.capture(root: system.root(of: app), target: nil) }) ?? before
        let restored = report.restoreFailed ? "não consegui devolver o app da frente"
            : report.restoredApp.map { "devolvi ao \($0)" } ?? "nada a devolver"
        var text = "Fiz \(steps.count == 1 ? "o passo" : "os \(steps.count) passos") com o mouse e o teclado reais em \(app.name). "
            + "[assumi a tela \(UIClock.seconds(report.duration)) · \(restored)] " + UIState.describe(from: before, to: after).clipped(to: 600)
        if report.restoreFailed {
            text += "\nAtenção: o app que o usuário usava não voltou para a frente (nem por Acessibilidade nem ativando-o); \(app.name) "
                + "ficou na frente. Avise o usuário."
        }
        if !report.cursorRestored { text += "\nAviso: o cursor não voltou exatamente para onde estava." }
        return text
    }
}

extension ToolBox {
    static let accessibilityTools: [any AgentTool] = [UIReadTool(), UIActTool()]
}
