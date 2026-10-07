import Foundation

/// One MCP server, local (stdio) or remote (HTTP), spoken to with JSON-RPC 2.0.
/// Single use: after `stop()` (or a crash) create a new connection to restart.
actor MCPConnection {
    let config: MCPServerConfig

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
        let sender: Task<Void, Never>
    }

    private var started = false
    private var transport: (any MCPTransport)?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1

    init(config: MCPServerConfig) { self.config = config }

    var isRunning: Bool { transport != nil }

    /// Connects to (or launches) the server, runs the MCP handshake and returns its tools.
    func start() async throws -> [ToolSpec] {
        guard !started else { throw ToolError("O conector \(config.name) já foi iniciado.") }
        started = true

        let transport: any MCPTransport = config.isRemote ? try HTTPTransport(config: config) : StdioTransport(config: config)
        self.transport = transport
        do {
            try await transport.open(receive: { [weak self] in await self?.handle($0) },
                                     closed: { [weak self] in await self?.shutdown($0) })
            _ = try await request("initialize", .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("OpenBot"), "version": .string("1.0")]),
            ]), timeout: .seconds(30))
            try await transport.send(notification("notifications/initialized"))
            return try await listTools()
        } catch {
            let detail = await transport.diagnostics
            stop()
            // Transport errors already name the connector; stderr explains a local server's failure best.
            if detail.isEmpty, error is ToolError { throw error }
            throw ToolError("Não foi possível iniciar o conector \(config.name): \(detail.isEmpty ? error.localizedDescription : detail)")
        }
    }

    /// Calls a tool and returns its text content. Throws `ToolError` when the tool reports an error.
    func call(_ name: String, arguments: JSONValue, timeout: Duration = .seconds(60)) async throws -> String {
        let arguments = if case .object = arguments { arguments } else { JSONValue.object([:]) }
        let result = try await request("tools/call", .object(["name": .string(name), "arguments": arguments]),
                                       timeout: timeout)
        let text = Self.text(of: result)
        if result["isError"]?.bool == true { throw ToolError(text.isEmpty ? "\(name) falhou." : text) }
        return text
    }

    /// Disconnects (terminating a local server) and fails pending requests.
    func stop() {
        shutdown(ToolError("O conector \(config.name) foi desligado."))
    }

    // MARK: Requests

    private func listTools() async throws -> [ToolSpec] {
        var specs: [ToolSpec] = []
        var cursor: String?
        for _ in 0..<100 {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await request("tools/list", params)
            for tool in result["tools"]?.array ?? [] {
                guard let name = tool["name"]?.string else { continue }
                let schema = if case .object = tool["inputSchema"] { tool["inputSchema"] } else { JSONValue?.none }
                specs.append(ToolSpec(name: name, description: tool["description"]?.string ?? "",
                                      parameters: schema ?? .schema([:])))
            }
            cursor = result["nextCursor"]?.string
            if cursor == nil { break }
        }
        return specs
    }

    private func request(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard let transport else { throw ToolError("O conector \(config.name) não está em execução.") }
        let id = nextID
        nextID += 1
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                        "method": .string(method), "params": params])
        let timeoutError = ToolError("O conector \(config.name) não respondeu a tempo (\(method)).")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.fail(id, timeoutError)
                }
                // The reply arrives through `handle`; over HTTP the sender lives until it does.
                let sender = Task {
                    do { try await transport.send(message) } catch { self.fail(id, error) }
                }
                pending[id] = Pending(continuation: continuation, timer: timer, sender: sender)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func notification(_ method: String, _ params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }

    /// Fire-and-forget message (cancellations, replies to the server).
    private func sendDetached(_ message: JSONValue) {
        guard let transport else { return }
        Task { try? await transport.send(message) }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.sender.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func cancel(_ id: Int) {
        guard pending[id] != nil else { return }
        fail(id, CancellationError())
        sendDetached(notification("notifications/cancelled", .object(["requestId": .number(Double(id))])))
    }

    // MARK: Receiving

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.string {
            // Server→client request: answer pings, refuse the rest. Notifications are ignored.
            guard let id = message["id"], id != .null else { return }
            let reply: (String, JSONValue) = method == "ping"
                ? ("result", .object([:]))
                : ("error", .object(["code": .number(-32601), "message": .string("Method not found: \(method)")]))
            sendDetached(.object(["jsonrpc": .string("2.0"), "id": id, reply.0: reply.1]))
            return
        }
        guard let id = message["id"]?.int, let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        if let error = message["error"] {
            let detail = error["message"]?.string ?? "erro desconhecido"
            entry.continuation.resume(throwing: ToolError("O conector \(config.name) respondeu com erro: \(detail)"))
        } else {
            entry.continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func shutdown(_ error: Error) {
        if let transport { Task { await transport.close() } }
        transport = nil
        let entries = pending.values
        pending = [:]
        for entry in entries {
            entry.timer.cancel()
            entry.sender.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    /// Text for the model from a `tools/call` result; non-text content is described briefly.
    static func text(of result: JSONValue) -> String {
        let parts = (result["content"]?.array ?? []).map { item -> String in
            switch item["type"]?.string {
            case "text": item["text"]?.string ?? ""
            case "image": "[imagem]"
            case "audio": "[áudio]"
            case "resource": item["resource"]?["text"]?.string ?? "[recurso: \(item["resource"]?["uri"]?.string ?? "?")]"
            case "resource_link": "[link: \(item["uri"]?.string ?? "?")]"
            case let type: "[\(type ?? "conteúdo")]"
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { return structured.jsonString }
        return parts.joined(separator: "\n")
    }
}
