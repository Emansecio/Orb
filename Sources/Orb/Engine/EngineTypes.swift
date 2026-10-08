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
        (try? WireEncoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Shorthand for a JSON Schema object with string-keyed properties. `required` is left out when empty (an empty
    /// list is the default, and the provider is charged for every character of it in every request).
    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    /// A typed property with no description, for one the name says everything about (every word is billed per request).
    static func property(_ type: String) -> JSONValue {
        .object(["type": .string(type)])
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
    /// Assistant messages: the model's reasoning for this reply, kept so it can be sent back unchanged.
    var reasoning: ReasoningTrace?
    /// Tool messages: the call failed (an error, an unknown tool, a refusal), which providers that have the notion
    /// (Anthropic's `is_error`) are told.
    var isError = false
    /// User messages: pictures the user attached. Tool messages: pictures the tool returned. Only the paths are
    /// kept here; the bytes are read from the files when a request is built (see `ImageAttachment`).
    var images: [ImageAttachment] = []

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    static func user(_ text: String, images: [ImageAttachment] = []) -> ChatMessage {
        ChatMessage(role: .user, content: text, images: images)
    }
    static func tool(_ id: String, _ output: String, isError: Bool = false, images: [ImageAttachment] = []) -> ChatMessage {
        ChatMessage(role: .tool, content: output, toolCallID: id, isError: isError, images: images)
    }

    /// The result made up for a call a stopped turn left unanswered (see `answeringDanglingToolCalls`): the call never ran.
    static let interruptedResult = "Not run: the turn was interrupted."
}

/// A picture the model can be shown. The file is a copy under the app's data folder (`ImageStore`), already
/// downscaled; the conversation keeps this description, never the bytes.
struct ImageAttachment: Codable, Hashable, Sendable {
    var path: String
    /// "image/jpeg" or "image/png".
    var mediaType: String
    var width: Int
    var height: Int

    init(path: String, mediaType: String, width: Int, height: Int) {
        self.path = path
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        mediaType = try c.value(.mediaType, default: "image/jpeg")
        width = try c.value(.width, default: 0)
        height = try c.value(.height, default: 0)
    }
}

extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls, toolCallID, reasoning, isError, images
    }

    /// `images` is left out when there are none, so conversations without pictures are written as before.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encode(isError, forKey: .isError)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
    }

    /// Tolerant decoding (see Store.swift): conversations saved before `reasoning` existed still load, a trace this
    /// version cannot read is dropped instead of losing the message, and a message with an unknown role is skipped by
    /// the lossy list around it. A picture entry this version cannot read is skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.value(.content, default: "")
        toolCalls = try c.lossyArray(.toolCalls)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        reasoning = try? c.decodeIfPresent(ReasoningTrace.self, forKey: .reasoning)
        isError = try c.value(.isError, default: false)
        images = try c.lossyArray(.images)
    }
}

/// The reasoning a model produced for one reply, as the provider that made it needs it back: Anthropic thinking
/// blocks (with their signatures) and Responses encrypted reasoning items. It only means something to the same
/// wire format, endpoint and model, so those travel with it.
struct ReasoningTrace: Codable, Hashable, Sendable {
    var format: APIFormat
    /// Host of the endpoint that produced it (a signature or encrypted blob is not valid anywhere else).
    var provider: String
    var model: String
    var parts: [ReasoningPart]

    /// Whether the parts may be sent in a request to this format, endpoint and model.
    func isReusable(format: APIFormat, provider: String, model: String) -> Bool {
        self.format == format && self.provider == provider && self.model == model && !parts.isEmpty
    }
}

struct ReasoningPart: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Anthropic `thinking` block: readable text plus a signature.
        case thinking
        /// Anthropic `redacted_thinking` block: opaque `data` only.
        case redactedThinking
        /// Responses `reasoning` item: `data` is its `encrypted_content`, `text` the readable summary.
        case encrypted
    }

    var kind: Kind
    var text: String = ""
    var signature: String?
    var data: String?
    /// Responses `reasoning` item id (the API requires it on the item when it is sent back).
    var id: String?
    /// Responses: how many of the reply's function calls came before this item, so it goes back right before the
    /// call it produced. nil (older traces) counts as 0.
    var callsBefore: Int?

    init(kind: Kind, text: String = "", signature: String? = nil, data: String? = nil, id: String? = nil,
         callsBefore: Int? = nil) {
        self.kind = kind
        self.text = text
        self.signature = signature
        self.data = data
        self.id = id
        self.callsBefore = callsBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.value(.text, default: "")
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        data = try c.decodeIfPresent(String.self, forKey: .data)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        callsBefore = try? c.decodeIfPresent(Int.self, forKey: .callsBefore)
    }
}

extension [ChatMessage] {
    /// Gives every assistant tool call a result. A stopped turn leaves calls unanswered, which providers reject.
    func answeringDanglingToolCalls() -> [ChatMessage] {
        var result: [ChatMessage] = []
        var open: [String] = []
        func close() {
            result += open.map { ChatMessage.tool($0, ChatMessage.interruptedResult) }
            open = []
        }
        for message in self {
            if message.role == .tool, let id = message.toolCallID {
                open.removeAll { $0 == id }
            } else {
                close()
            }
            result.append(message)
            if message.role == .assistant { open = message.toolCalls.map(\.id) }
        }
        close()
        return result
    }
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

/// Why a response ended.
enum StopReason: Sendable, Equatable {
    /// The model finished its answer.
    case done
    /// The model stopped to call tools.
    case toolUse
    /// Cut off by the output limit.
    case maxTokens
    /// The model (or the provider's filter) declined to answer.
    case refusal
    /// The prompt did not fit the model's context window.
    case contextExceeded
    /// Ended early for another reason (paused, or the stream closed before a normal ending).
    case incomplete
    /// A reason this version does not know, as the provider wrote it.
    case unknown(String)
}

/// Tokens a response used. `input` counts only prompt tokens that were not served from or written to the cache
/// (providers report them differently; the clients normalize), so the whole prompt is `input + cacheRead + cacheWrite`.
struct TokenUsage: Sendable, Equatable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?

    /// Adds another response's counts (a count nobody reported stays unknown).
    mutating func add(_ other: TokenUsage) {
        func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        input = sum(input, other.input)
        output = sum(output, other.output)
        cacheRead = sum(cacheRead, other.cacheRead)
        cacheWrite = sum(cacheWrite, other.cacheWrite)
    }

    /// The whole prompt: what was read from the cache, written to it and charged in full. nil when no count is known.
    var promptTokens: Int? {
        guard input != nil || cacheRead != nil || cacheWrite != nil else { return nil }
        return (input ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }

    /// Whether the provider says anything about its cache. Servers that have none (or do not report it) leave both
    /// counts out; one that has a cache and missed reports 0.
    var reportsCache: Bool { cacheRead != nil || cacheWrite != nil }

    /// The share of the prompt served from the cache, 0...1 (nil without a cache report or a prompt). On a sum over
    /// the requests of a turn the first one is always a miss, so a turn of several steps works when this is high.
    var cacheHitRatio: Double? {
        guard reportsCache, let prompt = promptTokens, prompt > 0 else { return nil }
        return Double(cacheRead ?? 0) / Double(prompt)
    }
}

/// Whether the provider's prompt cache is doing its job, judged on what a turn used. A request whose prefix is not
/// byte-identical to the one before (an unsorted key, a timestamp in the prompt, a tool list that moves) is charged
/// in full every time and nothing else says so; this is what makes it visible.
enum CacheHealth {
    /// Model calls of a turn needed before judging: the first one is a miss by nature.
    static let minimumRequests = 3
    /// Below this the provider would not cache anyway (OpenAI starts at 1,024 tokens, Anthropic at 1,024 to 4,096).
    static let minimumPromptTokens = 4_096
    /// A turn whose prompts were read from the cache less than this is not caching.
    static let healthyRatio = 0.2

    static let notice = "O provedor não está reaproveitando o início das conversas (cache), o que deixa cada passo mais caro. "
        + "Se continuar, confira o modelo e o provedor em Ajustes → Modelos."

    /// `total` is the turn's usage summed over `requests` model calls.
    static func isFailing(_ total: TokenUsage, requests: Int) -> Bool {
        guard requests >= minimumRequests, let ratio = total.cacheHitRatio, let prompt = total.promptTokens,
              prompt / requests >= minimumPromptTokens else { return false }
        return ratio < healthyRatio
    }

    /// One line per request for the developer log (`ORB_DEBUG_USAGE=1`): "step 3: prompt 8120, cache 7900 (97%), out 45".
    static func logLine(step: Int, usage: TokenUsage) -> String {
        var line = "step \(step): prompt \(usage.promptTokens.map(String.init) ?? "?")"
        if let ratio = usage.cacheHitRatio {
            line += ", cache read \(usage.cacheRead ?? 0) write \(usage.cacheWrite ?? 0) (\(Int((ratio * 100).rounded()))%)"
        } else {
            line += ", cache not reported"
        }
        return line + ", out \(usage.output.map(String.init) ?? "?")"
    }

    static var logsUsage: Bool { ProcessInfo.processInfo.environment["ORB_DEBUG_USAGE"] != nil }
}

/// Whether the model may call tools in a response. `.none` keeps the tool list (and so the provider's cache) but
/// makes the model answer in text, which is how the last step of a turn gets its summary.
enum ToolChoice: Sendable, Equatable {
    case auto
    case none
}

enum LLMEvent: Sendable, Equatable {
    /// Streamed piece of assistant text.
    case text(String)
    /// The model's reasoning for this response, to be kept on the assistant message (emitted once, before the tool calls).
    case reasoning(ReasoningTrace)
    /// Tool calls requested in this response, fully assembled (emitted once, before the stream ends).
    case toolCalls([ToolCallRequest])
    /// How the response ended and what it cost; the last event of every stream.
    case finished(StopReason, TokenUsage?)
}

protocol LLMClient: Sendable {
    /// Streams one assistant response. Throws `LLMError` for HTTP/protocol failures; honors task cancellation.
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error>
    /// Whether this client arranges the provider's prompt cache (a marker, a key, or a provider that caches by
    /// itself), so a miss is the app's concern. A client that sends nothing for it (chat completions to a gateway
    /// that wants explicit markers) must not be blamed by `CacheHealth`.
    var arrangesPromptCache: Bool { get }
}

extension LLMClient {
    var arrangesPromptCache: Bool { false }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        stream(model: model, messages: messages, tools: tools, toolChoice: .auto)
    }
}

/// Supplies the key or token for one request. `forceRefresh` asks for a new one after the provider rejected the
/// last (sign-in tokens expire; API keys come back unchanged).
typealias CredentialsProvider = @Sendable (_ forceRefresh: Bool) async throws -> String?

enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case http(status: Int, message: String, retryAfter: TimeInterval? = nil)
    /// The prompt is larger than the model's context window (HTTP 400 or an in-stream error).
    case contextExceeded(String)
    /// An error event inside an otherwise successful stream (Anthropic `overloaded_error`, `api_error`…).
    case stream(type: String, message: String)
    /// The connection failed (`URLError` code raw value).
    case network(code: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Nenhum modelo configurado. Abra Ajustes → Modelos."
        case .http(let status, let message, let retryAfter):
            Self.describe(status: status, message: message) + Self.waitNote(retryAfter)
        case .contextExceeded(let message): "A conversa ficou grande demais para este modelo. Detalhe do provedor: \(message)"
        case .stream(let type, let message):
            if Self.rateLimitTypes.contains(type) { Self.describe(status: 429, message: message) }
            else if Self.retryableStreamErrors.contains(type) { Self.describe(status: 503, message: message) }
            else { "O provedor devolveu um erro (\(type)): \(message)" }
        case .network(_, let message): "Sem conexão com o provedor: \(message)"
        case .invalidResponse(let detail): "Resposta inválida do provedor: \(detail)"
        }
    }

    /// Seconds the provider asked us to wait (`Retry-After`), when it did.
    var retryAfter: TimeInterval? {
        if case .http(_, _, let seconds) = self { seconds } else { nil }
    }

    /// Whether trying the same request again can succeed: rate limits, overload, timeouts, dropped connections.
    var isRetryable: Bool {
        switch self {
        // A 429 about money (OpenAI's `insufficient_quota`) is not a busy provider: waiting does not pay the bill.
        case .http(let status, let message, _): Self.retryableStatuses.contains(status) && !(status == 429 && Self.isAboutMoney(message, status: 429))
        case .stream(let type, _): Self.retryableStreamErrors.contains(type)
        case .network(let code, _): Self.retryableNetworkCodes.contains(URLError.Code(rawValue: code))
        case .notConfigured, .contextExceeded, .invalidResponse: false
        }
    }

    /// Whether the provider turned down the key or login itself (401/403), not the model, the plan or the balance.
    var isCredentialRefusal: Bool {
        guard case .http(let status, let message, _) = self, status == 401 || status == 403 else { return false }
        let lowered = message.lowercased()
        return !Self.isAboutMoney(message, status: status) && !Self.isModelRefused(lowered) && !lowered.contains("upgrade_required")
    }

    static let retryableStatuses: Set<Int> = [408, 409, 429, 500, 502, 503, 504, 529]
    static let retryableStreamErrors: Set<String> = ["overloaded_error", "api_error", "rate_limit_error", "server_error", "rate_limit_exceeded"]
    static let retryableNetworkCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet]

    private static let rateLimitTypes: Set<String> = ["rate_limit_error", "rate_limit_exceeded"]

    /// " O provedor pediu para aguardar 5 min." when the wait is long enough to matter (a long one is not retried).
    private static func waitNote(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 1 else { return "" }
        let wait = seconds >= 120 ? "\(Int((seconds / 60).rounded(.up))) min" : "\(Int(seconds.rounded(.up))) s"
        return " O provedor pediu para aguardar \(wait)."
    }

    private static func describe(status: Int, message: String) -> String {
        let lowered = message.lowercased()
        let isAboutMoney = Self.isAboutMoney(message, status: status)
        return switch status {
        case 403 where lowered.contains("upgrade_required"):
            // Command Code: the Go plan is the only one without API access.
            "O seu plano não inclui acesso à API (403). Na Command Code só o plano Go não tem: troque para Provider, GOAT, Pro, Max ou Team. Detalhe do provedor: \(message)"
        case 401 where isModelRefused(lowered), 403 where isModelRefused(lowered):
            // OpenCode: a model the workspace turned off, the gateway does not serve, that needs a data-use
            // opt-in (Muse Spark Contributor, DeepSeek in the Go plan) or that is closed to the country.
            "O provedor recusou este modelo (\(status)), mas a chave está certa. Ele pode estar desativado no espaço de trabalho da OpenCode, exigir aceite de uso de dados no console da OpenCode ou não estar liberado no seu país. Escolha outro modelo ou confira o console. Detalhe do provedor: \(message)"
        case 401 where isAboutMoney, 403 where isAboutMoney:
            // OpenCode answers a missing balance or a spent monthly limit with 401, which is not a bad key.
            "Sem saldo ou limite de gasto liberado no provedor (\(status)). Confira o saldo e o plano no console do provedor. Detalhe do provedor: \(message)"
        case 429 where isAboutMoney:
            // OpenAI answers an account without credit with 429 `insufficient_quota`; waiting does not help.
            "Sem saldo ou limite de gasto liberado no provedor (429). Confira o saldo e o plano no console do provedor. Detalhe do provedor: \(message)"
        case 401, 403: "Chave ou login inválido (\(status)). Confira em Ajustes → Modelos. Detalhe do provedor: \(message)"
        case 402: "O provedor pede pagamento ou mais saldo (402). Confira seu plano. Detalhe do provedor: \(message)"
        case 429: "Você atingiu o limite de uso do provedor (429); espere um pouco ou confira seu plano. Detalhe do provedor: \(message)"
        case 500...599: "O provedor está sobrecarregado ou instável (\(status)); tente de novo em instantes. Detalhe do provedor: \(message)"
        default: "O provedor respondeu \(status): \(message)"
        }
    }

    /// 401/403 bodies that say the model, not the credentials, was refused (OpenCode's `ModelError`, `DataPolicyError`
    /// and `RegionError`). Checked on the lowercased message.
    private static func isModelRefused(_ lowered: String) -> Bool {
        ["is disabled", "is not supported", "requires explicit opt in", "not available in your country"]
            .contains { lowered.contains($0) }
    }

    /// Words of a 401/403 body that say money or a spending cap, not credentials, is the problem.
    private static let billingHints = ["insufficient balance", "insufficient_quota", "exceeded your current quota", "no payment method",
                                       "billing", "monthly limit", "spend limit", "spending limit", "usage exceeded"]

    /// The narrower list for a 429. A per-minute rate limit often mentions billing too (OpenAI on an account without a
    /// card: "add a payment method at .../billing"; Gemini: "exceeded your current quota, check your plan and billing
    /// details" with a retry delay of seconds), and waiting is the cure there; only a spent balance or cap is not.
    private static let billingHintsFor429 = ["insufficient_quota", "insufficient balance", "spend limit", "spending limit", "monthly limit"]

    private static func isAboutMoney(_ message: String, status: Int) -> Bool {
        let lowered = message.lowercased()
        return (status == 429 ? billingHintsFor429 : billingHints).contains { lowered.contains($0) }
    }

    /// Whether an HTTP 400 message says the prompt did not fit (providers word it differently).
    static func isContextOverflow(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["context_length_exceeded", "context length", "context window", "prompt is too long", "prompt too long",
                "input is too long", "maximum context"].contains { text.contains($0) }
    }

    /// A transport failure as `.network`; cancellation and everything else pass through untouched.
    static func wrapping(_ error: Error) -> Error {
        guard let urlError = error as? URLError, urlError.code != .cancelled else { return error }
        return LLMError.network(code: urlError.code.rawValue, message: urlError.localizedDescription)
    }
}

// MARK: - Tools

enum ToolRisk: Sendable {
    /// Reads or looks things up; runs without asking.
    case safe
    /// Changes something or runs code; asks first in "Perguntar antes", refused in "Só leitura".
    case sensitive
    /// Changes the Orb's standing instructions (its identity and your preferences, in every future prompt): asks in
    /// "Perguntar antes" and "Automático", even after "Sempre permitir"; only "Sem pedir permissão" skips the card.
    case instructs
}

struct ToolContext: Sendable {
    /// Default directory for relative paths and commands.
    var workingDirectory: URL
    /// The Orb's own memory (remember/recall); nil where there is none (some tests).
    var memory: MemoryBank?
    /// The Orb running the tool; owns the background jobs it starts. Nil where there is no Orb (some tests).
    var botID: UUID?
    /// Background jobs of every Orb (one per app); nil where the app does not offer them.
    var jobs: BackgroundJobs?
    /// The user's Terminal environment that commands run in.
    var shell: ShellEnvironment = .shared
    /// Where pictures a tool returns are saved (nil: tools return text only).
    var imageStore: ImageStore?
    /// The model may be shown pictures, so a tool that can return one should.
    var acceptsImages = false
    /// Where saved tool outputs go (`saidas/<orb id>/` in the app's data folder); nil uses the temporary folder.
    var outputsDirectory: URL?
    /// The tool may write files outside the Orb's own work (a download with `save_to`): the Orb has "Terminal e arquivos".
    var canSaveFiles = true
    /// The Orb has "Controlar apps do Mac". Tools that are always offered (`open`) use it to refuse what only that switch allows.
    var computerUseAllowed = true
}

protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Icon/activity shown while it runs.
    var kind: ToolCall.Kind { get }
    /// Bot capability that must be enabled for the tool to be offered (nil = always available).
    var capability: Capability? { get }
    /// Another capability that also offers the tool (`trash` needs files or apps, whichever the Orb has).
    var alsoWithCapability: Capability? { get }
    func risk(_ arguments: JSONValue) -> ToolRisk
    /// Why this particular call is destructive (so "Automático" still asks), or nil. Shell text in `command` or
    /// `script` is checked separately by `DangerousCommand`; this is for tools whose danger is in other arguments.
    func danger(_ arguments: JSONValue) -> String?
    /// Same, for tools whose danger depends on the disk or the working directory (`open` on an executable file);
    /// defaults to `danger(_:)`.
    func danger(_ arguments: JSONValue, context: ToolContext) -> String?
    /// Human summary for the transcript and approval card, in Portuguese (title: "Rodando no Terminal", detail: the command).
    func summary(_ arguments: JSONValue) -> (title: String, detail: String)
    /// Same, for tools whose summary needs the working directory (to resolve a relative path); defaults to `summary(_:)`.
    func summary(_ arguments: JSONValue, context: ToolContext) -> (title: String, detail: String)
    /// Runs the tool and returns text for the model. Throw `ToolError` for user-facing failures.
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String
    /// Same, for tools that can also hand the model a picture. The engine calls this one.
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult
}

/// What a tool gives back: the text, and pictures the model may look at.
struct ToolResult: Sendable {
    var text: String
    var images: [ImageAttachment] = []
}

extension AgentTool {
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        ToolResult(text: try await run(arguments, context: context))
    }

    func summary(_ arguments: JSONValue, context: ToolContext) -> (title: String, detail: String) { summary(arguments) }
    func danger(_ arguments: JSONValue) -> String? { nil }
    var alsoWithCapability: Capability? { nil }

    /// Whether an Orb with these capabilities is offered the tool.
    func isOffered(for capabilities: Set<Capability>) -> Bool {
        guard let required = capability else { return true }
        return capabilities.contains(required) || alsoWithCapability.map(capabilities.contains) == true
    }

    func danger(_ arguments: JSONValue, context: ToolContext) -> String? { danger(arguments) }
}

struct ToolError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - MCP

/// An MCP server: local (launched over stdio) or remote (HTTP).
struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Local server: executable and arguments, run through the user's login shell.
    var command = ""
    var arguments: [String] = []
    var environment: [String: String] = [:]
    /// Remote server: Streamable HTTP endpoint (or legacy SSE). When set, `command` is ignored.
    var url = ""
    var headers: [String: String] = [:]
    var isEnabled = true
    /// Registry name when installed from the catalog (e.g. "io.github.owner/server").
    var source: String?
    /// The Orbs that may use this connector; nil means every Orb (what connectors did before they were scoped).
    var orbIDs: Set<UUID>?
    /// Names of environment variables or headers that hold secrets (kept in the Keychain, see `ConnectorSecrets`),
    /// besides the ones whose name gives them away.
    var secretKeys: Set<String> = []

    var isRemote: Bool { !url.isEmpty }
}

extension MCPServerConfig {
    /// Tolerant decoding: configs saved by older versions lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.decode(String.self, forKey: .name)
        command = try c.value(.command, default: "")
        arguments = try c.value(.arguments, default: [])
        environment = try c.value(.environment, default: [:])
        url = try c.value(.url, default: "")
        headers = try c.value(.headers, default: [:])
        isEnabled = try c.value(.isEnabled, default: true)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        orbIDs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .orbIDs)) ?? nil
        secretKeys = (try? c.decodeIfPresent(Set<String>.self, forKey: .secretKeys)) ?? []
    }
}
