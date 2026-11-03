import Foundation
import Testing
@testable import Orb

// A write over a file that changed since the Orb read it is refused; no record, no refusal.

final class FileStampsTests {
    let workspace: ToolWorkspace
    let stamps = FileStamps()
    let context: ToolContext

    init() throws {
        workspace = try ToolWorkspace()
        var context = workspace.context
        context.stamps = stamps
        self.context = context
    }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: context)
    }

    private func failure(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async -> String {
        do {
            _ = try await run(tool, arguments)
            return ""
        } catch {
            return (error as? ToolError)?.message ?? "\(error)"
        }
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: workspace.directory.appending(path: name), encoding: .utf8)
    }

    /// Another writer: new content and a modification date that cannot be mistaken for the old one.
    private func changeElsewhere(_ name: String, to text: String) throws {
        let url = workspace.directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: url.path)
    }

    @Test func aWriteAfterSomeoneElseChangedTheFileIsRefused() async throws {
        try workspace.write("a.txt", "um\n")
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        try changeElsewhere("a.txt", to: "do outro\n")
        let message = await failure(WriteFileTool(), ["path": .string("a.txt"), "content": .string("meu\n")])
        #expect(message.contains("changed since you last read it") && message.contains("Read it again before writing."))
        #expect(try text("a.txt") == "do outro\n")
        // Reading again lets it write.
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        _ = try await run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("meu\n")])
        #expect(try text("a.txt") == "meu\n")
    }

    @Test func anEditAfterSomeoneElseChangedTheFileIsRefused() async throws {
        try workspace.write("a.txt", "um dois\n")
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        try changeElsewhere("a.txt", to: "um dois três\n")
        let message = await failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("dois"), "new_text": .string("2")])
        #expect(message.contains("changed since you last read it"))
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        _ = try await run(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("dois"), "new_text": .string("2")])
        #expect(try text("a.txt") == "um 2 três\n")
    }

    @Test func aFreshReadAndTheOrbsOwnWritesAllowTheNextWrite() async throws {
        try workspace.write("a.txt", "um\n")
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        _ = try await run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("dois\n")])
        _ = try await run(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("dois"), "new_text": .string("três")])
        #expect(try text("a.txt") == "três\n")
        _ = try await run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("x"), "append": .bool(true)])
        #expect(try text("a.txt") == "três\nx")
    }

    @Test func aFileTheOrbNeverReadIsWrittenAsBefore() async throws {
        try workspace.write("a.txt", "um\n")
        _ = try await run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("dois\n")])
        _ = try await run(WriteFileTool(), ["path": .string("novo.txt"), "content": .string("n")])
        try workspace.write("b.txt", "b\n")
        _ = try await run(EditFileTool(), ["path": .string("b.txt"), "old_text": .string("b"), "new_text": .string("c")])
        #expect(try text("b.txt") == "c\n")
    }

    @Test func aContextWithoutRecordsNeverRefuses() async throws {
        try workspace.write("a.txt", "um\n")
        _ = try await workspace.run(ReadFileTool(), ["path": .string("a.txt")])
        try changeElsewhere("a.txt", to: "outro\n")
        _ = try await workspace.run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("meu\n")])
        #expect(try text("a.txt") == "meu\n")
    }

    @Test func aFileThatWasDeletedIsWrittenAgain() async throws {
        try workspace.write("a.txt", "um\n")
        _ = try await run(ReadFileTool(), ["path": .string("a.txt")])
        try FileManager.default.removeItem(at: workspace.directory.appending(path: "a.txt"))
        _ = try await run(WriteFileTool(), ["path": .string("a.txt"), "content": .string("de novo\n")])
        #expect(try text("a.txt") == "de novo\n")
    }

    @Test func aFailedReadLeavesNoRecord() async throws {
        let message = await failure(ReadFileTool(), ["path": .string("nao-existe.txt")])
        #expect(!message.isEmpty)
        _ = try await run(WriteFileTool(), ["path": .string("nao-existe.txt"), "content": .string("a")])
    }

    @Test func onlyTheNewestFiveHundredPathsAreKept() throws {
        let first = workspace.directory.appending(path: "primeiro.txt"), last = workspace.directory.appending(path: "ultimo.txt")
        try workspace.write("primeiro.txt", "1")
        try workspace.write("ultimo.txt", "2")
        let wrong = FileStamps.Stamp(modified: .distantPast, size: -1) // any real file differs from it
        stamps.record(first, stamp: wrong)
        for index in 0..<(FileStamps.limit - 1) { stamps.record(URL(fileURLWithPath: "/nada/\(index)"), stamp: wrong) }
        #expect(throws: ToolError.self) { try stamps.check(first) } // 500 paths: still kept
        stamps.record(last, stamp: wrong) // the 501st pushes the oldest out
        #expect(throws: ToolError.self) { try stamps.check(last) }
        try stamps.check(first)
    }

    @Test func recordingAPathAgainMakesItTheNewest() throws {
        let first = workspace.directory.appending(path: "primeiro.txt")
        try workspace.write("primeiro.txt", "1")
        let wrong = FileStamps.Stamp(modified: .distantPast, size: -1)
        stamps.record(first, stamp: wrong)
        for index in 0..<(FileStamps.limit - 1) { stamps.record(URL(fileURLWithPath: "/nada/\(index)"), stamp: wrong) }
        stamps.record(first, stamp: wrong) // seen again: no longer the oldest
        stamps.record(URL(fileURLWithPath: "/nada/extra"), stamp: wrong)
        #expect(throws: ToolError.self) { try stamps.check(first) }
    }
}
