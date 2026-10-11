import Foundation
import os

/// What a stdio MCP server of the app says: its name, the tools it lists, and how a call runs. Everything else of the
/// protocol is `MCPStdioServer`'s.
protocol MCPServerHandler: Sendable {
    /// The `serverInfo` name of the handshake (and what the server's stderr notes begin with).
    var serverName: String { get }
    /// The `tools/list` entries, each with name, description, `inputSchema` and annotations.
    func listedTools() -> [JSONValue]
    /// Whether `tools/call` knows the tool. It may know more than it lists.
    func offers(_ tool: String) -> Bool
    /// The `tools/call` result of a tool the server offers: its content and `isError`. A tool that fails is a result, not a protocol error.
    func call(_ tool: String, arguments: JSONValue) async -> JSONValue
}

/// The MCP protocol versions the app speaks.
enum MCPProtocol {
    static let versions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// The version the app asks for as a client, and answers with as a server when the other side asks for one it does not know.
    static let preferred = "2025-06-18"
}

/// The MCP server side the app speaks, shared by `Orb --pipe-tools` and the in-process local connectors: the handshake, `ping`,
/// `tools/list`, `tools/call` and the JSON-RPC envelope and errors.
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

    /// The reply to one line (a parse error gets a JSON-RPC error; notifications get none).
    static func respond(toLine line: String, handler: any MCPServerHandler) async -> JSONValue? {
        guard let request = JSONValue.parse(line), case .object = request else {
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
}
