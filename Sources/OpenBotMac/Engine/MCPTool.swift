import Foundation

/// One remote MCP tool offered to the model as `<server>__<tool>`.
struct MCPTool: AgentTool {
    let serverName: String
    let toolName: String
    let spec: ToolSpec
    let connection: MCPConnection

    init(serverName: String, remote: ToolSpec, connection: MCPConnection) {
        self.serverName = serverName
        toolName = remote.name
        self.connection = connection
        let description = remote.description.isEmpty ? remote.name : remote.description
        spec = ToolSpec(name: Self.modelName(server: serverName, tool: remote.name),
                        description: "[\(serverName)] \(description)", parameters: remote.parameters)
    }

    /// `<server>__<tool>` restricted to `[a-zA-Z0-9_-]` and 64 characters, as model APIs require.
    static func modelName(server: String, tool: String) -> String {
        let scalars = "\(server)__\(tool)".unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
                ? Character(scalar) : "_"
        }
        return String(scalars.prefix(64))
    }

    var kind: ToolCall.Kind { .connector }
    var capability: Capability? { .connectors }

    /// Third-party code: always confirm according to the bot's permission mode.
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let args = arguments == .object([:]) || arguments == .null ? "" : " " + arguments.jsonString
        return ("Usando \(serverName)", String((toolName + args).prefix(300)))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await connection.call(toolName, arguments: arguments)
    }
}

// MARK: - Manager

enum MCPStatus: Sendable, Equatable {
    case starting, ready(toolCount: Int), failed(String), stopped
}

/// Owns one connection per configured server and exposes their tools.
actor MCPManager {
    private struct Entry {
        var config: MCPServerConfig
        var connection: MCPConnection?
        var status: MCPStatus
        var tools: [MCPTool] = []
    }

    private var entries: [UUID: Entry] = [:]

    /// Stops removed, disabled or edited servers and starts new ones concurrently; returns once each has started or failed.
    func sync(_ configs: [MCPServerConfig]) async {
        let wanted = Dictionary(configs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in entries where wanted[id] != entry.config {
            entries[id] = nil
            await entry.connection?.stop()
        }
        var starting: [(UUID, MCPConnection)] = []
        for config in wanted.values where entries[config.id] == nil {
            guard config.isEnabled else {
                entries[config.id] = Entry(config: config, status: .stopped)
                continue
            }
            let connection = MCPConnection(config: config)
            entries[config.id] = Entry(config: config, connection: connection, status: .starting)
            starting.append((config.id, connection))
        }
        await withTaskGroup(of: (UUID, MCPConnection, Result<[ToolSpec], Error>).self) { group in
            for (id, connection) in starting {
                group.addTask {
                    do { return (id, connection, .success(try await connection.start())) }
                    catch { return (id, connection, .failure(error)) }
                }
            }
            for await (id, connection, result) in group {
                // A later sync may have replaced this connection meanwhile.
                guard var entry = entries[id], entry.connection === connection else { continue }
                switch result {
                case .success(let specs):
                    entry.tools = specs.map { MCPTool(serverName: entry.config.name, remote: $0, connection: connection) }
                    entry.status = .ready(toolCount: specs.count)
                case .failure(let error):
                    entry.status = .failed(error.localizedDescription)
                }
                entries[id] = entry
            }
        }
    }

    /// Tools of every server that is ready.
    func tools() async -> [any AgentTool] {
        var tools: [any AgentTool] = []
        for entry in entries.values.sorted(by: { $0.config.name < $1.config.name }) {
            if let connection = entry.connection, await connection.isRunning { tools += entry.tools }
        }
        return tools
    }

    func status() async -> [UUID: MCPStatus] {
        var result: [UUID: MCPStatus] = [:]
        for (id, entry) in entries {
            if case .ready = entry.status, let connection = entry.connection, await !connection.isRunning {
                result[id] = .failed("O conector \(entry.config.name) foi encerrado.")
            } else {
                result[id] = entry.status
            }
        }
        return result
    }
}
