import Foundation
import Testing
@testable import Orb

// Smoke tests of the real browser (see RealBrowserTests.swift for how they are enabled and what they measured).

/// What the browser is put through, on a page of ours served from `127.0.0.1` and on `example.com`.
struct RealBrowserScenario {
    let hub: BrowserHub
    let botID = UUID()
    let profiles: URL
    let server: LocalPageServer

    /// Takes the turn of the real-browser tests; `finish()` gives it back.
    static func make() async throws -> RealBrowserScenario {
        await RealBrowsers.gate.lock()
        do { return try await build() } catch {
            await RealBrowsers.gate.unlock()
            throw error
        }
    }

    private static func build() async throws -> RealBrowserScenario {
        let profiles = FileManager.default.temporaryDirectory.appending(path: "OrbRealBrowser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        // The background processes keep their files in a folder of this test, not in the user's `~/.agent-browser`.
        let sockets = "/tmp/orbab-\(UUID().uuidString.prefix(8))"
        let hub = BrowserHub(profilesDirectory: profiles, locate: { RealBrowsers.status() }, makeDriver: { config in
            var config = config
            config.socketDirectory = URL(fileURLWithPath: sockets)
            return AgentBrowserDriver(config: config, environment: { ProcessInfo.processInfo.environment })
        })
        return RealBrowserScenario(hub: hub, profiles: profiles, server: try await LocalPageServer(pages: LocalPageServer.testSite))
    }

    /// Closes everything, waits for the browser processes to be gone (a second or two) and gives the turn back. Returns what was
    /// still running after that.
    @discardableResult
    func finish() async -> [String] {
        await hub.close(botID: botID)
        server.stop()
        try? FileManager.default.removeItem(at: profiles)
        var left = Self.processes(under: profiles.path)
        for _ in 0..<150 where !left.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            left = Self.processes(under: profiles.path)
        }
        await RealBrowsers.gate.unlock()
        return left
    }

    func session() async throws -> BrowserSession { try await hub.session(botID: botID, mode: .background) }

    /// Seconds a step took, printed for the table at the top of RealBrowserTests.swift.
    func timed<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let result = try await work()
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("\(label): \(String(format: "%.2f", seconds)) s")
        return result
    }

    static func ref(_ snapshot: BrowserSnapshot, _ role: String, _ name: String) -> String? {
        snapshot.refs.first { $0.value.role == role && $0.value.name == name }?.key
    }

    /// Waits for the address of the page to end like `suffix` (a click that navigates answers before the page loads).
    static func waitForAddress(_ driver: any BrowserDriver, endingWith suffix: String) async throws -> String {
        var last = ""
        for _ in 0..<50 {
            last = (try? await driver.currentURL()) ?? ""
            if last.hasSuffix(suffix) { return last }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    /// The processes running from files under `folder` (a browser left behind).
    static func processes(under folder: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", folder]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // Read first: the end of the output is pgrep exiting. Waiting first could spin in `waitUntilExit` (it once held a full
        // run of the suite for a quarter of an hour).
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { String($0.prefix(200)) }
    }
}

@Suite(.serialized)
struct RealBrowserSmokeTests {
    // The pages of ours: forms, clicks, tabs.
    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3))) func browsesALocalPage() async throws { try await Self.localPage() }

    // A real public page.
    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3))) func opensExampleCom() async throws { try await Self.publicPage() }

    // The window (browse_show). It takes the focus of the Mac: run it only when nobody is using it.
    @Test(.enabled(if: RealBrowsers.isReady), .timeLimit(.minutes(3))) func showsAWindowAndGoesBack() async throws { try await Self.window() }

    static func localPage() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let driver = try await scenario.session().driver
            let page = try await scenario.timed("cold start + open of the local page") { try await driver.open(scenario.server.url("/index.html")) }
            #expect(page.title == "Página de teste do Orb")

            var snapshot = try await scenario.timed("snapshot") { try await driver.snapshot(interactive: true, selector: nil) }
            let box = try #require(RealBrowserScenario.ref(snapshot, "textbox", "Nome"))
            let submit = try #require(RealBrowserScenario.ref(snapshot, "button", "Enviar"))
            let button = try #require(RealBrowserScenario.ref(snapshot, "button", "Clique aqui"))
            let link = try #require(RealBrowserScenario.ref(snapshot, "link", "Ir para a segunda página"))
            let combo = try #require(snapshot.refs.first { $0.value.role == "combobox" }?.key)
            #expect(try await driver.attribute("type", of: box) == "text")

            try await driver.fill(box, text: "Ana")
            try await driver.click(submit)
            #expect(try await driver.evaluate("document.getElementById('msg').textContent") == "Enviado: Ana")

            // Text that the command line would take for options, quotes, accents.
            for text in ["--json", "--headed", "-x --session foo", "it's \"quoted\" \\ back", "ação ✓ 日本", "--"] {
                try await driver.fill(box, text: text)
                #expect(try await driver.evaluate("document.getElementById('nome').value") == text, "typed \(text)")
            }
            try await driver.click(button)
            #expect(try await driver.evaluate("document.getElementById('msg').textContent") == "Botão clicado")
            try await driver.select(combo, value: "Azul")
            #expect(try await driver.evaluate("document.getElementById('cor').value") == "a")

            let readout = try await scenario.timed("read") { try await driver.read() }
            #expect(readout.content.contains("Olá, navegador"))
            try await driver.press("Tab")
            try await driver.scroll(.down, pixels: 200)

            let shot = scenario.profiles.appending(path: "tela.png")
            try await scenario.timed("screenshot") { try await driver.screenshot(to: shot) }
            let bytes = try Data(contentsOf: shot)
            #expect(bytes.count > 1_000 && bytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "a PNG of some size")

            // A link.
            try await driver.click(link)
            let second = try await RealBrowserScenario.waitForAddress(driver, endingWith: "/segunda.html")
            #expect(second.hasSuffix("/segunda.html"))
            let back = try await scenario.timed("back") { try await driver.back() }
            #expect(back.url.hasSuffix("/index.html"), "back to \(back.url)")

            // Tabs.
            try await driver.newTab(scenario.server.url("/segunda.html"))
            var tabs = try await driver.tabs()
            #expect(tabs.count == 2 && tabs.filter(\.isActive).count == 1 && tabs.first { $0.isActive }?.url.hasSuffix("/segunda.html") == true, "\(tabs)")
            let first = try #require(tabs.first { !$0.isActive })
            try await driver.selectTab(first.id)
            tabs = try await driver.tabs()
            #expect(tabs.first { $0.isActive }?.id == first.id)
            let other = try #require(tabs.first { !$0.isActive })
            try await driver.closeTab(other.id)
            #expect(try await driver.tabs().count == 1)

            snapshot = try await driver.snapshot(interactive: false, selector: nil)
            #expect(snapshot.tree.contains("Olá, navegador"))
            try await driver.close()
            #expect(try await driver.currentURL() == nil, "closed: nothing is open, and nothing is started to answer")
        } catch {
            await scenario.finish()
            throw error
        }
        let left = await scenario.finish()
        #expect(left.isEmpty, "no browser left behind: \(left)")
    }

    static func publicPage() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let driver = try await scenario.session().driver
            let page = try await scenario.timed("cold start + open example.com") { try await driver.open("https://example.com") }
            #expect(page.title == "Example Domain", "\(page)")
            let snapshot = try await driver.snapshot(interactive: true, selector: nil)
            let link = try #require(snapshot.refs.first { $0.value.role == "link" }?.key, "\(snapshot)")
            #expect(snapshot.tree.contains("iana.org"))
            let readout = try await driver.read()
            #expect(readout.content.contains("documentation examples"))
            try await driver.click(link)
            let address = try await RealBrowserScenario.waitForAddress(driver, endingWith: "example-domains")
            #expect(address.contains("iana.org"), "\(address)")
            _ = try await scenario.timed("second open") { try await driver.open("https://example.com") }
            try await driver.close()
        } catch {
            await scenario.finish()
            throw error
        }
        await scenario.finish()
    }

    static func window() async throws {
        let scenario = try await RealBrowserScenario.make()
        do {
            let driver = try await scenario.session().driver
            _ = try await driver.open(scenario.server.url("/index.html"))
            let shown = try await scenario.timed("headed launch (browse_show)") { try await driver.setHeaded(true) }
            #expect(shown.url.hasSuffix("/index.html"), "\(shown)")
            #expect(try await driver.evaluate("document.title") == "Página de teste do Orb")
            let hidden = try await scenario.timed("back to headless") { try await driver.setHeaded(false) }
            #expect(hidden.url.hasSuffix("/index.html"), "\(hidden)")
            try await driver.close()
        } catch {
            await scenario.finish()
            throw error
        }
        await scenario.finish()
    }
}
