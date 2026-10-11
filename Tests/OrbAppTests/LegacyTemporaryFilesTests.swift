import Foundation
import Testing
@testable import Orb

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
