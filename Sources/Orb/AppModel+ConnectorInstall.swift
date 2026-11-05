import Foundation

// The `connector_install` tool's side of the app: an Orb installs a connector when the person asks for one, or the task
// needs one, without the person opening the Conectores page. It goes the same way as the page's form: the connector joins
// `connectors` (so its card appears at once, "Conectando…"), secrets go to the Keychain when the state is saved, the
// Orb's "Conectores" switch turns on, and it is started at once, so the result can list its tools.

extension AppModel {
    /// The handler a turn's tools get (`ToolContext.installConnector`). `usableNow`: the turn reaches connectors through
    /// `connector_call` (the Orb had "Conectores" on when it began), so a connector installed now can be used before it ends.
    func connectorInstallHandler(for botID: UUID, usableNow: Bool) -> ConnectorInstallHandler {
        { [weak self] arguments in
            guard let model = self else { throw ToolError("O app está fechando.") }
            return try await model.installConnector(arguments, orb: botID, usableNow: usableNow)
        }
    }

    /// Installs (or, when the same server is already there, enables for this Orb) the connector a call describes, starts it
    /// and says how it went. A connector that does not start is taken out again, so a wrong command leaves nothing behind.
    func installConnector(_ arguments: JSONValue, orb botID: UUID, usableNow: Bool) async throws -> ConnectorInstallResult {
        guard bot(botID) != nil else { throw ToolError("Este Orb não existe mais.") }
        // A dev run starts no connector (`syncConnectors`): installing would only leave a card that never comes up.
        guard !isDevRun else { throw ToolError("Conectores não rodam nesta execução de desenvolvimento.") }
        let request = try ConnectorInstallRequest(arguments)
        let existing = connectors.first(where: request.isSameServer)
        var config = existing ?? MCPServerConfig(name: request.name)
        if existing == nil {
            config.name = ConnectorGateway.uniqueName(request.name, among: connectors)
            config.command = request.command
            config.arguments = request.arguments
            config.url = request.url
            config.summary = request.summary
            config.orbIDs = request.allOrbs ? nil : [botID]
        } else if !request.allOrbs, var orbs = config.orbIDs {
            orbs.insert(botID)
            config.orbIDs = orbs
        } else if request.allOrbs {
            config.orbIDs = nil
        }
        // Values given now win; the ones it had stay (an installed connector keeps its keys).
        config.environment.merge(request.environment) { _, new in new }
        config.headers.merge(request.headers) { _, new in new }
        config.secretKeys.formUnion(ConnectorSecrets.secretNames(of: config))
        config.isEnabled = true

        if let index = connectors.firstIndex(where: { $0.id == config.id }) { connectors[index] = config } else { connectors.append(config) }
        allowConnectors(for: [botID])

        let status = await connectAndWait(config.id)
        let name = config.name
        let use = usableNow
            ? "Use it now: connector_call(connector: \"\(name)\", tool, arguments)."
            : "It is usable from the person's next message (connectors were off for this Orb and are now on)."
        switch status {
        case .ready?, .idle?:
            let listing = await mcp.catalog(config.id).map { ConnectorGateway.render($0, connector: name) } ?? ""
            let opening = existing == nil ? "Installed connector \(name)" : "Connector \(name) was already installed; enabled it for this Orb"
            return ConnectorInstallResult(text: "\(opening). \(use)\n\n\(listing)", config: config)
        case .needsSignIn?, .needsMorePermission?:
            return ConnectorInstallResult(
                text: "Installed connector \(name), but it needs the person to sign in: ask them to click \"Entrar\" on its card in "
                    + "Conectores, then use it.",
                config: nil)
        case .failed(let message)?:
            throw notStarted(name, existing: existing != nil, id: config.id, why: ": " + message.prefix(400))
        default:
            throw notStarted(name, existing: existing != nil, id: config.id, why: " (não respondeu)")
        }
    }

    /// A connector that did not start: a new one is taken out again (its card goes, nothing of it stays); one that was
    /// already installed stays, as the person had it, with what this call changed.
    private func notStarted(_ name: String, existing: Bool, id: UUID, why: some StringProtocol) -> ToolError {
        guard !existing else {
            return ToolError("O conector \(name) já estava instalado, mas não subiu\(why). Peça à pessoa para conferir o cartão dele em Conectores.")
        }
        connectors.removeAll { $0.id == id }
        return ToolError("O conector \(name) não subiu e não ficou instalado\(why). Confira o comando, os argumentos e as variáveis "
            + "na documentação dele e tente de novo.")
    }

}
