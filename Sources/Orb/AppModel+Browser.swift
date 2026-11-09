import AppKit
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

    /// A conversation of the Orb that will not come back (a routine's run, a request from another Orb) is over: the tab it had in
    /// the Orb's browser is closed (`BrowserHub.endScope`). A chat and a group keep theirs.
    func endBrowserConversation(_ conversation: Conversation, of botID: UUID) {
        guard let scope = conversation.gatewaySessionID else { return }
        let hub = browserHub
        Task { await hub.endScope(botID: botID, scope: scope) }
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

    // MARK: The person's own use

    /// Opens the Orb's browser in its own window for the person ("Abrir o navegador"), with its profile and logins, and brings
    /// it to the front: the person asked, so this one gesture may put another app's window ahead (AGENTS.md, PROD-1). The Orb's
    /// browser tools wait until it is handed back. Already open: brought forward again.
    func openBrowserForPerson(_ botID: UUID) {
        guard let bot = bot(botID), bot.capabilities.contains(.browser) else { return }
        let hub = browserHub
        if browserWithPerson.contains(botID) {
            if let pid = hub.profileFolder(botID: botID).flatMap(BrowserProfileCache.holder) { Self.bringForward(pid) }
            return
        }
        // One hand at a time: a takeover in the live screen's window ends here (its hand-back would let the Orb in).
        liveScreens.giveBackControl(botID)
        browserWithPerson.insert(botID)
        let vault = secretVault, mode = bot.browserMode, name = bot.name
        Task {
            // The Orb's proxy, as a turn sets it: a browser opened without it would be closed by the next turn, window and all.
            let proxy = BrowserProxy.hasUser(bot.browserProxy)
                ? await Task.detached { Self.browserProxy(of: bot, vault: vault) }.value : bot.browserProxy
            hub.setProxy(proxy, botID: botID)
            do {
                let pid = try await hub.openForPerson(botID: botID, mode: mode)
                // Handed back while it opened: the window goes again.
                guard browserWithPerson.contains(botID) else { await hub.giveBackFromPerson(botID: botID); return }
                if let pid { Self.bringForward(pid) }
                watchPersonBrowser(botID)
            } catch {
                browserWithPerson.remove(botID)
                appendToChat(.notice(Self.personBrowserFailure(error, orb: name)), of: botID, in: session(botID).chatID)
            }
        }
    }

    /// The person is done with the browser they opened: its window goes back to the background (unless the Orb is set to
    /// Visível) and the Orb's tools go on.
    func giveBrowserBack(_ botID: UUID) {
        guard browserWithPerson.remove(botID) != nil else { return }
        // Still opening (the watcher starts once the window is up): the open hands it back when it is done, since a close now
        // would race the launch and leave its window behind.
        guard let watcher = personBrowserWatchers.removeValue(forKey: botID) else { return }
        watcher.cancel()
        let hub = browserHub
        Task { [weak self] in
            let pages = await hub.giveBackFromPerson(botID: botID)
            self?.noteBrowserUsed(botID, pages: pages)
        }
    }

    /// A line in the Orb's chat that the person used its browser: the next turn is told it once, with the pages left open
    /// (`SinceLastTurn`), so "continua daqui" knows where they stopped. It marks nothing unread: the person did it.
    func noteBrowserUsed(_ botID: UUID, pages: [BrowserTab], at date: Date = .now) {
        guard let bot = bot(botID) else { return }
        _ = appendToChat(.event(OrbEvent(browserUsed: OrbRef(bot), pages: pages, until: date)), of: botID, marksUnread: false)
    }

    /// While the person has the browser, looks now and then whether its window is still there: closing it, or quitting the
    /// browser, hands it back as the button does. The look also keeps the browser's idle timeout from closing it under them.
    func watchPersonBrowser(_ botID: UUID) {
        personBrowserWatchers[botID]?.cancel()
        let hub = browserHub, every = personBrowserCheck
        personBrowserWatchers[botID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, self != nil else { return }
                if await hub.personWindowIsOpen(botID: botID) { continue }
                guard !Task.isCancelled else { return }
                self?.giveBrowserBack(botID)
                return
            }
        }
    }

    /// What the chat says when the window did not open, in the person's words (the driver's are the model's).
    nonisolated static func personBrowserFailure(_ error: any Error, orb: String) -> String {
        if case BrowserDriverError.notInstalled = error {
            return "O navegador de \(orb) não está pronto: confira em Ajustes → Navegador e tente de novo."
        }
        return "Não consegui abrir o navegador de \(orb). Tente de novo em instantes."
    }

    /// Brings the browser's window forward, by its process: the app gives way first (macOS 14 activates cooperatively).
    private static func bringForward(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp?.yieldActivation(to: app)
        LiveTakeoverPlatform().activate(pid)
    }
}
