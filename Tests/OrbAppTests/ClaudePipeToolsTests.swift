import Foundation
import Testing
@testable import Orb

// The Orb's tools for Claude Code as a pipe: the declarations file, the mailbox the engine delivers results to, the --mcp-config
// entry, and the MCP stdio server that lists the tools and answers a call with what the mailbox holds.

private func pipeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-pipe-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let sampleTools = [
    ToolSpec(name: "remember", description: "Guarda uma nota",
             parameters: .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])])])),
    ToolSpec(name: "screenshot", description: "Tira uma foto da tela", parameters: .object(["type": .string("object")])),
]

private func call(_ id: Int, tool: String, toolUseID: String?) -> String {
    var params: [String: JSONValue] = ["name": .string(tool), "arguments": .object([:])]
    if let toolUseID { params["_meta"] = .object([ClaudePipeServer.toolUseIDKey: .string(toolUseID)]) }
    return JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                             "params": .object(params)]).jsonString
}

private func request(_ id: Int, _ method: String) -> String {
    JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]).jsonString
}

private func respond(_ line: String, _ declarations: [JSONValue], _ mailbox: ClaudePipeMailbox,
                     poll: Duration = .milliseconds(5), timeout: Duration = .seconds(5)) async -> JSONValue? {
    await ClaudePipeServer.respond(toLine: line, declarations: declarations, mailbox: mailbox, pollInterval: poll, timeout: timeout)
}

@Suite struct ClaudePipeToolsTests {
    // MARK: Declarations and config

    @Test func declarationsRoundTrip() throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/tools.json")
        try ClaudePipeTools.writeDeclarations(sampleTools, to: file)
        let loaded = ClaudePipeServer.loadDeclarations(from: file)
        #expect(loaded.count == 2)
        #expect(loaded[0]["name"]?.string == "remember")
        #expect(loaded[0]["description"]?.string == "Guarda uma nota")
        #expect(loaded[0]["inputSchema"] == sampleTools[0].parameters)
        #expect(loaded[1]["name"]?.string == "screenshot")
        #expect(ClaudePipeServer.loadDeclarations(from: dir.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func mcpConfigNamesTheOrbServer() throws {
        let config = ClaudePipeTools.mcpConfig(binary: URL(fileURLWithPath: "/Apps/Orb.app/Contents/MacOS/Orb"),
                                               declarations: URL(fileURLWithPath: "/run/tools.json"),
                                               mailbox: URL(fileURLWithPath: "/run/mailbox"))
        let server = try #require(config["mcpServers"]?["orb"])
        #expect(server["type"]?.string == "stdio")
        #expect(server["command"]?.string == "/Apps/Orb.app/Contents/MacOS/Orb")
        #expect(server["args"] == .array([.string("--pipe-tools"), .string("/run/tools.json"),
                                          .string("--pipe-mailbox"), .string("/run/mailbox")]))
        #expect(server["env"] == .object([:]))
        // The arguments the config writes are the ones the binary reads back.
        guard case .array(let args)? = server["args"] else { Issue.record("no args"); return }
        let options = try #require(ClaudePipeServer.Options(arguments: ["Orb"] + args.compactMap(\.string)))
        #expect(options.declarations.path == "/run/tools.json")
        #expect(options.mailbox.path == "/run/mailbox")
        #expect(ClaudePipeServer.Options(arguments: ["Orb", "--pipe-tools", "/x"]) == nil)
        #expect(ClaudePipeServer.Options(arguments: ["Orb"]) == nil)
    }

    // MARK: Mailbox

    @Test func mailboxDeliversAndTakesOnce() throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        #expect(mailbox.take(toolUseID: "toolu_1") == nil)
        let image = ImageAttachment(path: "/tmp/a.png", mediaType: "image/png", width: 3, height: 2)
        let result = ClaudePipeToolResult(text: "feito", images: [image], isError: true)
        try mailbox.deliver(result, toolUseID: "toolu_1")
        #expect(mailbox.take(toolUseID: "toolu_1") == result)
        #expect(mailbox.take(toolUseID: "toolu_1") == nil)
    }

    @Test func mailboxIDsCannotEscapeTheFolder() throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        let result = ClaudePipeToolResult(text: "x", images: [], isError: false)
        try mailbox.deliver(result, toolUseID: "../../evil/id")
        let file = mailbox.file(for: "../../evil/id")
        #expect(file.deletingLastPathComponent().standardizedFileURL == mailbox.directory.standardizedFileURL)
        #expect(mailbox.take(toolUseID: "../../evil/id") == result)
    }

    // MARK: Server

    @Test func handshakeAndListing() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tools.json")
        try ClaudePipeTools.writeDeclarations(sampleTools, to: file)
        let declarations = ClaudePipeServer.loadDeclarations(from: file)
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))

        let initialize = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
                                           "params": .object(["protocolVersion": .string("2025-06-18")])]).jsonString
        let hello = try #require(await respond(initialize, declarations, mailbox))
        #expect(hello["result"]?["capabilities"]?["tools"] == .object([:]))
        #expect(hello["result"]?["serverInfo"]?["name"]?.string == "orb")

        let list = try #require(await respond(request(2, "tools/list"), declarations, mailbox))
        guard case .array(let tools)? = list["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.compactMap { $0["name"]?.string } == ["remember", "screenshot"])
        #expect(tools[0]["inputSchema"] == sampleTools[0].parameters)

        // Notifications get no reply; unknown methods with an id get an empty result.
        let note = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]).jsonString
        #expect(await respond(note, declarations, mailbox) == nil)
        let unknown = try #require(await respond(request(3, "resources/list"), declarations, mailbox))
        #expect(unknown["result"] == .object([:]))
        #expect(unknown["error"] == nil)
        #expect(await respond("not json", declarations, mailbox) == nil)
    }

    @Test func callReturnsTheDeliveredResultKeyedByToolUseID() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        // Already waiting when the call starts, and for another id: that one is not touched.
        try mailbox.deliver(ClaudePipeToolResult(text: "de outra", images: [], isError: false), toolUseID: "toolu_other")
        try mailbox.deliver(ClaudePipeToolResult(text: "nota guardada", images: [], isError: false), toolUseID: "toolu_A")

        let reply = try #require(await respond(call(7, tool: "remember", toolUseID: "toolu_A"), declarations, mailbox))
        #expect(reply["id"] == .number(7))
        #expect(reply["result"]?["isError"] == .bool(false))
        #expect(reply["result"]?["content"] == .array([.object(["type": .string("text"), "text": .string("nota guardada")])]))
        #expect(mailbox.take(toolUseID: "toolu_other")?.text == "de outra")
    }

    @Test func callWaitsForAResultDeliveredLater() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        let late = Task {
            try await Task.sleep(for: .milliseconds(100))
            try mailbox.deliver(ClaudePipeToolResult(text: "falhou", images: [], isError: true), toolUseID: "toolu_B")
        }
        let reply = try #require(await respond(call(1, tool: "screenshot", toolUseID: "toolu_B"), declarations, mailbox))
        try await late.value
        #expect(reply["result"]?["isError"] == .bool(true))
        #expect(reply["result"]?["content"]?.array?.first?["text"]?.string == "falhou")
    }

    @Test func imagesBecomeMCPImageContent() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let png = dir.appendingPathComponent("shot.png")
        try bytes.write(to: png)
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        let images = [ImageAttachment(path: png.path, mediaType: "image/png", width: 1, height: 1),
                      ImageAttachment(path: dir.appendingPathComponent("gone.jpg").path, mediaType: "image/jpeg", width: 1, height: 1)]
        try mailbox.deliver(ClaudePipeToolResult(text: "Tela capturada", images: images, isError: false), toolUseID: "toolu_C")

        let reply = try #require(await respond(call(1, tool: "screenshot", toolUseID: "toolu_C"), declarations, mailbox))
        let content = try #require(reply["result"]?["content"]?.array)
        // The picture that cannot be read is left out.
        #expect(content.count == 2)
        #expect(content[0]["type"]?.string == "text")
        #expect(content[1]["type"]?.string == "image")
        #expect(content[1]["data"]?.string == bytes.base64EncodedString())
        #expect(content[1]["mimeType"]?.string == "image/png")
    }

    @Test func neverDeliveredIsAnErrorResult() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))

        let timedOut = try #require(await respond(call(1, tool: "remember", toolUseID: "toolu_never"), declarations, mailbox,
                                                  poll: .milliseconds(5), timeout: .milliseconds(60)))
        #expect(timedOut["result"]?["isError"] == .bool(true))
        #expect(timedOut["result"]?["content"]?.array?.first?["text"]?.string?.contains("a tempo") == true)

        let noID = try #require(await respond(call(2, tool: "remember", toolUseID: nil), declarations, mailbox))
        #expect(noID["result"]?["isError"] == .bool(true))

        let unknown = try #require(await respond(call(3, tool: "nao_existe", toolUseID: "toolu_x"), declarations, mailbox))
        #expect(unknown["error"] != nil)
    }

    @Test func cancellingTheCallEndsTheWait() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        let started = ContinuousClock.now
        let task = Task { await respond(call(1, tool: "remember", toolUseID: "toolu_cancel"), declarations, mailbox,
                                        poll: .milliseconds(5), timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: Loop

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        func add(_ line: String) { lock.withLock { written.append(line) } }
        var replies: [JSONValue] { lock.withLock { written }.compactMap(JSONValue.parse) }
    }

    @Test func loopAnswersCallsSideBySideAndHonorsCancellation() async throws {
        let dir = try pipeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let declarations = sampleTools.map { JSONValue.object(["name": .string($0.name)]) }
        let mailbox = ClaudePipeMailbox(directory: dir.appendingPathComponent("box"))
        let output = Output()
        let loop = ClaudePipeServer.Loop(declarations: declarations, mailbox: mailbox, pollInterval: .milliseconds(5),
                                         timeout: .seconds(30)) { output.add($0) }

        loop.handle(line: request(1, "tools/list"))
        loop.handle(line: call(2, tool: "remember", toolUseID: "toolu_slow"))
        loop.handle(line: call(3, tool: "screenshot", toolUseID: "toolu_fast"))
        loop.handle(line: call(4, tool: "remember", toolUseID: "toolu_cancelled"))
        // The second call is delivered first; the first still waits.
        try mailbox.deliver(ClaudePipeToolResult(text: "rápido", images: [], isError: false), toolUseID: "toolu_fast")
        for _ in 0..<200 where !output.replies.contains(where: { $0["id"] == .number(3) }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(output.replies.contains { $0["id"] == .number(1) })
        let fast = try #require(output.replies.first { $0["id"] == .number(3) })
        #expect(fast["result"]?["content"]?.array?.first?["text"]?.string == "rápido")
        #expect(!output.replies.contains { $0["id"] == .number(2) })

        // notifications/cancelled ends call 4 without a reply; call 2 is answered when its result comes.
        loop.handle(line: JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                                            "params": .object(["requestId": .number(4)])]).jsonString)
        try mailbox.deliver(ClaudePipeToolResult(text: "lento", images: [], isError: false), toolUseID: "toolu_slow")
        for _ in 0..<200 where loop.running > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loop.running == 0)
        #expect(output.replies.contains { $0["id"] == .number(2) })
        #expect(!output.replies.contains { $0["id"] == .number(4) })
    }
}
