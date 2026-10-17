import Foundation

/// How the Orb's browser runs. Both modes are the same Chromium, driven by the `agent-browser` command line
/// (https://github.com/vercel-labs/agent-browser) with the Orb's own profile folder, so logins stay across modes.
enum BrowserMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Headless: no window, no Dock icon, never takes the focus of the Mac. What every Orb uses unless told otherwise.
    case background
    /// A window the person can see (and take the focus: a window opening is the Mac's own behavior). `browse_show` uses it for a
    /// moment; an Orb can also be set to it for good.
    case visible

    var id: String { rawValue }

    /// A value from a newer version falls back to the background.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .background) }

    /// What new Orbs, and the ones saved before the modes existed, use.
    static let `default` = BrowserMode.background

    var label: String {
        switch self {
        case .background: "Segundo plano"
        case .visible: "Visível"
        }
    }

    /// One line for the picker.
    var summary: String {
        switch self {
        case .background: "Sem janela e sem tirar o foco do que você está fazendo. Quando algo precisa de você (login, código), o Orb abre a janela."
        case .visible: "Abre uma janela do navegador para você acompanhar o Orb. A janela pode aparecer na frente do que você está fazendo."
        }
    }
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

/// A Chromium browser on this Mac that the Orb's browser launches.
struct BrowserProgram: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case chrome, brave, chromium, canary
        /// The Chrome for Testing the app installed itself (or `agent-browser install` did): the fallback, for a Mac with no browser.
        case testing
    }

    var kind: Kind
    var executable: String
    /// The Chromium major version ("155"), what the user agent of the launch says; nil when it could not be read.
    var major: Int?

    var name: String {
        switch kind {
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .chromium: "Chromium"
        case .canary: "Chrome Canary"
        case .testing: "Chrome for Testing"
        }
    }

    /// "Google Chrome 155", for the settings line.
    var label: String { major.map { "\(name) \($0)" } ?? name }
}

/// Whether the Orb's browser can run on this Mac, and when it cannot, what is missing. The settings screen installs it
/// (`BrowserInstaller`), and the Orb's prompt tells the model to ask the person to do it there.
struct BrowserStatus: Sendable, Equatable {
    /// The `agent-browser` executable, nil when it is not installed.
    var agentBrowser: String?
    /// The browser it launches, nil when the Mac has none.
    var program: BrowserProgram?
    /// What is missing, in the order to install it.
    var missing: [Missing] = []

    struct Missing: Sendable, Equatable {
        /// "agent-browser" or "Chrome".
        var name: String
    }

    var isReady: Bool { missing.isEmpty }

    /// For the person: what is missing and where to install it (Portuguese).
    var userMessage: String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).joined(separator: " e ")
        return "Falta instalar \(names) para o navegador do Orb. Abra Ajustes → Navegador e toque em Instalar."
    }

    /// For the model's prompt: one short line (English), so it can tell the user once.
    var modelNote: String? {
        guard !missing.isEmpty else { return nil }
        return "The Orb's browser is not installed on this Mac (missing: \(missing.map(\.name).joined(separator: ", "))), so you have "
            + "only web_fetch and web_search, which run no JavaScript and keep no logins. If the task needs a real browser, tell the user "
            + "once to open Ajustes → Navegador and install it (one button, nothing else to set up)."
    }
}

/// Finds `agent-browser` and the browser on this Mac. Everything it reads is injected, so tests need no browser.
struct BrowserLocator: Sendable {
    /// Directories searched for commands, in order: the app's own `navegador/bin` (what the app installed), then the user's
    /// own PATH (their login shell's, see `ShellEnvironment`), then where Homebrew, npm, cargo and pip put things when the
    /// PATH does not say.
    var searchPath: [String]
    var home: URL
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var directoryContents: @Sendable (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// The version a browser says (`CFBundleShortVersionString` of its app), by the path of its executable.
    var bundleVersion: @Sendable (String) -> String? = BrowserLocator.readBundleVersion
    /// The folder the app installs into (`BrowserInstallLayout.root`); what is there is preferred to anything else.
    var managedRoot: URL?

    /// The places a command usually is on a Mac, for when the PATH of the app does not include them.
    static func fallbackDirectories(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path, home.appending(path: ".cargo/bin").path,
         home.appending(path: ".npm-global/bin").path, home.appending(path: ".volta/bin").path, "/usr/bin"]
    }

    /// With the PATH of the user's login shell (`ShellEnvironment`). What the app installed (`managedRoot`) is searched first.
    static func live(path: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     managedRoot: URL? = nil) -> BrowserLocator {
        let given = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let own = managedRoot.map { [BrowserInstallLayout(root: $0).binDirectory.path] } ?? []
        var seen: Set<String> = []
        let directories = (own + given + fallbackDirectories(home: home)).filter { seen.insert($0).inserted }
        return BrowserLocator(searchPath: directories, home: home, managedRoot: managedRoot)
    }

    func command(_ name: String) -> String? {
        for directory in searchPath {
            let path = (directory as NSString).appendingPathComponent(name)
            if isExecutable(path) { return path }
        }
        return nil
    }

    func agentBrowser() -> String? { command("agent-browser") }

    /// The browsers the Orb may use, in the order it prefers them (`Google Chrome` first, `Brave` second): the executable inside
    /// the app, under `/Applications` or the user's own `Applications`.
    static let applications: [(kind: BrowserProgram.Kind, executable: String)] = [
        (.chrome, "Google Chrome.app/Contents/MacOS/Google Chrome"),
        (.brave, "Brave Browser.app/Contents/MacOS/Brave Browser"),
        (.chromium, "Chromium.app/Contents/MacOS/Chromium"),
        (.canary, "Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"),
    ]

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

    /// The Chrome for Testing the app installed itself (`<root>/chrome/chrome-<version>`).
    func installedChrome() -> String? {
        guard let managedRoot else { return nil }
        return chromeForTesting(in: BrowserInstallLayout(root: managedRoot).chromeDirectory.path)
    }

    /// The browser the Orb launches: Google Chrome, else Brave, Chromium or Chrome Canary (in Applications), and only when the Mac
    /// has none of them the Chrome for Testing: the one the app installed, or the one `agent-browser install` downloaded.
    func program() -> BrowserProgram? {
        for root in ["/Applications", home.appending(path: "Applications").path] {
            for (kind, relative) in Self.applications {
                let path = (root as NSString).appendingPathComponent(relative)
                if exists(path) { return make(kind, path) }
            }
        }
        if let path = installedChrome() { return make(.testing, path) }
        if let path = chromeForTesting(in: home.appending(path: ".agent-browser/browsers").path) { return make(.testing, path) }
        return nil
    }

    /// Whether the Mac has Chrome or Brave (or another in Applications), which makes the Chrome for Testing download unnecessary.
    func hasInstalledBrowser() -> Bool {
        guard let program = program() else { return false }
        return program.kind != .testing
    }

    private func make(_ kind: BrowserProgram.Kind, _ executable: String) -> BrowserProgram {
        let major = bundleVersion(executable).flatMap { BrowserVersion.numbers($0).first }
        return BrowserProgram(kind: kind, executable: executable, major: major)
    }

    /// `CFBundleShortVersionString` of the app that holds the executable (`X.app/Contents/MacOS/X`).
    static func readBundleVersion(executable: String) -> String? {
        let plist = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// What the Orb's browser needs and has.
    func status() -> BrowserStatus {
        var status = BrowserStatus()
        status.agentBrowser = agentBrowser()
        if status.agentBrowser == nil { status.missing.append(.init(name: BrowserComponent.agentBrowser.name)) }
        status.program = program()
        if status.program == nil { status.missing.append(.init(name: BrowserComponent.chrome.name)) }
        return status
    }
}
