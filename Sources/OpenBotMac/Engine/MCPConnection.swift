import Foundation

/// One MCP server process spoken to over stdio: JSON-RPC 2.0, one message per line.
/// Single use: after `stop()` (or a crash) create a new connection to restart.
actor MCPConnection {
    let config: MCPServerConfig

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
    }

    private var started = false
    private var process: Process?
    private var input: FileHandle?
    private var stderrReader: Task<Void, Never>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var buffer = Data()
    private var stderrTail = Data()

    init(config: MCPServerConfig) { self.config = config }

    deinit { process?.terminate() }

    var isRunning: Bool { process != nil }

    /// Launches the server, runs the MCP handshake and returns its tools.
    func start() async throws -> [ToolSpec] {
        guard !started else { throw ToolError("O conector \(config.name) já foi iniciado.") }
        started = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so Finder-launched apps still find the user's PATH; command and arguments stay argv, never script text.
        process.arguments = ["-lc", #"exec "$0" "$@""#, config.command] + config.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(config.environment) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing to a dead server must fail with EPIPE instead of killing the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw ToolError("Não foi possível iniciar o conector \(config.name): \(error.localizedDescription)")
        }
        self.process = process
        input = stdin.fileHandleForWriting

        let output = Self.chunks(stdout.fileHandleForReading)
        let errors = Self.chunks(stderr.fileHandleForReading)
        stderrReader = Task { [weak self] in
            for await chunk in errors { await self?.appendStderr(chunk) }
        }
        Task { [weak self] in
            for await chunk in output { await self?.receive(chunk) }
            await self?.outputClosed()
        }

        do {
            _ = try await request("initialize", .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("OpenBot"), "version": .string("1.0")]),
            ]), timeout: .seconds(30))
            try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
            return try await listTools()
        } catch {
            stop()
            let detail = stderrText.isEmpty ? error.localizedDescription : stderrText
            throw ToolError("Não foi possível iniciar o conector \(config.name): \(detail)")
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

    /// Closes the server's stdin, terminates it and fails pending requests.
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
        guard process != nil else { throw ToolError("O conector \(config.name) não está em execução.") }
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
                pending[id] = Pending(continuation: continuation, timer: timer)
                do { try send(message) } catch { fail(id, error) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let input else { throw ToolError("O conector \(config.name) não está em execução.") }
        try input.write(contentsOf: Data((message.jsonString + "\n").utf8))
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func cancel(_ id: Int) {
        guard pending[id] != nil else { return }
        fail(id, CancellationError())
        try? send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                           "params": .object(["requestId": .number(Double(id))])]))
    }

    // MARK: Reading

    /// Bytes from a pipe as they arrive; finishes at EOF.
    private static func chunks(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            // Anything that isn't a JSON object (e.g. stray log output) is ignored.
            if let message = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = message {
                handle(message)
            }
        }
    }

    private func handle(_ message: JSONValue) {
        if let method = message["method"]?.string {
            // Server→client request: answer pings, refuse the rest. Notifications are ignored.
            guard let id = message["id"], id != .null else { return }
            let reply: (String, JSONValue) = method == "ping"
                ? ("result", .object([:]))
                : ("error", .object(["code": .number(-32601), "message": .string("Method not found: \(method)")]))
            try? send(.object(["jsonrpc": .string("2.0"), "id": id, reply.0: reply.1]))
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

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > 4096 { stderrTail = Data(stderrTail.suffix(4096)) }
    }

    private var stderrText: String {
        String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func outputClosed() async {
        // Let stderr drain (briefly) so the error can say why the server died.
        if let stderrReader {
            let timer = Task { try? await Task.sleep(for: .seconds(1)); stderrReader.cancel() }
            await stderrReader.value
            timer.cancel()
        }
        let reason = stderrText.isEmpty ? "." : ": \(stderrText)"
        shutdown(ToolError("O conector \(config.name) foi encerrado\(reason)"))
    }

    private func shutdown(_ error: Error) {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        let entries = pending.values
        pending = [:]
        for entry in entries {
            entry.timer.cancel()
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
