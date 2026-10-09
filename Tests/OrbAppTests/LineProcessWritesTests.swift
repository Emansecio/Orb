import Foundation
import os
import Testing
@testable import Orb

// A child that does not read its stdin must not block whoever writes to it: `send` and `closeInput` run on the main thread
// when a Claude Code turn is cancelled (Stop, or quitting).

struct LineProcessWritesTests {
    private let environment = ["PATH": "/usr/bin:/bin"]

    @Test func writingToAChildThatDoesNotReadNeverBlocksTheCaller() async throws {
        let process = try LineProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"],
                                      directory: FileManager.default.temporaryDirectory, environment: environment)
        defer { process.terminate(after: 0) }
        let returned = OSAllocatedUnfairLock(initialState: false)
        // On a thread of its own, so a blocked call fails the test instead of hanging it.
        Thread.detachNewThread {
            process.send(String(repeating: "x", count: 256_000)) // more than a pipe holds
            process.send("y")
            process.closeInput()
            returned.withLock { $0 = true }
        }
        for _ in 0..<250 where !returned.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(returned.withLock { $0 }, "send / closeInput blocked on a full pipe")
    }

    @Test func linesReachTheChildInOrderAndTheEndOfInputFollows() async throws {
        let process = try LineProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                      directory: FileManager.default.temporaryDirectory, environment: environment)
        process.send("um")
        process.send("dois")
        process.send("três")
        process.closeInput()
        process.send("depois do fim") // ignored
        var lines: [String] = []
        for await line in process.lines { lines.append(line) }
        #expect(lines == ["um", "dois", "três"])
    }
}
