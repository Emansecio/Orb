import Foundation

// Model providers: who they are, how to authenticate, how to list their models live,
// and which wire format (chat completions, Responses, Anthropic Messages) each model speaks.

enum APIFormat: String, Codable, Sendable {
    case chat, responses, messages
    /// Not an HTTP API: the turn runs through the local Claude Code CLI (`ClaudeCodeEngine`).
    case claudeCode

    /// A format from a newer build reads as chat completions (and the file is kept, see `DecodeLoss`).
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .chat) }
}

/// One model offered by a provider, as fetched from its live catalog.
struct ProviderModel: Codable, Hashable, Identifiable, Sendable {
    /// The id sent on the wire.
    var id: String
    var name: String
    var format: APIFormat
    var contextLength: Int?
    /// Whether the model takes pictures, as its catalog says (nil: the catalog does not say).
    var supportsImages: Bool?
    /// What the provider's own list charges for it, when the list says (OpenRouter, models.dev for OpenCode).
    var price: ModelPrice?
    /// Set on a model the user typed in by hand (custom gateway): a refreshed list keeps it even when the gateway's
    /// own list does not name it. Optional so data from before this field decodes unchanged.
    var isManual: Bool?
    /// What a million input tokens cost, from `price` (only used to avoid picking a dearer model for a background note,
    /// see `ChunkSummarizer.model`).
    var inputPrice: Double? { price?.input }
}

extension ProviderModel {
    /// A model whose format this build doesn't speak can't be used here: it is left out of the list (which the
    /// provider's live catalog refills) instead of being called in the wrong format.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guard let known = APIFormat(rawValue: try c.decode(String.self, forKey: .format)) else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "Unknown API format")
        }
        format = known
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages)
        price = try? c.decodeIfPresent(ModelPrice.self, forKey: .price)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual)
    }
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
        case .opencodeZen: "Gateway da OpenCode com modelos testados em agentes (Claude, GPT, Grok e abertos; os modelos Gemini, que usam outro formato, ainda não aparecem). Pré-pago: cobra do seu saldo pelo uso, sem margem sobre o preço do modelo. Os modelos gratuitos, que podem usar seus dados, ficam fora da lista."
        case .opencodeGo: "Assinatura da OpenCode (Go US$ 10/mês, Go Plus US$ 40/mês) com modelos abertos como GLM, Kimi, DeepSeek e Qwen. O uso tem limite por modelo em janelas de 5 horas, semana e mês; passando do limite, os modelos gratuitos seguem funcionando, e o saldo do Zen cobre se você ativar \"Use balance\" no console."
        case .commandCode: "Modelos de vários laboratórios (Claude, GPT, DeepSeek, Kimi, GLM…) pela API da Command Code. Precisa de um plano com acesso à API: Provider (pago por uso), GOAT, Pro, Max ou Team. O plano Go não inclui a API. Os modelos gratuitos ou promocionais, que podem rodar sob outros termos, ficam fora da lista."
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

    /// Gateways whose docs say to authenticate every route with `Authorization: Bearer` (the Messages route included,
    /// where Anthropic's own SDKs would send `x-api-key`).
    var takesBearerOnMessages: Bool { [.opencodeZen, .opencodeGo, .commandCode].contains(self) }

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
        models = try c.lossyArray(.models)
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

/// When the automatic refresh of a provider's models is tried again after it failed (a gateway without `/models`, a
/// revoked key, a server that is off): after 5 minutes, then twice as long each time, never past the usual 6 hours.
/// A key or login the provider refused waits the full 6 hours at once: asking again changes nothing.
enum ModelRefreshBackoff {
    static let maxAge: TimeInterval = 6 * 3600
    static let firstWait: TimeInterval = 5 * 60

    /// The last automatic attempt that failed, and how many in a row.
    struct Failure: Equatable {
        var at: Date
        var count: Int
        var credentialRefused: Bool
    }

    static func wait(after failure: Failure) -> TimeInterval {
        guard !failure.credentialRefused else { return maxAge }
        return min(maxAge, firstWait * pow(2, Double(min(max(failure.count, 1) - 1, 16))))
    }

    /// Whether the list is due: older than `age` (or never fetched), and not still waiting out a failed attempt.
    static func isDue(updatedAt: Date?, failure: Failure?, now: Date, age: TimeInterval = maxAge) -> Bool {
        if let failure, now < failure.at.addingTimeInterval(wait(after: failure)) { return false }
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > age
    }
}

enum ModelCatalog {
    /// A refreshed list for a custom gateway: what the gateway lists, then the models added by hand that it does not name.
    static func mergingManual(fetched: [ProviderModel], previous: [ProviderModel]) -> [ProviderModel] {
        let listed = Set(fetched.map(\.id))
        return fetched + previous.filter { $0.isManual == true && !listed.contains($0.id) }
    }

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
                .map { ProviderModel(id: $0, name: $0, format: .messages, supportsImages: true) }
        case .openai:
            return openAIModels(try await OpenAIClient(baseURL: base, apiKey: token, session: session).models())
        case .commandCode:
            // The list is public (no key needed); the key goes along anyway.
            return commandCodeModels(try await getJSON(base.appending(path: "models"), token: token, session: session))
        case .opencodeZen, .opencodeGo:
            // The gateway lists what is live; models.dev (what OpenCode itself uses) says which format each one needs.
            async let live = OpenAIClient(baseURL: base, apiKey: nil, session: session).models()
            async let metadata = getJSON(modelsDevURL, token: nil, session: session)
            let key = account.kind == .opencodeZen ? "opencode" : "opencode-go"
            return openCodeModels(live: try await live, metadata: (try? await metadata)?[key]?["models"], provider: account.kind)
        case .custom:
            // The gateway speaks one chosen format; list via the matching endpoint, with the user's headers.
            let ids = account.format == .messages
                ? try await AnthropicClient(baseURL: base, apiKey: token, extraHeaders: account.headers, session: session).models()
                : try await OpenAIClient(baseURL: base, apiKey: token, extraHeaders: account.headers, session: session).models()
            return ids.map { ProviderModel(id: $0, name: $0, format: account.format) }
        case .openrouter:
            return openRouterModels(try await OpenAIClient(baseURL: base, apiKey: token, session: session).modelEntries())
        case .claudeCode, .xai, .ollama, .lmstudio:
            return try await OpenAIClient(baseURL: base, apiKey: token, session: session).models()
                .map { ProviderModel(id: $0, name: $0, format: .chat) }
        }
    }

    static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    /// Sign in with ChatGPT: `models[]` with `slug`, `display_name`, `visibility` (show only "list"), server order kept.
    static func chatGPTModels(_ json: JSONValue) -> [ProviderModel] {
        (json["models"]?.array ?? []).compactMap { entry in
            guard entry["visibility"]?.string == "list", let slug = entry["slug"]?.string else { return nil }
            return ProviderModel(id: slug, name: entry["display_name"]?.string ?? slug, format: .responses,
                                 supportsImages: supportsImages(in: entry) ?? openAIFamilySupportsImages(slug))
        }
    }

    /// Whether a catalog entry says the model takes pictures: its input modalities (models.dev `modalities.input`,
    /// OpenRouter `architecture.input_modalities`, `input_modalities`) include "image", or models.dev marks it
    /// `attachment: true`. A list without "image" says no; an entry that says nothing about it gives nil.
    static func supportsImages(in entry: JSONValue?) -> Bool? {
        guard let entry else { return nil }
        let lists = [entry["modalities"]?["input"], entry["input_modalities"], entry["architecture"]?["input_modalities"]]
            .compactMap { $0?.array }
        if lists.contains(where: { $0.contains(.string("image")) }) || entry["attachment"]?.bool == true { return true }
        return lists.isEmpty ? nil : false
    }

    /// OpenAI's own list says nothing about pictures: the families known to take them (GPT-4o, 4.1, 5, o3, o4)
    /// say yes; anything else is unknown.
    static func openAIFamilySupportsImages(_ id: String) -> Bool? {
        let id = id.lowercased()
        if id.hasPrefix("o3-mini") { return false }
        return ["gpt-4o", "chatgpt-4o", "gpt-4.1", "gpt-5", "o3", "o4"].contains { id.hasPrefix($0) } ? true : nil
    }

    /// OpenRouter lists each model's input modalities.
    static func openRouterModels(_ entries: [JSONValue]) -> [ProviderModel] {
        var seen: Set<String> = []
        return entries.compactMap { entry -> ProviderModel? in
            guard let id = entry["id"]?.string, seen.insert(id).inserted else { return nil }
            return ProviderModel(id: id, name: id, format: .chat, supportsImages: supportsImages(in: entry),
                                 price: openRouterPrice(entry["pricing"]))
        }
        .sorted { $0.id < $1.id }
    }

    /// OpenRouter prices are dollars per token, as text ("0.000003"); a negative one ("-1", the routers) means none.
    static func openRouterPrice(_ pricing: JSONValue?) -> ModelPrice? {
        func perMillion(_ key: String) -> Double? {
            guard let value = pricing?[key].flatMap({ $0.string.flatMap(Double.init) ?? $0.number }), value.isFinite, value >= 0 else { return nil }
            return value * 1_000_000
        }
        guard let input = perMillion("prompt"), let output = perMillion("completion") else { return nil }
        return ModelPrice(input: input, cacheRead: perMillion("input_cache_read"), cacheWrite: perMillion("input_cache_write"), output: output)
    }

    /// models.dev lists dollars per million tokens under `cost`.
    static func modelsDevPrice(_ cost: JSONValue?) -> ModelPrice? {
        guard let input = cost?["input"]?.number, let output = cost?["output"]?.number, input >= 0, output >= 0 else { return nil }
        return ModelPrice(input: input, cacheRead: cost?["cache_read"]?.number, cacheWrite: cost?["cache_write"]?.number, output: output)
    }

    /// The API also lists embeddings, audio, image and moderation models; keep the ones that chat.
    static func openAIModels(_ ids: [String]) -> [ProviderModel] {
        let excluded = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "audio", "realtime", "moderation",
                        "search", "davinci", "babbage", "sora", "computer-use"]
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o") || id.hasPrefix("chatgpt") || id.contains("codex"))
                && !excluded.contains { id.contains($0) }
        }
        .map { ProviderModel(id: $0, name: $0, format: .responses, supportsImages: openAIFamilySupportsImages($0)) }
    }

    /// `supported_endpoints` says what each model speaks; chat completions is preferred when offered.
    static func commandCodeModels(_ json: JSONValue) -> [ProviderModel] {
        (json["data"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string, !isCommandCodePromotional(id) else { return nil }
            let endpoints = entry["supported_endpoints"]?.array?.compactMap(\.string) ?? ["/chat/completions"]
            let format: APIFormat
            if endpoints.contains("/chat/completions") { format = .chat }
            else if endpoints.contains("/messages") { format = .messages }
            else if endpoints.contains("/responses") { format = .responses }
            else { return nil }
            return ProviderModel(id: id, name: entry["name"]?.string ?? id, format: format,
                                 contextLength: entry["context_length"]?.int, supportsImages: supportsImages(in: entry))
        }
    }

    /// Free and stealth models run "under different provider terms" (Command Code docs), possibly training on the
    /// prompts: left out, as Zen's free ones are.
    static func isCommandCodePromotional(_ id: String) -> Bool {
        let id = id.lowercased()
        return id.contains(":free") || id.hasSuffix("-free") || id.hasPrefix("stealth/")
    }

    /// Live ids filtered and typed with models.dev: `provider.npm` @ai-sdk/anthropic → Messages, @ai-sdk/openai →
    /// Responses, absent → chat (the same mapping the OpenCode docs give per endpoint); Google-format (a per-model
    /// path), deprecated, alpha, tool-less and, for Zen, free models are left out. The free models of Zen may train
    /// on the prompts during their free period; the one in the Go plan (zero retention) is part of the subscription
    /// and the only thing that keeps working past its limits, so Go keeps it. Without metadata (models.dev
    /// unreachable) the formats come from the endpoint tables of the docs instead.
    static func openCodeModels(live: [String], metadata: JSONValue?, provider: ProviderKind = .opencodeZen,
                               now: Date = .now) -> [ProviderModel] {
        let keepsFree = provider == .opencodeGo
        return live.compactMap { id in
            guard !isOpenCodeDeprecated(id, now: now) else { return nil }
            guard let metadata else {
                guard !id.contains("alpha"), provider != .opencodeGo || openCodeGoDocumentedIDs.contains(id),
                      let format = documentedOpenCodeFormat(id, provider: provider),
                      keepsFree || !isOpenCodeFree(id) else { return nil }
                return ProviderModel(id: id, name: id, format: format)
            }
            guard let info = metadata[id] else { return nil }
            guard !["deprecated", "alpha"].contains(info["status"]?.string ?? ""), info["tool_call"]?.bool != false else { return nil }
            let cost = info["cost"]
            if !keepsFree && cost?["input"]?.number == 0 && cost?["output"]?.number == 0 { return nil }
            let format: APIFormat
            switch info["provider"]?["npm"]?.string {
            case nil, "@ai-sdk/openai-compatible": format = .chat
            case "@ai-sdk/anthropic": format = .messages
            case "@ai-sdk/openai": format = .responses
            default: return nil
            }
            return ProviderModel(id: id, name: info["name"]?.string ?? id, format: format,
                                 contextLength: info["limit"]?["context"]?.int, supportsImages: supportsImages(in: info),
                                 price: modelsDevPrice(cost))
        }
    }

    /// Models the Zen docs (Deprecations table) retired, with the day: the gateway still lists some of them and
    /// models.dev does not always mark them.
    static let openCodeDeprecations: [String: String] = [
        "gpt-5.2-codex": "2026-07-23", "gpt-5.1-codex": "2026-07-23", "gpt-5.1-codex-max": "2026-07-23",
        "gpt-5.1-codex-mini": "2026-07-23", "gpt-5-codex": "2026-07-23",
        "claude-opus-4-1": "2026-08-05", "claude-sonnet-4": "2026-06-15", "claude-3-5-haiku": "2026-02-16",
        "gemini-3-pro": "2026-03-09", "minimax-m2.5": "2026-08-05", "minimax-m2.1": "2026-03-15",
        "glm-5": "2026-05-14", "glm-4.7": "2026-03-15", "glm-4.6": "2026-03-15",
        "kimi-k2.5": "2026-08-05", "kimi-k2-thinking": "2026-03-06", "kimi-k2": "2026-03-06",
        "qwen3-coder": "2026-02-06",
    ]

    /// The models the Go docs list (opencode.ai/docs/go). The gateway's own list also carries retired and test ids
    /// (omen-alpha, hy3-preview, glm-5.1…), so without models.dev only these are offered.
    static let openCodeGoDocumentedIDs: Set<String> = [
        "glm-5.3-flash", "glm-5.3", "glm-5.2", "gpt-6-luna", "gpt-5.6-luna", "claude-haiku-5-5", "kimi-k3", "kimi-k2.7-code",
        "longcat-2.0", "longcat-2.5-preview-free", "mimo-v2.6-flash", "mimo-v2.6-pro", "mimo-v2.5", "mimo-v2.5-pro",
        "minimax-m3", "minimax-m2.7", "muse-spark-1.3-contributor", "muse-spark-1.2-contributor", "qwen3.8-max",
        "qwen3.8-flash", "qwen3.7-plus", "deepseek-v4.1-flash", "deepseek-v4-pro", "deepseek-v4-flash",
        "deepseek-v4-flash-vision-exp", "hy4-preview", "hy3", "space-bunny",
    ]

    static func isOpenCodeDeprecated(_ id: String, now: Date) -> Bool {
        guard let day = openCodeDeprecations[id] else { return false }
        return day <= now.formatted(.iso8601.year().month().day()) // ISO days sort as text
    }

    /// Free ids carry "free" (and Zen's first free model, "big-pickle", does not).
    private static func isOpenCodeFree(_ id: String) -> Bool { id.contains("free") || id == "big-pickle" }

    /// The wire format the OpenCode docs list for a model id (Zen and Go share the paths): Claude on `/messages`,
    /// GPT, Grok and Muse Spark on `/responses`, the rest on `/chat/completions`, except the Qwen models and, on
    /// Go, MiniMax, which are on `/messages`. Gemini (a per-model path) and Jev (System One) are not chat models.
    static func documentedOpenCodeFormat(_ id: String, provider: ProviderKind) -> APIFormat? {
        if id.hasPrefix("gemini") || id.hasPrefix("jev") { return nil }
        if id.hasPrefix("claude") { return .messages }
        if ["gpt-", "grok-", "muse-spark-"].contains(where: id.hasPrefix) { return .responses }
        if id.hasPrefix("qwen") { return provider == .opencodeGo || id != "qwen3.8-max" ? .messages : .chat }
        if provider == .opencodeGo && id.hasPrefix("minimax") { return .messages }
        return .chat
    }

    private static func getJSON(_ url: URL, token: String?, session: URLSession) async throws -> JSONValue {
        let data = try await ProviderTransport.fetch(ProviderTransport.authorizedRequest(url, apiKey: token), session: session)
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
        // Without a listed model a custom gateway still speaks the format chosen for it, not always chat.
        switch model?.format ?? (kind == .custom ? format : .chat) {
        case .chat:
            return OpenAIClient(baseURL: base, credentials: credentials, extraHeaders: headers, conversationID: conversationID)
        case .messages:
            var client = AnthropicClient(baseURL: base, credentials: credentials, extraHeaders: headers)
            client.sendsBearer = kind.takesBearerOnMessages
            return client
        case .responses:
            // Sign in with ChatGPT takes tools as an `additional_tools` input item, not top-level `tools`.
            return ResponsesClient(baseURL: base, credentials: credentials, extraHeaders: headers,
                                   toolsAsInputItem: kind == .chatgpt, conversationID: conversationID)
        case .claudeCode:
            return nil
        }
    }
}
