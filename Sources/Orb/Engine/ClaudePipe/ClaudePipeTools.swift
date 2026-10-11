import Foundation

// The Orb's tools, as the Claude Code CLI sees them when it is only a pipe to the model: the CLI is started with `--tools ""` and an
// MCP config naming one stdio server, "orb" (the app's own binary in `--pipe-tools` mode), which only DECLARES the tools. When the model
// calls one, the Orb's engine runs it itself and leaves the result in a mailbox folder; the server, called by the CLI for that
// `tool_use_id`, waits for the file and returns it as the MCP result.

/// What the Orb's engine hands back for one tool call, read by the MCP server when the CLI runs that call.
struct ClaudePipeToolResult: Codable, Sendable, Equatable {
    var text: String
    var images: [ImageAttachment]
    var isError: Bool
}

/// A folder where tool results wait for the MCP server: one `<tool_use_id>.json` per call. The app delivers, the server takes.
struct ClaudePipeMailbox: Sendable {
    let directory: URL

    /// Writes the result atomically (the server never sees half a file).
    func deliver(_ result: ClaudePipeToolResult, toolUseID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: file(for: toolUseID), options: .atomic)
    }

    /// The result of this call, removed from the folder; nil when it has not been delivered (or cannot be read).
    func take(toolUseID: String) -> ClaudePipeToolResult? {
        let url = file(for: toolUseID)
        guard let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(ClaudePipeToolResult.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return result
    }

    /// The file of a call: the id with everything but letters, digits, "-" and "_" turned into "_" (an id never climbs out of the folder).
    func file(for toolUseID: String) -> URL {
        let safe = String(toolUseID.unicodeScalars.map { scalar -> Character in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")) ? Character(scalar) : "_"
        })
        return directory.appendingPathComponent((safe.isEmpty ? "_" : safe) + ".json")
    }
}

enum ClaudePipeTools {
    /// Writes the declarations file the MCP server lists: `[{name, description, inputSchema}]`.
    static func writeDeclarations(_ tools: [ToolSpec], to url: URL) throws {
        let entries: [JSONValue] = tools.map {
            .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.parameters])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    /// The `--mcp-config` JSON: one stdio server, "orb", which is the app's binary in `--pipe-tools` mode.
    static func mcpConfig(binary: URL, declarations: URL, mailbox: URL) -> JSONValue {
        .object(["mcpServers": .object([ClaudePipeServer.serverName: .object([
            "type": .string("stdio"),
            "command": .string(binary.path),
            "args": .array([.string(ClaudePipeServer.toolsFlag), .string(declarations.path),
                            .string(ClaudePipeServer.mailboxFlag), .string(mailbox.path)]),
            "env": .object([:]),
        ])])])
    }
}

/// The MCP stdio server of `Orb --pipe-tools <declarations.json> --pipe-mailbox <dir>`.
enum ClaudePipeServer {
    static let toolsFlag = "--pipe-tools"
    static let mailboxFlag = "--pipe-mailbox"
    static let serverName = "orb"
    /// Where Claude Code puts the id of the tool call it is running, in the `_meta` of `tools/call`.
    static let toolUseIDKey = "claudecode/toolUseId"
    static let defaultPollInterval: Duration = .milliseconds(50)
    static let defaultTimeout: Duration = .seconds(30 * 60)

    struct Options: Sendable {
        var declarations: URL
        var mailbox: URL

        /// Reads `--pipe-tools <file> --pipe-mailbox <dir>`; nil unless both are there.
        init?(arguments: [String]) {
            func value(of flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            guard let tools = value(of: ClaudePipeServer.toolsFlag), let mailbox = value(of: ClaudePipeServer.mailboxFlag) else { return nil }
            declarations = URL(fileURLWithPath: tools)
            self.mailbox = URL(fileURLWithPath: mailbox, isDirectory: true)
        }
    }

    /// The tools of the declarations file (an unreadable file declares none).
    static func loadDeclarations(from url: URL) -> [JSONValue] {
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        return entries.filter { $0["name"]?.string != nil }
    }

    /// The reply to one stdin line; nil for notifications and for lines that are not JSON objects.
    /// A `tools/call` waits (polling `mailbox` every `pollInterval`, up to `timeout`) for the result of its `_meta` tool-use id;
    /// cancelling the calling task ends the wait.
    static func respond(toLine line: String, declarations: [JSONValue], mailbox: ClaudePipeMailbox,
                        pollInterval: Duration = defaultPollInterval, timeout: Duration = defaultTimeout) async -> JSONValue? {
        guard let request = JSONValue.parse(line), case .object = request else { return nil }
        guard let id = request["id"], id != .null else { return nil }
        let handler = Handler(declarations: declarations)
        switch request["method"]?.string {
        case "tools/call":
            guard let name = request["params"]?["name"]?.string, handler.offers(name) else {
                return await MCPStdioServer.respond(to: request, handler: handler)
            }
            let result = await callResult(toolUseID: request["params"]?["_meta"]?[toolUseIDKey]?.string, name: name,
                                          mailbox: mailbox, pollInterval: pollInterval, timeout: timeout)
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        case "initialize", "ping", "tools/list":
            return await MCPStdioServer.respond(to: request, handler: handler)
        default:
            // Methods the server has nothing to say about (resources, prompts…) get an empty result instead of an error.
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
        }
    }

    /// The `tools/call` result of one call: the delivered text, then its pictures as MCP image blocks; an error result when nothing arrives.
    static func callResult(toolUseID: String?, name: String, mailbox: ClaudePipeMailbox,
                           pollInterval: Duration, timeout: Duration) async -> JSONValue {
        guard let toolUseID, !toolUseID.isEmpty else {
            return MCPStdioServer.textResult("O Claude Code não informou qual chamada de «\(name)» é esta; o Orb não consegue entregar o resultado.", isError: true)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let delivered = mailbox.take(toolUseID: toolUseID) { return content(of: delivered) }
            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            do { try await Task.sleep(for: pollInterval) } catch { break }
        }
        // One last look: the result may have arrived while the wait was ending.
        if let delivered = mailbox.take(toolUseID: toolUseID) { return content(of: delivered) }
        return MCPStdioServer.textResult("O Orb não devolveu o resultado de «\(name)» a tempo.", isError: true)
    }

    /// The MCP content of one delivered result (pictures that cannot be read are left out).
    static func content(of result: ClaudePipeToolResult) -> JSONValue {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(result.text)])]
        for image in result.images {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: image.path)), !data.isEmpty else { continue }
            blocks.append(.object(["type": .string("image"), "data": .string(data.base64EncodedString()),
                                   "mimeType": .string(image.mediaType)]))
        }
        return .object(["content": .array(blocks), "isError": .bool(result.isError)])
    }

    /// The handshake and listing of the server: the declared tools, nothing runs here (`tools/call` is `respond`'s).
    private struct Handler: MCPServerHandler {
        let declarations: [JSONValue]
        var serverName: String { ClaudePipeServer.serverName }
        func listedTools() -> [JSONValue] { declarations }
        func offers(_ tool: String) -> Bool { declarations.contains { $0["name"]?.string == tool } }
        func call(_ tool: String, arguments: JSONValue) async -> JSONValue {
            MCPStdioServer.textResult("Ferramenta desconhecida", isError: true)
        }
    }

    /// Serves over stdin/stdout until stdin closes, then exits (what Claude Code starts). Never opens a window. `tools/call`s run side
    /// by side (each waits for its own result); `notifications/cancelled` ends one's wait. The handshake and listing answer in order.
    static func run(_ options: Options) -> Never {
        Thread.detachNewThread {
            let declarations = loadDeclarations(from: options.declarations)
            let loop = Loop(declarations: declarations, mailbox: ClaudePipeMailbox(directory: options.mailbox)) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            for number in [SIGTERM, SIGINT] { signal(number, SIG_DFL) }
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                loop.handle(line: line)
            }
            // Stdin closed: the CLI is gone, nobody is left to read the results.
            exit(0)
        }
        dispatchMain()
    }

    /// The request loop: one task per line, replies written one at a time.
    final class Loop: @unchecked Sendable {
        private let declarations: [JSONValue]
        private let mailbox: ClaudePipeMailbox
        private let pollInterval: Duration
        private let timeout: Duration
        private let write: @Sendable (String) -> Void
        private let state = NSLock()
        private let writeLock = NSLock()
        private var tasks: [String: Task<Void, Never>] = [:]
        private var lane: Task<Void, Never>?
        private var anonymous = 0

        init(declarations: [JSONValue], mailbox: ClaudePipeMailbox, pollInterval: Duration = ClaudePipeServer.defaultPollInterval,
             timeout: Duration = ClaudePipeServer.defaultTimeout, write: @escaping @Sendable (String) -> Void) {
            self.declarations = declarations
            self.mailbox = mailbox
            self.pollInterval = pollInterval
            self.timeout = timeout
            self.write = write
        }

        /// How many requests are still running.
        var running: Int { state.withLock { tasks.count } }

        func handle(line: String) {
            let parsed = JSONValue.parse(line)
            if parsed?["method"]?.string == "notifications/cancelled" {
                if let id = parsed?["params"]?["requestId"], id != .null {
                    let task = state.withLock { tasks[id.jsonString] }
                    task?.cancel()
                }
                return
            }
            state.withLock {
                let key: String
                if let id = parsed?["id"], id != .null { key = id.jsonString } else { anonymous += 1; key = "#\(anonymous)" }
                let isCall = parsed?["method"]?.string == "tools/call"
                let previous = lane
                let (declarations, mailbox, pollInterval, timeout) = (self.declarations, self.mailbox, self.pollInterval, self.timeout)
                let task = Task.detached { [self] in
                    await previous?.value
                    let answer = await ClaudePipeServer.respond(toLine: line, declarations: declarations, mailbox: mailbox,
                                                                pollInterval: pollInterval, timeout: timeout)
                    // A cancelled request gets no reply, as the protocol asks.
                    if let answer, !Task.isCancelled { writeLock.withLock { write(answer.jsonString) } }
                    state.withLock { _ = tasks.removeValue(forKey: key) }
                }
                tasks[key] = task
                if !isCall { lane = task }
            }
        }
    }
}
