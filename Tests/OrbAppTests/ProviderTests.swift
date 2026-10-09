import Foundation
import os
import Testing
@testable import Orb

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
        #expect(OAuthLoopback.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
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
        let client = try #require(account.client(for: account.models[0], credentials: { _ in "k" }, conversationID: "abc") as? OpenAIClient)
        #expect(client.extraHeaders["x-opencode-session"] == "abc")
        let messages = ProviderModel(id: "claude-haiku-5-5", name: "Claude", format: .messages)
        #expect(account.client(for: messages, credentials: { _ in "k" }, conversationID: "abc") is AnthropicClient)
    }
}

struct ProviderExpansionTests {
    @Test func remembersOpenAndClosedProviders() {
        let state = ProviderExpansion.parse("xai:0,claudeCode:1,nope:1,quebrado")
        #expect(state == [.xai: false, .claudeCode: true])
        #expect(ProviderExpansion.parse("").isEmpty)
    }
}

struct CustomProviderTests {
    @Test func oldAccountsWithoutFormatOrHeadersStillDecode() throws {
        let json = #"{"kind":"custom","baseURL":"http://127.0.0.1:8080/v1","isEnabled":true,"models":[]}"#
        let account = try JSONDecoder().decode(ProviderAccount.self, from: Data(json.utf8))
        #expect(account.format == .chat)
        #expect(account.headers.isEmpty)
    }

    @Test func customClientUsesChosenFormatAndHeaders() throws {
        var account = ProviderAccount(kind: .custom)
        account.baseURL = "http://127.0.0.1:8080/v1"
        account.format = .messages
        account.headers = ["X-Gateway-Token": "abc"]
        account.models = [ProviderModel(id: "claude-x", name: "Claude X", format: .messages)]
        let client = try #require(account.client(for: account.models[0], credentials: { _ in nil }, conversationID: "c") as? AnthropicClient)
        #expect(client.extraHeaders["X-Gateway-Token"] == "abc")
    }

    @Test func customChatFormatKeepsOpenAIClientWithHeaders() throws {
        var account = ProviderAccount(kind: .custom)
        account.baseURL = "http://127.0.0.1:8080/v1"
        account.headers = ["Authorization": "Bearer t"]
        let model = ProviderModel(id: "m", name: "m", format: .chat)
        let client = try #require(account.client(for: model, credentials: { _ in nil }, conversationID: "c") as? OpenAIClient)
        #expect(client.extraHeaders["Authorization"] == "Bearer t")
    }
}

struct ProviderClientTests {
    @Test func clientsKeyTheirPromptCacheToTheConversation() throws {
        var openai = ProviderAccount(kind: .openai)
        openai.models = [ProviderModel(id: "gpt-x", name: "x", format: .responses)]
        let responses = try #require(openai.client(for: openai.models[0], credentials: { _ in "k" }, conversationID: "bot-1") as? ResponsesClient)
        #expect(responses.conversationID == "bot-1")
        let chat = try #require(openai.client(for: ProviderModel(id: "m", name: "m", format: .chat), credentials: { _ in "k" },
                                              conversationID: "bot-1") as? OpenAIClient)
        #expect(chat.conversationID == "bot-1")
        #expect(chat.isOpenAI) // so it sends the key
        let local = try #require(ProviderAccount(kind: .ollama).client(for: ProviderModel(id: "m", name: "m", format: .chat),
                                                                       credentials: { _ in nil }, conversationID: "bot-1") as? OpenAIClient)
        #expect(!local.isOpenAI && !local.reportsUsage) // local servers get neither the key nor stream_options
    }

    @Test func clientsAskForTheCredentialAtRequestTime() async throws {
        let account = ProviderAccount(kind: .openai)
        let current = Box<String?>("first")
        let client = try #require(account.client(for: ProviderModel(id: "m", name: "m", format: .chat),
                                                 credentials: { _ in current.value }, conversationID: "c") as? OpenAIClient)
        #expect(try await client.credentials(false) == "first")
        current.value = "second"
        #expect(try await client.credentials(false) == "second")
    }

    @Test func claudeCodeModelsHaveNoHTTPClient() {
        var account = ProviderAccount(kind: .claudeCode)
        account.baseURL = "http://127.0.0.1:1/v1"
        #expect(account.client(for: ProviderModel(id: "opus", name: "Opus", format: .claudeCode), credentials: { _ in nil }, conversationID: "c") == nil)
    }
}

struct ChatGPTAuthTests {
    private static let tokenReply = #"{"access_token":"access-2","refresh_token":"refresh-2","id_token":"id","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#

    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        init(_ credential: ChatGPTCredential?) { text = credential.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } }
        var storage: ChatGPTAuth.Storage {
            .init(load: { self.lock.withLock { self.text } }, save: { value in self.lock.withLock { self.text = value.isEmpty ? nil : value } })
        }
        var saved: String? { lock.withLock { text } }
    }

    private func credential(expiresIn seconds: TimeInterval) -> ChatGPTCredential {
        ChatGPTCredential(clientID: "oaiapp_test", accessToken: "access-1", refreshToken: "refresh-1", idToken: "id",
                          expiresAt: .now.addingTimeInterval(seconds), scopes: ["chatgpt.tokens.use.direct"])
    }

    private func auth(host: String, disk: Disk) -> ChatGPTAuth {
        ChatGPTAuth(storage: disk.storage, tokenURL: URL(string: "https://\(host)/oauth/token")!, session: StubProtocol.session)
    }

    @Test func aFreshTokenIsReturnedWithoutTouchingTheNetwork() async throws {
        let auth = auth(host: "auth-fresh.test", disk: Disk(credential(expiresIn: 3600)))
        StubProtocol.queue(host: "auth-fresh.test", [])
        #expect(try await auth.accessToken() == "access-1")
        #expect(StubProtocol.sent(to: "auth-fresh.test").isEmpty)
    }

    @Test func anExpiringTokenIsRefreshedAndSaved() async throws {
        let disk = Disk(credential(expiresIn: 60))
        let auth = auth(host: "auth-expiring.test", disk: disk)
        StubProtocol.queue(host: "auth-expiring.test", [.init(body: Self.tokenReply)])
        #expect(try await auth.accessToken() == "access-2")
        #expect(disk.saved?.contains("refresh-2") == true)
        #expect(try await auth.accessToken() == "access-2")
        #expect(StubProtocol.sent(to: "auth-expiring.test").count == 1)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let auth = auth(host: "auth-single.test", disk: Disk(credential(expiresIn: 30)))
        StubProtocol.queue(host: "auth-single.test", [.init(body: Self.tokenReply), .init(status: 400, body: #"{"error":"invalid_grant"}"#)])
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        async let third = auth.accessToken(forceRefresh: true)
        let tokens = try await [first, second, third]
        #expect(tokens == ["access-2", "access-2", "access-2"])
        // One call to the token endpoint, with the original refresh token: a rotated token must never be used twice.
        let sent = StubProtocol.sent(to: "auth-single.test")
        #expect(sent.count == 1)
        #expect(sent.first?.text.contains("refresh_token=refresh-1") == true)
    }

    @Test func forcingARefreshReplacesATokenTheAPIRejected() async throws {
        let auth = auth(host: "auth-force.test", disk: Disk(credential(expiresIn: 3600)))
        StubProtocol.queue(host: "auth-force.test", [.init(body: Self.tokenReply)])
        #expect(try await auth.accessToken() == "access-1")
        #expect(try await auth.accessToken(forceRefresh: true) == "access-2")
        // A second rejection right after reuses the token that was just issued instead of rotating again.
        #expect(try await auth.accessToken(forceRefresh: true) == "access-2")
        #expect(StubProtocol.sent(to: "auth-force.test").count == 1)
    }

    @Test func aFailedRefreshReachesEveryWaiterAndCanBeRetried() async throws {
        let auth = auth(host: "auth-fail.test", disk: Disk(credential(expiresIn: 30)))
        StubProtocol.queue(host: "auth-fail.test", [.init(status: 400, body: #"{"error":"invalid_grant"}"#), .init(body: Self.tokenReply)])
        async let first: String = auth.accessToken()
        async let second: String = auth.accessToken()
        do {
            _ = try await (first, second)
            Issue.record("should have thrown")
        } catch let error as ToolError {
            #expect(error.message.contains("expirou"))
        }
        #expect(StubProtocol.sent(to: "auth-fail.test").count == 1)
        #expect(try await auth.accessToken() == "access-2")
    }

    @Test func signingOutDuringARefreshKeepsTheLoginGone() async throws {
        let disk = Disk(credential(expiresIn: 30))
        let auth = ChatGPTAuth(storage: disk.storage, tokenURL: URL(string: "https://auth-race.test/oauth/token")!, session: HeldProtocol.session)
        let token = Task { try await auth.accessToken() }
        await waitUntil("the refresh to reach the token endpoint") { HeldProtocol.pending > 0 }
        await auth.signOut()
        HeldProtocol.release(body: Self.tokenReply)
        // The turn that was waiting for the token is told the login is gone, not handed a raw cancellation.
        let outcome = await token.result
        #expect({ if case .failure(let error) = outcome { error as? LLMError == .notConfigured } else { false } }())
        #expect(await auth.credential == nil)
        #expect(disk.saved == nil)
        await #expect(throws: LLMError.notConfigured) { try await auth.accessToken() }
    }

    @Test func cancellingTheSignInEndsTheWaitForTheBrowser() async throws {
        // The "Cancelar" button cancels the sign-in task; the loopback wait must end at once, not after its 5 minutes.
        let callback = try await LoopbackCallback.open(path: "/auth/callback")
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(300)) }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }

    @Test func signedOutThrowsNotConfigured() async {
        let auth = auth(host: "auth-none.test", disk: Disk(nil))
        await #expect(throws: LLMError.notConfigured) { try await auth.accessToken() }
    }
}

/// A token endpoint that answers only when the test lets it, to sign out while a refresh is in flight.
private final class HeldProtocol: URLProtocol {
    /// The loading protocol objects are not Sendable; they are only touched under the lock or to answer.
    private struct Held: @unchecked Sendable { var request: HeldProtocol }
    private static let held = OSAllocatedUnfairLock<[Held]>(initialState: [])

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var pending: Int { held.withLock { $0.count } }

    static func release(body: String) {
        let requests = held.withLock { list in
            let all = list
            list.removeAll()
            return all
        }
        for held in requests {
            let request = held.request
            guard let url = request.request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { continue }
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: Data(body.utf8))
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { let me = Held(request: self); Self.held.withLock { $0.append(me) } }
    override func stopLoading() { let me = Held(request: self); Self.held.withLock { list in list.removeAll { $0.request === me.request } } }
}
