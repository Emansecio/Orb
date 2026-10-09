import Foundation

/// What a server says about one of its tools (`annotations` in `tools/list`). Hints, not guarantees: they only
/// decide whether Orb asks, never what the tool can really do.
struct MCPToolAnnotations: Codable, Sendable, Equatable {
    var readOnly: Bool?
    var destructive: Bool?
    var openWorld: Bool?

    static let none = MCPToolAnnotations()

    init(readOnly: Bool? = nil, destructive: Bool? = nil, openWorld: Bool? = nil) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.openWorld = openWorld
    }

    /// Reads the `annotations` object of a tool; wrong types are ignored.
    init(json: JSONValue?) {
        readOnly = json?["readOnlyHint"]?.bool
        destructive = json?["destructiveHint"]?.bool
        openWorld = json?["openWorldHint"]?.bool
    }
}

/// What a server says about itself when the session opens (the result of `initialize`).
struct MCPHandshake: Sendable, Equatable {
    var protocolVersion: String?
    var serverName: String?
    var serverVersion: String?
    var instructions: String?

    init() {}

    init(initializeResult result: JSONValue) {
        protocolVersion = result["protocolVersion"]?.string
        serverName = result["serverInfo"]?["name"]?.string
        serverVersion = result["serverInfo"]?["version"]?.string
        instructions = result["instructions"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

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
    /// Why the connection closed. Requests made afterwards report it: a fire-and-forget message (the reply to a ping, a
    /// cancellation) can be the one that finds out the session expired, with no request pending to tell.
    private var closedError: Error?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    /// The annotations of each tool from the last `tools/list`, by the server's own tool name.
    private(set) var toolAnnotations: [String: MCPToolAnnotations] = [:]
    /// What the server said in `initialize`.
    private(set) var handshake = MCPHandshake()
    /// Called when the server announces that its tools changed (`notifications/tools/list_changed`).
    private var onToolsChanged: (@Sendable () async -> Void)?
    /// Called once when the connection ends, whoever ended it (`stop()`, a crash, an expired session).
    private var onClosed: (@Sendable () async -> Void)?

    private let shell: ShellEnvironment

    init(config: MCPServerConfig, shell: ShellEnvironment = .shared) {
        self.config = config
        self.shell = shell
    }

    var isRunning: Bool { transport != nil }

    func setHandlers(toolsChanged: (@Sendable () async -> Void)?, closed: (@Sendable () async -> Void)?) {
        onToolsChanged = toolsChanged
        onClosed = closed
    }

    /// Connects to (or launches) the server, runs the MCP handshake and returns its tools.
    func start() async throws -> [ToolSpec] {
        guard !started else { throw ToolError("O conector \(config.name) já foi iniciado.") }
        started = true

        let transport: any MCPTransport = config.isRemote ? try HTTPTransport(config: config) : StdioTransport(config: config, shell: shell)
        self.transport = transport
        do {
            try await transport.open(receive: { [weak self] in await self?.handle($0) },
                                     closed: { [weak self] in await self?.shutdown($0) })
            handshake = MCPHandshake(initializeResult: try await request("initialize", .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Orb"), "version": .string("1.0")]),
            ]), timeout: .seconds(30)))
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

    /// The server's tools now (its annotations are updated too).
    func listTools() async throws -> [ToolSpec] {
        var specs: [ToolSpec] = []
        var annotations: [String: MCPToolAnnotations] = [:]
        var cursor: String?
        for _ in 0..<100 {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await request("tools/list", params)
            for tool in result["tools"]?.array ?? [] {
                guard let name = tool["name"]?.string else { continue }
                let schema = if case .object = tool["inputSchema"] { tool["inputSchema"] } else { JSONValue?.none }
                specs.append(ToolSpec(name: name, description: tool["description"]?.string ?? "",
                                      parameters: schema ?? .schema([:])))
                annotations[name] = MCPToolAnnotations(json: tool["annotations"])
            }
            cursor = result["nextCursor"]?.string
            if cursor == nil { break }
        }
        toolAnnotations = annotations
        return specs
    }

    private func request(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard let transport else { throw closedError ?? ToolError("O conector \(config.name) não está em execução.") }
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
            // Server→client request: answer pings, refuse the rest. Notifications are ignored, but for a change of tools.
            if method == "notifications/tools/list_changed", let onToolsChanged { Task { await onToolsChanged() } }
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
        if let transport {
            Task { await transport.close() }
            if let onClosed { Task { await onClosed() } }
        }
        transport = nil
        closedError = closedError ?? error
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
