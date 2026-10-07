import Foundation
import Testing
@testable import OpenBotMac

struct ProviderTests {
    @Test func modelReferencesKeepSlashesInModelIds() throws {
        let ref = try #require(ModelRef("commandCode/deepseek/deepseek-v4-flash"))
        #expect(ref.provider == .commandCode)
        #expect(ref.model == "deepseek/deepseek-v4-flash")
        #expect(ref.text == "commandCode/deepseek/deepseek-v4-flash")
        #expect(ModelRef("grok-4") == nil)
        #expect(ModelRef("nope/x") == nil)
    }

    @Test func singleProviderStateMigrates() throws {
        let botID = UUID().uuidString
        let json = """
        {"bots":[{"id":"\(botID)","name":"Atlas","model":"grok-4-fast"}],
         "provider":{"preset":"xai","baseURL":"https://api.x.ai/v1","defaultModel":"grok-4"},
         "models":["grok-4","grok-4-fast"]}
        """
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.providers.map(\.kind) == [.xai])
        #expect(state.providers.first?.models.map(\.id) == ["grok-4", "grok-4-fast"])
        #expect(state.defaultModel == "xai/grok-4")
        #expect(state.bots.first?.model == "xai/grok-4-fast")
    }

    @Test func commandCodeFormatsComeFromSupportedEndpoints() throws {
        let json = try #require(JSONValue.parse("""
        {"data":[
          {"id":"claude-sonnet-5-5","name":"Claude Sonnet 5.5","context_length":1000000,"supported_endpoints":["/messages"]},
          {"id":"gpt-6-astra","name":"GPT-6 Astra","supported_endpoints":["/chat/completions","/responses"]},
          {"id":"deepseek/deepseek-v4-flash","supported_endpoints":["/chat/completions"]},
          {"id":"classifier","supported_endpoints":["/systemone"]}]}
        """))
        let models = ModelCatalog.commandCodeModels(json)
        #expect(models.map(\.id) == ["claude-sonnet-5-5", "gpt-6-astra", "deepseek/deepseek-v4-flash"])
        #expect(models.map(\.format) == [.messages, .chat, .chat])
        #expect(models[0].contextLength == 1_000_000)
    }

    @Test func openCodeUsesModelsDevForFormats() throws {
        let metadata = try #require(JSONValue.parse("""
        {"glm-5.3": {"name":"GLM 5.3","tool_call":true,"cost":{"input":1,"output":3},"limit":{"context":200000}},
         "claude-haiku-5-5": {"name":"Claude Haiku 5.5","tool_call":true,"provider":{"npm":"@ai-sdk/anthropic"},"cost":{"input":0.1,"output":0.5}},
         "gpt-5.6-luna": {"name":"GPT-5.6 Luna","tool_call":true,"provider":{"npm":"@ai-sdk/openai"},"cost":{"input":0.2,"output":1.2}},
         "gemini-x": {"name":"Gemini","tool_call":true,"provider":{"npm":"@ai-sdk/google"},"cost":{"input":1,"output":2}},
         "big-pickle": {"name":"Big Pickle","tool_call":true,"cost":{"input":0,"output":0}},
         "old": {"name":"Old","tool_call":true,"status":"deprecated","cost":{"input":1,"output":1}}}
        """))
        let models = ModelCatalog.openCodeModels(
            live: ["glm-5.3", "claude-haiku-5-5", "gpt-5.6-luna", "gemini-x", "big-pickle", "old", "unknown"], metadata: metadata)
        #expect(models.map(\.id) == ["glm-5.3", "claude-haiku-5-5", "gpt-5.6-luna"])
        #expect(models.map(\.format) == [.chat, .messages, .responses])
        #expect(models[0].contextLength == 200_000)
    }

    @Test func chatGPTListsOnlyVisibleModels() throws {
        let json = try #require(JSONValue.parse("""
        {"models":[{"slug":"gpt-6-sol","display_name":"GPT-6 Sol","visibility":"list"},
                   {"slug":"internal","display_name":"Hidden","visibility":"hide"}]}
        """))
        #expect(ModelCatalog.chatGPTModels(json) == [ProviderModel(id: "gpt-6-sol", name: "GPT-6 Sol", format: .responses)])
    }

    @Test func openAIListKeepsChatModels() {
        let ids = ["gpt-6-sol", "o4-mini", "text-embedding-3-large", "whisper-1", "gpt-image-2", "omni-moderation-latest", "dall-e-3"]
        #expect(ModelCatalog.openAIModels(ids).map(\.id) == ["gpt-6-sol", "o4-mini"])
    }

    @Test func pkceChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(ChatGPTAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func chatGPTToolsTravelAsAnInputItem() throws {
        let tools = [ToolSpec(name: "read_file", description: "Reads", parameters: .schema([:]))]
        let body = ResponsesClient.requestBody(model: "gpt-6-sol", messages: [.system("s"), .user("oi")], tools: tools,
                                               toolsAsInputItem: true)
        #expect(body["tools"] == nil)
        let first = try #require(body["input"]?.array?.first)
        #expect(first["type"] == .string("additional_tools"))
        #expect(first["tools"]?.array?.first?["name"] == .string("read_file"))
    }

    @Test func openCodeClientsCarryASessionHeader() throws {
        var account = ProviderAccount(kind: .opencodeGo)
        account.models = [ProviderModel(id: "glm-5.3", name: "GLM", format: .chat)]
        let client = try #require(account.client(for: account.models[0], token: "k", conversationID: "abc") as? OpenAIClient)
        #expect(client.extraHeaders["x-opencode-session"] == "abc")
        let messages = ProviderModel(id: "claude-haiku-5-5", name: "Claude", format: .messages)
        #expect(account.client(for: messages, token: "k", conversationID: "abc") is AnthropicClient)
    }
}

struct ProviderExpansionTests {
    @Test func remembersOpenAndClosedProviders() {
        let state = ProviderExpansion.parse("xai:0,claudeCode:1,nope:1,quebrado")
        #expect(state == [.xai: false, .claudeCode: true])
        #expect(ProviderExpansion.parse("").isEmpty)
    }
}
