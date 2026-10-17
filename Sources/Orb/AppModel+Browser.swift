import Foundation

// The Orb's browser as the panel sets it up: how it runs, which search, and what is installed.

extension AppModel {
    /// Another mode for the Orb's browser. The one it had is closed (the profile, and so the logins, stay): a running browser keeps
    /// the flags it was launched with, so the next page opens in the new mode (`update` closes it).
    func setBrowserMode(_ mode: BrowserMode, for botID: UUID) {
        update(botID) { $0.browserMode = mode }
    }

    /// Takes the proxy off the Orb's browser (the panel's "Remover"); the browser is closed and the next page opens direct.
    func removeBrowserProxy(for botID: UUID) {
        saveBrowserProxy(nil, for: botID)
    }

    /// What `browse_proxy` chose, kept for the Orb: the address in its file and the password, when there is one, in the Keychain
    /// (`BrowserProxy.keychainAccount`), never in `state.json`. A Keychain that refuses it leaves the browser with the proxy for
    /// this run of the app only; the file still keeps the address without the password.
    func saveBrowserProxy(_ proxy: String?, for botID: UUID) {
        let account = BrowserProxy.keychainAccount(botID: botID)
        let (address, password) = proxy.map(BrowserProxy.split) ?? (nil, nil)
        if let password {
            _ = secretVault.set(password, account: account)
        } else if BrowserProxy.hasUser(bot(botID)?.browserProxy) {
            secretVault.remove(account)
        }
        update(botID) { $0.browserProxy = address }
    }

    /// The Orb's proxy as the browser takes it: the address of its file with the password from the Keychain put back. A proxy
    /// with no user never reads the Keychain.
    nonisolated static func browserProxy(of bot: Bot, vault: any SecretVault) -> String? {
        guard let address = bot.browserProxy else { return nil }
        guard BrowserProxy.hasUser(address) else { return address }
        return BrowserProxy.joined(address, password: vault.get(BrowserProxy.keychainAccount(botID: bot.id)))
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
