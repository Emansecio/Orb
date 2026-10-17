import Foundation

/// Runs a program (no shell) and returns what it printed; `onOutput` gets the text as it arrives, for progress lines.
typealias InstallCommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String],
                                            _ timeout: Duration, _ onOutput: @escaping @Sendable (String) -> Void) async throws -> ProcessOutput

/// Installs what the Orbs' browser needs inside the app's own data folder (`BrowserInstallLayout`), with nothing but what a Mac
/// has: no Homebrew, no Node, no sudo. Everything is downloaded into a work folder, checked, tried, and only then moved into
/// place, so a failed or cancelled install leaves what was there untouched.
///
/// - `agent-browser`: the release binary of github.com/vercel-labs/agent-browser at the version the app was tested with
///   (`BrowserPlatform.agentBrowserVersion`), checked against the SHA-256 written down in the app for this Mac's architecture.
/// - Chrome: only when the Mac has neither Chrome nor Brave. `agent-browser install` (Chrome for Testing), run with a `HOME` of
///   its own so it lands in the app's folder.
final class BrowserInstaller: Sendable {
    let layout: BrowserInstallLayout
    let platform: BrowserPlatform
    private let network: any InstallNetwork
    private let run: InstallCommandRunner
    private let freeSpace: @Sendable (URL) -> Int64?

    static let chromeVersionsURL = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json")!

    init(layout: BrowserInstallLayout, platform: BrowserPlatform = .current, network: any InstallNetwork = URLSessionInstallNetwork(),
         run: @escaping InstallCommandRunner = BrowserInstaller.processRunner,
         freeSpace: @escaping @Sendable (URL) -> Int64? = BrowserInstaller.availableSpace) {
        self.layout = layout
        self.platform = platform
        self.network = network
        self.run = run
        self.freeSpace = freeSpace
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
        switch component {
        case .agentBrowser: return FileManager.default.isExecutableFile(atPath: layout.agentBrowser.path)
        case .chrome: return !Self.folders(in: layout.chromeDirectory, prefix: "chrome-").isEmpty
        }
    }

    // MARK: Installing

    /// Installs exactly `components`, in order (the caller says which: what is missing, or what has a newer release). Throws
    /// `CancellationError` when the task is cancelled; the work folder is gone either way.
    func install(_ components: [BrowserComponent], progress: @escaping @Sendable (BrowserInstallProgress) -> Void = { _ in }) async throws {
        removeStaleWorkFolders()
        removeLegacyEngines()
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let report: @Sendable (BrowserInstallProgress) -> Void = { update in
                var update = update
                update.step = index + 1
                update.steps = components.count
                progress(update)
            }
            report(BrowserInstallProgress(component: component, phase: .preparing))
            let installed: InstalledComponent
            switch component {
            case .agentBrowser: installed = try await installAgentBrowser(report)
            case .chrome: installed = try await installChrome(report)
            }
            try record(component, installed)
        }
        progress(BrowserInstallProgress(component: components.last ?? .agentBrowser, phase: .finishing, step: components.count, steps: components.count))
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
        let version = BrowserPlatform.agentBrowserVersion
        let asset = Asset(name: platform.agentBrowserAsset, url: platform.agentBrowserURL, size: BrowserPlatform.agentBrowserSize,
                          sha256: platform.agentBrowserSHA256)
        try requireSpace(asset.size * 3, at: layout.root)
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appending(path: "agent-browser")
        let hash = try await download(asset, to: file, component: component, version: version, report: report)
        report(.init(component: component, phase: .verifying, version: version))
        // The app carries the hash of the file it was tested with: anything else (a different release, a file changed on the way) is refused.
        guard hash.lowercased() == platform.agentBrowserSHA256 else { throw BrowserInstallError.checksumMismatch(component.name) }
        try Self.makeExecutable(file)
        Quarantine.clear(file)
        report(.init(component: component, phase: .checking, version: version))
        try await requireWorking(file.path, ["--version"], name: component.name, expecting: version)
        report(.init(component: component, phase: .installing, version: version))
        try replaceItem(at: layout.agentBrowser, with: file)
        return InstalledComponent(version: version, installedAt: .now, source: asset.url.absoluteString, sha256: hash, verified: true)
    }

    // MARK: Chrome

    /// Chrome for Testing, the fallback for a Mac with no Chrome or Brave.
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
        guard let executable = BrowserLocator.chromeExecutable(inFolder: folder) else {
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
            } catch {
                failure = error
            }
        }
        // A look that reached something counts as a look, even when part of it failed (what is known stays, and the next look is
        // tomorrow's). Only a look that reached nothing (no network) is not written down: the next try is soon.
        if !reached, let failure {
            if latest.isEmpty { throw failure }
            return BrowserUpdateCheck(checkedAt: cached?.checkedAt ?? now, latest: latest)
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
        case .agentBrowser:
            // The version the app was tested with is the newest an install can bring: an update shows when a newer app brings a newer
            // pin, not when the repository has a new release.
            return BrowserPlatform.agentBrowserVersion
        case .chrome:
            let json = JSONValue.parse(String(decoding: try await network.data(from: Self.chromeVersionsURL), as: UTF8.self))
            guard let version = json?["channels"]?["Stable"]?["version"]?.string else { throw BrowserInstallError.failed("Chrome", detail: "a lista de versões veio sem a estável.") }
            return version
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

    /// Removes the files of one component. Anything still running from them is the caller's to close first. The Orbs' profiles
    /// (their logins) are never touched here.
    func uninstall(_ component: BrowserComponent) throws {
        let fileManager = FileManager.default
        switch component {
        case .agentBrowser:
            try? fileManager.removeItem(at: layout.agentBrowser)
            try? fileManager.removeItem(at: layout.updatesFile)
            // The folder is only a place for the binary: empty, it goes.
            if (try? fileManager.contentsOfDirectory(atPath: layout.binDirectory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: layout.binDirectory)
            }
        case .chrome:
            try? fileManager.removeItem(at: layout.chromeDirectory)
        }
        try record(component, nil)
    }

    /// The Obscura and CloakBrowser files earlier versions of the app installed (`bin/obscura`, `cloak/`): nothing runs them any
    /// more, and the CloakBrowser Chromium alone is about 500 MB. Only what the app itself put in its own folder goes.
    func removeLegacyEngines() {
        let fileManager = FileManager.default
        for url in [layout.binDirectory.appending(path: "obscura"), layout.binDirectory.appending(path: "obscura-worker"),
                    layout.root.appending(path: "cloak", directoryHint: .isDirectory)] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        var all = records()
        guard all["obscura"] != nil || all["cloak"] != nil else { return }
        all["obscura"] = nil
        all["cloak"] = nil
        try? save(all)
    }

    // MARK: Pieces

    struct Asset: Sendable {
        var name: String
        var url: URL
        var size: Int64
        var sha256: String?
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
