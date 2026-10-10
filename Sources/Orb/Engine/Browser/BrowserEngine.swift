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

/// Whether an engine can run on this Mac, and when it cannot, what is missing and the exact command to fix it. The app never
/// installs anything itself: it only tells (the settings screen of a later phase offers the commands as buttons).
struct BrowserEngineStatus: Sendable, Equatable {
    var engine: BrowserEngineKind
    /// The `agent-browser` executable, nil when it is not installed.
    var agentBrowser: String?
    /// What the engine launches, when it is not Chrome: the `obscura` binary or CloakBrowser's Chromium.
    var browserExecutable: String?
    /// What is missing, each with the command that installs it, in the order to run them.
    var missing: [Missing] = []

    struct Missing: Sendable, Equatable {
        /// "agent-browser", "Chrome", "Obscura", "CloakBrowser".
        var name: String
        var command: String
    }

    var isReady: Bool { engine == .simple || missing.isEmpty }

    /// The commands to run in the Terminal, in order.
    var installCommands: [String] { missing.map(\.command) }

    /// For the person: what is missing and how to install it (Portuguese).
    var userMessage: String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).joined(separator: " e ")
        return "Falta instalar \(names) para o navegador \(engine.label). No Terminal: " + installCommands.joined(separator: " ; ")
    }

    /// For the model's prompt: one short line (English), so it can tell the user once.
    var modelNote: String? { modelNote(fetchTools: "web_fetch and web_search") }

    /// `fetchTools`: what the engine calls the tools that remain (Claude Code's are WebFetch and the Orb's web_search).
    func modelNote(fetchTools: String) -> String? {
        guard !missing.isEmpty else { return nil }
        return "The \(engine.label) browser is not installed on this Mac (missing: \(missing.map(\.name).joined(separator: ", "))), so you have "
            + "only \(fetchTools), which run no JavaScript and keep no logins. If the task needs a real browser, tell the user "
            + "once to run in the Terminal: " + installCommands.joined(separator: " ; ")
    }
}

/// Finds `agent-browser` and the engines on this Mac. Everything it reads is injected, so tests need no browser.
struct BrowserEngineLocator: Sendable {
    /// Directories searched for commands, in order: the user's own PATH (their login shell's, see `ShellEnvironment`) first,
    /// then where Homebrew, npm, cargo and pip put things when the PATH does not say.
    var searchPath: [String]
    var home: URL
    /// `CLOAKBROWSER_BINARY_PATH` and `CLOAKBROWSER_CACHE_DIR` live here.
    var environment: [String: String] = [:]
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var directoryContents: @Sendable (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    static let installAgentBrowser = "brew install agent-browser"
    static let installChrome = "agent-browser install"
    static let installObscura = "brew install obscura"
    static let installCloak = "pip3 install cloakbrowser && python3 -m cloakbrowser install"

    /// The places a command usually is on a Mac, for when the PATH of the app does not include them.
    static func fallbackDirectories(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path, home.appending(path: ".cargo/bin").path,
         home.appending(path: ".npm-global/bin").path, home.appending(path: ".volta/bin").path, "/usr/bin"]
    }

    /// With the PATH of the user's login shell (`ShellEnvironment`).
    static func live(path: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> BrowserEngineLocator {
        let given = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        var seen: Set<String> = []
        let directories = (given + fallbackDirectories(home: home)).filter { seen.insert($0).inserted }
        return BrowserEngineLocator(searchPath: directories, home: home, environment: environment)
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

    /// Whether `agent-browser` will find a Chrome: the one `agent-browser install` downloads (`~/.agent-browser/browsers/chrome-*`),
    /// or Chrome, Chromium or Brave in Applications (its own search, see `find_chrome` in agent-browser).
    func chromeAvailable() -> Bool {
        let cache = home.appending(path: ".agent-browser/browsers").path
        for entry in directoryContents(cache) where entry.hasPrefix("chrome-") {
            let folder = (cache as NSString).appendingPathComponent(entry)
            let app = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
            for relative in [app, "chrome-mac-arm64/" + app, "chrome-mac-x64/" + app]
            where exists((folder as NSString).appendingPathComponent(relative)) {
                return true
            }
        }
        return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
                "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"].contains { exists($0) }
    }

    /// CloakBrowser's Chromium: `CLOAKBROWSER_BINARY_PATH`, else the newest `chromium-<version>[-pro]` in its cache
    /// (`CLOAKBROWSER_CACHE_DIR`, default `~/.cloakbrowser`), as its Python wrapper lays it out on macOS.
    func cloakChromium() -> String? {
        if let own = environment["CLOAKBROWSER_BINARY_PATH"], !own.isEmpty { return isExecutable(own) ? own : nil }
        let cache = environment["CLOAKBROWSER_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home.appending(path: ".cloakbrowser").path
        let versions = directoryContents(cache).filter { $0.hasPrefix("chromium-") }.sorted { Self.version($1).lexicographicallyPrecedes(Self.version($0)) }
        for folder in versions {
            let path = (cache as NSString).appendingPathComponent(folder + "/Chromium.app/Contents/MacOS/Chromium")
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// "chromium-145.0.7632.109.2-pro" -> [145, 0, 7632, 109, 2], to compare versions numerically.
    private static func version(_ folder: String) -> [Int] {
        folder.dropFirst("chromium-".count).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// What `engine` needs and has. `simple` needs nothing.
    func status(for engine: BrowserEngineKind) -> BrowserEngineStatus {
        var status = BrowserEngineStatus(engine: engine)
        guard engine.drivesABrowser else { return status }
        status.agentBrowser = agentBrowser()
        if status.agentBrowser == nil {
            status.missing.append(.init(name: "agent-browser", command: Self.installAgentBrowser))
        }
        switch engine {
        case .simple:
            break
        case .chrome:
            // Without agent-browser the Chrome is not looked for: installing it is the next command anyway.
            if status.agentBrowser == nil || !chromeAvailable() {
                status.missing.append(.init(name: "Chrome", command: Self.installChrome))
            }
        case .obscura:
            status.browserExecutable = obscura()
            if status.browserExecutable == nil { status.missing.append(.init(name: "Obscura", command: Self.installObscura)) }
        case .cloak:
            status.browserExecutable = cloakChromium()
            if status.browserExecutable == nil { status.missing.append(.init(name: "CloakBrowser", command: Self.installCloak)) }
        }
        return status
    }
}
