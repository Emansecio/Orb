import Foundation
import Testing
@testable import Orb

/// Each model's window comes from whatever states it: the provider's own list, Ollama's own list for its cloud models, the
/// public catalog for a list that says none. A window nobody states stays unknown instead of being made up.
/// Serialized: the tests share the stub's answer for the public catalog's host.
@Suite(.serialized) struct ModelWindowTests {
    private func json(_ text: String) throws -> JSONValue { try #require(JSONValue.parse(text)) }

    /// The public catalog: the same model under several providers, which do not always agree.
    private let catalog = #"""
    {"lab-a":{"models":{"deepseek-v4-pro":{"limit":{"context":1000000}},"glm-5.3-flash":{"limit":{"context":1048576}},"tie":{"limit":{"context":500000}}}},
     "lab-b":{"models":{"DeepSeek/DeepSeek-V4-Pro":{"limit":{"context":1000000}},"glm-5-3-flash":{"limit":{"context":1048576}},"tie":{"limit":{"context":300000}},"zero":{"limit":{"context":0}}}},
     "lab-c":{"models":{"deepseek-v4-pro":{"limit":{"context":128000}},"glm-5.3-flash":{"limit":{"context":262144}},"nolimit":{}}},
     "lab-d":{"name":"no models here"}}
    """#

    private let tags = #"""
    {"models":[{"name":"big:cloud","remote_host":"https://ollama.com","details":{"context_length":1048576}},
               {"name":"local:8b","details":{"context_length":131072}},
               {"name":"odd:cloud","remote_host":"https://ollama.com","details":{}}]}
    """#

    private func account(_ kind: ProviderKind, host: String) -> ProviderAccount {
        var account = ProviderAccount(kind: kind)
        account.baseURL = "https://\(host)/v1"
        return account
    }

    // MARK: Reading

    @Test func aListEntryStatesItsWindowUnderTheNamesServersUse() throws {
        for key in ["context_length", "context_window", "max_context_length", "max_input_tokens", "max_model_len"] {
            #expect(try ModelCatalog.statedWindow(in: json(#"{"id":"m","\#(key)":1048576}"#)) == 1_048_576, "\(key)")
        }
        #expect(try ModelCatalog.statedWindow(in: json(#"{"id":"m"}"#)) == nil)
        // A name that says nothing gives way to the next one that does.
        #expect(try ModelCatalog.statedWindow(in: json(#"{"id":"m","context_length":0,"context_window":400000}"#)) == 400_000)
        #expect(try ModelCatalog.statedWindow(in: json(#"{"id":"m","context_length":-1}"#)) == nil)
        #expect(try ModelCatalog.statedWindow(in: json(#"{"id":"m","context_length":"big"}"#)) == nil)
        #expect(ModelCatalog.statedWindow(in: nil) == nil)
    }

    @Test func theProvidersOwnListsKeepTheWindowTheyState() throws {
        let router = ModelCatalog.openRouterModels([try json(#"{"id":"lab/big","context_length":1000000}"#), try json(#"{"id":"lab/plain"}"#)])
        #expect(router.map(\.contextLength) == [1_000_000, nil])
        let chatGPT = ModelCatalog.chatGPTModels(try json(
            #"{"models":[{"slug":"gpt-x","visibility":"list","context_window":272000},{"slug":"gpt-y","visibility":"list"}]}"#))
        #expect(chatGPT.map(\.contextLength) == [272_000, nil])
        // Each id once, in alphabetical order; an entry without an id is not a model.
        let listed = ModelCatalog.listedModels([try json(#"{"id":"b","context_length":64000}"#), try json(#"{"id":"a"}"#),
                                                try json(#"{"id":"b"}"#), try json(#"{"object":"model"}"#)], format: .chat)
        #expect(listed == [ProviderModel(id: "a", name: "a", format: .chat),
                           ProviderModel(id: "b", name: "b", format: .chat, contextLength: 64_000)])
    }

    @Test func thePublicCatalogGivesTheWindowMostProvidersStateForAnId() {
        // Two of three agree on each model; a tie goes to the smaller; no window and a zero say nothing.
        #expect(ModelCatalog.publicWindows(Data(catalog.utf8)) == ["deepseek-v4-pro": 1_000_000, "glm-5-3-flash": 1_048_576, "tie": 300_000])
        #expect(ModelCatalog.windowKey("Lab/GLM-5.3-Flash") == "glm-5-3-flash")
        // No catalog, one that is not the expected object, one cut short: no windows, never a failure.
        #expect(ModelCatalog.publicWindows(nil).isEmpty)
        #expect(ModelCatalog.publicWindows(Data("[]".utf8)).isEmpty)
        #expect(ModelCatalog.publicWindows(Data(catalog.utf8.prefix(40))).isEmpty)
    }

    @Test func onlyAnOllamaModelThatRunsInTheCloudTakesTheWindowItsEntryStates() throws {
        // The local model states its trained window, which is not the one the server loads it with.
        #expect(try ModelCatalog.ollamaCloudWindows(json(tags)) == ["big:cloud": 1_048_576])
        #expect(ModelCatalog.ollamaCloudWindows(nil).isEmpty)
    }

    @Test func aRefreshedListKeepsAKnownWindowOnlyWhereItStatesNone() {
        func model(_ id: String, _ window: Int?) -> ProviderModel { ProviderModel(id: id, name: id, format: .chat, contextLength: window) }
        let previous = [model("a", 1_000_000), model("b", 200_000), model("gone", 64_000)]
        let fetched = [model("a", nil), model("b", 400_000), model("new", nil)]
        #expect(ModelCatalog.keepingWindows(fetched: fetched, previous: previous) == [model("a", 1_000_000), model("b", 400_000), model("new", nil)])
        #expect(ModelCatalog.keepingWindows(fetched: fetched, previous: []) == fetched)
    }

    // MARK: Fetching

    @Test func aListThatStatesNoWindowIsFilledFromThePublicCatalog() async throws {
        let host = "windows-gateway.test"
        StubProtocol.queue(host: host, [.init(body:
            #"{"data":[{"id":"deepseek-v4-pro"},{"id":"glm-5.3-flash"},{"id":"house-model"},{"id":"stated","context_length":32000}]}"#)])
        StubProtocol.queue(host: "models.dev", [.init(body: catalog)])
        let models = try await ModelCatalog.fetch(account(.openDesign, host: host), token: "k", session: StubProtocol.session)
        #expect(models.map(\.id) == ["deepseek-v4-pro", "glm-5.3-flash", "house-model", "stated"])
        // What the list states wins; a model the public catalog does not know stays without a window.
        #expect(models.map(\.contextLength) == [1_000_000, 1_048_576, nil, 32_000])
    }

    @Test func thePublicCatalogFailingLeavesTheListAsTheProviderGaveIt() async throws {
        let host = "windows-offline.test"
        StubProtocol.queue(host: host, [.init(body: #"{"data":[{"id":"deepseek-v4-pro"}]}"#)])
        StubProtocol.queue(host: "models.dev", [.init(status: 404, body: "not found")])
        let models = try await ModelCatalog.fetch(account(.openDesign, host: host), token: "k", session: StubProtocol.session)
        #expect(models == [ProviderModel(id: "deepseek-v4-pro", name: "deepseek-v4-pro", format: .chat)])
    }

    @Test func aWindowThatIsThePlansOrTheLocalServersIsNotTakenFromThePublicCatalog() async throws {
        let host = "windows-local.test"
        StubProtocol.queue(host: host, [.init(body: #"{"data":[{"id":"deepseek-v4-pro"}]}"#)])
        StubProtocol.queue(host: "models.dev", [.init(body: catalog)])
        let models = try await ModelCatalog.fetch(account(.lmstudio, host: host), token: nil, session: StubProtocol.session)
        #expect(models.map(\.contextLength) == [nil])
        #expect(StubProtocol.sent(to: "models.dev").isEmpty)
        #expect([ProviderKind.chatgpt, .claudeCode, .ollama, .lmstudio].allSatisfy { !$0.takesPublicWindows })
        #expect([ProviderKind.openDesign, .xai, .openai, .anthropic, .custom, .openrouter].allSatisfy { $0.takesPublicWindows })
    }

    @Test func aListThatStatesEveryWindowDoesNotAskThePublicCatalog() async throws {
        let host = "windows-stated.test"
        StubProtocol.queue(host: host, [.init(body: #"{"data":[{"id":"deepseek-v4-pro","context_length":64000}]}"#)])
        StubProtocol.queue(host: "models.dev", [.init(body: catalog)])
        let models = try await ModelCatalog.fetch(account(.xai, host: host), token: "k", session: StubProtocol.session)
        #expect(models.map(\.contextLength) == [64_000])
        #expect(StubProtocol.sent(to: "models.dev").isEmpty)
    }

    @Test func ollamaIsAskedItsOwnListForTheModelsThatRunInTheCloud() async throws {
        let host = "windows-ollama.test"
        StubProtocol.queue(host: host, [.init(body: #"{"data":[{"id":"local:8b"},{"id":"big:cloud"}]}"#), .init(body: tags)])
        let models = try await ModelCatalog.fetch(account(.ollama, host: host), token: nil, session: StubProtocol.session)
        #expect(models.map(\.id) == ["big:cloud", "local:8b"])
        #expect(models.map(\.contextLength) == [1_048_576, nil])
        // Its own list lives beside `/v1`, not under it.
        #expect(StubProtocol.sent(to: host).compactMap { $0.request.url?.path() } == ["/v1/models", "/api/tags"])
    }

    @Test func anOllamaThatDoesNotAnswerItsOwnListStillListsItsModels() async throws {
        let host = "windows-ollama-old.test"
        StubProtocol.queue(host: host, [.init(body: #"{"data":[{"id":"big:cloud"}]}"#), .init(status: 404, body: "not found")])
        let models = try await ModelCatalog.fetch(account(.ollama, host: host), token: nil, session: StubProtocol.session)
        #expect(models == [ProviderModel(id: "big:cloud", name: "big:cloud", format: .chat)])
    }
}
