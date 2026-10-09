import Foundation
import Testing
@testable import Orb

/// The app used to be OpenBot: its data folder and preferences are copied over once, never over newer Orb data.
@Suite(.serialized) final class LegacyMigrationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbMigration-\(UUID().uuidString)")
    var legacy: URL { root.appending(path: "OpenBot") }
    var directory: URL { root.appending(path: "Orb") }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func copiesDataAndPreferencesOnce() throws {
        try write(#"{"bots":[]}"#, to: legacy.appending(path: "state.json"), modified: .now)
        let defaults = Preferences()

        #expect(LegacyMigration.run(into: directory, from: legacy, oldPreferences: ["notifyWhenDone": false], into: defaults))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "state.json").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "state.json").path)) // backup stays
        #expect(defaults.object(forKey: "notifyWhenDone") as? Bool == false)
        // Second launch: already migrated.
        try write(#"{"bots":[1]}"#, to: legacy.appending(path: "state.json"), modified: .now + 60)
        #expect(!LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: defaults))
    }

    @Test func theLargeToolOutputsAreNotCopied() throws {
        try write(#"{"bots":[]}"#, to: legacy.appending(path: "state.json"), modified: .now)
        try write("{}", to: legacy.appending(path: "conversations/x.json"), modified: .now)
        try write("grande", to: legacy.appending(path: "saidas/orb/comando-1.txt"), modified: .now)

        #expect(LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: Preferences()))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "state.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversations/x.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "saidas").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: LegacyMigration.marker).path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "saidas/orb/comando-1.txt").path)) // the original stays
    }

    @Test func anOlderCopyIsRedoneAndSetAside() throws {
        try write("velho", to: directory.appending(path: "state.json"), modified: .now - 3600)
        try write("novo", to: legacy.appending(path: "state.json"), modified: .now)
        #expect(LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: Preferences()))
        #expect(try String(contentsOf: directory.appending(path: "state.json"), encoding: .utf8) == "novo")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Orb (antes da migração") }
        #expect(aside.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Orb.migrando").path))
    }

    @Test func newerOrbDataIsNeverReplaced() throws {
        try write("antigo", to: legacy.appending(path: "state.json"), modified: .now - 3600)
        try write("meu orb", to: directory.appending(path: "state.json"), modified: .now)
        #expect(!LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: Preferences()))
        #expect(try String(contentsOf: directory.appending(path: "state.json"), encoding: .utf8) == "meu orb")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: LegacyMigration.marker).path))
    }

    @Test func doesNothingWithoutOldData() throws {
        #expect(!LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: Preferences()))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func testsAndDevRunsNeverMigrate() {
        #expect(!LegacyMigration.shouldRun) // the test runner is not the app bundle
    }

    @Test func builtInSkillsSavedByOpenBotStayBuiltIn() throws {
        let json = #"{"slug":"resumir","name":"Resumir","source":"openbot"}"#
        let skill = try JSONDecoder().decode(Skill.self, from: Data(json.utf8))
        #expect(skill.source == Skill.builtInSource)
        let other = try JSONDecoder().decode(Skill.self, from: Data(#"{"slug":"x","name":"X","source":"github.com/a/b"}"#.utf8))
        #expect(other.source == "github.com/a/b")
    }
}

private final class Preferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
