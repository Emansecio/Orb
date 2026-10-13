import Foundation

// One place that decides whether a tool call runs, asks or is refused: the engine turns a call into a `PermissionCall` and asks
// `PermissionPolicy.evaluate`. (The tools of a Claude Code model run through the same engine, so they are judged the same.)

// MARK: - Rules

/// What kind of thing a tool call does (`run_command`, and the old Claude Code `Bash`, are both `shell`), so a grant
/// keeps working after the Orb switches model.
enum PermissionFamily: String, CaseIterable, Codable, Sendable {
    case shell, writeFiles, web, open, appleScript, macApps, connector, memory, jobs
    /// Creating, pausing, resuming and deleting the Orb's scheduled tasks (`schedule`); listing them needs no permission.
    case schedule
    /// Clicking and typing in other apps' interface (ui_act): its own family, so an earlier grant for Shortcuts or the
    /// clipboard never extends to driving any app.
    case appInterface
    /// Clicking, typing and pressing keys in the Orb's own browser (`browse_click`, `browse_fill`, `browse_select`, `browse_press`,
    /// `browse_show`): its own family, so a grant for reading a site never lets the Orb act inside the pages it logged in to.
    case browserPage
    /// Asking and telling other Orbs (`orbs`). Never granted for good: only the turn's own grant covers it (listing needs no permission).
    case delegation
    /// Saving to a group's shared board (`group_remember`); the group's turn grants it, except for preferences.
    case groupMemory
}

/// A standing "Sempre permitir": a family of tools, narrowed by a scope.
struct PermissionRule: Codable, Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        /// Every call of the family.
        case any
        /// Shell commands that start with these words (`["git"]`, `["npm", "run"]`).
        case commandPrefix([String])
        /// Files inside this folder (absolute path).
        case folder(String)
        /// This site and its subdomains.
        case host(String)
        /// Searching the web (`web_search`), which has no site to name; never covers reading a page.
        case search
        /// One connector tool, by `PermissionPolicy.connectorKey`.
        case connectorTool(String)
    }

    var family: PermissionFamily
    var scope: Scope

    init(family: PermissionFamily, scope: Scope = .any) {
        self.family = family
        self.scope = scope
    }

    static func shell(_ words: String...) -> PermissionRule { PermissionRule(family: .shell, scope: .commandPrefix(words)) }
    static func folder(_ path: String) -> PermissionRule { PermissionRule(family: .writeFiles, scope: .folder(path)) }
    static func host(_ host: String) -> PermissionRule { PermissionRule(family: .web, scope: .host(host.lowercased())) }
    static func connector(_ name: String) -> PermissionRule {
        PermissionRule(family: .connector, scope: .connectorTool(PermissionPolicy.connectorKey(name)))
    }

    /// A scope only means something for its own family; anything else would never match.
    var isValid: Bool {
        switch scope {
        case .any: true
        case .commandPrefix(let words): family == .shell && !words.isEmpty && !words.contains(where: \.isEmpty)
        case .folder(let path): family == .writeFiles && path.hasPrefix("/") && path != "/"
        case .host(let host): family == .web && !host.isEmpty
        case .search: family == .web
        case .connectorTool(let key): family == .connector && !key.isEmpty
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decode(PermissionFamily.self, forKey: .family)
        scope = try c.decode(Scope.self, forKey: .scope)
        // A rule from a newer version, or a damaged one, is dropped by the lossy list around it: a broken scope
        // must never turn into a broader grant.
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .scope, in: c, debugDescription: "scope does not fit the family") }
    }
}

extension PermissionRule.Scope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, words, path, host, tool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "any": self = .any
        case "commandPrefix": self = .commandPrefix(try c.decode([String].self, forKey: .words))
        case "folder": self = .folder(try c.decode(String.self, forKey: .path))
        case "host": self = .host(try c.decode(String.self, forKey: .host))
        case "search": self = .search
        case "connectorTool": self = .connectorTool(try c.decode(String.self, forKey: .tool))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown scope \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any: try c.encode("any", forKey: .kind)
        case .commandPrefix(let words): try c.encode("commandPrefix", forKey: .kind); try c.encode(words, forKey: .words)
        case .folder(let path): try c.encode("folder", forKey: .kind); try c.encode(path, forKey: .path)
        case .host(let host): try c.encode("host", forKey: .kind); try c.encode(host, forKey: .host)
        case .search: try c.encode("search", forKey: .kind)
        case .connectorTool(let key): try c.encode("connectorTool", forKey: .kind); try c.encode(key, forKey: .tool)
        }
    }
}

extension PermissionRule {
    /// What the rule allows, as the list of grants shows it ("Rodar comandos git").
    var title: String {
        switch scope {
        case .any:
            switch family {
            case .shell: "Qualquer comando no Terminal"
            case .writeFiles: "Gravar em qualquer pasta"
            case .web: "Acessar qualquer site"
            case .open: "Abrir arquivos, apps e links"
            case .appleScript: "Controlar apps com AppleScript"
            case .macApps: "Usar Atalhos, a área de transferência e encerrar apps"
            case .appInterface: "Clicar e preencher campos na interface de outros apps"
            case .browserPage: "Clicar e preencher páginas no navegador do Orb"
            case .connector: "Usar qualquer ferramenta dos conectores"
            case .memory: "Guardar na memória"
            case .jobs: "Gerenciar processos em segundo plano"
            case .schedule: "Gerenciar as tarefas agendadas"
            case .delegation: "Pedir ajuda a outros Orbs"
            case .groupMemory: "Guardar no quadro do grupo"
            }
        case .commandPrefix(let words): "Rodar comandos \(words.joined(separator: " "))"
        case .folder(let path): "Gravar em \(Self.display(path))"
        case .host(let host): "Acessar \(host)"
        case .search: "Pesquisar na web"
        case .connectorTool(let key): "Usar \(Self.connectorTitle(key))"
        }
    }

    /// The same as a menu item on the approval card ("Sempre permitir comandos git").
    var menuTitle: String {
        switch scope {
        case .host(let host): return "Sempre permitir \(host)"
        case .commandPrefix(let words): return "Sempre permitir comandos \(words.joined(separator: " "))"
        case .folder(let path): return "Sempre permitir gravar em \(Self.display(path))"
        case .connectorTool, .any, .search:
            let text = title
            return "Sempre permitir " + text.prefix(1).lowercased() + text.dropFirst()
        }
    }

    fileprivate static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func connectorTitle(_ key: String) -> String {
        guard let range = key.range(of: "__") else { return key }
        return "\(key[range.upperBound...]) (\(key[..<range.lowerBound]))"
    }
}

/// The permission mode and rules as they are right now. Engines read this at every tool call (through
/// `PermissionSource`) instead of keeping a copy from the start of the turn, so changing the mode or revoking a
/// grant while the Orb works takes effect on its next action.
struct PermissionState: Sendable, Equatable {
    var mode: PermissionMode
    var rules: [PermissionRule]
}

typealias PermissionSource = @Sendable () async -> PermissionState

// MARK: - Calls

/// What a tool call is, reduced to what the policy needs.
struct PermissionCall: Sendable, Equatable {
    var toolName: String
    var family: PermissionFamily?
    var risk: ToolRisk
    /// Why this call is destructive, or nil.
    var danger: String?
    /// The shell text the call would run (`command`), parsed.
    var command: ShellCommandLine?
    /// Files the call changes, as they would really be written (relative paths resolved, symlinks followed).
    var paths: [URL] = []
    var host: String?
    /// A download that also writes a file (`web_fetch` with `save_to`).
    var savesFile = false
    /// The connector tool, by `PermissionPolicy.connectorKey`.
    var connector: String?
    /// The call only looks at the page the Orb's browser already has open (a snapshot, the page's text): it asks nothing, but
    /// "Só leitura" refuses it, as it refuses the web.
    var readsLivePage = false
}

enum PermissionVerdict: Equatable, Sendable {
    enum AskReason: Equatable, Sendable {
        case needsPermission
        /// Changes the Orb's standing instructions.
        case instructs
        case dangerous(String)

        /// The card's explanation, when the call itself is the reason to ask.
        var explanation: String? {
            if case .dangerous(let reason) = self { "Comando arriscado: \(reason)." } else { nil }
        }
    }

    case allow
    case ask(AskReason)
    case deny(String)
}

enum PermissionPolicy {
    static let readOnlyDenial = refusalPrefix + " set you to read-only mode. Explain what you would do instead."
    static let userDenial = refusalPrefix + " denied this action. Do not retry it; ask or suggest an alternative."
    /// How both refusals start: a call they answer never ran.
    static let refusalPrefix = "Not run: the user"

    // MARK: Evaluate

    /// Whether the call runs, needs the user's answer, or is refused.
    ///
    /// - "Só leitura" refuses everything that is not safe, whatever was granted.
    /// - "Sem pedir permissão" runs everything.
    /// - Otherwise destructive calls and ones that change the Orb's instructions always ask; "Automático" runs the
    ///   rest and "Perguntar antes" runs what a rule or this task's grants cover, or writes inside the Orb's own folder.
    static func evaluate(mode: PermissionMode, call: PermissionCall, rules: [PermissionRule], turnGrants: [PermissionRule] = [],
                         workspace: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PermissionVerdict {
        if call.risk == .safe { return call.readsLivePage && mode == .readOnly ? .deny(readOnlyDenial) : .allow }
        switch mode {
        case .bypass:
            return .allow
        case .readOnly:
            return .deny(readOnlyDenial)
        case .auto, .ask:
            if let danger = call.danger { return .ask(.dangerous(danger)) }
            if call.risk == .instructs { return .ask(.instructs) }
            if mode == .auto { return .allow }
            if isCovered(call, by: rules + turnGrants, ownFolder: ownFolder(workspace, home: home)) || isInsideOwnFolder(call, workspace: workspace, home: home) {
                return .allow
            }
            return .ask(.needsPermission)
        }
    }

    /// Whether the rules together allow the call. A download (`web_fetch` with `save_to`) does two things, reach the
    /// site and write a file, and needs both covered: a rule for the site alone, or "any site", never lets it write
    /// anywhere. `ownFolder` is where the Orb may write without a rule (see `ownFolder(_:home:)`).
    static func isCovered(_ call: PermissionCall, by rules: [PermissionRule], ownFolder: URL? = nil) -> Bool {
        guard let family = call.family else { return false }
        if family == .web, call.savesFile {
            var visit = call, write = call
            visit.savesFile = false
            visit.paths = []
            write.family = .writeFiles
            write.host = nil
            write.savesFile = false
            return isCovered(visit, by: rules)
                && (isCovered(write, by: rules) || (ownFolder.map { folder in !call.paths.isEmpty && call.paths.allSatisfy { isInside($0, folder: folder) } } ?? false))
        }
        let relevant = rules.filter { $0.family == family && $0.isValid }
        if relevant.contains(where: { $0.scope == .any }) { return true }
        switch family {
        case .shell:
            let prefixes: [[String]] = relevant.compactMap { if case .commandPrefix(let words) = $0.scope { words } else { nil } }
            // A rule saved before wrappers stopped being offered (`caffeinate`, `xcrun`) would cover whatever they wrap.
            return commandIsCovered(call.command, by: prefixes.filter { !($0.count == 1 && DangerousCommand.wrappers.contains($0[0])) })
        case .writeFiles:
            let folders: [URL] = relevant.compactMap { if case .folder(let path) = $0.scope { resolved(URL(fileURLWithPath: path)) } else { nil } }
            return !call.paths.isEmpty && call.paths.allSatisfy { path in folders.contains { isInside(path, folder: $0) } }
        case .web:
            if Self.isSearch(call) { return relevant.contains { $0.scope == .search } }
            guard let host = call.host else { return false }
            return relevant.contains { if case .host(let allowed) = $0.scope { hostMatches(host, allowed) } else { false } }
        case .connector:
            guard let key = call.connector else { return false }
            return relevant.contains { if case .connectorTool(let allowed) = $0.scope { allowed == key } else { false } }
        case .open, .appleScript, .macApps, .appInterface, .browserPage, .memory, .jobs, .schedule, .delegation, .groupMemory:
            return false
        }
    }

    /// Every command of the line starts with the words of some rule. Anything the words do not show (a `$( )`,
    /// backticks, a redirection into a file, a heredoc, an unclosed quote) is never covered.
    static func commandIsCovered(_ line: ShellCommandLine?, by prefixes: [[String]]) -> Bool {
        guard let line, line.isPlain, !prefixes.isEmpty else { return false }
        var covered = false
        for segment in line.segments {
            if isTransparent(segment) { continue }
            guard prefixes.contains(where: { segment.words.starts(with: $0) }) else { return false }
            covered = true
        }
        return covered
    }

    /// `cd dir` only moves; models chain it in front of the real command (`cd app && npm test`).
    private static func isTransparent(_ segment: ShellCommandLine.Segment) -> Bool {
        segment.words.first == "cd" && segment.words.count <= 2
    }

    /// The native `web_search` (as opposed to fetching a page).
    static func isSearch(_ call: PermissionCall) -> Bool {
        call.family == .web && call.toolName == "web_search"
    }

    static func hostMatches(_ host: String, _ allowed: String) -> Bool {
        let host = host.lowercased(), allowed = allowed.lowercased()
        return host == allowed || host.hasSuffix("." + allowed)
    }

    /// Writes, edits and trash moves inside the Orb's own folder need no card in "Perguntar antes".
    static func isInsideOwnFolder(_ call: PermissionCall, workspace: URL?, home: URL) -> Bool {
        guard call.family == .writeFiles, call.risk == .sensitive, !call.paths.isEmpty,
              let folder = ownFolder(workspace, home: home) else { return false }
        return call.paths.allSatisfy { isInside($0, folder: folder) }
    }

    /// The Orb's folder when it is a folder of its own. The home folder (the default when none was chosen), the
    /// root and anything that contains the home folder are not: the Orb would then write anywhere unasked.
    static func ownFolder(_ workspace: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let workspace else { return nil }
        let folder = resolved(workspace)
        guard folder.path != "/", !resolved(home).pathComponents.starts(with: folder.pathComponents) else { return nil }
        return folder
    }

    // MARK: Paths

    /// The path a write would really reach: relative parts collapsed, a link at the end followed (even a dangling
    /// one, as `write_file` does) and every existing folder on the way resolved, so `/tmp` and `/private/tmp` compare equal.
    static func resolved(_ url: URL) -> URL {
        let target = url.standardizedFileURL.resolvingLinkChain
        var existing = target
        var rest: [String] = []
        let manager = FileManager.default
        while existing.path != "/", !manager.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in rest { result.append(path: part) }
        return result.standardizedFileURL
    }

    /// Strictly inside: the folder itself is not.
    static func isInside(_ path: URL, folder: URL) -> Bool {
        let parts = path.pathComponents, base = folder.pathComponents
        return parts.count > base.count && parts.starts(with: base)
    }

    // MARK: Building calls

    /// Where the Orb works, for judging commands: only an Orb's own folder counts (see `ownFolder`).
    static func dangerScope(workspace: URL?, directory: URL?, home: URL) -> DangerousCommand.Scope? {
        guard let workspace, let folder = ownFolder(workspace, home: home) else { return nil }
        return DangerousCommand.Scope(workspace: folder, directory: directory ?? workspace)
    }

    /// A call to one of the built-in or connector tools.
    static func call(for tool: any AgentTool, arguments: JSONValue, context: ToolContext,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PermissionCall {
        let name = tool.spec.name
        let family = family(ofTool: name, kind: tool.kind)
        var call = PermissionCall(toolName: name, family: family, risk: tool.risk(arguments))
        call.readsLivePage = tool.readsLivePage(arguments)
        let directory = arguments.nonEmptyString("cwd").map(context.url(for:)) ?? context.workingDirectory
        let scope = dangerScope(workspace: context.workingDirectory, directory: directory, home: home)
        var danger = tool.danger(arguments, context: context)

        if let text = arguments["command"]?.string {
            call.command = ShellCommandLine.parse(text)
            danger = danger ?? DangerousCommand.reason(for: text, in: scope, home: home)
        } else if let script = arguments["script"]?.string {
            // No language means AppleScript (the tool's default); one it does not know is read both ways.
            let named = arguments.nonEmptyString("language")?.lowercased() ?? AppleScript.Language.applescript.rawValue
            danger = danger ?? DangerousCommand.reason(forAppleScript: script, language: AppleScript.Language(rawValue: named), in: scope, home: home)
        }
        switch family {
        case .writeFiles:
            let listed = arguments["paths"]?.array?.compactMap(\.string) ?? [arguments["path"]?.string, arguments["paths"]?.string].compactMap { $0 }
            call.paths = listed.filter { !$0.isEmpty }.map { resolved(context.url(for: $0)) }
            danger = danger ?? call.paths.lazy.compactMap { DangerousCommand.reason(forWritingTo: $0, home: home) }.first
        case .web:
            call.host = arguments["url"]?.string.flatMap(Self.host(of:))
            // A download is a write like `write_file`: judged by where it lands, so it cannot replace a startup
            // file or a key (`~/Library/LaunchAgents`, `.zshrc`, `.ssh`) any more than `write_file` can.
            if let destination = arguments.nonEmptyString("save_to") {
                call.savesFile = true
                call.paths = [resolved(context.url(for: destination))]
                danger = danger ?? call.paths.lazy.compactMap { DangerousCommand.reason(forWritingTo: $0, home: home) }.first
            }
        case .connector:
            call.connector = connectorKey(name)
        default:
            break
        }
        // Reading is harmless except for secrets: those ask like a destructive command (and are refused in read-only).
        if call.risk == .safe, let reason = secretBeingRead(toolName: name, path: arguments.nonEmptyString("path").map(context.url(for:)), home: home) {
            call.risk = .sensitive
            danger = reason
        }
        call.danger = danger
        // A line that only looks (ls, git status…) needs no card and runs even in read-only.
        if family == .shell, danger == nil, !arguments.flag("background"), let line = call.command,
           ReadOnlyCommand.isReadOnly(line, directory: directory, home: home) {
            call.risk = .safe
        }
        return call
    }

    /// Why this read of a file is a secret being read: `read_file` and `grep` of a private key, saved password or token.
    /// (A folder search withholds such files by itself, see `GrepTool`.)
    static func secretBeingRead(toolName: String, path: URL?, home: URL) -> String? {
        guard let path, ["read_file", "grep"].contains(toolName) else { return nil }
        let sensitive = DangerousCommand.SensitiveFiles(home: home)
        return sensitive.reason(for: path.standardizedFileURL.path) ?? sensitive.reason(for: resolved(path).path)
    }

    /// The family of a native tool: by name, and by kind for tools this list does not know (connectors, new tools).
    static func family(ofTool name: String, kind: ToolCall.Kind) -> PermissionFamily? {
        switch name {
        case "run_command": return .shell
        case "write_file", "edit_file", "trash": return .writeFiles
        case "web_fetch": return .web
        case "open": return .open
        case "applescript": return .appleScript
        case "shortcuts_run", "clipboard_write", "app_quit": return .macApps
        case "ui_read", "ui_act": return .appInterface
        case "browse_click", "browse_fill", "browse_select", "browse_press", "browse_show": return .browserPage
        case "remember", "recall": return .memory
        case "job_output", "job_stop": return .jobs
        case "schedule": return .schedule
        case "orbs": return .delegation
        case "group_remember", "group_recall": return .groupMemory
        default: break
        }
        switch kind {
        case .shell: return .shell
        case .file: return .writeFiles
        case .browser: return .web
        case .computer: return .macApps
        case .connector: return .connector
        case .memory: return .memory
        case .schedule: return .schedule
        case .orbs: return .delegation
        case .search: return nil
        }
    }

    /// What a connector tool does to the world outside, by the verbs in its name: `send`, `post`, `reply`, `forward`,
    /// `share`, `publish`, `comment`, `push`, `merge`, `submit`, `upload`, `notify`, `delete`, `remove`, `trash`, `archive`,
    /// `schedule`, `invite`, `transfer`. The sentence completes
    /// "o nome da ferramenta indica que ela …" on the approval card.
    private static let outwardVerbs: [String: String] = [
        "send": "envia algo", "post": "publica algo", "reply": "envia uma resposta", "forward": "encaminha mensagens",
        "share": "compartilha algo", "publish": "publica algo", "delete": "apaga algo", "remove": "remove algo",
        "trash": "joga algo no lixo", "archive": "arquiva algo", "schedule": "agenda um envio", "invite": "convida pessoas",
        "transfer": "transfere algo", "destroy": "apaga algo", "purge": "apaga algo", "comment": "publica um comentário",
        "push": "envia código para um repositório", "merge": "junta mudanças num repositório", "submit": "envia algo",
        "upload": "envia um arquivo", "notify": "avisa pessoas", "commit": "grava um commit num repositório",
    ]

    /// Why a connector tool asks even in "Automático", or nil. Two things count, for both engines: the server marks the tool
    /// destructive, or its name says it sends, publishes or deletes (`slack_send_message`, `delete_event`) and the server
    /// did not declare it read-only (`readOnlyHint` true wins: a tool that says it only reads is taken at its word).
    /// Annotations are hints and many servers leave them out, so the name is the second line.
    static func connectorDanger(toolName: String, annotations: MCPToolAnnotations) -> String? {
        if annotations.destructive == true { return "o conector marcou esta ferramenta como destrutiva" }
        if annotations.readOnly == true { return nil }
        let words = nameWords(toolName)
        for word in words {
            if let phrase = outwardVerbs[word] {
                return "o nome da ferramenta indica que ela \(phrase) (\(word)) e o conector não a marca como só leitura"
            }
        }
        // Opening a pull request publishes the branch for review (`create_pull_request`), but `create_issue` alone is a note to self.
        if words.contains("create"), words.contains("pull") {
            return "o nome da ferramenta indica que ela abre um pull request (create_pull_request) e o conector não a marca como só leitura"
        }
        // Writing a file or a branch on the service is a commit others see (`create_or_update_file`, `create_branch`).
        let wordSet = Set(words)
        if !wordSet.isDisjoint(with: ["create", "update", "write", "edit"]), !wordSet.isDisjoint(with: ["file", "files", "branch", "contents"]) {
            return "o nome da ferramenta indica que ela grava arquivos no serviço (\(toolName)) e o conector não a marca como só leitura"
        }
        return nil
    }

    /// The lowercase words of a tool name: `slack_send_message`, `sendMessage` and `gmail-send` all hold `send`.
    private static func nameWords(_ name: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in name {
            if character.isUppercase, previous?.isLowercase == true || previous?.isNumber == true { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A connector tool's identity: `GitHub__create_issue` and the old Claude Code name
    /// `mcp__github__create_issue` both become `github__create_issue`.
    static func connectorKey(_ name: String) -> String {
        var text = name.lowercased()
        if text.hasPrefix("mcp__") { text.removeFirst(5) }
        return String(text.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    static func host(of address: String) -> String? {
        guard var host = URL(string: address.trimmingCharacters(in: .whitespaces))?.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    // MARK: Suggestions

    /// Programs whose first argument is a subcommand, so "git push" is worth offering next to "git".
    private static let subcommandPrograms: Set<String> = [
        "git", "npm", "pnpm", "yarn", "brew", "docker", "swift", "cargo", "go", "pip", "pip3", "gh", "kubectl", "make",
    ]
    /// Programs that run whatever they are handed: a rule for one of them would allow everything. That includes the
    /// wrappers the danger check looks through (`caffeinate -i swift build`: a rule for `caffeinate` covers any command).
    private static let interpreters: Set<String> = DangerousCommand.wrappers.union([
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python2", "python3", "ruby", "perl", "node", "deno", "bun",
        "osascript", "xargs", "eval", "sudo", "doas", "find", "awk", "gawk", "sed", "ssh", "source", "open", "watch",
    ])

    /// Up to three standing rules that would cover this call, narrowest sensible first. Empty for calls that must
    /// always ask (destructive ones, changes to the Orb's instructions) and for anything that already runs.
    static func suggestions(for call: PermissionCall, existing: [PermissionRule] = [], workspace: URL? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [PermissionRule] {
        guard call.risk == .sensitive, call.danger == nil, let family = call.family else { return [] }
        var found: [PermissionRule] = []
        switch family {
        case .shell:
            found = commandSuggestions(call.command, existing: existing)
        case .writeFiles:
            found = call.paths.isEmpty ? [PermissionRule(family: .writeFiles)] : folderSuggestions(call.paths, home: home)
        case .web:
            // A search has no site to name; "any site" would also allow reading every page, so it gets its own rule.
            found = isSearch(call) ? [PermissionRule(family: .web, scope: .search)]
                : call.host.map { [PermissionRule.host($0)] } ?? [PermissionRule(family: .web)]
            if call.savesFile { found = [] }
        case .connector:
            found = call.connector.map { [PermissionRule(family: .connector, scope: .connectorTool($0))] } ?? []
        case .open, .appleScript, .macApps, .appInterface, .browserPage, .memory, .jobs, .schedule:
            found = [PermissionRule(family: family)]
        case .delegation, .groupMemory:
            found = [] // never "Sempre permitir": the turn's own grant covers them
        }
        return Array(unique(found).filter { !existing.contains($0) }.prefix(3))
    }

    static func unique(_ rules: [PermissionRule]) -> [PermissionRule] {
        var seen: Set<PermissionRule> = []
        return rules.filter { seen.insert($0).inserted }
    }

    private static func commandSuggestions(_ line: ShellCommandLine?, existing: [PermissionRule]) -> [PermissionRule] {
        guard let line, line.isPlain else { return [] }
        let known: [[String]] = existing.compactMap { if case .commandPrefix(let words) = $0.scope { words } else { nil } }
        let segments = line.segments.filter { !isTransparent($0) && !$0.words.isEmpty }
        let programs = segments.compactMap { segment -> String? in
            let word = segment.words[0]
            guard word.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil,
                  !interpreters.contains(word), !known.contains(where: { segment.words.starts(with: $0) }) else { return nil }
            return word
        }
        var rules: [PermissionRule] = []
        // The subcommand rule comes first: it is the narrowest, and what "Só nesta tarefa" grants.
        for segment in segments where subcommandPrograms.contains(segment.words[0]) && segment.words.count > 1 {
            let sub = segment.words[1]
            if programs.contains(segment.words[0]), sub.range(of: #"^[a-z][a-z0-9:_-]*$"#, options: .regularExpression) != nil {
                rules.append(PermissionRule(family: .shell, scope: .commandPrefix([segment.words[0], sub])))
            }
        }
        return rules + programs.map { PermissionRule(family: .shell, scope: .commandPrefix([$0])) }
    }

    /// The project folder the files belong to (the nearest one with a `.git` folder), then the folder they are in.
    private static func folderSuggestions(_ paths: [URL], home: URL) -> [PermissionRule] {
        let parents = paths.map { $0.deletingLastPathComponent() }
        guard let common = commonAncestor(parents) else { return [] }
        let homeFolder = resolved(home)
        func usable(_ url: URL) -> Bool {
            url.path != "/" && !homeFolder.pathComponents.starts(with: url.pathComponents)
        }
        var folders: [URL] = []
        var cursor = common
        for _ in 0..<8 where usable(cursor) {
            if FileManager.default.fileExists(atPath: cursor.appending(path: ".git").path) {
                folders.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }
        if usable(common) { folders.append(common) }
        return folders.map { PermissionRule.folder($0.path) }
    }

    private static func commonAncestor(_ urls: [URL]) -> URL? {
        guard var common = urls.first?.pathComponents else { return nil }
        for url in urls.dropFirst() {
            let parts = url.pathComponents
            var length = 0
            while length < min(common.count, parts.count), common[length] == parts[length] { length += 1 }
            common = Array(common.prefix(length))
        }
        return common.isEmpty ? nil : URL(fileURLWithPath: NSString.path(withComponents: common))
    }

    // MARK: Old grants

    /// What the tools of the Orb's own MCP server were called by the Claude Code CLI before it became only a pipe to the model:
    /// "Sempre permitir" choices saved then carry these names.
    static let legacyOrbToolPrefix = "mcp__orb_memoria__"

    /// The family a tool name from before scoped grants belonged to, in either engine's naming, or nil for names
    /// that no longer mean anything.
    static func legacyRule(forToolName name: String) -> PermissionRule? {
        // The Orb's own tools as the old Claude Code integration named them (`mcp__orb_memoria__applescript`) are their native twins.
        if name.hasPrefix(Self.legacyOrbToolPrefix) { return legacyRule(forToolName: String(name.dropFirst(Self.legacyOrbToolPrefix.count))) }
        switch name {
        case "run_command", "Bash": return PermissionRule(family: .shell)
        case "write_file", "edit_file", "trash", "Write", "Edit", "MultiEdit", "NotebookEdit": return PermissionRule(family: .writeFiles)
        case "web_fetch", "WebFetch", "WebSearch": return PermissionRule(family: .web)
        case "open": return PermissionRule(family: .open)
        case "applescript": return PermissionRule(family: .appleScript)
        case "shortcuts_run", "clipboard_write", "app_quit": return PermissionRule(family: .macApps)
        case "ui_act": return PermissionRule(family: .appInterface)
        case "remember": return PermissionRule(family: .memory)
        case "job_stop", "KillShell", "KillBash", "TaskStop": return PermissionRule(family: .jobs)
        default: break
        }
        // A connector tool: `server__tool` (native) or `mcp__server__tool` (Claude Code).
        guard name.hasPrefix("mcp__") || name.contains("__") else { return nil }
        let key = connectorKey(name)
        return key.contains("__") ? PermissionRule(family: .connector, scope: .connectorTool(key)) : nil
    }

    /// Rules for a set of old "Sempre permitir" tool names (sorted, so the result does not depend on set order).
    static func legacyRules(fromToolNames names: some Sequence<String>) -> [PermissionRule] {
        unique(names.sorted().compactMap(legacyRule(forToolName:)))
    }
}
