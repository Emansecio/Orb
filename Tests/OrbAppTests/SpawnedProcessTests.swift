import Foundation
import os
import Testing
@testable import Orb

// `SpawnedProcess.watch` must report every child's end without keeping a thread of the global queues for each one.

struct SpawnedProcessTests {
    private func spawn(_ executable: String, _ arguments: [String]) throws -> pid_t {
        let null = FileHandle(forWritingAtPath: "/dev/null")!
        defer { try? null.close() }
        return try SpawnedProcess.start(executable, arguments, directory: nil, environment: nil, output: null.fileDescriptor)
    }

    private final class Exits: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [ChildExit]())
        var all: [ChildExit] { state.withLock { $0 } }
        func add(_ exit: ChildExit) { state.withLock { $0.append(exit) } }
    }

    @Test func manyLongLivedChildrenDoNotStarveTheGlobalQueues() async throws {
        let exits = Exits()
        let pids = try (0..<100).map { _ in try spawn("/bin/sleep", ["30"]) }
        defer { pids.forEach { kill(-$0, SIGKILL) } }
        pids.forEach { SpawnedProcess.watch($0) { exits.add($0) } }

        // A block on the same queues the watchers used to wait on must still run.
        let ran = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).async { ran.withLock { $0 = true } }
        for _ in 0..<250 where !ran.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ran.withLock { $0 }, "the global queue is full of threads waiting for children")

        pids.forEach { kill(-$0, SIGKILL) }
        await waitUntil("every exit to be reported", timeout: .seconds(5)) { exits.all.count == 100 }
        #expect(exits.all.allSatisfy { $0.signaled && $0.status == SIGKILL })
    }

    @Test func aChildThatEndedBeforeWatchingIsStillReportedOnce() async throws {
        let exits = Exits()
        let pid = try spawn("/usr/bin/true", [])
        try await Task.sleep(for: .milliseconds(200))
        SpawnedProcess.watch(pid) { exits.add($0) }
        await waitUntil("the exit to be reported") { !exits.all.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(exits.all == [ChildExit(status: 0, signaled: false)])
    }

    /// An environment the system cannot take is refused before anything starts (and the arguments copied for it are freed).
    @Test func aNullByteInTheEnvironmentIsRefused() throws {
        let null = FileHandle(forWritingAtPath: "/dev/null")!
        defer { try? null.close() }
        let error = try #require(#expect(throws: ToolError.self) {
            _ = try SpawnedProcess.start("/bin/echo", ["oi"], directory: nil, environment: ["X": "a\u{0}b"], output: null.fileDescriptor)
        })
        #expect(error.message.contains("byte nulo"))
    }

    @Test func theExitCodeIsReported() async throws {
        let exits = Exits()
        SpawnedProcess.watch(try spawn("/bin/sh", ["-c", "exit 7"])) { exits.add($0) }
        await waitUntil("the exit to be reported") { !exits.all.isEmpty }
        #expect(exits.all == [ChildExit(status: 7, signaled: false)])
    }
}
