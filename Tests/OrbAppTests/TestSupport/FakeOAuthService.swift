import Foundation
import os
@testable import Orb

/// A fake network for the login tests: URLSession asks it, never the internet. It answers by host from a handler and writes
/// down every request (with its body), so a test can check what was sent, to whom and in which order.
final class FakeNetwork: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: String

        var json: JSONValue? { JSONValue.parse(body) }

        /// The body of a form post, decoded.
        var form: [String: String] {
            var result: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).removingPercentEncoding ?? ""
            }
            return result
        }

        /// "mcp POST /mcp": which side of the fake service was asked, how, and where.
        var label: String { "\(url.host()?.split(separator: "-").first.map(String.init) ?? "") \(method) \(url.path)" }
    }

    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first }, body: text)
        }
    }

    final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Request] = []
        let handler: @Sendable (Request) -> Reply

        init(handler: @escaping @Sendable (Request) -> Reply) { self.handler = handler }

        var requests: [Request] { lock.withLock { seen } }
        func note(_ request: Request) { lock.withLock { seen.append(request) } }
    }

    static let worlds = OSAllocatedUnfairLock<[String: World]>(initialState: [:])

    /// A session whose requests to `hosts` are answered by `handler`.
    static func session(hosts: [String], handler: @escaping @Sendable (Request) -> Reply) -> (URLSession, World) {
        let world = World(handler: handler)
        worlds.withLock { for host in hosts { $0[host] = world } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeNetwork.self]
        return (URLSession(configuration: configuration), world)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let world = Self.worlds.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let seen = Request(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
                           body: String(decoding: body, as: UTF8.self))
        world.note(seen)
        let reply = world.handler(seen)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A made-up service with an MCP server and an authorization server, in the shape the spec describes (the way Notion's is):
/// 401 with `WWW-Authenticate`, the metadata documents, registration, the token endpoint and an MCP endpoint that answers only
/// to the access token it handed out. The knobs change what it offers; the requests it saw are in `requests`.
final class FakeOAuthService: @unchecked Sendable {
    private let lock = NSLock()
    private var knobs = Knobs()

    struct Knobs: Sendable {
        /// What the MCP endpoint accepts as `Authorization: Bearer …`.
        var validToken = "at-1"
        var challengeScope: String?
        var challengeHeader: String?
        var challengeStatus = 401
        var methods: [String]? = ["S256"]
        var authMethods = ["none"]
        var offersRegistration = true
        var advertisesIss = false
        var revocation = false
        var issuerInMetadata: String?
        var scopesSupported = ["read", "write"]
        var resourceInMetadata: String?
        var onToken: @Sendable (FakeNetwork.Request) -> FakeNetwork.Reply = { request in
            request.form["grant_type"] == "refresh_token"
                ? .json(#"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600,"token_type":"Bearer"}"#)
                : .json(#"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer","scope":"read write"}"#)
        }
        var onTool: @Sendable (String) -> FakeNetwork.Reply? = { _ in nil }
    }

    let id = UUID().uuidString.prefix(8).lowercased()
    private(set) var session = URLSession.shared
    private(set) var world = FakeNetwork.World { _ in .init() }

    var mcpHost: String { "mcp-\(id).test" }
    var authHost: String { "auth-\(id).test" }
    var mcpURL: String { "https://\(mcpHost)/mcp" }
    var issuer: String { "https://\(authHost)" }
    var requests: [FakeNetwork.Request] { world.requests }

    init(_ configure: (inout Knobs) -> Void = { _ in }) {
        configure(&knobs)
        let (session, world) = FakeNetwork.session(hosts: [mcpHost, authHost]) { [weak self] in self?.answer($0) ?? .init(status: 404) }
        self.session = session
        self.world = world
    }

    func change(_ edit: (inout Knobs) -> Void) { lock.withLock { edit(&knobs) } }

    private func answer(_ request: FakeNetwork.Request) -> FakeNetwork.Reply {
        let knobs = lock.withLock { self.knobs }
        let path = request.url.path
        if request.url.host() == mcpHost {
            if path.hasPrefix("/.well-known/oauth-protected-resource") {
                let resource = knobs.resourceInMetadata ?? mcpURL
                return .json(#"{"resource":"\#(resource)","authorization_servers":["\#(issuer)"],"scopes_supported":\#(Self.array(knobs.scopesSupported))}"#)
            }
            guard path == "/mcp" else { return .init(status: 404) }
            guard request.headers["Authorization"] == "Bearer \(knobs.validToken)" else {
                var parts = [#"resource_metadata="https://\#(mcpHost)/.well-known/oauth-protected-resource/mcp""#]
                if let scope = knobs.challengeScope { parts.append(#"scope="\#(scope)""#) }
                let header = knobs.challengeHeader ?? "Bearer " + parts.joined(separator: ", ")
                return .init(status: knobs.challengeStatus, headers: ["WWW-Authenticate": header])
            }
            return mcp(request, knobs)
        }
        switch path {
        case "/.well-known/oauth-authorization-server":
            let issuer = knobs.issuerInMetadata ?? self.issuer
            var json = #"{"issuer":"\#(issuer)","authorization_endpoint":"\#(self.issuer)/authorize","token_endpoint":"\#(self.issuer)/token""#
            if knobs.offersRegistration { json += #","registration_endpoint":"\#(self.issuer)/register""# }
            if let methods = knobs.methods { json += #","code_challenge_methods_supported":\#(Self.array(methods))"# }
            json += #","token_endpoint_auth_methods_supported":\#(Self.array(knobs.authMethods))"#
            if knobs.revocation { json += #","revocation_endpoint":"\#(self.issuer)/revoke""# }
            if knobs.advertisesIss { json += #","authorization_response_iss_parameter_supported":true"# }
            return .json(json + "}")
        case "/register":
            return .json(#"{"client_id":"dyn-\#(id)"}"#, status: 201)
        case "/token":
            return knobs.onToken(request)
        case "/revoke":
            return .init()
        default:
            return .init(status: 404)
        }
    }

    private func mcp(_ request: FakeNetwork.Request, _ knobs: Knobs) -> FakeNetwork.Reply {
        guard request.method == "POST", let message = request.json, let method = message["method"]?.string else { return .init(status: 405) }
        guard let requestID = message["id"]?.int else { return .init(status: 202) }
        func result(_ body: String, headers: [String: String] = [:]) -> FakeNetwork.Reply {
            .json(#"{"jsonrpc":"2.0","id":\#(requestID),"result":\#(body)}"#, headers: headers)
        }
        switch method {
        case "initialize":
            return result(#"{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"0"}}"#,
                          headers: ["Mcp-Session-Id": "s-\(id)"])
        case "tools/list":
            return result(#"{"tools":[{"name":"echo","description":"Echo","inputSchema":{"type":"object"}}]}"#)
        case "tools/call":
            let name = message["params"]?["name"]?.string ?? ""
            return knobs.onTool(name) ?? result(#"{"content":[{"type":"text","text":"ok"}]}"#)
        default:
            return .json(#"{"jsonrpc":"2.0","id":\#(requestID),"error":{"code":-32601,"message":"nope"}}"#)
        }
    }

    private static func array(_ items: [String]) -> String { "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]" }

    // MARK: The browser

    /// Stands in for the person in the browser: opens nothing, remembers the authorization address and "approves" it by
    /// calling the redirect on the loopback the Orb opened. `answer` edits what the redirect carries (a wrong `state`, an `iss`…).
    final class Browser: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [URL] = []
        private let answer: @Sendable (inout [String: String]) -> Void

        init(answer: @escaping @Sendable (inout [String: String]) -> Void = { _ in }) { self.answer = answer }

        var urls: [URL] { lock.withLock { opened } }
        var last: URLComponents? { urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } }
        func value(_ name: String) -> String? { last?.queryItems?.first { $0.name == name }?.value }

        var open: MCPAuth.Opener {
            { [self] url in
                lock.withLock { opened.append(url) }
                var query: [String: String] = ["code": "code-1", "state": value("state") ?? ""]
                answer(&query)
                guard var redirect = URLComponents(string: value("redirect_uri") ?? "") else { return }
                redirect.host = "127.0.0.1"
                redirect.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                if let target = redirect.url { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
            }
        }
    }
}
