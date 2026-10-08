import Foundation
import os

/// The Orb's own tools for Claude Code turns. Claude Code only takes extra tools through MCP, so each turn's MCP
/// config starts the app's own binary as `Orb --tools-mcp <memory folder> [--mac] [--folder <working folder>]`: a
/// small stdio server offering `remember` and `recall` on the same files as the app (SQLite WAL lets it share the
/// index) and, for an Orb with "Apps do Mac", the Mac tools (`open`, `applescript`, `shortcuts_*`, `clipboard_*`,
/// `screenshot`, `notify`, `apps_list`, `processes`, `app_quit`, `trash`, `browser_tab`) with the same schemas.
enum OrbToolsMCPServer {
    static let flag = "--tools-mcp"
    /// What the server was called when it only served memory; still accepted.
    static let legacyFlag = "--memory-mcp"
    static let macFlag = "--mac"
    static let folderFlag = "--folder"
    /// MCP server name in the Claude Code config, so its tools are `mcp__orb_memoria__remember`, `__recall`, `__open`…
    /// The name stays what it was: sessions that are resumed, and the user's "Sempre permitir" choices, refer to the
    /// tools by it. It is also a name unlikely to collide with an MCP server of the user's own.
    static let name = "orb_memoria"
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// Every tool the server can offer, for naming and summarizing the calls Claude Code reports.
    static let allTools: [any AgentTool] = ToolBox.memoryTools + ToolBox.macTools

    /// What one server process offers, gated like the native tools: memory always, and each Mac tool when the Orb has
    /// "Apps do Mac" or the tool needs no capability (`open`, `notify`).
    static func tools(mac: Bool) -> [any AgentTool] {
        ToolBox.memoryTools + ToolBox.macTools.filter { mac || $0.capability == nil }
    }

    /// The tool behind a Claude Code tool name (`mcp__orb_memoria__open`), nil for anything else.
    static func tool(claudeCodeName: String) -> (any AgentTool)? {
        guard claudeCodeName.hasPrefix(ClaudeCodeTools.memoryPrefix) else { return nil }
        let short = claudeCodeName.dropFirst(ClaudeCodeTools.memoryPrefix.count)
        return allTools.first { $0.spec.name == short }
    }

    /// The command line of one server process.
    struct Options: Equatable, Sendable {
        var memoryDirectory: URL
        var mac = false
        /// The Orb's folder, where relative paths and commands of its tools start. Nil means the home folder.
        var folder: URL?

        init(memoryDirectory: URL, mac: Bool = false, folder: URL? = nil) {
            self.memoryDirectory = memoryDirectory
            self.mac = mac
            self.folder = folder
        }

        /// Reads `--tools-mcp <dir>` (or `--memory-mcp <dir>`) with the optional `--mac` and `--folder <dir>`;
        /// nil when the arguments do not ask for the server.
        init?(arguments: [String]) {
            guard let start = arguments.firstIndex(where: { $0 == OrbToolsMCPServer.flag || $0 == OrbToolsMCPServer.legacyFlag }),
                  arguments.indices.contains(start + 1) else { return nil }
            self.init(memoryDirectory: URL(fileURLWithPath: arguments[start + 1]))
            let rest = Array(arguments[(start + 2)...])
            mac = rest.contains(OrbToolsMCPServer.macFlag)
            if let folder = rest.firstIndex(of: OrbToolsMCPServer.folderFlag), rest.indices.contains(folder + 1) {
                self.folder = URL(fileURLWithPath: rest[folder + 1])
            }
        }

        var context: ToolContext {
            ToolContext(workingDirectory: folder ?? FileManager.default.homeDirectoryForCurrentUser,
                        memory: MemoryBank(directory: memoryDirectory))
        }
    }

    /// The stdio server entry for one Orb.
    static func config(directory: URL, mac: Bool = false, folder: URL? = nil) -> MCPServerConfig {
        var server = MCPServerConfig(name: name, command: Bundle.main.executablePath ?? CommandLine.arguments[0])
        server.arguments = [flag, directory.path] + (mac ? [macFlag] : []) + (folder.map { [folderFlag, $0.path] } ?? [])
        return server
    }

    /// Runs the server until stdin closes, then exits the process. The messages are read on a background thread so
    /// the main thread stays free for tools that must run on the main actor (clipboard, notifications); it only
    /// services the main queue, and never starts the app (no NSApplication, no windows, no Dock icon).
    static func run(_ options: Options) -> Never {
        Thread.detachNewThread {
            serve(options)
            exit(0)
        }
        dispatchMain()
    }

    /// Serves until stdin closes. Messages are split on "\n" only (JSON text may contain U+2028 and other Unicode
    /// line separators raw) and handled in turn. Call it off the main thread: it waits for each answer.
    static func serve(_ options: Options) {
        let context = options.context
        let mac = options.mac
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply = blocking { await respond(to: line, context: context, mac: mac) }
            if let reply { FileHandle.standardOutput.write(Data((reply.jsonString + "\n").utf8)) }
        }
    }

    /// The reply to one line (a parse error gets a JSON-RPC error; notifications get none).
    static func respond(to line: String, context: ToolContext, mac: Bool = false) async -> JSONValue? {
        guard let request = JSONValue.parse(line), case .object = request else {
            FileHandle.standardError.write(Data("orb-memoria: mensagem inválida ignorada\n".utf8))
            return .object(["jsonrpc": .string("2.0"), "id": .null,
                            "error": .object(["code": .number(-32700), "message": .string("Parse error")])])
        }
        return await handle(request, context: context, mac: mac)
    }

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await work()
            box.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 }!
    }

    /// The JSON-RPC response to one message (nil for notifications).
    static func handle(_ request: JSONValue, context: ToolContext, mac: Bool = false) async -> JSONValue? {
        guard let id = request["id"], id != .null else { return nil }
        let tools = tools(mac: mac)
        func result(_ value: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        switch request["method"]?.string {
        case "initialize":
            let asked = request["params"]?["protocolVersion"]?.string ?? ""
            return result(.object([
                "protocolVersion": .string(protocolVersions.contains(asked) ? asked : "2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("orb-memoria"), "version": .string("1.0")]),
            ]))
        case "ping":
            return result(.object([:]))
        case "tools/list":
            return result(.object(["tools": .array(tools.map {
                .object(["name": .string($0.spec.name), "description": .string($0.spec.description),
                         "inputSchema": $0.spec.parameters,
                         "annotations": .object(["readOnlyHint": .bool($0.risk(.object([:])) == .safe)])])
            })]))
        case "tools/call":
            let name = request["params"]?["name"]?.string
            let arguments = request["params"]?["arguments"] ?? .object([:])
            guard let tool = tools.first(where: { $0.spec.name == name }) else {
                return .object(["jsonrpc": .string("2.0"), "id": id,
                                "error": .object(["code": .number(-32602), "message": .string("Ferramenta desconhecida")])])
            }
            let (text, failed): (String, Bool)
            do { (text, failed) = (try await tool.run(arguments, context: context), false) } catch {
                (text, failed) = (error.localizedDescription, true)
            }
            return result(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                   "isError": .bool(failed)]))
        default:
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .number(-32601), "message": .string("Método não suportado")])])
        }
    }
}
