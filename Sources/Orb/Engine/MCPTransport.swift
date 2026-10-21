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
    /// The server's pid, which is also its process group.
    private var pid: pid_t?
    private var input: FileHandle?
    /// Kept so the readers' descriptors stay open for as long as the server may write.
    private var outputs: [Pipe] = []
    private var stderrReader: Task<Void, Never>?
    private var closed: (@Sendable (Error) async -> Void)?
    private var buffer = Data()
    /// How much of `buffer` is already known to hold no newline, so each chunk is searched only from where the last one ended.
    private var scanned = 0
    private var stderrTail = Data()

    private let shell: ShellEnvironment
    private let registry: StdioServerRegistry
    /// How long a server may take to leave after SIGTERM before it is killed.
    private let killGrace: Duration
    /// The longest output a server may write without a newline; past it the connection is closed.
    private let maxLineBytes: Int
    /// Writes to the server's stdin happen here, never on the actor: a server that stops reading blocks `write(2)` once the
    /// pipe is full, and `close` must still be able to run to kill it.
    private let writes = DispatchQueue(label: "app.orb.mcp.stdio-writes")

    init(config: MCPServerConfig, shell: ShellEnvironment = .shared, registry: StdioServerRegistry = .shared,
         killGrace: Duration = .seconds(3), maxLineBytes: Int = 32 << 20) {
        self.config = config
        self.shell = shell
        self.registry = registry
        self.killGrace = killGrace
        self.maxLineBytes = maxLineBytes
    }

    deinit { pid.map { registry.end($0, grace: killGrace) } }

    /// The server's process id while it runs.
    var processID: pid_t? { pid }

    func open(receive: @escaping @Sendable (JSONValue) async -> Void,
              closed: @escaping @Sendable (Error) async -> Void) async throws {
        self.closed = closed
        // The user's Terminal environment, so `npx`/`uvx` installed through `.zshrc` (nvm, fnm, Volta) are found
        // when the app is opened from the Finder, as for commands and for Claude Code.
        let resolved = await shell.resolved()
        guard self.closed != nil else { throw ToolError("O conector \(config.name) foi desligado.") } // stopped while asking
        let env = resolved.environment.merging(config.environment) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        // Writing to a dead server must fail with EPIPE instead of killing the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Command and arguments stay argv, never script text. The resolved environment already carries the profile files'
        // PATH; when the user's shell could not be asked, a login shell stands in so the system paths are still found.
        // The server leads a process group of its own, so ending it also ends what `npx`/`uvx` and the server launched.
        let pid: pid_t
        do {
            pid = try SpawnedProcess.start(resolved.shell, [resolved.isFromUserShell ? "-c" : "-lc", #"exec "$0" "$@""#, config.command] + config.arguments,
                                           directory: nil, environment: env,
                                           output: stdout.fileHandleForWriting.fileDescriptor,
                                           error: stderr.fileHandleForWriting.fileDescriptor,
                                           input: stdin.fileHandleForReading.fileDescriptor)
        } catch {
            for handle in [stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting] {
                try? handle.close()
            }
            throw ToolError("Não foi possível iniciar o conector \(config.name): \(error.localizedDescription)")
        }
        // Only the server holds these ends now, so the readers see the end of the streams when it is gone.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        SpawnedProcess.watch(pid) { _ in } // reaps it
        self.pid = pid
        registry.add(pid)
        input = stdin.fileHandleForWriting
        outputs = [stdout, stderr]

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

    func send(_ message: JSONValue) async throws {
        guard let input else { throw ToolError("O conector \(config.name) não está em execução.") }
        let data = Data((message.jsonString + "\n").utf8)
        // Queued in the order of the calls (this runs on the actor up to the suspension), written off the actor.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            writes.async {
                do {
                    try input.write(contentsOf: data)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Closes the server's stdin and terminates it (killing it if it does not leave).
    func close() {
        closed = nil
        if let input {
            // Behind a write that is stuck, if there is one: the process ending is what frees it.
            writes.async { try? input.close() }
        }
        input = nil
        if let pid { registry.end(pid, grace: killGrace) }
        pid = nil
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
        // The complete lines are cut out first, searching only the bytes that arrived since the last chunk.
        var lines: [Data] = []
        var start = 0
        while let newline = Self.newline(in: buffer, from: max(start, scanned)) {
            lines.append(buffer.subdata(in: buffer.startIndex + start..<buffer.startIndex + newline))
            start = newline + 1
        }
        if start > 0 { buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + start) }
        scanned = buffer.count
        for line in lines {
            // Anything that isn't a JSON object (e.g. stray log output) is ignored; a message that follows output written
            // without a newline (`Loading…\r{"jsonrpc":…}`) is still read.
            if let message = Self.message(in: line) { await deliver(message) }
        }
        if buffer.count > maxLineBytes {
            let closed = self.closed
            buffer = Data()
            scanned = 0
            close()
            await closed?(ToolError("O conector \(config.name) mandou uma resposta grande demais ou sem quebra de linha."))
        }
    }

    /// Offset of the first newline of `data` at or after `from`.
    private static func newline(in data: Data, from: Int) -> Int? {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, from < raw.count, let found = memchr(base + from, 0x0A, raw.count - from) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }

    private static func message(in line: Data) -> JSONValue? {
        func decode(_ data: some DataProtocol) -> JSONValue? {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(data)), case .object = message else { return nil }
            return message
        }
        if let message = decode(line) { return message }
        guard let brace = line.firstIndex(of: 0x7B), brace > line.startIndex else { return nil }
        return decode(line[brace...])
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

/// The server forgot the session (HTTP 404 with a session id). The request that got the 404 never ran there, so a new session
/// can take it again; the others in flight may have, and are not repeated.
struct MCPSessionExpired: Error, LocalizedError, Equatable {
    let name: String
    var errorDescription: String? { "A sessão com o conector \(name) expirou." }
}

/// A remote server over Streamable HTTP (2025-06-18), falling back to the legacy HTTP+SSE transport (2024-11-05)
/// when the server rejects the initialize POST.
actor HTTPTransport: MCPTransport {
    private let name: String
    private let url: URL
    private let headers: [String: String]
    /// The login of the connector, when it has one: its access token goes in `Authorization` of every request.
    private let token: MCPTokenProvider?
    /// The connector was made to sign in (a 401 without a Bearer challenge is still a request to sign in).
    private let declaresLogin: Bool
    private let session: URLSession
    /// The most a reply (or one event of a stream) may hold before the link is dropped, as for a local server.
    private let maxMessageBytes: Int
    private var receive: (@Sendable (JSONValue) async -> Void)?
    private var closed: (@Sendable (Error) async -> Void)?
    private var sessionID: String?
    /// The server answered 404 to the session: there is nothing left to end with a DELETE.
    private var sessionExpired = false
    private var protocolVersion: String?
    /// Legacy mode: the POST endpoint announced by the server and the task reading its event stream.
    private var legacyEndpoint: URL?
    private var legacyStream: Task<Void, Never>?

    /// Dedicated session: no disk cache, cookies kept in memory only, cross-host redirects refused.
    static let defaultSession = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    /// `token`: gives the access token of a connector that signs in. `session`: tests put a fake one here.
    init(config: MCPServerConfig, token: MCPTokenProvider? = nil, session: URLSession = HTTPTransport.defaultSession,
         maxMessageBytes: Int = 32 << 20) throws {
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            // The URL itself is not quoted: it may carry an API key in its query.
            throw ToolError("O endereço do conector \(config.name) é inválido (use http:// ou https://).")
        }
        name = config.name
        self.url = url
        headers = config.headers
        self.token = token
        declaresLogin = config.oauth != nil
        self.session = session
        self.maxMessageBytes = maxMessageBytes
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
        } catch let error as MCPAuthRequired {
            throw error
        } catch let error as MCPSessionExpired {
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
        guard legacyEndpoint == nil, sessionID != nil, !sessionExpired else { return }
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
            // The connection decides what this means for the other requests in flight; only this one is known not to have run.
            sessionExpired = true
            throw MCPSessionExpired(name: name)
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
            // A declared length over the ceiling is refused before reading; otherwise the bytes pile up in one buffer and the
            // ceiling is checked every 64 KB (so the body may overshoot it by less than that before the error).
            if response.expectedContentLength > Int64(maxMessageBytes) { throw tooLarge }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            var sinceCheck = 0
            for try await byte in bytes {
                data.append(byte)
                sinceCheck += 1
                if sinceCheck == 65_536 {
                    sinceCheck = 0
                    if data.count > maxMessageBytes { throw tooLarge }
                }
            }
            if data.count > maxMessageBytes { throw tooLarge }
            answered = await deliver(String(decoding: data, as: UTF8.self), replyTo: message)
        }
        guard answered else { throw ToolError("O conector \(name) encerrou a resposta sem resultado.") }
    }

    private var tooLarge: ToolError { ToolError("O conector \(name) mandou uma resposta grande demais.") }

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
        // A refused token is renewed once and the request repeated; a second refusal means the login is over.
        var renewing = false
        while true {
            var request = URLRequest(url: target, timeoutInterval: timeout)
            request.httpMethod = method
            // Per-request deadlines are enforced by MCPConnection, which cancels the request when they pass.
            for (field, value) in headers where token == nil || field.lowercased() != "authorization" {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let bearer = try await token?(renewing)
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
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
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ToolError("O conector \(name) enviou uma resposta inválida.")
            }
            guard token != nil, [401, 403].contains(response.statusCode) else { return (bytes, response) }
            let challenge = MCPChallenge(header: response.value(forHTTPHeaderField: "WWW-Authenticate"))
            if response.statusCode == 403 {
                // Signed in, but not for this: more permission, asked for by the person, never repeated here.
                guard challenge.error == "insufficient_scope" else { return (bytes, response) }
                throw MCPAuthRequired(reason: .moreScope, challenge: challenge)
            }
            if bearer != nil && !renewing {
                renewing = true
                continue
            }
            // Without a token, only a Bearer challenge (or a connector made to sign in) asks for a login; any other 401 is the server's own message.
            if bearer == nil && !(challenge.isBearer || challenge.resourceMetadata != nil || declaresLogin) { return (bytes, response) }
            throw MCPAuthRequired(reason: bearer == nil ? .signIn : .expired, challenge: challenge)
        }
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
        var decoder = SSEDecoder()
        var pending = 0      // bytes read since the last blank line (the event being read, comments included)
        var lineBytes = 0    // bytes of the line in progress
        var previous: UInt8 = 0
        for try await byte in bytes {
            defer { previous = byte }
            if byte == 0x0A || byte == 0x0D {
                // The LF of a CRLF: the CR already ended the line (the decoder still sees it, to clear its own CR state).
                if byte == 0x0A, previous == 0x0D {
                } else if lineBytes == 0 { pending = 0 } else { pending += 1; lineBytes = 0 }   // blank line: event boundary
            } else {
                lineBytes += 1
                pending += 1
            }
            if pending > maxMessageBytes { throw tooLarge }
            if let sse = decoder.feed(byte) {
                pending = 0
                if try await !handle(sse.name ?? "message", sse.data) { return }
            }
        }
        // The server closed without the final blank line: the last event still counts.
        if let sse = decoder.finish() { _ = try await handle(sse.name ?? "message", sse.data) }
    }
}

/// Follows redirects only within the same host and never from HTTPS down to HTTP, so configured headers and tokens never reach
/// another server or travel in the clear.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Self.follows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }

    static func follows(from original: URL?, to target: URL?) -> Bool {
        let downgrade = original?.scheme?.lowercased() == "https" && target?.scheme?.lowercased() != "https"
        return target?.host != nil && target?.host?.lowercased() == original?.host?.lowercased() && !downgrade
    }
}
