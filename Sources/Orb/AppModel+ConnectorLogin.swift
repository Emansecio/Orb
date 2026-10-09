import Foundation

/// The login of the connectors that sign in (Notion, Linear, Slack with its own app…): see `MCPAuth`.
extension AppModel {
    /// Signs connector `id` in through the browser, then starts it. `moreScope`: what the server asked for beyond what was
    /// granted ("Permitir mais"). Cancel it by cancelling the task that awaits it.
    func signIn(connector id: UUID, moreScope: String? = nil) async -> ConnectorTestOutcome {
        guard let config = connectors.first(where: { $0.id == id }) else { return .failed("Esse conector não existe mais.") }
        // One login per connector: a new one replaces the one still waiting for the browser (which holds the loopback port,
        // fixed for Slack) and starts when that one has let go of it.
        let previous = loginAttempts[id]
        previous?.cancel()
        let attempt = Task { [connectorAuth, opensLoginPage] () -> String? in
            _ = await previous?.result
            do {
                try await connectorAuth.signIn(config, scope: moreScope, open: opensLoginPage)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        loginAttempts[id] = attempt
        signingIn.insert(id)
        let failure = await withTaskCancellationHandler { await attempt.value } onCancel: { attempt.cancel() }
        if loginAttempts[id] == attempt {
            loginAttempts[id] = nil
            signingIn.remove(id)
        }
        if let failure { return .failed(failure) }
        // A connector that turned out to ask for a login (from the registry, say) is one that signs in from now on: its card offers "Sair da conta".
        if let index = connectors.firstIndex(where: { $0.id == id }), connectors[index].oauth == nil { connectors[index].oauth = MCPOAuthSettings() }
        await mcp.scopeGranted(id)
        return await testConnector(id)
    }

    /// Gives up the login that is waiting for the browser (it ends with "Login cancelado.").
    func cancelSignIn(connector id: UUID) { loginAttempts[id]?.cancel() }

    /// "Sair da conta": forgets the tokens (the Client ID and Secret typed for it stay) and stops the connector.
    func signOut(connector id: UUID) async {
        await connectorAuth.signOut(id)
        await mcp.signedOut(id)
    }

    /// Deletes a connector, and with it the account its login lives in.
    func removeConnector(_ id: UUID) {
        connectors.removeAll { $0.id == id }
        Task { [connectorAuth] in await connectorAuth.deleteAccount(id) }
    }
}
