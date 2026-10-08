import Foundation

/// A server listed in the official MCP Registry, reduced to what the app can install.
struct RegistryServer: Identifiable, Hashable, Sendable {
    /// Reverse-DNS name, e.g. "io.github.owner/server" (the namespace is verified by the registry).
    let id: String
    let title: String
    let summary: String
    /// Ready-to-edit connector (secrets left blank for the user to fill in).
    let config: MCPServerConfig
    /// Variables or headers the user must (or may) fill in.
    let inputs: [Input]

    struct Input: Hashable, Sendable {
        let name: String
        let summary: String
        let isSecret: Bool
        let isRequired: Bool
    }

    var kindLabel: String {
        config.isRemote ? "Remoto" : config.command == "docker" ? "Local · Docker" : "Local · \(config.command)"
    }

    /// The registry's own reference servers.
    var isOfficial: Bool { id.hasPrefix("io.modelcontextprotocol") || id.hasPrefix("io.github.modelcontextprotocol") }
}

/// Searches https://registry.modelcontextprotocol.io (search is a substring match on the server name).
struct MCPRegistry: Sendable {
    static let shared = MCPRegistry()

    var baseURL = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!
    var session = URLSession.shared

    func search(_ query: String, limit: Int = 40) async throws -> [RegistryServer] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "version", value: "latest"),
                                  URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { return [] }
        // The registry can be slow; give it time and say so in the UI.
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 60))
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { throw CatalogError.invalidResponse }
        var seen = Set<String>()
        return (json["servers"]?.array ?? []).compactMap { entry in
            let status = entry["_meta"]?["io.modelcontextprotocol.registry/official"]?["status"]?.string
            guard status == nil || status == "active", let server = Self.server(from: entry["server"] ?? .null),
                  seen.insert(server.id).inserted else { return nil }
            return server
        }
    }

    /// Maps one registry entry to an installable server; nil when no option is supported
    /// (we run npm, PyPI and Docker packages over stdio, and remote Streamable HTTP / SSE endpoints).
    static func server(from json: JSONValue) -> RegistryServer? {
        guard let name = json["name"]?.string else { return nil }
        let title = json["title"]?.string ?? name.split(separator: "/").last.map(String.init) ?? name
        var config: MCPServerConfig
        var inputs: [RegistryServer.Input] = []

        if let package = (json["packages"]?.array ?? []).first(where: { localCommand(for: $0) != nil }),
           let launch = localCommand(for: package) {
            config = MCPServerConfig(name: title, command: launch.command, arguments: launch.arguments)
            for variable in package["environmentVariables"]?.array ?? [] {
                guard let input = input(from: variable) else { continue }
                inputs.append(input)
                config.environment[input.name] = variable["default"]?.string ?? ""
            }
        } else if let remote = preferredRemote(json["remotes"]?.array ?? []), let url = remote["url"]?.string, !url.contains("{") {
            config = MCPServerConfig(name: title, url: url)
            for header in remote["headers"]?.array ?? [] {
                guard let input = input(from: header) else { continue }
                inputs.append(input)
                config.headers[input.name] = header["value"]?.string.flatMap { $0.contains("{") ? nil : $0 } ?? ""
            }
        } else {
            return nil
        }
        config.source = name
        return RegistryServer(id: name, title: title, summary: json["description"]?.string ?? "", config: config, inputs: inputs)
    }

    /// Streamable HTTP when offered, otherwise legacy SSE.
    private static func preferredRemote(_ remotes: [JSONValue]) -> JSONValue? {
        remotes.first { $0["type"]?.string == "streamable-http" } ?? remotes.first { $0["type"]?.string == "sse" }
    }

    /// `npx -y pkg@version`, `uvx pkg==version` or `docker run -i --rm image`, plus the package's fixed arguments.
    private static func localCommand(for package: JSONValue) -> (command: String, arguments: [String])? {
        guard let identifier = package["identifier"]?.string,
              (package["transport"]?["type"]?.string ?? "stdio") == "stdio" else { return nil }
        let version = package["version"]?.string ?? ""
        let extra = arguments(package["packageArguments"])
        switch package["registryType"]?.string {
        case "npm":
            return ("npx", ["-y", version.isEmpty ? identifier : "\(identifier)@\(version)"] + extra)
        case "pypi":
            return ("uvx", [version.isEmpty ? identifier : "\(identifier)==\(version)"] + extra)
        case "oci":
            let image = identifier.contains(":") || version.isEmpty ? identifier : "\(identifier):\(version)"
            return ("docker", ["run", "-i", "--rm"] + arguments(package["runtimeArguments"]) + [image] + extra)
        default:
            return nil
        }
    }

    /// Fixed arguments only: positional values and `--name value` pairs that need no user input.
    private static func arguments(_ list: JSONValue?) -> [String] {
        (list?.array ?? []).flatMap { argument -> [String] in
            guard let value = argument["value"]?.string ?? argument["default"]?.string, !value.contains("{") else { return [] }
            if argument["type"]?.string == "named", let name = argument["name"]?.string { return [name, value] }
            return [value]
        }
    }

    private static func input(from json: JSONValue) -> RegistryServer.Input? {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        return RegistryServer.Input(name: name, summary: json["description"]?.string ?? "",
                                    isSecret: json["isSecret"]?.bool ?? false, isRequired: json["isRequired"]?.bool ?? false)
    }
}
