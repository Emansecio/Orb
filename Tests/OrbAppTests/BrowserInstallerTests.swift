import Foundation
import Testing
@testable import Orb

/// The installer of the browsers, with a network and a command runner that are made up: no download, no browser.
@Suite final class BrowserInstallerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbInstaller-\(UUID().uuidString)/navegador")
    var layout: BrowserInstallLayout { BrowserInstallLayout(root: root) }
    let network = FakeInstallNetwork()

    deinit { removeTestFolder(root.deletingLastPathComponent()) }

    private let agentTag = "v0.39.0"
    private let obscuraTag = "v0.2.4"
    private let agentBinary = Data("#!/bin/sh\necho agent-browser 0.39.0\n".utf8)

    /// The releases of both repositories on the fake network.
    private func serveReleases(agentDigest: Bool = true, tamper: Bool = false, obscuraNames: [String] = []) throws {
        let arm = BrowserPlatform(architecture: .arm64), intel = BrowserPlatform(architecture: .x86_64)
        network.serve(document: "https://api.github.com/repos/vercel-labs/agent-browser/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: agentTag, assets: [(arm.agentBrowserAsset, agentBinary, agentDigest), (intel.agentBrowserAsset, Data("intel".utf8), agentDigest),
                                    ("agent-browser-linux-x64", Data("linux".utf8), agentDigest)]))
        network.serve(file: FakeInstallNetwork.assetURL(tag: agentTag, arm.agentBrowserAsset), tamper ? Data("tampered".utf8) : agentBinary)
        network.serve(file: FakeInstallNetwork.assetURL(tag: agentTag, intel.agentBrowserAsset), Data("intel".utf8))

        let archive = try FakeInstallRunner.archive(["obscura", "obscura-worker"] + obscuraNames, in: root.deletingLastPathComponent())
        let plain = try FakeInstallRunner.archive(["obscura", "obscura-worker"], in: root.deletingLastPathComponent())
        let names = arm.obscuraAssets + intel.obscuraAssets
        network.serve(document: "https://api.github.com/repos/h4ckf0r0day/obscura/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: obscuraTag, assets: names.map { ($0, $0.contains("stealth") ? archive : plain, true) }))
        for name in names { network.serve(file: FakeInstallNetwork.assetURL(tag: obscuraTag, name), name.contains("stealth") ? archive : plain) }
    }

    /// A runner that is every program installed right: versions, `agent-browser install`, the Python steps.
    private func workingRunner(chrome: String = "155.0.8059.39", cloak: String = "145.0.7632.109.2", python: String = "/usr/bin/python3") -> FakeInstallRunner {
        FakeInstallRunner { call, output in
            let exe = call.executable, args = call.arguments
            if exe.hasSuffix("/agent-browser"), args == ["--version"] { return FakeInstallRunner.ok("agent-browser 0.39.0\n") }
            if exe.hasSuffix("/obscura"), args == ["--version"] { return FakeInstallRunner.ok("obscura 0.2.4\n") }
            if exe.hasSuffix("/agent-browser"), args == ["install"] {
                output("Installing Chrome...\n  Downloading Chrome \(chrome) for mac-arm64\n  9/184 MB (5%)  92/184 MB (50%)")
                let browser = URL(fileURLWithPath: call.environment["HOME"] ?? "/nonexistent")
                    .appending(path: ".agent-browser/browsers/chrome-\(chrome)/Google Chrome for Testing.app/Contents/MacOS")
                try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
                let file = browser.appending(path: "Google Chrome for Testing")
                try Data("chrome".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                return FakeInstallRunner.ok("")
            }
            if exe.hasSuffix("Google Chrome for Testing"), args == ["--version"] { return FakeInstallRunner.ok("Google Chrome for Testing \(chrome)\n") }
            if exe.hasSuffix("/Chromium"), args == ["--version"] { return FakeInstallRunner.ok("Chromium \(cloak)\n") }
            if exe == "/usr/bin/xcode-select" { return FakeInstallRunner.ok("/Library/Developer/CommandLineTools\n") }
            if exe == python, args.first == "-c" { return FakeInstallRunner.ok("") }
            if args.starts(with: ["-m", "venv"]) {
                let venv = URL(fileURLWithPath: args[2]).appending(path: "bin")
                try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
                let file = venv.appending(path: "python")
                try Data("python".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                return FakeInstallRunner.ok("")
            }
            if args == ["-m", "pip", "install", "cloakbrowser"] { return FakeInstallRunner.ok("Successfully installed cloakbrowser-0.6.0") }
            if args == ["-m", "cloakbrowser", "install"] {
                for line in ["Download progress: 59% (82/140 MB)\n", "Download complete: 140 MB\n", "SHA256SUMS signature verified: Ed25519 OK\n",
                             "Checksum verified: SHA-256 OK\n", "Extracting to /x\n"] { output(line) }
                let cache = URL(fileURLWithPath: call.environment["CLOAKBROWSER_CACHE_DIR"] ?? "/nonexistent")
                let binary = cache.appending(path: "chromium-\(cloak)/Chromium.app/Contents/MacOS")
                try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
                let file = binary.appending(path: "Chromium")
                try Data("chromium".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                return FakeInstallRunner.ok("")
            }
            if args.first == "-c", args.last?.contains("__version__") == true { return FakeInstallRunner.ok("0.6.0\n") }
            return nil
        }
    }

    private func makeInstaller(_ runner: FakeInstallRunner? = nil, arch: BrowserPlatform.Architecture = .arm64, freeSpace: Int64? = nil) -> (BrowserInstaller, FakeInstallRunner) {
        let fake = runner ?? workingRunner()
        let space = freeSpace
        return (BrowserInstaller(layout: layout, platform: BrowserPlatform(architecture: arch), network: network, run: fake.runner,
                                 freeSpace: { _ in space }, findPython: { _ in "/usr/bin/python3" }), fake)
    }

    // MARK: What is chosen

    @Test func theFilesAreChosenForTheArchitecture() {
        let arm = BrowserPlatform(architecture: .arm64), intel = BrowserPlatform(architecture: .x86_64)
        #expect(arm.agentBrowserAsset == "agent-browser-darwin-arm64" && intel.agentBrowserAsset == "agent-browser-darwin-x64")
        #expect(arm.obscuraAssets == ["obscura-aarch64-macos-stealth.tar.gz", "obscura-aarch64-macos.tar.gz"])
        #expect(intel.obscuraAssets == ["obscura-x86_64-macos-stealth.tar.gz", "obscura-x86_64-macos.tar.gz"])
        #expect(BrowserEngineKind.chrome.components == [.agentBrowser, .chrome] && BrowserEngineKind.simple.components.isEmpty)
        #expect(BrowserEngineKind.cloak.browserComponent == .cloak && BrowserEngineKind.simple.browserComponent == nil)
    }

    @Test func anIntelMacGetsTheIntelFiles() async throws {
        try serveReleases()
        let (installer, _) = makeInstaller(arch: .x86_64)
        try await installer.install(.obscura)
        #expect(network.requests.contains(FakeInstallNetwork.assetURL(tag: agentTag, "agent-browser-darwin-x64")))
        #expect(network.requests.contains(FakeInstallNetwork.assetURL(tag: obscuraTag, "obscura-x86_64-macos-stealth.tar.gz")))
        #expect(!network.requests.contains { $0.contains("arm64") || $0.contains("aarch64") })
    }

    @Test func versionsAreComparedNumberByNumber() {
        #expect(BrowserVersion.isNewer("0.10.0", than: "0.9.0") && !BrowserVersion.isNewer("0.9.0", than: "0.10.0"))
        #expect(BrowserVersion.isNewer("145.0.7632.109.10", than: "145.0.7632.109.2") && !BrowserVersion.isNewer("1.2", than: "1.2.0"))
        #expect(BrowserVersion.clean("v0.39.0") == "0.39.0" && BrowserVersion.clean("0.39.0") == "0.39.0")
        #expect(BrowserVersion.find(in: "Google Chrome for Testing 155.0.8059.39 ") == "155.0.8059.39")
        #expect(Checksum.parseDigest("sha256:" + String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
        #expect(Checksum.parseDigest("sha256:short") == nil && Checksum.parseDigest(nil) == nil && Checksum.parseDigest("md5:abc") == nil)
        #expect(DownloadProgressLine.parse("  9/184 MB (5%)  18/184 MB (10%)")?.received == 18_000_000)
        #expect(DownloadProgressLine.parse("Download progress: 59% (82/140 MB)")?.total == 140_000_000)
        #expect(DownloadProgressLine.parse("Extracting to /x") == nil)
    }

    // MARK: agent-browser

    @Test func agentBrowserIsDownloadedCheckedAndPlacedWithItsVersionWritten() async throws {
        try serveReleases()
        let (installer, runner) = makeInstaller()
        let steps = LockedBox<[BrowserInstallProgress.Phase]>([])
        let bytes = LockedBox<Int64>(0)
        try await installer.install(.chrome, components: [.agentBrowser]) { progress in
            if steps.value.last != progress.phase { steps.value.append(progress.phase) }
            bytes.value = max(bytes.value, progress.received)
        }
        #expect(FileManager.default.isExecutableFile(atPath: layout.agentBrowser.path))
        #expect(try Data(contentsOf: layout.agentBrowser) == agentBinary)
        let record = try #require(installer.records()["agentBrowser"])
        #expect(record.version == "0.39.0" && record.sha256 == FakeInstallNetwork.sha256(agentBinary))
        #expect(record.source?.hasSuffix("agent-browser-darwin-arm64") == true)
        #expect(steps.value.starts(with: [.preparing, .resolving, .downloading, .verifying, .checking, .installing]), "\(steps.value)")
        #expect(bytes.value == Int64(agentBinary.count))
        #expect(runner.calls.first?.arguments == ["--version"], "it was run once before it was kept")
        // Nothing left in the work folders.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(BrowserInstallLayout.workPrefix) })
    }

    @Test func aChecksumThatDoesNotMatchInstallsNothing() async throws {
        try serveReleases(tamper: true)
        let (installer, runner) = makeInstaller()
        await #expect(throws: BrowserInstallError.checksumMismatch("agent-browser")) { try await installer.install(.chrome, components: [.agentBrowser]) }
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path))
        #expect(installer.records().isEmpty && runner.calls.isEmpty, "not even run")
        #expect(BrowserInstallError.checksumMismatch("Obscura").errorDescription?.contains("não confere") == true)
    }

    @Test func aFailedUpdateLeavesTheInstalledOneAsItWas() async throws {
        try serveReleases()
        let (installer, _) = makeInstaller()
        try await installer.install(.chrome, components: [.agentBrowser])
        let before = try Data(contentsOf: layout.agentBrowser)

        // The new download is damaged: it does not match the digest of the release.
        network.serve(file: FakeInstallNetwork.assetURL(tag: agentTag, "agent-browser-darwin-arm64"), Data("broken".utf8))
        await #expect(throws: BrowserInstallError.checksumMismatch("agent-browser")) { try await installer.install(.chrome, components: [.agentBrowser]) }
        #expect(try Data(contentsOf: layout.agentBrowser) == before)

        // One that downloads right but does not start is not kept either.
        network.serve(file: FakeInstallNetwork.assetURL(tag: agentTag, "agent-browser-darwin-arm64"), agentBinary)
        let (failing, _) = self.makeInstaller(FakeInstallRunner { _, _ in FakeInstallRunner.failed("killed", status: 137) })
        await #expect(throws: BrowserInstallError.broken("agent-browser", detail: "saiu com o código 137")) {
            try await failing.install(.chrome, components: [.agentBrowser])
        }
        #expect(try Data(contentsOf: layout.agentBrowser) == before)
    }

    @Test func aReleaseWithoutADigestIsCheckedAgainstItsChecksumsFileOrInstalledUnchecked() async throws {
        try serveReleases(agentDigest: false)
        let (installer, _) = makeInstaller()
        try await installer.install(.chrome, components: [.agentBrowser])
        #expect(installer.records()["agentBrowser"]?.sha256 == FakeInstallNetwork.sha256(agentBinary), "the hash is the one of the file that was kept")

        // A checksums file next to the asset is used.
        let arm = BrowserPlatform(architecture: .arm64)
        network.serve(document: "https://api.github.com/repos/vercel-labs/agent-browser/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: agentTag, assets: [(arm.agentBrowserAsset, agentBinary, false), ("SHA256SUMS", Data(), false)]))
        network.serve(document: FakeInstallNetwork.assetURL(tag: agentTag, "SHA256SUMS"),
                      String(repeating: "0", count: 64) + "  agent-browser-darwin-arm64\n")
        await #expect(throws: BrowserInstallError.checksumMismatch("agent-browser")) { try await installer.install(.chrome, components: [.agentBrowser]) }
        #expect(BrowserInstaller.checksum(of: "a.tar.gz", inListing: "\(String(repeating: "a", count: 64))  a.tar.gz\n\(String(repeating: "b", count: 64)) *b.tar.gz")
                == String(repeating: "a", count: 64))
        #expect(BrowserInstaller.checksum(of: "b.tar.gz", inListing: "\(String(repeating: "b", count: 64)) *b.tar.gz") == String(repeating: "b", count: 64))
        #expect(BrowserInstaller.checksum(of: "c", inListing: "\(String(repeating: "a", count: 64))  a.tar.gz") == nil)
    }

    // MARK: Obscura

    @Test func obscuraIsExtractedCheckedAndPlacedNextToAgentBrowser() async throws {
        try serveReleases()
        let (installer, _) = makeInstaller()
        try await installer.install(.obscura)
        #expect(FileManager.default.isExecutableFile(atPath: layout.obscura.path) && FileManager.default.isExecutableFile(atPath: layout.obscuraWorker.path))
        #expect(installer.records()["obscura"]?.version == "0.2.4" && installer.records()["obscura"]?.detail == "stealth")
        #expect(installer.isInstalled(.obscura) && installer.isInstalled(.agentBrowser))
        let found = BrowserEngineLocator.live(path: "/usr/bin", managedRoot: root).status(for: .obscura)
        #expect(found.isReady && found.agentBrowser == layout.agentBrowser.path && found.browserExecutable == layout.obscura.path)
    }

    @Test func anArchiveWithAnUnexpectedFileIsNotExtractedIntoPlace() async throws {
        try serveReleases(obscuraNames: ["intruso"])
        let (installer, _) = makeInstaller()
        await #expect(throws: BrowserInstallError.self) { try await installer.install(.obscura) }
        #expect(!FileManager.default.fileExists(atPath: layout.obscura.path))
    }

    @Test func withoutTheStealthBuildThePlainOneIsUsed() async throws {
        try serveReleases()
        let arm = BrowserPlatform(architecture: .arm64)
        let plain = try FakeInstallRunner.archive(["obscura", "obscura-worker"], in: root.deletingLastPathComponent())
        network.serve(document: "https://api.github.com/repos/h4ckf0r0day/obscura/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: obscuraTag, assets: [(arm.obscuraAssets[1], plain, true)]))
        network.serve(file: FakeInstallNetwork.assetURL(tag: obscuraTag, arm.obscuraAssets[1]), plain)
        let (installer, _) = makeInstaller()
        try await installer.install(.obscura)
        #expect(installer.records()["obscura"]?.detail == nil)

        network.serve(document: "https://api.github.com/repos/h4ckf0r0day/obscura/releases/latest", FakeInstallNetwork.releaseJSON(tag: obscuraTag, assets: []))
        await #expect(throws: BrowserInstallError.assetMissing("Obscura")) { try await installer.install(.obscura, components: [.obscura]) }
    }

    // MARK: Chrome

    @Test func chromeIsInstalledByAgentBrowserWithAHomeOfItsOwnAndMovedIntoTheAppFolder() async throws {
        try serveReleases()
        let (installer, runner) = makeInstaller()
        let phases = LockedBox<[Double]>([])
        try await installer.install(.chrome) { progress in
            if progress.component == .chrome, let fraction = progress.fraction { phases.value.append(fraction) }
        }
        let install = try #require(runner.calls.first { $0.arguments == ["install"] })
        #expect(install.executable == layout.agentBrowser.path && install.environment["HOME"]?.contains(BrowserInstallLayout.workPrefix) == true)
        #expect(install.environment["HOME"] != NSHomeDirectory(), "nothing lands in the user's own folder")
        let folder = layout.chromeDirectory.appending(path: "chrome-155.0.8059.39")
        #expect(FileManager.default.isExecutableFile(atPath: folder.appending(path: "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing").path))
        #expect(installer.records()["chrome"]?.version == "155.0.8059.39")
        #expect(phases.value.contains { $0 > 0.5 && $0 < 1 }, "the megabytes it prints become progress: \(phases.value)")
        let status = BrowserEngineLocator.live(path: "/usr/bin", home: root, managedRoot: root).status(for: .chrome)
        #expect(status.isReady && status.browserExecutable?.hasPrefix(folder.path) == true)

        // A newer one replaces the old folder.
        let (again, _) = self.makeInstaller(workingRunner(chrome: "156.0.1.2"))
        try await again.install(.chrome, components: [.chrome])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.chromeDirectory.path) == ["chrome-156.0.1.2"])
        #expect(again.records()["chrome"]?.version == "156.0.1.2")
    }

    @Test func chromeNeedsAgentBrowserFirst() async throws {
        let (installer, _) = makeInstaller()
        await #expect(throws: BrowserInstallError.needsAgentBrowser) { try await installer.install(.chrome, components: [.chrome]) }
    }

    // MARK: CloakBrowser

    @Test func cloakGetsAVirtualEnvironmentThePackageAndItsChromium() async throws {
        let (installer, runner) = makeInstaller()
        let phases = LockedBox<[BrowserInstallProgress.Phase]>([])
        try await installer.install(.cloak, components: [.cloak]) { progress in
            if phases.value.last != progress.phase { phases.value.append(progress.phase) }
        }
        let calls = runner.calls
        #expect(calls.contains { $0.arguments.starts(with: ["-m", "venv"]) && $0.executable == "/usr/bin/python3" })
        let pip = try #require(calls.first { $0.arguments == ["-m", "pip", "install", "cloakbrowser"] })
        #expect(pip.environment["PYTHONNOUSERSITE"] == "1" && pip.environment["PIP_DISABLE_PIP_VERSION_CHECK"] == "1", "nothing of the user's own Python leaks in")
        #expect(pip.arguments.allSatisfy { $0 != "--user" }, "never into the user's Python")
        let download = try #require(calls.first { $0.arguments == ["-m", "cloakbrowser", "install"] })
        #expect(download.environment["CLOAKBROWSER_CACHE_DIR"]?.contains(BrowserInstallLayout.workPrefix) == true, "downloaded into the work folder")
        #expect(!calls.contains { $0.executable == "sudo" || $0.arguments.contains("sudo") })
        #expect(FileManager.default.isExecutableFile(atPath: layout.cloakPython.path))
        #expect(installer.records()["cloak"]?.version == "0.6.0" && installer.records()["cloak"]?.detail == "Chromium 145.0.7632.109.2")
        let status = BrowserEngineLocator.live(path: "/usr/bin", home: root, managedRoot: root).status(for: .cloak)
        #expect(status.browserExecutable == layout.cloakCache.appending(path: "chromium-145.0.7632.109.2/Chromium.app/Contents/MacOS/Chromium").path)
        #expect(phases.value.contains(.downloading) && phases.value.contains(.verifying) && phases.value.contains(.extracting), "\(phases.value)")
    }

    @Test func withoutAWorkingPythonTheMessageSaysWhatToDo() async throws {
        // The system's python3 is a stub until the Command Line Tools are installed: it is not asked about.
        let ran = LockedBox<[String]>([])
        let fake = FakeInstallRunner { call, _ in
            ran.value.append(call.executable + " " + call.arguments.joined(separator: " "))
            return call.executable == "/usr/bin/xcode-select" ? FakeInstallRunner.failed("xcode-select: error: unable to get active developer directory", status: 2) : nil
        }
        await #expect(throws: BrowserInstallError.self) { _ = try await BrowserInstaller.locatePython(run: fake.runner) }
        #expect(!ran.value.contains { $0.hasPrefix("/usr/bin/python3") }, "\(ran.value)")
        #expect(BrowserInstallError.needsCommandLineTools.errorDescription?.contains("xcode-select --install") == true)
        #expect(BrowserInstallError.noPython.errorDescription?.contains("Python 3.9") == true)

        let tools = FakeInstallRunner { call, _ in call.executable == "/usr/bin/python3" ? FakeInstallRunner.ok("") : nil }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            let python = try await BrowserInstaller.locatePython(run: tools.runner)
            #expect(FileManager.default.isExecutableFile(atPath: python))
        }
    }

    @Test func cloakThatNeedsAKeySaysSoInsteadOfFailingObscurely() async throws {
        // Everything but the download answers like the working runner.
        let working = workingRunner()
        let combined = FakeInstallRunner { call, output in
            if call.arguments == ["-m", "cloakbrowser", "install"] { return FakeInstallRunner.failed("CloakBrowserLicenseError: license key is invalid") }
            return try await working.handler(call, output)
        }
        let (installer, _) = makeInstaller(combined)
        await #expect(throws: BrowserInstallError.cloakNeedsKey) { try await installer.install(.cloak, components: [.cloak]) }
        #expect(!FileManager.default.fileExists(atPath: layout.cloakDirectory.path), "nothing half installed")
        #expect(BrowserInstallError.cloakNeedsKey.errorDescription?.contains("cloakbrowser.dev/free") == true)
    }

    // MARK: Cancelling, space, network

    @Test func cancellingStopsTheDownloadAndLeavesNothingBehind() async throws {
        try serveReleases()
        let started = LockedBox(false)
        network.beforeDownload = { _ in
            started.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let (installer, _) = makeInstaller()
        let task = Task { try await installer.install(.obscura) }
        while !started.value { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path) && installer.records().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(BrowserInstallLayout.workPrefix) })
    }

    @Test func aFullDiskIsToldBeforeAndAfterDownloading() async throws {
        try serveReleases()
        let (small, _) = makeInstaller(freeSpace: 10)
        await #expect(throws: BrowserInstallError.diskFull(needed: Int64(agentBinary.count) * 3)) { try await small.install(.chrome, components: [.agentBrowser]) }
        #expect(network.requests.filter { $0.contains("example.test") }.isEmpty, "nothing was downloaded")

        // The disk filled up in the middle.
        let working = workingRunner()
        let full = FakeInstallRunner { call, output in
            call.arguments == ["install"] ? FakeInstallRunner.failed("Error: No space left on device (os error 28)") : try await working.handler(call, output)
        }
        let (installer, _) = makeInstaller(full)
        try await installer.install(.chrome, components: [.agentBrowser])
        await #expect(throws: BrowserInstallError.diskFull(needed: nil)) { try await installer.install(.chrome, components: [.chrome]) }
        #expect(BrowserInstallError.diskFull(needed: 900_000_000).errorDescription?.contains("900 MB") == true)
        #expect(BrowserInstaller.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)) && BrowserInstaller.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(!BrowserInstaller.isOutOfSpace(CocoaError(.fileNoSuchFile)))
    }

    @Test func noNetworkIsToldAsSuch() async throws {
        network.offline = true
        let (installer, _) = makeInstaller()
        await #expect(throws: BrowserInstallError.noNetwork) { try await installer.install(.chrome) }
        #expect(BrowserInstallError.noNetwork.errorDescription?.contains("Sem conexão") == true)
        #expect(BrowserInstallError.rateLimited.errorDescription?.contains("GitHub") == true)
        #expect(URLSessionInstallNetwork.translate(URLError(.notConnectedToInternet)) as? BrowserInstallError == .noNetwork)
        #expect(URLSessionInstallNetwork.translate(URLError(.cancelled)) is CancellationError)

        func failure(_ text: String) -> BrowserInstallError { BrowserInstaller.commandFailure("X", FakeInstallRunner.failed(text)) }
        #expect(failure("pip._vendor.urllib3.exceptions.NewConnectionError: Failed to establish a new connection: [Errno 8] nodename nor servname provided") == .noNetwork)
        #expect(failure("Error: error sending request for url (https://storage.googleapis.com/x): dns error") == .noNetwork)
        #expect(failure("OSError: [Errno 28] No space left on device") == .diskFull(needed: nil))
        if case .failed("X", let detail) = failure("line one\nERROR: Could not find a version\n") { #expect(detail.contains("Could not find a version")) } else { Issue.record("generic failure") }
        #expect(BrowserInstaller.commandFailure("X", ProcessOutput(status: -1, signal: nil, output: "", timedOut: true)) == .failed("X", detail: "demorou demais e foi interrompido."))
    }

    // MARK: Removing

    @Test func removingAnEngineKeepsTheProfilesAndTheCommandForTheOthers() async throws {
        try serveReleases()
        let (installer, _) = makeInstaller()
        try await installer.install(.obscura)
        try await installer.install(.chrome)
        // The Orbs' logins.
        let orb = UUID()
        let profile = root.appending(path: "\(orb.uuidString)/chrome")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("login".utf8).write(to: profile.appending(path: "Cookies"))

        try installer.uninstall(.chrome)
        #expect(!installer.isInstalled(.chrome) && installer.records()["chrome"] == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.chromeDirectory.path))
        #expect(FileManager.default.fileExists(atPath: profile.appending(path: "Cookies").path), "the logins stay")
        #expect(installer.isInstalled(.obscura) && installer.isInstalled(.agentBrowser), "Obscura still needs agent-browser")

        try installer.uninstall(.obscura)
        #expect(!FileManager.default.fileExists(atPath: layout.obscura.path) && !FileManager.default.fileExists(atPath: layout.obscuraWorker.path))
        #expect(!FileManager.default.fileExists(atPath: layout.agentBrowser.path), "the last engine takes the command with it")
        #expect(installer.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: profile.appending(path: "Cookies").path))

        // Asked for, the profiles of that engine go (and the Orb's folder when it is left empty).
        installer.removeProfileFolders(of: .chrome)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: orb.uuidString).path))
    }

    @Test func removingWithProfilesOnlyTouchesThatEnginesProfiles() async throws {
        let orb = UUID()
        for engine in ["chrome", "cloak"] {
            let folder = root.appending(path: "\(orb.uuidString)/\(engine)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "f"))
        }
        let (installer, _) = makeInstaller()
        try installer.uninstall(.chrome, removeProfiles: true)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "\(orb.uuidString)/chrome").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(orb.uuidString)/cloak/f").path))
    }

    // MARK: Updates

    @Test func newerReleasesAreLookedForOnceADay() async throws {
        try serveReleases()
        network.serve(document: BrowserInstaller.chromeVersionsURL.absoluteString, #"{"channels":{"Stable":{"version":"156.0.1.1"}}}"#)
        network.serve(document: BrowserInstaller.cloakPackageURL.absoluteString, #"{"info":{"version":"0.6.0"}}"#)
        let (installer, _) = makeInstaller()
        try await installer.install(.chrome)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // A newer agent-browser and Chrome exist.
        network.serve(document: "https://api.github.com/repos/vercel-labs/agent-browser/releases/latest", FakeInstallNetwork.releaseJSON(
            tag: "v0.40.0", assets: [("agent-browser-darwin-arm64", agentBinary, true)]))
        let first = try await installer.checkForUpdates(now: start)
        #expect(first.latest["agentBrowser"] == "0.40.0" && first.latest["chrome"] == "156.0.1.1")
        #expect(installer.updatable(first) == [.agentBrowser, .chrome])
        let asked = network.requests.count

        // Within the day nothing is asked again; after it, it is.
        _ = try await installer.checkForUpdates(now: start.addingTimeInterval(3_600))
        #expect(network.requests.count == asked)
        _ = try await installer.checkForUpdates(now: start.addingTimeInterval(25 * 3_600))
        #expect(network.requests.count > asked)
        _ = try await installer.checkForUpdates(force: true, now: start.addingTimeInterval(25 * 3_600 + 5))
        #expect(BrowserUpdateCheck(checkedAt: start, latest: [:]).isDue(now: start.addingTimeInterval(86_400)))
        #expect(!BrowserUpdateCheck(checkedAt: start, latest: [:]).isDue(now: start.addingTimeInterval(86_399)))

        // Nothing newer: nothing to update.
        #expect(installer.updatable(BrowserUpdateCheck(checkedAt: start, latest: ["agentBrowser": "0.39.0", "chrome": "155.0.8059.39"])).isEmpty)
        // Not installed: never offered.
        #expect(!installer.updatable(BrowserUpdateCheck(checkedAt: start, latest: ["obscura": "9.9.9"])).contains(.obscura))
    }

    @Test func withoutNetworkTheLookForUpdatesKeepsWhatWasKnown() async throws {
        try serveReleases()
        let (installer, _) = makeInstaller()
        try await installer.install(.obscura)
        network.offline = true
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await #expect(throws: BrowserInstallError.self) { _ = try await installer.checkForUpdates(now: day) }
        #expect(BrowserInstaller.readUpdates(layout.updatesFile) == nil, "a look that reached nothing is not written down, so the next try is soon")
    }
}
