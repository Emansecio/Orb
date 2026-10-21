import Foundation

// The browser tools that came after the first thirteen: waiting, finding by words, JavaScript dialogs, files, the page as a whole
// and a door to every other command of agent-browser (`browse_run`). `BrowseTools.swift` has the rest and what they share.

// MARK: - Waiting

struct BrowseWaitTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_wait",
        description: """
        Wait for one of: `text` to appear, `url` (a glob like **/done), `ref` to show, a `load` state, or `ms`. Fails after \
        `timeout` ms (default 10000, up to 40000).
        """,
        parameters: .schema([
            "text": .property("string"), "url": .property("string"), "ref": .property("string"),
            "load": BrowseSupport.choice(["load", "domcontentloaded", "networkidle"]),
            "ms": .property("integer"), "timeout": .property("integer"),
        ]))

    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func readsLivePage(_ arguments: JSONValue) -> Bool { true }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Esperando a página", arguments["text"]?.string ?? arguments["url"]?.string ?? arguments["load"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let timeout = String(arguments.integer("timeout", default: 10_000, in: 1_000...40_000))
        let words: [String]
        let what: String
        let given = ["text", "url", "ref", "load", "ms"].filter { arguments[$0] != nil && arguments.nonEmptyString($0) != nil || ($0 == "ms" && arguments[$0]?.int != nil) }
        guard given.count == 1, let one = given.first else { throw ToolError("Give exactly one of `text`, `url`, `ref`, `load` or `ms`.") }
        switch one {
        case "text":
            let text = try arguments.requiredString("text")
            guard !text.hasPrefix("-") else { throw ToolError("`text` cannot start with “-”.") }
            words = ["wait", "--text", text, "--timeout", timeout]
            what = "the text “\(text.clipped(to: 80))” appeared"
        case "url":
            let pattern = try arguments.requiredString("url")
            guard !pattern.hasPrefix("-") else { throw ToolError("`url` cannot start with “-”.") }
            words = ["wait", "--url", pattern, "--timeout", timeout]
            what = "the address matched \(pattern)"
        case "ref":
            let ref = try BrowseSupport.ref(arguments)
            words = ["wait", "@" + ref, "--timeout", timeout]
            what = "\(ref) showed"
        case "load":
            let state = try arguments.requiredString("load").lowercased()
            guard ["load", "domcontentloaded", "networkidle"].contains(state) else { throw ToolError("`load` is load, domcontentloaded or networkidle.") }
            words = ["wait", "--load", state, "--timeout", timeout]
            what = "the page reached \(state)"
        default:
            let ms = arguments.integer("ms", default: 1_000, in: 1...40_000)
            words = ["wait", String(ms)]
            what = "\(ms) ms passed"
        }
        let session = try await BrowseSupport.session(context)
        _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(words) } }
        session.pageChanged()
        return "Done: \(what)."
    }
}

// MARK: - Finding by words

struct BrowseFindTool: BrowseTool {
    static let locators = ["role", "text", "label", "placeholder", "alt", "title", "testid"]
    static let actions = ["text", "click", "fill", "check", "hover"]

    let spec = ToolSpec(
        name: "browse_find",
        description: """
        Find an element by what a person sees (no ref) and act on it: `by` and `value` (a role also takes `name`); `do` (default \
        text, which reads it; fill types `text`). For what browse_snapshot did not list. Never for passwords or card numbers: \
        browse_show.
        """,
        parameters: .schema([
            "by": BrowseSupport.choice(locators), "value": .property("string"), "name": .property("string"),
            "do": BrowseSupport.choice(actions), "text": .property("string"), "exact": .property("boolean"),
        ], required: ["by", "value"]))

    private func action(_ arguments: JSONValue) -> String { arguments.nonEmptyString("do")?.lowercased() ?? "text" }

    func risk(_ arguments: JSONValue) -> ToolRisk { action(arguments) == "text" ? .safe : .sensitive }
    func readsLivePage(_ arguments: JSONValue) -> Bool { action(arguments) == "text" }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let found = (arguments["value"]?.string ?? "").clipped(to: 80)
        switch action(arguments) {
        case "click": return ("Clicando em um elemento", found)
        case "fill": return ("Preenchendo um campo", found)
        case "check": return ("Marcando uma caixa", found)
        case "hover": return ("Passando o mouse", found)
        default: return ("Procurando na página", found)
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let by = try arguments.requiredString("by").lowercased()
        guard Self.locators.contains(by) else { throw ToolError("`by` is one of: \(Self.locators.joined(separator: ", ")).") }
        let value = try arguments.requiredString("value")
        let action = action(arguments)
        guard Self.actions.contains(action) else { throw ToolError("`do` is one of: \(Self.actions.joined(separator: ", ")).") }
        guard !value.hasPrefix("-") else { throw ToolError("`value` cannot start with “-”.") }
        var built = ["find", by, value, action]
        if action == "fill" {
            let text = try arguments.requiredString("text", allowEmpty: true)
            guard !text.hasPrefix("-") else { throw ToolError("To type text that starts with “-” use browse_fill with a ref.") }
            // `name` only goes to the page for `by: role`; for any other locator the text that finds the field is `value`.
            let name = by == "role" ? (arguments.nonEmptyString("name") ?? value) : value
            if let reason = SecretField.reason(role: by == "role" ? value : "", name: name) { throw ToolError(SecretField.refusal(reason)) }
            built.append(text)
        }
        var options: [String] = []
        if let name = arguments.nonEmptyString("name"), by == "role" {
            guard !name.hasPrefix("-") else { throw ToolError("`name` cannot start with “-”.") }
            options += ["--name", name]
        }
        if arguments.flag("exact") { options.append("--exact") }
        let words = built + options
        // The same find, only to focus the field first: it is judged by its real type, as browse_fill and browse_press do.
        let focusWords = ["find", by, value, "focus"] + options
        let session = try await BrowseSupport.session(context)
        let (data, dialog) = try await BrowseSupport.acting {
            try await session.exclusive {
                if action == "fill" {
                    _ = try await session.driver.command(focusWords)
                    let focus = try await session.driver.evaluate(BrowsePressTool.focusScript)
                    if let reason = BrowsePressTool.secretReason(focus: focus) { throw ToolError(SecretField.refusal(reason)) }
                }
                let data = try await session.driver.command(words)
                let after = action == "text" ? (url: nil as String?, dialog: nil as String?) : await BrowseSupport.addressOrDialog(session)
                return (data, after.dialog)
            }
        }
        if action != "text" { session.pageChanged() }
        if action == "text" { return "\(BrowseSupport.untrusted)\n" + data.jsonString.truncated(to: 4_000) }
        return "Found by \(by) and did \(action): \(data.jsonString.truncated(to: 400))" + (dialog.map { " " + $0 } ?? " If the page changed, take a new browse_snapshot.")
    }
}

// MARK: - JavaScript dialogs

struct BrowseDialogTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_dialog",
        description: """
        A JavaScript dialog (alert, confirm, prompt): `action` (default status); `text` answers a prompt. While one is open \
        nothing else works on the page.
        """,
        parameters: .schema(["action": BrowseSupport.choice(["status", "accept", "dismiss"]), "text": .property("string")]))

    private func action(_ arguments: JSONValue) -> String { arguments.nonEmptyString("action")?.lowercased() ?? "status" }

    func risk(_ arguments: JSONValue) -> ToolRisk { action(arguments) == "status" ? .safe : .sensitive }
    func readsLivePage(_ arguments: JSONValue) -> Bool { action(arguments) == "status" }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch action(arguments) {
        case "accept": ("Aceitando o aviso da página", (arguments["text"]?.string ?? "").clipped(to: 120))
        case "dismiss": ("Recusando o aviso da página", "")
        default: ("Vendo o aviso da página", "")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let action = action(arguments)
        guard ["status", "accept", "dismiss"].contains(action) else { throw ToolError("`action` is status, accept or dismiss.") }
        let session = try await BrowseSupport.session(context)
        do {
            return try await session.exclusive {
                if action == "status" {
                    let data = try await session.driver.command(["dialog", "status"])
                    guard data["hasDialog"]?.bool == true else { return "No dialog is open." }
                    return "A \(data["type"]?.string ?? "JavaScript") dialog is open: “\((data["message"]?.string ?? "").clipped(to: 400))”."
                        + (data["defaultPrompt"]?.string.flatMap { $0.isEmpty ? nil : " Its default answer is “\($0)”." } ?? "")
                        + " Answer it with browse_dialog accept or dismiss."
                }
                let text = action == "accept" ? arguments.nonEmptyString("text") : nil
                _ = try await session.driver.command(["dialog", action] + (text.map { [$0] } ?? []), text: true)
                session.pageChanged()
                return action == "accept" ? "Dialog accepted." : "Dialog dismissed."
            }
        } catch BrowserDriverError.failed(let message) where message.contains("No dialog") {
            return "No dialog is open."
        }
    }
}

// MARK: - Files

struct BrowseFilesTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_files",
        description: """
        Files in the page: upload (`ref` of a file input, `path` of the file) or download (`ref` of what to click, `path` to save \
        at). Needs “Terminal e arquivos”; refused for keys, passwords and system files.
        """,
        parameters: .schema(["action": BrowseSupport.choice(["upload", "download"]), "ref": .property("string"), "path": .property("string")],
                            required: ["action", "ref", "path"]))

    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let path = arguments["path"]?.string ?? ""
        return arguments["action"]?.string == "download" ? ("Baixando um arquivo da página", "→ " + path) : ("Enviando um arquivo para a página", path)
    }

    /// An upload hands a file of the Mac to a site, a download writes one: each is judged like the tool that already does it.
    func danger(_ arguments: JSONValue, context: ToolContext) -> String? {
        guard let path = arguments.nonEmptyString("path") else { return nil }
        let url = context.url(for: path).resolvingLinkChain
        if arguments["action"]?.string == "download" { return DangerousCommand.reason(forWritingTo: url) }
        return DangerousCommand.SensitiveFiles().reason(for: url.path)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard context.canSaveFiles else { throw BrowseSupport.needsFiles("Files in the browser") }
        let action = try arguments.requiredString("action").lowercased()
        let ref = try BrowseSupport.ref(arguments)
        let url = context.url(for: try arguments.requiredString("path")).resolvingLinkChain
        let session = try await BrowseSupport.session(context)
        let fileManager = FileManager.default
        switch action {
        case "upload":
            guard fileManager.fileExists(atPath: url.path), !url.isExistingDirectory else { throw ToolError("\(url.path) is not a file.") }
            if let reason = DangerousCommand.SensitiveFiles().reason(for: url.path) { throw ToolError("Refused: this \(reason).") }
            _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(["upload", "@" + ref, url.path]) } }
            session.pageChanged()
            return "Uploaded \(url.lastPathComponent) to \(ref)."
        case "download":
            guard !url.isExistingDirectory else { throw ToolError("\(url.path) is a folder; give the file's name in `path`.") }
            try BrowseSupport.prepareToWrite(url)
            let before = BrowseSupport.stamp(of: url)
            _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(["download", "@" + ref, url.path]) } }
            session.pageChanged()
            guard let after = BrowseSupport.stamp(of: url), after != before else {
                throw ToolError("The page did not hand over a new file by clicking \(ref).")
            }
            let size = after.size
            return "Downloaded to \(url.path) (\(size) bytes)."
        default:
            throw ToolError("`action` is upload or download.")
        }
    }
}

// MARK: - The page as a whole

struct BrowsePageTool: BrowseTool {
    static let actions = ["frame", "pdf", "state_save", "state_load", "mouse_move", "mouse_down", "mouse_up", "mouse_wheel"]

    let spec = ToolSpec(
        name: "browse_page",
        description: """
        The page as a whole, by `action`: frame works inside the iframe `ref` (or main), then snapshot again; pdf saves it at \
        `path`; state_save and state_load keep this Orb's cookies and storage under `name`; mouse_* take `x`, `y`, `button`, \
        or `dy`, `dx` for the wheel.
        """,
        parameters: .schema([
            "action": BrowseSupport.choice(actions), "ref": .property("string"), "path": .property("string"), "name": .property("string"),
            "x": .property("number"), "y": .property("number"), "button": .property("string"), "dx": .property("number"), "dy": .property("number"),
        ], required: ["action"]))

    private func action(_ arguments: JSONValue) -> String { arguments.nonEmptyString("action")?.lowercased() ?? "" }

    private static let gentle: Set<String> = ["frame", "state_save", "mouse_move", "mouse_wheel"]
    func risk(_ arguments: JSONValue) -> ToolRisk { Self.gentle.contains(action(arguments)) ? .safe : .sensitive }
    func readsLivePage(_ arguments: JSONValue) -> Bool { Self.gentle.contains(action(arguments)) }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch action(arguments) {
        case "frame": ("Trocando de quadro da página", arguments["ref"]?.string ?? "")
        case "pdf": ("Salvando a página em PDF", "→ " + (arguments["path"]?.string ?? ""))
        case "state_save": ("Guardando os logins do navegador", arguments["name"]?.string ?? "")
        case "state_load": ("Restaurando os logins do navegador", arguments["name"]?.string ?? "")
        default: ("Usando o mouse na página", action(arguments))
        }
    }

    func danger(_ arguments: JSONValue, context: ToolContext) -> String? {
        guard action(arguments) == "pdf", let path = arguments.nonEmptyString("path") else { return nil }
        return DangerousCommand.reason(forWritingTo: context.url(for: path).resolvingLinkChain)
    }

    /// `name` as a file name in the Orb's own folder: letters, digits, `-` and `_`.
    static func stateName(_ arguments: JSONValue) throws -> String {
        let name = arguments.nonEmptyString("name") ?? "default"
        guard name.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil else {
            throw ToolError("`name` is up to 40 letters, digits, - or _.")
        }
        return name
    }

    private func number(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.number ?? arguments[key]?.string.flatMap(Double.init), value.isFinite, abs(value) < 100_000 else {
            throw ToolError("`\(key)` is a number of pixels.")
        }
        return String(Int(value.rounded()))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let action = action(arguments)
        guard Self.actions.contains(action) else { throw ToolError("`action` is one of: \(Self.actions.joined(separator: ", ")).") }
        let session = try await BrowseSupport.session(context)
        switch action {
        case "frame":
            let target = arguments.nonEmptyString("ref")?.lowercased() == "main" ? "main" : "@" + (try BrowseSupport.ref(arguments))
            _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(["frame", target]) } }
            session.forgetPage()
            return target == "main" ? "Back to the main page. Take a new browse_snapshot." : "Working inside the frame \(target.dropFirst()). Take a new browse_snapshot: its refs are the frame's."
        case "pdf":
            guard context.canSaveFiles else { throw BrowseSupport.needsFiles("Saving a PDF") }
            let url = context.url(for: try arguments.requiredString("path")).resolvingLinkChain
            guard !url.isExistingDirectory else { throw ToolError("\(url.path) is a folder; give the file's name in `path`.") }
            try BrowseSupport.prepareToWrite(url)
            let before = BrowseSupport.stamp(of: url)
            _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(["pdf", url.path]) } }
            guard let after = BrowseSupport.stamp(of: url), after != before else {
                throw ToolError("The browser reported a PDF but no new file was written.")
            }
            let size = after.size
            return "Saved the page as PDF at \(url.path) (\(size) bytes)."
        case "state_save", "state_load":
            let name = try Self.stateName(arguments)
            guard let botID = context.botID, let folder = context.browser.hub?.stateFolder(botID: botID) else {
                throw ToolError("There is no place to keep this browser's state here.")
            }
            let file = folder.appending(path: name + ".json")
            if action == "state_load", !FileManager.default.fileExists(atPath: file.path) { throw ToolError("No saved state called “\(name)”.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await BrowseSupport.acting {
                try await session.exclusive { try await session.driver.command(["state", action == "state_save" ? "save" : "load", file.path]) }
            }
            if action == "state_load" { session.forgetPage() }
            return action == "state_save" ? "Saved the cookies and storage as “\(name)”." : "Restored “\(name)”: open the page again to see it."
        default:
            let words: [String]
            switch action {
            case "mouse_move": words = ["mouse", "move", try number(arguments, "x"), try number(arguments, "y")]
            case "mouse_wheel": words = ["mouse", "wheel", try number(arguments, "dy")] + (arguments["dx"] == nil ? [] : [try number(arguments, "dx")])
            default:
                let button = arguments.nonEmptyString("button")?.lowercased() ?? "left"
                guard ["left", "right", "middle"].contains(button) else { throw ToolError("`button` is left, right or middle.") }
                words = ["mouse", action == "mouse_down" ? "down" : "up", button]
            }
            _ = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(words) } }
            session.pageChanged()
            return "Mouse: \(words.dropFirst().joined(separator: " "))."
        }
    }
}

// MARK: - Every other command

/// What `browse_run` takes and refuses, in one place: the same rules judge the call before it runs (the approval card) and when it does.
enum BrowseRunRules {
    /// Commands that are never run here, with what to do instead.
    static let refusedCommands: [String: String] = [
        "connect": "it would drive another browser than yours",
        "install": "the user installs the browser in Ajustes → Navegador", "upgrade": "the user updates it in Ajustes → Navegador",
        "doctor": "the user checks the install in Ajustes → Navegador",
        "plugin": "plugins are not available", "plugins": "plugins are not available",
        "dashboard": "it opens a server and a window", "mcp": "it starts another server", "stream": "it opens a server",
        "chat": "it runs another model", "inspect": "it opens DevTools in a window", "auth": "stored logins are typed by the user (browse_show)",
        "session": "your browser is the only session you work in", "close": "use browse_close",
        "open": "use browse_open", "goto": "use browse_open", "navigate": "use browse_open",
        "tab": "use browse_tabs, which keeps each conversation in its own tab",
        "batch": "send the commands one by one, so each is checked",
        "profiles": "it lists the user's own Chrome profiles",
        "clipboard": "it reaches the Mac's clipboard (clipboard_read and clipboard_write do that, with their own permission)",
        "confirm": "nothing in your session waits for a confirmation", "deny": "nothing in your session waits for a confirmation",
    ]
    /// Options that would change which browser it is, where it keeps its profile, how it starts, or where it writes files (the
    /// command line takes them exactly as written, anywhere in the command; they are compared the same way, ignoring case).
    static let refusedFlags: Set<String> = [
        "--cdp", "--session", "--profile", "--args", "--executable-path", "--headed", "--config", "--proxy", "--engine", "--provider", "-p",
        "--auto-connect", "--extension", "--allow-file-access", "--session-name", "--namespace", "--pin-tab", "--no-pin-tab",
        "--download-path", "--screenshot-dir", "--init-script", "--enable", "--state", "--restore", "--restore-save", "--user-agent",
        "--ignore-https-errors", "--ca-cert", "--no-ca-cert", "--use-system-ca", "--action-policy", "--confirm-actions",
        "--confirm-interactive", "--allowed-domains", "--idle-timeout", "--proxy-bypass", "--webgpu", "--no-webmcp", "--device",
        "--model", "--no-auto-dialog",
    ]
    /// What `state` may do here: the files named in the command (checked like any other). Listing, showing, renaming and
    /// cleaning reach the saved states of every session of agent-browser.
    static let stateActions: Set<String> = ["save", "load"]

    /// Why the command is refused, or nil.
    static func refusal(_ words: [String]) -> String? {
        guard let first = words.first?.lowercased() else { return "Give the command in `args`, like [\"get\", \"title\"]." }
        // The command line reads its options anywhere and the command is the first other word: one that starts with an option
        // could hide the real command behind it (["--debug", "connect", …]).
        if first.hasPrefix("-") { return "Start `args` with the command, like [\"get\", \"title\"]; its options come after it." }
        if let why = refusedCommands[first] { return "`\(first)` is not run here: \(why)." }
        if first == "state", !stateActions.contains(words.dropFirst().first?.lowercased() ?? "") {
            return "`state` here is only save or load (or browse_page state_save and state_load)."
        }
        for (index, word) in words.enumerated().dropFirst() {
            let flag = word.lowercased().split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if flag == "--all" { return "`--all` would reach other sessions." }
            if refusedFlags.contains(flag) {
                return "`\(flag)` is not accepted here: it would change which browser this is or how it starts."
            }
            // `--params @file` reads a file of the Mac and hands it to the page.
            if flag == "--params", index + 1 < words.count, words[index + 1].hasPrefix("@") {
                return "`--params` takes the JSON itself here, not a file (@…)."
            }
        }
        return nil
    }

    /// Why a call is risky enough to ask even in "Automático", or nil: a script that runs in every page the browser opens from
    /// now on, other conversations' tabs included, until the browser closes.
    static func danger(_ words: [String]) -> String? {
        words.first?.lowercased() == "addinitscript" ? "roda um script em toda página que o navegador do Orb abrir, até ele fechar" : nil
    }

    /// Looks at the page or the browser's records without changing anything.
    static func isSafe(_ words: [String]) -> Bool {
        guard let first = words.first?.lowercased() else { return false }
        func second() -> String? { words.dropFirst().first?.lowercased() }
        switch first {
        case "get", "is", "snapshot", "console", "errors": return true
        case "cookies": return words.count == 1 || second() == "get"
        case "network": return second() == "requests"
        default: return false
        }
    }

    enum Access { case read, write }

    /// Where in the command a file of the Mac is named, and whether it is read or written.
    static func files(_ words: [String]) -> [(index: Int, access: Access)] {
        guard let first = words.first?.lowercased() else { return [] }
        func plain(from start: Int) -> [Int] { words.indices.filter { $0 >= start && !words[$0].hasPrefix("-") } }
        var found: [(index: Int, access: Access)] = []
        let sub = words.dropFirst().first?.lowercased()
        switch first {
        case "screenshot":
            // `screenshot [selector] [path]`: a word is the path when it looks like one (a folder or a picture's name), never a selector.
            for index in plain(from: 1) where !words[index].hasPrefix("@") && !words[index].hasPrefix("#") {
                let word = words[index].lowercased()
                if word.contains("/") || [".png", ".jpg", ".jpeg", ".webp", ".pdf"].contains(where: word.hasSuffix) { found.append((index, .write)) }
            }
        case "pdf": if words.count > 1 { found.append((1, .write)) }
        case "download": if words.count > 2 { found.append((2, .write)) }
        case "upload": for index in plain(from: 2) { found.append((index, .read)) }
        case "state":
            if sub == "save", words.count > 2 { found.append((2, .write)) }
            if sub == "load", words.count > 2 { found.append((2, .read)) }
        case "record": if sub == "start", words.count > 2 { found.append((2, .write)) }
        case "trace", "profiler": if sub == "stop", words.count > 2 { found.append((2, .write)) }
        case "network", "har": if let index = words.firstIndex(where: { $0.lowercased() == "stop" }), words.contains(where: { $0.lowercased() == "har" }) || first == "har",
                                  index + 1 < words.count { found.append((index + 1, .write)) }
        default: break
        }
        for (flag, access) in [("--curl", Access.read), ("--baseline", .read), ("--output", .write), ("-o", .write)] {
            if let index = words.firstIndex(where: { $0.lowercased() == flag }), index + 1 < words.count { found.append((index + 1, access)) }
        }
        return found
    }

    /// The command with each file named by a path of its own in the folder the Orb works in, as the permission check judges it.
    static func resolved(_ words: [String], context: ToolContext) -> [String] {
        var result = words
        for (index, _) in files(words) { result[index] = context.url(for: words[index]).resolvingLinkChain.path }
        return result
    }

    /// The `args` of a call, or nil when they are not a list of words.
    static func words(_ arguments: JSONValue) -> [String]? {
        guard let list = arguments["args"]?.array else { return nil }
        let words = list.compactMap { $0.string ?? $0.number.map { number in Int(exactly: number).map(String.init) ?? String(number) } }
        return words.count == list.count ? words : nil
    }
}

/// The manual `browse_run` shows on demand: the command line's own help, so it is the one of the version the app carries.
enum BrowseRunManual {
    /// Sections of the help about what `browse_run` refuses or what the app does for the user.
    private static let hidden = ["Streaming", "MCP", "Chat", "Dashboard", "Setup", "Plugins", "Sessions", "Confirmation", "Auth Vault", "WebMCP", "iOS",
                                         "Tabs", "Batch"]

    static func overview(fromHelp help: String) -> String {
        var kept: [String] = []
        var inside = false, skipping = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !line.isEmpty, !line.hasPrefix(" ") {
                if line.hasPrefix("Core Commands") { inside = true }
                if line.hasPrefix("Snapshot Options") { inside = false }
                skipping = hidden.contains { line.hasPrefix($0) }
            }
            if inside, !skipping { kept.append(line) }
        }
        let body = kept.isEmpty ? help.clipped(to: 6_000) : kept.joined(separator: "\n")
        return """
        agent-browser commands, for browse_run `args` (["get", "text", "@e3"]). Elements are the @e12 refs of browse_snapshot. \
        browse_run with `manual` set to one command's name shows how that command works. Some commands are refused \
        (open, close, tab, batch, connect, session, and flags that change the browser itself).

        \(body)
        """
    }
}

struct BrowseRunTool: BrowseTool {
    let spec = ToolSpec(
        name: "browse_run",
        description: """
        Any other agent-browser command in your session: `args` as words, like ["get","text","@e3"], ["network","requests"] \
        or ["eval","document.title"] (elements: the @e12 refs of browse_snapshot). `manual` empty lists the commands; with a \
        command's name, explains it. Refused: open, close and tab (browse_open, browse_close, browse_tabs) and what changes the \
        browser itself.
        """,
        parameters: .schema(["args": .object(["type": .string("array"), "items": .property("string")]), "manual": .property("string")]))

    func risk(_ arguments: JSONValue) -> ToolRisk {
        if arguments["args"] == nil { return .safe }
        guard let words = BrowseRunRules.words(arguments) else { return .sensitive }
        return BrowseRunRules.isSafe(words) && BrowseRunRules.files(words).isEmpty ? .safe : .sensitive
    }

    func readsLivePage(_ arguments: JSONValue) -> Bool { risk(arguments) == .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        guard let words = BrowseRunRules.words(arguments), !words.isEmpty else { return ("Consultando o manual do navegador", arguments["manual"]?.string ?? "") }
        return ("Rodando no navegador", words.joined(separator: " ").clipped(to: 200))
    }

    /// A file named in the command is judged like the tools that read or write one: a download lands where the rules allow, an
    /// upload never takes a key or a saved password.
    func danger(_ arguments: JSONValue, context: ToolContext) -> String? {
        guard let words = BrowseRunRules.words(arguments) else { return nil }
        if let reason = BrowseRunRules.danger(words) { return reason }
        let resolved = BrowseRunRules.resolved(words, context: context)
        let sensitive = DangerousCommand.SensitiveFiles()
        for (index, access) in BrowseRunRules.files(words) {
            let url = URL(fileURLWithPath: resolved[index])
            if let reason = access == .write ? DangerousCommand.reason(forWritingTo: url) : sensitive.reason(for: url.path) { return reason }
        }
        return nil
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let session = try await BrowseSupport.session(context)
        let words = BrowseRunRules.words(arguments) ?? []
        // `skills get core` is where the manual of agent-browser is for people; its release has no skills folder, so it is this.
        if words.first?.lowercased() == "skills" || (arguments["args"] == nil && arguments["manual"] != nil) {
            let topic = arguments.nonEmptyString("manual")?.lowercased()
            return try await manual(topic, session: session)
        }
        guard arguments["args"] != nil else { throw ToolError("Give `args` (the command as words) or `manual`.") }
        guard !words.isEmpty, words.count <= 40, words.allSatisfy({ $0.count <= 8_000 }) else {
            throw ToolError("`args` is the command as a list of up to 40 words, like [\"get\",\"title\"].")
        }
        if let refusal = BrowseRunRules.refusal(words) { throw ToolError(refusal) }
        let files = BrowseRunRules.files(words)
        if !files.isEmpty, !context.canSaveFiles { throw BrowseSupport.needsFiles("A command that reads or writes a file") }
        let resolved = BrowseRunRules.resolved(words, context: context)
        for (index, access) in files {
            let url = URL(fileURLWithPath: resolved[index])
            if access == .write {
                try BrowseSupport.prepareToWrite(url)
            } else if let reason = DangerousCommand.SensitiveFiles().reason(for: url.path) {
                throw ToolError("Refused: this \(reason).")
            }
        }
        let data = try await BrowseSupport.acting { try await session.exclusive { try await session.driver.command(resolved) } }
        if !BrowseRunRules.isSafe(words) { session.pageChanged() }
        let text = data == .null ? "Done." : data.jsonString.truncated(to: 12_000)
        return "\(BrowseSupport.untrusted)\n" + text
    }

    private func manual(_ topic: String?, session: BrowserSession) async throws -> String {
        let text = try await session.driver.manual(topic)
        guard !text.isEmpty else { throw ToolError("No manual for “\(topic ?? "")”.") }
        return topic == nil ? BrowseRunManual.overview(fromHelp: text) : text.truncated(to: 8_000)
    }
}
