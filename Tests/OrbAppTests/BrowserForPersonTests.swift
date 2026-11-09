import Foundation
import Testing
@testable import Orb

/// The person opens an Orb's browser for themself ("Abrir o navegador", docs/NAVEGADOR-DA-PESSOA-PLANO.md): its window, the
/// Orb's tools waiting, a run nobody watches not waiting, and the hand-back.
@Suite final class BrowserForPersonTests {
    let profiles = TempFolder("OrbPersonBrowser", creating: true)

    /// The browser holds the Orb's profile: its lock names a running process (this one), as Chromium writes it.
    private func lockProfile(_ setup: FakeBrowserSetup) throws {
        let profile = try #require(setup.hub.profileFolder(botID: setup.botID))
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile.appending(path: "SingletonLock").path,
                                                   withDestinationPath: "host.local-\(getpid())")
    }

    private func unlockProfile(_ setup: FakeBrowserSetup) throws {
        let profile = try #require(setup.hub.profileFolder(botID: setup.botID))
        try FileManager.default.removeItem(at: profile.appending(path: "SingletonLock"))
    }

    private func setup(mode: BrowserMode = .background, ready: Bool = true) -> FakeBrowserSetup {
        FakeBrowserSetup(mode: mode, ready: ready, profiles: profiles.url)
    }

    // MARK: Opening

    @Test func aBrowserThatIsNotRunningOpensWithItsWindowAndTheOrbWaits() async throws {
        let setup = setup()
        setup.driver.state.withLock { $0.hasPage = false }
        try lockProfile(setup)
        let pid = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        #expect(setup.driver.calls.contains("setHeaded true"))
        #expect(setup.hub.control.isHeld(setup.botID))
        #expect(pid == getpid(), "the process named by the profile's lock is the one brought forward")
    }

    @Test func aBrowserInTheBackgroundIsLaunchedAgainWithItsWindow() async throws {
        let setup = setup()
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        #expect(setup.driver.calls.contains("setHeaded true"))
    }

    @Test func aWindowAlreadyOpenIsLeftAsItIs() async throws {
        // The Orb set to Visível, or a window `browse_show` left open: nothing is launched again, nothing reloads.
        let setup = setup(mode: .visible)
        setup.driver.state.withLock { $0.headed = true }
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .visible)
        #expect(!setup.driver.calls.contains { $0.hasPrefix("setHeaded") })
        #expect(setup.hub.control.isHeld(setup.botID))
    }

    @Test func aBrowserThatCannotOpenHoldsNothing() async throws {
        let setup = setup(ready: false)
        await #expect(throws: BrowserDriverError.self) { try await setup.hub.openForPerson(botID: setup.botID, mode: .background) }
        #expect(!setup.hub.control.isHeld(setup.botID))
        #expect(setup.driver.calls.isEmpty)
    }

    @Test func showingTheWindowFromTheWholeBrowserReopensOnlyTheOtherConversationsPages() async throws {
        let setup = setup()
        func scroll(_ scope: String) async throws {
            var context = setup.context()
            context.browser.scope = scope
            _ = try await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context)
        }
        let labelB = TabBook.label(for: "chat-B")
        try await scroll("chat-A")
        try await scroll("chat-B")
        setup.driver.state.withLock {
            $0.tabs = [BrowserTab(id: "t1", title: "A", url: "https://a.test/", isActive: false),
                       BrowserTab(id: "t2", title: "B", url: "https://b.test/", isActive: true, label: labelB)]
        }
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        let calls = setup.driver.calls
        let shown = try #require(calls.firstIndex(of: "setHeaded true"))
        // chat-B called last: its page is the one the window reopened. Only chat-A's comes back in a tab of its own, once.
        #expect(Array(calls.dropFirst(shown + 1).filter { $0.hasPrefix("command tab new") })
                == ["command tab new --label \(TabBook.label(for: "chat-A")) https://a.test/"])
    }

    // MARK: While the person has it

    @Test func theWindowIsOpenWhileTheBrowserHoldsTheProfileAndHasATab() async throws {
        let setup = setup()
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        #expect(await !setup.hub.personWindowIsOpen(botID: setup.botID), "no lock: the browser was quit")
        #expect(!setup.driver.calls.contains("tabs"), "a quit browser is asked nothing (it would be launched again)")
        try lockProfile(setup)
        #expect(await setup.hub.personWindowIsOpen(botID: setup.botID))
        setup.driver.state.withLock { $0.tabs = [] }
        #expect(await !setup.hub.personWindowIsOpen(botID: setup.botID), "no tab left: the window was closed")
    }

    @Test func aRunNobodyWatchesDoesNotWaitForThePerson() async throws {
        let setup = setup()
        setup.hub.control.take(setup.botID)
        var context = setup.context()
        context.unattended = true
        let answered = LockedBox(false)
        let call = Task {
            defer { answered.value = true }
            return try await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context)
        }
        // Waiting would last as long as the person browses: a call still waiting after a while is the failure, and is let go.
        #expect(await waitUntil("the run to answer without waiting", timeout: .seconds(5)) { answered.value })
        call.cancel()
        await #expect(throws: ToolError(BrowserControl.inUseByPerson)) { _ = try await call.value }
        #expect(setup.driver.calls.isEmpty)
    }

    @Test func aChatWaitsForThePersonAndLooksAgainAfter() async throws {
        let setup = setup()
        setup.hub.control.take(setup.botID)
        let context = setup.context()
        let call = Task { try await BrowseScrollTool().run(.object(["direction": .string("down")]), context: context) }
        #expect(await waitUntil("the chat's tool to wait") { setup.hub.control.waitingCount(setup.botID) == 1 })
        #expect(setup.driver.calls.isEmpty)
        await setup.hub.giveBackFromPerson(botID: setup.botID)
        await #expect(throws: ToolError(BrowserControl.handedBack)) { _ = try await call.value }
    }

    // MARK: Handing it back

    @Test func handingBackHidesTheWindowAndLetsTheOrbGoOn() async throws {
        let setup = setup()
        try lockProfile(setup)
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        await setup.hub.giveBackFromPerson(botID: setup.botID)
        #expect(setup.driver.calls.last == "setHeaded false")
        #expect(!setup.hub.control.isHeld(setup.botID))
        #expect(setup.hub.existingSession(botID: setup.botID) != nil)
    }

    @Test func aVisibleOrbKeepsItsWindowWhenHandedBack() async throws {
        let setup = setup(mode: .visible)
        try lockProfile(setup)
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .visible)
        let before = setup.driver.calls.count
        await setup.hub.giveBackFromPerson(botID: setup.botID)
        #expect(!setup.driver.calls.dropFirst(before).contains { $0.hasPrefix("setHeaded") })
        #expect(!setup.hub.control.isHeld(setup.botID))
    }

    @Test func aBrowserThePersonQuitIsClosedForGoodAndNotLaunchedAgain() async throws {
        let setup = setup()
        try lockProfile(setup)
        _ = try await setup.hub.openForPerson(botID: setup.botID, mode: .background)
        try unlockProfile(setup)
        let before = setup.driver.calls.count
        await setup.hub.giveBackFromPerson(botID: setup.botID)
        let after = Array(setup.driver.calls.dropFirst(before))
        #expect(after == ["close"], "no relaunch, nothing asked of a browser that is gone")
        #expect(setup.hub.existingSession(botID: setup.botID) == nil)
        #expect(!setup.hub.control.isHeld(setup.botID))
    }

    @Test func theFailureIsToldInThePersonsWords() {
        #expect(AppModel.personBrowserFailure(BrowserDriverError.notInstalled("x"), orb: "Atlas").contains("Ajustes → Navegador"))
        #expect(AppModel.personBrowserFailure(BrowserDriverError.noPage, orb: "Atlas") == "Não consegui abrir o navegador de Atlas. Tente de novo em instantes.")
    }
}

/// The app's side: the state the views read, the watcher that hands the browser back when its window goes, and the mode that
/// does not change under the person.
@Suite final class BrowserForPersonModelTests {
    let root = TempFolder("OrbPersonBrowserModel")
    let profiles = TempFolder("OrbPersonBrowserProfiles", creating: true)

    @MainActor private func model(capable: Bool = true) -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Atlas", role: "", orb: OrbConfig()))
        Store(directory: root.url).save(state)
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false, secretVault: MemoryVault())
        model.personBrowserCheck = .milliseconds(20)
        let botID = model.bots[0].id
        model.update(botID) { if capable { $0.capabilities.insert(.browser) } else { $0.capabilities.remove(.browser) } }
        return (model, botID)
    }

    @Test @MainActor func openingHoldsTheBrowserUntilItIsHandedBack() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup(profiles: profiles.url)
        model.browserHub = setup.hub
        // The browser holds the profile (as Chromium locks it), so the watcher finds the window there.
        let profile = try #require(setup.hub.profileFolder(botID: botID))
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile.appending(path: "SingletonLock").path,
                                                   withDestinationPath: "host.local-\(getpid())")
        model.openBrowserForPerson(botID)
        #expect(model.browserWithPerson.contains(botID))
        #expect(await waitUntil("the window to open") { setup.driver.calls.contains("setHeaded true") })
        #expect(setup.hub.control.isHeld(botID))
        model.giveBrowserBack(botID)
        #expect(!model.browserWithPerson.contains(botID))
        #expect(await waitUntil("the Orb to have it again") { !setup.hub.control.isHeld(botID) })
    }

    @Test @MainActor func closingTheWindowHandsTheBrowserBack() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup(profiles: profiles.url)
        model.browserHub = setup.hub
        model.openBrowserForPerson(botID)
        // No lock on the profile: the browser is gone, as after ⌘Q in its window.
        #expect(await waitUntil("the watcher to hand it back") { !model.browserWithPerson.contains(botID) })
        #expect(await waitUntil("the Orb to have it again") { !setup.hub.control.isHeld(botID) })
        #expect(model.personBrowserWatchers[botID] == nil)
    }

    @Test @MainActor func handingBackWhileItOpensLetsTheOpenFinishFirst() async throws {
        let (model, botID) = model()
        let setup = FakeBrowserSetup(profiles: profiles.url)
        model.browserHub = setup.hub
        _ = try await setup.hub.session(botID: botID, mode: .background)   // the Orb had used its browser before
        let gate = TestGate()
        setup.driver.headedGate.withLock { $0 = gate }
        model.openBrowserForPerson(botID)
        #expect(await waitUntil("the window to be coming up") { setup.driver.calls.contains("setHeaded true") })
        model.giveBrowserBack(botID)   // before the window is up: the open hands it back when it is done
        // The window comes up a moment later: a close sent meanwhile would go under it and leave it behind.
        for _ in 0..<200 { await Task.yield() }
        let beforeUp = setup.driver.calls.count
        await gate.open()
        #expect(await waitUntil("the window to go after it came up") { setup.driver.calls.dropFirst(beforeUp).contains("close") })
        #expect(await waitUntil("the Orb to have it again") { !setup.hub.control.isHeld(botID) })
        #expect(model.personBrowserWatchers[botID] == nil)
    }

    @Test @MainActor func aBrowserThatDoesNotOpenSaysSoInTheChat() async throws {
        let (model, botID) = model()
        model.browserHub = FakeBrowserSetup(ready: false, profiles: profiles.url).hub
        model.openBrowserForPerson(botID)
        #expect(await waitUntil("the failure") { !model.browserWithPerson.contains(botID) })
        let notices = model.session(botID).conversation?.items.compactMap { item -> String? in
            if case .notice(let text) = item.kind { text } else { nil }
        } ?? []
        #expect(notices.contains { $0.contains("Ajustes → Navegador") })
    }

    @Test @MainActor func anOrbWithoutTheWebOpensNothing() {
        let (model, botID) = model(capable: false)
        let setup = FakeBrowserSetup(profiles: profiles.url)
        model.browserHub = setup.hub
        model.openBrowserForPerson(botID)
        #expect(!model.browserWithPerson.contains(botID))
        #expect(!setup.hub.control.isHeld(botID))
    }
}
