import Foundation

// Claude Code's headless wire format: newline-delimited JSON on stdin/stdout (`--input-format stream-json`,
// `--output-format stream-json`) plus the Agent SDK control protocol for permission prompts.
// Shapes follow the official Agent SDK (anthropics/claude-agent-sdk-python, `_internal/query.py`,
// `_internal/client.py`, `_internal/message_parser.py`) and https://code.claude.com/docs/en/headless.

/// One stdout line from Claude Code, reduced to what Orb shows. Subagent traffic is skipped.
enum ClaudeCodeMessage: Equatable, Sendable {
    /// `system/init`: the session this run writes to.
    case started(sessionID: String)
    /// Assistant text: a streamed delta, or a whole block that was never streamed (e.g. an API error notice).
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, output: String, isError: Bool)
    /// API failure reported on an assistant message (`error`, e.g. "authentication_failed").
    case apiError(String)
    /// `control_request` / `can_use_tool`.
    case permission(ClaudeCodePermissionRequest)
    /// Any other control request (hooks, SDK MCP); answered with an error so the CLI never waits on us.
    case unsupportedRequest(requestID: String, subtype: String)
    /// The answer to one of our control requests; `error` is the CLI's text when it refused (nil = success).
    case controlResponse(requestID: String, error: String?)
    case result(ClaudeCodeResult)
    /// `system/compact_boundary`: Claude Code compacted its own session (`trigger` "auto" or "manual"; the token
    /// counts are its estimates of the context before and after, when it reports them).
    case compacted(trigger: String, preTokens: Int?, postTokens: Int?)
}

struct ClaudeCodePermissionRequest: Equatable, Sendable {
    var requestID: String
    var toolName: String
    var input: JSONValue
    var toolUseID: String?
    /// Standing rules Claude Code suggests for this request (`permission_suggestions`), as far as Orb has an
    /// equivalent: command prefixes, sites, folders and connector tools.
    var suggestions: [PermissionRule] = []
}

struct ClaudeCodeResult: Equatable, Sendable {
    var isError: Bool
    /// Final text, or the most informative error text (`errors[]`, then `result`, then `subtype`).
    var message: String
    var sessionID: String?
    /// What the whole turn used (every model call in it added up), when the CLI reports it.
    var usage: TokenUsage?
    /// What the turn cost at API prices (`total_cost_usd`); on a subscription this is an estimate, not a charge.
    var costUSD: Double?
}

/// Turns stdout lines into `ClaudeCodeMessage`s. Remembers which assistant messages were streamed so their
/// final copy is not shown twice.
struct ClaudeCodeParser {
    private var currentMessageID: String?
    private var streamed: Set<String> = []

    mutating func parse(_ line: String) -> [ClaudeCodeMessage] {
        guard let json = JSONValue.parse(line), let type = json["type"]?.string else { return [] }
        // Messages of subagents carry the id of the tool call that started them.
        if let parent = json["parent_tool_use_id"], parent != .null { return [] }
        switch type {
        case "system":
            switch json["subtype"]?.string {
            case "init":
                guard let id = json["session_id"]?.string else { return [] }
                return [.started(sessionID: id)]
            case "compact_boundary":
                let details = json["compact_metadata"]
                return [.compacted(trigger: details?["trigger"]?.string ?? "auto", preTokens: details?["pre_tokens"]?.int,
                                   postTokens: details?["post_tokens"]?.int)]
            default:
                return []
            }
        case "stream_event":
            return streamEvent(json["event"])
        case "assistant":
            return assistant(json)
        case "user":
            return (json["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
                return .toolResult(id: id, output: Self.flatten(block["content"]), isError: block["is_error"]?.bool ?? false)
            }
        case "control_request":
            return controlRequest(json)
        case "control_response":
            guard let id = json["response"]?["request_id"]?.string else { return [] }
            let failed = json["response"]?["subtype"]?.string == "error"
            let reason = json["response"]?["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return [.controlResponse(requestID: id, error: failed ? reason ?? "erro desconhecido" : nil)]
        case "result":
            return [.result(Self.result(json))]
        default:
            return []
        }
    }

    private mutating func streamEvent(_ event: JSONValue?) -> [ClaudeCodeMessage] {
        switch event?["type"]?.string {
        case "message_start":
            currentMessageID = event?["message"]?["id"]?.string
            return []
        case "content_block_delta":
            guard event?["delta"]?["type"]?.string == "text_delta", let text = event?["delta"]?["text"]?.string else { return [] }
            if let id = currentMessageID { streamed.insert(id) }
            return [.text(text)]
        default:
            return []
        }
    }

    private func assistant(_ json: JSONValue) -> [ClaudeCodeMessage] {
        if let error = json["error"]?.string { return [.apiError(error)] }
        let wasStreamed = json["message"]?["id"]?.string.map(streamed.contains) ?? false
        return (json["message"]?["content"]?.array ?? []).compactMap { block in
            switch block["type"]?.string {
            case "text":
                guard !wasStreamed, let text = block["text"]?.string else { return nil }
                return .text(text)
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
                return .toolUse(id: id, name: name, input: block["input"] ?? .object([:]))
            default:
                return nil
            }
        }
    }

    private func controlRequest(_ json: JSONValue) -> [ClaudeCodeMessage] {
        guard let id = json["request_id"]?.string, let request = json["request"] else { return [] }
        let subtype = request["subtype"]?.string ?? ""
        guard subtype == "can_use_tool", let tool = request["tool_name"]?.string else {
            return [.unsupportedRequest(requestID: id, subtype: subtype)]
        }
        return [.permission(ClaudeCodePermissionRequest(requestID: id, toolName: tool, input: request["input"] ?? .object([:]),
                                                         toolUseID: request["tool_use_id"]?.string,
                                                         suggestions: Self.rules(fromSuggestions: request["permission_suggestions"])))]
    }

    /// `permission_suggestions` are Claude Code's own permission updates: `addRules` (`toolName` + `ruleContent`
    /// such as `git status:*` or `domain:github.com`), `addDirectories`, `setMode`… Only the "allow" ones that
    /// map to an Orb rule are kept; anything else is ignored.
    static func rules(fromSuggestions suggestions: JSONValue?) -> [PermissionRule] {
        var rules: [PermissionRule] = []
        for update in suggestions?.array ?? [] {
            switch update["type"]?.string {
            case "addRules" where update["behavior"]?.string == "allow":
                for rule in update["rules"]?.array ?? [] {
                    guard let tool = rule["toolName"]?.string else { continue }
                    let content = rule["ruleContent"]?.string ?? ""
                    switch tool {
                    case "Bash":
                        // `git status:*` and `git status *` are prefix rules; a bare command is one exact command.
                        let prefix = content.hasSuffix(":*") ? String(content.dropLast(2)) : content.hasSuffix(" *") ? String(content.dropLast(2)) : ""
                        let words = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
                        if !words.isEmpty { rules.append(PermissionRule(family: .shell, scope: .commandPrefix(words))) }
                    case "WebFetch":
                        if content.hasPrefix("domain:"), content.count > 7 { rules.append(.host(String(content.dropFirst(7)))) }
                    case let name where name.hasPrefix("mcp__") && content.isEmpty:
                        rules.append(.connector(name))
                    default:
                        break
                    }
                }
            case "addDirectories":
                for directory in update["directories"]?.array?.compactMap(\.string) ?? [] where directory.hasPrefix("/") && directory != "/" {
                    rules.append(.folder(directory))
                }
            default:
                break
            }
        }
        return rules.filter(\.isValid)
    }

    /// Mirrors the SDK's `_error_result_text`: `errors[]`, then `result`, then a non-success `subtype`.
    static func result(_ json: JSONValue) -> ClaudeCodeResult {
        let isError = json["is_error"]?.bool ?? false
        let text = json["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var message = text
        if isError {
            let errors = (json["errors"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            let subtype = json["subtype"]?.string.flatMap { $0 == "success" ? nil : $0 }
            message = errors.isEmpty ? (text.isEmpty ? subtype ?? "erro desconhecido" : text) : errors.joined(separator: "; ")
        }
        return ClaudeCodeResult(isError: isError, message: message, sessionID: json["session_id"]?.string,
                                usage: usage(in: json["usage"]), costUSD: json["total_cost_usd"]?.number)
    }

    /// Anthropic's counting, like `TokenUsage` itself: `input_tokens` leaves out what the cache served or stored.
    static func usage(in usage: JSONValue?) -> TokenUsage? {
        guard let usage, case .object = usage else { return nil }
        let result = TokenUsage(input: usage["input_tokens"]?.int, output: usage["output_tokens"]?.int,
                                cacheRead: usage["cache_read_input_tokens"]?.int,
                                cacheWrite: usage["cache_creation_input_tokens"]?.int)
        return result == TokenUsage() ? nil : result
    }

    /// Tool result content is a string or a list of content blocks.
    static func flatten(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text): text
        case .array(let blocks): blocks.map { $0["text"]?.string ?? ($0["type"]?.string == "image" ? "[imagem]" : "") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        default: ""
        }
    }
}

// MARK: - Lines Orb writes

enum ClaudeCodeWire {
    /// `{"type":"user","session_id":"","message":{"role":"user","content":…},"parent_tool_use_id":null}` (SDK client.py).
    static func userMessage(_ text: String) -> String {
        JSONValue.object(["type": .string("user"), "session_id": .string(""), "parent_tool_use_id": .null,
                          "message": .object(["role": .string("user"), "content": .string(text)])]).jsonString
    }

    /// `set_permission_mode`: switches the running session's `--permission-mode` (SDK `set_permission_mode`).
    static func setPermissionMode(id: String, mode: String) -> String {
        JSONValue.object(["type": .string("control_request"), "request_id": .string(id),
                          "request": .object(["subtype": .string("set_permission_mode"), "mode": .string(mode)])]).jsonString
    }

    /// `initialize` (sent first, before any user message) or `interrupt`.
    static func controlRequest(id: String, subtype: String) -> String {
        var request: [String: JSONValue] = ["subtype": .string(subtype)]
        if subtype == "initialize" { request["hooks"] = .null }
        return JSONValue.object(["type": .string("control_request"), "request_id": .string(id),
                                 "request": .object(request)]).jsonString
    }

    /// Answer to `can_use_tool`: allow (echoing the input as `updatedInput`) or deny with a message for Claude.
    static func permissionResponse(requestID: String, answer: ClaudeCodePermissionAnswer, input: JSONValue) -> String {
        let body: JSONValue = switch answer {
        case .allow: .object(["behavior": .string("allow"), "updatedInput": input])
        case .deny(let message): .object(["behavior": .string("deny"), "message": .string(message)])
        }
        return JSONValue.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string(requestID), "response": body,
        ])]).jsonString
    }

    static func errorResponse(requestID: String, message: String) -> String {
        JSONValue.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("error"), "request_id": .string(requestID), "error": .string(message),
        ])]).jsonString
    }

    /// Request ids in the SDK's style (`req_<n>_<hex>`).
    static func newRequestID() -> String {
        "req_1_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Models from the `initialize` response (`response.response.models[]`: `value`, `displayName`); nil if
    /// `line` is not the answer to `requestID`. "default" keeps Claude Code's own choice.
    static func models(fromInitializeResponse line: String, requestID: String) -> [ProviderModel]? {
        guard let json = JSONValue.parse(line), json["type"]?.string == "control_response",
              json["response"]?["request_id"]?.string == requestID else { return nil }
        return (json["response"]?["response"]?["models"]?.array ?? []).compactMap { entry in
            guard let value = entry["value"]?.string, !value.isEmpty else { return nil }
            let name = value == ClaudeCodeModels.defaultID ? "Padrão do Claude Code" : entry["displayName"]?.string ?? value
            return ProviderModel(id: value, name: name, format: .claudeCode)
        }
    }
}

enum ClaudeCodePermissionAnswer: Equatable, Sendable {
    case allow
    case deny(String)
}

// MARK: - Models

enum ClaudeCodeModels {
    /// Not passed to `--model`, so the user's own Claude Code setting (or their plan's default) applies.
    static let defaultID = "default"

    /// Documented aliases (https://code.claude.com/docs/en/model-config#model-aliases), used when the CLI
    /// cannot be asked for its list.
    static let fallback: [ProviderModel] = [
        ProviderModel(id: defaultID, name: "Padrão do Claude Code", format: .claudeCode),
        ProviderModel(id: "opus", name: "Opus", format: .claudeCode),
        ProviderModel(id: "sonnet", name: "Sonnet", format: .claudeCode),
        ProviderModel(id: "haiku", name: "Haiku", format: .claudeCode),
    ]
}

// MARK: - Tools and permissions

enum ClaudeCodeTools {
    /// Tools of the Orb's own MCP server: memory (`mcp__orb_memoria__remember`, `__recall`) and, for an Orb with
    /// "Controlar apps do Mac", the Mac tools (`mcp__orb_memoria__open`, `__applescript`…). The server keeps its first name.
    static let memoryPrefix = "mcp__\(OrbToolsMCPServer.name)__"
    /// Removed when the bot's "Terminal e arquivos" capability is off: the shell, everything that changes files, and the
    /// tools that look through them or manage shell jobs, as the native engine offers none of these then. `Read` stays,
    /// because Claude Code opens the pictures the user attaches with it.
    static let terminal = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS", "NotebookRead",
                           "BashOutput", "TaskOutput", "KillShell", "KillBash", "TaskStop"]
    /// Reads of private keys and saved passwords, refused outright in every mode but "Sem pedir permissão". The CLI trusts
    /// the whole home folder (`--add-dir`) and so would never ask the Orb about these reads (the native engine asks, see
    /// `PermissionPolicy.secretBeingRead`).
    static let secretReads = [
        "Read(~/.ssh/**)", "Read(~/.gnupg/**)", "Read(~/.aws/**)", "Read(~/.kube/**)", "Read(~/.config/gcloud/**)",
        "Read(~/Library/Keychains/**)", "Read(~/.netrc)", "Read(~/.npmrc)", "Read(~/.config/gh/hosts.yml)", "Read(~/.docker/config.json)",
    ]
    /// Removed when "Navegar na web" is off.
    static let web = ["WebFetch", "WebSearch"]
    /// The CLI's multiple-choice question to the user. The Orb has no card to answer it with (the SDK's host sends the
    /// choices back as `answers`), so the tool is removed in every mode and the model asks in text instead.
    static let askUserQuestion = "AskUserQuestion"

    static func kind(_ name: String) -> ToolCall.Kind {
        switch name {
        case "Bash": .shell
        case "Read", "LS", "Edit", "Write", "MultiEdit", "NotebookEdit", "NotebookRead": .file
        case "Glob", "Grep": .search
        case "WebFetch", "WebSearch": .browser
        default:
            if name.hasPrefix(memoryPrefix) { OrbToolsMCPServer.tool(claudeCodeName: name)?.kind ?? .memory }
            else { name.hasPrefix("mcp__") ? .connector : .computer }
        }
    }

    /// The file a Write, Edit or MultiEdit changes, when it names one by its full path.
    static func writtenPath(_ name: String, _ input: JSONValue) -> String? {
        guard ["Write", "Edit", "MultiEdit"].contains(name), let path = input["file_path"]?.string, path.hasPrefix("/") else { return nil }
        return path
    }

    /// Transcript and approval-card text, in Portuguese.
    static func summary(_ name: String, _ input: JSONValue) -> (title: String, detail: String) {
        // The Orb's own tools (memory, Mac) describe their calls themselves, as they do outside Claude Code.
        if let tool = OrbToolsMCPServer.tool(claudeCodeName: name) { return tool.summary(input) }
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string ?? ""
        switch name {
        case "Bash": return ("Rodando no Terminal", input["command"]?.string ?? "")
        case "Read": return ("Lendo arquivo", path)
        case "LS": return ("Listando pasta", path)
        case "Edit", "MultiEdit", "NotebookEdit": return ("Editando arquivo", path)
        case "Write": return ("Gravando arquivo", path)
        case "Glob", "Grep": return ("Procurando arquivos", input["pattern"]?.string ?? "")
        case "WebFetch": return ("Lendo página", input["url"]?.string ?? "")
        case "WebSearch": return ("Pesquisando na web", input["query"]?.string ?? "")
        case "NotebookRead": return ("Lendo caderno", path)
        case "TodoWrite":
            // The step under way, not the whole list as JSON.
            let todos = input["todos"]?.array ?? []
            let current = todos.first { $0["status"]?.string == "in_progress" }
            return ("Atualizando a lista de tarefas", current?["activeForm"]?.string ?? current?["content"]?.string ?? "")
        case "Task", "Agent": return ("Delegando a um subagente", input["description"]?.string ?? "")
        case "ExitPlanMode": return ("Apresentando o plano", String((input["plan"]?.string ?? "").prefix(300)))
        case "Skill": return ("Usando uma habilidade", input["skill"]?.string ?? input["command"]?.string ?? "")
        default:
            let arguments = input == .object([:]) ? "" : " " + input.jsonString
            if name.hasPrefix("mcp__") {
                // mcp__<server>__<tool>
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let tool = parts.dropFirst().joined(separator: "__")
                return ("Usando \(parts[0])", String((tool + arguments).prefix(300)))
            }
            return ("Usando \(name)", String(arguments.dropFirst().prefix(300)))
        }
    }
}

enum ClaudeCodePolicy {
    /// `--permission-mode` for a bot. Read-only plans (edits reach us and are denied). "Perguntar antes" and
    /// "Automático" both run the CLI in `default`: nothing it considers risky is approved by the CLI itself, every
    /// such request reaches the Orb as `can_use_tool`, and `PermissionPolicy.evaluate` decides (ask, or in
    /// "Automático" allow unless dangerous or it changes the Orb's instructions, exactly like the native engine).
    /// `acceptEdits` would let the CLI approve file edits without the Orb's checks (`~/.zshrc`, `~/.ssh`,
    /// LaunchAgents…). "Sem pedir permissão" is Claude Code's own `bypassPermissions`.
    static func cliMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .readOnly: "plan"
        case .ask, .auto: "default"
        case .bypass: "bypassPermissions"
        }
    }

    static let readOnlyDenial = PermissionPolicy.readOnlyDenial
    static let userDenial = "The user denied this action. Do not retry it; ask or suggest an alternative."
    /// For an `AskUserQuestion` call that reaches us anyway (an older CLI may not know the name to remove).
    static let questionDenial = "This app cannot show interactive questions. Ask the question as plain text in your reply and end the turn."

    /// The answer when no one needs to be asked; nil means show an approval card. The decision is
    /// `PermissionPolicy`'s, the same as for the built-in tools.
    static func answer(mode: PermissionMode, toolName: String, input: JSONValue = .null, rules: [PermissionRule] = [],
                       turnGrants: [PermissionRule] = [], workspace: URL? = nil) -> ClaudeCodePermissionAnswer? {
        let call = PermissionPolicy.call(claudeCodeTool: toolName, input: input, workspace: workspace)
        let verdict = PermissionPolicy.evaluate(mode: mode, call: call, rules: rules,
                                                turnGrants: turnGrants, workspace: workspace)
        switch verdict {
        case .allow: return .allow
        case .deny(let message): return .deny(message)
        case .ask: return nil
        }
    }
}
