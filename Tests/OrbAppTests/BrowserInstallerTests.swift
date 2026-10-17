import Foundation
import Testing
@testable import Orb

/// The installer of the browser, with a network and a command runner that are made up: no download, no browser.
@Suite final class BrowserInstallerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbInstaller-\(UUID().uuidString)/navegador")
    var layout: BrowserInstallLayout { BrowserInstallLayout(root: root) }
    let network = FakeInstallNetwork()

    deinit { removeTestFolder(root.deletingLastPathComponent()) }

    private let agentVersion = BrowserPlatform.agentBrowserVersion
    private let agentBinary = Data("#!/bin/sh\necho agent-browser \(BrowserPlatform.agentBrowserVersion)\n".utf8)

    /// A platform whose pinned hash is the one of the file the fake network serves, and the network serving it.
    private func platform(_ arch: BrowserPlatform.Architecture = .arm64, serving data: Data? = nil, hash: Data? = nil) -> BrowserPlatform {
        var platform = BrowserPlatform(architecture: arch)
        platform.pinnedHashes[arch] = FakeInstallNetwork.sha256(hash ?? agentBinary)
        network.serve(file: platform.agentBrowserURL.absoluteString, data ?? agentBinary)
        return platform
    }

    /// A runner that is every program installed right: versions, `agent-browser install`.
    private func workingRunner(chrome: String = "155.0.8059.39") -> FakeInstallRunner {
        FakeInstallRunner { [agentVersion] call, output in
            let exe = call.executable, args = call.arguments
            if exe.hasSuffix("/agent-browser"), args == ["--version"] { return FakeInstallRunner.ok("agent-browser \(agentVersion)\n") }
            if exe.hasSuffix("/agent-browser"), args == ["install"] {
                output("Installing Chrome...\n  Downloading Chrome \(chrome) for mac-arm64\n  9/184 MB (5%)  92/184 MB (50%)")
                let browser = URL(fileURLWithPath: call.environment["HOME"] ?? "/nonexistent")
                    .appending(path: ".agent-browser/browsers/chrome-\(chrome)/Google Chrome for Testing.app/Contents/MacOS")
                try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
                try writeExecutable("chrome", to: browser.appending(path: "Google Chrome for Testing"))
                return FakeInstallRunner.ok("")
            }
            if exe.hasSuffix("Google Chrome for Testing"), args == ["--version"] { return FakeInstallRunner.ok("Google Chrome for Testing \(chrome)\n") }
            return nil
        }
    }

    private func makeInstaller(_ runner: FakeInstallRunner? = nil, platform: BrowserPlatform? = nil, freeSpace: Int64? = nil)
        -> (BrowserInstaller, FakeInstallRunner) {
        let fake = runner ?? workingRunner()
        let space = freeSpace
        return (BrowserInstaller(layout: layout, platform: platform ?? self.platform(), network: network, run: fake.runner,
                                 freeSpace: { _ in space }), fake)
    }

    // MARK: What is chosen

    @Test func theFileIsThePinnedReleaseForTheArchitecture() {
        let arm = BrowserPlatform(architecture: .arm64), intel = BrowserPlatform(architecture: .x86_64)
        #expect(BrowserPlatform.agentBrowserVersion == "0.39.1")
        #expect(arm.agentBrowserAsset == "agent-browser-darwin-arm64" && intel.agentBrowserAsset == "agent-browser-darwin-x64")
        #expect(arm.agentBrowserURL.absoluteString == "https://github.com/vercel-labs/agent-browser/releases/download/v0.39.1/agent-browser-darwin-arm64")
        #expect(intel.agentBrowserURL.absoluteString == "https://github.com/vercel-labs/agent-browser/releases/download/v0.39.1/agent-browser-darwin-x64")
        for platform in [arm, intel] {
            #expect(platform.agentBrowserSHA256.count == 64 && platform.agentBrowserSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(arm.agentBrowserSHA256 != intel.agentBrowserSHA256)
    }

    @Test func anIntelMacGetsTheIntelFileAndNothingElseIsAsked() async throws {
        let (installer, _) = makeInstaller(platform: platform(.x86_64))
        try await installer.install([.agentBrowser])
        #expect(network.requests == [BrowserPlatform(architecture: .x86_64).agentBrowserURL.absoluteString], "no lookup of the latest release")
    }

    @Test func versionsAreComparedNumberByNumber() {
        #expect(BrowserVersion.isNewer("0.10.0", than: "0.9.0") && !BrowserVersion.isNewer("0.9.0", than: "0.10.0"))
        #expect(BrowserVersion.isNewer("145.0.7632.109.10", than: "145.0.7632.109.2") && !BrowserVersion.isNewer("1.2", than: "1.2.0"))
        #expect(BrowserVersion.clean("v0.39.1") == "0.39.1" && BrowserVersion.clean("0.39.1") == "0.39.1")
        #expect(BrowserVersion.find(in: "Google Chrome for Testing 155.0.8059.39 ") == "155.0.8059.39")
        #expect(DownloadProgressLine.parse("  9/184 MB (5%)  18/184 MB (10%)")?.received == 18_000_000)
        #expect(DownloadProgressLine.parse("Extracting to /x") == nil)
    }

    // MARK: agent-browser

    @Test func agentBrowserIsDownloadedCheckedAgainstThePinAndPlacedWithItsVersionWritten() async throws {
        let (installer, runner) = makeInstaller()
        let steps = LockedBox<[BrowserInstallProgress.Phase]>([])
        let bytes = LockedBox<Int64>(0)
        try await installer.install([.agentBrowser]) { progress in
            if steps.value.last != progress.phase { steps.value.append(progress.phase) }
            bytes.value = max(bytes.value, progress.received)
        }
        #expect(FileManager.default.isExecutableFile(atPath: layout.agentBrowser.path))
        #expect(try Data(contentsOf: layout.agentBrowser) == agentBinary)
        let record = try #require(installer.records()["agentBrowser"])
        #expect(record.version == agentVersion && record.sha256 == FakeInstallNetwork.sha256(agentBinary) && record.verified == true)
        #expect(record.source?.hasSuffix("/v\(agentVersion)/agent-browser-darwin-arm64") == true)
        #expect(steps.value.starts(with: [.preparing, .downloading, .verifying, .checking, .installing]), "\(steps.value)")
        #expect(bytes.value == Int64(agentBinary.count))
        #expect(runner.calls.first?.arguments == ["--version"], "it was run once before it was kept")
        // Nothing left in the work folders.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(BrowserInstallLayout.workPrefix) })
    }

    @Test func aFileThatIsNotThePinnedOneInstallsNothing() async throws {
        // The network serves something else than the file the pin was taken from.
        let (installer, runner) = makeInstaller(platform: platform(serving: Data("tampered".utf8)))
        await #expect(throws: BrowserInstallError.checksumMismatch("agent-browser")) { try await installer.install([.agentBrowser]) }
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path))
        #expect(installer.records().isEmpty && runner.calls.isEmpty, "not even run")
        #expect(BrowserInstallError.checksumMismatch("agent-browser").errorDescription?.contains("não confere") == true)
    }

    @Test func aFailedUpdateLeavesTheInstalledOneAsItWas() async throws {
        let (installer, _) = makeInstaller()
        try await installer.install([.agentBrowser])
        let before = try Data(contentsOf: layout.agentBrowser)

        // The new download is damaged: it does not match the pin.
        let damaged = platform(serving: Data("broken".utf8))
        let (broken, _) = makeInstaller(platform: damaged)
        await #expect(throws: BrowserInstallError.checksumMismatch("agent-browser")) { try await broken.install([.agentBrowser]) }
        #expect(try Data(contentsOf: layout.agentBrowser) == before)

        // One that downloads right but does not start is not kept either.
        let (failing, _) = makeInstaller(FakeInstallRunner { _, _ in FakeInstallRunner.failed("killed", status: 137) }, platform: platform())
        await #expect(throws: BrowserInstallError.broken("agent-browser", detail: "saiu com o código 137")) {
            try await failing.install([.agentBrowser])
        }
        #expect(try Data(contentsOf: layout.agentBrowser) == before)
    }

    @Test func aBinaryThatSaysAnotherVersionIsNotKept() async throws {
        let wrong = FakeInstallRunner { call, _ in call.arguments == ["--version"] ? FakeInstallRunner.ok("agent-browser 0.1.0\n") : nil }
        let (installer, _) = makeInstaller(wrong)
        await #expect(throws: BrowserInstallError.self) { try await installer.install([.agentBrowser]) }
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path) && installer.records().isEmpty)
    }

    // MARK: Chrome

    @Test func chromeIsInstalledByAgentBrowserWithAHomeOfItsOwnAndMovedIntoTheAppFolder() async throws {
        let (installer, runner) = makeInstaller()
        let phases = LockedBox<[Double]>([])
        try await installer.install([.agentBrowser, .chrome]) { progress in
            if progress.component == .chrome, let fraction = progress.componentFraction { phases.value.append(fraction) }
        }
        let install = try #require(runner.calls.first { $0.arguments == ["install"] })
        #expect(install.executable == layout.agentBrowser.path && install.environment["HOME"]?.contains(BrowserInstallLayout.workPrefix) == true)
        #expect(install.environment["HOME"] != NSHomeDirectory(), "nothing lands in the user's own folder")
        let folder = layout.chromeDirectory.appending(path: "chrome-155.0.8059.39")
        #expect(FileManager.default.isExecutableFile(atPath: folder.appending(path: "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing").path))
        #expect(installer.records()["chrome"]?.version == "155.0.8059.39")
        #expect(phases.value.contains { $0 > 0.4 && $0 < 1 }, "the megabytes it prints become progress: \(phases.value)")
        // The locator finds both in the app's folder.
        let locator = BrowserLocator.live(path: "/usr/bin", home: root, managedRoot: root)
        #expect(locator.agentBrowser() == layout.agentBrowser.path)
        #expect(locator.installedChrome()?.hasPrefix(folder.path) == true)

        // A newer one replaces the old folder.
        let (again, _) = makeInstaller(workingRunner(chrome: "156.0.1.2"))
        try await again.install([.chrome])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.chromeDirectory.path) == ["chrome-156.0.1.2"])
        #expect(again.records()["chrome"]?.version == "156.0.1.2")
    }

    @Test func chromeNeedsAgentBrowserFirst() async throws {
        let (installer, _) = makeInstaller()
        await #expect(throws: BrowserInstallError.needsAgentBrowser) { try await installer.install([.chrome]) }
    }

    // MARK: Cancelling, space, network

    @Test func cancellingStopsTheDownloadAndLeavesNothingBehind() async throws {
        let started = LockedBox(false)
        network.beforeDownload = { _ in
            started.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let (installer, _) = makeInstaller()
        let task = Task { try await installer.install([.agentBrowser, .chrome]) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path) && installer.records().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(BrowserInstallLayout.workPrefix) })
    }

    @Test func aFullDiskIsToldBeforeAndAfterDownloading() async throws {
        let (small, _) = makeInstaller(freeSpace: 10)
        await #expect(throws: BrowserInstallError.diskFull(needed: BrowserPlatform.agentBrowserSize * 3)) { try await small.install([.agentBrowser]) }
        #expect(network.requests.isEmpty, "nothing was downloaded")

        // The disk filled up in the middle.
        let working = workingRunner()
        let full = FakeInstallRunner { call, output in
            call.arguments == ["install"] ? FakeInstallRunner.failed("Error: No space left on device (os error 28)") : try await working.handler(call, output)
        }
        let (installer, _) = makeInstaller(full)
        try await installer.install([.agentBrowser])
        await #expect(throws: BrowserInstallError.diskFull(needed: nil)) { try await installer.install([.chrome]) }
        #expect(BrowserInstallError.diskFull(needed: 900_000_000).errorDescription?.contains("900 MB") == true)
        #expect(BrowserInstaller.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)) && BrowserInstaller.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(!BrowserInstaller.isOutOfSpace(CocoaError(.fileNoSuchFile)))
    }

    @Test func noNetworkIsToldAsSuch() async throws {
        network.offline = true
        let (installer, _) = makeInstaller()
        await #expect(throws: BrowserInstallError.noNetwork) { try await installer.install([.agentBrowser]) }
        #expect(BrowserInstallError.noNetwork.errorDescription?.contains("Sem conexão") == true)
        #expect(BrowserInstallError.rateLimited.errorDescription?.contains("GitHub") == true)
        #expect(URLSessionInstallNetwork.translate(URLError(.notConnectedToInternet)) as? BrowserInstallError == .noNetwork)
        #expect(URLSessionInstallNetwork.translate(URLError(.cancelled)) is CancellationError)

        func failure(_ text: String) -> BrowserInstallError { BrowserInstaller.commandFailure("X", FakeInstallRunner.failed(text)) }
        #expect(failure("Error: error sending request for url (https://storage.googleapis.com/x): dns error") == .noNetwork)
        #expect(failure("OSError: [Errno 28] No space left on device") == .diskFull(needed: nil))
        if case .failed("X", let detail) = failure("line one\nERROR: Could not find a version\n") { #expect(detail.contains("Could not find a version")) } else { Issue.record("generic failure") }
        #expect(BrowserInstaller.commandFailure("X", ProcessOutput(status: -1, signal: nil, output: "", timedOut: true)) == .failed("X", detail: "demorou demais e foi interrompido."))
    }

    // MARK: Removing

    @Test func removingAComponentKeepsTheProfilesAndTheCommandForTheOthers() async throws {
        let (installer, _) = makeInstaller()
        try await installer.install([.agentBrowser, .chrome])
        // The Orbs' logins.
        let orb = UUID()
        let profile = root.appending(path: "\(orb.uuidString)/chrome")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("login".utf8).write(to: profile.appending(path: "Cookies"))

        try installer.uninstall(.chrome)
        #expect(!installer.isInstalled(.chrome) && installer.records()["chrome"] == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.chromeDirectory.path))
        #expect(FileManager.default.fileExists(atPath: profile.appending(path: "Cookies").path), "the logins stay")
        #expect(installer.isInstalled(.agentBrowser))

        try installer.uninstall(.agentBrowser)
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path) && !FileManager.default.fileExists(atPath: layout.binDirectory.path))
        #expect(installer.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: profile.appending(path: "Cookies").path))
    }

    @Test func theFilesOfObscuraAndCloakBrowserFromEarlierVersionsAreRemovedAndTheLoginsAreNot() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        for name in ["obscura", "obscura-worker", "agent-browser"] { try Data(name.utf8).write(to: layout.binDirectory.appending(path: name)) }
        let cloak = root.appending(path: "cloak/chromium-145/Chromium.app")
        try fileManager.createDirectory(at: cloak, withIntermediateDirectories: true)
        let orb = UUID()
        let oldLogins = root.appending(path: "\(orb.uuidString)/cloak")
        try fileManager.createDirectory(at: oldLogins, withIntermediateDirectories: true)
        try Data("login".utf8).write(to: oldLogins.appending(path: "Cookies"))
        let record = #"{"obscura":{"version":"0.2.4","installedAt":"2026-10-01T00:00:00Z"},"cloak":{"version":"0.6.0","installedAt":"2026-10-01T00:00:00Z"},"agentBrowser":{"version":"0.39.0","installedAt":"2026-10-01T00:00:00Z"}}"#
        try Data(record.utf8).write(to: layout.recordsFile)
        let (installer, _) = makeInstaller()

        installer.removeLegacyEngines()
        #expect(!fileManager.fileExists(atPath: layout.binDirectory.appending(path: "obscura").path))
        #expect(!fileManager.fileExists(atPath: layout.binDirectory.appending(path: "obscura-worker").path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: "cloak").path))
        #expect(fileManager.fileExists(atPath: layout.agentBrowser.path), "agent-browser stays")
        #expect(Set(installer.records().keys) == ["agentBrowser"])
        #expect(fileManager.fileExists(atPath: oldLogins.appending(path: "Cookies").path), "the logins of the Orbs are theirs")
    }

    // MARK: Updates

    @Test func newerReleasesAreLookedForOnceADay() async throws {
        network.serve(document: BrowserInstaller.chromeVersionsURL.absoluteString, #"{"channels":{"Stable":{"version":"156.0.1.1"}}}"#)
        let (installer, _) = makeInstaller()
        try await installer.install([.agentBrowser, .chrome])
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // The app's pin is the newest agent-browser an install can bring, so it is never "outdated" against itself; Chrome has a newer one.
        let first = try await installer.checkForUpdates(now: start)
        #expect(first.latest["agentBrowser"] == agentVersion && first.latest["chrome"] == "156.0.1.1")
        #expect(installer.updatable(first) == [.chrome])
        let asked = network.requests.count

        // Within the day nothing is asked again; after it, it is.
        _ = try await installer.checkForUpdates(now: start.addingTimeInterval(3_600))
        #expect(network.requests.count == asked)
        _ = try await installer.checkForUpdates(now: start.addingTimeInterval(25 * 3_600))
        #expect(network.requests.count > asked)
        _ = try await installer.checkForUpdates(force: true, now: start.addingTimeInterval(25 * 3_600 + 5))
        #expect(BrowserUpdateCheck(checkedAt: start, latest: [:]).isDue(now: start.addingTimeInterval(86_400)))
        #expect(!BrowserUpdateCheck(checkedAt: start, latest: [:]).isDue(now: start.addingTimeInterval(86_399)))

        // Nothing newer: nothing to update. An older agent-browser than the pin is offered the pin.
        #expect(installer.updatable(BrowserUpdateCheck(checkedAt: start, latest: ["agentBrowser": agentVersion, "chrome": "155.0.8059.39"])).isEmpty)
        let older = InstalledRecords(uniqueKeysWithValues: [("agentBrowser", InstalledComponent(version: "0.39.0", installedAt: start))])
        #expect(installer.updatable(first, records: older).contains(.agentBrowser))
    }

    @Test func withoutNetworkTheLookForUpdatesKeepsWhatWasKnown() async throws {
        let (installer, _) = makeInstaller()
        try await installer.install([.agentBrowser, .chrome])
        network.offline = true
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        // agent-browser has nothing to ask (the pin), Chrome cannot be asked: the look reaches something, so it is written down.
        let look = try await installer.checkForUpdates(now: day)
        #expect(look.latest["agentBrowser"] == agentVersion && look.latest["chrome"] == nil)
    }

    @Test func aChromeLookThatCannotBeReadIsWrittenDownAndNotRepeatedToday() async throws {
        network.serve(document: BrowserInstaller.chromeVersionsURL.absoluteString, "not a list")
        let (installer, _) = makeInstaller()
        try await installer.install([.agentBrowser, .chrome])
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let partial = try await installer.checkForUpdates(now: day)
        #expect(partial.latest["agentBrowser"] == agentVersion && partial.latest["chrome"] == nil)
        #expect(BrowserInstaller.readUpdates(layout.updatesFile)?.checkedAt == day)
        let asked = network.requests.count
        _ = try await installer.checkForUpdates(now: day.addingTimeInterval(3_600))
        #expect(network.requests.count == asked, "at most one round of calls a day")
    }

    // MARK: Downloads

    @Test func downloadsFollowRedirectsToHTTPSOnly() async throws {
        #expect(URLSessionInstallNetwork.allowsRedirect(to: URL(string: "https://objects.example.test/x")))
        #expect(!URLSessionInstallNetwork.allowsRedirect(to: URL(string: "http://objects.example.test/x")))
        #expect(!URLSessionInstallNetwork.allowsRedirect(to: URL(string: "ftp://x.test/x")) && !URLSessionInstallNetwork.allowsRedirect(to: nil))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let network = URLSessionInstallNetwork(session: URLSession(configuration: configuration))
        // A document that is handed to a plain-HTTP address on the way is refused.
        let error = try #require(await #expect(throws: BrowserInstallError.self, "a redirect to http must be refused") {
            _ = try await network.data(from: URL(string: "https://example.test/release")!)
        })
        guard case .failed(_, let detail) = error else { Issue.record("wrong error \(error)"); return }
        #expect(detail.contains("sem HTTPS"), "\(detail)")
        // One that goes on over https is followed.
        let data = try await network.data(from: URL(string: "https://example.test/moved")!)
        #expect(String(decoding: data, as: UTF8.self) == "arrived")
        // The same for a download: nothing is written.
        let file = root.deletingLastPathComponent().appending(path: "baixado")
        let downloadError = try #require(await #expect(throws: BrowserInstallError.self, "a download must not follow a redirect to http") {
            _ = try await network.download(URL(string: "https://example.test/release")!, to: file) { _, _ in }
        })
        guard case .failed(_, let downloadDetail) = downloadError else { Issue.record("wrong error \(downloadError)"); return }
        #expect(downloadDetail.contains("sem HTTPS"), "\(downloadDetail)")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = file.deletingLastPathComponent().appending(path: "baixado-ok")
        _ = try await network.download(URL(string: "https://example.test/moved")!, to: kept) { _, _ in }
        #expect(try String(contentsOf: kept, encoding: .utf8) == "arrived")
    }
}

/// Answers `https://example.test/release` with a redirect to a plain-HTTP address, `/moved` with one to another https address, and
/// that one with a body.
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        func redirect(to address: String) {
            let target = URL(string: address)!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": address])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // When the redirect is not followed the page is the redirect itself, as a server's would be.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        switch url.path {
        case "/release": redirect(to: "http://objects.example.test/file")
        case "/moved": redirect(to: "https://objects.example.test/file")
        default:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("arrived".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
