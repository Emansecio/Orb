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
    case controlResponse(requestID: String, isError: Bool)
    case result(ClaudeCodeResult)
}

struct ClaudeCodePermissionRequest: Equatable, Sendable {
    var requestID: String
    var toolName: String
    var input: JSONValue
    var toolUseID: String?
    /// Claude Code's own explanation, when it sends one.
    var reason: String?
}

struct ClaudeCodeResult: Equatable, Sendable {
    var isError: Bool
    /// Final text, or the most informative error text (`errors[]`, then `result`, then `subtype`).
    var message: String
    var sessionID: String?
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
            guard json["subtype"]?.string == "init", let id = json["session_id"]?.string else { return [] }
            return [.started(sessionID: id)]
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
            return [.controlResponse(requestID: id, isError: json["response"]?["subtype"]?.string == "error")]
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
        let reason = [request["decision_reason"], request["description"], request["title"]]
            .compactMap { $0?.string }.first { !$0.isEmpty }
        return [.permission(ClaudeCodePermissionRequest(requestID: id, toolName: tool, input: request["input"] ?? .object([:]),
                                                         toolUseID: request["tool_use_id"]?.string, reason: reason))]
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
        return ClaudeCodeResult(isError: isError, message: message, sessionID: json["session_id"]?.string)
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
    /// Tools of the Orb's memory server (`mcp__memoria__remember`, `mcp__memoria__recall`).
    static let memoryPrefix = "mcp__\(MemoryMCPServer.name)__"
    /// Removed when the bot's "Terminal e arquivos" capability is off.
    static let terminal = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// Removed when "Ler páginas da web" is off.
    static let web = ["WebFetch", "WebSearch"]

    static func kind(_ name: String) -> ToolCall.Kind {
        switch name {
        case "Bash": .shell
        case "Read", "LS", "Edit", "Write", "MultiEdit", "NotebookEdit": .file
        case "Glob", "Grep": .search
        case "WebFetch", "WebSearch": .browser
        default: name.hasPrefix(memoryPrefix) ? .memory : name.hasPrefix("mcp__") ? .connector : .computer
        }
    }

    /// Transcript and approval-card text, in Portuguese.
    static func summary(_ name: String, _ input: JSONValue) -> (title: String, detail: String) {
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
        case memoryPrefix + "remember", memoryPrefix + "recall":
            return MemoryMCPServer.tools.first { memoryPrefix + $0.spec.name == name }?.summary(input) ?? ("Usando a memória", "")
        default:
            let arguments = input == .object([:]) ? "" : " " + input.jsonString
            if name.hasPrefix("mcp__") {
                // mcp__<server>__<tool>
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let tool = parts.dropFirst().joined(separator: "__")
                return ("Usando \(parts[0])", String((tool + arguments).prefix(300)))
            }
            return (name, String(arguments.dropFirst().prefix(300)))
        }
    }
}

enum ClaudeCodePolicy {
    /// `--permission-mode` for a bot: read-only plans (edits reach us and are denied), "ask" uses the default
    /// mode (unapproved tools reach us as approval cards), automatic accepts edits and we allow the rest except
    /// destructive commands, and "sem pedir permissão" is Claude Code's own `bypassPermissions`.
    static func cliMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .readOnly: "plan"
        case .ask: "default"
        case .auto: "acceptEdits"
        case .bypass: "bypassPermissions"
        }
    }

    static let readOnlyDenial = "Not run: the user set you to read-only mode. Explain what you would do instead."
    static let userDenial = "The user denied this action. Do not retry it; ask or suggest an alternative."

    /// The answer when no one needs to be asked; nil means show an approval card. Destructive shell commands
    /// always ask in "Perguntar antes" and "Automático", even for tools marked "Sempre permitir".
    static func answer(mode: PermissionMode, toolName: String, input: JSONValue = .null,
                       allowed: Set<String>) -> ClaudeCodePermissionAnswer? {
        // Searching the Orb's own memory only reads it, like `recall` outside Claude Code.
        if toolName == ClaudeCodeTools.memoryPrefix + "recall" { return .allow }
        // Saving identity or preferences changes the Orb's standing instructions: ask unless "Sem pedir permissão".
        if toolName == ClaudeCodeTools.memoryPrefix + "remember",
           RememberTool().risk(input) == .instructs, mode == .ask || mode == .auto { return nil }
        let isDangerous = input["command"]?.string.flatMap(DangerousCommand.reason) != nil
        switch mode {
        case .readOnly: return .deny(readOnlyDenial)
        case .bypass: return .allow
        case .auto: return isDangerous ? nil : .allow
        case .ask: return allowed.contains(toolName) && !isDangerous ? .allow : nil
        }
    }
}
