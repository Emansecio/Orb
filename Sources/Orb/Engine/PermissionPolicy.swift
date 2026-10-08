import Foundation

// One place that decides whether a tool call runs, asks or is refused. Both engines (the native tool loop and
// Claude Code) turn a call into a `PermissionCall` and ask `PermissionPolicy.evaluate`, so they cannot drift.

// MARK: - Rules

/// What kind of thing a tool call does, the same for both engines (`run_command` and Claude Code's `Bash` are
/// both `shell`), so a grant keeps working after the Orb switches model.
enum PermissionFamily: String, CaseIterable, Codable, Sendable {
    case shell, writeFiles, web, open, appleScript, macApps, connector, memory, jobs
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
            case .connector: "Usar qualquer ferramenta dos conectores"
            case .memory: "Guardar na memória"
            case .jobs: "Gerenciar processos em segundo plano"
            }
        case .commandPrefix(let words): "Rodar comandos \(words.joined(separator: " "))"
        case .folder(let path): "Gravar em \(Self.display(path))"
        case .host(let host): "Acessar \(host)"
        case .connectorTool(let key): "Usar \(Self.connectorTitle(key))"
        }
    }

    /// The same as a menu item on the approval card ("Sempre permitir comandos git").
    var menuTitle: String {
        switch scope {
        case .host(let host): return "Sempre permitir \(host)"
        case .commandPrefix(let words): return "Sempre permitir comandos \(words.joined(separator: " "))"
        case .folder(let path): return "Sempre permitir gravar em \(Self.display(path))"
        case .connectorTool, .any:
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
    static let readOnlyDenial = "Not run: the user set you to read-only mode. Explain what you would do instead."
    static let userDenial = "Not run: the user denied this action. Do not retry it; ask or suggest an alternative."

    // MARK: Evaluate

    /// Whether the call runs, needs the user's answer, or is refused.
    ///
    /// - "Só leitura" refuses everything that is not safe, whatever was granted.
    /// - "Sem pedir permissão" runs everything.
    /// - Otherwise destructive calls and ones that change the Orb's instructions always ask; "Automático" runs the
    ///   rest and "Perguntar antes" runs what a rule or this task's grants cover, or writes inside the Orb's own folder.
    static func evaluate(mode: PermissionMode, call: PermissionCall, rules: [PermissionRule], turnGrants: [PermissionRule] = [],
                         workspace: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PermissionVerdict {
        if call.risk == .safe { return .allow }
        switch mode {
        case .bypass:
            return .allow
        case .readOnly:
            return .deny(readOnlyDenial)
        case .auto, .ask:
            if let danger = call.danger { return .ask(.dangerous(danger)) }
            if call.risk == .instructs { return .ask(.instructs) }
            if mode == .auto { return .allow }
            if isCovered(call, by: rules + turnGrants) || isInsideOwnFolder(call, workspace: workspace, home: home) { return .allow }
            return .ask(.needsPermission)
        }
    }

    /// Whether the rules together allow the call.
    static func isCovered(_ call: PermissionCall, by rules: [PermissionRule]) -> Bool {
        guard let family = call.family else { return false }
        let relevant = rules.filter { $0.family == family && $0.isValid }
        if relevant.contains(where: { $0.scope == .any }) { return true }
        switch family {
        case .shell:
            let prefixes: [[String]] = relevant.compactMap { if case .commandPrefix(let words) = $0.scope { words } else { nil } }
            return commandIsCovered(call.command, by: prefixes)
        case .writeFiles:
            let folders: [URL] = relevant.compactMap { if case .folder(let path) = $0.scope { resolved(URL(fileURLWithPath: path)) } else { nil } }
            return !call.paths.isEmpty && call.paths.allSatisfy { path in folders.contains { isInside(path, folder: $0) } }
        case .web:
            guard let host = call.host, !call.savesFile else { return false }
            return relevant.contains { if case .host(let allowed) = $0.scope { hostMatches(host, allowed) } else { false } }
        case .connector:
            guard let key = call.connector else { return false }
            return relevant.contains { if case .connectorTool(let allowed) = $0.scope { allowed == key } else { false } }
        case .open, .appleScript, .macApps, .memory, .jobs:
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
        let directory = arguments.nonEmptyString("cwd").map(context.url(for:)) ?? context.workingDirectory
        let scope = dangerScope(workspace: context.workingDirectory, directory: directory, home: home)
        var danger = tool.danger(arguments)

        if let text = arguments["command"]?.string {
            call.command = ShellCommandLine.parse(text)
            danger = danger ?? DangerousCommand.reason(for: text, in: scope, home: home)
        } else if let script = arguments["script"]?.string {
            danger = danger ?? DangerousCommand.reason(forAppleScript: script, in: scope, home: home)
        }
        switch family {
        case .writeFiles:
            let listed = arguments["paths"]?.array?.compactMap(\.string) ?? [arguments["path"]?.string, arguments["paths"]?.string].compactMap { $0 }
            call.paths = listed.filter { !$0.isEmpty }.map { resolved(context.url(for: $0)) }
            danger = danger ?? call.paths.lazy.compactMap { DangerousCommand.reason(forWritingTo: $0, home: home) }.first
        case .web:
            call.host = arguments["url"]?.string.flatMap(Self.host(of:))
            call.savesFile = arguments.nonEmptyString("save_to") != nil
        case .connector:
            call.connector = connectorKey(name)
        default:
            break
        }
        call.danger = danger
        return call
    }

    /// A tool call from Claude Code (`Bash`, `Write`, `mcp__server__tool`…).
    static func call(claudeCodeTool name: String, input: JSONValue, workspace: URL?,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PermissionCall {
        // The Orb's own tools (memory, Mac) are judged exactly like their native twins: risk, `danger` (a forced
        // quit, AppleScript's `do shell script`, standing instructions) and families.
        if let tool = OrbToolsMCPServer.tool(claudeCodeName: name) {
            var call = call(for: tool, arguments: input, context: ToolContext(workingDirectory: workspace ?? home), home: home)
            call.toolName = name
            return call
        }
        let base = workspace ?? home
        func path(_ key: String) -> URL? {
            guard let text = input[key]?.string, !text.isEmpty else { return nil }
            let expanded = (text as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appending(path: expanded)
        }
        func risk(_ name: String) -> ToolRisk {
            switch name {
            case "Read", "LS", "Glob", "Grep", "NotebookRead", "BashOutput":
                .safe
            default:
                .sensitive
            }
        }
        var call = PermissionCall(toolName: name, family: nil, risk: risk(name))
        let scope = dangerScope(workspace: workspace, directory: workspace, home: home)
        switch name {
        case "Bash":
            call.family = .shell
            if let text = input["command"]?.string {
                call.command = ShellCommandLine.parse(text)
                call.danger = DangerousCommand.reason(for: text, in: scope, home: home)
            }
        case "BashOutput", "KillShell", "KillBash":
            call.family = .jobs
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            call.family = .writeFiles
            call.paths = [path("file_path") ?? path("notebook_path")].compactMap { $0 }.map(resolved)
            call.danger = call.paths.lazy.compactMap { DangerousCommand.reason(forWritingTo: $0, home: home) }.first
        case "WebFetch":
            call.family = .web
            call.host = input["url"]?.string.flatMap(Self.host(of:))
        case "WebSearch":
            call.family = .web
        case let name where name.hasPrefix("mcp__"):
            call.family = .connector
            call.connector = connectorKey(name)
        default:
            break
        }
        return call
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
        case "remember", "recall": return .memory
        case "job_output", "job_list", "job_stop": return .jobs
        default: break
        }
        switch kind {
        case .shell: return .shell
        case .file: return .writeFiles
        case .browser: return .web
        case .computer: return .macApps
        case .connector: return .connector
        case .memory: return .memory
        case .search: return nil
        }
    }

    /// A connector tool's identity, the same whichever engine names it: `GitHub__create_issue` (native) and
    /// `mcp__github__create_issue` (Claude Code) both become `github__create_issue`.
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
    /// Programs that run whatever they are handed: a rule for one of them would allow everything.
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python2", "python3", "ruby", "perl", "node", "deno", "bun",
        "osascript", "env", "xargs", "eval", "exec", "sudo", "doas", "nohup", "time", "command", "find", "awk", "gawk", "sed",
        "ssh", "source", "open",
    ]

    /// Up to three standing rules that would cover this call, narrowest sensible first. Empty for calls that must
    /// always ask (destructive ones, changes to the Orb's instructions) and for anything that already runs.
    static func suggestions(for call: PermissionCall, existing: [PermissionRule] = [], workspace: URL? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser, extra: [PermissionRule] = []) -> [PermissionRule] {
        guard call.risk == .sensitive, call.danger == nil, let family = call.family else { return [] }
        var found: [PermissionRule] = []
        switch family {
        case .shell:
            found = commandSuggestions(call.command, existing: existing)
        case .writeFiles:
            found = call.paths.isEmpty ? [PermissionRule(family: .writeFiles)] : folderSuggestions(call.paths, home: home)
        case .web:
            found = call.host.map { [PermissionRule.host($0)] } ?? [PermissionRule(family: .web)]
            if call.savesFile { found = [] }
        case .connector:
            found = call.connector.map { [PermissionRule(family: .connector, scope: .connectorTool($0))] } ?? []
        case .open, .appleScript, .macApps, .memory, .jobs:
            found = [PermissionRule(family: family)]
        }
        // Suggestions from Claude Code come after Orb's own, and only where they fit the call's family.
        // A rule for an interpreter (`Bash(python3:*)`) would allow everything, so those are not offered either.
        found += extra.filter { rule in
            guard rule.family == family, rule.isValid else { return false }
            if case .commandPrefix(let words) = rule.scope {
                guard let program = words.first else { return false }
                return !interpreters.contains(program)
                    && program.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil
            }
            return true
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

    /// The family a tool name from before scoped grants belonged to, in either engine's naming, or nil for names
    /// that no longer mean anything.
    static func legacyRule(forToolName name: String) -> PermissionRule? {
        // The Orb's own tools as Claude Code names them (`mcp__orb_memoria__applescript`) are their native twins.
        if name.hasPrefix(ClaudeCodeTools.memoryPrefix) { return legacyRule(forToolName: String(name.dropFirst(ClaudeCodeTools.memoryPrefix.count))) }
        switch name {
        case "run_command", "Bash": return PermissionRule(family: .shell)
        case "write_file", "edit_file", "trash", "Write", "Edit", "MultiEdit", "NotebookEdit": return PermissionRule(family: .writeFiles)
        case "web_fetch", "WebFetch", "WebSearch": return PermissionRule(family: .web)
        case "open": return PermissionRule(family: .open)
        case "applescript": return PermissionRule(family: .appleScript)
        case "shortcuts_run", "clipboard_write", "app_quit": return PermissionRule(family: .macApps)
        case "remember": return PermissionRule(family: .memory)
        case "job_stop", "KillShell", "KillBash": return PermissionRule(family: .jobs)
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
