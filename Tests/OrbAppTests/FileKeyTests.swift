import Foundation
import Testing
@testable import Orb

/// A file is the same file to the gate, the writer queues and the seals whether or not it exists yet. (A conversation
/// read could wait forever for a write that was registered under one spelling of its path and finished under another.)
struct FileKeyTests {
    @Test func theKeyDoesNotDependOnTheFileSystem() throws {
        // `/private/tmp` is where `/tmp` really lives: `standardizedFileURL` dropped the prefix only once the file existed.
        let folder = URL(fileURLWithPath: "/private/tmp/OrbFileKey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.meta.json")
        let before = FileKey.of(file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        #expect(FileKey.of(file) == before)
        #expect(FileKey.of(URL(fileURLWithPath: "/tmp/x/../y/./z.json")) == "/tmp/y/z.json")
        #expect(FileKey.of(URL(fileURLWithPath: "/private/tmp/y/z.json")) == "/tmp/y/z.json")
        #expect(FileKey.of(URL(fileURLWithPath: "/private/var/folders/a")) == "/var/folders/a")
        #expect(FileKey.of(URL(fileURLWithPath: "/private/other/a")) == "/private/other/a")
    }

    @Test func aWriteRegisteredBeforeTheFileExistedIsFinishedWhenItDoes() throws {
        let gate = FileGate()
        let folder = URL(fileURLWithPath: "/private/tmp/OrbGate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.meta.json")
        gate.willWrite([file])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        gate.didWrite([file])
        #expect(gate.queuedWrites(containing: folder.lastPathComponent) == 0)
    }

    @Test func aFirstLaunchLeavesNoWriteQueuedForever() async throws {
        // A data folder that does not exist yet, under a path whose spelling the file system rewrites (the case that
        // left the first conversation of a developer run stuck on "Carregando a conversa").
        let folder = URL(fileURLWithPath: "/private/tmp/OrbFirstLaunch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder)
        let botID = UUID()
        var conversation = Conversation()
        conversation.items = [TranscriptItem(.user(text: "oi", attachments: []))]
        // The note is written after the first read, the save from another thread meanwhile: both finish.
        store.save(conversation, for: botID)
        store.flush()
        let reads = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask { await store.readConversationAsync(botID).value != nil }
                group.addTask { await store.readMetaAsync(botID) != nil }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        store.flush()
        #expect(reads.count == 12)
        #expect(Store.gate.queuedWrites(containing: folder.lastPathComponent) == 0)
    }
}
