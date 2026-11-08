import Foundation
import os

/// What `connector_install` asks of the app (`AppModel.installConnector`): the connector is saved like one added on the
/// Conectores page, started, and handed back with what the model is told.
typealias ConnectorInstallHandler = @Sendable (JSONValue) async throws -> ConnectorInstallResult

struct ConnectorInstallResult: Sendable {
    /// What the model reads (and the chat shows as the tool's result).
    let text: String
    /// The connector, when it was installed and is usable now (it joins this turn's `ConnectorRoster`).
    let config: MCPServerConfig?
}

/// The connectors one turn may reach through `connector_tools` and `connector_call`: the ones it began with, and any the
/// Orb installed during it (`connector_install`), so a connector installed mid-task is usable right away. The index in the
/// description of `connector_tools` stays the one the turn began with (it travels in every request of the turn).
final class ConnectorRoster: Sendable {
    private let list: OSAllocatedUnfairLock<[MCPServerConfig]>

    init(_ connectors: [MCPServerConfig]) { list = OSAllocatedUnfairLock(initialState: connectors) }

    var connectors: [MCPServerConfig] { list.withLock { $0 } }

    func add(_ config: MCPServerConfig) {
        list.withLock { list in
            if let index = list.firstIndex(where: { $0.id == config.id }) { list[index] = config } else { list.append(config) }
        }
    }
}

/// `connector_install`: the Orb adds an MCP server as a connector, when the person asks or the task needs one, without the
/// person going to the Conectores page. It always shows the approval card first (it runs a program from the internet, or
/// reaches a new server), the connector appears on the Conectores page at once, starting, and the result lists its tools.
struct ConnectorInstallTool: AgentTool {
    static let name = "connector_install"

    let spec = ToolSpec(
        name: ConnectorInstallTool.name,
        description: """
        Install an MCP server as a connector (the person approves), start it and list its tools; then use connector_call. \
        Local: command + args (npx -y pkg, uvx pkg). Remote: url. Keys in env (local) or headers (remote), kept in the \
        Keychain. Only what the person asked for or the task needs, from its official docs.
        """,
        parameters: .schema([
            "name": .property("string"),
            "command": .property("string"),
            "args": .object(["type": .string("array"), "items": .property("string")]),
            "env": .object(["type": .string("object"), "additionalProperties": .property("string")]),
            "url": .property("string"),
            "headers": .object(["type": .string("object"), "additionalProperties": .property("string")]),
            "summary": .property("string"),
            "all_orbs": .property("boolean"),
        ], required: ["name"]))

    var kind: ToolCall.Kind { .connector }
    /// Offered to every Orb: installing is how one without connectors gets its first (and the switch turns on with it).
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    /// Always asks (even in "Automático"): it runs a program from the internet, or sends requests to a new server, from now on.
    func danger(_ arguments: JSONValue) -> String? {
        arguments["url"]?.string.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } == true
            ? "conecta o Orb a um servidor novo, que recebe o que o Orb mandar a ele"
            : "instala e roda um programa da internet como conector"
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let name = arguments["name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = name.isEmpty ? "Instalando um conector" : "Instalando o conector \(name)"
        // The names of what goes with it (never the values: they may be keys), so the card hides nothing that changes the run.
        let scope = arguments.flag("all_orbs") ? " · para todos os Orbs" : ""
        func names(_ key: String) -> String? {
            guard case .object(let object)? = arguments[key], !object.isEmpty else { return nil }
            return "\(key): " + object.keys.sorted().joined(separator: ", ")
        }
        if let url = arguments["url"]?.string, !url.trimmingCharacters(in: .whitespaces).isEmpty {
            return (title, ([url] + [names("headers")].compactMap { $0 }).joined(separator: " · ") + scope)
        }
        let args = arguments["args"]?.array?.compactMap(ConnectorInstallRequest.text) ?? arguments["args"]?.string.map { [$0] } ?? []
        let line = ([arguments["command"]?.string ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (title, ([line] + [names("env")].compactMap { $0 }).joined(separator: " · ") + scope)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let install = context.installConnector else { throw ToolError("Instalar conectores não está disponível agora.") }
        let result = try await install(arguments)
        if let config = result.config { context.connectorRoster?.add(config) }
        return result.text
    }
}

/// One `connector_install` call, read and checked before anything is saved.
struct ConnectorInstallRequest: Equatable {
    var name: String
    var command = ""
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var url = ""
    var headers: [String: String] = [:]
    var summary: String?
    var allOrbs = false

    var isRemote: Bool { !url.isEmpty }

    init(_ arguments: JSONValue, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws {
        name = (arguments["name"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw ToolError("Diga o nome do conector em name.") }
        name = String(name.prefix(ConnectorGateway.nameLimit))
        url = (arguments["url"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (arguments["command"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Numbers and booleans in args count as text; an array is an argv, a lone string is read like a line of the form.
        let argsArray = arguments["args"]?.array
        let args = argsArray?.compactMap(Self.text) ?? arguments["args"]?.string.map { [$0] } ?? []
        if !url.isEmpty {
            guard command.isEmpty else { throw ToolError("Use command (servidor local) ou url (remoto), não os dois.") }
            guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                throw ToolError("url precisa ser um endereço http(s) completo, como https://exemplo.com/mcp.")
            }
            guard try Self.pairs(arguments["env"], what: "env").isEmpty else {
                throw ToolError("env só vale para servidor local (command). Em um servidor remoto (url), passe as chaves em headers.")
            }
            headers = try Self.pairs(arguments["headers"], what: "headers")
        } else {
            guard !command.isEmpty else { throw ToolError("Diga command (e args) de um servidor local, ou url de um remoto.") }
            // As a README writes it ("npx -y pkg" in one line) works too, the same way the Conectores form reads it.
            let parsed = ConnectorArguments.parse(command: command, arguments: args, literalArguments: argsArray != nil, fileExists: fileExists)
            self.command = parsed.command
            self.arguments = parsed.arguments
            environment = try Self.pairs(arguments["env"], what: "env")
        }
        let summary = (arguments["summary"]?.string ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        self.summary = summary.isEmpty ? nil : String(summary.prefix(200))
        allOrbs = arguments.flag("all_orbs")
    }

    /// A string, number or boolean as the text a program receives.
    fileprivate static func text(_ item: JSONValue) -> String? {
        let number = item.number.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String($0) }
        return item.string ?? number ?? item.bool.map(String.init)
    }

    /// A `{"NAME": "value"}` object; names are what a variable or a header can be called.
    private static func pairs(_ value: JSONValue?, what: String) throws -> [String: String] {
        guard let value, value != .null else { return [:] }
        guard case .object(let object) = value else { throw ToolError("\(what) precisa ser um objeto {\"NOME\": \"valor\"}.") }
        var pairs: [String: String] = [:]
        for (key, item) in object {
            let name = key.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                throw ToolError("Nome inválido em \(what): \(key.prefix(60)).")
            }
            guard let text = Self.text(item)
            else { throw ToolError("O valor de \(name) em \(what) precisa ser texto.") }
            pairs[name] = text
        }
        return pairs
    }

    /// Whether `config` is this same server (the same program and arguments, or the same address): it is not installed twice.
    func isSameServer(as config: MCPServerConfig) -> Bool {
        guard config.local == nil else { return false }
        if isRemote { return config.url.trimmingCharacters(in: .whitespaces).lowercased() == url.lowercased() }
        return config.url.isEmpty && config.command == command && config.arguments == arguments
    }
}
