import CoreGraphics
import Foundation

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
                "O app \"\(name)\" não está aberto. Abra-o com open e tente de novo (apps_list mostra o que está aberto)."
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
        let apps = await system.runningApps()
        switch UIAppResolver.resolve(query, in: apps, ownPID: ownPID, ownBundleID: ownBundleID) {
        case .success(let app): return app
        case .failure(let failure): throw ToolError(failure.message)
        }
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
        let running = await system.runningApps()
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
            "app": .property("string", "Name or bundle id (default: the frontmost)."),
            "window": .property("string", "Number or part of the title."),
            "query": .property("string", "Only elements containing this text."),
            "max_depth": .property("integer", "1-12."),
            "include_menus": .property("boolean"),
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
        let app = arguments.nonEmptyString("app") ?? "o app da frente"
        let detail = [arguments.nonEmptyString("window").map { "janela \($0)" }, arguments.nonEmptyString("query").map { "busca: \($0)" },
                      arguments.nonEmptyString("wait").map { "esperando: \($0)" }]
        return ("Lendo a interface de \(app)", detail.compactMap { $0 }.joined(separator: " · "))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let app = try await UIAccess.open(arguments["app"]?.string, system: system)
        var limits = limits
        limits.maxDepth = arguments.integer("max_depth", default: limits.maxDepth, in: 1...limits.maxDepth)
        let window = arguments["window"]?.int.map(String.init) ?? arguments.nonEmptyString("window"), query = arguments.nonEmptyString("query")
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
                var enabled = false
                if session.state.withLock({ $0.manualAccessibility == nil }) {
                    system.prepare(root)
                    let accepted = root.attribute("AXManualAccessibility")?.bool == true
                    session.state.withLock { $0.manualAccessibility = accepted }
                    enabled = accepted
                }
                return (try Self.reading(root: root, app: app, window: window, query: query, includeMenus: menus, limits: readLimits), enabled)
            }
        }
        var reading = first
        if justEnabled, reading.listed < 3 {
            try await Task.sleep(for: .milliseconds(300))
            reading = try await UIAccess.mapped(app) {
                try await sessions.run(app, within: deadline) {
                    try Self.reading(root: system.root(of: app), app: app, window: window, query: query, includeMenus: menus, limits: readLimits)
                }
            }
        }

        var snapshot = reading.snapshot
        snapshot.generation = live.nextGeneration()
        snapshot = snapshot.carryingOver(from: store.snapshot(bot: context.botID, app: app), partial: query != nil)
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
    static func read(root: any AccessibilityElement, app: AccessibilityApp, window selector: String?, query: String?,
                     includeMenus: Bool, limits: UIOutlineLimits) throws -> (text: String, snapshot: UISnapshot) {
        let reading = try reading(root: root, app: app, window: selector, query: query, includeMenus: includeMenus, limits: limits)
        return (reading.text, reading.snapshot)
    }

    static func reading(root: any AccessibilityElement, app: AccessibilityApp, window selector: String?, query: String?,
                        includeMenus: Bool, limits: UIOutlineLimits) throws -> UIReading {
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
            let outline = UIOutlineBuilder.outline(of: windows[index], prefix: "w\(index + 1)", query: query, limits: limits)
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
        switch mode.trimmingCharacters(in: .whitespaces).lowercased() {
        case "appears", "disappears":
            guard let query else { throw ToolError("wait \(mode) precisa de query: o texto que deve aparecer ou sumir.") }
            self = mode.lowercased() == "appears" ? .appears(query) : .disappears(query)
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

/// Waits for something to show in an app: re-checks when a notification comes (60 ms after the last of a burst), and
/// every 250 ms when the app sends none.
struct UIWaiter: Sendable {
    let system: any AccessibilitySystem
    let sessions: AXSessions
    let store: UISnapshotStore
    let live: UILiveElements
    var poll: Duration = .milliseconds(250)
    var quiet: Duration = .milliseconds(60)

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
        while true {
            try Task.checkCancellation()
            let left = max(clock.now.duration(to: end + sessions.deadlines.waitGrace), .milliseconds(100))
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
            if watcher.isFinished {
                try await Task.sleep(for: min(poll, remaining))
            } else if await watcher.waitForMore(than: watcher.count, timeout: min(.seconds(1), remaining)) {
                try await Task.sleep(for: min(quiet, max(clock.now.duration(to: end), .zero)))
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

// MARK: - Finding an element again

enum UIResolver {
    static let staleMessage = "A interface mudou; chame ui_read de novo."

    static func stale(_ detail: String) -> ToolError { ToolError("A interface mudou (\(detail)); chame ui_read de novo.") }

    /// `w1.3.2.5` → kind "w", numbers [1, 3, 2, 5]; `m2` → kind "m", numbers [2].
    static func parse(_ id: String) -> (kind: Character, numbers: [Int])? {
        guard id.range(of: #"^[wm][0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil, let kind = id.first else { return nil }
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
        if parsed.kind == "m" {
            guard let items = root.element("AXMenuBar")?.elements("AXChildren"), items.indices.contains(parsed.numbers[0] - 1) else {
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
        if !entry.label.isEmpty, UIText.fold(live.identity) != UIText.fold(entry.label) {
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

    /// `- Novo`, `- Abrir recente ▸`, `- Salvar (desativado)` for the items under a menu bar item or submenu item.
    static func listing(under item: any AccessibilityElement) -> String {
        listing(of: items(under: item))
    }

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

    /// The enabled menu item whose keyboard shortcut is `stroke`, found without opening any menu (the shortcut then works
    /// whatever the keyboard layout and with the app in the background). Looks at most `limit` items deep in submenus.
    static func item(for stroke: KeyStroke, root: any AccessibilityElement, limit: Int = 800) -> (element: any AccessibilityElement, titles: [String])? {
        guard let bar = root.element("AXMenuBar"), let top = bar.elements("AXChildren") else { return nil }
        var budget = limit
        let names = ["AXTitle", "AXEnabled", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXChildren"]

        func search(_ items: [any AccessibilityElement], path: [String], depth: Int) -> (any AccessibilityElement, [String])? {
            for item in items {
                guard budget > 0 else { return nil }
                budget -= 1
                guard let values = item.read(names).attributes else { continue }
                let title = values["AXTitle"]?.string ?? ""
                if values["AXEnabled"]?.bool != false, matches(stroke, values) { return (item, path + [title]) }
                guard depth < 3, let menu = values["AXChildren"]?.elements?.first(where: { $0.string("AXRole") == "AXMenu" }),
                      let children = menu.elements("AXChildren") else { continue }
                if let found = search(children, path: path + [title], depth: depth + 1) { return found }
            }
            return nil
        }
        return search(top, path: [], depth: 0).map { (element: $0.0, titles: Array($0.1.filter { !$0.isEmpty })) }
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
        Rule(phrases: ["esvaziar lixeira", "esvaziar a lixeira", "empty trash", "empty the trash"],
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
            for phrase in rule.phrases {
                let wanted = words(phrase)
                guard !wanted.isEmpty, found.count >= wanted.count else { continue }
                if (0...(found.count - wanted.count)).contains(where: { Array(found[$0..<($0 + wanted.count)]) == wanted }) { return rule.reason }
            }
        }
        return nil
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
        case press, focus, setValue = "set_value", type, key, select, scroll, click, increment, decrement
        case showMenu = "show_menu", pickMenu = "pick_menu"
    }

    /// The stable marker of an error that only the real mouse and keyboard can get past.
    static let takeoverMarker = "[precisa_assumir_tela]"

    let spec = ToolSpec(
        name: "ui_act",
        description: """
        Operate an element found with ui_read, in the background (focus and cursor untouched): press, click (id, \
        "#n" mark or x,y screenshot pixels), focus, set_value, type (value into id or the focused field), key, select, \
        scroll, increment, decrement, show_menu, pick_menu (menu_path ["Arquivo", "Exportar…"], no id). If the screen \
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
            "count": .property("integer", "Clicks, 1-2."),
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
        var direction: String?
        var amount = 1

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
                step.keys = try step.keysText.split(separator: ",").map { piece in
                    do { return try KeyStroke.parse(String(piece)) } catch let error as KeyStroke.ParseError {
                        throw ToolError(error.errorDescription ?? "Atalho inválido.")
                    }
                }
            case .click:
                func coordinate(_ key: String) -> Int? {
                    arguments[key]?.int ?? arguments[key]?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                }
                if let x = coordinate("x"), let y = coordinate("y") {
                    step.point = CGPoint(x: x, y: y)
                } else if !hasTarget {
                    throw ToolError("Faltou o argumento \"id\" (ou x e y, em pixels do último screenshot).")
                }
                step.button = MouseButton(rawValue: arguments.nonEmptyString("button")?.lowercased() ?? "left") ?? .left
                step.count = arguments.integer("count", default: 1, in: 1...2)
            case .scroll:
                if !hasTarget { _ = try arguments.requiredString("id") }
                if let direction = arguments.nonEmptyString("direction")?.lowercased() {
                    guard ["up", "down", "left", "right"].contains(direction) else {
                        throw ToolError("direction desconhecida \"\(direction)\": use up, down, left ou right.")
                    }
                    step.direction = direction
                }
                step.amount = arguments.integer("amount", default: 1, in: 1...10)
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
        case .click: return ("Clicando em \(label)", role + reference + (step.count == 2 ? " (duplo)" : "") + place)
        case .focus: return ("Focando em \(label)", role + reference + place)
        case .setValue: return ("Escrevendo em \(label)", text(step.value) + place)
        case .type: return (step.reference == nil ? "Digitando no campo em foco" : "Digitando em \(label)", text(step.value) + place)
        case .key: return ("Teclando \(step.keysText)", (step.reference == nil ? "" : role + reference) + place)
        case .select: return ("Selecionando \(step.value.map(UIText.quoted) ?? label)", role + reference + place)
        case .scroll: return ("Rolando \(label)", [step.direction, "\(step.amount) pág."].compactMap { $0 }.joined(separator: " ") + place)
        case .increment: return ("Aumentando \(label)", place)
        case .decrement: return ("Diminuindo \(label)", place)
        case .showMenu: return ("Abrindo o menu \(label)", place)
        case .pickMenu: return ("Escolhendo no menu de \(appName)", step.menuPath.joined(separator: " → "))
        }
    }

    // MARK: Running

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let steps = try Self.steps(in: arguments)
        let needsName = steps.contains { $0.action == .pickMenu || $0.action == .key }
        let app = try await UIAccess.forAction(arguments["app"]?.string, bot: context.botID, store: store, system: system, needsName: needsName)
        // What the approval card judged: an action whose live target turns out dangerous runs only if the card said so. The
        // engine hands the card's own verdict over (`judged`); only a call no card was computed for judges itself here.
        let approved = Self.judged(arguments, context: context) ?? (danger(arguments, context: context) != nil)
        if arguments.flag("takeover") { return try await takeOver(steps, app: app, context: context) }

        var done: [String] = []
        var last: Performed?
        for (index, step) in steps.enumerated() {
            do {
                let performed = try await perform(step, app: app, context: context, approved: approved, waitsAfter: index == steps.count - 1 && arguments["wait"] != nil)
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

    // MARK: The card's verdict

    /// Where the Claude Code engine puts the card's verdict in the call it lets through to the tools server (another
    /// process, with its own readings): `"<token>:dangerous"` or `"<token>:safe"`.
    static let cardKey = "orb_card"
    /// The environment variable that gives the tools server the app's token, so a verdict cannot be made up by the model.
    static let cardTokenVariable = "ORB_UI_CARD_TOKEN"
    /// The app makes one per launch; the tools server it starts reads the app's.
    static let cardToken: String = ProcessInfo.processInfo.environment[cardTokenVariable].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString

    /// The value of `cardKey` for a call the card judged dangerous or not.
    static func cardMark(dangerous: Bool, token: String = cardToken) -> String { token + (dangerous ? ":dangerous" : ":safe") }

    /// Whether the card judged the call dangerous, as the engine says: the native engine through the context, the Claude
    /// Code engine through `cardKey`. A "safe" verdict is taken whoever wrote it (it only makes the run stricter); a
    /// "dangerous" one only with this process's token. Nil when the engine said nothing.
    static func judged(_ arguments: JSONValue, context: ToolContext, token: String = cardToken) -> Bool? {
        if let judged = context.judgedDanger { return judged }
        guard let mark = arguments[cardKey]?.string else { return nil }
        if mark == cardMark(dangerous: true, token: token) { return true }
        if mark.hasSuffix(":safe") { return false }
        return nil
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
    }

    /// Events still to send to the app after the Accessibility part (N1).
    enum InputPlan: Sendable {
        case click(CGPoint, window: WindowRef, button: MouseButton, count: Int)
        case scroll(dx: Int, dy: Int, at: CGPoint, window: WindowRef)
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
        let request = Request(step: step, snapshot: snapshot, bot: context.botID, approved: approved,
                              stealsFocus: session.state.withLock { $0.stealsFocus })
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
                acted.notes += try await send(plan, what: acted.inputWhat, app: app, snapshot: snapshot, frontBefore: frontBefore, session: session)
                method = .event
            }
            if !waitsAfter { await settle.wait(on: events) }
            let target = acted.target
            let after = (try? await sessions.run(app, within: sessions.deadlines.action) { UIState.capture(root: system.root(of: app), target: target) })
                ?? acted.before
            acted.notes += await restoreFront(frontBefore, app: app, session: session)

            var text = acted.summary + " " + method.tag + " " + UIState.describe(from: acted.before, to: after).clipped(to: 600)
            if let listing = acted.listing, !listing.isEmpty { text += "\nItens do menu:\n" + listing }
            if !acted.notes.isEmpty { text += "\n" + acted.notes.joined(separator: "\n") }
            return Performed(text: text, watcher: events, before: acted.before, target: target)
        } catch {
            // Failing (or being cancelled) after acting does not leave the person with another app in front.
            watcher?.cancel()
            let notes = await restoreFront(frontBefore, app: app, session: session)
            guard !notes.isEmpty, !(error is CancellationError) else { throw error }
            throw ToolError(Self.reason(error) + ".\n" + notes.joined(separator: "\n"))
        }
    }

    /// After every action, and after a failed or cancelled one, the app in front must be the one that was: an app that
    /// brought itself forward is sent back (`AXFrontmost` on the user's app, never `activate`) and remembered as one that
    /// steals focus. Not cancellable: it runs in its own task, awaited whatever happens to the caller's.
    private func restoreFront(_ before: Int32?, app: AccessibilityApp, session: AXAppSession) async -> [String] {
        let system = system, sessions = sessions
        return await Task.detached(priority: .userInitiated) {
            guard let before, before != app.pid, await system.frontmostPID() == app.pid else { return [String]() }
            session.state.withLock { $0.stealsFocus = true }
            let previous = AccessibilityApp(name: "", bundleID: nil, pid: before)
            _ = try? await sessions.run(previous, within: sessions.deadlines.action) {
                try system.root(of: previous).setValue(.bool(true), for: "AXFrontmost")
            }
            return ["Aviso: \(app.name) veio para a frente sozinho; devolvi o app que estava na frente. Focar ou digitar nele agora pede takeover."]
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
        let notes = await restoreFront(before, app: app, session: session)
        throw Self.needsScreen(what, because: "\(app.name) veio para a frente ao receber o foco"
                               + (notes.isEmpty ? "" : " (devolvi o app que estava na frente)"))
    }

    /// The error that tells the model only the real mouse and keyboard can do it (with the user's consent).
    static func needsScreen(_ what: String, because reason: String) -> ToolError {
        ToolError("\(takeoverMarker) Não deu para \(what) em segundo plano: \(reason). Se for preciso, repita com takeover: true "
                  + "(o usuário confirma e o Orb usa o mouse e o teclado reais por alguns segundos); repetir pode duplicar o que já foi feito.")
    }

    // MARK: Events to the app (N1)

    private func send(_ plan: InputPlan, what: String, app: AccessibilityApp, snapshot: UISnapshot?, frontBefore: Int32?,
                      session: AXAppSession) async throws -> [String] {
        try await refuseIfUserIsActive(app)
        var notes: [String] = []
        switch plan {
        case .click(let point, let window, let button, let count):
            let id = try await windowID(window, app: app, snapshot: snapshot, what: what)
            do { try await system.input.click(at: point, window: id, button: button, count: count, to: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .scroll(let dx, let dy, let point, let window):
            let id = try await windowID(window, app: app, snapshot: snapshot, what: what)
            do { try await system.input.scroll(dx: dx, dy: dy, at: point, window: id, to: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        case .keys(let strokes, let target):
            if let target {
                try await focus(target, app: app)
                try await refuseIfBroughtForward(frontBefore, app: app, session: session, what: what)
            }
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
        return notes
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

    /// The `CGWindowID` of the window: the one the screenshot captured when it is the same window, else the window the
    /// app has with the same frame (±2 pt) and title. Windows come from the window server's list, which needs no
    /// permission (the title may be missing without Screen Recording: then the frame decides); ScreenCaptureKit, which
    /// needs Screen Recording, only when that list has nothing for the app.
    private func windowID(_ window: WindowRef, app: AccessibilityApp, snapshot: UISnapshot?, what: String) async throws -> UInt32 {
        let known = window.windowID ?? snapshot?.shot.flatMap { shot in
            window.frame.map { Self.close(shot.windowFrame, $0) } == true ? shot.windowID : nil
        }
        let listed = system.windowList(pid: app.pid).sorted { $0.isOnScreen && !$1.isOnScreen }
        if let known {
            // The window of the screenshot must still exist (a new window can reuse the frame, not the number).
            let current = listed.isEmpty ? ((try? await system.capturer.windows(pid: app.pid)) ?? []) : listed
            if !current.isEmpty, !current.contains(where: { $0.windowID == known }) {
                throw UIResolver.stale("a janela do screenshot não existe mais; tire outro")
            }
            return known
        }
        let windows: [CapturableWindow]
        if !listed.isEmpty {
            windows = listed
        } else {
            do { windows = try await system.capturer.windows(pid: app.pid) } catch {
                throw Self.needsScreen(what, because: Self.reason(error))
            }
        }
        let match = windows.first { candidate in
            window.frame.map { Self.close(candidate.frame, $0) } ?? true && UIText.fold(candidate.title) == UIText.fold(window.title)
        } ?? windows.first { candidate in window.frame.map { Self.close(candidate.frame, $0) } ?? false }
        guard let match else { throw Self.needsScreen(what, because: "não achei a janela \(UIText.quoted(window.title)) para mandar o evento") }
        return match.windowID
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
        guard let focused = root.element("AXFocusedUIElement"), focused.isSame(as: target) else {
            throw ToolError("O foco de \(app.name) não está no campo pedido; não mandei nada. Leia de novo com ui_read e diga o id do campo.")
        }
    }

    /// Types in chunks of at most 20 UTF-16 units, checking before each one that the focus is still on the field and the
    /// user is not using the app; stops between chunks when the task is cancelled and says how much went in.
    /// `checkFront` runs right after the focus is given and before every chunk, with the app in front then: it throws when
    /// the app came forward.
    private func type(_ text: String, into target: any AccessibilityElement, replace: Bool, app: AccessibilityApp, what: String,
                      checkFront: @Sendable (Int32?) async throws -> Void) async throws -> [String] {
        try await focus(target, app: app, replace: replace)
        try await checkFront(await system.frontmostPID())
        let chunks = Self.chunks(text)
        let total = text.count
        var sent = 0
        let system = system
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return ["Parei a pedido: digitei \(sent) de \(total) caracteres."] }
            if index > 0 {
                do {
                    // The app in front is asked once per chunk, for both checks.
                    let front = await system.frontmostPID()
                    try await checkFront(front)
                    try await refuseIfUserIsActive(app, front: .some(front))
                    try await UIAccess.mapped(app) {
                        try await sessions.run(app, within: sessions.deadlines.action) {
                            try Self.confirmFocus(on: target, root: system.root(of: app), app: app)
                        }
                    }
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
            while started.duration(to: clock.now) < timeout {
                if last.watcher.events.contains(where: { UIWaiter.changeNotifications.contains($0.notification) }) {
                    return "(esperei \(UIClock.seconds(started.duration(to: clock.now))): mudou)"
                }
                let now = try await sessions.run(app, within: sessions.deadlines.action) { UIState.capture(root: system.root(of: app), target: target) }
                if now != last.before { return "(esperei \(UIClock.seconds(started.duration(to: clock.now))): mudou)" }
                let left = timeout - started.duration(to: clock.now)
                guard left > .zero else { break }
                if last.watcher.isFinished {
                    try await Task.sleep(for: min(.milliseconds(250), left))
                } else {
                    await last.watcher.waitForMore(than: last.watcher.count, timeout: min(.seconds(1), left))
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

        func windowRef(_ target: UIResolver.Resolved) -> WindowRef {
            let shotID = snapshot?.shot.flatMap { shot in target.windowFrame.map { close(shot.windowFrame, $0) } == true ? shot.windowID : nil }
            return WindowRef(frame: target.windowFrame, title: snapshot?.windowTitle ?? "", windowID: shotID)
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
            if let action = ["AXPress", "AXConfirm", "AXPick"].first(where: actions.contains) {
                try target.element.perform(action)
                return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            if target.element.isSettable("AXSelected") {
                try target.element.setValue(.bool(true), for: "AXSelected")
                return Acted(summary: "Selecionei \(target.name) (\(target.id)).", target: target.element, before: state)
            }
            guard let frame = target.frame, target.window != nil else { throw missing(target, "clique", actions) }
            return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: state,
                         input: .click(CGPoint(x: frame.midX, y: frame.midY), window: windowRef(target), button: .left, count: 1),
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
            if step.button == .left, step.count == 1 { return try press(target) }
            try checkDanger(target.live.identity, target.name)
            guard let frame = target.frame, target.window != nil else { throw missing(target, "clique", target.element.actionNames()) }
            let verb = step.button == .right ? "Cliquei com o botão direito em" : (step.count == 2 ? "Dei dois cliques em" : "Cliquei em")
            return Acted(summary: "\(verb) \(target.name) (\(target.id)).", target: target.element, before: before(target),
                         input: .click(CGPoint(x: frame.midX, y: frame.midY), window: windowRef(target), button: step.button, count: step.count),
                         inputWhat: "clicar em \(target.name)")

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
                guard textRoles.contains(target.live.role), !request.stealsFocus else {
                    throw missing(target, "receber um valor (não é um campo editável)", target.element.actionNames())
                }
                return Acted(summary: "Escrevi em \(target.name) (\(target.id)).", target: target.element, before: state,
                             input: .text(value, target: target.element, replace: true), inputWhat: "escrever em \(target.name)")
            }
            let newValue = settableValue(value, current: target.live.secure ? nil : target.element.attribute("AXValue"))
            try target.element.setValue(newValue, for: "AXValue")
            // Fields driven by a page's script ignore AXValue: then the text is typed.
            if case .string(let wanted) = newValue, !target.live.secure, textRoles.contains(target.live.role),
               let back = target.element.attribute("AXValue")?.string, back != wanted, !request.stealsFocus {
                return Acted(summary: "Escrevi em \(target.name) (\(target.id)).", target: target.element, before: state,
                             input: .text(value, target: target.element, replace: true), inputWhat: "escrever em \(target.name)",
                             notes: ["O campo ignorou o valor por Acessibilidade; digitei o texto."])
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
            let state = UIState.capture(root: root, target: target?.element, known: target?.attributes)
            // A shortcut of the menu bar is pressed as its menu item: no keyboard layout involved, works in the background.
            if step.keys.count == 1, let stroke = step.keys.first, !stroke.modifiers.isDisjoint(with: [.command, .control]),
               let item = UIMenu.item(for: stroke, root: root) {
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
            return try scroll(target, direction: direction, amount: step.amount, before: state, windowRef: windowRef(target))

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
        guard let snapshot = request.snapshot, let shot = snapshot.shot else {
            throw ToolError("x e y são pixels do último screenshot com marcas da janela; tire um screenshot de \(app.name) antes (ou use um id).")
        }
        let relative = CGPoint(x: pixel.x / shot.scale, y: pixel.y / shot.scale)
        guard CGRect(origin: .zero, size: shot.windowFrame.size).contains(relative) else {
            throw ToolError("O ponto x \(Int(pixel.x)), y \(Int(pixel.y)) fica fora da imagem (\(shot.pixelWidth)×\(shot.pixelHeight) px).")
        }
        // The window must still have the size it had in the picture, or the pixels point elsewhere now.
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
        let screen = CGPoint(x: origin.x + relative.x, y: origin.y + relative.y)
        let windowRef = WindowRef(frame: CGRect(origin: origin, size: size), title: snapshot.windowTitle, windowID: shot.windowID)
        let description = "x \(Int(pixel.x)), y \(Int(pixel.y))"

        let local = localHit(pixel, in: snapshot)
        let target = try local.map { try resolve($0.id) }
        // The app's hit test sees what is really on top (a popover, a sheet); it is z-ordered, so a covered window answers
        // nothing and the reading decides. It sees every window of the app, though: what it finds in another window (one
        // over the screenshot's) is not what the click is about, and the reading decides then too.
        if let hit = system.hitTest(app, at: screen), belongs(hit, to: window), !(target.map { related(hit, to: $0.element) } ?? false) {
            var element: any AccessibilityElement = hit
            for _ in 0..<5 where clickable(element) == false {
                guard let parent = element.element("AXParent") else { break }
                element = parent
            }
            let info = UIElementInfo(attributes: element.attributes(UIElementInfo.attributeNames))
            let name = info.role + (info.identity.isEmpty ? "" : " " + UIText.quoted(info.identity))
            if !request.approved, let reason = UIDanger.reason(forLabel: info.identity, appName: app.name, bundleID: app.bundleID) {
                throw ToolError("Não fiz: \(name) \(reason), e o pedido não passou pela confirmação do usuário. "
                                + "Leia de novo com ui_read e repita por id para que ele confirme.")
            }
            let state = UIState.capture(root: root, target: element)
            if step.button == .left, step.count == 1, let action = ["AXPress", "AXConfirm", "AXPick"].first(where: element.actionNames().contains) {
                try element.perform(action)
                return Acted(summary: "Cliquei em \(name) (\(description)).", target: element, before: state)
            }
            return Acted(summary: "Cliquei em \(name) (\(description)).", target: element, before: state,
                         input: .click(screen, window: windowRef, button: step.button, count: step.count), inputWhat: "clicar em \(description)")
        }
        if let target {
            if step.button == .left, step.count == 1, target.entry.actionable || local?.actionable == true {
                return try press(target, "Cliquei em")
            }
            let state = UIState.capture(root: root, target: target.element, known: target.attributes)
            return Acted(summary: "Cliquei em \(target.name) (\(target.id), \(description)).", target: target.element, before: state,
                         input: .click(screen, window: windowRef, button: step.button, count: step.count), inputWhat: "clicar em \(target.name)")
        }
        return Acted(summary: "Cliquei em \(description) de \(snapshot.windowTitle.isEmpty ? app.name : UIText.quoted(snapshot.windowTitle)).",
                     target: nil, before: UIState.capture(root: root, target: nil),
                     input: .click(screen, window: windowRef, button: step.button, count: step.count), inputWhat: "clicar em \(description)")
    }

    /// Whether `element` is in `window`, or in a sheet or drawer of it: its `AXWindow` (or that window's parent) is the
    /// window, or, for an element that does not say, the window is among its ancestors.
    static func belongs(_ element: any AccessibilityElement, to window: any AccessibilityElement) -> Bool {
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
        let containing = snapshot.entries.filter { $0.key.hasPrefix("w") && ($0.value.frame?.contains(point) ?? false) }
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

    /// Lists and tables (`AXSelected`, `AXSelectedRows`), pop-up buttons (their menu, without opening it), combo boxes
    /// (`AXValue`), tab and radio groups.
    private static func select(_ step: Step, resolve: (String) throws -> UIResolver.Resolved, root: any AccessibilityElement, app: AccessibilityApp,
                               before: (UIResolver.Resolved?) -> UIState, press: (UIResolver.Resolved, String) throws -> Acted,
                               checkDanger: (String, String) throws -> Void) throws -> Acted {
        if !step.ids.isEmpty {
            let rows = try ([step.reference].compactMap { $0 } + step.ids).map(resolve)
            for row in rows { try checkDanger(row.live.identity, row.name) }
            let state = before(rows.first)
            // A table or outline selects several rows at once through its AXSelectedRows.
            if let parent = rows[0].element.element("AXParent"), parent.isSettable("AXSelectedRows") {
                try parent.setValue(.elements(rows.map(\.element)), for: "AXSelectedRows")
            } else {
                for row in rows {
                    guard row.element.isSettable("AXSelected") else { throw ToolError("\(row.name) (\(row.id)) não pode ser selecionado.") }
                    try row.element.setValue(.bool(true), for: "AXSelected")
                }
            }
            return Acted(summary: "Selecionei \(rows.count) itens: \(rows.map(\.id).joined(separator: ", ")).", target: rows.first?.element, before: state)
        }
        let target = try resolve(step.reference ?? "")
        guard let value = step.value else {
            if target.element.isSettable("AXSelected") {
                try checkDanger(target.live.identity, target.name)
                let state = before(target)
                try target.element.setValue(.bool(true), for: "AXSelected")
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
            guard let row = rows.prefix(500).first(where: { UIText.fold(rowText($0)).contains(wanted) }) else {
                throw ToolError("Nenhuma linha de \(target.name) tem \(UIText.quoted(value)).")
            }
            try checkDanger(rowText(row), "a linha \(UIText.quoted(value))")
            if row.isSettable("AXSelected") {
                try row.setValue(.bool(true), for: "AXSelected")
            } else if target.element.isSettable("AXSelectedRows") {
                try target.element.setValue(.elements([row]), for: "AXSelectedRows")
            } else {
                throw ToolError("As linhas de \(target.name) não podem ser selecionadas por Acessibilidade.")
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

    /// The scroll bar's value (0…1) moved by pages; else a scroll event sent to the app over the area.
    private static func scroll(_ target: UIResolver.Resolved, direction: String, amount: Int, before state: UIState, windowRef: WindowRef) throws -> Acted {
        var area: (any AccessibilityElement)? = target.element
        var areaRole = target.live.rawRole
        for _ in 0..<5 where areaRole != "AXScrollArea" {
            area = area?.element("AXParent")
            areaRole = area?.string("AXRole") ?? ""
        }
        let vertical = direction == "up" || direction == "down"
        let sign: Double = direction == "up" || direction == "left" ? -1 : 1
        let words = "\(direction == "up" ? "para cima" : direction == "down" ? "para baixo" : direction == "left" ? "para a esquerda" : "para a direita") (\(amount) pág.)"
        let scrollArea = areaRole == "AXScrollArea" ? area : nil
        if let scrollArea, let bar = scrollArea.element(vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"),
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
        let pixels = Int(Double(vertical ? frame.height : frame.width) * 0.9) * amount
        // Positive values move the content down (the page goes up), like a trackpad.
        let delta = Int(-sign) * pixels
        return Acted(summary: "Rolei \(target.name) (\(target.id)) \(words).", target: target.element, before: state,
                     input: .scroll(dx: vertical ? 0 : delta, dy: vertical ? delta : 0, at: CGPoint(x: frame.midX, y: frame.midY), window: windowRef),
                     inputWhat: "rolar \(target.name)")
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
        case click(CGPoint, button: MouseButton, count: Int)
        case type(String)
        case key(KeyStroke)
    }

    /// Runs the steps with the real mouse and keyboard, only through `ScreenOwner` (which brings the app forward, and puts
    /// the user's app, window and cursor back whatever happens). Where each step lands is read in the background first.
    private func takeOver(_ steps: [Step], app: AccessibilityApp, context: ToolContext) async throws -> String {
        let snapshot = store.snapshot(bot: context.botID, app: app)
        let system = system, live = live
        let bot = context.botID
        let (moves, window, before) = try await UIAccess.mapped(app) {
            try await sessions.run(app, within: sessions.deadlines.action) { () throws -> ([Move], (any AccessibilityElement)?, UIState) in
                let root = system.root(of: app)
                var moves: [Move] = []
                var window: (any AccessibilityElement)?
                func center(_ step: Step) throws -> CGPoint {
                    if let pixel = step.point {
                        guard let snapshot, let shot = snapshot.shot else {
                            throw ToolError("x e y são pixels do último screenshot com marcas da janela; tire um screenshot antes.")
                        }
                        guard let windows = root.elements("AXWindows"), let found = UIWindowChooser.window(of: snapshot, in: windows) else {
                            throw UIResolver.stale("a janela \(UIText.quoted(snapshot.windowTitle)) não está mais aberta")
                        }
                        let now = found.read(["AXPosition", "AXSize"]).attributes ?? [:]
                        guard case .point(let origin)? = now["AXPosition"], case .size(let size)? = now["AXSize"] else {
                            throw UIResolver.stale("não consegui ler onde está a janela")
                        }
                        // As in the background: the pixels point elsewhere in a window that changed size since the picture.
                        guard abs(size.width - shot.windowFrame.width) <= 2, abs(size.height - shot.windowFrame.height) <= 2 else {
                            throw UIResolver.stale("a janela mudou de tamanho desde o screenshot; tire outro")
                        }
                        window = window ?? found
                        return CGPoint(x: origin.x + pixel.x / shot.scale, y: origin.y + pixel.y / shot.scale)
                    }
                    let id = try UIResolver.id(for: step.reference ?? "", in: snapshot, app: app)
                    let cached = snapshot.flatMap { live.element(bot: bot, pid: app.pid, generation: $0.generation, takenAt: $0.takenAt, id: id) }
                    let target = try UIResolver.resolve(id: id, root: root, app: app, snapshot: snapshot, cached: cached)
                    window = window ?? target.window
                    guard let frame = target.frame else { throw ToolError("\(target.name) não diz onde está na tela.") }
                    return CGPoint(x: frame.midX, y: frame.midY)
                }
                for step in steps {
                    switch step.action {
                    case .press, .focus, .select, .showMenu:
                        moves.append(.click(try center(step), button: .left, count: 1))
                    case .click:
                        moves.append(.click(try center(step), button: step.button, count: step.count))
                    case .type:
                        if step.reference != nil { moves.append(.click(try center(step), button: .left, count: 1)) }
                        moves.append(.type(step.value ?? ""))
                    case .setValue:
                        moves.append(.click(try center(step), button: .left, count: 1))
                        moves.append(.key(KeyStroke(.character("a"), modifiers: .command)))
                        moves.append(.type(step.value ?? ""))
                    case .key:
                        if step.reference != nil { moves.append(.click(try center(step), button: .left, count: 1)) }
                        moves += step.keys.map(Move.key)
                    case .scroll, .increment, .decrement, .pickMenu:
                        throw ToolError("\(step.action.rawValue) funciona em segundo plano; repita sem takeover.")
                    }
                }
                return (moves, window, UIState.capture(root: root, target: nil))
            }
        }
        let report = try await system.screen.takeOver(app, window: window, limit: .seconds(10)) { hand in
            for move in moves {
                try Task.checkCancellation()
                switch move {
                case .click(let point, let button, let count): try await hand.click(at: point, button: button, count: count)
                case .type(let text): try await hand.type(text)
                case .key(let stroke): try await hand.key(stroke)
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
