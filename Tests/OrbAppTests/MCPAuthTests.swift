import Foundation
import os
import Testing
@testable import Orb

// The login of the remote connectors (OAuth 2.1 of the MCP spec), against a fake network: nothing here reaches a real service.

private func connector(_ service: FakeOAuthService, _ settings: MCPOAuthSettings? = MCPOAuthSettings()) -> MCPServerConfig {
    var config = MCPServerConfig(name: "Notion", url: service.mcpURL)
    config.oauth = settings
    return config
}

/// A login already in the vault, as the sign-in leaves it.
private func seed(_ vault: MemoryVault, _ id: UUID, _ service: FakeOAuthService, expiresIn: TimeInterval = 3600,
                  refreshToken: String? = "rt-0", secret: String? = nil, method: String = "none", registrationPort: UInt16? = nil) throws {
    let credential = MCPOAuthCredential(issuer: service.issuer, clientID: "client", clientSecret: secret, registrationPort: registrationPort,
                                        accessToken: "at-0", refreshToken: refreshToken, expiresAt: .now.addingTimeInterval(expiresIn),
                                        scopes: "read", tokenEndpoint: "\(service.issuer)/token", authMethod: method, resource: service.mcpURL)
    _ = vault.set(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self), account: ConnectorSecrets.oauthAccount(id: id))
}

private func stored(_ vault: MemoryVault, _ id: UUID) throws -> MCPOAuthCredential {
    let json = try #require(vault.get(ConnectorSecrets.oauthAccount(id: id)))
    return try JSONDecoder().decode(MCPOAuthCredential.self, from: Data(json.utf8))
}

// MARK: - Reading the challenge

struct MCPChallengeTests {
    @Test func readsTheParametersOfTheBearerChallenge() {
        let challenge = MCPChallenge(header: #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read files:write""#)
        #expect(challenge.resourceMetadata == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        #expect(challenge.scope == "files:read files:write" && challenge.error == nil)

        let denied = MCPChallenge(header: #"Bearer error="insufficient_scope", scope="chat:write", error_description="needs \"more\"""#)
        #expect(denied.error == "insufficient_scope" && denied.scope == "chat:write" && denied.resourceMetadata == nil)
    }

    @Test func skipsOtherSchemesAndToleratesNonsense() {
        let mixed = MCPChallenge(header: #"Basic realm="x", Bearer realm="mcp", resource_metadata=https://a.example/prm, error=invalid_token"#)
        #expect(mixed.resourceMetadata == URL(string: "https://a.example/prm") && mixed.error == "invalid_token")
        #expect(MCPChallenge(header: #"Basic realm="x", scope="nope""#) == MCPChallenge())
        #expect(MCPChallenge(header: nil) == MCPChallenge())
        #expect(MCPChallenge(header: "Bearer") == MCPChallenge(isBearer: true))
        #expect(!MCPChallenge(header: #"Basic realm="x""#).isBearer && MCPChallenge(header: #"Basic realm="x", Bearer"#).isBearer)
        #expect(MCPChallenge(header: #"Bearer resource_metadata="file:///etc/passwd""#).resourceMetadata == nil)
        #expect(MCPChallenge(header: #"Bearer realm="unterminated"#) == MCPChallenge(isBearer: true))
    }
}

// MARK: - Discovery

struct MCPDiscoveryTests {
    @Test func theResourceMetadataIsLookedForAtTheEndpointsPathThenAtTheRoot() throws {
        let url = try #require(URL(string: "https://mcp.example.com/public/mcp"))
        #expect(MCPAuth.protectedResourceAddresses(for: url).map(\.absoluteString) == [
            "https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp",
            "https://mcp.example.com/.well-known/oauth-protected-resource",
        ])
        #expect(MCPAuth.protectedResourceAddresses(for: try #require(URL(string: "https://mcp.example.com/"))).map(\.absoluteString)
                == ["https://mcp.example.com/.well-known/oauth-protected-resource"])
    }

    @Test func theServerMetadataIsLookedForInTheOrderOfTheSpec() throws {
        let withPath = try #require(URL(string: "https://auth.example.com/tenant1"))
        #expect(MCPAuth.authorizationServerAddresses(for: withPath).map(\.absoluteString) == [
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example.com/.well-known/openid-configuration/tenant1",
            "https://auth.example.com/tenant1/.well-known/openid-configuration",
        ])
        let bare = try #require(URL(string: "https://auth.example.com"))
        #expect(MCPAuth.authorizationServerAddresses(for: bare).map(\.absoluteString) == [
            "https://auth.example.com/.well-known/oauth-authorization-server",
            "https://auth.example.com/.well-known/openid-configuration",
        ])
    }

    @Test func theResourceIsTheAddressWithoutQueryFragmentOrFinalSlash() throws {
        #expect(MCPAuth.canonical(try #require(URL(string: "HTTPS://MCP.Example.com/mcp/?read_only=true#x"))) == "https://mcp.example.com/mcp")
        #expect(MCPAuth.canonical(try #require(URL(string: "https://mcp.example.com/"))) == "https://mcp.example.com")
        #expect(MCPAuth.canonical(try #require(URL(string: "https://mcp.example.com:8443/mcp"))) == "https://mcp.example.com:8443/mcp")
    }

    @Test func discoveryFollowsTheChallengeThenFallsBackToTheWellKnownAddresses() async throws {
        let service = FakeOAuthService { $0.challengeHeader = "Bearer realm=\"mcp\"" } // no resource_metadata in the challenge
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        _ = try await auth.signIn(connector(service), open: FakeOAuthService.Browser().open)
        #expect(service.requests.map(\.label) == [
            "mcp POST /mcp", "mcp GET /.well-known/oauth-protected-resource/mcp", "auth GET /.well-known/oauth-authorization-server",
            "auth POST /register", "auth POST /token",
        ])
    }

    @Test func aServerWithoutPKCEOrWithoutS256IsRefusedBeforeAnythingIsAsked() async throws {
        for methods in [nil, ["plain"]] as [[String]?] {
            let service = FakeOAuthService { $0.methods = methods }
            let browser = FakeOAuthService.Browser()
            let auth = MCPAuth(vault: MemoryVault(), session: service.session)
            let error = try #require(await #expect(throws: ToolError.self, "expected a refusal") {
                _ = try await auth.signIn(connector(service), open: browser.open)
            })
            #expect(error.message == "Este serviço não oferece login seguro (PKCE). Conexão recusada.")
            #expect(browser.urls.isEmpty)
            #expect(!service.requests.contains { $0.label.contains("/register") || $0.label.contains("/token") })
        }
    }

    @Test func aResourceThatIsNotTheServersOwnIsRefused() async throws {
        let service = FakeOAuthService { $0.resourceInMetadata = "https://other.example.com" }
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        await #expect(throws: ToolError.self) { try await auth.signIn(connector(service), open: FakeOAuthService.Browser().open) }
        #expect(!service.requests.contains { $0.label.contains("/register") })
    }

    @Test func aBroaderResourceIsUsedAsTheServerNamesIt() async throws {
        let service = FakeOAuthService()
        service.change { $0.resourceInMetadata = "https://\(service.mcpHost)" } // Slack names the host, the endpoint is /mcp
        let browser = FakeOAuthService.Browser()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        _ = try await auth.signIn(connector(service), open: browser.open)
        #expect(browser.value("resource") == "https://\(service.mcpHost)")
    }

    @Test func aServerWithoutAnyMetadataSaysSo() async throws {
        let (session, _) = FakeNetwork.session(hosts: ["mcp-none.test"]) { _ in .init(status: 404) }
        let auth = MCPAuth(vault: MemoryVault(), session: session)
        var config = MCPServerConfig(name: "Vazio", url: "https://mcp-none.test/mcp")
        config.oauth = MCPOAuthSettings()
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        })
        #expect(error.message == "O Vazio não explicou como entrar (sem metadados de login).")
    }
}

// MARK: - Signing in

struct MCPSignInTests {
    @Test func registersTheOrbAsANativeAppAndSignsIn() async throws {
        let service = FakeOAuthService()
        let browser = FakeOAuthService.Browser()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        let credential = try await auth.signIn(config, open: browser.open)

        // Registration: a native app, no client authentication, a redirect on the loopback.
        let registration = try #require(service.requests.first { $0.label == "auth POST /register" }?.json)
        #expect(registration["application_type"]?.string == "native" && registration["token_endpoint_auth_method"]?.string == "none")
        #expect(registration["client_name"]?.string == "Orb")
        #expect(registration["grant_types"]?.array?.compactMap(\.string) == ["authorization_code", "refresh_token"])
        let redirect = try #require(registration["redirect_uris"]?.array?.first?.string)
        #expect(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/callback"))

        // The authorization request: PKCE S256, state, resource and the scopes the resource lists.
        #expect(browser.urls.count == 1 && browser.last?.host == "auth-\(service.id).test" && browser.last?.path == "/authorize")
        #expect(browser.value("response_type") == "code" && browser.value("client_id") == "dyn-\(service.id)")
        #expect(browser.value("redirect_uri") == redirect && browser.value("code_challenge_method") == "S256")
        #expect(browser.value("resource") == service.mcpURL && browser.value("scope") == "read write")
        #expect(browser.value("state")?.isEmpty == false)

        // The exchange proves the verifier of that challenge, with the same redirect and resource.
        let exchange = try #require(service.requests.first { $0.label == "auth POST /token" }).form
        #expect(exchange["grant_type"] == "authorization_code" && exchange["code"] == "code-1")
        #expect(exchange["redirect_uri"] == redirect && exchange["resource"] == service.mcpURL)
        #expect(exchange["client_id"] == "dyn-\(service.id)")
        #expect(OAuthLoopback.challenge(for: try #require(exchange["code_verifier"])) == browser.value("code_challenge"))

        // What is kept: one account in the vault, holding the tokens and the client.
        #expect(vault.accounts == [ConnectorSecrets.oauthAccount(id: config.id)])
        let kept = try stored(vault, config.id)
        #expect(kept == credential && kept.accessToken == "at-1" && kept.refreshToken == "rt-1")
        #expect(kept.issuer == service.issuer && kept.clientID == "dyn-\(service.id)" && kept.registrationPort != nil && kept.scopes == "read write")
        #expect(await auth.isSignedIn(config.id))
        #expect(try await auth.accessToken(config.id) == "at-1")
    }

    @Test func noTokenEverTravelsInAnAddress() async throws {
        let service = FakeOAuthService()
        let browser = FakeOAuthService.Browser()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        _ = try await auth.signIn(connector(service), open: browser.open)
        let addresses = service.requests.map(\.url.absoluteString) + browser.urls.map(\.absoluteString)
        #expect(!addresses.contains { $0.contains("at-1") || $0.contains("rt-1") })
    }

    @Test func aStateThatDoesNotMatchIsIgnoredAndTheCodeIsNeverUsed() async throws {
        // The loopback answers a forged callback with an error page and keeps waiting for the real one, which never comes here.
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session, signInTimeout: .seconds(1))
        let browser = FakeOAuthService.Browser { $0["state"] = "forged" }
        let error = try #require(await #expect(throws: ToolError.self, "expected the sign-in to time out") {
            _ = try await auth.signIn(connector(service), open: browser.open)
        })
        #expect(error.message == "O login demorou demais; tente de novo.")
        #expect(!service.requests.contains { $0.label == "auth POST /token" })
    }

    @Test func anIssuerThatIsNotTheOneAskedIsRefusedWhateverElseTheResponseSays() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let browser = FakeOAuthService.Browser { $0["iss"] = "https://evil.example.com"; $0["error"] = "access_denied" }
        let error = try #require(await #expect(throws: ToolError.self, "expected a refusal") {
            _ = try await auth.signIn(connector(service), open: browser.open)
        })
        #expect(error.message.contains("não veio do serviço esperado"))
        #expect(!error.message.contains("access_denied")) // an error from the wrong server is not shown
        #expect(!service.requests.contains { $0.label == "auth POST /token" })
    }

    @Test func theIssuerRulesOfTheSpecHold() throws {
        // Advertised and absent: refused. Present and equal: fine, whether or not it was advertised. Not advertised and absent: fine.
        func check(_ query: [String: String], advertised: Bool) throws {
            try MCPAuth.check(query, state: "s", issuer: "https://a.example", advertisesIssuer: advertised, name: "X")
        }
        #expect(throws: ToolError.self) { try check(["state": "s", "code": "c"], advertised: true) }
        #expect(throws: ToolError.self) { try check(["state": "s", "iss": "https://a.example/"], advertised: false) } // no normalisation
        try check(["state": "s", "iss": "https://a.example"], advertised: true)
        try check(["state": "s", "iss": "https://a.example"], advertised: false)
        try check(["state": "s", "code": "c"], advertised: false)
        #expect(throws: ToolError("Login cancelado.")) { try check(["state": "s", "error": "access_denied"], advertised: false) }
    }

    @Test func aServerThatAdvertisesIssNeedsItInTheAnswer() async throws {
        let service = FakeOAuthService { $0.advertisesIss = true }
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        await #expect(throws: ToolError.self) { try await auth.signIn(connector(service), open: FakeOAuthService.Browser().open) }
        let ok = FakeOAuthService { $0.advertisesIss = true }
        let signedIn = try await MCPAuth(vault: MemoryVault(), session: ok.session)
            .signIn(connector(ok), open: FakeOAuthService.Browser { $0["iss"] = ok.issuer }.open)
        #expect(signedIn.accessToken == "at-1")
    }

    @Test func cancellingEndsTheWaitForTheBrowser() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let waiting = Task { try await auth.signIn(connector(service), open: { _ in }) }
        await waitUntil("the sign-in to be waiting for the browser") { service.requests.contains { $0.label == "auth POST /register" } }
        waiting.cancel()
        let error = try #require(await #expect(throws: ToolError.self, "expected the sign-in to end") {
            _ = try await waiting.value
        })
        #expect(error.message == "Login cancelado.")
    }

    @Test func aBrowserThatNeverComesBackTimesOut() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session, signInTimeout: .milliseconds(200))
        let error = try #require(await #expect(throws: ToolError.self, "expected a timeout") {
            _ = try await auth.signIn(connector(service), open: { _ in })
        })
        #expect(error.message == "O login demorou demais; tente de novo.")
    }

    @Test func aDeniedLoginIsSaidInPlainWords() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let browser = FakeOAuthService.Browser { $0["error"] = "access_denied"; $0["code"] = nil }
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await auth.signIn(connector(service), open: browser.open)
        })
        #expect(error.message == "Login cancelado.")
    }

    @Test func anAppRegisteredByThePersonIsUsedAsIsAndNeverRegisteredAgain() async throws {
        let service = FakeOAuthService { $0.authMethods = ["client_secret_post"] }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let port = Int.random(in: 47_900...47_990)
        let config = connector(service, MCPOAuthSettings(clientID: "slack-app", needsClientSecret: true, scopes: "chat:write search:read.public",
                                                         authorizeParameters: ["access_type": "offline", "prompt": "consent"],
                                                         redirect: "http://localhost:\(port)/slack/callback"))
        // The editor wants the secret first.
        let error = try #require(await #expect(throws: ToolError.self, "expected a request for the secret") {
            _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        })
        #expect(error.message == "O Notion pede um app registrado: cole o Client ID e o Client Secret.")
        #expect(error.message.contains(MCPAuth.needsAppPhrase)) // what the connector sheet looks for
        await auth.setClientSecret("s3cret", for: config.id)

        let browser = FakeOAuthService.Browser()
        _ = try await auth.signIn(config, open: browser.open)
        #expect(!service.requests.contains { $0.label == "auth POST /register" })
        #expect(browser.value("client_id") == "slack-app" && browser.value("redirect_uri") == "http://localhost:\(port)/slack/callback")
        #expect(browser.value("scope") == "chat:write search:read.public") // the person's scopes, not everything the resource lists
        #expect(browser.value("access_type") == "offline" && browser.value("prompt") == "consent")
        let exchange = try #require(service.requests.last { $0.label == "auth POST /token" })
        #expect(exchange.form["client_id"] == "slack-app" && exchange.form["client_secret"] == "s3cret") // client_secret_post
        #expect(exchange.headers["Authorization"] == nil)
        let kept = try stored(vault, config.id)
        #expect(kept.clientSecret == "s3cret" && kept.registrationPort == nil && kept.authMethod == "post")
    }

    @Test func aSecretIsSentInTheHeaderWhenTheServerTakesIt() async throws {
        let service = FakeOAuthService { $0.authMethods = ["client_secret_basic", "client_secret_post"] }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service, MCPOAuthSettings(clientID: "app"))
        await auth.setClientSecret("s:ecret", for: config.id)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        let exchange = try #require(service.requests.last { $0.label == "auth POST /token" })
        #expect(exchange.headers["Authorization"] == "Basic " + Data("app:s%3Aecret".utf8).base64EncodedString())
        #expect(exchange.form["client_secret"] == nil)
    }

    @Test func withoutAnyWayToGetAnAppThePersonIsAsked() async throws {
        let service = FakeOAuthService { $0.offersRegistration = false }
        let browser = FakeOAuthService.Browser()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await auth.signIn(connector(service), open: browser.open)
        })
        #expect(error.message.hasPrefix("O Notion pede um app registrado: cole o Client ID"))
        #expect(browser.urls.isEmpty)
    }

    @Test func theAppTheOrbRegisteredIsReusedOnlyForTheSameServiceAndPort() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        let first = try stored(vault, config.id)

        // Same service, and its port is free again: the same client, no new registration.
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        let second = try stored(vault, config.id)
        let registrations = service.requests.filter { $0.label == "auth POST /register" }.count
        #expect((second.registrationPort == first.registrationPort) == (registrations == 1)) // reused exactly when the port came back
        #expect(second.clientID == (registrations == 1 ? first.clientID : second.clientID))

        // The service moved to another issuer: the old client is not shown to it.
        var other = second
        other.issuer = "https://elsewhere.example.com"
        _ = vault.set(String(decoding: try JSONEncoder().encode(other), as: UTF8.self), account: ConnectorSecrets.oauthAccount(id: config.id))
        let fresh = FakeOAuthService()
        let moved = MCPAuth(vault: vault, session: fresh.session)
        var movedConfig = connector(fresh)
        movedConfig.id = config.id
        let browser = FakeOAuthService.Browser()
        _ = try await moved.signIn(movedConfig, open: browser.open)
        #expect(browser.value("client_id") == "dyn-\(fresh.id)")
        #expect(fresh.requests.contains { $0.label == "auth POST /register" })
    }

    @Test func aSecretTypedAfterTheOrbRegisteredItselfSurvivesTheSwitchToTheOwnApp() async throws {
        let service = FakeOAuthService { $0.authMethods = ["client_secret_post"] }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        var config = connector(service)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open) // registered by the Orb
        #expect(try stored(vault, config.id).registrationPort != nil)
        // The person pastes the Client ID and Secret of an app of their own (Avançado).
        config.oauth = MCPOAuthSettings(clientID: "own-app")
        await auth.setClientSecret("typed-secret", clientID: "own-app", for: config.id)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        let exchange = try #require(service.requests.last { $0.label == "auth POST /token" })
        #expect(exchange.form["client_id"] == "own-app" && exchange.form["client_secret"] == "typed-secret")
        let kept = try stored(vault, config.id)
        #expect(kept.clientSecret == "typed-secret" && kept.registrationPort == nil && kept.authMethod == "post")

        // Changing only the Client ID drops the secret of the old app.
        config.oauth = MCPOAuthSettings(clientID: "other-app")
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        #expect(try stored(vault, config.id).clientSecret == nil)
    }

    @Test func aLoginThatEndsAfterTheConnectorWasDeletedOrSignedOutLeavesNothingBehind() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        let browser = FakeOAuthService.Browser()
        // The person deletes the connector while the browser is open, then finishes the login there.
        let error = try #require(await #expect(throws: ToolError.self, "expected the login to be cancelled") {
            _ = try await auth.signIn(config) { url in
                await auth.deleteAccount(config.id)
                await browser.open(url)
            }
        })
        #expect(error.message == "Login cancelado.")
        #expect(vault.accounts.isEmpty)
        #expect(!service.requests.contains { $0.label == "auth POST /token" }) // the code was never exchanged
        #expect(await !auth.isSignedIn(config.id))

        // The same with "Sair da conta".
        let secondError = try #require(await #expect(throws: ToolError.self, "expected the login to be cancelled") {
            _ = try await auth.signIn(config) { url in
                await auth.signOut(config.id)
                await browser.open(url)
            }
        })
        #expect(secondError.message == "Login cancelado.")
        #expect(await !auth.isSignedIn(config.id))
        #expect(!vault.accounts.contains { (vault.get($0) ?? "").contains("at-1") })
    }

    @Test func aConnectorWithoutHTTPSNeverSignsInNorCarriesAToken() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        var plain = connector(service)
        plain.url = plain.url.replacingOccurrences(of: "https://", with: "http://")
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await auth.signIn(plain, open: FakeOAuthService.Browser().open)
        })
        #expect(error.message == "O endereço do conector Notion não usa HTTPS; o login foi recusado.")
        #expect(service.requests.isEmpty)
        try seed(vault, plain.id, service)
        #expect(auth.tokenProvider(for: plain) == nil)
        // A server being developed on this Mac may use plain HTTP.
        var local = plain
        local.url = "http://localhost:8080/mcp"
        #expect(auth.tokenProvider(for: local) != nil)
    }

    @Test func redirectsNeverLeaveTheHostNorDropFromHTTPSToHTTP() {
        func follows(_ from: String, _ to: String) -> Bool { RedirectGuard.follows(from: URL(string: from), to: URL(string: to)) }
        #expect(follows("https://mcp.test/a", "https://mcp.test/b"))
        #expect(follows("http://mcp.test/a", "https://mcp.test/b"))
        #expect(!follows("https://mcp.test/a", "http://mcp.test/b"))
        #expect(!follows("https://mcp.test/a", "https://other.test/b"))
        #expect(!follows("https://mcp.test/a", "not a url"))
    }

    @Test func cancellingBeforeTheServerAnswersIsSaidAsACancellation() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let task = Task { try await auth.signIn(connector(service), open: { _ in }) }
        task.cancel()
        let error = try #require(await #expect(throws: ToolError.self, "expected the sign-in to end") {
            _ = try await task.value
        })
        #expect(error.message == "Login cancelado.")
    }

    @Test func scopesFollowTheChallengeThenThePersonThenWhatTheResourceLists() {
        let settings = MCPOAuthSettings(scopes: "mine")
        #expect(MCPAuth.scopeToAsk(challenge: MCPChallenge(scope: "a b"), settings: settings, supported: ["x"], granted: "", extra: nil, offersOffline: false) == "a b")
        #expect(MCPAuth.scopeToAsk(challenge: nil, settings: settings, supported: ["x"], granted: "", extra: nil, offersOffline: false) == "mine")
        #expect(MCPAuth.scopeToAsk(challenge: nil, settings: MCPOAuthSettings(), supported: ["x", "y"], granted: "", extra: nil, offersOffline: false) == "x y")
        #expect(MCPAuth.scopeToAsk(challenge: nil, settings: MCPOAuthSettings(), supported: [], granted: "", extra: nil, offersOffline: true) == nil)
        // To ask for more, what was granted stays.
        #expect(MCPAuth.scopeToAsk(challenge: nil, settings: settings, supported: [], granted: "a b", extra: "b c", offersOffline: false) == "a b c")
        #expect(MCPAuth.scopeToAsk(challenge: nil, settings: settings, supported: ["x"], granted: "", extra: nil, offersOffline: true) == "mine offline_access")
    }

    @Test func askingForMoreKeepsWhatWasGranted() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        let browser = FakeOAuthService.Browser()
        _ = try await auth.signIn(config, scope: "admin", open: browser.open)
        #expect(browser.value("scope") == "read write admin")
    }
}

// MARK: - Renewing

struct MCPRenewalTests {
    @Test func twoRenewalsAtOnceAreOneAndTheRotationIsKept() async throws {
        let service = FakeOAuthService { $0.onToken = { _ in
            Thread.sleep(forTimeInterval: 0.2) // long enough for the second caller to arrive while the first is still waiting
            return .json(#"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600}"#)
        } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 30) // about to end
        async let first = auth.accessToken(id), second = auth.accessToken(id), third = auth.accessToken(id, forceRefresh: true)
        let tokens = try await [first, second, third]
        #expect(tokens == ["at-2", "at-2", "at-2"])
        let renewals = service.requests.filter { $0.label == "auth POST /token" }
        #expect(renewals.count == 1)
        #expect(renewals[0].form["grant_type"] == "refresh_token" && renewals[0].form["refresh_token"] == "rt-0")
        #expect(renewals[0].form["resource"] == service.mcpURL)
        let kept = try stored(vault, id)
        #expect(kept.accessToken == "at-2" && kept.refreshToken == "rt-2" && kept.clientID == "client")
    }

    @Test func aTokenWithTimeLeftIsUsedWithoutTouchingTheNetwork() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 3600)
        #expect(try await auth.accessToken(id) == "at-0")
        #expect(service.requests.isEmpty)
        #expect(try await auth.accessToken(UUID()) == nil) // no login at all: no token, no error
    }

    @Test func aRefusedTokenIsRenewedOnceWhenForced() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service)
        #expect(try await auth.accessToken(id, forceRefresh: true) == "at-2")
        // A second refusal right after is the same token the first one just gave: not renewed again within seconds.
        #expect(try await auth.accessToken(id, forceRefresh: true) == "at-2")
        #expect(service.requests.filter { $0.label == "auth POST /token" }.count == 1)
    }

    @Test func aRotatedRefreshTokenThatIsNotRepeatedKeepsTheOldOne() async throws {
        let service = FakeOAuthService { $0.onToken = { _ in .json(#"{"access_token":"at-9","expires_in":3600}"#) } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 10)
        #expect(try await auth.accessToken(id) == "at-9")
        #expect(try stored(vault, id).refreshToken == "rt-0")
    }

    @Test func invalidGrantEndsTheLoginAndAsksToSignInAgain() async throws {
        let service = FakeOAuthService { $0.onToken = { _ in .json(#"{"error":"invalid_grant"}"#, status: 400) } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 10, secret: "keep-me")
        await #expect(throws: MCPAuthRequired(reason: .expired)) { try await auth.accessToken(id) }
        let kept = try stored(vault, id)
        #expect(kept.accessToken.isEmpty && kept.refreshToken == nil) // no token is left in the Keychain
        #expect(kept.clientID == "client" && kept.clientSecret == "keep-me") // what the person typed stays
        #expect(await !auth.isSignedIn(id))
        #expect(try await auth.accessToken(id) == nil)
        #expect(service.requests.filter { $0.label == "auth POST /token" }.count == 1) // no retry in a loop
    }

    @Test func aFailureOfTheNetworkKeepsTheLoginForNextTime() async throws {
        let service = FakeOAuthService { $0.onToken = { _ in .json(#"{"error":"temporarily_unavailable"}"#, status: 503) } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 10)
        // A token about to end still works: the failed renewal is not an error for whoever only wants to use it.
        #expect(try await auth.accessToken(id) == "at-0")
        // One the server just refused has nothing to fall back on.
        await #expect(throws: ToolError.self) { try await auth.accessToken(id, forceRefresh: true) }
        #expect(try stored(vault, id).refreshToken == "rt-0")
    }

    @Test func otherRefusalsOfTheServiceEndTheLoginToo() async throws {
        let replies = [#"{"error":"invalid_client"}"#, #"{"error":"unauthorized_client"}"#,
                       #"{"ok":false,"error":"invalid_refresh_token"}"#] // Slack answers 200 with ok:false
        for (index, reply) in replies.enumerated() {
            let service = FakeOAuthService { $0.onToken = { _ in .json(reply, status: index == 2 ? 200 : 401) } }
            let vault = MemoryVault()
            let auth = MCPAuth(vault: vault, session: service.session)
            let id = UUID()
            try seed(vault, id, service, expiresIn: 10, secret: "typed")
            await #expect(throws: MCPAuthRequired(reason: .expired)) { try await auth.accessToken(id) }
            let kept = try stored(vault, id)
            #expect(kept.accessToken.isEmpty && kept.refreshToken == nil && kept.clientID == "client")
            #expect(service.requests.filter { $0.label == "auth POST /token" }.count == 1)
        }
    }

    @Test func aClientTheServiceLostIsForgottenSoTheNextLoginRegistersAgain() async throws {
        let service = FakeOAuthService { $0.onToken = { _ in .json(#"{"error":"invalid_client"}"#, status: 401) } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, expiresIn: 10, registrationPort: 47_123) // registered by the Orb
        await #expect(throws: MCPAuthRequired(reason: .expired)) { try await auth.accessToken(id) }
        let kept = try stored(vault, id)
        #expect(kept.clientID == nil && kept.registrationPort == nil && kept.accessToken.isEmpty)
    }

    @Test func aConnectorWithoutALoginAsksTheVaultOnlyOnce() async throws {
        final class Counting: SecretVault, @unchecked Sendable {
            let inner = MemoryVault()
            private let lock = NSLock()
            private var count = 0
            var reads: Int { lock.withLock { count } }
            func get(_ account: String) -> String? { lock.withLock { count += 1 }; return inner.get(account) }
            func set(_ value: String, account: String) -> Bool { inner.set(value, account: account) }
            func remove(_ account: String) { inner.remove(account) }
        }
        let vault = Counting()
        let auth = MCPAuth(vault: vault, session: FakeOAuthService().session)
        let id = UUID()
        for _ in 0..<5 { #expect(try await auth.accessToken(id) == nil) }
        #expect(vault.reads == 1)
    }

    @Test func signingOutAsksTheServiceToRevokeWhenItSaysWhere() async throws {
        let service = FakeOAuthService { $0.revocation = true }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        _ = try await auth.signIn(config, open: FakeOAuthService.Browser().open)
        await auth.signOut(config.id)
        await waitUntil("the revocation") { service.requests.contains { $0.label == "auth POST /revoke" } }
        let request = try #require(service.requests.last { $0.label == "auth POST /revoke" })
        #expect(request.form["token"] == "rt-1" && request.form["token_type_hint"] == "refresh_token")
        #expect(try stored(vault, config.id).accessToken.isEmpty)
        // Deleting the connector does it too, and a service that did not say where is left alone.
        let quiet = FakeOAuthService()
        let other = MCPAuth(vault: vault, session: quiet.session)
        let id = UUID()
        try seed(vault, id, quiet)
        await other.deleteAccount(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(quiet.requests.isEmpty && vault.get(ConnectorSecrets.oauthAccount(id: id)) == nil)
    }

    @Test func signingOutKeepsTheClientButNoToken() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let id = UUID()
        try seed(vault, id, service, secret: "typed")
        await auth.signOut(id)
        let kept = try stored(vault, id)
        #expect(kept.accessToken.isEmpty && kept.refreshToken == nil && kept.clientSecret == "typed")
        #expect(!(vault.get(ConnectorSecrets.oauthAccount(id: id)) ?? "").contains("at-0"))
        await auth.deleteAccount(id)
        #expect(vault.accounts.isEmpty)
    }

}

// MARK: - The transport

struct MCPLoginTransportTests {
    private func transport(_ service: FakeOAuthService, auth: MCPAuth, _ config: MCPServerConfig) throws -> HTTPTransport {
        try HTTPTransport(config: config, token: auth.tokenProvider(for: config), session: service.session)
    }

    private func initialize(_ transport: HTTPTransport) async throws {
        await transport.open(receive: { _ in }, closed: { _ in })
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"), "params": .object([:])]))
    }

    @Test func theBearerGoesInEveryRequestAndOnlyInTheHeader() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        try seed(vault, config.id, service)
        service.change { $0.validToken = "at-0" }
        let connection = MCPConnection(config: config, token: auth.tokenProvider(for: config), session: service.session)
        _ = try await connection.start()
        _ = try await connection.call("echo", arguments: .object([:]))
        let posts = service.requests.filter { $0.label == "mcp POST /mcp" }
        #expect(posts.count == 4) // initialize, initialized, tools/list, tools/call
        #expect(posts.allSatisfy { $0.headers["Authorization"] == "Bearer at-0" })
        #expect(!service.requests.contains { $0.url.absoluteString.contains("at-0") })
        await connection.stop()
    }

    @Test func aRefusedTokenIsRenewedOnceAndTheRequestRepeated() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        try seed(vault, config.id, service) // at-0 looks fine, but the server only takes at-2 (it was revoked)
        service.change { $0.validToken = "at-2" }
        try await initialize(transport(service, auth: auth, config))
        let posts = service.requests.filter { $0.label == "mcp POST /mcp" }
        #expect(posts.map { $0.headers["Authorization"] } == ["Bearer at-0", "Bearer at-2"])
        #expect(service.requests.filter { $0.label == "auth POST /token" }.count == 1)
    }

    @Test func aSecondRefusalMeansTheLoginIsOver() async throws {
        let service = FakeOAuthService { $0.validToken = "never" }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        try seed(vault, config.id, service)
        let required = try #require(await #expect(throws: MCPAuthRequired.self, "expected the login to be asked for") {
            try await initialize(transport(service, auth: auth, config))
        })
        #expect(required.reason == .expired)
        #expect(service.requests.filter { $0.label == "mcp POST /mcp" }.count == 2) // once, renewed, once more: never a loop
    }

    @Test func withoutALoginTheChallengeIsPassedOn() async throws {
        let service = FakeOAuthService { $0.challengeScope = "files:read" }
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let config = connector(service)
        let required = try #require(await #expect(throws: MCPAuthRequired.self, "expected the login to be asked for") {
            try await initialize(transport(service, auth: auth, config))
        })
        #expect(required.reason == .signIn && required.challenge.scope == "files:read")
        #expect(required.challenge.resourceMetadata?.path == "/.well-known/oauth-protected-resource/mcp")
        #expect(service.requests.count == 1 && service.requests[0].headers["Authorization"] == nil)
    }

    @Test func a401WithoutABearerChallengeKeepsTheServersOwnMessage() async throws {
        let service = FakeOAuthService { $0.challengeHeader = #"ApiKey realm="x""# }
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let config = connector(service, nil) // from the registry: it does not say it signs in
        #expect(auth.tokenProvider(for: config) != nil)
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            try await initialize(transport(service, auth: auth, config))
        })
        #expect(error.message.hasPrefix("O conector Notion respondeu HTTP 401"))
    }

    @Test func aKeyPastedByHandIsLeftAloneAndAnOldMessageStays() async throws {
        let service = FakeOAuthService()
        var config = MCPServerConfig(name: "Remoto", url: service.mcpURL, headers: ["Authorization": "Bearer pasted"])
        config.oauth = nil
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        #expect(auth.tokenProvider(for: config) == nil)
        let connection = MCPConnection(config: config, token: auth.tokenProvider(for: config), session: service.session)
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await connection.start()
        })
        #expect(error.message.hasPrefix("O conector Remoto respondeu HTTP 401"))
        #expect(service.requests.allSatisfy { $0.headers["Authorization"] == "Bearer pasted" })
    }

    @Test func notEnoughPermissionIsReportedOnceAndNeverRepeated() async throws {
        let service = FakeOAuthService { _ in }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let config = connector(service)
        try seed(vault, config.id, service)
        service.change {
            $0.validToken = "at-0"
            $0.onTool = { _ in nil }
        }
        let connection = MCPConnection(config: config, token: auth.tokenProvider(for: config), session: service.session)
        _ = try await connection.start()
        service.change {
            $0.validToken = "none" // from now on the server answers 403 insufficient_scope
            $0.challengeStatus = 403
            $0.challengeHeader = #"Bearer error="insufficient_scope", scope="chat:write", resource_metadata="https://x.test/prm""#
        }
        let required = try #require(await #expect(throws: MCPAuthRequired.self, "expected the permission to be asked for") {
            _ = try await connection.call("echo", arguments: .object([:]))
        })
        #expect(required.reason == .moreScope && required.challenge.scope == "chat:write")
        #expect(service.requests.filter { $0.label == "mcp POST /mcp" && $0.json?["method"]?.string == "tools/call" }.count == 1)
        #expect(service.requests.filter { $0.label == "auth POST /token" }.isEmpty) // nothing was renewed for a 403
    }
}

// MARK: - What the card shows

struct MCPLoginStatusTests {
    private func manager(_ service: FakeOAuthService, auth: MCPAuth) -> MCPManager {
        MCPManager(auth: auth, session: service.session)
    }

    @Test func aConnectorWithoutALoginAsksForItInsteadOfFailing() async throws {
        let service = FakeOAuthService()
        let auth = MCPAuth(vault: MemoryVault(), session: service.session)
        let manager = manager(service, auth: auth)
        let config = connector(service)
        await manager.sync([config])
        #expect(await manager.status()[config.id] == .needsSignIn(nil)) // before anything was asked of it

        var plain = connector(service, nil) // from the registry: nothing says it signs in until the server does
        plain.id = UUID()
        await manager.sync([config, plain])
        #expect(await manager.status()[plain.id] == .idle(toolCount: nil))
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await manager.ensureStarted(plain.id)
        })
        #expect(error.message == "Notion precisa de login. Peça para a pessoa clicar em Entrar em Conectores.")
        #expect(await manager.status()[plain.id] == .needsSignIn(nil))
    }

    @Test func anEndedLoginSaysSoOnTheCardAndToTheModel() async throws {
        let service = FakeOAuthService { $0.validToken = "never"; $0.onToken = { _ in .json(#"{"error":"invalid_grant"}"#, status: 400) } }
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let manager = manager(service, auth: auth)
        let config = connector(service)
        try seed(vault, config.id, service, expiresIn: 10)
        await manager.sync([config])
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await manager.call(config.id, tool: "echo", arguments: .object([:]))
        })
        #expect(error.message == "A sessão do Notion expirou. Peça para a pessoa clicar em Entrar de novo em Conectores.")
        #expect(await manager.status()[config.id] == .needsSignIn("A sessão do Notion expirou. Entre de novo."))
        // The next attempt finds no token, and the card still says the session ended (not a first-time "Entrar").
        _ = try? await manager.call(config.id, tool: "echo", arguments: .object([:]))
        #expect(await manager.status()[config.id] == .needsSignIn("A sessão do Notion expirou. Entre de novo."))
    }

    @Test func missingPermissionBecomesItsOwnStateAndTheModelIsToldWhomToAsk() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let manager = manager(service, auth: auth)
        let config = connector(service)
        try seed(vault, config.id, service)
        service.change { $0.validToken = "at-0" }
        await manager.sync([config])
        _ = try await manager.test(config.id)
        #expect(await manager.status()[config.id] == .ready(toolCount: 1))
        service.change {
            $0.validToken = "none"
            $0.challengeStatus = 403
            $0.challengeHeader = #"Bearer error="insufficient_scope", scope="chat:write""#
        }
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await manager.call(config.id, tool: "echo", arguments: .object([:]))
        })
        #expect(error.message == "Notion pediu mais permissão. Peça para a pessoa clicar em Permitir mais em Conectores.")
        #expect(await manager.status()[config.id] == .needsMorePermission("chat:write"))
    }

    @Test func theRequestForMorePermissionSurvivesTheServerRestartingForTheNextCall() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let manager = manager(service, auth: auth)
        let config = connector(service)
        try seed(vault, config.id, service)
        let refused = OSAllocatedUnfairLock(initialState: false) // only the first tools/call is refused for lack of scope
        service.change {
            $0.validToken = "at-0"
            $0.onTool = { _ in
                guard !refused.withLock({ let was = $0; $0 = true; return was }) else { return nil }
                return .init(status: 403, headers: ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="chat:write""#])
            }
        }
        await manager.sync([config])
        let error = try #require(await #expect(throws: ToolError.self, "expected an error") {
            _ = try await manager.call(config.id, tool: "echo", arguments: .object([:]))
        })
        #expect(error.message.hasSuffix("Permitir mais em Conectores."))
        #expect(await manager.status()[config.id] == .needsMorePermission("chat:write"))
        // Another tool of the same connector works with the token it has, and must not make the card forget the request.
        #expect(try await manager.call(config.id, tool: "echo", arguments: .object([:])) == "ok")
        #expect(await manager.status()[config.id] == .needsMorePermission("chat:write"))
        _ = try await manager.test(config.id)
        #expect(await manager.status()[config.id] == .needsMorePermission("chat:write"))

        // Granting it clears the request; the server then reports as usual.
        await manager.scopeGranted(config.id)
        #expect(await manager.status()[config.id] == .idle(toolCount: 1))
        _ = try await manager.test(config.id)
        #expect(await manager.status()[config.id] == .ready(toolCount: 1))
    }

    @Test func signingOutStopsTheConnectorAndAsksForALoginAgain() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let auth = MCPAuth(vault: vault, session: service.session)
        let manager = manager(service, auth: auth)
        let config = connector(service)
        try seed(vault, config.id, service)
        service.change { $0.validToken = "at-0" }
        await manager.sync([config])
        _ = try await manager.test(config.id)
        await auth.signOut(config.id)
        await manager.signedOut(config.id)
        let running = await manager.isRunning(config.id)
        #expect(await manager.status()[config.id] == .needsSignIn(nil) && !running)
    }
}

// MARK: - The model

@MainActor
struct ConnectorLoginModelTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "OrbLogin-\(UUID().uuidString)") }

    @Test func aNewLoginReplacesTheOneStillWaitingForTheBrowserAndTakesItsPort() async throws {
        let service = FakeOAuthService()
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let root = folder()
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: MemoryVault(), connectorSession: service.session)
        model.opensLoginPage = { _ in opened.withLock { $0 += 1 } } // the person never comes back from this tab
        // Slack's way: an app registered to the letter, so the redirect is on one fixed port.
        let config = connector(service, MCPOAuthSettings(clientID: "app", redirect: "http://localhost:\(Int.random(in: 48_100...48_900))/cb"))
        model.connectors = [config]
        let first = Task { await model.signIn(connector: config.id) }
        await waitUntil("the first login to wait for the browser") { opened.withLock { $0 } == 1 }
        #expect(model.signingIn.contains(config.id))

        // Back on the card, "Entrar" is offered again: the second click must not meet the first one's port.
        let browser = FakeOAuthService.Browser()
        model.opensLoginPage = browser.open
        let second = await model.signIn(connector: config.id)
        guard case .connected = second else { Issue.record("expected the second login to connect, got \(second)"); return }
        guard case .failed(let reason) = await first.value else { Issue.record("expected the first login to end"); return }
        #expect(reason == "Login cancelado.")
        #expect(model.signingIn.isEmpty && model.loginAttempts.isEmpty)
    }

    @Test func signingInThroughTheModelStartsTheConnectorAndKeepsTheTokenOutOfTheDataFolder() async throws {
        let service = FakeOAuthService()
        let browser = FakeOAuthService.Browser()
        let vault = MemoryVault()
        let root = folder()
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault, connectorSession: service.session)
        model.opensLoginPage = browser.open
        let config = connector(service)
        model.connectors = [config]
        let outcome = await model.signIn(connector: config.id)
        guard case .connected(let tools, _) = outcome else { Issue.record("expected a connection, got \(outcome)"); return }
        #expect(tools == 1)
        #expect(await model.mcp.status()[config.id] == .ready(toolCount: 1))

        // The token is in the vault, and in no file of the data folder and no address.
        model.saveNow()
        #expect(vault.accounts == [ConnectorSecrets.oauthAccount(id: config.id)])
        #expect(vault.get(ConnectorSecrets.oauthAccount(id: config.id))?.contains("at-1") == true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(files.contains { $0.lastPathComponent == "state.json" })
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains("at-1") && !text.contains("rt-1"), "\(file.lastPathComponent) holds a token")
        }
        #expect(!service.requests.contains { $0.url.absoluteString.contains("at-1") })
        // Every request to the MCP server after the login carries it as a Bearer.
        let calls = service.requests.filter { $0.label == "mcp POST /mcp" }.dropFirst() // the first is the probe
        #expect(!calls.isEmpty && calls.allSatisfy { $0.headers["Authorization"] == "Bearer at-1" })

        // Signing out takes the token from the Keychain and the connector goes back to asking for a login.
        await model.signOut(connector: config.id)
        #expect(vault.get(ConnectorSecrets.oauthAccount(id: config.id))?.contains("at-1") == false)
        #expect(await model.mcp.status()[config.id] == .needsSignIn(nil))
    }

    @Test func deletingAConnectorErasesItsLogin() async throws {
        let service = FakeOAuthService()
        let vault = MemoryVault()
        let root = folder()
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: vault, connectorSession: service.session)
        let config = connector(service)
        model.connectors = [config]
        try seed(vault, config.id, service)
        model.removeConnector(config.id)
        await waitUntil("the account to go") { vault.accounts.isEmpty }
        #expect(model.connectors.isEmpty)
    }

    @Test func resettingTheAppErasesTheLoginsToo() throws {
        var config = MCPServerConfig(name: "Notion", url: "https://mcp.notion.com/mcp")
        config.oauth = MCPOAuthSettings()
        let plan = ResetPlan.make(bots: [], connectors: [config], providers: [], defaultModel: "", learnedContexts: [:],
                                  options: ResetOptions(leavesProviders: true))
        #expect(plan.secretAccounts.contains(ConnectorSecrets.oauthAccount(id: config.id)))
    }

    @Test func aConnectorSavedBeforeLoginsStillLoadsAndOneWithLoginRoundTrips() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"GitHub","url":"https://api.githubcopilot.com/mcp/"}"#
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: Data(old.utf8))
        #expect(config.oauth == nil)
        let broken = #"{"name":"X","oauth":{"clientID":42,"scopes":["a"],"authorizeParameters":"no"}}"#
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: Data(broken.utf8)).oauth == MCPOAuthSettings())
        var withLogin = config
        withLogin.oauth = MCPOAuthSettings(clientID: "abc", needsClientSecret: true, scopes: "a b", authorizeParameters: ["prompt": "consent"],
                                           redirect: "http://localhost:1/cb")
        let data = try JSONEncoder().encode(withLogin)
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: data) == withLogin)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret\":\"")) // the secret has no field in the data file
    }
}
