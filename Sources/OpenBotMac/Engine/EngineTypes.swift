import Foundation

// Contracts shared by the agent engine, the LLM client, the tools and MCP.

// MARK: - JSON

/// Minimal JSON value, used for tool schemas, tool arguments and MCP payloads.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    /// Truncated integer; nil for NaN or out-of-range numbers (never traps on model input).
    var int: Int? { number.flatMap { Int(exactly: $0.rounded(.towardZero)) } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }

    /// Parses JSON text; nil if invalid. Empty text parses as an empty object (models send "" for no arguments).
    static func parse(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }

    /// Compact JSON text.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Shorthand for a JSON Schema object with string-keyed properties.
    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string))])
    }

    /// Shorthand for a typed JSON Schema property.
    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}

// MARK: - Chat

/// One message of the model conversation (OpenAI chat-completions shape).
struct ChatMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant, tool }

    var role: Role
    var content: String
    /// Assistant messages: tools the model asked to call.
    var toolCalls: [ToolCallRequest] = []
    /// Tool messages: which call this result answers.
    var toolCallID: String?

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    static func tool(_ id: String, _ output: String) -> ChatMessage { ChatMessage(role: .tool, content: output, toolCallID: id) }
}

struct ToolCallRequest: Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// Raw JSON arguments as produced by the model.
    var arguments: String
}

/// A function the model may call.
struct ToolSpec: Hashable, Sendable {
    var name: String
    var description: String
    /// JSON Schema of the arguments object.
    var parameters: JSONValue
}

// MARK: - LLM client

enum LLMEvent: Sendable, Equatable {
    /// Streamed piece of assistant text.
    case text(String)
    /// Tool calls requested in this response, fully assembled (emitted once, before the stream ends).
    case toolCalls([ToolCallRequest])
}

protocol LLMClient: Sendable {
    /// Streams one assistant response. Throws `LLMError` for HTTP/protocol failures; honors task cancellation.
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error>
    /// Model ids offered by the provider.
    func models() async throws -> [String]
}

enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case http(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Nenhum provedor de modelo configurado. Abra Ajustes → Modelo."
        case .http(let status, let message): "O provedor respondeu \(status): \(message)"
        case .invalidResponse(let detail): "Resposta inválida do provedor: \(detail)"
        }
    }
}

/// OpenAI-compatible providers. All speak `POST {baseURL}/chat/completions` and `GET {baseURL}/models`.
enum ProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case xai, openai, openrouter, ollama, lmstudio, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xai: "xAI (Grok)"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .lmstudio: "LM Studio (local)"
        case .custom: "Outro compatível com OpenAI"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .xai: "https://api.x.ai/v1"
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        case .custom: ""
        }
    }

    /// Local servers and custom endpoints usually work without a key.
    var needsKey: Bool { ![.ollama, .lmstudio, .custom].contains(self) }
}

struct ProviderConfig: Codable, Hashable, Sendable {
    var preset: ProviderPreset = .xai
    var baseURL = ProviderPreset.xai.defaultBaseURL
    var defaultModel = ""
}

// MARK: - Tools

enum ToolRisk: Sendable {
    /// Reads or looks things up; runs without asking.
    case safe
    /// Changes something or runs code; asks first in "Perguntar antes", refused in "Só leitura".
    case sensitive
}

struct ToolContext: Sendable {
    /// Default directory for relative paths and commands.
    var workingDirectory: URL
    /// Saves a durable fact to the bot's memory.
    var remember: @Sendable (String) async -> Void
}

protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Icon/activity shown while it runs.
    var kind: ToolCall.Kind { get }
    /// Bot capability that must be enabled for the tool to be offered (nil = always available).
    var capability: Capability? { get }
    func risk(_ arguments: JSONValue) -> ToolRisk
    /// Human summary for the transcript and approval card, in Portuguese (title: "Rodando no Terminal", detail: the command).
    func summary(_ arguments: JSONValue) -> (title: String, detail: String)
    /// Runs the tool and returns text for the model. Throw `ToolError` for user-facing failures.
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String
}

struct ToolError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - MCP

/// A local MCP server launched over stdio.
struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var isEnabled = true
}
