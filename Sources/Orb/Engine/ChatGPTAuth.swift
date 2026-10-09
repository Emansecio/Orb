import Foundation
import CryptoKit
import Network

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

actor ChatGPTAuth {
    static let shared = ChatGPTAuth()

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
        if cached == nil, let data = storage.load()?.data(using: .utf8) {
            cached = try? JSONDecoder().decode(ChatGPTCredential.self, from: data)
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
        return try await refresh(current).accessToken
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

    /// Opens the browser, waits for the loopback callback and stores the credential.
    func signIn(open: @Sendable (URL) async -> Void) async throws -> ChatGPTCredential {
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        let callback = try LoopbackCallback(path: Self.callbackPath)
        defer { callback.stop() }
        let redirect = "http://127.0.0.1:\(callback.port)\(Self.callbackPath)"
        let reuse = credential?.clientID

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        var items = [
            ("client_id", reuse ?? "dynamic_agent_client"), ("ext_agent_host_id", Self.hostID),
            ("response_type", "code"), ("redirect_uri", redirect), ("scope", Self.scope), ("resource", Self.resource),
            ("state", state), ("nonce", Self.randomToken()), ("code_challenge", Self.challenge(for: verifier)),
            ("code_challenge_method", "S256"),
        ]
        if reuse == nil { items.append(("agent_name_hint", "Orb")) }
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw ToolError("Não foi possível montar o endereço de login.") }
        await open(url)

        let query = try await callback.wait(timeout: .seconds(300))
        guard query["state"] == state else { throw ToolError("O login voltou com um estado inválido; tente de novo.") }
        if let error = query["error"] {
            throw ToolError(error == "access_denied" ? "Login cancelado ou uso do plano do ChatGPT não liberado." : "O login falhou: \(error)")
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
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json,
              let access = json["access_token"]?.string else {
            if json?["error"]?.string == "invalid_grant" {
                throw ToolError("A sessão do ChatGPT expirou. Entre de novo em Ajustes → Modelos.")
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

    private static func randomToken() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's query string.
/// Tries the conventional port 1455 first, then any free port (the docs allow the port to vary).
final class LoopbackCallback: Sendable {
    private let listener: NWListener
    private let result: AsyncStream<[String: String]>
    private let continuation: AsyncStream<[String: String]>.Continuation
    let port: UInt16

    init(path: String) throws {
        (result, continuation) = AsyncStream.makeStream(of: [String: String].self)
        guard let listener = Self.bind(1455) ?? Self.bind(nil), let bound = listener.port?.rawValue else {
            throw ToolError("Não foi possível abrir a porta local para o login.")
        }
        self.listener = listener
        port = bound
        let continuation = continuation
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let page = "<html><body style=\"font-family:-apple-system;background:#070707;color:#fcfcfc;text-align:center;padding-top:80px\"><h2>Pronto!</h2><p>Pode voltar para o app.</p></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard let components = URLComponents(string: target), components.path == path else { return }
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
                continuation.yield(query)
            }
        }
    }

    /// A listener on 127.0.0.1 that reached `.ready` (nil port = any free port).
    private static func bind(_ port: UInt16?) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let settled = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var isReady = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: isReady = true; settled.signal()
            case .failed, .cancelled: settled.signal()
            default: break
            }
        }
        // A handler must exist before start; the real one is installed right after.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        // Ready in milliseconds; the margin is for a Mac under load (it only ever waits that long when binding fails).
        _ = settled.wait(timeout: .now() + 10)
        guard isReady else { listener.cancel(); return nil }
        listener.stateUpdateHandler = nil
        return listener
    }

    func wait(timeout: Duration) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { [result] in
                for await query in result { return query }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError("O login demorou demais; tente de novo.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    func stop() {
        listener.cancel()
        continuation.finish()
    }
}
