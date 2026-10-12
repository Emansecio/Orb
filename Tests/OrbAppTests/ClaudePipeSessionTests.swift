import Foundation
import Testing
@testable import Orb

struct ClaudePipeSessionTests {
    private func call(_ id: String, _ name: String = "ls", _ arguments: String = #"{"path":"."}"#) -> ToolCallRequest {
        ToolCallRequest(id: id, name: name, arguments: arguments)
    }

    private func decode(_ lines: [String]) throws -> [JSONValue] {
        try lines.map { try #require(JSONValue.parse($0)) }
    }

    private func lines(_ history: [ChatMessage]) throws -> [JSONValue] {
        try decode(ClaudePipeSession.sessionLines(history, sessionID: "s1", cwd: "/w", model: "m", now: Date(timeIntervalSince1970: 0)))
    }

    private func tempImage(bytes: [UInt8] = [1, 2, 3, 4], type: String = "image/png") throws -> ImageAttachment {
        let url = FileManager.default.temporaryDirectory.appending(path: "pipe-\(UUID().uuidString).png")
        try Data(bytes).write(to: url)
        return ImageAttachment(path: url.path, mediaType: type, width: 1, height: 1)
    }

    // MARK: split

    @Test func systemMessagesFormTheSystemPrompt() {
        let split = ClaudePipeSession.split([.system("A"), .user("oi"), .system("B")])
        #expect(split.system == "A\n\nB")
        #expect(split.history.isEmpty)
        #expect(split.prompt == "oi")
    }

    @Test func plainTurnIsHistoryPlusPrompt() {
        let messages: [ChatMessage] = [.system("S"), .user("um"), assistant("resposta"), .user("dois")]
        let split = ClaudePipeSession.split(messages)
        #expect(split.history == [.user("um"), assistant("resposta")])
        #expect(split.prompt == "dois")
        #expect(split.images.isEmpty)
    }

    @Test func promptImagesAreTheLastUserMessagesImages() {
        let image = ImageAttachment(path: "/x.png", mediaType: "image/png", width: 1, height: 1)
        let split = ClaudePipeSession.split([.user("a"), assistant("b"), .user("c", images: [image])])
        #expect(split.images == [image])
    }

    @Test func completedToolExchangeStaysInHistory() {
        let messages: [ChatMessage] = [.user("lista"), assistant("vou", calls: [call("c1")]), .tool("c1", "a.txt"), assistant("tem a.txt"), .user("e agora?")]
        let split = ClaudePipeSession.split(messages)
        #expect(split.history.count == 4)
        #expect(split.prompt == "e agora?")
    }

    @Test func trailingToolExchangeBeforeTheUserMessageIsTrimmedIntoThePrompt() {
        // The previous turn never got its final answer: assistant tool call + result, then a new user message.
        let messages: [ChatMessage] = [.user("um"), assistant("ok"), .user("lista"), assistant("vou", calls: [call("c1")]), .tool("c1", "a.txt"), .user("continua")]
        let split = ClaudePipeSession.split(messages)
        #expect(split.history == [.user("um"), assistant("ok")])
        #expect(split.prompt == """
        [Histórico anterior, em texto]
        Usuário: lista
        Assistente: vou
        Ferramenta ls chamada com {"path":"."} → resultado: a.txt

        continua
        """)
    }

    @Test func trailingUserMessageBeforeThePromptIsTrimmed() {
        let split = ClaudePipeSession.split([.user("a"), assistant("b"), .user("c"), .user("d")])
        #expect(split.history == [.user("a"), assistant("b")])
        #expect(split.prompt == "[Histórico anterior, em texto]\nUsuário: c\n\nd")
    }

    @Test func unfinishedTurnAfterTheUserMessageBecomesTextAfterIt() {
        let messages: [ChatMessage] = [.user("um"), assistant("ok"), .user("lista"), assistant("vou", calls: [call("c1"), call("c2", "cat", #"{"f":"x"}"#)]), .tool("c1", "a.txt"), .tool("c2", "boom", isError: true)]
        let split = ClaudePipeSession.split(messages)
        #expect(split.history == [.user("um"), assistant("ok")])
        #expect(split.prompt == """
        lista

        [Continuação deste pedido, em texto]
        Assistente: vou
        Ferramenta ls chamada com {"path":"."} → resultado: a.txt
        Ferramenta cat chamada com {"f":"x"} → resultado (erro): boom
        """)
    }

    @Test func callWithoutResultAndStrayResultAreSaid() {
        let split = ClaudePipeSession.split([.user("q"), assistant("", calls: [call("c1")]), .tool("zzz", "solto")])
        #expect(split.prompt == """
        q

        [Continuação deste pedido, em texto]
        Ferramenta ls chamada com {"path":"."} → sem resultado
        Resultado de ferramenta: solto
        """)
    }

    @Test func withoutAUserMessageEverythingIsPromptText() {
        let split = ClaudePipeSession.split([.system("S"), assistant("oi"), assistant("", calls: [call("c1")]), .tool("c1", "r")])
        #expect(split.system == "S")
        #expect(split.history.isEmpty)
        #expect(split.prompt == "[Conversa até aqui, em texto]\nAssistente: oi\nFerramenta ls chamada com {\"path\":\".\"} → resultado: r")
        #expect(ClaudePipeSession.split([]).prompt == "")
    }

    @Test func emptyTrailingAssistantIsTrimmedToo() {
        let split = ClaudePipeSession.split([.user("a"), assistant("b"), assistant(""), .user("c")])
        #expect(split.history == [.user("a"), assistant("b")])
        #expect(split.prompt == "c")
    }

    @Test func imagesInTrimmedMessagesAreMentioned() {
        let image = ImageAttachment(path: "/x.png", mediaType: "image/png", width: 1, height: 1)
        let split = ClaudePipeSession.split([.user("veja", images: [image]), .user("e?")])
        #expect(split.history.isEmpty)
        #expect(split.prompt == "[Histórico anterior, em texto]\nUsuário: veja [1 imagem anexada]\n\ne?")
    }

    // MARK: sessionLines

    @Test func linesAreChainedAndShaped() throws {
        let result = try lines([.user("oi"), assistant("olá")])
        #expect(result.count == 2)
        let first = result[0], second = result[1]
        #expect(first["type"]?.string == "user")
        #expect(first["parentUuid"] == .null)
        #expect(second["parentUuid"] == first["uuid"])
        #expect(first["uuid"]?.string != second["uuid"]?.string)
        for line in result {
            #expect(line["sessionId"]?.string == "s1")
            #expect(line["cwd"]?.string == "/w")
            #expect(line["isSidechain"]?.bool == false)
            #expect(line["userType"]?.string == "external")
            #expect(line["timestamp"]?.string?.hasPrefix("1970-01-01T00:00:00") == true)
        }
        #expect(first["message"]?["content"]?.string == "oi")
        #expect(second["message"]?["role"]?.string == "assistant")
        #expect(second["message"]?["model"]?.string == "m")
        #expect(second["message"]?["content"]?.array == [.object(["type": .string("text"), "text": .string("olá")])])
    }

    @Test func toolCallsAndResultsMapToBlocks() throws {
        let history: [ChatMessage] = [.user("lista"), assistant("vou", calls: [call("c1"), call("c2", "cat", "não é json")]),
                                      .tool("c2", "ruim", isError: true), .tool("c1", "a.txt"), assistant("pronto")]
        let result = try lines(history)
        #expect(result.count == 4)
        let blocks = try #require(result[1]["message"]?["content"]?.array)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .object(["type": .string("tool_use"), "id": .string("c1"), "name": .string("mcp__orb__ls"),
                                      "input": .object(["path": .string(".")])]))
        #expect(blocks[2]["name"]?.string == "mcp__orb__cat")
        #expect(blocks[2]["input"] == .object([:]))
        // One user message, a tool_result per tool message, in their order.
        #expect(result[2]["type"]?.string == "user")
        let results = try #require(result[2]["message"]?["content"]?.array)
        #expect(results.count == 2)
        #expect(results[0] == .object(["type": .string("tool_result"), "tool_use_id": .string("c2"), "content": .string("ruim"), "is_error": .bool(true)]))
        #expect(results[1]["tool_use_id"]?.string == "c1")
        #expect(results[1]["is_error"]?.bool == false)
        #expect(result[3]["message"]?["content"]?.array?.first?["text"]?.string == "pronto")
    }

    @Test func emptyArgumentsAreAnEmptyObject() throws {
        let result = try lines([.user("a"), assistant("", calls: [call("c1", "ls", "")]), .tool("c1", "x"), assistant("b")])
        #expect(result[1]["message"]?["content"]?.array?.first?["input"] == .object([:]))
    }

    @Test func toolResultImagesAreImageBlocks() throws {
        let image = try tempImage(bytes: [9, 8, 7])
        let result = try lines([.user("a"), assistant("", calls: [call("c1")]), .tool("c1", "shot", images: [image]), assistant("b")])
        let content = try #require(result[2]["message"]?["content"]?.array?.first?["content"]?.array)
        #expect(content.count == 2)
        #expect(content[0]["text"]?.string == "shot")
        #expect(content[1]["source"] == .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string(Data([9, 8, 7]).base64EncodedString())]))
    }

    @Test func userImagesAreReadAndUnreadableOnesSkipped() throws {
        let good = try tempImage()
        let bad = ImageAttachment(path: "/nao/existe.png", mediaType: "image/png", width: 1, height: 1)
        let result = try lines([.user("veja", images: [bad, good]), assistant("vi")])
        let content = try #require(result[0]["message"]?["content"]?.array)
        #expect(content.count == 2)
        #expect(content[0]["type"]?.string == "text")
        #expect(content[1]["type"]?.string == "image")
    }

    @Test func unmatchedCallsAndStrayResultsBecomeText() throws {
        // c1 has no result right after it; "zzz" has no call.
        let history: [ChatMessage] = [.user("a"), assistant("x", calls: [call("c1")]), .user("b"), .tool("zzz", "solto"), assistant("fim")]
        let result = try lines(history)
        let blocks = try #require(result[1]["message"]?["content"]?.array)
        #expect(blocks.count == 1)
        #expect(blocks[0]["text"]?.string == "x\nFerramenta ls chamada com {\"path\":\".\"} → sem resultado")
        // user "b" and the stray result are merged into one user message.
        #expect(result.count == 4)
        let user = try #require(result[2]["message"]?["content"]?.array)
        #expect(user.map { $0["text"]?.string } == ["b", "Resultado de ferramenta: solto"])
    }

    @Test func neighboursOfTheSameRoleAreMergedAndEmptyAssistantsSkipped() throws {
        let result = try lines([.user("a"), .user("b"), assistant(""), assistant("c"), assistant("d")])
        #expect(result.count == 2)
        #expect(result[0]["message"]?["content"]?.array?.count == 2)
        #expect(result[1]["message"]?["content"]?.array?.count == 2)
    }

    @Test func historyStartingWithTheAssistantGetsAUserMessageFirst() throws {
        let result = try lines([assistant("Olá, sou o Orb."), .user("oi"), assistant("sim")])
        #expect(result.count == 4)
        #expect(result[0]["type"]?.string == "user")
        #expect(result[1]["type"]?.string == "assistant")
    }

    @Test func emptyHistoryHasNoLines() throws {
        #expect(try lines([]).isEmpty)
    }

    @Test func splitHistoryAlwaysEndsWithAnAssistantLine() throws {
        let messages: [ChatMessage] = [.user("um"), assistant("ok"), .user("lista"), assistant("vou", calls: [call("c1")]), .tool("c1", "a"), .user("continua")]
        let split = ClaudePipeSession.split(messages)
        let result = try lines(split.history)
        #expect(result.last?["type"]?.string == "assistant")
        #expect(result.last?["message"]?["content"]?.array?.contains { $0["type"]?.string == "tool_use" } == false)
    }

    // MARK: userLine

    @Test func userLineWithText() throws {
        let line = try ClaudePipeSession.userLine("oi \"você\"\n", images: [])
        #expect(JSONValue.parse(line) == .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .string("oi \"você\"\n")])]))
        #expect(!line.contains("\n"))
    }

    @Test func userLineWithImages() throws {
        let image = try tempImage(bytes: [5, 6])
        let bad = ImageAttachment(path: "/nao/existe.png", mediaType: "image/png", width: 1, height: 1)
        let line = try #require(JSONValue.parse(ClaudePipeSession.userLine("veja", images: [image, bad])))
        let content = try #require(line["message"]?["content"]?.array)
        #expect(content.count == 2)
        #expect(content[0] == .object(["type": .string("text"), "text": .string("veja")]))
        #expect(content[1]["source"]?["data"]?.string == Data([5, 6]).base64EncodedString())
    }

    @Test func userLineWithOnlyImagesHasNoEmptyTextBlock() throws {
        let image = try tempImage()
        let line = try #require(JSONValue.parse(ClaudePipeSession.userLine("", images: [image])))
        #expect(line["message"]?["content"]?.array?.count == 1)
    }

    // MARK: folders

    @Test func projectDirectoryEscapesTheRealPath() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "pipe é \(UUID().uuidString)", directoryHint: .isDirectory)
        let cwd = base.appending(path: "cwd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = URL(fileURLWithPath: "/Users/someone")
        let folders = ClaudePipeFolders(workingDirectory: cwd, scratch: base.appending(path: "runs"), home: home)

        let real = String(cString: realpath(cwd.path, nil)!)
        // One dash per UTF-16 unit that is not an ASCII letter or digit (as many as the CLI's JavaScript regex gives).
        let expected = String(decoding: real.utf16.map { u -> UInt16 in
            (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) ? u : 0x2D
        }, as: UTF16.self)
        #expect(folders.projectDirectory.deletingLastPathComponent().path == "/Users/someone/.claude/projects")
        #expect(folders.projectDirectory.lastPathComponent == expected)
        #expect(!folders.projectDirectory.lastPathComponent.contains("/"))
        #expect(real.hasPrefix("/private/") || !cwd.path.hasPrefix("/var/"))
    }

    @Test func projectDirectoryOfAFolderThatDoesNotExistYetUsesTheRealParent() {
        let cwd = FileManager.default.temporaryDirectory.appending(path: "pipe-\(UUID().uuidString)/a/b", directoryHint: .isDirectory)
        let folders = ClaudePipeFolders(workingDirectory: cwd, scratch: cwd, home: URL(fileURLWithPath: "/h"))
        let parent = String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)!)
        #expect(ClaudePipeFolders.realPath(cwd).hasPrefix(parent))
        #expect(folders.projectDirectory.lastPathComponent.hasPrefix(parent.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()))
    }

    @Test func standardFoldersLiveUnderTheDataFolder() {
        let folders = ClaudePipeFolders.standard
        #expect(folders.workingDirectory.path.hasSuffix("/claude-pipe/cwd"))
        #expect(folders.scratch.path.hasSuffix("/claude-pipe/runs"))
        #expect(folders.home == FileManager.default.homeDirectoryForCurrentUser)
    }
}
