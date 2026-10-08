import Foundation

// Model providers: who they are, how to authenticate, how to list their models live,
// and which wire format (chat completions, Responses, Anthropic Messages) each model speaks.

enum APIFormat: String, Codable, Sendable {
    case chat, responses, messages
    /// Not an HTTP API: the turn runs through the local Claude Code CLI (`ClaudeCodeEngine`).
    case claudeCode
}

/// One model offered by a provider, as fetched from its live catalog.
struct ProviderModel: Codable, Hashable, Identifiable, Sendable {
    /// The id sent on the wire.
    var id: String
    var name: String
    var format: APIFormat
    var contextLength: Int?
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatgpt, claudeCode, openai, anthropic, opencodeZen, opencodeGo, commandCode, xai, openrouter, ollama, lmstudio, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatgpt: "ChatGPT (sua assinatura)"
        case .claudeCode: "Claude Code (sua assinatura)"
        case .openai: "OpenAI (chave de API)"
        case .anthropic: "Claude (chave de API)"
        case .opencodeZen: "OpenCode Zen"
        case .opencodeGo: "OpenCode Go"
        case .commandCode: "Command Code"
        case .xai: "xAI (Grok)"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .lmstudio: "LM Studio (local)"
        case .custom: "Gateway próprio"
        }
    }

    var summary: String {
        switch self {
        case .chatgpt: "Entre com sua conta ChatGPT Plus ou Pro e use o limite do seu plano."
        case .claudeCode: "Usa o Claude Code instalado no seu Mac, com o login da própria Anthropic (Pro ou Max). O app só abre o Claude Code; nunca vê nem guarda a sua sessão."
        case .openai: "Modelos GPT pela API da OpenAI, cobrados por uso."
        case .anthropic: "Modelos Claude pela API da Anthropic, cobrados por uso."
        case .opencodeZen: "Gateway da OpenCode com modelos selecionados para agentes, cobrado por uso."
        case .opencodeGo: "Assinatura da OpenCode com modelos abertos (GLM, Kimi, DeepSeek…)."
        case .commandCode: "API de modelos da Command Code (plano com acesso à API)."
        case .xai: "Modelos Grok pela API da xAI."
        case .openrouter: "Centenas de modelos com uma chave só."
        case .ollama: "Modelos rodando no seu Mac com o Ollama."
        case .lmstudio: "Modelos rodando no seu Mac com o LM Studio."
        case .custom: "Qualquer gateway compatível (OpenAI, Responses ou Anthropic Messages). Útil para apontar o motor do app para um servidor seu."
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .chatgpt, .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .opencodeZen: "https://opencode.ai/zen/v1"
        case .opencodeGo: "https://opencode.ai/zen/go/v1"
        case .commandCode: "https://api.commandcode.ai/provider/v1"
        case .xai: "https://api.x.ai/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        case .claudeCode, .custom: ""
        }
    }

    /// Where the user creates a key (nil: no key, or signs in instead).
    var keyPage: URL? {
        switch self {
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .opencodeZen, .opencodeGo: URL(string: "https://opencode.ai/auth")
        case .commandCode: URL(string: "https://commandcode.ai/settings/keys")
        case .xai: URL(string: "https://console.x.ai")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .chatgpt, .claudeCode, .ollama, .lmstudio, .custom: nil
        }
    }

    var usesSignIn: Bool { self == .chatgpt || self == .claudeCode }
    var needsKey: Bool { ![.chatgpt, .claudeCode, .ollama, .lmstudio, .custom].contains(self) }
    var hasEditableURL: Bool { [.ollama, .lmstudio, .custom].contains(self) }
}

/// A provider the user set up. Keys and sign-in tokens live in the Keychain, not here.
struct ProviderAccount: Codable, Hashable, Identifiable, Sendable {
    var kind: ProviderKind
    var baseURL: String
    var isEnabled = true
    var models: [ProviderModel] = []
    var modelsUpdatedAt: Date?
    /// Custom provider only: the wire format its gateway speaks, and any extra request headers it needs.
    var format: APIFormat = .chat
    var headers: [String: String] = [:]

    var id: ProviderKind { kind }

    init(kind: ProviderKind) {
        self.kind = kind
        baseURL = kind.defaultBaseURL
    }

    /// Tolerant: accounts saved before `format`/`headers` existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.value(.baseURL, default: kind.defaultBaseURL)
        isEnabled = try c.value(.isEnabled, default: true)
        models = try c.value(.models, default: [])
        modelsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .modelsUpdatedAt)
        format = try c.value(.format, default: .chat)
        headers = try c.value(.headers, default: [:])
    }
}

/// "kind/modelId" as stored on bots (model ids may themselves contain slashes).
struct ModelRef: Hashable, Sendable {
    var provider: ProviderKind
    var model: String

    init(provider: ProviderKind, model: String) {
        self.provider = provider
        self.model = model
    }

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = ProviderKind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(provider: provider, model: parts[1])
    }

    var text: String { "\(provider.rawValue)/\(model)" }
}

// MARK: - Live catalogs

enum ModelCatalog {
    /// Fetches the provider's current models with their wire format.
    /// `token` is the API key or, for ChatGPT, the access token.
    static func fetch(_ account: ProviderAccount, token: String?, session: URLSession = .shared) async throws -> [ProviderModel] {
        if account.kind == .claudeCode { return try await ClaudeCode.shared.models() }
        guard let base = URL(string: account.baseURL), base.host != nil else { throw LLMError.notConfigured }
        switch account.kind {
        case .chatgpt:
            return chatGPTModels(try await getJSON(base.appending(path: "models"), token: token, session: session))
        case .anthropic:
            return try await AnthropicClient(baseURL: base, apiKey: token, session: session).models()
                .map { ProviderModel(id: $0, name: $0, format: .messages) }
        case .openai:
            return openAIModels(try await OpenAIClient(baseURL: base, apiKey: token, session: session).models())
        case .commandCode:
            return commandCodeModels(try await getJSON(base.appending(path: "models"), token: nil, session: session))
        case .opencodeZen, .opencodeGo:
            // The gateway lists what is live; models.dev (what OpenCode itself uses) says which format each one needs.
            async let live = OpenAIClient(baseURL: base, apiKey: nil, session: session).models()
            async let metadata = getJSON(modelsDevURL, token: nil, session: session)
            let key = account.kind == .opencodeZen ? "opencode" : "opencode-go"
            return openCodeModels(live: try await live, metadata: (try? await metadata)?[key]?["models"])
        case .custom:
            // The gateway speaks one chosen format; list via the matching endpoint, with the user's headers.
            let ids = account.format == .messages
                ? try await AnthropicClient(baseURL: base, apiKey: token, extraHeaders: account.headers, session: session).models()
                : try await OpenAIClient(baseURL: base, apiKey: token, extraHeaders: account.headers, session: session).models()
            return ids.map { ProviderModel(id: $0, name: $0, format: account.format) }
        case .claudeCode, .xai, .openrouter, .ollama, .lmstudio:
            return try await OpenAIClient(baseURL: base, apiKey: token, session: session).models()
                .map { ProviderModel(id: $0, name: $0, format: .chat) }
        }
    }

    static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    /// Sign in with ChatGPT: `models[]` with `slug`, `display_name`, `visibility` (show only "list"), server order kept.
    static func chatGPTModels(_ json: JSONValue) -> [ProviderModel] {
        (json["models"]?.array ?? []).compactMap { entry in
            guard entry["visibility"]?.string == "list", let slug = entry["slug"]?.string else { return nil }
            return ProviderModel(id: slug, name: entry["display_name"]?.string ?? slug, format: .responses)
        }
    }

    /// The API also lists embeddings, audio, image and moderation models; keep the ones that chat.
    static func openAIModels(_ ids: [String]) -> [ProviderModel] {
        let excluded = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "audio", "realtime", "moderation",
                        "search", "davinci", "babbage", "sora", "computer-use"]
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o") || id.hasPrefix("chatgpt") || id.contains("codex"))
                && !excluded.contains { id.contains($0) }
        }
        .map { ProviderModel(id: $0, name: $0, format: .responses) }
    }

    /// `supported_endpoints` says what each model speaks; chat completions is preferred when offered.
    static func commandCodeModels(_ json: JSONValue) -> [ProviderModel] {
        (json["data"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string else { return nil }
            let endpoints = entry["supported_endpoints"]?.array?.compactMap(\.string) ?? ["/chat/completions"]
            let format: APIFormat
            if endpoints.contains("/chat/completions") { format = .chat }
            else if endpoints.contains("/messages") { format = .messages }
            else if endpoints.contains("/responses") { format = .responses }
            else { return nil }
            return ProviderModel(id: id, name: entry["name"]?.string ?? id, format: format,
                                 contextLength: entry["context_length"]?.int)
        }
    }

    /// Live ids filtered and typed with models.dev: `provider.npm` @ai-sdk/anthropic → Messages, @ai-sdk/openai →
    /// Responses, absent → chat; Google-format, deprecated, tool-less and free (OpenCode-only) models are left out.
    static func openCodeModels(live: [String], metadata: JSONValue?) -> [ProviderModel] {
        live.compactMap { id in
            guard let info = metadata?[id] else { return nil }
            guard info["status"]?.string != "deprecated", info["tool_call"]?.bool != false else { return nil }
            let cost = info["cost"]
            if cost?["input"]?.number == 0 && cost?["output"]?.number == 0 { return nil }
            let format: APIFormat
            switch info["provider"]?["npm"]?.string {
            case nil, "@ai-sdk/openai-compatible": format = .chat
            case "@ai-sdk/anthropic": format = .messages
            case "@ai-sdk/openai": format = .responses
            default: return nil
            }
            return ProviderModel(id: id, name: info["name"]?.string ?? id, format: format,
                                 contextLength: info["limit"]?["context"]?.int)
        }
    }

    private static func getJSON(_ url: URL, token: String?, session: URLSession) async throws -> JSONValue {
        let (data, response) = try await session.data(for: OpenAIClient.authorizedRequest(url, apiKey: token))
        try await OpenAIClient.check(response, body: { data.prefix(OpenAIClient.errorBodyLimit) })
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw LLMError.invalidResponse("lista de modelos ilegível")
        }
        return json
    }
}

// MARK: - Clients

extension ProviderAccount {
    /// The client for one model: the format decides the wire protocol; OpenCode also wants a stable session id,
    /// and the OpenAI-style formats key their prompt cache to the conversation.
    func client(for model: ProviderModel?, credentials: @escaping CredentialsProvider, conversationID: String) -> (any LLMClient)? {
        guard let base = URL(string: baseURL), base.host != nil else { return nil }
        var headers = kind == .custom ? self.headers : [:]
        if kind == .opencodeZen || kind == .opencodeGo { headers["x-opencode-session"] = conversationID }
        switch model?.format ?? .chat {
        case .chat:
            return OpenAIClient(baseURL: base, credentials: credentials, extraHeaders: headers, conversationID: conversationID)
        case .messages:
            return AnthropicClient(baseURL: base, credentials: credentials, extraHeaders: headers)
        case .responses:
            // Sign in with ChatGPT takes tools as an `additional_tools` input item, not top-level `tools`.
            return ResponsesClient(baseURL: base, credentials: credentials, extraHeaders: headers,
                                   toolsAsInputItem: kind == .chatgpt, conversationID: conversationID)
        case .claudeCode:
            return nil
        }
    }
}
