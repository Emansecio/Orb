import Foundation
import Testing
@testable import Orb

/// The bytes of a request depend only on what it says (so provider caches that match the rendered prefix hit), and a
/// request is the start of the one a step later.
struct RequestBodyTests {
    /// A schema whose keys are inserted in `order`, so every call builds dictionaries with their own layout.
    private func schema(order: [String]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for key in order { properties[key] = .object(["type": .string("string"), "description": .string("campo \(key)")]) }
        var object: [String: JSONValue] = [:]
        for key in ["type", "required", "properties", "additionalProperties"].shuffled() {
            switch key {
            case "type": object[key] = .string("object")
            case "required": object[key] = .array([.string("zeta"), .string("alfa")])
            case "properties": object[key] = .object(properties)
            default: object[key] = .bool(false)
            }
        }
        return .object(object)
    }

    private func tools() -> [ToolSpec] {
        let keys = ["zeta", "alfa", "mike", "bravo", "yankee", "charlie", "x", "delta", "echo", "foxtrot"]
        return (0..<4).map { index in
            ToolSpec(name: "tool_\(index)", description: "Ferramenta \(index)", parameters: schema(order: keys.shuffled()))
        }
    }

    /// Assistant turns whose tool calls carry `arguments` with several keys.
    private func history(steps: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = [.system("sys"), .user("faça isso")]
        for step in 0..<steps {
            let arguments = #"{"zeta":1,"alfa":"a","path":"p\#(step)","beta":{"y":2,"b":1}}"#
            messages.append(ChatMessage(role: .assistant, content: "passo \(step)",
                                        toolCalls: [ToolCallRequest(id: "c\(step)", name: "tool_0", arguments: arguments)]))
            messages.append(.tool("c\(step)", "saída \(step)"))
        }
        return messages
    }

    private func chat(_ messages: [ChatMessage], tools: [ToolSpec]) throws -> Data {
        try WireEncoder.encode(OpenAIClient.requestBody(model: "m", messages: messages, tools: tools, includeUsage: true,
                                                         promptCacheKey: "bot"), trailing: OpenAIClient.trailingKeys)
    }

    private func responses(_ messages: [ChatMessage], tools: [ToolSpec]) throws -> Data {
        try WireEncoder.encode(ResponsesClient.requestBody(model: "m", messages: messages, tools: tools, promptCacheKey: "bot"),
                               trailing: ResponsesClient.trailingKeys)
    }

    private func messagesFormat(_ messages: [ChatMessage], tools: [ToolSpec]) throws -> Data {
        try WireEncoder.encode(AnthropicClient.requestBody(model: "m", messages: messages, tools: tools, maxTokens: 100),
                               trailing: AnthropicClient.trailingKeys)
    }

    // MARK: Determinism

    @Test func theSameRequestIsTheSameBytesInEveryFormat() throws {
        let formats: [(String, ([ChatMessage], [ToolSpec]) throws -> Data)] = [
            ("chat", chat), ("responses", responses), ("messages", messagesFormat),
        ]
        for (name, encode) in formats {
            let first = try encode(history(steps: 3), tools())
            for _ in 0..<25 {
                // Specs and arguments rebuilt each time: every dictionary has its own layout.
                #expect(try encode(history(steps: 3), tools()) == first, "\(name)")
            }
        }
    }

    @Test func keysComeOutSorted() throws {
        let text = String(decoding: try chat(history(steps: 1), tools: tools()), as: UTF8.self)
        // Tool schema: required, then the properties alphabetically.
        let alfa = try #require(text.range(of: #""alfa":{"description""#)?.lowerBound)
        let bravo = try #require(text.range(of: #""bravo":{"description""#)?.lowerBound)
        let zeta = try #require(text.range(of: #""zeta":{"description""#)?.lowerBound)
        #expect(alfa < bravo && bravo < zeta)
        // The arguments of an old call are re-encoded from a dictionary on the Anthropic format; there they are sorted too.
        let anthropic = String(decoding: try messagesFormat(history(steps: 1), tools: []), as: UTF8.self)
        #expect(anthropic.contains(#""input":{"alfa":"a","beta":{"b":1,"y":2},"path":"p0","zeta":1}"#))
    }

    @Test func slashesAreNotEscaped() throws {
        let body = try chat([.system("s"), .user("veja /tmp/a e https://x.y/z")], tools: [])
        #expect(String(decoding: body, as: UTF8.self).contains("veja /tmp/a e https://x.y/z"))
    }

    // MARK: A request is the start of the next one

    /// The body without its last two characters, `]}`: what a longer conversation continues.
    private func opening(_ body: Data) -> Data { body.dropLast(2) }

    @Test func eachStepStartsWithTheBytesOfThePreviousStep() throws {
        let specs = tools()
        for steps in 1..<5 {
            let a = try chat(history(steps: steps), tools: specs)
            let b = try chat(history(steps: steps + 1), tools: specs)
            #expect(b.starts(with: opening(a)), "chat, step \(steps)")
            let c = try responses(history(steps: steps), tools: specs)
            let d = try responses(history(steps: steps + 1), tools: specs)
            #expect(d.starts(with: opening(c)), "responses, step \(steps)")
        }
    }

    @Test func theMessagesFormatKeepsItsPrefixOnceTheMovingCacheMarkerIsSetAside() throws {
        let specs = tools()
        func unmarked(_ messages: [ChatMessage]) throws -> Data {
            let body = AnthropicClient.requestBody(model: "m", messages: messages, tools: specs, maxTokens: 100)
            return try WireEncoder.encode(Self.removingMessageMarkers(from: body), trailing: AnthropicClient.trailingKeys)
        }
        for steps in 1..<5 {
            let a = try unmarked(history(steps: steps))
            let b = try unmarked(history(steps: steps + 1))
            #expect(b.starts(with: opening(a)), "step \(steps)")
        }
    }

    /// Takes the cache marker of the last message out (it moves with each step; the ones on the tools and the system
    /// prompt stay put and are part of the prefix).
    private static func removingMessageMarkers(from body: JSONValue) -> JSONValue {
        guard case .object(var object) = body, var turns = object["messages"]?.array else { return body }
        turns = turns.map { turn in
            guard case .object(var turnObject) = turn, let blocks = turnObject["content"]?.array else { return turn }
            turnObject["content"] = .array(blocks.map { block in
                guard case .object(var blockObject) = block else { return block }
                blockObject["cache_control"] = nil
                return .object(blockObject)
            })
            return .object(turnObject)
        }
        object["messages"] = .array(turns)
        return .object(object)
    }

    @Test func theConversationAndTheToolChoiceComeLast() throws {
        let none = try WireEncoder.encode(OpenAIClient.requestBody(model: "m", messages: history(steps: 1), tools: tools(), toolChoice: .none),
                                          trailing: OpenAIClient.trailingKeys)
        let auto = try WireEncoder.encode(OpenAIClient.requestBody(model: "m", messages: history(steps: 1), tools: tools()),
                                          trailing: OpenAIClient.trailingKeys)
        // The last step of a turn only adds `tool_choice` after the conversation: everything before it is the same.
        #expect(none.starts(with: opening(auto)))
        let text = String(decoding: none, as: UTF8.self)
        let tools = try #require(text.range(of: #""tools":"#)?.lowerBound)
        let messages = try #require(text.range(of: #""messages":"#)?.lowerBound)
        let choice = try #require(text.range(of: #""tool_choice":"#)?.lowerBound)
        #expect(tools < messages && messages < choice)
    }

    @Test func trailingKeysGoLastInTheOrderGivenAndMissingOnesAreIgnored() throws {
        let value = JSONValue.object(["b": .number(1), "z": .number(2), "a": .number(3), "messages": .array([]), "c": .bool(true)])
        let text = String(decoding: try WireEncoder.encode(value, trailing: ["messages", "tool_choice", "z"]), as: UTF8.self)
        #expect(text == #"{"a":3,"b":1,"c":true,"messages":[],"z":2}"#)
        // Without trailing keys, or for something that is not an object, it is plain sorted JSON.
        #expect(String(decoding: try WireEncoder.encode(value), as: UTF8.self) == #"{"a":3,"b":1,"c":true,"messages":[],"z":2}"#)
        #expect(String(decoding: try WireEncoder.encode(.array([.string("a/b")]), trailing: ["x"]), as: UTF8.self) == #"["a/b"]"#)
    }

    @Test func jsonStringUsesTheSameEncoding() {
        #expect(JSONValue.object(["b": .string("/x"), "a": .null]).jsonString == #"{"a":null,"b":"/x"}"#)
    }

    // MARK: Over the wire

    @Test func aClientSendsTheSameBytesForTheSameConversation() async throws {
        let host = "bytes-\(UUID().uuidString.prefix(8)).test"
        StubProtocol.queue(host: host, [.init(body: "data: [DONE]\n\n"), .init(body: "data: [DONE]\n\n")])
        let client = OpenAIClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: nil, session: StubProtocol.session)
        for _ in 0..<2 {
            for try await _ in client.stream(model: "m", messages: history(steps: 2), tools: tools()) {}
        }
        let sent = StubProtocol.sent(to: host)
        #expect(sent.count == 2)
        #expect(sent[0].text == sent[1].text && !sent[0].text.isEmpty)
    }

    @Test func theMessagesClientSendsSortedBodiesToo() async throws {
        let host = "msg-bytes-\(UUID().uuidString.prefix(8)).test"
        let done = #"data: {"type":"message_stop"}"# + "\n\n"
        StubProtocol.queue(host: host, [.init(body: done), .init(body: done)])
        let client = AnthropicClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "k", session: StubProtocol.session)
        for _ in 0..<2 {
            for try await _ in client.stream(model: "m", messages: history(steps: 2), tools: tools(), toolChoice: .auto) {}
        }
        let sent = StubProtocol.sent(to: host)
        #expect(sent.count == 2 && sent[0].text == sent[1].text)
        // Not the host that takes the one-hour life: the plain marker only.
        #expect(!sent[0].text.contains("\"ttl\""))
    }

    // MARK: Cache markers

    private func markers(in body: JSONValue) -> [(place: String, control: JSONValue)] {
        var found: [(String, JSONValue)] = []
        for (index, tool) in (body["tools"]?.array ?? []).enumerated() {
            if let control = tool["cache_control"] { found.append(("tool \(index)", control)) }
        }
        for block in body["system"]?.array ?? [] {
            if let control = block["cache_control"] { found.append(("system", control)) }
        }
        for (index, turn) in (body["messages"]?.array ?? []).enumerated() {
            for block in turn["content"]?.array ?? [] {
                if let control = block["cache_control"] { found.append(("message \(index)", control)) }
            }
        }
        return found
    }

    @Test func onAnthropicsOwnAPIThePartThatNeverChangesLivesAnHourAndTheTailFiveMinutes() {
        #expect(AnthropicClient.stablePrefixTTL(host: "api.anthropic.com") == .oneHour)
        let body = AnthropicClient.requestBody(model: "m", messages: history(steps: 2), tools: tools(), maxTokens: 10,
                                               stablePrefixTTL: .oneHour)
        let found = markers(in: body)
        #expect(found.map(\.place) == ["tool 3", "system", "message 4"])
        let hour = JSONValue.object(["type": .string("ephemeral"), "ttl": .string("1h")])
        #expect(found[0].control == hour && found[1].control == hour)
        #expect(found[2].control == .object(["type": .string("ephemeral")]))
        // The API wants the longer life first in the prompt (tools, system, then messages): it is.
    }

    @Test func otherHostsGetThePlainMarkerWithoutATTL() {
        for host in ["", "example.com", "openrouter.ai", "localhost", "api.anthropic.com.evil.test"] {
            #expect(AnthropicClient.stablePrefixTTL(host: host) == .fiveMinutes, "\(host)")
        }
        let body = AnthropicClient.requestBody(model: "m", messages: history(steps: 1), tools: tools(), maxTokens: 10)
        #expect(markers(in: body).allSatisfy { $0.control == .object(["type": .string("ephemeral")]) })
        #expect(!body.jsonString.contains("ttl"))
    }

    // MARK: The cache key

    @Test func theResponsesCacheKeyOnlyGoesToHostsThatTakeIt() async throws {
        let make = { (host: String) in ResponsesClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: nil, conversationID: "bot-1") }
        #expect(make("api.openai.com").sendsCacheKey)
        #expect(make("chatgpt.com").sendsCacheKey)
        for other in ["api.x.ai", "openrouter.ai", "localhost", "gateway.example.com", "api.openai.com.evil.test"] {
            #expect(!make(other).sendsCacheKey, "\(other)")
        }

        // On the wire: a gateway gets a body without the field, whatever the conversation id.
        let host = "gateway-\(UUID().uuidString.prefix(8)).test"
        StubProtocol.queue(host: host, [.init(body: #"data: {"type":"response.completed","response":{}}"# + "\n\n")])
        let client = ResponsesClient(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "k", conversationID: "bot-1",
                                     session: StubProtocol.session)
        for try await _ in client.stream(model: "m", messages: [.user("oi")], tools: []) {}
        let sent = try #require(StubProtocol.sent(to: host).first)
        #expect(sent.body?["prompt_cache_key"] == nil)
        #expect(sent.body?["input"] != nil)
    }

    @Test func theChatCacheKeyStaysForOpenAIOnly() {
        let openAI = OpenAIClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: nil, conversationID: "bot-1")
        #expect(openAI.isOpenAI)
        #expect(!OpenAIClient(baseURL: URL(string: "https://gateway.test/v1")!, apiKey: nil, conversationID: "bot-1").isOpenAI)
    }
}
