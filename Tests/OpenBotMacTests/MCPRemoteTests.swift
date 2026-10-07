import Foundation
import Testing
@testable import OpenBotMac

private let hasPython = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// Fake remote MCP server. "streamable" mode: POST /mcp needs `Authorization: Bearer test` and a session id,
/// answers initialize/tools/list as JSON and tools/call as SSE. "legacy" mode: POST /sse is 405, GET /sse is the
/// event stream that announces `/messages` (or another host when the path is /evil). GET /state reports what it saw.
private let fakeHTTPServer = #"""
import json, queue, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LEGACY = sys.argv[1] == "legacy"
state = {"session": None, "deleted": False, "cancelled": [], "replies": []}
streams = {}

def handle(msg):
    method, id = msg.get("method"), msg.get("id")
    if method is None:
        state["replies"].append(msg); return None
    if method == "notifications/cancelled":
        state["cancelled"].append(msg["params"]["requestId"])
    if id is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": "2024-11-05" if LEGACY else "2025-06-18", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake", "version": "0"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}, {"name": "fail"},
                            {"name": "slow"}, {"name": "expire"}]}
    elif method == "tools/call":
        name, args = msg["params"]["name"], msg["params"]["arguments"]
        if name == "fail":
            result = {"content": [{"type": "text", "text": "deu ruim"}], "isError": True}
        elif name == "slow":
            time.sleep(5); result = {"content": []}
        elif name == "expire":
            state["session"] = "gone"; result = {"content": [{"type": "text", "text": "ok"}]}
        else:
            result = {"content": [{"type": "text", "text": args.get("text", "")}]}
    else:
        return {"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "nope"}}
    return {"jsonrpc": "2.0", "id": id, "result": result}

def event(data, name=None):
    lines = ("event: %s\n" % name if name else "") + "".join("data: %s\n" % l for l in data.split("\n"))
    return (lines + "\n").encode()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass

    def reply(self, status, body=b"", ctype="application/json", headers={}):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers.items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)

    def start_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers(); self.close_connection = True

    def do_GET(self):
        if self.path == "/state":
            return self.reply(200, json.dumps(state).encode())
        if not LEGACY or self.headers.get("Authorization") != "Bearer test":
            return self.reply(405)
        sid = uuid.uuid4().hex
        streams[sid] = q = queue.Queue()
        self.start_stream()
        target = "http://example.com/messages" if self.path == "/evil" else "/messages?session=" + sid
        self.wfile.write(b": hello\n\n" + event(target, "endpoint"))
        while True:
            self.wfile.write(event(json.dumps(q.get()), "message"))

    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if LEGACY:
            q = streams.get(self.path.split("session=")[-1]) if self.path.startswith("/messages") else None
            if q is None:
                return self.reply(405, b"use SSE")
            response = handle(msg)
            if response: q.put(response)
            return self.reply(202)
        problems = []
        if self.path != "/mcp": return self.reply(404, b"unknown path")
        if self.headers.get("Authorization") != "Bearer test": return self.reply(401, b"missing token")
        if self.headers.get("Content-Type") != "application/json": problems.append("content-type")
        if "text/event-stream" not in self.headers.get("Accept", ""): problems.append("accept")
        if msg.get("method") != "initialize":
            if self.headers.get("Mcp-Session-Id") != state["session"]: return self.reply(404, b"no session")
            if self.headers.get("MCP-Protocol-Version") != "2025-06-18": problems.append("version")
        if problems: return self.reply(400, ",".join(problems).encode())
        if msg.get("method") == "initialize":
            state["session"] = uuid.uuid4().hex
            return self.reply(200, json.dumps(handle(msg)).encode(), headers={"Mcp-Session-Id": state["session"]})
        response = handle(msg)
        if response is None:
            return self.reply(202)
        if msg.get("method") != "tools/call":
            return self.reply(200, json.dumps(response).encode())
        self.start_stream()
        self.wfile.write(event(json.dumps({"jsonrpc": "2.0", "method": "notifications/progress", "params": {}})))
        self.wfile.write(event(json.dumps({"jsonrpc": "2.0", "id": "srv-1", "method": "ping"})))
        self.wfile.write(b"id: 7\r\n" + event(json.dumps(response, indent=1)).replace(b"\n", b"\r\n"))
        time.sleep(0.2)

    def do_DELETE(self):
        if self.headers.get("Mcp-Session-Id") == state["session"] and self.headers.get("Authorization") == "Bearer test":
            state["deleted"] = True
        self.reply(204)

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, address): pass

server = Server(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
"""#

/// One fake server process on a free port, killed by `stop()`.
private struct FakeHTTPServer {
    let process = Process()
    let port: Int

    init(mode: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try fakeHTTPServer.write(to: script, atomically: true, encoding: .utf8)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, mode]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while !data.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        port = try #require(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func config(path: String, token: String? = "test") -> MCPServerConfig {
        MCPServerConfig(name: "Remoto", url: "http://127.0.0.1:\(port)\(path)",
                        headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:])
    }

    /// What the server saw, polled until `condition` holds (requests like DELETE are fire-and-forget).
    func state(until condition: (JSONValue) -> Bool = { _ in true }) async throws -> JSONValue {
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/state"))
        var state = JSONValue.null
        for _ in 0..<40 {
            let (data, _) = try await URLSession.shared.data(from: url)
            state = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self)))
            if condition(state) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return state
    }

    func stop() { process.terminate() }
}

private func message(_ error: any Error) -> String { (error as? ToolError)?.message ?? "\(error)" }

@Suite(.enabled(if: hasPython))
struct MCPRemoteTests {
    @Test func streamableHTTP() async throws {
        let server = try FakeHTTPServer(mode: "streamable")
        defer { server.stop() }
        let connection = MCPConnection(config: server.config(path: "/mcp"))
        let tools = try await connection.start()
        #expect(tools.map(\.name) == ["echo", "fail", "slow", "expire"])
        #expect(tools[1].parameters == .schema([:]))

        // SSE reply with a notification, a server ping, CRLF line endings and multi-line data before the result.
        #expect(try await connection.call("echo", arguments: .object(["text": .string("olá")])) == "olá")
        await #expect(throws: ToolError("deu ruim")) {
            try await connection.call("fail", arguments: .object([:]))
        }

        let slow = Task { try await connection.call("slow", arguments: .object([:])) }
        try await Task.sleep(for: .milliseconds(300))
        slow.cancel()
        await #expect(throws: CancellationError.self) { try await slow.value }
        var state = try await server.state { $0["cancelled"]?.array?.isEmpty == false }
        #expect(state["cancelled"]?.array?.count == 1)
        #expect(state["replies"]?.array?.first?["id"]?.string == "srv-1")

        await connection.stop()
        #expect(await !connection.isRunning)
        state = try await server.state { $0["deleted"]?.bool == true }
        #expect(state["deleted"]?.bool == true)
    }

    @Test func missingTokenReportsHTTPStatus() async throws {
        let server = try FakeHTTPServer(mode: "streamable")
        defer { server.stop() }
        let connection = MCPConnection(config: server.config(path: "/mcp", token: nil))
        do {
            _ = try await connection.start()
            Issue.record("expected an error")
        } catch {
            #expect(message(error) == "O conector Remoto respondeu HTTP 401: missing token")
        }
        #expect(await !connection.isRunning)
    }

    @Test func failedFallbackReportsTheInitializeError() async throws {
        let server = try FakeHTTPServer(mode: "streamable")
        defer { server.stop() }
        await #expect(throws: ToolError("O conector Remoto respondeu HTTP 404: unknown path")) {
            try await MCPConnection(config: server.config(path: "/nope")).start()
        }
    }

    @Test func expiredSessionClosesTheConnection() async throws {
        let server = try FakeHTTPServer(mode: "streamable")
        defer { server.stop() }
        let connection = MCPConnection(config: server.config(path: "/mcp"))
        _ = try await connection.start()
        #expect(try await connection.call("expire", arguments: .object([:])) == "ok")
        do {
            _ = try await connection.call("echo", arguments: .object(["text": .string("x")]))
            Issue.record("expected an error")
        } catch {
            #expect(message(error).contains("expirou"))
        }
        #expect(await !connection.isRunning)
    }

    @Test func legacySSEFallback() async throws {
        let server = try FakeHTTPServer(mode: "legacy")
        defer { server.stop() }
        let connection = MCPConnection(config: server.config(path: "/sse"))
        let tools = try await connection.start()
        #expect(tools.count == 4)
        #expect(try await connection.call("echo", arguments: .object(["text": .string("legado")])) == "legado")
        await #expect(throws: ToolError("deu ruim")) {
            try await connection.call("fail", arguments: .object([:]))
        }
        await connection.stop()
        #expect(await !connection.isRunning)
    }

    @Test func legacyEndpointOnAnotherHostIsRefused() async throws {
        let server = try FakeHTTPServer(mode: "legacy")
        defer { server.stop() }
        let connection = MCPConnection(config: server.config(path: "/evil"))
        do {
            _ = try await connection.start()
            Issue.record("expected an error")
        } catch {
            #expect(message(error).contains("outro servidor"))
        }
    }

    @Test func invalidURL() async throws {
        let connection = MCPConnection(config: MCPServerConfig(name: "Remoto", url: "ftp://example.com"))
        await #expect(throws: ToolError("O endereço do conector Remoto é inválido (use http:// ou https://).")) {
            try await connection.start()
        }
    }
}
