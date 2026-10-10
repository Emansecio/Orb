import Foundation

// The Orb's browser as the panel sets it up: which engine, which search, and what is installed.

extension AppModel {
    /// Another browser for the Orb. The one it had is closed (the profile, and so the logins, stay): a running browser keeps
    /// the engine it was launched with, so the next page opens in the new one.
    func setBrowserEngine(_ engine: BrowserEngineKind, for botID: UUID) {
        guard let old = bot(botID)?.browserEngine, old != engine else { return }
        update(botID) { $0.browserEngine = engine }
        let hub = browserHub
        Task { await hub.close(botID: botID, leaving: old) }
    }

    func setSearchProvider(_ provider: SearchProvider, for botID: UUID) {
        update(botID) { $0.searchProvider = provider }
    }

    /// What `engine` needs and has on this Mac, for the panel's status line.
    func browserEngineStatus(for engine: BrowserEngineKind) async -> BrowserEngineStatus {
        await browserHub.status(for: engine)
    }

    /// Whether a TinyFish key is saved. The Keychain is read off the main thread.
    func hasSearchKey(for provider: SearchProvider) async -> Bool {
        guard provider == .tinyfish else { return true }
        let keys = SearchKeys(vault: secretVault)
        return (try? await runDetached { keys.tinyFish != nil }) ?? false
    }
}
