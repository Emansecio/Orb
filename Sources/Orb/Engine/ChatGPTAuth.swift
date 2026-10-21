import Foundation

/// "Sign in with ChatGPT" for locally hosted apps (OpenAI's documented token-sharing flow):
/// dynamic client registration, PKCE with a 127.0.0.1 loopback callback, and the resulting token used on the
/// public Responses API. Docs: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
struct ChatGPTCredential: Codable, Sendable {
    /// Issued by OpenAI on first sign-in (`oaiapp_…`); reused for refresh and later sign-ins.
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
    var scopes: [String]

    /// Display only (read from the ID token without verifying it; never used for authorization).
    var email: String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) }?["email"]?.string
    }
}

extension Notification.Name {
    /// Posted when the login was turned down for good (the refresh token was revoked) and removed: the settings
    /// should offer "Entrar" again.
    static let chatGPTSessionEnded = Notification.Name("app.orb.chatgpt.sessionEnded")
}

actor ChatGPTAuth {
    static let shared = ChatGPTAuth()

    /// What the token endpoint's refusal of a refresh token says (`invalid_grant`, `invalid_client`).
    static let sessionEndedMessage = "A sessão do ChatGPT expirou. Entre de novo em Ajustes → Modelos."

    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let defaultTokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let resource = "https://api.openai.com/v1"
    private static let directScope = "chatgpt.tokens.use.direct"
    private static let scope = "openid profile email offline_access resource.invoke \(directScope)"
    private static let keychainAccount = "chatgpt"
    private static let callbackPath = "/auth/callback"

    /// Where the credential is kept between launches (the Keychain, except in tests).
    struct Storage: Sendable {
        var load: @Sendable () -> String?
        /// An empty value deletes it.
        var save: @Sendable (String) -> Void

        static let keychain = Storage(load: { Keychain.get(ChatGPTAuth.keychainAccount) },
                                      save: { Keychain.set($0, account: ChatGPTAuth.keychainAccount) })
    }

    private let storage: Storage
    private let tokenURL: URL
    private let session: URLSession
    private var cached: ChatGPTCredential?
    /// The storage was read once: without a login, `credential` does not go to the Keychain on every call.
    private var loaded = false
    /// The refresh in progress, shared by every caller that needs one: refresh tokens rotate, so two refreshes with
    /// the same token would make the second fail and sign the user out.
    private var refreshing: Task<ChatGPTCredential, Error>?
    private var lastRefresh: Date?
    /// Bumped by `signOut`, so a refresh that was already waiting on the network does not bring the login back.
    private var generation = 0

    init(storage: Storage = .keychain, tokenURL: URL = ChatGPTAuth.defaultTokenURL, session: URLSession = .shared) {
        self.storage = storage
        self.tokenURL = tokenURL
        self.session = session
    }

    var credential: ChatGPTCredential? {
        if cached == nil, !loaded {
            loaded = true
            if let data = storage.load()?.data(using: .utf8) {
                cached = try? JSONDecoder().decode(ChatGPTCredential.self, from: data)
            }
        }
        return cached
    }

    func signOut() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        cached = nil
        storage.save("")
    }

    /// A valid access token, refreshed shortly before it expires. `forceRefresh` is for a token the API just
    /// rejected; if another caller already refreshed a moment ago, that fresh token is returned instead.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = credential else { throw LLMError.notConfigured }
        let expiring = current.expiresAt.timeIntervalSinceNow < 180
        let justRefreshed = lastRefresh.map { -$0.timeIntervalSinceNow < 10 } ?? false
        let stale = expiring || (forceRefresh && !justRefreshed)
        if !stale && refreshing == nil { return current.accessToken }
        do {
            return try await refresh(current).accessToken
        } catch where !forceRefresh && current.expiresAt > .now && Self.isPassing(error) {
            // The endpoint is having a moment (5xx, 429, no network) and the token in hand still works: use it.
            return current.accessToken
        }
    }

    /// A failure that says nothing about the login itself.
    private static func isPassing(_ error: Error) -> Bool {
        (error as? LLMError)?.isRetryable == true || error is URLError
    }

    /// Joins the refresh in progress or starts one.
    private func refresh(_ current: ChatGPTCredential) async throws -> ChatGPTCredential {
        if let refreshing { return try await refreshing.value }
        let started = generation
        let task = Task {
            let fresh: ChatGPTCredential
            do {
                fresh = try await exchange([
                    "grant_type": "refresh_token", "client_id": current.clientID,
                    "refresh_token": current.refreshToken, "resource": Self.resource,
                ], clientID: current.clientID, previous: current)
            } catch {
                // Signing out cancels this task: whoever awaits it is told the login is gone, not a raw cancellation.
                if generation != started { throw LLMError.notConfigured }
                if (error as? ToolError)?.message == Self.sessionEndedMessage { forget(current) }
                throw error
            }
            // Signed out while the token endpoint was answering: keep the credential gone.
            guard generation == started else { throw LLMError.notConfigured }
            save(fresh)
            lastRefresh = .now
            return fresh
        }
        refreshing = task
        defer { if generation == started { refreshing = nil } }
        return try await task.value
    }

    /// The refresh token was turned down: the login is removed (unless another copy of the app already stored a newer
    /// one), so the settings go back to "Entrar com ChatGPT" instead of showing a connection that cannot work.
    private func forget(_ current: ChatGPTCredential) {
        if let stored = storage.load().flatMap({ try? JSONDecoder().decode(ChatGPTCredential.self, from: Data($0.utf8)) }),
           stored.refreshToken != current.refreshToken {
            cached = stored
            return
        }
        cached = nil
        storage.save("")
        NotificationCenter.default.post(name: .chatGPTSessionEnded, object: self)
    }

    /// Opens the browser, waits for the loopback callback and stores the credential.
    func signIn(open: @Sendable (URL) async -> Void) async throws -> ChatGPTCredential {
        let verifier = OAuthLoopback.randomToken()
        let state = OAuthLoopback.randomToken()
        let callback = try await LoopbackCallback.open(path: Self.callbackPath, state: state)
        defer { callback.stop() }
        let redirect = "http://127.0.0.1:\(callback.port)\(Self.callbackPath)"
        let reuse = credential?.clientID

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        var items = [
            ("client_id", reuse ?? "dynamic_agent_client"), ("ext_agent_host_id", Self.hostID),
            ("response_type", "code"), ("redirect_uri", redirect), ("scope", Self.scope), ("resource", Self.resource),
            ("state", state), ("nonce", OAuthLoopback.randomToken()), ("code_challenge", OAuthLoopback.challenge(for: verifier)),
            ("code_challenge_method", "S256"),
        ]
        if reuse == nil { items.append(("agent_name_hint", "Orb")) }
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw ToolError("Não foi possível montar o endereço de login.") }
        await open(url)

        let query = try await callback.wait(timeout: .seconds(300))
        guard query["state"] == state else { throw ToolError("O login voltou com um estado inválido; tente de novo.") }
        if let error = query["error"] {
            throw ToolError(error == "access_denied" ? "Login cancelado ou uso do plano do ChatGPT não liberado."
                            : "O login falhou: \(query["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error)")
        }
        guard let code = query["code"] else { throw ToolError("O login não devolveu um código.") }
        // First sign-in must return the issued client id; later sign-ins may omit it but must not change it.
        let clientID = query["client_id"] ?? reuse
        guard let clientID, clientID != "dynamic_agent_client", reuse == nil || clientID == reuse else {
            throw ToolError("O registro do app no ChatGPT não foi concluído; tente de novo.")
        }
        let fresh = try await exchange([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource,
        ], clientID: clientID, previous: nil)
        save(fresh)
        return fresh
    }

    // MARK: Token endpoint

    private func exchange(_ form: [String: String], clientID: String, previous: ChatGPTCredential?) async throws -> ChatGPTCredential {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, let json,
              let access = json["access_token"]?.string else {
            if let http, [408, 429].contains(http.statusCode) || http.statusCode >= 500 {
                // The login service is busy or down (often with an HTML page): not a refusal, and worth trying again.
                throw LLMError.http(status: http.statusCode, message: json?["error_description"]?.string ?? "o serviço de login não respondeu",
                                    retryAfter: ProviderTransport.retryAfter(in: http))
            }
            if ["invalid_grant", "invalid_client"].contains(json?["error"]?.string ?? "") {
                throw ToolError(Self.sessionEndedMessage)
            }
            throw ToolError("O ChatGPT recusou o login: \(json?["error_description"]?.string ?? json?["error"]?.string ?? "erro desconhecido")")
        }
        let scopes = (json["scope"]?.string ?? previous?.scopes.joined(separator: " ") ?? "").split(separator: " ").map(String.init)
        guard scopes.contains(Self.directScope) else {
            throw ToolError("Sua conta não liberou o uso do plano do ChatGPT em outros apps (Plus ou Pro necessário).")
        }
        return ChatGPTCredential(
            clientID: clientID, accessToken: access,
            refreshToken: json["refresh_token"]?.string ?? previous?.refreshToken ?? "",
            idToken: json["id_token"]?.string ?? previous?.idToken ?? "",
            expiresAt: .now.addingTimeInterval(json["expires_in"]?.number ?? 3600), scopes: scopes)
    }

    private func save(_ credential: ChatGPTCredential) {
        cached = credential
        if let data = try? JSONEncoder().encode(credential) {
            storage.save(String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Helpers

    /// Stable per installation (`ext_agent_host_id`), as the docs require.
    private static var hostID: String {
        let key = "chatgptHostID"
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return "urn:uuid:\(id)"
    }
}
