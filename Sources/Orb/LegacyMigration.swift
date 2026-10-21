import Foundation

/// The app used to be called OpenBot. When the real app (bundle `app.orb.mac`, not a dev run) opens as Orb, it copies
/// OpenBot's data folder (Orbs, conversations, routines, skills) and preferences over. Keychain items (API keys,
/// sign-ins) are copied one by one when first used (`Keychain.get`), so there is no burst of password prompts at launch.
/// The originals stay where they were, as a backup; an account that was copied, or whose key was removed or replaced
/// in Orb, is noted (`LegacyKeychainLedger`) and its original is not looked at again.
enum LegacyMigration {
    static let oldFolder = "OpenBot"
    static let oldIdentifier = "app.openbot.mac"
    static let identifier = "app.orb.mac"
    /// The folder of large tool outputs, which is not copied (see `ToolOutputCap`).
    static let skipped = "saidas"
    /// Written into Orb's data folder once the copy is done.
    static let marker = ".migrado-do-openbot"

    /// Whether this process should migrate: the bundled app on a normal launch (dev runs such as `--render-icon`
    /// from scripts/bundle.sh or `--snapshot` must not touch the user's data).
    static var shouldRun: Bool {
        Bundle.main.bundleIdentifier == identifier
            && !DevRun.isActive
    }

    /// Copies OpenBot's folder into `directory` unless Orb already has data at least as new (an earlier copy, or
    /// you already used Orb). An older copy (e.g. made before you kept using OpenBot) is set aside next to it, not
    /// deleted. The copy goes through a temporary folder, so a failure halfway leaves nothing behind and is retried
    /// on the next launch. Returns whether the folder was copied.
    @discardableResult
    static func run(into directory: URL, from legacy: URL,
                    oldPreferences: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldIdentifier),
                    into defaults: any PreferenceStore = UserDefaults.standard, now: Date = .now) -> Bool {
        let files = FileManager.default
        let legacyState = legacy.appending(path: "state.json"), state = directory.appending(path: "state.json")
        guard !files.fileExists(atPath: directory.appending(path: marker).path),
              files.fileExists(atPath: legacyState.path) else { return false }
        if files.fileExists(atPath: state.path), modified(state) >= modified(legacyState) {
            files.createFile(atPath: directory.appending(path: marker).path, contents: nil)
            return false
        }
        let staging = directory.deletingLastPathComponent().appending(path: directory.lastPathComponent + ".migrando")
        try? files.removeItem(at: staging)
        do {
            // Item by item, without the large tool outputs (`saidas/`): they are cleaned by age anyway and can be the
            // bulk of the folder. The original stays where it was.
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in try files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) where item.lastPathComponent != skipped {
                try files.copyItem(at: item, to: staging.appending(path: item.lastPathComponent))
            }
            if files.fileExists(atPath: directory.path) {
                let format = DateFormatter.make(locale: "en_US_POSIX", format: "yyyy-MM-dd HH.mm")
                let aside = directory.deletingLastPathComponent()
                    .appending(path: "\(directory.lastPathComponent) (antes da migração \(format.string(from: now)))")
                try files.moveItem(at: directory, to: aside)
            }
            try files.moveItem(at: staging, to: directory)
        } catch {
            try? files.removeItem(at: staging)
            NSLog("Orb: não foi possível copiar os dados do OpenBot: \(error)")
            return false
        }
        files.createFile(atPath: directory.appending(path: marker).path, contents: nil)
        for (key, value) in oldPreferences ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        return true
    }

    private static func modified(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }
}

/// Where migrated preferences go (UserDefaults; tests use a dictionary, so they leave no .plist behind).
protocol PreferenceStore {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}
