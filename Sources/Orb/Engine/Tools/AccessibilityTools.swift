import Foundation

// Reading and operating other apps' interface through the Accessibility API (`ui_read`, `ui_act`), for apps that have
// no AppleScript or Shortcuts support. The API itself sits behind `AccessibilitySystem` (AccessibilityElements.swift);
// the outline and the snapshot that ties an id to the element it named are in AccessibilityOutline.swift.

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
        func target(_ app: RunningAppInfo) -> AccessibilityApp { AccessibilityApp(name: app.name, bundleID: app.bundleID, pid: app.pid) }

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
}

// MARK: - Windows

enum UIWindowChooser {
    static func title(of window: any AccessibilityElement) -> String { window.string("AXTitle") ?? "" }

    /// The index (from 0) of the window to read. `selector` is a position from 1 or part of a title; without one, the
    /// focused window, else the main one, else the first.
    static func choose(from windows: [any AccessibilityElement], selector: String?) throws -> Int {
        guard !windows.isEmpty else { throw ToolError("O app não tem janelas.") }
        let wanted = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            return windows.firstIndex { $0.bool("AXFocused") == true } ?? windows.firstIndex { $0.bool("AXMain") == true } ?? 0
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
}

// MARK: - ui_read

struct UIReadTool: AgentTool {
    let spec = ToolSpec(
        name: "ui_read",
        description: """
        Read an app's interface through Accessibility, for apps without AppleScript or Shortcuts support. \
        Returns an indented outline of one window, a line per element: id (w1.3.2 = window 1, 3rd child, its 2nd \
        child; m2 = 2nd menu), role, title, value (cut at 80 characters; passwords never read) and flags \
        [desativado, foco, selecionado]. Stops at 400 lines. Ids are valid for this reading only. Needs \
        Accessibility.
        """,
        parameters: .schema([
            "app": .property("string", "Name or bundle id (default: the frontmost)."),
            "window": .property("string", "Number (1 = frontmost) or part of the title."),
            "query": .property("string", "Only elements containing this text."),
            "max_depth": .property("integer", "1-12 (default 12)."),
            "include_menus": .property("boolean", "Also the top-level menus (m1, m2…)."),
        ]))

    let system: any AccessibilitySystem
    let store: UISnapshotStore
    var limits = UIOutlineLimits()

    init(system: any AccessibilitySystem = LiveAccessibilitySystem(), store: UISnapshotStore = .shared, limits: UIOutlineLimits = UIOutlineLimits()) {
        self.system = system
        self.store = store
        self.limits = limits
    }

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let app = arguments.nonEmptyString("app") ?? "o app da frente"
        let detail = [arguments.nonEmptyString("window").map { "janela \($0)" }, arguments.nonEmptyString("query").map { "busca: \($0)" }]
        return ("Lendo a interface de \(app)", detail.compactMap { $0 }.joined(separator: " · "))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let app = try await UIAccess.open(arguments["app"]?.string, system: system)
        let root = system.root(of: app)
        var limits = limits
        limits.maxDepth = arguments.integer("max_depth", default: limits.maxDepth, in: 1...limits.maxDepth)
        let window = arguments["window"]?.int.map(String.init) ?? arguments.nonEmptyString("window"), query = arguments.nonEmptyString("query")
        let menus = arguments.flag("include_menus")
        let readLimits = limits
        let system = system
        let result = try await runDetached {
            system.prepare(root)
            return try Self.read(root: root, app: app, window: window, query: query, includeMenus: menus, limits: readLimits)
        }
        store.save(result.snapshot, bot: context.botID)
        return result.text
    }

    /// Reads one window (and the menus when asked or when there is no window). Blocking: call it off the main actor.
    static func read(root: any AccessibilityElement, app: AccessibilityApp, window selector: String?, query: String?,
                     includeMenus: Bool, limits: UIOutlineLimits) throws -> (text: String, snapshot: UISnapshot) {
        let windows = root.elements("AXWindows")
        guard windows != nil || root.attribute("AXRole") != nil else {
            throw ToolError("\(app.name) não respondeu. Ele pode estar travado, ocupado com um diálogo ou não expor a interface por acessibilidade.")
        }
        var text = "App: \(app.name)" + (app.bundleID.map { " (\($0))" } ?? "")
        var entries: [String: UISnapshot.Entry] = [:]
        var windowIndex: Int?
        var windowTitle = ""

        if let windows, !windows.isEmpty {
            let index = try UIWindowChooser.choose(from: windows, selector: selector)
            windowIndex = index + 1
            windowTitle = UIWindowChooser.title(of: windows[index])
            let outline = UIOutlineBuilder.outline(of: windows[index], prefix: "w\(index + 1)", query: query, limits: limits)
            try Task.checkCancellation()
            entries = outline.entries
            text += "\n" + UIWindowChooser.list(windows, reading: index)
            if outline.lines.isEmpty {
                text += query.map { "\nNenhum elemento combina com \(UIText.quoted($0)) nesta janela." } ?? "\nNão consegui ler elementos desta janela."
            } else {
                text += "\n" + outline.lines.joined(separator: "\n")
            }
            if let query, !outline.lines.isEmpty { text += "\n(\(outline.matched) elemento\(outline.matched == 1 ? "" : "s") combina\(outline.matched == 1 ? "" : "m") com \(UIText.quoted(query)))" }
            if let notice = cutNotice(outline, limits: limits) { text += "\n" + notice }
        } else {
            text += "\nO app está aberto mas não tem janelas visíveis. Dá para usar os menus (ui_act com pick_menu ou show_menu)."
        }

        if includeMenus || windowIndex == nil {
            if let menus = UIOutlineBuilder.menuBar(of: root) {
                entries.merge(menus.entries) { current, _ in current }
                text += "\nMenus da barra:\n" + menus.lines.joined(separator: "\n")
            } else {
                text += "\nNão consegui ler a barra de menus de \(app.name)."
            }
        }
        let snapshot = UISnapshot(app: app, windowIndex: windowIndex, windowTitle: windowTitle, entries: entries)
        return (text, snapshot)
    }

    private static func cutNotice(_ outline: UIOutline, limits: UIOutlineLimits) -> String? {
        var reasons: [String] = []
        if outline.cuts.contains(.lines) { reasons.append("mostrei \(outline.lines.count) de \(outline.total) elementos (limite de \(limits.maxLines) linhas)") }
        if outline.cuts.contains(.depth) { reasons.append("há elementos mais fundos que a profundidade \(limits.maxDepth)") }
        if outline.cuts.contains(.visited) { reasons.append("a janela é grande: examinei só os primeiros \(limits.maxVisited) elementos") }
        if outline.cuts.contains(.time) { reasons.append("a leitura passou de \(Int(limits.seconds)) s e parou") }
        guard !reasons.isEmpty else { return nil }
        return "[Saída cortada: " + reasons.joined(separator: "; ") + ". Use query para achar um elemento ou window para outra janela.]"
    }
}

// MARK: - Finding an element again

enum UIResolver {
    static let staleMessage = "A interface mudou; chame ui_read de novo."

    /// `w1.3.2.5` → kind "w", numbers [1, 3, 2, 5]; `m2` → kind "m", numbers [2].
    static func parse(_ id: String) -> (kind: Character, numbers: [Int])? {
        guard id.range(of: #"^[wm][0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil, let kind = id.first else { return nil }
        let numbers = id.dropFirst().split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : (kind, numbers)
    }

    /// The live element behind an id of the last reading, checked against what that reading saw there (role and name):
    /// if they differ the interface moved and the caller must read again rather than click something else.
    static func resolve(id: String, root: any AccessibilityElement, app: AccessibilityApp,
                        snapshot: UISnapshot?) throws -> (element: any AccessibilityElement, entry: UISnapshot.Entry) {
        guard let snapshot else { throw ToolError("Ainda não li a interface de \(app.name); chame ui_read antes de agir.") }
        guard snapshot.app.pid == app.pid else { throw ToolError(staleMessage) }
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parse(id) else {
            throw ToolError("Id inválido \"\(id)\": use um id de ui_read, como w1.3.2 ou m2.")
        }
        guard let entry = snapshot.entries[id] else {
            throw ToolError("O id \"\(id)\" não está na última leitura de \(app.name); chame ui_read de novo (use query para achar o elemento).")
        }

        var current: any AccessibilityElement
        if parsed.kind == "m" {
            guard let items = root.element("AXMenuBar")?.elements("AXChildren"), items.indices.contains(parsed.numbers[0] - 1) else {
                throw ToolError(staleMessage)
            }
            current = items[parsed.numbers[0] - 1]
        } else {
            guard snapshot.windowIndex == parsed.numbers[0], let windows = root.elements("AXWindows"),
                  let window = window(at: parsed.numbers[0] - 1, titled: snapshot.windowTitle, in: windows) else {
                throw ToolError(staleMessage)
            }
            current = window
        }
        for position in parsed.numbers.dropFirst() {
            guard let children = current.elements("AXChildren"), children.indices.contains(position - 1) else { throw ToolError(staleMessage) }
            current = children[position - 1]
        }

        let live = UIElementInfo(attributes: current.attributes(UIElementInfo.attributeNames))
        guard live.rawRole == entry.rawRole else { throw ToolError(staleMessage) }
        if !entry.label.isEmpty, UIText.fold(live.identity) != UIText.fold(entry.label) { throw ToolError(staleMessage) }
        return (current, entry)
    }

    /// The window the snapshot came from: at the same position with the same title, else any window with that title
    /// (windows reorder as focus moves).
    private static func window(at index: Int, titled title: String, in windows: [any AccessibilityElement]) -> (any AccessibilityElement)? {
        let wanted = UIText.fold(title)
        if windows.indices.contains(index), UIText.fold(UIWindowChooser.title(of: windows[index])) == wanted { return windows[index] }
        return windows.first { UIText.fold(UIWindowChooser.title(of: $0)) == wanted }
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
        let lines = items(under: item).compactMap { entry -> String? in
            let name = title(of: entry)
            guard !name.isEmpty else { return nil }
            var line = "- " + UIText.clean(name, limit: 60)
            if !items(under: entry).isEmpty { line += " ▸" }
            if entry.bool("AXEnabled") == false { line += " (desativado)" }
            return line
        }
        return lines.prefix(40).joined(separator: "\n") + (lines.count > 40 ? "\n- …" : "")
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

    static func capture(root: any AccessibilityElement, target: (any AccessibilityElement)?) -> UIState {
        var state = UIState()
        state.windows = (root.elements("AXWindows") ?? []).map(UIWindowChooser.title(of:))
        let front = root.element("AXFocusedWindow")
        state.focusedWindow = front.map(UIWindowChooser.title(of:))
        state.sheet = front?.elements("AXChildren")?.contains { $0.string("AXRole") == "AXSheet" } ?? false
        if let focused = root.element("AXFocusedUIElement") {
            let info = UIElementInfo(attributes: focused.attributes(UIElementInfo.attributeNames))
            state.focusedElement = info.role + (info.identity.isEmpty ? "" : " " + UIText.quoted(info.identity))
        }
        if let target {
            let attributes = target.attributes(UIElementInfo.attributeNames)
            if attributes.isEmpty {
                state.targetGone = true
            } else {
                let info = UIElementInfo(attributes: attributes)
                var parts: [String] = []
                if let value = UIElementInfo.readValue(of: target, info: info) { parts.append("valor \(UIText.quoted(value))") }
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

/// Clicks that cannot be taken back, recognized by the name of the element or menu item.
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
}

// MARK: - ui_act

struct UIActTool: AgentTool {
    enum Action: String, CaseIterable {
        case press, focus, setValue = "set_value", increment, decrement, showMenu = "show_menu", pickMenu = "pick_menu"
    }

    let spec = ToolSpec(
        name: "ui_act",
        description: """
        Operate one element found with ui_read: press (click), focus, set_value (field text, slider number), \
        increment, decrement, show_menu (list a menu's items) or pick_menu (menu_path such as \
        ["Arquivo", "Exportar…"] clicks menu bar items by title, no id). Use ids from the latest ui_read of that \
        app; if the screen changed the call fails with "a interface mudou" and you read again. Anything that \
        deletes, sends, buys or discards always asks the user first. Needs Accessibility.
        """,
        parameters: .schema([
            "app": .property("string"),
            "action": .object(["type": .string("string"), "enum": .array(Action.allCases.map { JSONValue.string($0.rawValue) })]),
            "id": .property("string", "From ui_read (w1.3.2, m2); not for pick_menu."),
            "value": .property("string"),
            "menu_path": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        ], required: ["action"]))

    let system: any AccessibilitySystem
    let store: UISnapshotStore
    /// How long to wait after acting before looking at what changed.
    let settle: Duration
    /// How long to wait after bringing the app forward (menus of a background app can ignore the click).
    let activation: Duration

    init(system: any AccessibilitySystem = LiveAccessibilitySystem(), store: UISnapshotStore = .shared,
         settle: Duration = .milliseconds(300), activation: Duration = .milliseconds(150)) {
        self.system = system
        self.store = store
        self.settle = settle
        self.activation = activation
    }

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    // MARK: Judging a call before it runs

    /// Every reading that has the id and may be what the call is about (the readings of the named app, or of any app when
    /// none is named), newest first. Which one `run` clicks depends on the frontmost app and the Orb, so the danger check
    /// looks at all of them: it may ask too much, never too little.
    private func targets(of arguments: JSONValue) -> [(snapshot: UISnapshot, entry: UISnapshot.Entry)] {
        guard let id = arguments.nonEmptyString("id")?.trimmingCharacters(in: .whitespaces) else { return [] }
        return store.candidates(matching: arguments.nonEmptyString("app")).compactMap { snapshot in
            snapshot.entries[id].map { (snapshot, $0) }
        }
    }

    /// What the call would click, from the last readings: the approval card names it. When readings disagree, the one
    /// that makes the call dangerous is shown, so the card is not milder than the check.
    private func target(of arguments: JSONValue) -> (snapshot: UISnapshot, entry: UISnapshot.Entry)? {
        let found = targets(of: arguments)
        return found.first { UIDanger.reason(forLabel: $0.entry.label, appName: $0.snapshot.app.name, bundleID: $0.snapshot.app.bundleID) != nil }
            ?? found.first
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

    /// Deleting, sending, buying and discarding stay asked even in "Automático": judged by the name of the element
    /// (from the last reading) or of the menu item. A password field is never filled without asking.
    func danger(_ arguments: JSONValue) -> String? {
        guard let action = arguments["action"]?.string.flatMap(Action.init(rawValue:)) else { return nil }
        let appArgument = arguments.nonEmptyString("app")
        switch action {
        case .pickMenu:
            guard let last = Self.menuPath(in: arguments)?.last else { return nil }
            // Without an app the call is about the frontmost one, which no reading tells: assume a messaging app.
            guard let appArgument else { return UIDanger.reason(forLabel: last, appName: nil, bundleID: nil, assumeMessaging: true) }
            for snapshot in store.candidates(matching: appArgument) {
                if let reason = UIDanger.reason(forLabel: last, appName: snapshot.app.name, bundleID: snapshot.app.bundleID) { return reason }
            }
            return UIDanger.reason(forLabel: last, appName: appArgument, bundleID: appArgument)
        case .press:
            for found in targets(of: arguments) {
                if let reason = UIDanger.reason(forLabel: found.entry.label, appName: found.snapshot.app.name, bundleID: found.snapshot.app.bundleID) { return reason }
            }
            return nil
        case .setValue:
            return targets(of: arguments).contains { $0.entry.secure } ? "preenche um campo de senha" : nil
        default:
            return nil
        }
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let action = arguments["action"]?.string.flatMap(Action.init(rawValue:))
        let appName = arguments.nonEmptyString("app") ?? "o app da frente"
        if action == .pickMenu {
            return ("Escolhendo no menu de \(appName)", Self.menuPath(in: arguments)?.joined(separator: " → ") ?? "")
        }
        let found = target(of: arguments)
        let label = found.map { $0.entry.label }.flatMap { $0.isEmpty ? nil : UIText.quoted($0) }
            ?? "o elemento \(arguments.nonEmptyString("id") ?? "")"
        let role = found.map { UIRole.short($0.entry.rawRole) + " " } ?? ""
        let place = " · " + (found?.snapshot.app.name ?? appName)
        switch action {
        case .press?: return ("Clicando em \(label)", role + (arguments.nonEmptyString("id") ?? "") + place)
        case .focus?: return ("Focando em \(label)", role + (arguments.nonEmptyString("id") ?? "") + place)
        case .setValue?:
            let value = arguments["value"]?.string ?? ""
            let text = found?.entry.secure == true ? "(campo de senha)" : (value.count > 300 ? value.prefix(300) + "…" : value)
            return ("Escrevendo em \(label)", text + place)
        case .increment?: return ("Aumentando \(label)", place)
        case .decrement?: return ("Diminuindo \(label)", place)
        case .showMenu?: return ("Abrindo o menu \(label)", place)
        default: return ("Operando a interface de \(appName)", arguments.nonEmptyString("id") ?? "")
        }
    }

    // MARK: Running

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let actionName = try arguments.requiredString("action")
        guard let action = Action(rawValue: actionName) else {
            throw ToolError("Ação desconhecida \"\(actionName)\": use \(Action.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        var menuPath: [String] = []
        var id = ""
        var value = ""
        switch action {
        case .pickMenu:
            guard let path = Self.menuPath(in: arguments) else { throw ToolError("Faltou o argumento \"menu_path\", por exemplo [\"Arquivo\", \"Exportar…\"].") }
            menuPath = path
        case .setValue:
            id = try arguments.requiredString("id")
            value = try arguments.requiredString("value", allowEmpty: true)
        default:
            id = try arguments.requiredString("id")
        }

        let app = try await UIAccess.open(arguments["app"]?.string, system: system)
        let root = system.root(of: app)
        let snapshot = action == .pickMenu ? nil : store.snapshot(bot: context.botID, app: app)

        if action == .pickMenu || action == .showMenu {
            system.activate(app)
            try await Task.sleep(for: activation)
        }
        let acted: Acted
        let system = system
        do {
            let request = Request(action: action, id: id, value: value, menuPath: menuPath)
            acted = try await runDetached {
                system.prepare(root)
                return try Self.perform(request, root: root, app: app, snapshot: snapshot)
            }
        } catch let failure as AXFailure {
            throw UIAccess.error(for: failure, app: app)
        }
        try await Task.sleep(for: settle)
        let after = await (try? runDetached { UIState.capture(root: root, target: acted.target) }) ?? acted.before
        var text = acted.summary + " " + UIState.describe(from: acted.before, to: after)
        if let listing = acted.listing, !listing.isEmpty { text += "\nItens do menu:\n" + listing }
        return text
    }

    struct Request: Sendable {
        var action: Action
        var id: String
        var value: String
        var menuPath: [String]
    }

    struct Acted: Sendable {
        var summary: String
        var target: (any AccessibilityElement)?
        var before: UIState
        var listing: String?
    }

    /// The action itself. Blocking: call it off the main actor. Throws `ToolError` for what the model can fix and
    /// `AXFailure` for what the API refused.
    static func perform(_ request: Request, root: any AccessibilityElement, app: AccessibilityApp, snapshot: UISnapshot?) throws -> Acted {
        if request.action == .pickMenu {
            let before = UIState.capture(root: root, target: nil)
            let found = try UIMenu.resolve(request.menuPath, root: root, app: app)
            do { try found.element.perform("AXPress") } catch AXFailure.notSupported {
                throw ToolError("Esse item de menu de \(app.name) não aceita clique.")
            }
            return Acted(summary: "Escolhi \(found.titles.joined(separator: " → ")) em \(app.name).", target: nil, before: before)
        }

        let resolved = try UIResolver.resolve(id: request.id, root: root, app: app, snapshot: snapshot)
        let element = resolved.element
        let name = resolved.entry.label.isEmpty ? UIRole.short(resolved.entry.rawRole) : "\(UIRole.short(resolved.entry.rawRole)) \(UIText.quoted(resolved.entry.label))"
        let before = UIState.capture(root: root, target: element)
        let actions = element.actionNames()

        func missing(_ what: String) -> ToolError {
            let known = actions.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
            let subject = name.prefix(1).uppercased() + name.dropFirst()
            return ToolError("\(subject) não aceita \(what)." + (known.isEmpty ? "" : " Ações dele: " + known.joined(separator: ", ") + "."))
        }

        switch request.action {
        case .press:
            if actions.contains("AXPress") {
                try element.perform("AXPress")
                return Acted(summary: "Cliquei em \(name) (\(request.id)).", target: element, before: before)
            }
            if element.isSettable("AXSelected") {
                try element.setValue(.bool(true), for: "AXSelected")
                return Acted(summary: "Selecionei \(name) (\(request.id)).", target: element, before: before)
            }
            throw missing("clique")
        case .focus:
            do { try element.setValue(.bool(true), for: "AXFocused") } catch AXFailure.notSupported {
                guard actions.contains("AXRaise") else { throw missing("foco") }
                try element.perform("AXRaise")
            }
            return Acted(summary: "Dei foco a \(name) (\(request.id)).", target: element, before: before)
        case .setValue:
            guard element.isSettable("AXValue") else { throw missing("receber um valor (não é um campo editável)") }
            try element.setValue(settableValue(request.value, current: element.attribute("AXValue")), for: "AXValue")
            return Acted(summary: "Escrevi em \(name) (\(request.id)).", target: element, before: before)
        case .increment, .decrement:
            let action = request.action == .increment ? "AXIncrement" : "AXDecrement"
            guard actions.contains(action) else { throw missing(request.action == .increment ? "aumentar" : "diminuir") }
            try element.perform(action)
            return Acted(summary: "\(request.action == .increment ? "Aumentei" : "Diminuí") \(name) (\(request.id)).", target: element, before: before)
        case .showMenu:
            let menuLike: Set<String> = ["AXMenuBarItem", "AXMenuItem", "AXPopUpButton", "AXMenuButton"]
            let preferred = !menuLike.contains(resolved.entry.rawRole) && actions.contains("AXShowMenu") ? "AXShowMenu" : "AXPress"
            guard actions.contains(preferred) || actions.contains("AXShowMenu") else { throw missing("abrir menu") }
            try element.perform(actions.contains(preferred) ? preferred : "AXShowMenu")
            return Acted(summary: "Abri o menu de \(name) (\(request.id)).", target: nil, before: before, listing: UIMenu.listing(under: element))
        case .pickMenu:
            throw ToolError(UIResolver.staleMessage)
        }
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
}

extension ToolBox {
    static let accessibilityTools: [any AgentTool] = [UIReadTool(), UIActTool()]
}
