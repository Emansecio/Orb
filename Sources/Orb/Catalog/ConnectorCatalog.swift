import Foundation

/// What a connector's server offered the last time it ran, kept on disk (`conectores/<id>.json`, never a secret) so the
/// Orb can list, resolve and judge the connector's tools without starting it: the index the model reads, the card's
/// "12 ferramentas", "Ver ferramentas" and the annotations the permission check reads all come from here.
struct ConnectorCatalog: Codable, Sendable, Equatable {
    struct Tool: Codable, Sendable, Equatable {
        var name: String
        var description: String
        var inputSchema: JSONValue
        var annotations: MCPToolAnnotations

        var spec: ToolSpec { ToolSpec(name: name, description: description, parameters: inputSchema) }
    }

    /// The protocol version the server answered `initialize` with.
    var protocolVersion: String?
    var serverName: String?
    var serverVersion: String?
    /// What the server says about how to use it, shortened: a long text would only fill the disk.
    var instructions: String?
    var tools: [Tool]
    var updatedAt: Date

    static let instructionsLimit = 2_000

    init(handshake: MCPHandshake, specs: [ToolSpec], annotations: [String: MCPToolAnnotations], updatedAt: Date = .now) {
        protocolVersion = handshake.protocolVersion
        serverName = handshake.serverName
        serverVersion = handshake.serverVersion
        instructions = handshake.instructions.map { String($0.prefix(Self.instructionsLimit)) }
        tools = specs.map { Tool(name: $0.name, description: $0.description, inputSchema: $0.parameters,
                                 annotations: annotations[$0.name] ?? .none) }
        self.updatedAt = updatedAt
    }
}
