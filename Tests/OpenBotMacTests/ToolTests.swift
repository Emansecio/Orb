import Foundation
import Testing
@testable import OpenBotMac

final class ToolTests {
    let directory: URL
    let context: ToolContext

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OpenBotToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        context = ToolContext(workingDirectory: directory, remember: { _ in })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: context)
    }

    // MARK: run_command

    @Test func runCommandReportsOutputAndExitCode() async throws {
        let output = try await run(RunCommandTool(), ["command": .string("echo hello; echo oops >&2; exit 3")])
        #expect(output.hasPrefix("Código de saída: 3"))
        #expect(output.contains("hello"))
        #expect(output.contains("oops"))

        let cwd = try await run(RunCommandTool(), ["command": .string("pwd")])
        #expect(cwd.contains(directory.lastPathComponent))
    }

    @Test func runCommandKillsTheProcessTreeOnTimeout() async throws {
        let start = ContinuousClock.now
        let output = try await run(RunCommandTool(), ["command": .string("sleep 30 & echo $!; wait"), "timeout_seconds": .number(1)])
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(output.contains("tempo esgotado"))

        let child = try #require(output.split(separator: "\n").compactMap { pid_t($0) }.first)
        var alive = true
        for _ in 0..<30 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(child, 0) == 0
        }
        #expect(!alive)
    }

    @Test func longOutputKeepsHeadAndTail() async throws {
        let output = try await run(RunCommandTool(), ["command": .string("seq 1 100000")])
        #expect(output.contains("caracteres omitidos"))
        #expect(output.contains("\n1\n2\n3\n"))
        #expect(output.hasSuffix("99999\n100000\n"))
        #expect(output.count < 21_000)
    }

    @Test func cancellationStopsTheCommand() async throws {
        let start = ContinuousClock.now
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    // MARK: Files

    @Test func writeReadAndListWithRelativePaths() async throws {
        let written = try await run(WriteFileTool(), ["path": .string("notes/a.txt"), "content": .string("one\ntwo\nthree\n")])
        #expect(written.hasPrefix("14 bytes"))
        _ = try await run(WriteFileTool(), ["path": .string("notes/a.txt"), "content": .string("four\n"), "append": .bool(true)])

        let all = try await run(ReadFileTool(), ["path": .string("notes/a.txt")])
        #expect(all == "     1\tone\n     2\ttwo\n     3\tthree\n     4\tfour")

        let page = try await run(ReadFileTool(), ["path": .string("notes/a.txt"), "offset": .number(2), "limit": .number(2)])
        #expect(page.hasPrefix("     2\ttwo\n     3\tthree\n"))
        #expect(page.contains("offset=4"))

        let listing = try await run(ListDirectoryTool(), [:])
        #expect(listing.contains("notes/"))
        let notes = try await run(ListDirectoryTool(), ["path": .string("notes")])
        #expect(notes.contains("a.txt  ("))
    }

    @Test func expandsTilde() {
        #expect(context.url(for: "~/x.txt").path == NSHomeDirectory() + "/x.txt")
        #expect(context.url(for: "/tmp/../etc").path == "/etc")
        #expect(context.url(for: "a/../b.txt").path == directory.appending(path: "b.txt").path)
    }

    @Test func readRefusesBinaryFilesAndDirectories() async throws {
        try Data([0x50, 0x4B, 0x00, 0x01]).write(to: directory.appending(path: "blob.bin"))
        await #expect(throws: ToolError.self) { try await run(ReadFileTool(), ["path": .string("blob.bin")]) }
        await #expect(throws: ToolError.self) { try await run(ReadFileTool(), ["path": .string(".")]) }
        await #expect(throws: ToolError.self) { try await run(ReadFileTool(), ["path": .string("missing.txt")]) }
    }

    @Test func listHidesDotfilesUnlessAsked() async throws {
        try Data().write(to: directory.appending(path: ".secret"))
        #expect(try await !run(ListDirectoryTool(), [:]).contains(".secret"))
        #expect(try await run(ListDirectoryTool(), ["show_hidden": .bool(true)]).contains(".secret"))
    }

    @Test func fileNameQueriesUseNameSearch() {
        #expect(SearchFilesTool.looksLikeFileName("budget.xlsx"))
        #expect(!SearchFilesTool.looksLikeFileName("quarterly budget"))
    }

    // MARK: Web

    @Test func htmlBecomesReadableText() {
        let html = """
        <html><head><title> Caf&eacute; &amp; Co </title><style>body { color: red }</style></head>
        <body><nav><a href="/">Home</a></nav>
        <script>alert("x")</script><!-- hidden -->
        <h1>Hello   world</h1>
        <p>See <a href="https://example.com">the docs</a>&nbsp;now &#8212; ok &#x41;.</p>
        <ul><li>One</li><li>Two</li></ul>
        </body></html>
        """
        let page = HTMLText.convert(html)
        #expect(page.title == "Café & Co")
        #expect(page.text == "Hello world\n\nSee the docs now — ok A.\n\n• One\n\n• Two")
    }

    // MARK: Catalog

    @Test func openRiskDependsOnTarget() {
        let tool = OpenTool()
        #expect(tool.risk(.object(["target": .string("https://example.com")])) == .safe)
        #expect(tool.risk(.object(["target": .string("Safari")])) == .sensitive)
        #expect(tool.risk(.object(["target": .string("~/Downloads/app.dmg")])) == .sensitive)
        #expect(tool.risk(.object(["target": .string("file:///Applications/Calculator.app")])) == .sensitive)
    }

    @Test func rememberCallsTheContext() async throws {
        let saved = Saved()
        let context = ToolContext(workingDirectory: directory) { await saved.add($0) }
        _ = try await RememberTool().run(.object(["fact": .string("Prefere respostas curtas.")]), context: context)
        #expect(await saved.facts == ["Prefere respostas curtas."])
    }

    @Test func catalogIsWellFormed() {
        let names = ToolBox.all.map(\.spec.name)
        #expect(Set(names).count == names.count)
        #expect(names.first == "run_command")
        #expect(ToolBox.tool(named: "read_file") is ReadFileTool)
        #expect(ToolBox.tool(named: "nope") == nil)
        for tool in ToolBox.all {
            let parameters = tool.spec.parameters
            #expect(parameters["type"] == .string("object"), "\(tool.spec.name)")
            for required in parameters["required"]?.array ?? [] {
                #expect(parameters["properties"]?[required.string ?? ""] != nil, "\(tool.spec.name)")
            }
            #expect(!tool.spec.description.isEmpty)
        }
    }
}

private actor Saved {
    var facts: [String] = []
    func add(_ fact: String) { facts.append(fact) }
}
