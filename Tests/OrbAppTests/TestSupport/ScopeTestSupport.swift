import Foundation
@testable import Orb

// Scope operations the app itself no longer calls (the editors set `orbIDs` directly); the scope tests still use them.

extension OrbScoped {
    var isForAllOrbs: Bool { orbIDs == nil }
}

extension AppModel {
    /// Turns one connector on or off for one Orb, and the Orb's "Conectores" switch on with it.
    func setConnector(_ id: UUID, enabled: Bool, for botID: UUID) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].orbIDs = Self.toggled(connectors[index].orbIDs, botID: botID, on: enabled, allBots: bots.map(\.id))
        if enabled { allowConnectors(for: [botID]) }
    }

    /// The new scope after switching one Orb: from "all Orbs" it becomes everyone else (minus this one) or just it.
    nonisolated static func toggled(_ scope: Set<UUID>?, botID: UUID, on: Bool, allBots: [UUID]) -> Set<UUID>? {
        var ids = scope ?? Set(allBots)
        if on { ids.insert(botID) } else { ids.remove(botID) }
        return ids.isSuperset(of: allBots) && scope == nil ? nil : ids
    }
}
