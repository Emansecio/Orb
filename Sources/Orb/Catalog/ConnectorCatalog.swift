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

/// How much a connector tool can change, as its server declared it (MCP `readOnlyHint` / `destructiveHint`).
enum ToolEffect: Equatable, Sendable {
    case readOnly
    /// Writes, but the server did not mark it destructive (`create_issue`, `merge_pull_request`).
    case modifies
    case destructive
    /// The server said nothing: no claim is made either way.
    case unknown

    init(_ annotations: MCPToolAnnotations) {
        if annotations.destructive == true { self = .destructive }
        else if annotations.readOnly == true { self = .readOnly }
        else if annotations.readOnly == false || annotations.destructive == false { self = .modifies }
        else { self = .unknown }
    }
}

enum ConnectorToolText {
    /// "create_issue" -> "Create issue": the tool's name as a phrase; the identifier stays beside it, small, for who needs it.
    static func title(_ identifier: String) -> String {
        let words = identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
