import Foundation

/// The login of the connectors that sign in (Notion, Linear, Slack with its own app…): see `MCPAuth`.
extension AppModel {
    /// Signs connector `id` in through the browser, then starts it. `moreScope`: what the server asked for beyond what was
    /// granted ("Permitir mais"). Cancel it by cancelling the task that awaits it.
    func signIn(connector id: UUID, moreScope: String? = nil) async -> ConnectorTestOutcome {
        guard let config = connectors.first(where: { $0.id == id }) else { return .failed("Esse conector não existe mais.") }
        do {
            try await connectorAuth.signIn(config, scope: moreScope, open: opensLoginPage)
        } catch {
            return .failed(error.localizedDescription)
        }
        // A connector that turned out to ask for a login (from the registry, say) is one that signs in from now on: its card offers "Sair da conta".
        if let index = connectors.firstIndex(where: { $0.id == id }), connectors[index].oauth == nil { connectors[index].oauth = MCPOAuthSettings() }
        return await testConnector(id)
    }

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
