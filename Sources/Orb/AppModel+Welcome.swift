import Foundation

// What the welcome screen asks of the model: the Orb it suggests, starting a new Orb from a kept memory, and the one
// bit of memory it keeps (that an Orb was made once, which changes its first sentence).

/// A preference store that lives only in memory (tests and developer runs, which must not touch the app's preferences).
final class InMemoryPreferences: PreferenceStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Why the welcome screen was opened by something other than the empty list, so it can say so above the connect card.
enum WelcomeReason: Equatable {
    /// "Nova rotina" with no Orb and no model.
    case routine

    var message: String {
        switch self {
        case .routine: "Para criar uma rotina, primeiro conecte um modelo. Depois é só voltar em Rotinas."
        }
    }
}

extension AppModel {
    /// The preference that says an Orb was made here once. "Redefinir o Orb" clears the app's preferences, so after a
    /// reset the welcome screen speaks as it does on first use.
    static let createdOrbKey = "orb.welcome.criouOrb"

    /// An Orb was made: the welcome screen, if it comes back (every Orb deleted), says "Hora de um Orb novo".
    func noteOrbCreated() {
        welcomePreferences.set(true, forKey: Self.createdOrbKey)
    }

    var hasCreatedOrb: Bool { welcomePreferences.object(forKey: Self.createdOrbKey) as? Bool == true }

    /// What the welcome screen says, first use or an emptied list.
    var welcomeCopy: WelcomeCopy { hasCreatedOrb ? .returning : .firstUse }

    /// "Começar com o Atlas": the suggested Orb, made in one click with a folder of its own (`~/Orbs/Atlas`, or the
    /// next free name) and the interview on, like the Orb the app used to start with.
    @discardableResult
    func createSuggestedOrb(base: URL = OrbFolder.defaultBase) -> Bot {
        let look = WelcomeLooks.atlas
        return createBot(name: "Atlas", role: "Assistente do seu Mac", orb: look, model: "", mode: .ask, base: base)
    }

    /// "Continuar" on a kept memory: opens the new-Orb sheet already starting from it. The sheet takes the memory
    /// (`NewBotSheet(kept:chosen:)`); the root view clears `newBotStart` when the sheet goes away.
    func startNewOrb(from memory: KeptMemory?) {
        newBotStart = memory
        showNewBot = true
    }

    /// "Importar de outro assistente": opens the new-Orb sheet already on the import panel.
    func startNewOrbImporting() {
        newBotStart = nil
        newBotImporting = true
        showNewBot = true
    }
}
