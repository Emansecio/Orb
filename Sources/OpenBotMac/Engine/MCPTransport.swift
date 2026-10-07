import Foundation

/// Carries JSON-RPC messages between `MCPConnection` and one MCP server.
protocol MCPTransport: Sendable {
    /// Connects. `receive` gets every message from the server; `closed` is called if the link dies on its own.
    func open(receive: @escaping @Sendable (JSONValue) async -> Void,
              closed: @escaping @Sendable (Error) async -> Void) async throws
    /// Delivers one message. Over HTTP this also reads the reply (handed to `receive`) before returning.
    func send(_ message: JSONValue) async throws
    func close() async
    /// Recent stderr output of a local server, to explain failures; empty for remote servers.
    var diagnostics: String { get async }
}

// MARK: - stdio

/// A local server process: newline-delimited JSON-RPC over stdin/stdout.
actor StdioTransport: MCPTransport {
    private let config: MCPServerConfig
    private var process: Process?
    private var input: FileHandle?
    private var stderrReader: Task<Void, Never>?
    private var closed: (@Sendable (Error) async -> Void)?
    private var buffer = Data()
    private var stderrTail = Data()

    init(config: MCPServerConfig) { self.config = config }

    deinit { process?.terminate() }

    func open(receive: @escaping @Sendable (JSONValue) async -> Void,
              closed: @escaping @Sendable (Error) async -> Void) throws {
        self.closed = closed
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
            for await chunk in output { await self?.receive(chunk, deliver: receive) }
            await self?.outputClosed()
        }
    }

    func send(_ message: JSONValue) throws {
        guard let input else { throw ToolError("O conector \(config.name) não está em execução.") }
        try input.write(contentsOf: Data((message.jsonString + "\n").utf8))
    }

    /// Closes the server's stdin and terminates it.
    func close() {
        closed = nil
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    var diagnostics: String {
        String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    private func receive(_ chunk: Data, deliver: @Sendable (JSONValue) async -> Void) async {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            // Anything that isn't a JSON object (e.g. stray log output) is ignored.
            if let message = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = message {
                await deliver(message)
            }
        }
    }

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > 4096 { stderrTail = Data(stderrTail.suffix(4096)) }
    }

    private func outputClosed() async {
        // Let stderr drain (briefly) so the error can say why the server died.
        if let stderrReader {
            let timer = Task { try? await Task.sleep(for: .seconds(1)); stderrReader.cancel() }
            await stderrReader.value
            timer.cancel()
        }
        let closed = self.closed
        close()
        let reason = diagnostics.isEmpty ? "." : ": \(diagnostics)"
        await closed?(ToolError("O conector \(config.name) foi encerrado\(reason)"))
    }
}

// MARK: - HTTP

/// A remote server over Streamable HTTP (2025-06-18), falling back to the legacy HTTP+SSE transport (2024-11-05)
/// when the server rejects the initialize POST.
actor HTTPTransport: MCPTransport {
    private let name: String
    private let url: URL
    private let headers: [String: String]
    private var receive: (@Sendable (JSONValue) async -> Void)?
    private var closed: (@Sendable (Error) async -> Void)?
    private var sessionID: String?
    private var protocolVersion: String?
    /// Legacy mode: the POST endpoint announced by the server and the task reading its event stream.
    private var legacyEndpoint: URL?
    private var legacyStream: Task<Void, Never>?

    /// Dedicated session: no disk cache, cookies kept in memory only, cross-host redirects refused.
    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    init(config: MCPServerConfig) throws {
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            // The URL itself is not quoted: it may carry an API key in its query.
            throw ToolError("O endereço do conector \(config.name) é inválido (use http:// ou https://).")
        }
        name = config.name
        self.url = url
        headers = config.headers
    }

    deinit { legacyStream?.cancel() }

    func open(receive: @escaping @Sendable (JSONValue) async -> Void,
              closed: @escaping @Sendable (Error) async -> Void) {
        self.receive = receive
        self.closed = closed
    }

    var diagnostics: String { "" }

    func send(_ message: JSONValue) async throws {
        do {
            if let legacyEndpoint {
                let (bytes, response) = try await load(legacyEndpoint, method: "POST", body: message)
                try await check(response, bytes)
            } else {
                try await post(message)
            }
        } catch let error as ToolError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ToolError("Não foi possível conectar ao conector \(name): \(error.localizedDescription)")
        }
    }

    /// Ends the session (best effort) and the legacy event stream.
    func close() async {
        receive = nil
        closed = nil
        legacyStream?.cancel()
        legacyStream = nil
        guard legacyEndpoint == nil, sessionID != nil else { return }
        _ = try? await load(url, method: "DELETE", timeout: 5)
        sessionID = nil
    }

    // MARK: Streamable HTTP

    private func post(_ message: JSONValue) async throws {
        let isInitialize = message["method"]?.string == "initialize"
        let (bytes, response) = try await load(url, method: "POST", body: message)
        if isInitialize, [400, 404, 405].contains(response.statusCode) {
            do {
                try await openLegacy()
            } catch is NoLegacyStream {
                try await check(response, bytes) // not a legacy server either: report why it refused initialize
            }
            return try await send(message)
        }
        if response.statusCode == 404, sessionID != nil {
            sessionID = nil
            let error = ToolError("A sessão com o conector \(name) expirou; reconecte o conector.")
            await closed?(error)
            throw error
        }
        try await check(response, bytes)
        if isInitialize { sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") }
        // Notifications and responses are acknowledged with 202 and no body.
        guard message["id"] != nil, message["method"] != nil, response.statusCode != 202 else { return }

        var answered = false
        if response.mimeType == "text/event-stream" {
            try await readEvents(bytes) { _, data in
                answered = await deliver(data, replyTo: message)
                return !answered
            }
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            answered = await deliver(String(decoding: data, as: UTF8.self), replyTo: message)
        }
        guard answered else { throw ToolError("O conector \(name) encerrou a resposta sem resultado.") }
    }

    /// Hands a message to the connection; true if it is the response to `request`.
    private func deliver(_ text: String, replyTo request: JSONValue? = nil) async -> Bool {
        guard let message = JSONValue.parse(text), case .object = message else { return false }
        let isReply = request != nil && message["method"] == nil && message["id"] == request?["id"]
        if isReply, request?["method"]?.string == "initialize" {
            protocolVersion = message["result"]?["protocolVersion"]?.string
        }
        await receive?(message)
        return isReply
    }

    // MARK: Legacy HTTP+SSE

    private struct NoLegacyStream: Error {}

    /// Opens the GET event stream and waits for the server to announce where to POST.
    private func openLegacy() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            legacyStream = Task { await readLegacyStream(ready: ready) }
        }
    }

    private func readLegacyStream(ready: CheckedContinuation<Void, Error>) async {
        var ready = Optional(ready)
        do {
            let (bytes, response) = try await load(url, method: "GET", timeout: 24 * 60 * 60)
            guard (200..<300).contains(response.statusCode) else { throw NoLegacyStream() }
            try await readEvents(bytes) { event, data in
                if event == "endpoint", let pending = ready {
                    guard let endpoint = URL(string: data, relativeTo: url)?.absoluteURL,
                          endpoint.host?.lowercased() == url.host?.lowercased(), endpoint.scheme == url.scheme else {
                        throw ToolError("O conector \(name) indicou um endereço em outro servidor; conexão recusada.")
                    }
                    legacyEndpoint = endpoint
                    ready = nil
                    pending.resume()
                } else if event == "message" {
                    _ = await deliver(data)
                }
                return true
            }
            throw ToolError("O conector \(name) encerrou a conexão.")
        } catch {
            if let ready {
                ready.resume(throwing: error)
            } else if !Task.isCancelled {
                let closed = self.closed
                legacyStream = nil
                await closed?(error as? ToolError ?? ToolError("O conector \(name) encerrou a conexão."))
            }
        }
    }

    // MARK: Plumbing

    private func load(_ target: URL, method: String, body: JSONValue? = nil,
                      timeout: TimeInterval = 300) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        // Per-request deadlines are enforced by MCPConnection, which cancels the request when they pass.
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpBody = Data(body.jsonString.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        } else if method == "GET" {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        if legacyEndpoint == nil {
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        }
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ToolError("O conector \(name) enviou uma resposta inválida.")
        }
        return (bytes, response)
    }

    /// Throws for non-2xx responses, quoting the start of the body (e.g. why a token was refused).
    private func check(_ response: HTTPURLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 300 { break }
        }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: response.statusCode) : body
        throw ToolError("O conector \(name) respondeu HTTP \(response.statusCode): \(detail)")
    }

    /// Server-Sent Events: calls `handle(event, data)` per event (multi-line data joined by "\n") until it returns false.
    private func readEvents(_ bytes: URLSession.AsyncBytes,
                            _ handle: (String, String) async throws -> Bool) async throws {
        var line = Data(), event = "", data: [String] = []
        for try await byte in bytes {
            guard byte == 0x0A else { line.append(byte); continue }
            if line.last == 0x0D { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                if !data.isEmpty, try await !handle(event.isEmpty ? "message" : event, data.joined(separator: "\n")) { return }
                event = ""
                data = []
                continue
            }
            let field = text.prefix { $0 != ":" }
            var value = text.dropFirst(field.count + 1)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            if field == "data" { data.append(String(value)) } else if field == "event" { event = String(value) }
        }
    }
}

/// Follows redirects only within the same host, so configured headers never reach another server.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased() ? request : nil
    }
}
