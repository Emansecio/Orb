import Foundation

// How an app can be controlled, known before the first try (`apps_list`): from its bundle only, no Apple Event and no
// Accessibility call, so listing apps stays as fast as before and never touches the app.

struct AppControlInfo: Sendable, Equatable {
    /// `NSAppleScriptEnabled` or an `OSAScriptingDefinition`: the app has an AppleScript dictionary.
    var scriptable: Bool
    /// What makes the app's Accessibility tree poor (Electron, Qt…); nil for a native app.
    var weakAccessibility: String?

    /// Reads the bundle at `url`. Cheap: one Info.plist and a look at the Frameworks and PlugIns folders.
    static func inspect(bundle url: URL) -> AppControlInfo {
        let plist = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist"))
        return AppControlInfo(scriptable: isScriptable(plist), weakAccessibility: weakness(of: url))
    }

    /// `NSAppleScriptEnabled` is a Boolean in most apps and "YES"/"Yes"/"true" text in others.
    static func isScriptable(_ plist: NSDictionary?) -> Bool {
        guard let plist else { return false }
        if let definition = plist["OSAScriptingDefinition"] as? String, !definition.isEmpty { return true }
        switch plist["NSAppleScriptEnabled"] {
        case let flag as Bool: return flag
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    /// Frameworks that draw their own interface and expose little of it to Accessibility. The Orb asks Electron and
    /// Chromium for `AXManualAccessibility`, but labels are often missing: `screenshot` helps there.
    static func weakness(of url: URL) -> String? {
        let frameworks = url.appending(path: "Contents/Frameworks")
        let fm = FileManager.default
        let signs: [(String, String)] = [("Electron Framework.framework", "Electron"),
                                         ("Chromium Embedded Framework.framework", "Chromium"),
                                         ("QtCore.framework", "Qt")]
        for (file, name) in signs where fm.fileExists(atPath: frameworks.appending(path: file).path) { return name }
        // Java: the old app bundler, JetBrains' own runtime (IntelliJ, Android Studio) and jpackage's.
        let java = ["Contents/Java", "Contents/MacOS/JavaAppLauncher", "Contents/jbr", "Contents/runtime/Contents/Home"]
        if java.contains(where: { fm.fileExists(atPath: url.appending(path: $0).path) }) { return "Java" }
        return nil
    }

    /// What a line of `apps_list` assumes when it says nothing: the header spells it out.
    static let usual = "AppleScript · AX bom"

    /// Only what departs from `usual`: ` · sem AppleScript`, ` · AX fraco (Electron)`, or both; empty for the usual.
    var summary: String {
        (scriptable ? "" : " · sem AppleScript") + (weakAccessibility.map { " · AX fraco (\($0))" } ?? "")
    }
}

/// Info by bundle path, kept while the bundle's Info.plist stays as it was (an update changes its date).
actor AppControlCache {
    static let shared = AppControlCache()
    private var entries: [String: (stamp: Date?, info: AppControlInfo)] = [:]

    func info(for url: URL) -> AppControlInfo {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.appending(path: "Contents/Info.plist").path))?[.modificationDate] as? Date
        if let hit = entries[url.path], hit.stamp == stamp { return hit.info }
        let info = AppControlInfo.inspect(bundle: url)
        if entries.count >= 300 { entries.removeAll() }
        entries[url.path] = (stamp, info)
        return info
    }
}

/// The user's Shortcuts names, asked once in a while: `shortcuts list` takes about 0.2 s, so `apps_list` does not pay for it every time.
actor ShortcutNamesCache {
    static let shared = ShortcutNamesCache()
    private var names: [String] = []
    private var loadedAt: Date?

    func current(ttl: TimeInterval = 300, load: @Sendable () async -> [String]? = ShortcutNamesCache.live) async -> [String] {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < ttl { return names }
        // A failure is remembered for a minute only, so a slow or locked Shortcuts does not cost 2 s on every call.
        let fresh = await load()
        // Parar in the middle is not Shortcuts failing: nothing is remembered, and the next call asks again.
        if Task.isCancelled, fresh == nil { return names }
        if let fresh {
            names = fresh
            loadedAt = Date()
        } else {
            // The names read before stay (a new cache has none): a failed reread does not hide what was known.
            loadedAt = Date().addingTimeInterval(60 - ttl)
        }
        return names
    }

    static func live() async -> [String]? {
        guard let result = try? await ProcessRunner.run("/usr/bin/shortcuts", ["list"], timeout: .seconds(2), outputLimit: 500_000),
              !result.timedOut, result.status == 0 else { return nil }
        return result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Shortcuts whose name has the app's name as a whole word, at most `limit`: "Abrir Spotify", "Spotify: pausar"; not
    /// "Email do dia" for Mail.
    static func matching(app: String, in names: [String], limit: Int = 3) -> [String] {
        let app = app.trimmingCharacters(in: .whitespaces)
        guard app.count >= 3 else { return [] }
        return Array(names.filter { hasWord(app, in: $0) }.prefix(limit))
    }

    private static func hasWord(_ word: String, in text: String) -> Bool {
        var from = text.startIndex
        while let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !(before?.isLetter ?? false) && !(before?.isNumber ?? false) && !(after?.isLetter ?? false) && !(after?.isNumber ?? false) {
                return true
            }
            from = text.index(after: found.lowerBound)
        }
        return false
    }
}
