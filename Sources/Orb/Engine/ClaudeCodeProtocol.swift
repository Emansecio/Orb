import Foundation

// What the Orb still needs of the Claude Code CLI's wire format (newline-delimited JSON on stdin/stdout, `--input-format
// stream-json`, `--output-format stream-json`, plus the Agent SDK control protocol): the lines `ClaudeCodeClient` writes, the
// failure text of a `result` line and the models of the plan. Shapes follow the official Agent SDK
// (anthropics/claude-agent-sdk-python, `_internal/query.py`) and https://code.claude.com/docs/en/headless.

/// What a `result` line says: whether the call failed and the text to show.
struct ClaudeCodeResult: Equatable, Sendable {
    var isError: Bool
    /// Final text, or the most informative error text (`errors[]`, then `result`, then `subtype`).
    var message: String
}

enum ClaudeCodeParser {
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
        return ClaudeCodeResult(isError: isError, message: message)
    }
}

// MARK: - Lines Orb writes

enum ClaudeCodeWire {
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
            let levels = (entry["supportedEffortLevels"]?.array ?? []).compactMap(\.string)
            return ProviderModel(id: value, name: name, format: .claudeCode, contextLength: ClaudeCodeModels.window(of: value), supportsImages: true,
                                 efforts: ReasoningEffort.levels(levels))
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

    /// The window the Orb plans a Claude Code model's history by (the CLI does not say; Claude models take 200K tokens).
    static let windowTokens = 200_000

    /// An id ending in `[1m]` is the million-token variant.
    static func window(of id: String) -> Int { id.hasSuffix("[1m]") ? 1_000_000 : windowTokens }

    /// Documented aliases (https://code.claude.com/docs/en/model-config#model-aliases), used when the CLI
    /// cannot be asked for its list.
    static let fallback: [ProviderModel] = [
        ProviderModel(id: defaultID, name: "Padrão do Claude Code", format: .claudeCode, contextLength: windowTokens, supportsImages: true),
        ProviderModel(id: "opus", name: "Opus", format: .claudeCode, contextLength: windowTokens, supportsImages: true),
        ProviderModel(id: "sonnet", name: "Sonnet", format: .claudeCode, contextLength: windowTokens, supportsImages: true),
        ProviderModel(id: "haiku", name: "Haiku", format: .claudeCode, contextLength: windowTokens, supportsImages: true),
    ]
}
