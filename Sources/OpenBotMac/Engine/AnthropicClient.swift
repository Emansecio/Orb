import Foundation

/// Client for the Anthropic Messages API (Claude with an API key, or any Anthropic-compatible gateway).
struct AnthropicClient: LLMClient {
    let baseURL: URL
    let apiKey: String?
    let session: URLSession
    /// Upper bound on the reply length (the API requires one).
    var maxTokens = 16_000

    static let apiVersion = "2023-06-01"

    init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest("messages")
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        Self.requestBody(model: model, messages: messages, tools: tools, maxTokens: maxTokens))

                    let (bytes, response) = try await session.bytes(for: request)
                    try await OpenAIClient.check(response, body: { try await OpenAIClient.prefix(of: bytes) })

                    var assembler = AnthropicStreamAssembler()
                    for try await line in bytes.lines {
                        guard case .data(let payload) = SSEParser.parse(line) else { continue }
                        guard let event = JSONValue.parse(payload) else {
                            throw LLMError.invalidResponse(String(payload.prefix(200)))
                        }
                        for output in try assembler.ingest(event) { continuation.yield(output) }
                        if assembler.isFinished { break }
                    }
                    if !assembler.toolCalls.isEmpty { continuation.yield(.toolCalls(assembler.toolCalls)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// All model ids (follows `has_more` / `last_id` pagination).
    func models() async throws -> [String] {
        var ids: [String] = []
        var after: String?
        for _ in 0..<20 {
            var request = makeRequest("models")
            var components = URLComponents(url: request.url ?? baseURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            request.url = components?.url
            let (data, response) = try await session.data(for: request)
            try await OpenAIClient.check(response, body: { data.prefix(OpenAIClient.errorBodyLimit) })
            guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), let page = json["data"]?.array else {
                throw LLMError.invalidResponse("lista de modelos ausente")
            }
            ids += page.compactMap { $0["id"]?.string }
            guard json["has_more"]?.bool == true, let last = json["last_id"]?.string else { break }
            after = last
        }
        return Array(Set(ids)).sorted()
    }

    private func makeRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        return request
    }
}

// MARK: - Wire format

extension AnthropicClient {
    /// System messages become the top-level `system`; tool results travel as `tool_result` blocks in a user turn;
    /// consecutive turns of the same role are merged (the API expects user/assistant alternation).
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], maxTokens: Int) -> JSONValue {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var turns: [(role: String, blocks: [JSONValue])] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "assistant" : "user"
            var blocks: [JSONValue] = []
            switch message.role {
            case .tool:
                blocks.append(.object(["type": .string("tool_result"), "tool_use_id": .string(message.toolCallID ?? ""),
                                       "content": .string(message.content.isEmpty ? "(sem saída)" : message.content)]))
            case .assistant:
                if !message.content.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(message.content)])) }
                for call in message.toolCalls {
                    let input = JSONValue.parse(call.arguments).flatMap { value -> JSONValue? in
                        if case .object = value { value } else { nil }
                    } ?? .object([:])
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
                                           "input": input]))
                }
            default:
                blocks.append(.object(["type": .string("text"), "text": .string(message.content)]))
            }
            guard !blocks.isEmpty else { continue }
            if turns.last?.role == role { turns[turns.count - 1].blocks += blocks } else { turns.append((role, blocks)) }
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "messages": .array(turns.map { .object(["role": .string($0.role), "content": .array($0.blocks)]) }),
        ]
        if !system.isEmpty { body["system"] = .string(system) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters])
            })
        }
        return .object(body)
    }
}

/// Turns Messages API stream events into `LLMEvent`s: text deltas pass through, `tool_use` blocks are assembled
/// from `input_json_delta` fragments and reported once at the end. Thinking blocks are ignored.
struct AnthropicStreamAssembler {
    private var calls: [Int: ToolCallRequest] = [:]
    private(set) var isFinished = false

    var toolCalls: [ToolCallRequest] { calls.sorted { $0.key < $1.key }.map(\.value) }

    mutating func ingest(_ event: JSONValue) throws -> [LLMEvent] {
        let index = event["index"]?.int ?? 0
        switch event["type"]?.string {
        case "content_block_start":
            if let block = event["content_block"], block["type"]?.string == "tool_use" {
                calls[index] = ToolCallRequest(id: block["id"]?.string ?? "call_\(index)", name: block["name"]?.string ?? "",
                                               arguments: "")
            }
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.string {
            case "text_delta":
                if let text = delta?["text"]?.string, !text.isEmpty { return [.text(text)] }
            case "input_json_delta":
                calls[index]?.arguments += delta?["partial_json"]?.string ?? ""
            default:
                break
            }
        case "message_stop":
            isFinished = true
        case "error":
            throw LLMError.invalidResponse(event["error"]?["message"]?.string ?? event.jsonString)
        default:
            break
        }
        return []
    }
}
