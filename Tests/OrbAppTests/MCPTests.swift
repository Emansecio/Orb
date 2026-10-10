import Foundation
import Testing
@testable import Orb

/// Fake MCP server: paginated tools/list, partial-line writes, a server→client request, stray stdout noise.
private let fakeServer = #"""
import json, os, sys, time

replies = []

def send(message, split=False):
    text = json.dumps(message) + "\n"
    if split:
        sys.stdout.write(text[:10]); sys.stdout.flush(); time.sleep(0.05)
        text = text[10:]
    sys.stdout.write(text); sys.stdout.flush()

def result(id, value, **kw):
    send({"jsonrpc": "2.0", "id": id, "result": value}, **kw)

print("not json, just noise", flush=True)
while True:
    line = sys.stdin.readline()
    if not line:
        break
    msg = json.loads(line)
    method, id = msg.get("method"), msg.get("id")
    if method is None:
        replies.append(msg)
    elif method == "initialize":
        result(id, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "0"}})
    elif method == "tools/list":
        if msg["params"].get("cursor") == "p2":
            result(id, {"tools": [
                {"name": "fail", "inputSchema": {"type": "object"}},
                {"name": "info", "description": "Argv and env"},
                {"name": "crash"}, {"name": "slow"}]})
        else:
            result(id, {"tools": [{"name": "echo", "description": "Echoes text",
                "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}], "nextCursor": "p2"})
    elif method == "tools/call":
        name, args = msg["params"]["name"], msg["params"]["arguments"]
        if name == "echo":
            send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "hi"}})
            send({"jsonrpc": "2.0", "id": "srv-1", "method": "roots/list"})
            send({"jsonrpc": "2.0", "id": id, "result": {"content": [
                {"type": "text", "text": args["text"]}, {"type": "image", "data": "", "mimeType": "image/png"}]}}, split=True)
        elif name == "fail":
            result(id, {"content": [{"type": "text", "text": "deu ruim"}], "isError": True})
        elif name == "info":
            result(id, {"content": [{"type": "text", "text": json.dumps(
                {"argv": sys.argv[1:], "env": os.environ.get("ORB_TEST"), "replies": replies})}]})
        elif name == "crash":
            sys.stderr.write("boom\n"); sys.stderr.flush(); sys.exit(3)
        elif name == "slow":
            time.sleep(5)
    elif id is not None:
        send({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "nope"}})
"""#

private func fakeConfig(arguments: [String] = []) throws -> MCPServerConfig {
    let script = try testScript(fakeServer)
    return MCPServerConfig(name: "Fake Server", command: "/usr/bin/python3", arguments: [script.path] + arguments,
                           environment: ["ORB_TEST": "ok"])
}

private func message(_ error: any Error) -> String { (error as? ToolError)?.message ?? "\(error)" }

@Suite(.enabled(if: hasPython))
struct MCPConnectionTests {
    @Test func startListCallErrorStop() async throws {
        let connection = MCPConnection(config: try fakeConfig(arguments: ["a b", "$HOME", "'; echo x"]))
        let tools = try await connection.start()
        #expect(tools.map(\.name) == ["echo", "fail", "info", "crash", "slow"])
        #expect(tools[0].description == "Echoes text")
        #expect(tools[0].parameters["properties"]?["text"]?["type"]?.string == "string")
        #expect(tools[2].parameters == .schema([:]))

        #expect(try await connection.call("echo", arguments: .object(["text": .string("olá")])) == "olá\n[imagem]")

        // The client's reply to the server's request travels on its own, so it may reach the server after this call does:
        // ask until the server has seen it.
        var info = JSONValue.null
        try await waitUntil("the server to receive the client's reply to its request") {
            info = try #require(JSONValue.parse(try await connection.call("info", arguments: .null)))
            return info["replies"]?.array?.isEmpty == false
        }
        #expect(info["argv"]?.array == [.string("a b"), .string("$HOME"), .string("'; echo x")])
        #expect(info["env"]?.string == "ok")
        #expect(info["replies"]?.array?.first?["error"]?["code"]?.int == -32601)

        await #expect(throws: ToolError("deu ruim")) {
            try await connection.call("fail", arguments: .object([:]))
        }

        await #expect(throws: ToolError.self) {
            try await connection.call("slow", arguments: .object([:]), timeout: .milliseconds(200))
        }

        await connection.stop()
        #expect(await !connection.isRunning)
        await #expect(throws: ToolError.self) {
            try await connection.call("echo", arguments: .object(["text": .string("x")]))
        }
    }

    @Test func processExitFailsPendingRequests() async throws {
        let connection = MCPConnection(config: try fakeConfig())
        _ = try await connection.start()
        do {
            _ = try await connection.call("crash", arguments: .object([:]))
            Issue.record("expected an error")
        } catch {
            #expect(message(error).contains("encerrado"))
            #expect(message(error).contains("boom"))
        }
        #expect(await !connection.isRunning)
    }

    @Test func missingCommandReportsStderr() async throws {
        let connection = MCPConnection(config: MCPServerConfig(name: "Quebrado", command: "orb-no-such-command-xyz"))
        do {
            _ = try await connection.start()
            Issue.record("expected an error")
        } catch {
            #expect(message(error).contains("Quebrado"))
            #expect(message(error).contains("orb-no-such-command-xyz"))
            #expect(message(error).contains("not found"))
        }
    }

    @Test func localServersFindCommandsOnThePathOfTheUsersShell() async throws {
        // `fake-mcp` lives in a folder only the user's `.zshrc` would put on the PATH (nvm, fnm, Volta…).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTestFolder(directory) }
        let command = directory.appendingPathComponent("fake-mcp")
        try ("#!/usr/bin/python3\n" + fakeServer).write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        let userShell = try FakeShell.make(in: directory, exports: ["PATH": "\(directory.path):/usr/bin:/bin"])
        let config = MCPServerConfig(name: "Arquivos", command: "fake-mcp", environment: ["ORB_TEST": "ok"])

        let connection = MCPConnection(config: config, shell: ShellEnvironment(shell: userShell, base: base, timeout: .seconds(60)))
        let tools = try await connection.start()
        #expect(tools.map(\.name).first == "echo")
        await connection.stop()

        // Without the user's PATH the same connector cannot start, which is what happened before.
        let bare = MCPConnection(config: config, shell: ShellEnvironment(shell: "/nonexistent/shell", base: base))
        await #expect(throws: ToolError.self) { _ = try await bare.start() }
    }

    @Test func managerRegistersWithoutStartingAndStartsOnTheFirstCall() async throws {
        let manager = MCPManager()
        var config = try fakeConfig()
        let broken = MCPServerConfig(name: "Quebrado", command: "orb-no-such-command-xyz")
        await manager.sync([config, broken])
        // Registering starts nothing.
        #expect(await manager.status() == [config.id: .idle(toolCount: nil), broken.id: .idle(toolCount: nil)])
        #expect(await !manager.isRunning(config.id))
        #expect(await manager.catalog(config.id) == nil)

        let echo = MCPTool(serverName: "Fake Server", remote: ToolSpec(name: "echo", description: "", parameters: .schema([:])),
                           serverID: config.id, manager: manager)
        #expect(echo.spec.name == "Fake_Server__echo")
        #expect(echo.summary(.object(["text": .string("oi")])) == (title: "Usando Fake Server", detail: #"echo {"text":"oi"}"#))
        #expect(await echo.connectingNote(.null) == "Conectando a Fake Server…")
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(try await echo.run(.object(["text": .string("oi")]), context: context) == "oi\n[imagem]")
        #expect(await manager.status()[config.id] == .ready(toolCount: 5))
        #expect(await echo.connectingNote(.null) == nil)
        let catalog = try #require(await manager.catalog(config.id))
        #expect(catalog.tools.map(\.name) == ["echo", "fail", "info", "crash", "slow"])
        #expect(catalog.serverName == "fake" && catalog.protocolVersion == "2025-06-18")

        // A server that does not come up is a failure, not a hang; the others are left alone.
        await #expect(throws: ToolError.self) { try await manager.ensureStarted(broken.id) }
        guard case .failed? = await manager.status()[broken.id] else { Issue.record("expected failure"); return }

        config.isEnabled = false
        await manager.sync([config])
        #expect(await manager.status() == [config.id: .stopped])
        #expect(await !manager.isRunning(config.id))
        await #expect(throws: ToolError.self) { try await manager.ensureStarted(config.id) }
    }
}

struct MCPToolNameTests {
    @Test func sanitizesModelNames() {
        #expect(MCPTool.modelName(server: "GitHub", tool: "create_issue") == "GitHub__create_issue")
        #expect(MCPTool.modelName(server: "Meu Café", tool: "files.read") == "Meu_Caf___files_read")
        let long = MCPTool.modelName(server: String(repeating: "s", count: 50), tool: String(repeating: "t", count: 50))
        #expect(long.count == 64)
        #expect(long.hasPrefix(String(repeating: "s", count: 50) + "__"))
    }
}
