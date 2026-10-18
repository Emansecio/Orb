import Foundation

/// How the model reaches the connectors. Their tools are not in the request: a GitHub alone has dozens, and they would
/// travel with every message. Instead the model gets two fixed tools. `connector_tools` lists what a connector offers
/// (the answer lands at the end of the conversation, where the provider's cache is not disturbed) and `connector_call`
/// runs one of those tools. The description of `connector_tools` carries a short index of the connectors the Orb may use,
/// which depends only on which connectors those are: it changes when one is installed, removed or switched off, never when
/// a server changes its tools.
///
/// The engine turns a `connector_call` into the call of the real tool (`GitHub__create_issue`) before the permission
/// policy looks at it, so approval cards, annotations and the "Sempre permitir" rules work as they always did.
enum ConnectorGateway {
    static let toolsName = "connector_tools"
    static let callName = "connector_call"

    /// Lines the index spells out; the connectors past them are listed by name only.
    static let indexLines = 20
    /// Longest line of the index, and the longest summary within it.
    static let lineLimit = 100
    static let summaryLimit = 80
    static let nameLimit = 30
    /// Longest description of a tool in the listing.
    static let descriptionLimit = 300

    /// The two tools, for the connectors the Orb may use; none when there are none.
    static func tools(for connectors: [MCPServerConfig], manager: MCPManager) -> [any AgentTool] {
        guard !connectors.isEmpty else { return [] }
        return [ConnectorToolsTool(connectors: connectors, manager: manager),
                ConnectorCallTool(connectors: connectors, manager: manager)]
    }

    // MARK: Index

    /// "- GitHub: Ler repositórios e issues." per connector, sorted by name, so the same connectors always give the same text.
    static func index(for connectors: [MCPServerConfig]) -> String {
        let sorted = connectors.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
        var lines = sorted.prefix(indexLines).map(line(for:))
        if sorted.count > indexLines {
            lines.append("+\(sorted.count - indexLines): " + sorted.dropFirst(indexLines).map { oneLine($0.name, limit: nameLimit) }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func line(for connector: MCPServerConfig) -> String {
        let name = oneLine(connector.name, limit: nameLimit)
        let summary = firstSentence(of: connector.summary ?? ConnectorTemplate.matching(connector)?.summary ?? "")
        guard !summary.isEmpty else { return "- " + name }
        let room = min(summaryLimit, lineLimit - name.count - 4)
        return "- \(name): " + oneLine(summary, limit: max(room, 0))
    }

    private static func firstSentence(of text: String) -> String {
        let flat = oneLine(text, limit: .max)
        guard let end = flat.range(of: ". ") else { return flat.hasSuffix(".") ? String(flat.dropLast()) : flat }
        return String(flat[..<end.lowerBound])
    }

    /// The text on one line, shortened with "…" past `limit` characters.
    private static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Listing

    /// What `connector_tools` answers: per tool, "name — description" and its arguments. A listing over a page
    /// of text gives only the names with a line each, and says how to ask for the arguments of some.
    static func render(_ catalog: ConnectorCatalog, connector: String, only names: [String]? = nil) -> String {
        guard !catalog.tools.isEmpty else { return "\(connector) não oferece ferramentas." }
        var tools = catalog.tools
        var missing: [String] = []
        if let names, !names.isEmpty {
            tools = names.compactMap { name in catalog.tools.first { $0.name == name } }
            missing = names.filter { name in !catalog.tools.contains { $0.name == name } }
        }
        var text = tools.map { tool in
            "\(tool.name) — \(oneLine(tool.description, limit: descriptionLimit))\nargs: \(tool.inputSchema.jsonString)"
        }.joined(separator: "\n\n")
        let room = ToolOutputBudget.pageCharacters - 300
        if text.count > room {
            // A line each; the names alone when even that is too much.
            text = tools.map { "\($0.name) — \(oneLine($0.description, limit: 100))" }.joined(separator: "\n")
            if text.count > room { text = tools.map(\.name).joined(separator: ", ") }
            text += "\n\nSão muitas ferramentas: chame de novo com tools:[…] para ver os argumentos das que quiser."
        }
        if !missing.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + "\(connector) não tem: \(missing.joined(separator: ", "))."
        }
        return text
    }

    // MARK: Resolving

    /// The connector named `name` among `connectors`: the exact name, or the same once the characters a model name
    /// cannot hold are ignored (`GitHub` for `github`).
    static func connector(named name: String, in connectors: [MCPServerConfig]) throws -> MCPServerConfig {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        func key(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        }
        if let found = connectors.first(where: { $0.name == wanted }) ?? connectors.first(where: { key($0.name) == key(wanted) }) {
            return found
        }
        let names = connectors.map(\.name).sorted().joined(separator: ", ")
        throw ToolError("Não existe o conector \"\(wanted)\". Os disponíveis são: \(names).")
    }

    /// The real tool a `connector_call` names, with the arguments it passes on. Throws what the model needs to correct
    /// the call: the connector or the tool does not exist (it lists them again), or an argument is missing.
    static func resolve(_ arguments: JSONValue, connectors: [MCPServerConfig], manager: MCPManager) async throws
        -> (tool: MCPTool, arguments: JSONValue) {
        let config = try connector(named: try arguments.requiredString("connector"), in: connectors)
        let name = try arguments.requiredString("tool")
        // No catalog is not "no such tool": the connector has not run yet, and connector_tools starts it to find out.
        guard let catalog = await manager.catalog(config.id) else {
            throw ToolError("Ainda não sei as ferramentas de \(config.name). Chame connector_tools(connector: \"\(config.name)\") primeiro.")
        }
        guard let found = catalog.tools.first(where: { $0.name == name }) else {
            throw ToolError("\(config.name) não tem a ferramenta \(name). Chame connector_tools(connector: \"\(config.name)\") para ver a lista.")
        }
        let tool = MCPTool(serverName: config.name, remote: found.spec, serverID: config.id, manager: manager,
                           annotations: found.annotations, siblings: catalog.tools.map(\.name))
        return (tool, try passedArguments(arguments["arguments"]))
    }

    /// The `arguments` object of the call; models sometimes send it as JSON text, or leave it out. Text that is no JSON
    /// object is an error the model can fix: sent as `{}`, the call would run without what it meant to pass.
    static func passedArguments(_ value: JSONValue?) throws -> JSONValue {
        switch value {
        case .object?: return value ?? .object([:])
        case .string(let text)? where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return .object([:])
        case .string(let text)?:
            if case .object? = JSONValue.parse(text) { return JSONValue.parse(text) ?? .object([:]) }
            throw ToolError(Self.invalidArguments(text))
        case nil, .null?: return .object([:])
        default: throw ToolError(Self.invalidArguments(value?.jsonString ?? ""))
        }
    }

    /// The `tools` of a connector_tools call: a list, or text that holds one (JSON like `arguments`, or names separated by
    /// commas or line breaks). nil lists everything.
    static func requestedNames(_ value: JSONValue?) -> [String]? {
        if let list = value?.array { return list.compactMap(\.string) }
        guard let text = value?.string else { return nil }
        if case .array(let items)? = JSONValue.parse(text) { return items.compactMap(\.string) }
        let names = text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    static func invalidArguments(_ text: String) -> String {
        "arguments precisa ser um objeto JSON ({\"campo\": valor}); recebi: \(text.prefix(200)). Corrija e chame de novo."
    }
}

/// `connector_tools`: the tools of one connector and their arguments.
struct ConnectorToolsTool: AgentTool {
    let connectors: [MCPServerConfig]
    let manager: MCPManager
    let spec: ToolSpec

    init(connectors: [MCPServerConfig], manager: MCPManager) {
        self.connectors = connectors
        self.manager = manager
        spec = ToolSpec(
            name: ConnectorGateway.toolsName,
            description: "Lists a connector's tools and their arguments. Call it before connector_call. Connectors:\n"
                + ConnectorGateway.index(for: connectors),
            parameters: .schema([
                "connector": .property("string"),
                "tools": .object(["type": .string("array"), "items": .property("string")]),
            ], required: ["connector"]))
    }

    var kind: ToolCall.Kind { .connector }
    var capability: Capability? { .connectors }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Vendo as ferramentas de \(arguments["connector"]?.string ?? "um conector")", "")
    }

    func connectingNote(_ arguments: JSONValue) async -> String? {
        guard let config = try? ConnectorGateway.connector(named: arguments["connector"]?.string ?? "", in: connectors),
              await manager.catalog(config.id) == nil else { return nil }
        return "Conectando a \(config.name)…"
    }

    func prepare(_ arguments: JSONValue) async throws {
        let config = try ConnectorGateway.connector(named: try arguments.requiredString("connector"), in: connectors)
        try await manager.ensureStarted(config.id)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let config = try ConnectorGateway.connector(named: try arguments.requiredString("connector"), in: connectors)
        // What the server offered last time is enough; a connector that has never run is started to find out.
        if await manager.catalog(config.id) == nil { try await manager.ensureStarted(config.id) }
        guard let catalog = await manager.catalog(config.id) else {
            throw ToolError("O conector \(config.name) não listou as ferramentas.")
        }
        let names = ConnectorGateway.requestedNames(arguments["tools"])
        return ConnectorGateway.render(catalog, connector: config.name, only: names)
    }
}

/// `connector_call`: runs one tool of a connector. The engine replaces the call by the tool's own before it runs, so
/// `run` only happens when that failed, and then says why.
struct ConnectorCallTool: AgentTool {
    let connectors: [MCPServerConfig]
    let manager: MCPManager
    let spec = ToolSpec(
        name: ConnectorGateway.callName,
        description: "Runs one tool of a connector listed in connector_tools.",
        parameters: .schema([
            "connector": .property("string"),
            "tool": .property("string"),
            "arguments": .property("object"),
        ], required: ["connector", "tool", "arguments"]))

    var kind: ToolCall.Kind { .connector }
    var capability: Capability? { .connectors }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Usando \(arguments["connector"]?.string ?? "um conector")", arguments["tool"]?.string ?? "")
    }

    /// The tool the call names, or what is wrong with it.
    func resolve(_ arguments: JSONValue) async throws -> (tool: MCPTool, arguments: JSONValue) {
        try await ConnectorGateway.resolve(arguments, connectors: connectors, manager: manager)
    }

    /// Never runs the tool itself: that would skip the permission policy, which only sees the resolved call.
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        _ = try await resolve(arguments)
        throw ToolError("A chamada não pôde ser executada. Tente de novo.")
    }
}
