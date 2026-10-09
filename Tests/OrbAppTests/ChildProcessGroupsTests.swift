import Foundation
import Testing
@testable import Orb

// Quitting the app must not leave Claude Code or a foreground command running: they lead groups of their own, so
// only `ChildProcessGroups` reaches them. The tests share the process with others that start children, so each one only
// touches the pids it started itself.

struct ChildProcessGroupsTests {
    @Test func killAllStopsTheGroupsItKnows() async throws {
        let null = FileHandle(forWritingAtPath: "/dev/null")!
        defer { try? null.close() }
        let pid = try SpawnedProcess.start("/bin/sleep", ["60"], directory: nil, environment: nil, output: null.fileDescriptor)
        ChildProcessGroups.insert(pid)
        SpawnedProcess.watch(pid) { _ in ChildProcessGroups.remove(pid) }
        #expect(ChildProcessGroups.running.contains(pid))

        ChildProcessGroups.killAllNow(only: [pid])

        await waitUntil("the group to be gone", timeout: .seconds(2)) { kill(-pid, 0) != 0 }
        await waitUntil("the list to forget it") { !ChildProcessGroups.running.contains(pid) }
    }

    @Test func aLineProcessIsKnownWhileItRunsAndForgottenAfter() async throws {
        let line = try LineProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                   directory: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment)
        #expect(ChildProcessGroups.running.contains(line.pid))
        line.closeInput() // cat ends at the end of its input
        await waitUntil("the list to forget it") { !ChildProcessGroups.running.contains(line.pid) }
    }

    @Test func aForegroundCommandIsKnownWhileItRuns() async throws {
        let argument = "61.\(Int.random(in: 100_000...999_999))" // makes the command line this test's own
        let command = Task { try await ProcessRunner.run("/bin/sleep", [argument], timeout: .seconds(120)) }
        defer { command.cancel() }
        var pid: pid_t?
        await waitUntil("the command to be listed") {
            let found = try? await ProcessRunner.run("/usr/bin/pgrep", ["-f", "sleep \(argument)"], timeout: .seconds(10))
            pid = found?.output.split(whereSeparator: \.isNewline).first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            return pid != nil
        }
        let known = try #require(pid)
        #expect(ChildProcessGroups.running.contains(known))

        command.cancel() // stops its own group
        _ = try? await command.value
        await waitUntil("the list to forget it") { !ChildProcessGroups.running.contains(known) }
    }
}
