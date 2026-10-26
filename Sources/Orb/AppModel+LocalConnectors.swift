import Foundation

/// The connectors that run on this Mac (Google Agenda, Lembretes, Gmail): installing one, and checking where it stands with
/// macOS. Checking never shows a dialog; only `LocalConnectorSetup.connect`, started by the person's click, does.
extension AppModel {
    var localSetup: LocalConnectorSetup { LocalConnectorSetup(environment: localEnvironment) }

    func installedLocalConnector(_ kind: LocalConnectorKind) -> MCPServerConfig? {
        connectors.first { $0.local == kind.rawValue }
    }

    /// Installs the connector (or, when it is already there, changes which Orbs use it) and turns "Conectores" on for the Orbs
    /// that get it, like the editor of any other connector.
    @discardableResult
    func installLocalConnector(_ kind: LocalConnectorKind, orbIDs: Set<UUID>?, anyAccount: Bool = false) -> MCPServerConfig {
        if let index = connectors.firstIndex(where: { $0.local == kind.rawValue }) {
            let before = connectors[index].orbIDs ?? Set(bots.map(\.id))
            connectors[index].orbIDs = orbIDs
            connectors[index].anyAccount = connectors[index].anyAccount || anyAccount
            allowConnectors(for: (orbIDs ?? []).subtracting(before))
            return connectors[index]
        }
        var config = kind.config
        config.orbIDs = orbIDs
        config.anyAccount = anyAccount
        connectors.append(config)
        allowConnectors(for: orbIDs ?? [])
        return config
    }

    /// Looks at the permission and the account of every installed local connector, for the cards. Never asks macOS anything.
    func refreshLocalStates() async {
        guard !DevRun.isActive else { return } // a developer run (snapshots) draws the states it was given and touches nothing of the Mac
        let setup = localSetup
        var states: [LocalConnectorKind: LocalConnectorState] = [:]
        for kind in LocalConnectorKind.allCases {
            guard let installed = installedLocalConnector(kind) else { continue }
            states[kind] = await setup.state(of: kind, anyAccount: installed.anyAccount)
        }
        if states != localStates { localStates = states } // same states: no write, so no view redraws
    }
}
