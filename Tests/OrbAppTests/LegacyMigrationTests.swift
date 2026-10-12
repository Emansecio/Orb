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
        let defaults = FakePreferences()

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

        #expect(LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: FakePreferences()))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "state.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversations/x.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "saidas").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: LegacyMigration.marker).path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "saidas/orb/comando-1.txt").path)) // the original stays
    }

    @Test func anOlderCopyIsRedoneAndSetAside() throws {
        try write("velho", to: directory.appending(path: "state.json"), modified: .now - 3600)
        try write("novo", to: legacy.appending(path: "state.json"), modified: .now)
        #expect(LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: FakePreferences()))
        #expect(try String(contentsOf: directory.appending(path: "state.json"), encoding: .utf8) == "novo")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Orb (antes da migração") }
        #expect(aside.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Orb.migrando").path))
    }

    @Test func newerOrbDataIsNeverReplaced() throws {
        try write("antigo", to: legacy.appending(path: "state.json"), modified: .now - 3600)
        try write("meu orb", to: directory.appending(path: "state.json"), modified: .now)
        #expect(!LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: FakePreferences()))
        #expect(try String(contentsOf: directory.appending(path: "state.json"), encoding: .utf8) == "meu orb")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: LegacyMigration.marker).path))
    }

    @Test func doesNothingWithoutOldData() throws {
        #expect(!LegacyMigration.run(into: directory, from: legacy, oldPreferences: [:], into: FakePreferences()))
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

struct LegacyTemporaryFilesTests {
    @Test func aDeadOwnersConnectorConfigGoesAndALiveOwnersStays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owned-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let me = ProcessInfo.processInfo.processIdentifier
        let alive = folder.appendingPathComponent("orb-mcp-p\(me)-A.json"), dead = folder.appendingPathComponent("orb-mcp-p2000000000-B.json")
        let nameless = folder.appendingPathComponent("orb-mcp-C.json")
        for url in [alive, dead, nameless] { try Data("{}".utf8).write(to: url) }
        // Old enough to be stale by age: only the one with no owner in its name goes by it.
        let long = Date(timeIntervalSinceNow: -3600)
        for url in [alive, dead, nameless] { try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: url.path) }
        #expect(LegacyTemporaryFiles.removeStaleMCPConfigs(in: folder) == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [alive.lastPathComponent])
    }

    @Test func staleConnectorConfigsAreRemovedOnlyWhenOld() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stale-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Names without a process (older versions) go by age.
        let old = folder.appendingPathComponent("orb-mcp-A.json"), fresh = folder.appendingPathComponent("orb-mcp-B.json")
        let other = folder.appendingPathComponent("outro.json"), notes = folder.appendingPathComponent("orb-mcp-notes.txt")
        for url in [old, fresh, other, notes] { try Data("{}".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        #expect(LegacyTemporaryFiles.removeStaleMCPConfigs(in: folder) == 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["orb-mcp-B.json", "outro.json", "orb-mcp-notes.txt"])
        // Everything of ours goes once it is old enough, whatever its name after the prefix.
        #expect(LegacyTemporaryFiles.removeStaleMCPConfigs(in: folder, now: .now.addingTimeInterval(600)) == 1)
        #expect(LegacyTemporaryFiles.removeStaleMCPConfigs(in: folder.appendingPathComponent("nao-existe")) == 0)
    }
}
