import Foundation

/// Which browser an Orb uses for web work under "Navegar na web". `simple` is `web_fetch` alone (no JavaScript, nothing to
/// install); the other three are driven by the `agent-browser` command line (https://github.com/vercel-labs/agent-browser).
enum BrowserEngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case simple, chrome, obscura, cloak

    var id: String { rawValue }

    /// A value from a newer version falls back to the default engine.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .chrome) }

    /// What new Orbs, and the Orbs that had "Navegar na web" before the engines existed, use.
    static let `default` = BrowserEngineKind.chrome

    var label: String {
        switch self {
        case .simple: "Leitura simples"
        case .chrome: "Chrome"
        case .obscura: "Obscura"
        case .cloak: "CloakBrowser"
        }
    }

    /// One line for the picker.
    var summary: String {
        switch self {
        case .simple: "Só lê páginas (web_fetch), sem JavaScript, sem logins. Não precisa instalar nada."
        case .chrome: "Chrome de verdade, em segundo plano: páginas com JavaScript, logins que ficam guardados, cliques e formulários."
        case .obscura: "Motor leve em Rust com JavaScript. Mais rápido, mas sem perfil guardado (logins) e sem janela."
        case .cloak: "Chromium modificado para parecer um navegador comum em sites que barram automação."
        }
    }

    /// Whether the Orb gets the `browse_*` tools (every engine but `simple`).
    var drivesABrowser: Bool { self != .simple }
    /// Whether logins can stay between runs (a profile folder). Obscura has no persistent profile.
    var keepsProfile: Bool { self == .chrome || self == .cloak }
    /// Whether the same session can be shown in a window for the person to finish a login. Obscura is headless only.
    var canShowWindow: Bool { self == .chrome || self == .cloak }
}

/// Where the web search of an Orb goes.
enum SearchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case duckduckgo, google, tinyfish

    var id: String { rawValue }

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .duckduckgo) }

    var label: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        case .tinyfish: "TinyFish"
        }
    }
}

// MARK: - What is installed

/// Whether an engine can run on this Mac, and when it cannot, what is missing. The settings screen installs it (`BrowserInstaller`),
/// and the Orb's prompt tells the model to ask the person to do it there.
struct BrowserEngineStatus: Sendable, Equatable {
    var engine: BrowserEngineKind
    /// The `agent-browser` executable, nil when it is not installed.
    var agentBrowser: String?
    /// What the engine launches: the `obscura` binary, CloakBrowser's Chromium, or the Chrome for Testing the app installed
    /// (nil for Chrome when agent-browser is to find one by itself: the one in Applications, say).
    var browserExecutable: String?
    /// What is missing, in the order to install it.
    var missing: [Missing] = []

    struct Missing: Sendable, Equatable {
        /// "agent-browser", "Chrome", "Obscura", "CloakBrowser".
        var name: String
    }

    var isReady: Bool { engine == .simple || missing.isEmpty }

    /// For the person: what is missing and where to install it (Portuguese).
    var userMessage: String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).joined(separator: " e ")
        return "Falta instalar \(names) para o navegador \(engine.label). Abra Ajustes → Navegador e toque em Instalar."
    }

    /// For the model's prompt: one short line (English), so it can tell the user once.
    var modelNote: String? { modelNote(fetchTools: "web_fetch and web_search") }

    /// `fetchTools`: what the engine calls the tools that remain (Claude Code's are WebFetch and the Orb's web_search).
    func modelNote(fetchTools: String) -> String? {
        guard !missing.isEmpty else { return nil }
        return "The \(engine.label) browser is not installed on this Mac (missing: \(missing.map(\.name).joined(separator: ", "))), so you have "
            + "only \(fetchTools), which run no JavaScript and keep no logins. If the task needs a real browser, tell the user "
            + "once to open Ajustes → Navegador and install it (one button, nothing else to set up)."
    }
}

/// Finds `agent-browser` and the engines on this Mac. Everything it reads is injected, so tests need no browser.
struct BrowserEngineLocator: Sendable {
    /// Directories searched for commands, in order: the app's own `navegador/bin` (what the app installed), then the user's
    /// own PATH (their login shell's, see `ShellEnvironment`), then where Homebrew, npm, cargo and pip put things when the
    /// PATH does not say.
    var searchPath: [String]
    var home: URL
    /// `CLOAKBROWSER_BINARY_PATH` and `CLOAKBROWSER_CACHE_DIR` live here.
    var environment: [String: String] = [:]
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var directoryContents: @Sendable (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// The folder the app installs into (`BrowserInstallLayout.root`); what is there is preferred to anything else.
    var managedRoot: URL?

    /// The places a command usually is on a Mac, for when the PATH of the app does not include them.
    static func fallbackDirectories(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path, home.appending(path: ".cargo/bin").path,
         home.appending(path: ".npm-global/bin").path, home.appending(path: ".volta/bin").path, "/usr/bin"]
    }

    /// With the PATH of the user's login shell (`ShellEnvironment`). What the app installed (`managedRoot`) is searched first.
    static func live(path: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     managedRoot: URL? = nil) -> BrowserEngineLocator {
        let given = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let own = managedRoot.map { [BrowserInstallLayout(root: $0).binDirectory.path] } ?? []
        var seen: Set<String> = []
        let directories = (own + given + fallbackDirectories(home: home)).filter { seen.insert($0).inserted }
        return BrowserEngineLocator(searchPath: directories, home: home, environment: environment, managedRoot: managedRoot)
    }

    func command(_ name: String) -> String? {
        for directory in searchPath {
            let path = (directory as NSString).appendingPathComponent(name)
            if isExecutable(path) { return path }
        }
        return nil
    }

    func agentBrowser() -> String? { command("agent-browser") }

    func obscura() -> String? { command("obscura") }

    /// "Google Chrome for Testing" in a `chrome-<version>` folder, where `agent-browser install` puts it (the app is at the top of
    /// the folder, or in a `chrome-mac-*` folder in it). The newest version wins.
    func chromeForTesting(in cache: String) -> String? {
        let app = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let folders = directoryContents(cache).filter { $0.hasPrefix("chrome-") }.sorted { BrowserVersion.isNewer($0, than: $1) }
        for entry in folders {
            let folder = (cache as NSString).appendingPathComponent(entry)
            for relative in [app, "chrome-mac-arm64/" + app, "chrome-mac-x64/" + app] {
                let path = (folder as NSString).appendingPathComponent(relative)
                if exists(path) { return path }
            }
        }
        return nil
    }

    /// The Chrome for Testing in a `chrome-<version>` folder as the installer left it.
    static func chromeExecutable(inFolder folder: URL) -> URL? {
        let app = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        for relative in [app, "chrome-mac-arm64/" + app, "chrome-mac-x64/" + app] {
            let path = folder.appending(path: relative)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        return nil
    }

    /// The Chrome the app installed itself (`<root>/chrome/chrome-<version>`): what the Chrome engine launches.
    func installedChrome() -> String? {
        guard let managedRoot else { return nil }
        return chromeForTesting(in: BrowserInstallLayout(root: managedRoot).chromeDirectory.path)
    }

    /// Whether `agent-browser` will find a Chrome: the one the app installed, the one `agent-browser install` downloads
    /// (`~/.agent-browser/browsers/chrome-*`), or Chrome, Chromium or Brave in Applications (its own search).
    func chromeAvailable() -> Bool {
        if installedChrome() != nil { return true }
        if chromeForTesting(in: home.appending(path: ".agent-browser/browsers").path) != nil { return true }
        return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
                "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"].contains { exists($0) }
    }

    /// CloakBrowser's Chromium: `CLOAKBROWSER_BINARY_PATH`, else the newest `chromium-<version>[-pro]` in the app's own cache, in
    /// `CLOAKBROWSER_CACHE_DIR`, or in `~/.cloakbrowser`, as its Python wrapper lays it out on macOS.
    func cloakChromium() -> String? {
        if let own = environment["CLOAKBROWSER_BINARY_PATH"], !own.isEmpty { return isExecutable(own) ? own : nil }
        var caches: [String] = []
        if let managedRoot { caches.append(BrowserInstallLayout(root: managedRoot).cloakCache.path) }
        caches.append(environment["CLOAKBROWSER_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home.appending(path: ".cloakbrowser").path)
        for cache in caches {
            let versions = directoryContents(cache).filter { $0.hasPrefix("chromium-") }.sorted { BrowserVersion.isNewer($0, than: $1) }
            for folder in versions {
                let path = (cache as NSString).appendingPathComponent(folder + "/Chromium.app/Contents/MacOS/Chromium")
                if isExecutable(path) { return path }
            }
        }
        return nil
    }

    /// What `engine` needs and has. `simple` needs nothing.
    func status(for engine: BrowserEngineKind) -> BrowserEngineStatus {
        var status = BrowserEngineStatus(engine: engine)
        guard engine.drivesABrowser else { return status }
        status.agentBrowser = agentBrowser()
        if status.agentBrowser == nil { status.missing.append(.init(name: BrowserComponent.agentBrowser.name)) }
        switch engine {
        case .simple:
            break
        case .chrome:
            // The Chrome the app installed is launched by its path; without one agent-browser looks for Chrome itself.
            status.browserExecutable = installedChrome()
            if status.browserExecutable == nil, !chromeAvailable() { status.missing.append(.init(name: BrowserComponent.chrome.name)) }
        case .obscura:
            status.browserExecutable = obscura()
            if status.browserExecutable == nil { status.missing.append(.init(name: BrowserComponent.obscura.name)) }
        case .cloak:
            status.browserExecutable = cloakChromium()
            if status.browserExecutable == nil { status.missing.append(.init(name: BrowserComponent.cloak.name)) }
        }
        return status
    }
}
