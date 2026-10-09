import Foundation
import os
import Testing
@testable import Orb

// Local (stdio) servers that misbehave: stuck, deaf to SIGTERM, not reading stdin, noisy or flooding stdout. The fake server is
// a small Python script; its first argument is the behaviour.

private let behaviorServer = #"""
import json, os, signal, sys, time

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "ignore-sigterm":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

def send(message):
    sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()

def result(id, value):
    send({"jsonrpc": "2.0", "id": id, "result": value})

def text(id, value):
    result(id, {"content": [{"type": "text", "text": value}]})

if mode == "flood":
    while True:
        sys.stdout.write("x" * 4096); sys.stdout.flush()

while True:
    line = sys.stdin.readline()
    if not line:
        while mode == "ignore-sigterm":  # stdin closed, SIGTERM ignored: only SIGKILL ends it
            time.sleep(1)
        break
    msg = json.loads(line)
    method, id = msg.get("method"), msg.get("id")
    if method == "initialize":
        result(id, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "0"}})
    elif method == "tools/list":
        if mode == "list-once" and os.environ.get("LISTED"):
            continue  # never answers the second listing
        os.environ["LISTED"] = "1"
        result(id, {"tools": [{"name": n} for n in ["pid", "hang", "echo", "noisy", "big"]]})
    elif method == "tools/call":
        name, args = msg["params"]["name"], msg["params"]["arguments"]
        if name == "pid":
            text(id, str(os.getpid()))
        elif name == "hang":
            time.sleep(30)  # alive, and not reading its input
        elif name == "echo":
            text(id, args.get("text", ""))
        elif name == "noisy":
            sys.stdout.write("Loading...\r"); sys.stdout.flush()  # no newline before the reply
            text(id, "clean")
        elif name == "big":
            text(id, "y" * 4_000_000)
    elif id is not None:
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "nope"}})
"""#

private func config(_ mode: String = "") throws -> MCPServerConfig {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-behavior-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("server.py")
    try behaviorServer.write(to: script, atomically: true, encoding: .utf8)
    return MCPServerConfig(name: "Comportado", command: "/usr/bin/python3", arguments: [script.path, mode])
}

private func pid(_ text: String) throws -> pid_t { try #require(pid_t(text)) }

/// What a transport hands back, collected for the test.
private final class Inbox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (messages: [JSONValue](), closed: [String]()))
    var messages: [JSONValue] { state.withLock { $0.messages } }
    var closed: [String] { state.withLock { $0.closed } }
    func receive(_ message: JSONValue) { state.withLock { $0.messages.append(message) } }
    func close(_ error: Error) { state.withLock { $0.closed.append((error as? ToolError)?.message ?? "\(error)") } }
}

@Suite(.enabled(if: hasPython))
struct MCPStdioRobustnessTests {
    private func open(_ mode: String = "", registry: StdioServerRegistry = StdioServerRegistry(), grace: Duration = .milliseconds(300),
                      maxLine: Int = 32 << 20) async throws -> (transport: StdioTransport, inbox: Inbox, pid: pid_t) {
        let transport = StdioTransport(config: try config(mode), registry: registry, killGrace: grace, maxLineBytes: maxLine)
        let inbox = Inbox()
        try await transport.open(receive: { inbox.receive($0) }, closed: { inbox.close($0) })
        let pid = try #require(await transport.processID)
        return (transport, inbox, pid)
    }

    private func initialize(_ transport: StdioTransport, _ inbox: Inbox) async throws {
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"), "params": .object([:])]))
        await waitUntil("the server to answer initialize") { !inbox.messages.isEmpty }
    }

    // MARK: A stuck server (conectores-2)

    @Test func aServerThatStaysSilentIsReplacedInsteadOfWaitedForAgain() async throws {
        let manager = MCPManager()
        let server = try config()
        await manager.sync([server])
        let first = try pid(try await manager.call(server.id, tool: "pid", arguments: .object([:])))
        for _ in 0..<MCPConnection.stuckAfter {
            await #expect(throws: ToolError.self) { try await manager.call(server.id, tool: "hang", arguments: .object([:]), timeout: .milliseconds(200)) }
        }
        let started = ContinuousClock.now
        let second = try pid(try await manager.call(server.id, tool: "pid", arguments: .object([:])))
        #expect(second != first, "the stuck process was reused")
        #expect(ContinuousClock.now - started < .seconds(10))
        await waitUntil("the stuck process to end") { !processIsAlive(first) }
        await manager.sync([])
    }

    @Test func oneSlowCallDoesNotMakeTheServerCountAsStuck() async throws {
        let manager = MCPManager()
        let server = try config()
        await manager.sync([server])
        _ = try await manager.call(server.id, tool: "pid", arguments: .object([:]))
        await #expect(throws: ToolError.self) { try await manager.call(server.id, tool: "hang", arguments: .object([:]), timeout: .milliseconds(200)) }
        // One timeout is a slow tool, not a dead server: the connection stays.
        #expect(await manager.isRunning(server.id))
        await manager.sync([])
    }

    @Test func aServerThatCannotListItsToolsAnymoreIsClosedAtOnce() async throws {
        let connection = MCPConnection(config: try config("list-once"))
        _ = try await connection.start()
        await #expect(throws: ToolError.self) { try await connection.listTools(timeout: .milliseconds(200)) }
        #expect(await !connection.isRunning)
    }

    // MARK: Ending servers (conectores-4)

    @Test func aServerThatIgnoresSIGTERMIsKilled() async throws {
        let (transport, inbox, pid) = try await open("ignore-sigterm")
        try await initialize(transport, inbox) // the handler is installed by now
        await transport.close()
        await waitUntil("the server that ignores SIGTERM to be killed", timeout: .seconds(10)) { !processIsAlive(pid) }
    }

    @Test func quittingTheAppEndsEveryServerStillRunning() async throws {
        let registry = StdioServerRegistry()
        let plain = try await open(registry: registry)
        let deaf = try await open("ignore-sigterm", registry: registry)
        try await initialize(deaf.transport, deaf.inbox)
        #expect(registry.count == 2)
        registry.killAllNow()
        await waitUntil("both servers to end") { !processIsAlive(plain.pid) && !processIsAlive(deaf.pid) }
        #expect(registry.count == 0)
    }

    // MARK: Writing to a server that does not read (conectores-7)

    @Test func aServerThatStopsReadingDoesNotKeepItselfAliveForever() async throws {
        let connection = MCPConnection(config: try config())
        _ = try await connection.start()
        let process = try pid(try await connection.call("pid", arguments: .object([:])))
        await #expect(throws: ToolError.self) { try await connection.call("hang", arguments: .object([:]), timeout: .milliseconds(200)) }
        // The server is asleep, so this fills the pipe and the write blocks: that must not keep the connection from closing.
        let big = JSONValue.object(["text": .string(String(repeating: "x", count: 300_000))])
        await #expect(throws: ToolError.self) { try await connection.call("echo", arguments: big, timeout: .milliseconds(300)) }
        await connection.stop()
        await waitUntil("the process to be killed although a write was stuck", timeout: .seconds(10)) { !processIsAlive(process) }
    }

    // MARK: Output (conectores-9)

    @Test func outputWithoutANewlineBeforeAReplyDoesNotSwallowIt() async throws {
        let connection = MCPConnection(config: try config())
        _ = try await connection.start()
        let started = ContinuousClock.now
        #expect(try await connection.call("noisy", arguments: .object([:]), timeout: .seconds(10)) == "clean")
        #expect(ContinuousClock.now - started < .seconds(5))
        // A big reply in one line, arriving in many chunks.
        #expect(try await connection.call("big", arguments: .object([:]), timeout: .seconds(20)).count == 4_000_000)
        await connection.stop()
    }

    @Test func aServerThatNeverWritesANewlineIsCutOffWithAReason() async throws {
        let (transport, inbox, pid) = try await open("flood", maxLine: 64 * 1024)
        await waitUntil("the connection to be closed") { !inbox.closed.isEmpty }
        #expect(inbox.closed.first == "O conector Comportado mandou uma resposta grande demais ou sem quebra de linha.")
        await waitUntil("the flooding server to end", timeout: .seconds(10)) { !processIsAlive(pid) }
        await transport.close()
    }
}
