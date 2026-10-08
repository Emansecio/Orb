import Foundation
import os

/// The Orb's memory tools for Claude Code turns. Claude Code only takes tools through MCP, so each turn's MCP
/// config starts the app's own binary as `Orb --memory-mcp <memory folder>`: a small stdio server offering the
/// same `remember` and `recall` tools on the same files (SQLite WAL lets it share the index with the app).
enum MemoryMCPServer {
    static let flag = "--memory-mcp"
    /// MCP server name in the Claude Code config, so its tools are `mcp__orb_memoria__remember` / `__recall` (a name
    /// unlikely to collide with an MCP server of the user's own).
    static let name = "orb_memoria"
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    static let tools: [any AgentTool] = [RememberTool(), RecallTool()]

    /// The stdio server entry for one Orb's memory.
    static func config(directory: URL) -> MCPServerConfig {
        var server = MCPServerConfig(name: name, command: Bundle.main.executablePath ?? CommandLine.arguments[0])
        server.arguments = [flag, directory.path]
        return server
    }

    /// Serves until stdin closes. Runs on the calling thread: messages are split on "\n" only (JSON text may contain
    /// U+2028 and other Unicode line separators raw), each handled in turn.
    static func serve(directory: URL) {
        let bank = MemoryBank(directory: directory)
        let context = ToolContext(workingDirectory: FileManager.default.homeDirectoryForCurrentUser, memory: bank)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply = blocking { await respond(to: line, context: context) }
            if let reply { FileHandle.standardOutput.write(Data((reply.jsonString + "\n").utf8)) }
        }
    }

    /// The reply to one line (a parse error gets a JSON-RPC error; notifications get none).
    static func respond(to line: String, context: ToolContext) async -> JSONValue? {
        guard let request = JSONValue.parse(line), case .object = request else {
            FileHandle.standardError.write(Data("orb-memoria: mensagem inválida ignorada\n".utf8))
            return .object(["jsonrpc": .string("2.0"), "id": .null,
                            "error": .object(["code": .number(-32700), "message": .string("Parse error")])])
        }
        return await handle(request, context: context)
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
    static func handle(_ request: JSONValue, context: ToolContext) async -> JSONValue? {
        guard let id = request["id"], id != .null else { return nil }
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
