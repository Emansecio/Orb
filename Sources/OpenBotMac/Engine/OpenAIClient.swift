import Foundation

/// Client for OpenAI-compatible Chat Completions APIs (xAI, OpenAI, OpenRouter, Ollama, LM Studio).
struct OpenAIClient: LLMClient {
    let baseURL: URL
    let apiKey: String?
    let session: URLSession

    init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest("chat/completions")
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300 // local models can take long before the first token
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(Self.requestBody(model: model, messages: messages, tools: tools))

                    let (bytes, response) = try await session.bytes(for: request)
                    try await Self.check(response, body: { try await Self.prefix(of: bytes) })

                    var toolCalls = ToolCallAccumulator()
                    lines: for try await line in bytes.lines {
                        switch SSEParser.parse(line) {
                        case nil: continue
                        case .done: break lines
                        case .data(let payload):
                            guard let chunk = JSONValue.parse(payload) else {
                                throw LLMError.invalidResponse(String(payload.prefix(200)))
                            }
                            if let error = chunk["error"] {
                                throw LLMError.invalidResponse(Self.message(in: error) ?? error.jsonString)
                            }
                            guard let delta = chunk["choices"]?.array?.first?["delta"] else { continue }
                            if let text = delta["content"]?.string, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            if let fragments = delta["tool_calls"]?.array {
                                toolCalls.ingest(fragments)
                            }
                        }
                    }
                    let calls = toolCalls.requests
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func models() async throws -> [String] {
        let (data, response) = try await session.data(for: makeRequest("models"))
        try await Self.check(response, body: { data.prefix(Self.errorBodyLimit) })
        guard let entries = JSONValue.parse(String(decoding: data, as: UTF8.self))?["data"]?.array else {
            throw LLMError.invalidResponse("lista de modelos ausente")
        }
        return Set(entries.compactMap { $0["id"]?.string }).sorted()
    }

    private func makeRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Wire format

extension OpenAIClient {
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "messages": .array(messages.map(wire)),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object(["type": .string("function"), "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ])])
            })
        }
        return .object(body)
    }

    static func wire(_ message: ChatMessage) -> JSONValue {
        let onlyCalls = message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": onlyCalls ? JSONValue.null : .string(message.content),
        ]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"), "function": .object([
                    "name": .string(call.name),
                    // Some providers reject an empty arguments string.
                    "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments),
                ])])
            })
        }
        if message.role == .tool, let id = message.toolCallID {
            object["tool_call_id"] = .string(id)
        }
        return .object(object)
    }

    // MARK: Errors

    static let errorBodyLimit = 2048

    /// Throws `LLMError.http` for non-2xx responses, using the (lazily read) body as the message.
    static func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("resposta não HTTP")
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw LLMError.http(status: http.statusCode, message: errorMessage(from: try await body(), status: http.statusCode))
    }

    /// `error.message` (OpenAI), `error` as a string (Ollama) or `message`; otherwise the raw text.
    static func errorMessage(from data: Data, status: Int) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = JSONValue.parse(text), let message = message(in: json["error"] ?? json) {
            return message
        }
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
    }

    private static func message(in error: JSONValue) -> String? {
        error.string ?? error["message"]?.string
    }

    /// The start of an error body (enough for the message, without reading huge responses).
    static func prefix(of bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= errorBodyLimit { break }
        }
        return data
    }
}

// MARK: - Streaming helpers

/// Line-level Server-Sent Events parsing (one `data:` line per event, as chat-completions providers send).
enum SSEParser {
    enum Line: Equatable {
        case data(String)
        case done
    }

    /// The event carried by `line`; nil for comments, blank lines and other fields.
    static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty { return nil }
        return payload == "[DONE]" ? .done : .data(payload)
    }
}

/// Assembles streamed `delta.tool_calls` fragments: id/name come first, `arguments` arrive in pieces.
struct ToolCallAccumulator {
    private var calls: [Int: ToolCallRequest] = [:]

    mutating func ingest(_ fragments: [JSONValue]) {
        for fragment in fragments {
            // Providers that omit `index` send one call per id.
            let index = fragment["index"]?.int ?? (fragment["id"] == nil ? max(calls.count - 1, 0) : calls.count)
            var call = calls[index] ?? ToolCallRequest(id: "", name: "", arguments: "")
            if let id = fragment["id"]?.string, !id.isEmpty { call.id = id }
            if let name = fragment["function"]?["name"]?.string, !name.isEmpty { call.name = name }
            if let arguments = fragment["function"]?["arguments"] {
                if let piece = arguments.string { call.arguments += piece }
                else if arguments != .null { call.arguments = arguments.jsonString } // some local servers send an object
            }
            calls[index] = call
        }
    }

    /// Completed calls ordered by index; missing ids get a stable placeholder.
    var requests: [ToolCallRequest] {
        calls.sorted { $0.key < $1.key }.compactMap { index, call in
            guard !call.name.isEmpty else { return nil }
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)" }
            return call
        }
    }
}
