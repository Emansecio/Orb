import Foundation
import os

/// What a stdio MCP server of the app says: its name, the tools it lists, and how a call runs. Everything else of the
/// protocol is `MCPStdioServer`'s.
protocol MCPServerHandler: Sendable {
    /// The `serverInfo` name of the handshake (and what the server's stderr notes begin with).
    var serverName: String { get }
    /// Whether a line that is not JSON-RPC gets an error reply (and a note on stderr) or is skipped silently.
    var answersParseErrors: Bool { get }
    /// The `tools/list` entries, each with name, description, `inputSchema` and annotations.
    func listedTools() -> [JSONValue]
    /// Whether `tools/call` knows the tool. It may know more than it lists.
    func offers(_ tool: String) -> Bool
    /// The `tools/call` result of a tool the server offers: its content and `isError`. A tool that fails is a result, not a protocol error.
    func call(_ tool: String, arguments: JSONValue) async -> JSONValue
}

extension MCPServerHandler {
    var answersParseErrors: Bool { true }
}

/// The MCP protocol versions the app speaks.
enum MCPProtocol {
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// The version the app asks for as a client, and answers with as a server when the other side asks for one it does not know.
    static let preferred = "2025-06-18"
}

/// The MCP server side the app speaks over stdio, shared by `Orb --pipe-tools` and the in-process local connectors: the handshake, `ping`,
/// `tools/list`, `tools/call`, the JSON-RPC envelope and errors, and the loop that reads stdin.
enum MCPStdioServer {
    /// The response to one message; nil for notifications.
    static func respond(to request: JSONValue, handler: any MCPServerHandler) async -> JSONValue? {
        guard let id = request["id"], id != .null else { return nil }
        switch request["method"]?.string {
        case "initialize":
            let asked = request["params"]?["protocolVersion"]?.string ?? ""
            return reply(id, .object([
                "protocolVersion": .string(MCPProtocol.versions.contains(asked) ? asked : MCPProtocol.preferred),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(handler.serverName), "version": .string("1.0")]),
            ]))
        case "ping":
            return reply(id, .object([:]))
        case "tools/list":
            return reply(id, .object(["tools": .array(handler.listedTools())]))
        case "tools/call":
            guard let name = request["params"]?["name"]?.string, handler.offers(name) else { return failure(id, -32602, "Ferramenta desconhecida") }
            return reply(id, await handler.call(name, arguments: request["params"]?["arguments"] ?? .object([:])))
        default:
            return failure(id, -32601, "Método não suportado")
        }
    }

    /// The reply to one line (a parse error gets a JSON-RPC error if the handler answers them; notifications get none).
    static func respond(toLine line: String, handler: any MCPServerHandler) async -> JSONValue? {
        guard let request = JSONValue.parse(line), case .object = request else {
            guard handler.answersParseErrors else { return nil }
            FileHandle.standardError.write(Data("\(handler.serverName): mensagem inválida ignorada\n".utf8))
            return failure(.null, -32700, "Parse error")
        }
        return await respond(to: request, handler: handler)
    }

    /// A `tools/call` result with one text block.
    static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }

    private static func reply(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func failure(_ id: JSONValue, _ code: Double, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(code), "message": .string(message)])])
    }

    /// Serves until stdin closes, then exits the process (what the Claude Code CLI starts; never opens a window). The messages are read
    /// on a background thread so the main thread stays free for tools that must run on the main actor (clipboard, notifications);
    /// it only services the main queue. Messages are split on "\n" only (JSON text may contain U+2028 and other Unicode line
    /// separators raw). Requests run concurrently, each in its own task (see `MCPServerLoop`): stopping a turn
    /// cancels the call at once, and stdin closing or SIGTERM cancels everything, lets a screen takeover put the screen back,
    /// and exits.
    static func run(_ makeHandler: @escaping @Sendable () -> any MCPServerHandler) -> Never {
        Thread.detachNewThread {
            let loop = MCPServerLoop(handler: makeHandler()) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            // SIGTERM and SIGINT (how a client stops a server) are caught instead of killing the process on the spot.
            var sources: [DispatchSourceSignal] = []
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    Task.detached {
                        await loop.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                sources.append(source)
            }
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                loop.handle(line: line)
            }
            // Stdin closed: cancel what runs, wait for takeovers to give the screen back, and leave.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                // Requests that are about to finish (a script piped in, then stdin closed) are let finish; the rest is cancelled.
                await loop.shutdown(patience: .milliseconds(500))
                done.signal()
            }
            done.wait()
            withExtendedLifetime(sources) { exit(0) }
        }
        dispatchMain()
    }
}

/// The request loop of a stdio MCP server: one task per request, so a long call does not hold up the next one and can be
/// cancelled. Replies are written one at a time. A request is cancelled by `notifications/cancelled` (no reply is sent for
/// it, as the protocol asks), and everything is cancelled by `shutdown()` (stdin closed, SIGTERM).
final class MCPServerLoop: @unchecked Sendable {
    private let handler: any MCPServerHandler
    private let write: @Sendable (String) -> Void
    private let writeLock = NSLock()
    private let state = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var anonymous = 0
    /// The latest request that is not a tool call.
    private var lane: Task<Void, Never>?
    private var stopping = false

    /// `write` receives one JSON line (without the line break) per reply.
    init(handler: any MCPServerHandler, write: @escaping @Sendable (String) -> Void) {
        self.handler = handler
        self.write = write
    }

    /// How many requests are still running.
    var running: Int { state.withLock { tasks.count } }

    /// Starts handling one line. Returns at once; the reply is written when the request finishes.
    func handle(line: String) {
        let parsed = JSONValue.parse(line)
        if case .object? = parsed, parsed?["method"]?.string == "notifications/cancelled" {
            if let id = parsed?["params"]?["requestId"], id != .null { cancel(Self.key(for: id)) }
            return
        }
        state.withLock {
            guard !stopping else { return }
            // A request is found again by its id; a line without one (a parse error) is only tracked to be waited for.
            let key: String
            if let id = parsed?["id"], id != .null { key = Self.key(for: id) } else { anonymous += 1; key = "#\(anonymous)" }
            let handler = handler
            // The handshake, `ping`, `tools/list` and errors answer in the order they came; a tool call starts only after those
            // before it were answered (a script piped in gets its replies in order), and then runs on its own.
            let isCall = parsed?["method"]?.string == "tools/call"
            let previous = lane
            let task = Task.detached { [self] in
                await previous?.value
                let answer = await MCPStdioServer.respond(toLine: line, handler: handler)
                // A cancelled request gets no reply.
                if let answer, !Task.isCancelled { send(answer.jsonString) }
                state.withLock { _ = tasks.removeValue(forKey: key) }
            }
            tasks[key] = task
            if !isCall { lane = task }
        }
    }

    /// Cancels the request with this key, if it is still running.
    func cancel(_ key: String) {
        let task = state.withLock { tasks[key] }
        task?.cancel()
    }

    /// Stops taking requests, cancels the running ones (after `patience`) and waits for them to wind down, at most `grace`: a screen takeover
    /// puts the screen back before its call returns, which is what this waits for.
    /// `patience` is how long the running requests may first take to finish on their own (stdin closing after a script was
    /// piped in); a signal gives none.
    func shutdown(grace: Duration = .milliseconds(1500), patience: Duration = .zero) async {
        state.withLock { stopping = true }
        let patient = ContinuousClock.now.advanced(by: patience)
        while self.running > 0, ContinuousClock.now < patient { try? await Task.sleep(for: .milliseconds(5)) }
        let running = state.withLock { Array(tasks.values) }
        for task in running { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: grace)
        while self.running > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func send(_ line: String) {
        writeLock.withLock { write(line) }
    }

    /// The registry key of a JSON-RPC id: the same number or string always gives the same key.
    static func key(for id: JSONValue) -> String { id.jsonString }
}
