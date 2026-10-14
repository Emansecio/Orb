import Foundation
import Testing
@testable import Orb

/// The Orb's "Esforço": the levels each model's catalog lists, what a turn sends, and the line under the picker.
struct ReasoningEffortTests {
    private let sonnet = ProviderModel(id: "sonnet", name: "Sonnet 5.5", format: .claudeCode,
                                       efforts: ["low", "medium", "high", "xhigh", "max"])
    private let oldHaiku = ProviderModel(id: "claude-haiku-4-5", name: "Haiku 4.5", format: .claudeCode)

    @Test func claudeCodeSaysWhichLevelsEachModelTakes() {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"models":[{"value":"sonnet","displayName":"Sonnet 5.5","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-sonnet-4-6","displayName":"Sonnet 4.6","supportedEffortLevels":["low","medium","high","max"]},{"value":"claude-haiku-4-5","displayName":"Haiku 4.5"}]}}}"#
        let models = ClaudeCodeWire.models(fromInitializeResponse: line, requestID: "r1")
        #expect(models?.map(\.efforts) == [["low", "medium", "high", "xhigh", "max"], ["low", "medium", "high", "max"], nil])
    }

    @Test func chatGPTSaysWhichLevelsEachModelTakesAndTheOrbLeavesUltraOut() throws {
        let json = try #require(JSONValue.parse("""
        {"models":[{"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","default_reasoning_level":"medium",
                    "supported_reasoning_levels":[{"effort":"low","description":"a"},{"effort":"medium"},{"effort":"high"},
                                                  {"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
                   {"slug":"gpt-old","display_name":"Old","visibility":"list"}]}
        """))
        let models = ModelCatalog.chatGPTModels(json)
        #expect(models.map(\.efforts) == [["low", "medium", "high", "xhigh", "max"], nil])
        #expect(models.map(\.defaultEffort) == ["medium", nil])
        #expect(ReasoningEffort.defaultLabel(for: models[0]) == "Padrão (Médio)")
        #expect(ReasoningEffort.defaultLabel(for: models[1]) == "Padrão do modelo")
    }

    @Test func aTurnSendsTheLevelOnlyToAModelThatTakesIt() {
        #expect(ReasoningEffort.sent("high", for: sonnet) == "high")
        #expect(ReasoningEffort.sent("", for: sonnet) == nil)
        #expect(ReasoningEffort.sent("minimal", for: sonnet) == nil)
        #expect(ReasoningEffort.sent("high", for: oldHaiku) == nil)
        #expect(ReasoningEffort.sent("high", for: nil) == nil)
    }

    @Test func theLineUnderThePickerSaysWhatTheChoiceMeans() {
        #expect(ReasoningEffort.note("", for: sonnet) == nil)
        #expect(ReasoningEffort.note("high", for: sonnet) == nil)
        #expect(ReasoningEffort.note("max", for: sonnet)
                == "Esforço alto deixa as respostas mais lentas e gasta mais do limite da assinatura.")
        #expect(ReasoningEffort.note("minimal", for: sonnet) == "Este modelo não tem o esforço Mínimo; ele usa o padrão dele.")
        #expect(ReasoningEffort.note("high", for: oldHaiku) == "Este modelo não tem ajuste de esforço; ele usa o padrão dele.")
    }

    @Test func theResponsesRequestCarriesTheLevelOnlyWhenOneIsChosen() {
        let chosen = ResponsesClient.requestBody(model: "gpt-6-sol", messages: [.user("oi")], tools: [], effort: "high")
        #expect(chosen["reasoning"] == .object(["effort": .string("high")]))
        let none = ResponsesClient.requestBody(model: "gpt-6-sol", messages: [.user("oi")], tools: [])
        #expect(none["reasoning"] == nil)
    }

    @Test func theAccountHandsTheLevelToTheClient() throws {
        var chatgpt = ProviderAccount(kind: .chatgpt)
        chatgpt.baseURL = "https://chatgpt.com/backend-api/codex"
        let model = ProviderModel(id: "gpt-6-sol", name: "GPT-6-Sol", format: .responses, efforts: ["low", "high"])
        let client = try #require(chatgpt.client(for: model, credentials: { _ in "t" }, conversationID: "c", effort: "high") as? ResponsesClient)
        #expect(client.reasoningEffort == "high")
    }

    @Test func anOrbSavedBeforeTheChoiceExistedUsesTheModelsDefault() throws {
        var bot = AppState.initial.bots[0]
        bot.effort = "max"
        let data = try JSONEncoder().encode(bot)
        #expect(try JSONDecoder().decode(Bot.self, from: data).effort == "max")
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "effort")
        let decoded = try JSONDecoder().decode(Bot.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.effort == "")

        let saved = try JSONEncoder().encode(sonnet)
        #expect(try JSONDecoder().decode(ProviderModel.self, from: saved).efforts == sonnet.efforts)
    }
}
