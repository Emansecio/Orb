import Foundation

// OAuth 2.1 for remote connectors, as the MCP authorization spec describes it (2025-11-25, with the issuer check of 2026-07-28):
// the server answers 401 with a WWW-Authenticate; the Protected Resource Metadata (RFC 9728) names the authorization server,
// whose metadata (RFC 8414 or OpenID Connect) says where to sign in; the client is a pre-registered one or one registered
// on the spot (RFC 7591); PKCE `S256` is mandatory; the browser comes back through a loopback address.

/// How a connector signs in, besides what the server tells. Never holds a secret: the Client Secret lives with the tokens
/// in the Keychain (`MCPOAuthCredential`).
struct MCPOAuthSettings: Codable, Hashable, Sendable {
    /// The app the person (or a ready-made model) registered with the service. nil: the Orb registers itself, when the service lets.
    var clientID: String?
    /// The editor asks for a Client Secret too, and signing in waits for it.
    var needsClientSecret = false
    /// The scopes to ask for, space separated, when the server does not name any.
    var scopes: String?
    /// Extra parameters of the authorization request (Google: `access_type=offline`, `prompt=consent`).
    var authorizeParameters: [String: String] = [:]
    /// The redirect address of an app registered to the letter (Slack compares the port too). nil: `http://127.0.0.1:<port>/callback`.
    var redirect: String?

    init(clientID: String? = nil, needsClientSecret: Bool = false, scopes: String? = nil,
         authorizeParameters: [String: String] = [:], redirect: String? = nil) {
        self.clientID = clientID
        self.needsClientSecret = needsClientSecret
        self.scopes = scopes
        self.authorizeParameters = authorizeParameters
        self.redirect = redirect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID = (try? c.decodeIfPresent(String.self, forKey: .clientID)) ?? nil
        needsClientSecret = (try? c.decodeIfPresent(Bool.self, forKey: .needsClientSecret)) ?? false
        scopes = (try? c.decodeIfPresent(String.self, forKey: .scopes)) ?? nil
        authorizeParameters = (try? c.decodeIfPresent([String: String].self, forKey: .authorizeParameters)) ?? [:]
        redirect = (try? c.decodeIfPresent(String.self, forKey: .redirect)) ?? nil
    }
}

/// What a login leaves in the Keychain (account `mcp.<id>.oauth`, as JSON): the client, the tokens and where they came from.
/// Never in `state.json`, in a log or in a URL.
struct MCPOAuthCredential: Codable, Sendable, Equatable {
    var issuer: String?
    var clientID: String?
    var clientSecret: String?
    /// The port the redirect was registered with when the client was registered by the Orb (nil: pre-registered).
    var registrationPort: UInt16?
    var accessToken = ""
    var refreshToken: String?
    var expiresAt: Date?
    /// What was granted, space separated.
    var scopes = ""
    var tokenEndpoint: String?
    /// How the token endpoint wants the client to identify itself: `basic`, `post` or `none`.
    var authMethod: String?
    var resource: String?
    /// Where the service takes a token back (RFC 7009), when its metadata says.
    var revocationEndpoint: String?

    var hasToken: Bool { !accessToken.isEmpty }
}

/// The parameters of a Bearer challenge (`WWW-Authenticate`, RFC 6750 and 9728).
struct MCPChallenge: Equatable, Sendable {
    var resourceMetadata: URL?
    var scope: String?
    var error: String?
    /// The header offered the Bearer scheme (the server wants an access token, not some other key).
    var isBearer: Bool

    init(resourceMetadata: URL? = nil, scope: String? = nil, error: String? = nil, isBearer: Bool = false) {
        self.resourceMetadata = resourceMetadata
        self.scope = scope
        self.error = error
        self.isBearer = isBearer
    }

    /// Reads the Bearer challenge of the header; other schemes in the same header are skipped.
    init(header: String?) {
        var parameters: [String: String] = [:]
        let text = Array(header ?? "")
        var index = 0
        var isBearer = false, sawBearer = false
        func skip(_ characters: Set<Character>) { while index < text.count, characters.contains(text[index]) { index += 1 } }
        func word() -> String {
            let start = index
            while index < text.count, !" =,".contains(text[index]) { index += 1 }
            return String(text[start..<index])
        }
        while index < text.count {
            skip([" ", ","])
            let name = word()
            let wordEnd = index
            skip([" "])
            guard index < text.count, text[index] == "=" else {
                // No "=": a scheme name (or a token68 of another scheme).
                if !name.isEmpty {
                    isBearer = name.lowercased() == "bearer"
                    sawBearer = sawBearer || isBearer
                }
                if index == wordEnd { index += 1 }
                continue
            }
            index += 1
            skip([" "])
            var value = ""
            if index < text.count, text[index] == "\"" {
                index += 1
                while index < text.count, text[index] != "\"" {
                    if text[index] == "\\", index + 1 < text.count { index += 1 }
                    value.append(text[index])
                    index += 1
                }
                index += 1
            } else {
                value = word()
            }
            if isBearer { parameters[name.lowercased()] = value }
        }
        resourceMetadata = parameters["resource_metadata"].flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
        scope = parameters["scope"].flatMap { $0.isEmpty ? nil : $0 }
        error = parameters["error"]
        self.isBearer = sawBearer
    }
}

/// The server wants a login (or a better one) before it answers. Thrown by the transport, turned into a status by `MCPManager`.
struct MCPAuthRequired: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// No login yet.
        case signIn
        /// The login stopped working and could not be renewed.
        case expired
        /// The login works but does not cover what was asked (403 `insufficient_scope`).
        case moreScope
    }

    var reason: Reason
    var challenge = MCPChallenge()
}

/// Gives the access token of a connector for each request (`force`: the one in use was just refused), or nil when there is no login.
typealias MCPTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String?

extension MCPServerConfig {
    /// A fixed `Authorization` header (a pasted key): then the connector does not sign in.
    var hasStaticAuthorization: Bool {
        headers.contains { $0.key.lowercased() == "authorization" && !$0.value.isEmpty }
    }

    /// A remote connector that may sign in: no fixed key, and an address that keeps the token from travelling in the clear.
    var canSignIn: Bool {
        isRemote && !hasStaticAuthorization && URL(string: url.trimmingCharacters(in: .whitespaces)).map(MCPAuth.isSecure) == true
    }
}

extension ConnectorSecrets {
    /// The Keychain account of a connector's login.
    nonisolated static func oauthAccount(id: UUID) -> String { "mcp.\(id.uuidString).oauth" }
}

// MARK: - Sign-in and renewal

/// The logins of the remote connectors: discovery, registration, the browser round trip, the token exchange, renewal and
/// sign-out. One credential per connector, in the vault; a renewal is shared by everyone who needs one (refresh tokens rotate,
/// so two renewals with the same token would make the second fail and sign the person out).
actor MCPAuth {
    typealias Opener = @Sendable (URL) async -> Void

    static let pkceRefusal = "Este serviço não oferece login seguro (PKCE). Conexão recusada."
    static let callbackPath = "/callback"
    /// A token this close to its end is renewed before it is used.
    static let renewalMargin: TimeInterval = 180

    /// Dedicated session: nothing cached on disk, cookies in memory only, redirects only within the same host.
    static let liveSession = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    private let vault: any SecretVault
    private let session: URLSession
    private let signInTimeout: Duration
    private var cache: [UUID: MCPOAuthCredential] = [:]
    /// The connectors whose account was looked for in the vault (found or not): a connector without a login does not ask again.
    private var looked: Set<UUID> = []
    /// The renewal in progress of each connector, shared by every caller that needs one.
    private var refreshing: [UUID: Task<MCPOAuthCredential, Error>] = [:]
    private var lastRefresh: [UUID: Date] = [:]
    /// Bumped by a sign-in or sign-out, so a renewal that was already waiting on the network does not bring the old login back.
    private var generation: [UUID: Int] = [:]

    init(vault: any SecretVault, session: URLSession = MCPAuth.liveSession, signInTimeout: Duration = .seconds(300)) {
        self.vault = vault
        self.session = session
        self.signInTimeout = signInTimeout
    }

    // MARK: Tokens

    /// The token provider of a connector that signs in; nil for one that does not (local, or with a fixed key).
    nonisolated func tokenProvider(for config: MCPServerConfig) -> MCPTokenProvider? {
        guard config.canSignIn else { return nil }
        let id = config.id
        return { [self] force in try await accessToken(id, forceRefresh: force) }
    }

    func credential(_ id: UUID) -> MCPOAuthCredential? {
        if looked.insert(id).inserted, let data = vault.get(ConnectorSecrets.oauthAccount(id: id))?.data(using: .utf8) {
            cache[id] = try? JSONDecoder().decode(MCPOAuthCredential.self, from: data)
        }
        return cache[id]
    }

    func isSignedIn(_ id: UUID) -> Bool { credential(id)?.hasToken == true }

    /// A valid access token, renewed shortly before it ends; nil when there is no login. `forceRefresh` is for a token the
    /// server just refused: if another caller renewed a moment ago, that fresh token is returned instead.
    /// Throws `MCPAuthRequired` when the login can no longer be renewed.
    func accessToken(_ id: UUID, forceRefresh: Bool = false, minimumLife: TimeInterval = MCPAuth.renewalMargin) async throws -> String? {
        guard let current = credential(id), current.hasToken else { return nil }
        let left = current.expiresAt?.timeIntervalSinceNow
        let ending = left.map { $0 < minimumLife } ?? false
        let justRefreshed = lastRefresh[id].map { -$0.timeIntervalSinceNow < 10 } ?? false
        if !(ending || (forceRefresh && !justRefreshed)) && refreshing[id] == nil { return current.accessToken }
        // A token that has not ended yet still works when nothing can renew it (no refresh token) or the renewal failed for a passing reason.
        let stillWorks = !forceRefresh && (left ?? 1) > 0
        if stillWorks && current.refreshToken == nil { return current.accessToken }
        do {
            return try await refresh(id, current).accessToken
        } catch is ToolError where stillWorks {
            return current.accessToken
        }
    }

    /// `servers` with the Bearer of each connector that has a login, renewed if less than `minimumLife` is left: for Claude
    /// Code, which reads the headers once and cannot renew in the middle of a turn.
    func withBearer(_ servers: [MCPServerConfig], minimumLife: TimeInterval = 1800) async -> [MCPServerConfig] {
        var result = servers
        for index in result.indices where result[index].canSignIn {
            if let token = try? await accessToken(result[index].id, minimumLife: minimumLife) {
                result[index].headers["Authorization"] = "Bearer \(token)"
            }
        }
        return result
    }

    /// Joins the renewal in progress or starts one.
    private func refresh(_ id: UUID, _ current: MCPOAuthCredential) async throws -> MCPOAuthCredential {
        if let running = refreshing[id] { return try await running.value }
        let started = generation[id, default: 0]
        let task = Task { () throws -> MCPOAuthCredential in
            let fresh: MCPOAuthCredential
            do {
                fresh = try await renew(current)
            } catch {
                // Signing in or out cancelled this: whoever waits is told there is no login, not a raw cancellation.
                if generation[id, default: 0] != started { throw MCPAuthRequired(reason: .signIn) }
                if let refused = error as? TokenRefused {
                    guard Self.endedLogins.contains(refused.code) else {
                        throw ToolError("O serviço de login recusou renovar a sessão (\(refused.code)).")
                    }
                    // The service no longer honours the login (a client it forgot is forgotten here too): the login is over.
                    forgetTokens(id, dropsClient: refused.code == "invalid_client")
                    throw MCPAuthRequired(reason: .expired)
                }
                if error is MCPAuthRequired { forgetTokens(id) } // no refresh token to use
                throw error
            }
            guard generation[id, default: 0] == started else { throw MCPAuthRequired(reason: .signIn) }
            cache[id] = fresh
            _ = persist(fresh, id)
            lastRefresh[id] = .now
            return fresh
        }
        refreshing[id] = task
        defer { if generation[id, default: 0] == started { refreshing[id] = nil } }
        return try await task.value
    }

    /// What the token endpoint answers when the login can no longer be renewed: `invalid_refresh_token` is Slack's, in an HTTP 200.
    private static let endedLogins: Set<String> = ["invalid_grant", "invalid_client", "unauthorized_client", "invalid_refresh_token"]

    /// The network part of a renewal. Throws `TokenRefused` with the service's error when it refuses.
    private func renew(_ current: MCPOAuthCredential) async throws -> MCPOAuthCredential {
        guard let refresh = current.refreshToken, let endpoint = current.tokenEndpoint.flatMap(URL.init(string:)) else {
            throw MCPAuthRequired(reason: .expired)
        }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh]
        if let resource = current.resource { form["resource"] = resource }
        let reply = try await tokenRequest(form, endpoint: endpoint, client: current)
        // The service may rotate the refresh token: the new one replaces the old, together with the new access token.
        return current.applying(reply, requestedScope: nil)
    }

    private func forgetTokens(_ id: UUID, dropsClient: Bool = false) {
        guard var current = credential(id) else { return }
        current.accessToken = ""
        current.refreshToken = nil
        current.expiresAt = nil
        if dropsClient && current.registrationPort != nil { // a client the Orb registered, and the service lost: the next login registers a new one
            current.clientID = nil
            current.clientSecret = nil
            current.registrationPort = nil
            current.issuer = nil
        }
        cache[id] = current
        _ = persist(current, id)
    }

    // MARK: Signing out

    /// Ends the login of a connector, keeping what the person typed for it (Client ID and Secret).
    func signOut(_ id: UUID) {
        generation[id, default: 0] += 1
        refreshing[id]?.cancel()
        refreshing[id] = nil
        if let current = credential(id) { revoke(current) }
        forgetTokens(id)
    }

    /// Erases the connector's account altogether (the connector was deleted).
    func deleteAccount(_ id: UUID) {
        generation[id, default: 0] += 1
        refreshing[id]?.cancel()
        refreshing[id] = nil
        if let current = credential(id) { revoke(current) }
        cache[id] = nil
        vault.remove(ConnectorSecrets.oauthAccount(id: id))
    }

    /// The Client Secret the person typed in the editor, saved straight to the connector's account (empty: forgets it). With the
    /// `clientID` it belongs to: then the account holds that app, not a client the Orb registered, and the sign-in keeps the secret.
    func setClientSecret(_ secret: String, clientID: String? = nil, for id: UUID) {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = clientID?.trimmingCharacters(in: .whitespaces).nonEmpty
        var current = credential(id) ?? MCPOAuthCredential()
        guard current.clientSecret != secret.nonEmpty || (app != nil && current.clientID != app) else { return }
        current.clientSecret = secret.nonEmpty
        if let app, !secret.isEmpty {
            current.clientID = app
            current.registrationPort = nil
        }
        cache[id] = current
        _ = persist(current, id)
    }

    @discardableResult
    private func persist(_ credential: MCPOAuthCredential, _ id: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        return vault.set(String(decoding: data, as: UTF8.self), account: ConnectorSecrets.oauthAccount(id: id))
    }

    /// Asks the service to drop the tokens being forgotten (RFC 7009), in the background and only if it said where. Best effort:
    /// if it fails, the tokens are gone from the Mac all the same.
    private func revoke(_ credential: MCPOAuthCredential) {
        guard let endpoint = credential.revocationEndpoint.flatMap(URL.init(string:)),
              let token = credential.refreshToken ?? credential.accessToken.nonEmpty else { return }
        let hint = credential.refreshToken == nil ? "access_token" : "refresh_token"
        Task { _ = try? await post(["token": token, "token_type_hint": hint], endpoint: endpoint, client: credential) }
    }

    // MARK: Signing in

    /// Logs the connector in: finds out how from the server, opens the browser, waits for the way back and keeps the tokens.
    /// `scope`: scopes to add to the ones already granted (the server asked for more). Throws `ToolError` with a message for the person.
    @discardableResult
    func signIn(_ config: MCPServerConfig, scope extraScope: String? = nil, open: Opener) async throws -> MCPOAuthCredential {
        do {
            return try await login(config, extraScope: extraScope, open: open)
        } catch is CancellationError {
            throw ToolError("Login cancelado.")
        }
    }

    private func login(_ config: MCPServerConfig, extraScope: String?, open: Opener) async throws -> MCPOAuthCredential {
        let id = config.id, name = config.name
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            throw ToolError("O endereço do conector \(name) é inválido.")
        }
        guard Self.isSecure(url) else { throw ToolError("O endereço do conector \(name) não usa HTTPS; o login foi recusado.") }
        let started = generation[id, default: 0]
        let settings = config.oauth ?? MCPOAuthSettings()
        let challenge = await probe(url)
        try Task.checkCancellation()
        let protectedResource = try await protectedResource(challenge: challenge, url: url, name: name)
        let server = try await authorizationServer(protectedResource.authorizationServer, name: name)
        guard server.challengeMethods.contains("S256") else { throw ToolError(Self.pkceRefusal) }

        // The way back. A pre-registered app may need its address to the letter; one the Orb registered keeps its port when it can.
        var stored = credential(id) ?? MCPOAuthCredential()
        let preRegistered = settings.clientID?.trimmingCharacters(in: .whitespaces).nonEmpty
        let reusable = preRegistered == nil && stored.clientID != nil && stored.issuer == server.issuer
        let fixed = settings.redirect.flatMap(URL.init(string:))
        let callback: LoopbackCallback
        do {
            let ports = fixed?.port.map { [UInt16($0)] } ?? (reusable ? stored.registrationPort.map { [$0] } ?? [] : [])
            callback = try await LoopbackCallback.open(path: fixed?.path ?? Self.callbackPath, preferredPorts: ports, exactPortOnly: fixed != nil)
        } catch {
            guard let port = fixed?.port else { throw error }
            throw ToolError("A porta \(port) do login está ocupada. Feche o que a usa e tente de novo.")
        }
        defer { callback.stop() }
        let redirect = fixed?.absoluteString ?? "http://127.0.0.1:\(callback.port)\(Self.callbackPath)"

        // The client: the registered app of the model or of the editor, the one the Orb registered before, or a new one.
        if let preRegistered {
            if stored.clientID != preRegistered || stored.registrationPort != nil {
                if stored.clientID != nil { stored.clientSecret = nil } // the secret of another app, or of a client the Orb registered, is not this app's
                stored.clientID = preRegistered
                stored.registrationPort = nil
            }
            if settings.needsClientSecret && stored.clientSecret?.nonEmpty == nil { throw Self.needsApp(name, secret: true) }
        } else if !(reusable && stored.registrationPort == callback.port) {
            guard let endpoint = server.registrationEndpoint else { throw Self.needsApp(name, secret: settings.needsClientSecret) }
            let registered = try await register(at: endpoint, redirect: redirect, name: name)
            stored.clientID = registered.clientID
            stored.clientSecret = registered.secret
            stored.registrationPort = callback.port
        }
        guard let clientID = stored.clientID else { throw Self.needsApp(name, secret: settings.needsClientSecret) }
        stored.issuer = server.issuer

        // The request. The issuer is noted before the browser opens: the answer is checked against it.
        let verifier = OAuthLoopback.randomToken(), state = OAuthLoopback.randomToken()
        let scope = Self.scopeToAsk(challenge: challenge, settings: settings, supported: protectedResource.scopes,
                                    granted: stored.hasToken ? stored.scopes : "", extra: extraScope,
                                    offersOffline: server.scopes.contains("offline_access"))
        var items = [("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect)]
        if let scope { items.append(("scope", scope)) }
        items += [("state", state), ("code_challenge", OAuthLoopback.challenge(for: verifier)), ("code_challenge_method", "S256"),
                  ("resource", protectedResource.resource)]
        for (key, value) in settings.authorizeParameters.sorted(by: { $0.key < $1.key }) where !items.contains(where: { $0.0 == key }) {
            items.append((key, value))
        }
        await open(Self.url(server.authorizationEndpoint, adding: items))

        let query = try await callback.wait(timeout: signInTimeout)
        try left(id, since: started)
        try Self.check(query, state: state, issuer: server.issuer, advertisesIssuer: server.advertisesIssuer, name: name)
        guard let code = query["code"] else { throw ToolError("O login não devolveu um código.") }

        // The exchange.
        stored.tokenEndpoint = server.tokenEndpoint.absoluteString
        stored.revocationEndpoint = server.revocationEndpoint?.absoluteString
        stored.authMethod = stored.clientSecret?.nonEmpty == nil ? "none"
            : (server.authMethods?.contains("client_secret_basic") ?? true) ? "basic"
            : server.authMethods?.contains("client_secret_post") == true ? "post" : "basic"
        let reply: JSONValue
        do {
            reply = try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                            "code_verifier": verifier, "resource": protectedResource.resource],
                                           endpoint: server.tokenEndpoint, client: stored)
        } catch let refused as TokenRefused {
            throw ToolError("O \(name) recusou o login: \(refused.detail ?? refused.code)")
        }
        try left(id, since: started)
        var fresh = stored.applying(reply, requestedScope: scope)
        fresh.resource = protectedResource.resource
        generation[id, default: 0] += 1 // a renewal of the old login that is still under way must not bring it back
        refreshing[id]?.cancel()
        refreshing[id] = nil
        cache[id] = fresh
        guard persist(fresh, id) else { throw ToolError("Não foi possível guardar o login no Keychain do Mac.") }
        lastRefresh[id] = .now
        return fresh
    }

    /// A sign-out or a deletion while the browser was open ends this login: nothing is kept for a connector the person has left.
    private func left(_ id: UUID, since started: Int) throws {
        guard generation[id, default: 0] == started else { throw ToolError("Login cancelado.") }
    }

    private static func needsApp(_ name: String, secret: Bool) -> ToolError {
        ToolError(secret ? "O \(name) pede um app registrado: cole o Client ID e o Client Secret."
                         : "O \(name) pede um app registrado: cole o Client ID (e o Client Secret, se o app tiver um).")
    }

    /// The scopes of the request: what the server's challenge says, else what the connector's model or the person chose, else everything
    /// the resource lists. To ask for more, the ones already granted stay in (a new grant would otherwise drop them).
    static func scopeToAsk(challenge: MCPChallenge?, settings: MCPOAuthSettings, supported: [String], granted: String,
                           extra: String?, offersOffline: Bool) -> String? {
        func words(_ text: String?) -> [String] { (text ?? "").split(separator: " ").map(String.init) }
        var scopes: [String]
        if let extra {
            scopes = words(granted)
            for scope in words(extra) where !scopes.contains(scope) { scopes.append(scope) }
        } else {
            scopes = words(challenge?.scope)
            if scopes.isEmpty { scopes = words(settings.scopes) }
            if scopes.isEmpty { scopes = supported }
        }
        if !scopes.isEmpty && offersOffline && !scopes.contains("offline_access") { scopes.append("offline_access") }
        return scopes.isEmpty ? nil : scopes.joined(separator: " ")
    }

    /// The checks on the way back, before the code goes anywhere (the spec's table for `iss`, RFC 9207). A mismatch is not
    /// explained with what the response says: it did not come from the server asked.
    static func check(_ query: [String: String], state: String, issuer: String, advertisesIssuer: Bool, name: String) throws {
        if let reported = query["iss"] {
            guard reported == issuer else { throw ToolError("A resposta do login não veio do serviço esperado; por segurança, a conexão foi recusada.") }
        } else if advertisesIssuer {
            throw ToolError("A resposta do login não veio do serviço esperado; por segurança, a conexão foi recusada.")
        }
        guard query["state"] == state else { throw ToolError("O login voltou com um estado inválido; tente de novo.") }
        if let error = query["error"] {
            throw ToolError(error == "access_denied" ? "Login cancelado." : "O \(name) recusou o login: \(query["error_description"] ?? error)")
        }
    }

    // MARK: Discovery

    private struct ProtectedResource {
        var resource: String
        var authorizationServer: String
        var scopes: [String]
    }

    private struct AuthorizationServer {
        var issuer: String
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var revocationEndpoint: URL?
        var challengeMethods: [String]
        var authMethods: [String]?
        var advertisesIssuer: Bool
        var scopes: [String]
    }

    /// Asks the server something without a token, to read how it wants a login. nil if it does not ask for one.
    private func probe(_ url: URL) async -> MCPChallenge? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                               "clientInfo": .object(["name": .string("Orb"), "version": .string("1.0")])]),
        ]).jsonString.utf8)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              http.statusCode == 401 else { return nil }
        return MCPChallenge(header: http.value(forHTTPHeaderField: "WWW-Authenticate"))
    }

    /// The Protected Resource Metadata (RFC 9728): the address in the challenge, else the well-known ones, in the spec's order.
    private func protectedResource(challenge: MCPChallenge?, url: URL, name: String) async throws -> ProtectedResource {
        let addresses = (challenge?.resourceMetadata.map { [$0] } ?? []) + Self.protectedResourceAddresses(for: url)
        for address in addresses {
            let found = await fetch(address)
            try Task.checkCancellation()
            guard let json = found, let server = json["authorization_servers"]?.array?.compactMap(\.string).first else { continue }
            let own = Self.canonical(url)
            var resource = own
            if let declared = json["resource"]?.string {
                // The resource may be broader than the endpoint (Slack names the host); one that does not cover it is not this server's.
                let broad = Self.canonical(declared)
                guard own == broad || own.hasPrefix(broad + "/") else {
                    throw ToolError("O \(name) indicou um recurso de login que não é o dele; conexão recusada.")
                }
                resource = broad
            }
            return ProtectedResource(resource: resource, authorizationServer: server,
                                     scopes: json["scopes_supported"]?.array?.compactMap(\.string) ?? [])
        }
        throw ToolError("O \(name) não explicou como entrar (sem metadados de login).")
    }

    /// The metadata of the authorization server: OAuth (RFC 8414), then OpenID Connect, in the spec's order.
    private func authorizationServer(_ issuer: String, name: String) async throws -> AuthorizationServer {
        guard let issuerURL = URL(string: issuer), Self.isSecure(issuerURL) else {
            throw ToolError("O \(name) indicou um serviço de login sem HTTPS; conexão recusada.")
        }
        for address in Self.authorizationServerAddresses(for: issuerURL) {
            let found = await fetch(address)
            try Task.checkCancellation()
            guard let json = found, let reported = json["issuer"]?.string,
                  Self.canonical(reported) == Self.canonical(issuer),
                  let authorize = json["authorization_endpoint"]?.string.flatMap(URL.init(string:)),
                  let token = json["token_endpoint"]?.string.flatMap(URL.init(string:)),
                  Self.isSecure(authorize), Self.isSecure(token) else { continue }
            return AuthorizationServer(
                issuer: reported, authorizationEndpoint: authorize, tokenEndpoint: token,
                registrationEndpoint: json["registration_endpoint"]?.string.flatMap(URL.init(string:)).flatMap { Self.isSecure($0) ? $0 : nil },
                revocationEndpoint: json["revocation_endpoint"]?.string.flatMap(URL.init(string:)).flatMap { Self.isSecure($0) ? $0 : nil },
                challengeMethods: json["code_challenge_methods_supported"]?.array?.compactMap(\.string) ?? [],
                authMethods: json["token_endpoint_auth_methods_supported"]?.array?.compactMap(\.string),
                advertisesIssuer: json["authorization_response_iss_parameter_supported"]?.bool == true,
                scopes: json["scopes_supported"]?.array?.compactMap(\.string) ?? [])
        }
        throw ToolError("O serviço de login do \(name) não respondeu como esperado.")
    }

    /// Where the Protected Resource Metadata of `url` may be: at the path of the endpoint, then at the root.
    static func protectedResourceAddresses(for url: URL) -> [URL] {
        wellKnown("oauth-protected-resource", on: url, path: url.path)
    }

    /// Where the metadata of the authorization server `issuer` may be, in the order the spec fixes: OAuth with the path inserted,
    /// OpenID Connect with the path inserted, OpenID Connect with the path appended (the last two only when the issuer has a path).
    static func authorizationServerAddresses(for issuer: URL) -> [URL] {
        let path = issuer.path.hasSuffix("/") ? String(issuer.path.dropLast()) : issuer.path
        let appended = path.isEmpty ? [] : [URL(string: origin(of: issuer) + path + "/.well-known/openid-configuration")].compactMap { $0 }
        return wellKnown("oauth-authorization-server", on: issuer, path: path, includesRoot: path.isEmpty)
            + wellKnown("openid-configuration", on: issuer, path: path, includesRoot: path.isEmpty) + appended
    }

    /// `/.well-known/<name>` with the path of the endpoint inserted after it, then (if asked) without the path.
    private static func wellKnown(_ name: String, on url: URL, path: String, includesRoot: Bool = true) -> [URL] {
        let path = path.hasSuffix("/") ? String(path.dropLast()) : path
        let root = origin(of: url) + "/.well-known/" + name
        return ((path.isEmpty ? [] : [root + path]) + (includesRoot ? [root] : [])).compactMap { URL(string: $0) }
    }

    private static func origin(of url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "https")://\((url.host(percentEncoded: true) ?? "").lowercased())\(url.port.map { ":\($0)" } ?? "")"
    }

    /// The identifier of a server for the `resource` parameter (RFC 8707): the address without query, fragment or final slash.
    static func canonical(_ url: URL) -> String {
        var text = origin(of: url) + url.path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func canonical(_ text: String) -> String { URL(string: text).map(canonical) ?? text }

    /// Authorization servers are reached over HTTPS; a loopback address may use plain HTTP (a server being developed).
    static func isSecure(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host() ?? ""))
    }

    /// A JSON document, or nil if the address does not answer with one.
    private func fetch(_ address: URL) async -> JSONValue? {
        guard ["http", "https"].contains(address.scheme) else { return nil }
        var request = URLRequest(url: address, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), case .object = json else { return nil }
        return json
    }

    // MARK: Registration and tokens

    /// Registers the Orb as a native app (RFC 7591) with the redirect it will use.
    private func register(at endpoint: URL, redirect: String, name: String) async throws -> (clientID: String, secret: String?) {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(JSONValue.object([
            "client_name": .string("Orb"),
            "redirect_uris": .array([.string(redirect)]),
            "application_type": .string("native"),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]).jsonString.utf8)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode), let json = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let clientID = json["client_id"]?.string else {
            throw ToolError("O \(name) não aceitou o registro do Orb (HTTP \(response.statusCode)).")
        }
        return (clientID, json["client_secret"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    private struct TokenRefused: Error {
        var code: String
        var detail: String?
    }

    /// A call to the token endpoint, with the client identifying itself the way the service wants. Returns the reply when it
    /// holds an access token; throws `TokenRefused` with the service's error otherwise. Nothing sent is ever put in an error.
    private func tokenRequest(_ form: [String: String], endpoint: URL, client: MCPOAuthCredential) async throws -> JSONValue {
        let (data, response) = try await post(form, endpoint: endpoint, client: client)
        let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        if (200..<300).contains(response.statusCode), json?["error"] == nil, json?["access_token"]?.string != nil, let json { return json }
        throw TokenRefused(code: json?["error"]?.string ?? "HTTP \(response.statusCode)", detail: json?["error_description"]?.string)
    }

    /// A form post to an endpoint of the service, the client identifying itself as the credential says.
    private func post(_ form: [String: String], endpoint: URL, client: MCPOAuthCredential) async throws -> (Data, HTTPURLResponse) {
        var form = form
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientID = client.clientID {
            let secret = client.clientSecret?.nonEmpty
            switch (client.authMethod, secret) {
            case ("basic", let secret?):
                let credentials = "\(Self.formEncoded(clientID)):\(Self.formEncoded(secret))"
                request.setValue("Basic \(Data(credentials.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            case ("post", let secret?):
                form["client_id"] = clientID
                form["client_secret"] = secret
            default:
                form["client_id"] = clientID
            }
        }
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\(Self.formEncoded($0.key))=\(Self.formEncoded($0.value))" }.joined(separator: "&").utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ToolError("O serviço de login enviou uma resposta inválida.") }
            return (data, response)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ToolError("Não foi possível falar com o serviço de login: \(error.localizedDescription)")
        }
    }

    // MARK: Encoding

    /// `application/x-www-form-urlencoded` of one value: everything but the unreserved characters is escaped.
    static func formEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// `endpoint` with `items` added to its query, in order.
    static func url(_ endpoint: URL, adding items: [(String, String)]) -> URL {
        let query = items.map { "\(formEncoded($0.0))=\(formEncoded($0.1))" }.joined(separator: "&")
        let base = endpoint.absoluteString
        return URL(string: base + (endpoint.query == nil ? "?" : "&") + query) ?? endpoint
    }
}

private extension MCPOAuthCredential {
    /// The credential after a token reply: new access token and expiry, the refresh token it brought (it may rotate) or the old one.
    func applying(_ reply: JSONValue, requestedScope: String?) -> MCPOAuthCredential {
        var next = self
        next.accessToken = reply["access_token"]?.string ?? ""
        next.refreshToken = reply["refresh_token"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        next.expiresAt = reply["expires_in"]?.number.map { Date.now.addingTimeInterval($0) }
        next.scopes = reply["scope"]?.string ?? requestedScope ?? scopes
        return next
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
