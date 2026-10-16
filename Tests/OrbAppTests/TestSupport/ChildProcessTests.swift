import Foundation
import Testing
@testable import Orb

struct ChildProcessTests {
    @Test func droppingAChildReleasesTheReaderAndStopsTheProcess() async throws {
        var child: ChildProcess? = try ChildProcess(URL(filePath: "/bin/sh"), ["-c", "echo $$; exec /bin/sleep 30"])
        let released = { [weak child] in child == nil }
        guard await waitUntil("the child to report its pid", { child?.lines.first != nil }) else { return }
        let pid = try #require(child?.lines.first.flatMap(Int32.init))
        defer { kill(pid, SIGKILL) }
        child = nil
        // A callback already reading a line may still hold the child briefly.
        await waitUntil("the reader to release its owner", timeout: .seconds(5)) { released() }
        await waitUntil("the released child to stop") { !processIsAlive(pid) }
    }

    @Test func linesAndJSONRepliesAreReadWhileTheChildIsRunning() async throws {
        let child = try ChildProcess(URL(filePath: "/bin/cat"), [])
        child.sendLine("plain text")
        child.sendLine(#"{"id":7,"result":"ok"}"#)
        let reply = await child.waitForReply(7)
        #expect(reply?["result"]?.string == "ok")
        #expect(child.lines.first == "plain text")
        child.closeInput()
        #expect(await child.exit(within: .seconds(5)) == 0)
    }

    @Test func cancelledWaitsStopWithoutPollingUntilTheDeadline() async throws {
        let child = try ChildProcess(URL(filePath: "/bin/cat"), [])
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(await child.waitForReply(1, timeout: .seconds(30)) == nil)
            #expect(await child.exit(within: .seconds(30)) == nil)
        }
        await waiting.value
        // A cancelled exit wait kills the child; observe its actual termination separately.
        #expect(await child.exit(within: .seconds(5)) == SIGKILL)
    }
}
