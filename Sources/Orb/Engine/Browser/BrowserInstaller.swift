import Foundation

/// Runs a program (no shell) and returns what it printed; `onOutput` gets the text as it arrives, for progress lines.
typealias InstallCommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String],
                                            _ timeout: Duration, _ onOutput: @escaping @Sendable (String) -> Void) async throws -> ProcessOutput

/// Installs the browsers of the Orbs inside the app's own data folder (`BrowserInstallLayout`), with nothing but what a Mac
/// has: no Homebrew, no Node, no sudo. Everything is downloaded into a work folder, checked, tried, and only then moved into
/// place, so a failed or cancelled install leaves what was there untouched.
///
/// - `agent-browser`: the release binary of github.com/vercel-labs/agent-browser for this Mac's architecture, checked against the
///   SHA-256 GitHub publishes for the asset.
/// - Chrome: `agent-browser install` (Chrome for Testing), run with a `HOME` of its own so it lands in the app's folder.
/// - Obscura: the macOS `stealth` build of github.com/h4ckf0r0day/obscura, checked the same way.
/// - CloakBrowser: its Python package in a private virtual environment; the package downloads its own Chromium and checks the
///   signature of it (it needs no account for the free build).
final class BrowserInstaller: Sendable {
    let layout: BrowserInstallLayout
    let platform: BrowserPlatform
    private let network: any InstallNetwork
    private let run: InstallCommandRunner
    private let freeSpace: @Sendable (URL) -> Int64?
    private let findPython: @Sendable (InstallCommandRunner) async throws -> String
    /// Whether `agent-browser` would find a Chrome for the Chrome engine (the one the app installed, or one on the Mac).
    private let chromeAvailable: @Sendable (BrowserInstallLayout) -> Bool

    static let agentBrowserRepository = "vercel-labs/agent-browser"
    static let obscuraRepository = "h4ckf0r0day/obscura"
    static let chromeVersionsURL = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json")!

    init(layout: BrowserInstallLayout, platform: BrowserPlatform = .current, network: any InstallNetwork = URLSessionInstallNetwork(),
         run: @escaping InstallCommandRunner = BrowserInstaller.processRunner,
         freeSpace: @escaping @Sendable (URL) -> Int64? = BrowserInstaller.availableSpace,
         findPython: @escaping @Sendable (InstallCommandRunner) async throws -> String = { try await BrowserInstaller.locatePython(run: $0) },
         chromeAvailable: @escaping @Sendable (BrowserInstallLayout) -> Bool = { BrowserEngineLocator.live(path: nil, managedRoot: $0.root).chromeAvailable() }) {
        self.layout = layout
        self.platform = platform
        self.network = network
        self.run = run
        self.freeSpace = freeSpace
        self.findPython = findPython
        self.chromeAvailable = chromeAvailable
    }

    static let processRunner: InstallCommandRunner = { executable, arguments, environment, timeout, onOutput in
        try await ProcessRunner.run(executable, arguments, directory: FileManager.default.temporaryDirectory, environment: environment,
                                    timeout: timeout, outputLimit: 200_000) { data in onOutput(String(decoding: data, as: UTF8.self)) }
    }

    // MARK: What is installed

    func records() -> InstalledRecords {
        guard let data = try? Data(contentsOf: layout.recordsFile) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(InstalledRecords.self, from: data)) ?? [:]
    }

    private func save(_ records: InstalledRecords) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: layout.recordsFile, options: .atomic)
    }

    private func record(_ component: BrowserComponent, _ value: InstalledComponent?) throws {
        var all = records()
        all[component.rawValue] = value
        try save(all)
    }

    /// Whether the files of the component are there (the record alone is not trusted: the folder may have been emptied by hand).
    func isInstalled(_ component: BrowserComponent) -> Bool {
        let fileManager = FileManager.default
        switch component {
        case .agentBrowser: return fileManager.isExecutableFile(atPath: layout.agentBrowser.path)
        case .obscura: return fileManager.isExecutableFile(atPath: layout.obscura.path)
        case .chrome: return !Self.folders(in: layout.chromeDirectory, prefix: "chrome-").isEmpty
        case .cloak: return fileManager.isExecutableFile(atPath: layout.cloakPython.path) && Self.cloakChromium(in: layout.cloakCache) != nil
        }
    }

    /// Whether everything the engine needs from the app's folder is installed.
    func hasEverythingInstalled(for engine: BrowserEngineKind) -> Bool { engine.components.allSatisfy { isInstalled($0) } }

    // MARK: Installing

    /// Installs what `engine` is missing (or exactly `components`, to update), in order. Throws `CancellationError` when the
    /// task is cancelled; the work folder is gone either way.
    func install(_ engine: BrowserEngineKind, components: [BrowserComponent]? = nil,
                 progress: @escaping @Sendable (BrowserInstallProgress) -> Void = { _ in }) async throws {
        let wanted = components ?? engine.components.filter { !isInstalled($0) }
        removeStaleWorkFolders()
        for (index, component) in wanted.enumerated() {
            try Task.checkCancellation()
            let report: @Sendable (BrowserInstallProgress) -> Void = { update in
                var update = update
                update.step = index + 1
                update.steps = wanted.count
                progress(update)
            }
            report(BrowserInstallProgress(component: component, phase: .preparing))
            let installed: InstalledComponent
            switch component {
            case .agentBrowser: installed = try await installAgentBrowser(report)
            case .chrome: installed = try await installChrome(report)
            case .obscura: installed = try await installObscura(report)
            case .cloak: installed = try await installCloak(report)
            }
            try record(component, installed)
        }
        progress(BrowserInstallProgress(component: wanted.last ?? .agentBrowser, phase: .finishing, step: wanted.count, steps: wanted.count))
    }

    private func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                           "TMPDIR": NSTemporaryDirectory()]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    // MARK: agent-browser

    private func installAgentBrowser(_ report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> InstalledComponent {
        let component = BrowserComponent.agentBrowser
        report(.init(component: component, phase: .resolving))
        let release = try await latestRelease(Self.agentBrowserRepository)
        guard let asset = release.assets.first(where: { $0.name == platform.agentBrowserAsset }) else {
            throw BrowserInstallError.assetMissing(component.name)
        }
        try requireSpace(asset.size * 3, at: layout.root)
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "agent-browser")
        let hash = try await download(asset, to: file, component: component, version: release.version, report: report)
        let verified = try await verify(hash, of: asset, in: release, component: component, report: report)
        try Self.makeExecutable(file)
        Quarantine.clear(file)
        report(.init(component: component, phase: .checking, version: release.version))
        try await requireWorking(file.path, ["--version"], name: component.name, expecting: release.version)
        report(.init(component: component, phase: .installing, version: release.version))
        try replaceItem(at: layout.agentBrowser, with: file)
        return InstalledComponent(version: release.version, installedAt: .now, source: asset.url.absoluteString,
                                  sha256: verified ? hash : nil, verified: verified)
    }

    // MARK: Obscura

    private func installObscura(_ report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> InstalledComponent {
        let component = BrowserComponent.obscura
        report(.init(component: component, phase: .resolving))
        let release = try await latestRelease(Self.obscuraRepository)
        guard let asset = platform.obscuraAssets.lazy.compactMap({ name in release.assets.first { $0.name == name } }).first else {
            throw BrowserInstallError.assetMissing(component.name)
        }
        try requireSpace(asset.size * 4, at: layout.root)
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appending(path: "obscura.tar.gz")
        let hash = try await download(asset, to: archive, component: component, version: release.version, report: report)
        let verified = try await verify(hash, of: asset, in: release, component: component, report: report)

        report(.init(component: component, phase: .extracting, version: release.version))
        let unpacked = work.appending(path: "conteudo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await extract(archive, into: unpacked, expecting: ["obscura", "obscura-worker"])
        guard FileManager.default.fileExists(atPath: unpacked.appending(path: "obscura").path) else {
            throw BrowserInstallError.assetMissing(component.name)
        }
        for name in ["obscura", "obscura-worker"] {
            let file = unpacked.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try Self.makeExecutable(file)
            Quarantine.clear(file)
        }
        report(.init(component: component, phase: .checking, version: release.version))
        try await requireWorking(unpacked.appending(path: "obscura").path, ["--version"], name: component.name, expecting: release.version)
        report(.init(component: component, phase: .installing, version: release.version))
        // The worker first: `obscura` is what the locator looks for, so it only appears when its helper is already there.
        if FileManager.default.fileExists(atPath: unpacked.appending(path: "obscura-worker").path) {
            try replaceItem(at: layout.obscuraWorker, with: unpacked.appending(path: "obscura-worker"))
        }
        try replaceItem(at: layout.obscura, with: unpacked.appending(path: "obscura"))
        return InstalledComponent(version: release.version, installedAt: .now, source: asset.url.absoluteString,
                                  sha256: verified ? hash : nil, detail: asset.name.contains("stealth") ? "stealth" : nil, verified: verified)
    }

    /// Unpacks a `.tar.gz` after reading its list: only the files named in `expecting`, only regular files (a link in the package
    /// could point anywhere on the Mac, and the files are made executable and moved into the app's folder), none with a path that
    /// leaves the folder.
    private func extract(_ archive: URL, into folder: URL, expecting: Set<String>) async throws {
        let listing = try await run("/usr/bin/tar", ["-tzf", archive.path], environment(), .seconds(120), { _ in })
        guard listing.status == 0 else { throw Self.commandFailure("Obscura", listing) }
        for entry in listing.output.split(whereSeparator: \.isNewline).map(String.init) {
            let name = entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
            if name.isEmpty || name.hasSuffix("/") { continue }
            guard expecting.contains(name) else {
                throw BrowserInstallError.failed("Obscura", detail: "o pacote traz um arquivo inesperado (\(name.clipped(to: 60))), por segurança nada foi instalado.")
            }
        }
        // The same list with the kind of each entry (`-` file, `d` folder, `l` symbolic link, `h` hard link).
        let detailed = try await run("/usr/bin/tar", ["-tvzf", archive.path], environment(), .seconds(120), { _ in })
        guard detailed.status == 0 else { throw Self.commandFailure("Obscura", detailed) }
        if let entry = Self.unsafeEntry(inVerboseListing: detailed.output) {
            throw BrowserInstallError.failed("Obscura", detail: "o pacote traz um atalho ou link (\(entry.clipped(to: 60))), por segurança nada foi instalado.")
        }
        let result = try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path], environment(), .seconds(300), { _ in })
        guard result.status == 0 else { throw Self.commandFailure("Obscura", result) }
        // What came out is what was listed: regular files, not links.
        for name in expecting {
            guard let type = try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)[.type] as? FileAttributeType else { continue }
            guard type == .typeRegular else {
                throw BrowserInstallError.failed("Obscura", detail: "\(name) do pacote não é um arquivo comum, por segurança nada foi instalado.")
            }
        }
    }

    /// The first entry of a `tar -tv` listing that is not a regular file or a folder (a symbolic or hard link, a device…), nil when
    /// all are.
    static func unsafeEntry(inVerboseListing text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let kind = line.first else { continue }
            if kind != "-" && kind != "d" { return String(line) }
            if line.contains(" link to ") { return String(line) }
        }
        return nil
    }

    // MARK: Chrome

    private func installChrome(_ report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> InstalledComponent {
        let component = BrowserComponent.chrome
        guard FileManager.default.isExecutableFile(atPath: layout.agentBrowser.path) else { throw BrowserInstallError.needsAgentBrowser }
        try requireSpace(900_000_000, at: layout.root)
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        // `agent-browser install` puts Chrome in `~/.agent-browser/browsers`: with a HOME of its own that is the work folder.
        let home = work.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        report(.init(component: component, phase: .downloading))
        let tracker = ProgressTracker(component: component, report: report)
        let output = try await run(layout.agentBrowser.path, ["install"], environment(["HOME": home.path]), .seconds(1_500)) { text in
            tracker.consume(text)
        }
        guard output.status == 0 else { throw Self.commandFailure(component.name, output) }

        let browsers = home.appending(path: ".agent-browser/browsers", directoryHint: .isDirectory)
        guard let folder = Self.folders(in: browsers, prefix: "chrome-").last else {
            throw BrowserInstallError.failed(component.name, detail: "o agent-browser terminou sem baixar o Chrome.")
        }
        guard let executable = BrowserEngineLocator.chromeExecutable(inFolder: folder) else {
            throw BrowserInstallError.broken(component.name, detail: "o pacote não traz o aplicativo")
        }
        report(.init(component: component, phase: .checking))
        Quarantine.clear(folder)
        let version = String(folder.lastPathComponent.dropFirst("chrome-".count))
        try await requireWorking(executable.path, ["--version"], name: component.name, expecting: nil, timeout: .seconds(60))
        report(.init(component: component, phase: .installing, version: version))
        let previous = Self.folders(in: layout.chromeDirectory, prefix: "chrome-")
        try FileManager.default.createDirectory(at: layout.chromeDirectory, withIntermediateDirectories: true)
        let destination = layout.chromeDirectory.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
        try replaceItem(at: destination, with: folder)
        for old in previous where old != destination { try? FileManager.default.removeItem(at: old) }
        return InstalledComponent(version: version, installedAt: .now, source: "agent-browser install", detail: "Chrome for Testing")
    }

    // MARK: CloakBrowser

    private func installCloak(_ report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> InstalledComponent {
        let component = BrowserComponent.cloak
        try requireSpace(900_000_000, at: layout.root)
        report(.init(component: component, phase: .preparing))
        let python = try await findPython(run)
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let cloak = work.appending(path: "cloak", directoryHint: .isDirectory)
        let venv = cloak.appending(path: "venv", directoryHint: .isDirectory)
        let cache = cloak.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cloak, withIntermediateDirectories: true)
        let env = environment(["PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_NO_INPUT": "1", "PYTHONNOUSERSITE": "1",
                               "CLOAKBROWSER_CACHE_DIR": cache.path])

        report(.init(component: component, phase: .preparing))
        let made = try await run(python, ["-m", "venv", venv.path], env, .seconds(180), { _ in })
        guard made.status == 0 else { throw Self.commandFailure(component.name, made) }
        let venvPython = venv.appending(path: "bin/python").path

        // The package and what it lists (its automation library comes along: the package cannot even start without it, about 130 MB).
        report(.init(component: component, phase: .installing))
        // The version this app was tested with, not whatever is newest: the app drives the package's Chromium by its own flags.
        let pip = try await run(venvPython, ["-m", "pip", "install", "cloakbrowser==\(Self.cloakPackageVersion)"], env, .seconds(900), { _ in })
        guard pip.status == 0 else { throw Self.commandFailure(component.name, pip) }

        report(.init(component: component, phase: .downloading))
        let tracker = ProgressTracker(component: component, report: report)
        let download = try await run(venvPython, ["-m", "cloakbrowser", "install"], env, .seconds(1_800)) { tracker.consume($0) }
        guard download.status == 0 else {
            let lowered = download.output.lowercased()
            if lowered.contains("cloakbrowserlicenseerror") || lowered.contains("license key") || lowered.contains("pro binary") {
                throw BrowserInstallError.cloakNeedsKey
            }
            throw Self.commandFailure(component.name, download)
        }
        guard let chromium = Self.cloakChromium(in: cache) else {
            throw BrowserInstallError.failed(component.name, detail: "o pacote terminou sem baixar o Chromium.")
        }
        report(.init(component: component, phase: .checking))
        Quarantine.clear(chromium.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        try await requireWorking(chromium.path, ["--version"], name: component.name, expecting: nil, timeout: .seconds(60))
        let package = try? await run(venvPython, ["-c", "import cloakbrowser; print(cloakbrowser.__version__)"], env, .seconds(60), { _ in })
        let version = package.flatMap { BrowserVersion.find(in: $0.output) } ?? "desconhecida"
        let chromiumVersion = chromium.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "chromium-", with: "")

        report(.init(component: component, phase: .installing, version: version))
        let aside = try swapDirectory(layout.cloakDirectory, with: cloak)
        let installed = InstalledComponent(version: version, installedAt: .now, source: "pypi.org/project/cloakbrowser==\(Self.cloakPackageVersion)",
                                           detail: "Chromium \(chromiumVersion)")
        // The old install stays where it was put aside until the new one is checked in its place and written down: if either
        // fails (or the task is cancelled), the old one comes back, and the record still says what is really there.
        do {
            // The folder moved with its virtual environment inside: it must still start.
            let moved = try await run(layout.cloakPython.path, ["-c", "import cloakbrowser"], env, .seconds(60), { _ in })
            guard moved.status == 0 else {
                throw BrowserInstallError.broken(component.name, detail: "o Python da instalação não abriu depois de ser movido")
            }
            try Task.checkCancellation()
            try record(component, installed)
        } catch {
            try? FileManager.default.removeItem(at: layout.cloakDirectory)
            if let aside { try? FileManager.default.moveItem(at: aside, to: layout.cloakDirectory) }
            if aside != nil, let broken = error as? BrowserInstallError, case .broken(_, let detail) = broken {
                throw BrowserInstallError.updateRolledBack(component.name, detail: detail)
            }
            throw error
        }
        if let aside { try? FileManager.default.removeItem(at: aside) }
        return installed
    }

    /// The `cloakbrowser` package version the app installs (the one its CloakBrowser support was tested with).
    static let cloakPackageVersion = "0.6.0"

    /// `<cache>/chromium-<version>/Chromium.app/Contents/MacOS/Chromium`, the newest.
    static func cloakChromium(in cache: URL) -> URL? {
        let folders = folders(in: cache, prefix: "chromium-")
            .sorted { BrowserVersion.isNewer($0.lastPathComponent, than: $1.lastPathComponent) }
        for folder in folders {
            let path = folder.appending(path: "Chromium.app/Contents/MacOS/Chromium")
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        return nil
    }

    // MARK: Python

    /// A Python 3.9+ with `venv` and `ssl`. `/usr/bin/python3` is only a stub that opens a dialog to install the Command Line
    /// Tools until they are installed, so it is asked about only when `xcode-select -p` says they are.
    static func locatePython(run: InstallCommandRunner,
                             isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) async throws -> String {
        let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        let tools = try? await run("/usr/bin/xcode-select", ["-p"], environment, .seconds(15), { _ in })
        let hasTools = tools?.status == 0
        if hasTools { candidates.insert("/usr/bin/python3", at: 0) }
        for candidate in candidates where isExecutable(candidate) {
            let check = try? await run(candidate, ["-c", "import sys, venv, ssl; sys.exit(0 if sys.version_info >= (3, 9) else 1)"],
                                       environment, .seconds(30), { _ in })
            if check?.status == 0 { return candidate }
        }
        if !hasTools, isExecutable("/usr/bin/python3") { throw BrowserInstallError.needsCommandLineTools }
        throw BrowserInstallError.noPython
    }

    // MARK: Updates

    /// The newest release of every component (the ones installed first), looked up at most once a day unless `force`. A failed
    /// look returns what was known before, or throws when nothing was.
    @discardableResult
    func checkForUpdates(force: Bool = false, now: Date = .now) async throws -> BrowserUpdateCheck {
        let cached = Self.readUpdates(layout.updatesFile)
        if !force, let cached, !cached.isDue(now: now) { return cached }
        var latest: [String: String] = cached?.latest ?? [:]
        var failure: Error?
        var reached = false
        for component in BrowserComponent.allCases where isInstalled(component) {
            do {
                latest[component.rawValue] = try await latestVersion(of: component)
                reached = true
            } catch is CancellationError {
                throw CancellationError()
            } catch BrowserInstallError.rateLimited {
                // The limit counts calls: stop asking for the rest, and do not ask again before tomorrow.
                failure = BrowserInstallError.rateLimited
                break
            } catch {
                failure = error
            }
        }
        // A look that reached something counts as a look, even when part of it failed (what is known stays, and the next look is
        // tomorrow's: GitHub allows few calls an hour to a Mac without a login), and so does being told to wait. Only a look that
        // reached nothing (no network) is not written down: the next try is soon.
        let wasLimited = (failure as? BrowserInstallError) == .rateLimited
        if !reached, let failure {
            if wasLimited { Self.writeUpdates(BrowserUpdateCheck(checkedAt: now, latest: latest), to: layout.updatesFile) }
            if latest.isEmpty { throw failure }
            return BrowserUpdateCheck(checkedAt: wasLimited ? now : (cached?.checkedAt ?? now), latest: latest)
        }
        let result = BrowserUpdateCheck(checkedAt: now, latest: latest)
        Self.writeUpdates(result, to: layout.updatesFile)
        return result
    }

    static func readUpdates(_ file: URL) -> BrowserUpdateCheck? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BrowserUpdateCheck.self, from: data)
    }

    private static func writeUpdates(_ check: BrowserUpdateCheck, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(check).write(to: file, options: .atomic)
    }

    func latestVersion(of component: BrowserComponent) async throws -> String {
        switch component {
        case .agentBrowser: return try await latestRelease(Self.agentBrowserRepository).version
        case .obscura: return try await latestRelease(Self.obscuraRepository).version
        case .chrome:
            let json = JSONValue.parse(String(decoding: try await network.data(from: Self.chromeVersionsURL), as: UTF8.self))
            guard let version = json?["channels"]?["Stable"]?["version"]?.string else { throw BrowserInstallError.failed("Chrome", detail: "a lista de versões veio sem a estável.") }
            return version
        case .cloak:
            // The package is installed at the version the app was tested with (`cloakPackageVersion`), so the newest one an
            // install can bring is that: an update shows when a newer app brings a newer pin, not when the index has a new release.
            return Self.cloakPackageVersion
        }
    }

    /// The components whose installed version is older than the newest known.
    func updatable(_ check: BrowserUpdateCheck?, records: InstalledRecords? = nil) -> Set<BrowserComponent> {
        guard let check else { return [] }
        let records = records ?? self.records()
        return Set(BrowserComponent.allCases.filter { component in
            guard isInstalled(component), let installed = records[component.rawValue]?.version,
                  let latest = check.latest[component.rawValue] else { return false }
            return BrowserVersion.isNewer(latest, than: installed)
        })
    }

    // MARK: Removing

    /// Removes the files of the engine's browser (not the profiles, unless `removeProfiles`); `agent-browser` goes with the last
    /// engine that needed it. Anything still running from these files is the caller's to close first.
    func uninstall(_ engine: BrowserEngineKind, removeProfiles: Bool = false) throws {
        let fileManager = FileManager.default
        if let component = engine.browserComponent {
            switch component {
            case .agentBrowser: break
            case .chrome: try? fileManager.removeItem(at: layout.chromeDirectory)
            case .obscura:
                try? fileManager.removeItem(at: layout.obscura)
                try? fileManager.removeItem(at: layout.obscuraWorker)
            case .cloak: try? fileManager.removeItem(at: layout.cloakDirectory)
            }
            try record(component, nil)
        }
        if removeProfiles { removeProfileFolders(of: engine) }
        // Another engine still needs `agent-browser` when it can run: Obscura and CloakBrowser when their files are here, and Chrome
        // whenever a Chrome can be found (the one the app installed, or one on the Mac that `agent-browser` finds by itself, which
        // is the common setup: Chrome there, nothing of the app's own but `agent-browser`).
        let stillUsed = BrowserEngineKind.allCases.contains { other in
            guard other != engine, other.drivesABrowser else { return false }
            if other == .chrome { return chromeAvailable(layout) }
            return other.browserComponent.map(isInstalled) == true
        }
        if !stillUsed {
            try? fileManager.removeItem(at: layout.agentBrowser)
            try record(.agentBrowser, nil)
            try? fileManager.removeItem(at: layout.updatesFile)
            // The folder is only a place for the work and the binaries: empty, it goes.
            for folder in [layout.binDirectory] where (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    /// What the engine keeps for the Orbs (logins): `<root>/<orb id>/<engine>`.
    func removeProfileFolders(of engine: BrowserEngineKind) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: layout.root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            try? fileManager.removeItem(at: entry.appending(path: engine.rawValue))
            if (try? fileManager.contentsOfDirectory(atPath: entry.path))?.isEmpty == true { try? fileManager.removeItem(at: entry) }
        }
    }

    // MARK: Pieces

    struct Release: Sendable {
        var version: String
        var assets: [Asset]
    }

    struct Asset: Sendable {
        var name: String
        var url: URL
        var size: Int64
        var sha256: String?
    }

    func latestRelease(_ repository: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let data = try await network.data(from: url)
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), let tag = json["tag_name"]?.string else {
            throw BrowserInstallError.failed(repository, detail: "o GitHub respondeu algo que não é uma versão.")
        }
        let assets = (json["assets"]?.array ?? []).compactMap { entry -> Asset? in
            guard let name = entry["name"]?.string, let address = entry["browser_download_url"]?.string, let url = URL(string: address),
                  url.scheme == "https" else { return nil }
            return Asset(name: name, url: url, size: Int64(entry["size"]?.int ?? 0), sha256: Checksum.parseDigest(entry["digest"]?.string))
        }
        return Release(version: BrowserVersion.clean(tag), assets: assets)
    }

    private func download(_ asset: Asset, to file: URL, component: BrowserComponent, version: String,
                          report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> String {
        report(.init(component: component, phase: .downloading, total: asset.size > 0 ? asset.size : nil, version: version))
        do {
            return try await network.download(asset.url, to: file) { received, total in
                report(.init(component: component, phase: .downloading, received: received, total: total ?? (asset.size > 0 ? asset.size : nil), version: version))
            }
        } catch {
            if Self.isOutOfSpace(error) { throw BrowserInstallError.diskFull(needed: asset.size * 3) }
            throw error
        }
    }

    /// Compares the hash of the download with the one the release publishes: GitHub's own `digest` of the asset, else a checksums
    /// file next to it. A release that publishes neither is installed without the check, and the record says so (false): it is
    /// not written down as verified.
    @discardableResult
    private func verify(_ hash: String, of asset: Asset, in release: Release, component: BrowserComponent,
                        report: @escaping @Sendable (BrowserInstallProgress) -> Void) async throws -> Bool {
        report(.init(component: component, phase: .verifying, version: release.version))
        var expected = asset.sha256
        if expected == nil {
            for sums in release.assets where Self.isChecksumFile(sums.name, for: asset.name) {
                guard let data = try? await network.data(from: sums.url) else { continue }
                if let found = Self.checksum(of: asset.name, inListing: String(decoding: data, as: UTF8.self)) { expected = found; break }
            }
        }
        guard let expected else { return false }
        if expected.lowercased() != hash.lowercased() { throw BrowserInstallError.checksumMismatch(component.name) }
        return true
    }

    static func isChecksumFile(_ name: String, for asset: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == asset.lowercased() + ".sha256" || ["sha256sums", "sha256sums.txt", "checksums.txt", "checksums.sha256"].contains(lowered)
    }

    /// The hash of `name` in the text of a `sha256sum` listing ("<hex>  <file>" per line, or just the hash).
    static func checksum(of name: String, inListing text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let hash = parts.first, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            if parts.count == 1 || (parts.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) } == name) { return hash.lowercased() }
        }
        return nil
    }

    /// Runs the program to see that it starts and, when `expecting` is given, that it says the version it should.
    private func requireWorking(_ executable: String, _ arguments: [String], name: String, expecting version: String?,
                                timeout: Duration = .seconds(30)) async throws {
        let result: ProcessOutput
        do {
            result = try await run(executable, arguments, environment(), timeout, { _ in })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BrowserInstallError.broken(name, detail: error.localizedDescription)
        }
        guard result.status == 0, !result.timedOut else {
            throw BrowserInstallError.broken(name, detail: result.timedOut ? "não respondeu" : "saiu com o código \(result.status)")
        }
        if let version, !result.output.contains(version) {
            throw BrowserInstallError.broken(name, detail: "disse \"\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).clipped(to: 60))\" em vez da versão \(version)")
        }
    }

    // MARK: Files

    private func makeWorkFolder() throws -> URL {
        let folder = layout.workFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            if Self.isOutOfSpace(error) { throw BrowserInstallError.diskFull(needed: nil) }
            throw error
        }
        return folder
    }

    /// Work folders of an install that was killed (the app quit in the middle) are never reused.
    private func removeStaleWorkFolders() {
        let fileManager = FileManager.default
        for entry in (try? fileManager.contentsOfDirectory(at: layout.root, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix(BrowserInstallLayout.workPrefix) {
            // An install killed between setting the old CloakBrowser aside and putting the new one in place left the old one
            // here and nothing in its place: it is the installed one, not leftovers.
            if entry.lastPathComponent.hasPrefix(BrowserInstallLayout.workPrefix + Self.asideMarker),
               !fileManager.fileExists(atPath: layout.cloakDirectory.path),
               (try? fileManager.moveItem(at: entry, to: layout.cloakDirectory)) != nil {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func requireSpace(_ needed: Int64, at folder: URL) throws {
        guard let available = freeSpace(folder), available < needed else { return }
        throw BrowserInstallError.diskFull(needed: needed)
    }

    /// Puts `source` at `destination`, replacing what is there in one step.
    private func replaceItem(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            if Self.isOutOfSpace(error) { throw BrowserInstallError.diskFull(needed: nil) }
            throw error
        }
    }

    /// Replaces a folder by another: the old one is set aside first and comes back if the move fails. Returns where the old one
    /// is (nil when there was none); the caller deletes it once the new one is known to work, or moves it back if it is not.
    private func swapDirectory(_ destination: URL, with new: URL) throws -> URL? {
        let fileManager = FileManager.default
        let aside = destination.deletingLastPathComponent().appending(path: BrowserInstallLayout.workPrefix + Self.asideMarker + UUID().uuidString)
        let hadOld = fileManager.fileExists(atPath: destination.path)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if hadOld { try fileManager.moveItem(at: destination, to: aside) }
        do {
            try fileManager.moveItem(at: new, to: destination)
        } catch {
            if hadOld { try? fileManager.moveItem(at: aside, to: destination) }
            throw error
        }
        return hadOld ? aside : nil
    }

    /// What the name of a folder set aside by `swapDirectory` has after the work prefix.
    static let asideMarker = "antigo-"

    static func makeExecutable(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// `prefix*` folders of a folder, oldest version first.
    static func folders(in folder: URL, prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
            .sorted { BrowserVersion.isNewer($1, than: $0) }
            .map { folder.appending(path: $0, directoryHint: .isDirectory) }
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    static let availableSpace: @Sendable (URL) -> Int64? = { url in
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// What a program that failed says, as an error the person can read.
    static func commandFailure(_ name: String, _ output: ProcessOutput) -> BrowserInstallError {
        if output.timedOut { return .failed(name, detail: "demorou demais e foi interrompido.") }
        let text = output.output
        let lowered = text.lowercased()
        if lowered.contains("no space left on device") || lowered.contains("errno 28") { return .diskFull(needed: nil) }
        let offline = ["could not resolve", "name or service not known", "nodename nor servname", "network is unreachable", "temporary failure in name resolution",
                       "failed to establish a new connection", "connection refused", "connection reset", "connection timed out", "read timed out",
                       "dns error", "error sending request", "no address associated", "network connection was lost", "internet connection appears to be offline",
                       "max retries exceeded", "connecterror", "remotedisconnected", "urlerror", "ssl: certificate_verify_failed"]
        if offline.contains(where: lowered.contains) { return .noNetwork }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let detail = lines.suffix(2).joined(separator: " ").clipped(to: 280)
        return .failed(name, detail: detail.isEmpty ? "o programa terminou com o código \(output.status)." : detail)
    }
}

// MARK: - Helpers

/// Turns the lines a program prints while it downloads (`  9/184 MB (5%)`) into progress.
final class ProgressTracker: @unchecked Sendable {
    private let component: BrowserComponent
    private let report: @Sendable (BrowserInstallProgress) -> Void
    private let lock = NSLock()
    private var phase = BrowserInstallProgress.Phase.downloading

    init(component: BrowserComponent, report: @escaping @Sendable (BrowserInstallProgress) -> Void) {
        self.component = component
        self.report = report
    }

    func consume(_ text: String) {
        let lowered = text.lowercased()
        let update: BrowserInstallProgress? = lock.withLock {
            if lowered.contains("extracting") || lowered.contains("unpacking") { phase = .extracting }
            else if lowered.contains("checksum verified") || lowered.contains("signature verified") { phase = .verifying }
            else if lowered.contains("download complete") { phase = .verifying }
            if let found = DownloadProgressLine.parse(text) {
                phase = .downloading
                return BrowserInstallProgress(component: component, phase: .downloading, received: found.received, total: found.total)
            }
            return phase == .downloading ? nil : BrowserInstallProgress(component: component, phase: phase)
        }
        if let update { report(update) }
    }
}

/// Removes the "downloaded from the internet" mark that makes Gatekeeper refuse to start a program the first time.
enum Quarantine {
    static func clear(_ file: URL) {
        removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        // An app bundle is checked by its folder, but a file inside can carry the mark too.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let items = FileManager.default.enumerator(at: file, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL { removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
}
