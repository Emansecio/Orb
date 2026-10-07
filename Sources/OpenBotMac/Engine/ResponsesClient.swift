import Foundation

/// Client for the OpenAI Responses API (`POST {base}/responses`), used by GPT/Grok-class models that
/// providers only serve there. Stateless (`store: false`): the full history is sent every turn.
struct ResponsesClient: LLMClient {
    let baseURL: URL
    let apiKey: String?
    var extraHeaders: [String: String] = [:]
    /// Send tools as an `additional_tools` input item (required by Sign in with ChatGPT) instead of top-level `tools`.
    var toolsAsInputItem = false
    let session: URLSession

    init(baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:], toolsAsInputItem: Bool = false,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.extraHeaders = extraHeaders
        self.toolsAsInputItem = toolsAsInputItem
        self.session = session
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = OpenAIClient.authorizedRequest(baseURL.appending(path: "responses"), apiKey: apiKey,
                                                                 headers: extraHeaders)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(
                        Self.requestBody(model: model, messages: messages, tools: tools, toolsAsInputItem: toolsAsInputItem))

                    let (bytes, response) = try await session.bytes(for: request)
                    try await OpenAIClient.check(response, body: { try await OpenAIClient.prefix(of: bytes) })

                    var assembler = ResponsesStreamAssembler()
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

    func models() async throws -> [String] {
        try await OpenAIClient(baseURL: baseURL, apiKey: apiKey, session: session).models()
    }

    /// System messages become `instructions`; tool calls and results become `function_call` /
    /// `function_call_output` items.
    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolSpec], toolsAsInputItem: Bool = false) -> JSONValue {
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var input: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                input.append(.object(["role": .string("user"), "content": .string(message.content)]))
            case .assistant:
                if !message.content.isEmpty {
                    input.append(.object(["role": .string("assistant"), "content": .string(message.content)]))
                }
                for call in message.toolCalls {
                    input.append(.object(["type": .string("function_call"), "call_id": .string(call.id),
                                          "name": .string(call.name),
                                          "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)]))
                }
            case .tool:
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(message.toolCallID ?? ""),
                                      "output": .string(message.content)]))
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "input": .array(input), "stream": .bool(true), "store": .bool(false),
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        let functions = JSONValue.array(tools.map {
            .object(["type": .string("function"), "name": .string($0.name), "description": .string($0.description),
                     "parameters": $0.parameters, "strict": .bool(false)])
        })
        if !tools.isEmpty {
            if toolsAsInputItem {
                input.insert(.object(["type": .string("additional_tools"), "role": .string("developer"), "tools": functions]), at: 0)
                body["input"] = .array(input)
            } else {
                body["tools"] = functions
            }
        }
        return .object(body)
    }
}

/// Turns Responses API stream events into `LLMEvent`s; function calls are reported once, when complete.
struct ResponsesStreamAssembler {
    private var calls: [Int: ToolCallRequest] = [:]
    private(set) var isFinished = false

    var toolCalls: [ToolCallRequest] { calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty } }

    mutating func ingest(_ event: JSONValue) throws -> [LLMEvent] {
        let index = event["output_index"]?.int ?? 0
        switch event["type"]?.string {
        case "response.output_text.delta":
            if let text = event["delta"]?.string, !text.isEmpty { return [.text(text)] }
        case "response.output_item.added", "response.output_item.done":
            if let item = event["item"], item["type"]?.string == "function_call" {
                var call = calls[index] ?? ToolCallRequest(id: "", name: "", arguments: "")
                call.id = item["call_id"]?.string ?? item["id"]?.string ?? "call_\(index)"
                call.name = item["name"]?.string ?? call.name
                if let arguments = item["arguments"]?.string, !arguments.isEmpty { call.arguments = arguments }
                calls[index] = call
            }
        case "response.function_call_arguments.delta":
            calls[index]?.arguments += event["delta"]?.string ?? ""
        case "response.function_call_arguments.done":
            if let arguments = event["arguments"]?.string { calls[index]?.arguments = arguments }
        case "response.completed", "response.incomplete":
            isFinished = true
        case "response.failed":
            throw LLMError.invalidResponse(event["response"]?["error"]?["message"]?.string ?? "a resposta falhou")
        case "error":
            throw LLMError.invalidResponse(event["message"]?.string ?? event["error"]?["message"]?.string ?? event.jsonString)
        default:
            break
        }
        return []
    }
}
