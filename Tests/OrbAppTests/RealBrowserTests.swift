import Foundation
import Testing
@testable import Orb

// Tests against the real browser. Nothing here runs without it: the installation test needs an environment variable, and the
// smoke tests run only when `agent-browser` and a Chrome (or Brave) are found (in the app's own `navegador` folder, or anywhere the
// locator looks). CI has none of them. Set ORB_SKIP_REAL_BROWSER_TESTS=1 to leave them out on a Mac that has them. Real browsers
// run headless here, so they never take the focus of the Mac. The measurements that chose this browser are in
// docs/REVISAO-NAVEGADOR-2026-10-16.md.

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

    static let locator = BrowserLocator.live(path: environment["PATH"], managedRoot: root)

    static func status() -> BrowserStatus { locator.status() }

    /// Whether the browser can be started on this Mac.
    static var isReady: Bool { !skipped && status().isReady }

    /// What `ORB_INSTALL_BROWSERS` asks to install ("agent-browser,chrome", or "all").
    static var toInstall: [BrowserComponent] {
        let wanted = (environment["ORB_INSTALL_BROWSERS"] ?? "").lowercased()
        if wanted == "all" || wanted == "1" { return BrowserComponent.allCases }
        return wanted.split(separator: ",").compactMap { text in
            let name = text.trimmingCharacters(in: .whitespaces)
            return BrowserComponent.allCases.first { $0.rawValue == name || ($0 == .chrome && name == "chrome") }
        }
    }
}

/// Installs the components for real, with the installer the app uses, into the app's own folder. Needs the network and downloads
/// up to 200 MB: only with `ORB_INSTALL_BROWSERS=all` (or a list: `agentBrowser,chrome`).
struct RealBrowserInstallTests {
    @Test(.enabled(if: !RealBrowsers.toInstall.isEmpty), .timeLimit(.minutes(30)))
    func installsTheRequestedComponentsWithTheAppsInstaller() async throws {
        let installer = BrowserInstaller(layout: BrowserInstallLayout(root: RealBrowsers.root))
        let started = Date()
        let last = LockedBox<String>("")
        try await installer.install(RealBrowsers.toInstall) { progress in
            let line = "[\(progress.component.rawValue)] \(progress.text)"
            if line != last.value, progress.phase != .downloading || progress.received == 0 { print(line) }
            last.value = line
        }
        print("pronto em \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
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
