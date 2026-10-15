import Foundation
import Testing
@testable import Orb

// Command Code and OpenCode (Zen, Go), checked against their documentation: Command Code's Provider API page
// (https://commandcode.ai/docs/provider) and OpenCode's Zen and Go pages (https://opencode.ai/docs/zen, /docs/go).
// Fixtures are trimmed copies of the public model lists.

struct GatewayCatalogTests {
    /// `GET /provider/v1/models`: Claude on `/messages` only, GPT and open models on chat completions and Responses,
    /// a few open models on chat completions alone.
    private let commandCodeList = """
    {"object":"list","data":[
      {"id":"claude-haiku-4-5-20251001","name":"Claude Haiku 4.5","context_length":200000,"supported_endpoints":["/messages"]},
      {"id":"gpt-5.5","name":"GPT-5.5","context_length":400000,"supported_endpoints":["/chat/completions","/responses"]},
      {"id":"deepseek/deepseek-v4-flash-fast","name":"DeepSeek V4 Flash Fast","context_length":1000000,"supported_endpoints":["/chat/completions"]},
      {"id":"moonshotai/Kimi-K3","name":"Kimi K3","context_length":1000000,"supported_endpoints":["/responses","/chat/completions"]},
      {"id":"responses-only","name":"Responses Only","supported_endpoints":["/responses"]},
      {"id":"typesafe/jev","name":"Jev","supported_endpoints":["/systemone"]}]}
    """

    @Test func commandCodeSendsEachModelToTheRouteItsListSays() throws {
        let models = ModelCatalog.commandCodeModels(try #require(JSONValue.parse(commandCodeList)))
        #expect(models.map(\.id) == ["claude-haiku-4-5-20251001", "gpt-5.5", "deepseek/deepseek-v4-flash-fast",
                                     "moonshotai/Kimi-K3", "responses-only"])
        // Claude answers on /messages only; chat completions is preferred whenever it is offered; the decision model
        // (/systemone) is not a chat model.
        #expect(models.map(\.format) == [.messages, .chat, .chat, .chat, .responses])
        #expect(models[0].contextLength == 200_000)
        #expect(models[4].contextLength == nil)
    }

    /// models.dev entries for Go, as documented: Qwen and MiniMax on Messages, GPT and Grok on Responses, the rest on
    /// chat completions, plus the free model the plan includes and a retired one.
    private let goMetadata = """
    {"glm-5.3":{"name":"GLM-5.3","tool_call":true,"cost":{"input":1.4,"output":4.4},"limit":{"context":1000000},"modalities":{"input":["text"]}},
     "minimax-m3":{"name":"MiniMax M3","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"},"cost":{"input":0.3,"output":1.2},"limit":{"context":1000000},"modalities":{"input":["text","image","video"]}},
     "qwen3.8-max":{"name":"Qwen3.8 Max","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"},"cost":{"input":2,"output":6}},
     "gpt-6-luna":{"name":"GPT 6 Luna","tool_call":true,"provider":{"npm":"@ai-sdk/openai"},"cost":{"input":0.1,"output":0.5}},
     "longcat-2.5-preview-free":{"name":"LongCat 2.5 Preview Free","tool_call":true,"cost":{"input":0,"output":0}},
     "alpha-x":{"name":"Alpha","tool_call":true,"status":"alpha","cost":{"input":1,"output":1}},
     "no-tools":{"name":"No Tools","tool_call":false,"cost":{"input":1,"output":1}}}
    """

    @Test func goKeepsItsFreeModelButZenDoesNot() throws {
        let metadata = try #require(JSONValue.parse(goMetadata))
        let live = ["glm-5.3", "minimax-m3", "qwen3.8-max", "gpt-6-luna", "longcat-2.5-preview-free", "alpha-x", "no-tools", "omen-alpha"]
        let go = ModelCatalog.openCodeModels(live: live, metadata: metadata, provider: .opencodeGo)
        #expect(go.map(\.id) == ["glm-5.3", "minimax-m3", "qwen3.8-max", "gpt-6-luna", "longcat-2.5-preview-free"])
        #expect(go.map(\.format) == [.chat, .messages, .messages, .responses, .chat])
        #expect(go[1].supportsImages == true && go[0].supportsImages == false)
        let zen = ModelCatalog.openCodeModels(live: live, metadata: metadata, provider: .opencodeZen)
        #expect(!zen.map(\.id).contains("longcat-2.5-preview-free"))
        #expect(zen.count == 4)
    }

    @Test func modelsTheZenDocsRetiredAreDroppedOnceTheirDayPasses() throws {
        // models.dev does not mark these, and the gateway still lists them.
        let entry = #"{"tool_call":true,"cost":{"input":1,"output":1}}"#
        let ids = ["claude-sonnet-4", "gpt-5.1-codex", "glm-5", "kimi-k2.5", "minimax-m2.5", "glm-5.3"]
        let metadata = try #require(JSONValue.parse("{" + ids.map { "\"\($0)\":\(entry)" }.joined(separator: ",") + "}"))
        let after = ModelCatalog.openCodeModels(live: ids, metadata: metadata, now: Date(timeIntervalSince1970: 1_791_000_000)) // 2026-10-03
        #expect(after.map(\.id) == ["glm-5.3"])
        let before = ModelCatalog.openCodeModels(live: ids, metadata: metadata, now: Date(timeIntervalSince1970: 1_775_000_000)) // 2026-04-01
        #expect(before.map(\.id) == ["claude-sonnet-4", "gpt-5.1-codex", "glm-5", "kimi-k2.5", "minimax-m2.5", "glm-5.3"])
    }

    @Test func commandCodeLeavesOutItsFreeAndStealthModels() throws {
        // The docs: free or promotional models may run under different provider terms.
        let list = #"""
        {"data":[{"id":"stealth/glyph-cluster:free","supported_endpoints":["/chat/completions"]},
                 {"id":"poolside/laguna-s-2.1-free","supported_endpoints":["/chat/completions"]},
                 {"id":"inclusionai/ling-3.1-flash:free","supported_endpoints":["/chat/completions"]},
                 {"id":"gpt-5.5","supported_endpoints":["/chat/completions","/responses"]}]}
        """#
        #expect(ModelCatalog.commandCodeModels(try #require(JSONValue.parse(list))).map(\.id) == ["gpt-5.5"])
    }

    @Test func withoutMetadataGoOffersOnlyTheModelsItsDocsList() {
        // The gateway's own list also carries retired and test ids.
        let live = ["glm-5.3", "omen-alpha", "hy3-preview", "glm-5.1", "qwen3.6-plus", "qwen3.7-max", "grok-4.7", "kimi-k3"]
        let go = ModelCatalog.openCodeModels(live: live, metadata: nil, provider: .opencodeGo)
        #expect(go.map(\.id) == ["glm-5.3", "kimi-k3"])
        #expect(!ModelCatalog.openCodeModels(live: ["omen-alpha", "glm-5.3"], metadata: nil, provider: .opencodeZen).map(\.id).contains("omen-alpha"))
    }

    @Test func withoutMetadataFormatsFollowTheEndpointTablesOfTheDocs() {
        let live = ["claude-opus-5-5", "gpt-6-sol", "grok-4.7", "muse-spark-1.3", "gemini-3.8-flash", "jev-1.13",
                    "qwen3.8-max", "qwen3.8-flash", "minimax-m3", "kimi-k3", "glm-5.3", "deepseek-v4-pro",
                    "mistral-large-4", "big-pickle", "nemotron-3-ultra-free", "claude-sonnet-4"]
        let zen = ModelCatalog.openCodeModels(live: live, metadata: nil, provider: .opencodeZen)
        #expect(Dictionary(uniqueKeysWithValues: zen.map { ($0.id, $0.format) }) == [
            "claude-opus-5-5": .messages, "gpt-6-sol": .responses, "grok-4.7": .responses, "muse-spark-1.3": .responses,
            "qwen3.8-max": .chat, "qwen3.8-flash": .messages, "minimax-m3": .chat, "kimi-k3": .chat, "glm-5.3": .chat,
            "deepseek-v4-pro": .chat, "mistral-large-4": .chat,
        ])
        // On Go the docs put MiniMax and every Qwen model on /messages, and keep the free model.
        let go = ModelCatalog.openCodeModels(live: ["minimax-m3", "qwen3.8-max", "longcat-2.5-preview-free"], metadata: nil,
                                             provider: .opencodeGo)
        #expect(go.map(\.format) == [.messages, .messages, .chat])
    }
}

@Suite(.serialized)
struct GatewayWireTests {
    private func events(_ client: some LLMClient) async throws {
        for try await _ in client.stream(model: "m", messages: [.user("oi")], tools: []) {}
    }

    @Test func gatewaysAuthenticateMessagesWithBearerAndTheKeyHeader() async throws {
        for (host, bearer) in [("api.commandcode.ai", true), ("api.anthropic.com", false)] {
            var client = AnthropicClient(baseURL: URL(string: "https://\(host)/provider/v1")!, apiKey: " sk-test ",
                                         session: StubProtocol.session)
            client.sendsBearer = bearer
            StubProtocol.queue(host: host, [.init(body: "data: {\"type\":\"message_stop\"}\n\n")])
            try await events(client)
            let request = try #require(StubProtocol.sent(to: host).first?.request)
            #expect(request.url?.path() == "/provider/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == (bearer ? "Bearer sk-test" : nil))
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicClient.apiVersion)
        }
    }

    @Test func gatewayAccountsTurnOnBearerForMessagesOnly() throws {
        let messages = ProviderModel(id: "claude-haiku-5-5", name: "Claude", format: .messages)
        for kind in [ProviderKind.commandCode, .opencodeZen, .opencodeGo] {
            let client = ProviderAccount(kind: kind).client(for: messages, credentials: { _ in "k" }, conversationID: "c")
            #expect((client as? AnthropicClient)?.sendsBearer == true, "\(kind)")
        }
        let anthropic = ProviderAccount(kind: .anthropic).client(for: messages, credentials: { _ in "k" }, conversationID: "c")
        #expect((anthropic as? AnthropicClient)?.sendsBearer == false)
    }

    @Test func commandCodeAndOpenCodeChatAskForUsage() async throws {
        for (kind, host, path) in [(ProviderKind.commandCode, "api.commandcode.ai", "/provider/v1/chat/completions"),
                                   (.opencodeGo, "opencode.ai", "/zen/go/v1/chat/completions")] {
            let account = ProviderAccount(kind: kind)
            let client = OpenAIClient(baseURL: try #require(URL(string: account.baseURL)), apiKey: "k",
                                      extraHeaders: ["x-opencode-session": "s1"], conversationID: "s1", session: StubProtocol.session)
            StubProtocol.queue(host: host, [.init(body: "data: [DONE]\n\n")])
            try await events(client)
            let sent = try #require(StubProtocol.sent(to: host).first)
            #expect(sent.request.url?.path() == path)
            #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
            #expect(sent.request.value(forHTTPHeaderField: "x-opencode-session") == "s1")
            #expect(sent.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Orb/") == true) // OpenCode Go asks for its own
            #expect(sent.body?["stream_options"] == .object(["include_usage": .bool(true)]))
            #expect(sent.body?["prompt_cache_key"] == nil) // only OpenAI itself takes it on chat completions
        }
    }

    @Test func theGoPlanErrorOfMessagesCarriesNoCodeButStillExplainsItself() async throws {
        // /messages answers in Anthropic's envelope: type and message, no `code` (Command Code docs, Errors).
        let body = #"{"type":"error","error":{"type":"permission_error","message":"Go plan has no API access"}}"#
        var client = AnthropicClient(baseURL: URL(string: "https://api.commandcode.ai/provider/v1")!, apiKey: "k",
                                     session: StubProtocol.session)
        client.sendsBearer = true
        StubProtocol.queue(host: "api.commandcode.ai", [.init(status: 403, body: body)])
        let error = try #require(await #expect(throws: LLMError.self, "expected a 403") {
            for try await _ in client.stream(model: "claude-haiku-4-5-20251001", messages: [.user("oi")], tools: []) {}
        })
        let text = error.errorDescription ?? ""
        #expect(text.contains("plano não inclui acesso à API") && !text.contains("Chave ou login inválido"))
        // Anthropic's own 403 is not about a plan.
        #expect(ProviderTransport.errorMessage(from: Data(body.utf8), status: 403, host: "api.anthropic.com") == "Go plan has no API access")
    }

    @Test func aRejectedApiKeyIsNotSentTwice() async throws {
        let client = OpenAIClient(baseURL: URL(string: "https://opencode.ai/zen/go/v1")!, apiKey: "k", session: StubProtocol.session)
        StubProtocol.queue(host: "opencode.ai", [.init(status: 401, body: #"{"type":"error","error":{"type":"CreditsError","message":"Insufficient balance."}}"#),
                                                 .init(status: 401, body: "")])
        do {
            for try await _ in client.stream(model: "m", messages: [.user("oi")], tools: []) {}
            Issue.record("expected a 401")
        } catch is LLMError {}
        #expect(StubProtocol.sent(to: "opencode.ai").count == 1)
    }

    @Test func opencodeSessionHeaderTravelsOnEveryFormat() throws {
        for kind in [ProviderKind.opencodeZen, .opencodeGo] {
            for format in [APIFormat.chat, .messages, .responses] {
                let model = ProviderModel(id: "m", name: "M", format: format)
                let client = ProviderAccount(kind: kind).client(for: model, credentials: { _ in "k" }, conversationID: "conv-1")
                let headers = (client as? OpenAIClient)?.extraHeaders ?? (client as? AnthropicClient)?.extraHeaders
                    ?? (client as? ResponsesClient)?.extraHeaders
                #expect(headers?["x-opencode-session"] == "conv-1", "\(kind) \(format)")
            }
        }
    }
}

struct GatewayErrorTests {
    @Test func keepsTheDocumentedActionableCodeWithTheMessage() {
        let message = { (text: String) in ProviderTransport.errorMessage(from: Data(text.utf8), status: 403) }
        #expect(message(#"{"error":{"message":"Plan lacks API access","type":"permission_error","code":"upgrade_required"}}"#)
                == "Plan lacks API access [upgrade_required]")
        #expect(message(#"{"error":{"message":"unsupported_model: x","code":"unsupported_model"}}"#) == "unsupported_model: x")
        #expect(message(#"{"error":{"message":"Slow down","type":"rate_limit_error","code":"rate"}}"#) == "Slow down")
        // OpenCode's envelope has a type and no code.
        #expect(message(#"{"type":"error","error":{"type":"CreditsError","message":"Insufficient balance."}}"#) == "Insufficient balance.")
    }

    @Test func explainsTheGoPlanHasNoAPI() {
        let text = LLMError.http(status: 403, message: "Plan lacks API access [upgrade_required]").errorDescription ?? ""
        #expect(text.contains("plano não inclui acesso à API") && text.contains("Go") && !text.contains("Chave ou login inválido"))
    }

    @Test func aModelOpenCodeRefusedIsNotABadKey() {
        // OpenCode's ModelError (401), DataPolicyError and RegionError (403), from the gateway's own messages.
        for (status, message) in [(401, "Model is disabled"), (401, "Model foo is not supported"),
                                  (403, "This model collects data used to improve its quality and requires explicit opt in: https://opencode.ai/workspace/x/go"),
                                  (403, "The latest version of this model is only available hosted in China and requires explicit opt in: https://opencode.ai/workspace/x/go"),
                                  (403, "This model is not available in your country.")] {
            let text = LLMError.http(status: status, message: message).errorDescription ?? ""
            #expect(text.contains("recusou este modelo") && !text.contains("Chave ou login inválido"), "\(message)")
        }
        #expect(LLMError.http(status: 401, message: "Invalid API key.").errorDescription?.contains("Chave ou login inválido") == true)
    }

    @Test func aMissingBalanceIsNotABadKey() {
        for message in ["Insufficient balance. Manage your billing here", "No payment method. Add one in billing", "Monthly limit reached"] {
            let text = LLMError.http(status: 401, message: message).errorDescription ?? ""
            #expect(text.contains("Sem saldo") && !text.contains("Chave ou login inválido"), "\(message)")
        }
        #expect(LLMError.http(status: 401, message: "Invalid API key").errorDescription?.contains("Chave ou login inválido") == true)
        #expect(LLMError.http(status: 402, message: "x").errorDescription?.contains("pagamento") == true)
    }

    @Test func goLimitsAskForALongWaitThatIsNotRetried() {
        // OpenCode answers a spent 5-hour/weekly/monthly Go allowance with 429 and Retry-After.
        let limited = LLMError.http(status: 429, message: "Subscription quota exceeded", retryAfter: 5 * 3600)
        #expect(limited.errorDescription?.contains("300 min") == true)
        #expect(Retry.delay(afterAttempt: 1, retryAfter: limited.retryAfter, jitter: 0) == nil)
    }
}

struct GatewaySessionTests {
    @Test func aRoutineRunAndAFreshChatGetTheirOwnGatewaySession() {
        var chat = Conversation()
        chat.gatewaySessionID = "s1"
        #expect(chat.startingRoutineRun(at: .now).gatewaySessionID == nil)
        #expect(Conversation().gatewaySessionID == nil)
    }

    @Test func theGatewaySessionSurvivesSavingTheConversation() throws {
        var chat = Conversation()
        chat.gatewaySessionID = "s1"
        let data = try JSONEncoder().encode(chat)
        #expect(try JSONDecoder().decode(Conversation.self, from: data).gatewaySessionID == "s1")
    }
}
