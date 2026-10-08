import Foundation

/// One remote MCP tool offered to the model as `<server>__<tool>`.
struct MCPTool: AgentTool {
    let serverName: String
    let toolName: String
    let spec: ToolSpec
    let connection: MCPConnection
    let annotations: MCPToolAnnotations
    /// The connector this tool belongs to (to offer an Orb only the connectors it may use).
    var serverID: UUID?

    init(serverName: String, remote: ToolSpec, connection: MCPConnection, annotations: MCPToolAnnotations = .none) {
        self.serverName = serverName
        toolName = remote.name
        self.connection = connection
        self.annotations = annotations
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

    /// Third-party code: confirm according to the bot's permission mode, unless the server declares the tool
    /// read-only and closed-world (it only reads what the server itself holds). A tool that declares itself
    /// destructive stays sensitive, whatever else it claims.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        annotations.readOnly == true && annotations.openWorld != true && annotations.destructive != true ? .safe : .sensitive
    }

    /// A tool the server marks destructive asks even in "Automático" and is never covered by "Sempre permitir".
    func danger(_ arguments: JSONValue) -> String? {
        annotations.destructive == true ? "o conector marcou esta ferramenta como destrutiva" : nil
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let args = arguments == .object([:]) || arguments == .null ? "" : " " + arguments.jsonString
        return ("Usando \(serverName)", String((toolName + args).prefix(300)))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await connection.call(toolName, arguments: arguments)
    }
}

// MARK: - Manager

extension MCPServerConfig {
    /// The config without what only decides who may use it: two configs that agree here run the same server.
    var runtimeIdentity: MCPServerConfig {
        var copy = self
        copy.orbIDs = nil
        copy.secretKeys = []
        return copy
    }
}

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

    /// Stops removed, disabled, edited or dead servers and (re)starts the rest concurrently;
    /// returns once each has started or failed. `progress` hears about each one the moment it is done, so a caller that
    /// cares about one connector need not wait for a slow, unrelated one.
    func sync(_ configs: [MCPServerConfig], progress: (@Sendable (UUID, MCPStatus) async -> Void)? = nil) async {
        let wanted = Dictionary(configs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in entries {
            // Which Orbs may use a connector does not change how it runs: no restart for that.
            var stale = wanted[id].map { $0.runtimeIdentity != entry.config.runtimeIdentity } ?? true
            if case .failed = entry.status { stale = true }
            if case .ready = entry.status, let connection = entry.connection, await !connection.isRunning { stale = true }
            guard stale else { continue }
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
                    let annotations = await connection.toolAnnotations
                    entry.tools = specs.map {
                        var tool = MCPTool(serverName: entry.config.name, remote: $0, connection: connection,
                                           annotations: annotations[$0.name] ?? .none)
                        tool.serverID = id
                        return tool
                    }
                    entry.status = .ready(toolCount: specs.count)
                case .failure(let error):
                    entry.status = .failed(error.localizedDescription)
                }
                entries[id] = entry
                await progress?(id, entry.status)
            }
        }
    }

    /// Tools of every server that is ready, or only of the servers in `allowing` (the connectors an Orb may use).
    func tools(allowing: Set<UUID>? = nil) async -> [any AgentTool] {
        var tools: [any AgentTool] = []
        for entry in entries.values.sorted(by: { $0.config.name < $1.config.name }) {
            if let allowing, !allowing.contains(entry.config.id) { continue }
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
