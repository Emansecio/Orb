import Foundation
import Testing
@testable import Orb

// The request loop of the stdio MCP servers: calls run side by side, `notifications/cancelled` stops one, and closing
// stdin or SIGTERM stops all, after the takeovers (which put the screen back) have finished.

private final class LoopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    func note(_ event: String) { lock.withLock { events.append(event) } }
    func has(_ event: String) -> Bool { all.contains(event) }
}

private final class LoopOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    var lines: [String] { lock.withLock { written } }
    func add(_ line: String) { lock.withLock { written.append(line) } }
    /// The parsed replies, by id.
    var replies: [JSONValue] { lines.compactMap(JSONValue.parse) }
    func reply(id: JSONValue) -> JSONValue? { replies.first { $0["id"] == id } }
}

private struct FakeHandler: MCPServerHandler {
    let recorder: LoopRecorder
    var serverName: String { "fake" }
    func listedTools() -> [JSONValue] { [] }
    func offers(_ tool: String) -> Bool { tool != "missing" }

    func call(_ tool: String, arguments: JSONValue) async -> JSONValue {
        let label = arguments["label"]?.string ?? tool
        recorder.note("start \(label)")
        switch tool {
        case "slow":
            do { try await Task.sleep(for: .seconds(30)) } catch { recorder.note("cancelled \(label)") }
            return MCPStdioServer.textResult("late")
        case "takeover":
            // Like a screen takeover: waits to be cancelled, then restores in a task that cannot be cancelled.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            recorder.note("cancelled \(label)")
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(250))
                recorder.note("restored \(label)")
            }.value
            return MCPStdioServer.textResult("restored")
        case "stubborn":
            // Ignores the cancellation for far longer than the grace period.
            await Task.detached {
                try? await Task.sleep(for: .seconds(60))
                recorder.note("finished \(label)")
            }.value
            return MCPStdioServer.textResult("late")
        default:
            return MCPStdioServer.textResult("ok \(label)")
        }
    }
}

private func call(_ id: JSONValue, _ tool: String, label: String? = nil) -> String {
    var arguments: [String: JSONValue] = [:]
    if let label { arguments["label"] = .string(label) }
    return JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "method": .string("tools/call"),
                             "params": .object(["name": .string(tool), "arguments": .object(arguments)])]).jsonString
}

private func cancel(_ id: JSONValue) -> String {
    JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                      "params": .object(["requestId": id, "reason": .string("user")])]).jsonString
}

/// Waits until `condition` holds (polling) or `timeout` passes.
private func eventually(_ timeout: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

struct MCPServerLoopTests {
    private func make() -> (MCPServerLoop, LoopRecorder, LoopOutput) {
        let recorder = LoopRecorder(), output = LoopOutput()
        return (MCPServerLoop(handler: FakeHandler(recorder: recorder)) { output.add($0) }, recorder, output)
    }

    @Test func aFastCallIsAnsweredWhileASlowOneIsStillRunning() async {
        let (loop, recorder, output) = make()
        loop.handle(line: call(.number(1), "slow"))
        #expect(await eventually { recorder.has("start slow") })
        loop.handle(line: call(.number(2), "fast", label: "b"))
        #expect(await eventually { output.reply(id: .number(2)) != nil })
        #expect(output.reply(id: .number(1)) == nil)
        #expect(loop.running == 1)
        await loop.shutdown()
    }

    @Test func aCancelledNotificationStopsTheCallAndSendsNoReply() async {
        let (loop, recorder, output) = make()
        loop.handle(line: call(.number(7), "slow"))
        loop.handle(line: call(.string("abc"), "slow", label: "other"))
        #expect(await eventually { recorder.has("start slow") && recorder.has("start other") })
        loop.handle(line: cancel(.number(7)))
        #expect(await eventually { recorder.has("cancelled slow") })
        #expect(await eventually { loop.running == 1 })
        #expect(output.lines.isEmpty, "a cancelled request gets no reply")
        // The string id is a different request, still running; it is cancelled by its own id.
        loop.handle(line: cancel(.string("abc")))
        #expect(await eventually { recorder.has("cancelled other") })
        #expect(await eventually { loop.running == 0 })
        #expect(output.lines.isEmpty)
    }

    @Test func cancellingAnUnknownOrFinishedRequestDoesNothing() async {
        let (loop, _, output) = make()
        loop.handle(line: cancel(.number(99)))
        loop.handle(line: call(.number(1), "fast"))
        #expect(await eventually { output.reply(id: .number(1)) != nil })
        loop.handle(line: cancel(.number(1)))
        loop.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#)
        #expect(loop.running == 0 && output.lines.count == 1)
    }

    @Test func closingStdinCancelsEverythingAndWaitsForTheScreenToBeGivenBack() async {
        let (loop, recorder, output) = make()
        loop.handle(line: call(.number(1), "takeover", label: "t"))
        loop.handle(line: call(.number(2), "slow"))
        #expect(await eventually { recorder.has("start t") && recorder.has("start slow") })
        let begin = ContinuousClock.now
        // A generous grace: on a loaded machine the restoration can be slow to be scheduled; the real default is 1.5 s.
        await loop.shutdown(grace: .seconds(20))
        #expect(recorder.has("cancelled slow") && recorder.has("cancelled t"))
        #expect(recorder.has("restored t"), "shutdown returned only after the restoration finished")
        #expect(begin.duration(to: .now) < .seconds(10))
        #expect(loop.running == 0)
        #expect(output.lines.isEmpty, "nothing is answered once cancelled")
    }

    @Test func aCallThatIgnoresCancellationIsNotWaitedForBeyondTheGracePeriod() async {
        let (loop, recorder, _) = make()
        loop.handle(line: call(.number(1), "stubborn", label: "s"))
        #expect(await eventually { recorder.has("start s") })
        let begin = ContinuousClock.now
        await loop.shutdown(grace: .milliseconds(300))
        let waited = begin.duration(to: .now)
        #expect(waited >= .milliseconds(250), "it waited for the grace period")
        #expect(!recorder.has("finished s"))
    }

    @Test func nothingNewIsAcceptedAfterShutdown() async {
        let (loop, recorder, output) = make()
        await loop.shutdown()
        loop.handle(line: call(.number(1), "fast"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(output.lines.isEmpty && recorder.all.isEmpty)
    }

    @Test func manyCallsAtOnceGetOneWholeLineEach() async {
        let (loop, _, output) = make()
        for index in 0..<200 { loop.handle(line: call(.number(Double(index)), "fast", label: "n\(index)")) }
        #expect(await eventually { output.lines.count == 200 })
        let replies = output.replies
        #expect(replies.count == 200, "every line parses on its own")
        let ids = Set(replies.compactMap { $0["id"] })
        #expect(ids.count == 200)
        for reply in replies {
            let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
            #expect(text.hasPrefix("ok n"), "\(text)")
        }
    }

    @Test func repliesAreByteForByteWhatTheDirectEntryPointsGive() async throws {
        let (loop, recorder, output) = make()
        let requests = [
            JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
                              "params": .object(["protocolVersion": .string("2025-03-26")])]),
            .object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("ping")]),
            .object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/list")]),
            .object(["jsonrpc": .string("2.0"), "id": .string("x"), "method": .string("nada")]),
            .object(["jsonrpc": .string("2.0"), "id": .number(5), "method": .string("tools/call"),
                     "params": .object(["name": .string("missing")])]),
        ]
        for request in requests { loop.handle(line: request.jsonString) }
        #expect(await eventually { output.lines.count == requests.count })
        for request in requests {
            let direct = try #require(await MCPStdioServer.respond(to: request, handler: FakeHandler(recorder: recorder))).jsonString
            #expect(output.lines.contains(direct), "\(direct)")
        }
        // Notifications get no reply.
        loop.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(output.lines.count == requests.count)
    }

    @Test func aLineThatIsNotJSONStillGetsItsParseError() async {
        let (loop, _, output) = make()
        loop.handle(line: "{nao é json")
        #expect(await eventually { output.lines.count == 1 })
        #expect(output.replies.first?["error"]?["code"] == .number(-32700))
        #expect(await eventually { loop.running == 0 })
    }

    @Test func aPipedScriptGetsItsRepliesInOrder() async {
        let (loop, _, output) = make()
        loop.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        loop.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        loop.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        loop.handle(line: call(.number(3), "fast"))
        loop.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        #expect(await eventually { output.lines.count == 4 })
        let ids = output.replies.compactMap { reply -> Double? in if case .number(let n)? = reply["id"] { n } else { nil } }
        #expect(ids.firstIndex(of: 1)! < ids.firstIndex(of: 2)! && ids.firstIndex(of: 2)! < ids.firstIndex(of: 3)!)
    }

    @Test func patienceLetsAShortCallFinishBeforeTheRestIsCancelled() async {
        let (loop, recorder, output) = make()
        loop.handle(line: call(.number(1), "fast", label: "quick"))
        loop.handle(line: call(.number(2), "slow"))
        #expect(await eventually { recorder.has("start slow") })
        await loop.shutdown(patience: .milliseconds(200))
        #expect(output.reply(id: .number(1)) != nil, "the call that was about to finish was answered")
        #expect(recorder.has("cancelled slow") && output.reply(id: .number(2)) == nil)
    }
}
