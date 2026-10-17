import Foundation
import Testing
@testable import Orb

/// How `apps_list` tells the way to control each app: made-up bundles in a temporary folder, so no real app is touched.
struct AppControlInfoTests {
    private func bundle(_ plist: [String: Any], folders: [String] = [], files: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-control-\(UUID().uuidString)")
        let app = directory.appending(path: "Fake.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try (plist as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"))
        for folder in folders { try FileManager.default.createDirectory(at: app.appending(path: folder), withIntermediateDirectories: true) }
        for file in files {
            try FileManager.default.createDirectory(at: app.appending(path: file).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: app.appending(path: file))
        }
        return app
    }

    private func remove(_ app: URL) { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

    @Test func scriptabilityComesFromTheInfoPlist() throws {
        let cases: [(plist: [String: Any], scriptable: Bool)] = [
            ([:], false),
            (["NSAppleScriptEnabled": true], true),
            (["NSAppleScriptEnabled": "YES"], true),
            (["NSAppleScriptEnabled": "Yes"], true),
            (["NSAppleScriptEnabled": false], false),
            (["NSAppleScriptEnabled": "NO"], false),
            (["OSAScriptingDefinition": "Safari.sdef"], true),
            (["OSAScriptingDefinition": ""], false),
        ]
        for item in cases {
            let app = try bundle(item.plist)
            defer { remove(app) }
            #expect(AppControlInfo.inspect(bundle: app).scriptable == item.scriptable, "\(item.plist)")
        }
    }

    @Test func aNativeAppHasGoodAccessibilityAndFrameworksThatDrawTheirOwnInterfaceHaveNot() throws {
        let native = try bundle([:])
        let electron = try bundle([:], folders: ["Contents/Frameworks/Electron Framework.framework"])
        let qt = try bundle([:], folders: ["Contents/Frameworks/QtCore.framework"])
        let java = try bundle([:], folders: ["Contents/Java"])
        defer { [native, electron, qt, java].forEach(remove) }
        #expect(AppControlInfo.inspect(bundle: native).weakAccessibility == nil)
        #expect(AppControlInfo.inspect(bundle: electron).weakAccessibility == "Electron")
        #expect(AppControlInfo.inspect(bundle: qt).weakAccessibility == "Qt")
        #expect(AppControlInfo.inspect(bundle: java).weakAccessibility == "Java")
    }

    @Test func theSummaryIsOneShortPhrase() {
        #expect(AppControlInfo(scriptable: true, weakAccessibility: nil).summary == " · AppleScript · AX bom")
        #expect(AppControlInfo(scriptable: false, weakAccessibility: "Electron").summary == " · sem AppleScript · AX fraco (Electron)")
    }

    @Test func theListGainsTheWayToControlEachApp() {
        let spotify = RunningAppInfo(name: "Spotify", bundleID: "com.spotify.client", pid: 7, isActive: false, isHidden: false, isRegular: true)
        let plain = RunningAppInfo(name: "Calculadora", bundleID: "com.apple.calculator", pid: 8, isActive: true, isHidden: false, isRegular: true)
        let text = AppListFormatter.format([spotify, plain],
                                           control: [7: .init(scriptable: true, weakAccessibility: "Electron"), 8: .init(scriptable: false, weakAccessibility: nil)],
                                           shortcuts: ["Spotify": ["Spotify: pausar"]])
        #expect(text.contains("- Spotify (com.spotify.client) · pid 7 · AppleScript · AX fraco (Electron) · Atalhos: Spotify: pausar"))
        #expect(text.contains("- Calculadora (com.apple.calculator) · pid 8 · em primeiro plano · sem AppleScript · AX bom"))
        // Without the extras the line is what it always was.
        #expect(AppListFormatter.format([plain]).contains("pid 8 · em primeiro plano") && !AppListFormatter.format([plain]).contains("AX"))
    }

    @Test func shortcutsAreMatchedByTheAppNameIgnoringCaseAndAccents() {
        let names = ["Abrir spotify", "Pausar Spotify", "Café rápido", "Relatório", "Música: tocar", "a", "Spotify 3", "Spotify 4"]
        #expect(ShortcutNamesCache.matching(app: "Spotify", in: names) == ["Abrir spotify", "Pausar Spotify", "Spotify 3"])
        #expect(ShortcutNamesCache.matching(app: "Musica", in: names) == ["Música: tocar"])
        #expect(ShortcutNamesCache.matching(app: "Ab", in: names).isEmpty, "a two-letter name matches too much")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func theShortcutNamesAreAskedOnceWhileFreshAndAFailureIsNotRetriedAtOnce() async {
        let calls = Calls()
        let cache = ShortcutNamesCache()
        let first = await cache.current(load: { calls.bump(); return ["A"] })
        let second = await cache.current(load: { calls.bump(); return ["B"] })
        #expect(first == ["A"] && second == ["A"] && calls.count == 1)

        let failing = ShortcutNamesCache()
        let none = await failing.current(load: { calls.bump(); return nil })
        let again = await failing.current(load: { calls.bump(); return ["late"] })
        #expect(none.isEmpty && again.isEmpty && calls.count == 2, "a failure is remembered for a minute")

        let expired = ShortcutNamesCache()
        _ = await expired.current(ttl: 0, load: { ["old"] })
        #expect(await expired.current(ttl: 0, load: { ["new"] }) == ["new"])
    }

    @Test func theInfoIsCachedUntilTheInfoPlistChanges() async throws {
        let app = try bundle(["NSAppleScriptEnabled": false])
        defer { remove(app) }
        let cache = AppControlCache()
        #expect(await cache.info(for: app).scriptable == false)
        try ("""
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>NSAppleScriptEnabled</key><true/></dict></plist>
            """).write(to: app.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: app.appending(path: "Contents/Info.plist").path)
        #expect(await cache.info(for: app).scriptable, "an updated Info.plist is read again")
    }

    /// The real list of apps: only reads (the running apps and their Info.plist), and it must stay fast.
    @Test func theRealListStaysFast() async throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let tool = AppsListTool()
        let clock = ContinuousClock()
        var text = ""
        let cold = try await clock.measure { text = try await tool.run(.object([:]), context: context) }
        let warm = try await clock.measure { _ = try await tool.run(.object([:]), context: context) }
        print("apps_list: frio \(cold), quente \(warm), \(text.split(separator: "\n").count) linhas")
        #expect(text.contains("AX bom") || text.contains("AX fraco") || text == "Nenhum app aberto.")
        // Only a ceiling that a loaded machine keeps too; the measured times (0,19 s cold, 25 ms after) are in the REVISAO.
        #expect(cold < .seconds(10) && warm < .seconds(3))
    }
}
