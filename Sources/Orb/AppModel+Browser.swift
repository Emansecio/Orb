import Foundation

// The Orb's browser as the panel sets it up: how it runs, which search, and what is installed.

extension AppModel {
    /// Another mode for the Orb's browser. The one it had is closed (the profile, and so the logins, stay): a running browser keeps
    /// the flags it was launched with, so the next page opens in the new mode (`update` closes it).
    func setBrowserMode(_ mode: BrowserMode, for botID: UUID) {
        update(botID) { $0.browserMode = mode }
    }

    func setSearchProvider(_ provider: SearchProvider, for botID: UUID) {
        update(botID) { $0.searchProvider = provider }
    }

    /// What the Orb's browser needs and has on this Mac, for the panel's status line.
    func browserStatus() async -> BrowserStatus {
        await browserHub.status()
    }

    /// Whether a TinyFish key is saved. The Keychain is read off the main thread.
    func hasSearchKey(for provider: SearchProvider) async -> Bool {
        guard provider == .tinyfish else { return true }
        let keys = SearchKeys(vault: secretVault)
        return (try? await runDetached { keys.tinyFish != nil }) ?? false
    }
}
