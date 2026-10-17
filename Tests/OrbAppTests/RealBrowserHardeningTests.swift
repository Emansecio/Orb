import Foundation
import Testing
@testable import Orb

// The same guarantees as AgentBrowserHardeningTests, against the real `agent-browser` and a real Chrome: a command never starts a
// browser of its own choosing, a stale session with other flags is not reused, and quitting closes what the tools server of a Claude
// Code turn opened. Skipped without the browser (and with ORB_SKIP_REAL_BROWSER_TESTS=1), like the other real-browser tests.
@Suite(.serialized)
struct RealBrowserHardeningTests {
    private static func driver(for config: AgentBrowserConfig) -> AgentBrowserDriver {
        AgentBrowserDriver(config: config, environment: { ProcessInfo.processInfo.environment })
    }

    private static func waitUntilGone(_ session: String, with driver: AgentBrowserDriver) async -> Bool {
        for _ in 0..<80 {
            if await !driver.runningSessions().contains(session) { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3)))
    func aBrowserWhoseBackgroundProcessDiedIsNotReplacedByOneOfAgentBrowsersChoosing() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let session = try await scenario.session()
            let first = try #require(session.driver as? AgentBrowserDriver)
            _ = try await first.open(scenario.server.url("/index.html"))
            #expect(try await first.currentURL() != nil)

            // The daemon goes while this driver is not looking: another process closes it (the Orb's `browse_close` in a Claude Code
            // turn, an idle timeout, a mode change, "Remover" in Ajustes).
            let other = Self.driver(for: first.config)
            try await other.close()
            #expect(await Self.waitUntilGone(first.config.session, with: other), "the background process is gone")
            // (The first driver's own cache of "it is there" is only a few seconds long.)
            try await Task.sleep(for: AgentBrowserDriver.aliveWindow + .milliseconds(300))

            await #expect(throws: BrowserDriverError.noPage) { _ = try await first.snapshot(interactive: true, selector: nil) }
            await #expect(throws: BrowserDriverError.noPage) { _ = try await first.read() }
            await #expect(throws: BrowserDriverError.noPage) { _ = try await first.tabs() }
            await #expect(throws: BrowserDriverError.noPage) { _ = try await first.attribute("type", of: "e1") }
            #expect(try await first.currentURL() == nil)
            // Nothing started: the session is still not running (before, any of these launched a Chrome without the Orb's flags).
            #expect(await !other.runningSessions().contains(first.config.session), "no browser was started by a command that is not `open`")

            // And the page opens again with the Orb's own profile.
            let page = try await first.open(scenario.server.url("/index.html"))
            #expect(page.title == "Página de teste do Orb")
        } catch {
            await scenario.finish()
            throw error
        }
        let left = await scenario.finish()
        #expect(left.isEmpty, "\(left)")
    }

    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3)))
    func aRunningSessionLaunchedWithAnotherProfileIsRelaunchedWithTheOrbs() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let base = try #require(try await scenario.session().driver as? AgentBrowserDriver).config
            let wrong = scenario.profiles.appending(path: "perfil-errado")
            let right = scenario.profiles.appending(path: "perfil-certo")
            var staleConfig = base
            staleConfig.profile = wrong
            var orbConfig = base
            orbConfig.profile = right

            // A browser left running with another profile (an older version of the app, a settings change).
            _ = try await Self.driver(for: staleConfig).open(scenario.server.url("/index.html"))
            #expect(!RealBrowserScenario.processes(under: wrong.path).isEmpty, "the wrong one is running")

            let current = Self.driver(for: orbConfig)
            let page = try await current.open(scenario.server.url("/index.html"))
            #expect(page.title == "Página de teste do Orb")
            let running = RealBrowserScenario.processes(under: right.path)
            #expect(!running.isEmpty, "the Orb's profile is the one in use now")
            for _ in 0..<60 where !RealBrowserScenario.processes(under: wrong.path).isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            #expect(RealBrowserScenario.processes(under: wrong.path).isEmpty, "and the wrong one is closed")
        } catch {
            await scenario.finish()
            throw error
        }
        let left = await scenario.finish()
        #expect(left.isEmpty, "\(left)")
    }

    /// The tools server of a Claude Code turn opens the browser in a process of its own, with a hub of its own; the app's hub holds
    /// nothing. Quitting the app must still leave no browser behind.
    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3)))
    func quittingClosesTheBrowserATurnOfClaudeCodeOpened() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let base = try #require(try await scenario.session().driver as? AgentBrowserDriver).config
            await scenario.hub.close(botID: scenario.botID) // the app's own session (it only served to find out the settings)
            // The app's hub, at quit, has no session; it knows where agent-browser is because the browser was looked up.
            let app = BrowserHub(profilesDirectory: scenario.profiles, locate: { RealBrowsers.status() }, makeDriver: { config in
                var config = config
                config.socketDirectory = base.socketDirectory
                return AgentBrowserDriver(config: config, environment: { ProcessInfo.processInfo.environment })
            })
            _ = await app.status()
            // The tools server's hub, another process in real life.
            let server = BrowserHub(profilesDirectory: scenario.profiles, locate: { RealBrowsers.status() }, makeDriver: { config in
                var config = config
                config.socketDirectory = base.socketDirectory
                return AgentBrowserDriver(config: config, environment: { ProcessInfo.processInfo.environment })
            })
            let opened = try await server.session(botID: scenario.botID, mode: .background)
            _ = try await opened.driver.open(scenario.server.url("/index.html"))
            #expect(!RealBrowserScenario.processes(under: scenario.profiles.path).isEmpty, "the browser is running before the quit")
            #expect(app.existingSession(botID: scenario.botID) == nil, "the app's hub knows nothing of it")

            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    app.terminateAllNow()
                    continuation.resume()
                }
            }
        } catch {
            await scenario.finish()
            throw error
        }
        let left = await scenario.finish()
        #expect(left.isEmpty, "no browser process left: \(left)")
    }

    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3)))
    func browseCloseInALaterTurnClosesTheBrowserAnEarlierTurnOpened() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let base = try #require(try await scenario.session().driver as? AgentBrowserDriver).config
            await scenario.hub.close(botID: scenario.botID)
            func turnHub() -> BrowserHub {
                BrowserHub(profilesDirectory: scenario.profiles, locate: { RealBrowsers.status() }, makeDriver: { config in
                    var config = config
                    config.socketDirectory = base.socketDirectory
                    return AgentBrowserDriver(config: config, environment: { ProcessInfo.processInfo.environment })
                })
            }
            // Turn 1 opens the page.
            var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: scenario.botID)
            context.browser = BrowserAccess(hub: turnHub(), available: true, mode: .background)
            _ = try await BrowseOpenTool().run(.object(["url": .string(scenario.server.url("/index.html"))]), context: context)
            // Turn 2 has a hub with nothing in it.
            context.browser = BrowserAccess(hub: turnHub(), available: true, mode: .background)
            #expect(try await BrowseCloseTool().run(.object([:]), context: context) == "Browser closed.")
            // (The background process takes a moment to go; once it has, there is nothing to close.)
            let session = AgentBrowserConfig.sessionName(botID: scenario.botID)
            #expect(await Self.waitUntilGone(session, with: Self.driver(for: base)))
            #expect(try await BrowseCloseTool().run(.object([:]), context: context) == "The browser was not open.")
        } catch {
            await scenario.finish()
            throw error
        }
        let left = await scenario.finish()
        #expect(left.isEmpty, "\(left)")
    }
}
