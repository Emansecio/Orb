import Foundation
import Testing
@testable import Orb

// Tests against real browsers. Nothing here runs without the browsers: the installation test needs an environment variable, and the
// smoke tests of an engine run only when that engine is installed (in the app's own `navegador` folder, or anywhere the locator
// looks). CI has none of them. Set ORB_SKIP_REAL_BROWSER_TESTS=1 to leave them out on a Mac that has them.
//
// Measured on an Apple silicon Mac (Wi-Fi, October 2026). "Cold" is the first command of a session, which starts the browser; the very
// first launch of a Chrome or Chromium after it is installed is slower (macOS checks it: about 4 s for Chrome and CloakBrowser).
//
//                                  Chrome for Testing 155   Obscura 0.2.4 (stealth)   CloakBrowser (Chromium 145)
//   cold start + open (local page)        1.1 s                  0.25 s                    1.2 s
//   cold start + open (example.com)       0.9 s                  0.4 s                     1.0 s
//   open again (example.com)              0.09 s                 0.07 s                    0.35 s
//   snapshot / read                       0.01-0.02 s            0.01-0.02 s               0.01-0.02 s
//   screenshot                            0.05 s                 0.02 s                    0.27 s
//   back                                  0.55 s                 0.55 s                    0.65 s
//   headed window (browse_show) / back    2.0 s / 2.5 s          not available             4.1 s / 2.2 s
//   web_search (DuckDuckGo / Google)      2.0 s / 2.2 s          1.3 s / blocked           2.0-3.0 s / 2.4 s
//   quit (close of an open browser)       about 1-2 s            about 1 s                 1.8 s
//   install (agent-browser already there) 11 s (180 MB)          5 s (70 MB, with agent)   17 s (venv + 140 MB Chromium)
//
// On disk: bin/ 156 MB (agent-browser 16, obscura 75, obscura-worker 72), chrome/ 362 MB, cloak/ 509 MB (venv 157, Chromium 352).

enum RealBrowsers {
    static let environment = ProcessInfo.processInfo.environment

    /// The `navegador` folder the real engines live in: `ORB_BROWSER_ROOT`, else the app's own data folder.
    static let root: URL = {
        if let own = environment["ORB_BROWSER_ROOT"], !own.isEmpty { return URL(fileURLWithPath: own) }
        return DevRun.currentDataFolder.url.appending(path: "navegador")
    }()

    /// The tests that start real browsers take turns (they look at the processes of the same folder).
    static let gate = RealBrowserGate()

    static let skipped = environment["ORB_SKIP_REAL_BROWSER_TESTS"] == "1"

    static let locator = BrowserEngineLocator.live(path: environment["PATH"], managedRoot: root)

    static func status(_ engine: BrowserEngineKind) -> BrowserEngineStatus { locator.status(for: engine) }

    /// Whether the engine can be started on this Mac.
    static func isReady(_ engine: BrowserEngineKind) -> Bool { !skipped && status(engine).isReady }

    /// The engines `ORB_INSTALL_BROWSERS` asks to install ("chrome,obscura,cloak", or "all").
    static var toInstall: [BrowserEngineKind] {
        let wanted = (environment["ORB_INSTALL_BROWSERS"] ?? "").lowercased()
        if wanted == "all" || wanted == "1" { return [.chrome, .obscura, .cloak] }
        return wanted.split(separator: ",").compactMap { BrowserEngineKind(rawValue: String($0.trimmingCharacters(in: .whitespaces))) }
    }
}

/// Installs the engines for real, with the installer the app uses, into the app's own folder. Needs the network and downloads
/// about 300 MB: only with `ORB_INSTALL_BROWSERS=all` (or a list: `chrome,obscura`).
struct RealBrowserInstallTests {
    @Test(.enabled(if: !RealBrowsers.toInstall.isEmpty), .timeLimit(.minutes(30)))
    func installsTheRequestedEnginesWithTheAppsInstaller() async throws {
        let installer = BrowserInstaller(layout: BrowserInstallLayout(root: RealBrowsers.root))
        for engine in RealBrowsers.toInstall {
            let started = Date()
            let last = LockedBox<String>("")
            try await installer.install(engine) { progress in
                let line = "[\(engine.rawValue)] \(progress.text)"
                if line != last.value, progress.phase != .downloading || progress.received == 0 { print(line) }
                last.value = line
            }
            let seconds = Date().timeIntervalSince(started)
            print("[\(engine.rawValue)] pronto em \(String(format: "%.1f", seconds)) s")
            let status = RealBrowsers.status(engine)
            #expect(status.isReady, "\(engine): \(status.userMessage ?? "")")
            #expect(installer.hasEverythingInstalled(for: engine))
        }
        let records = installer.records()
        for (name, record) in records.sorted(by: { $0.key < $1.key }) { print("instalado \(name) \(record.version) \(record.detail ?? "")") }
    }
}

/// One turn at a time. A holder that never gives the turn back (its test was cut short by the time limit) loses it after four minutes,
/// so one stuck test cannot hold up all the others.
actor RealBrowserGate {
    private var heldSince: Date?

    /// The real browsers start only when the rest of the suite has had its twenty seconds: Chrome windows and processes starting
    /// beside three thousand tests make the ones that wait on a clock (a process that must end in 3 s) fail now and then.
    static let quietAfter: TimeInterval = 30

    func lock() async {
        while let age = Self.processAge(), age < Self.quietAfter { try? await Task.sleep(for: .milliseconds(500)) }
        while let since = heldSince, Date().timeIntervalSince(since) < 240 { try? await Task.sleep(for: .milliseconds(100)) }
        heldSince = Date()
    }

    func unlock() { heldSince = nil }

    /// Seconds since this process started (nil when the system will not say).
    static func processAge() -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
