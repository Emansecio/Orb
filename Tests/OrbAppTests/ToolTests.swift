import Foundation
import Testing
@testable import Orb

final class ToolTests {
    let workspace: ToolWorkspace
    var directory: URL { workspace.directory }
    /// Where tool outputs that outgrow the cap are saved, away from the working directory.
    var outputs: URL { workspace.outputs }
    var context: ToolContext { workspace.context }

    init() throws { workspace = try ToolWorkspace() }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await workspace.run(tool, arguments)
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
        let output = try await run(RunCommandTool(), ["command": .string("sleep 30 & echo $!; wait"), "timeout_seconds": .number(2)])
        // Ended by the timeout, not by the thirty seconds of the child. Long enough for the shell to print the child's
        // pid first on a busy machine.
        #expect(ContinuousClock.now - start < .seconds(20))
        #expect(output.contains("tempo esgotado"))

        let child = try #require(output.split(separator: "\n").compactMap { pid_t($0) }.first)
        await waitUntil("the timed-out command's child to be gone") { !processIsAlive(child) }
    }

    @Test func longOutputKeepsHeadAndTail() async throws {
        let output = try await run(RunCommandTool(), ["command": .string("seq 1 100000")])
        #expect(output.contains("caracteres omitidos"))
        #expect(output.contains("\n1\n2\n3\n"))
        #expect(output.contains("99999\n100000\n"))
        #expect(output.contains("full output saved at"))
        #expect(output.count < 21_000)
    }

    @Test func cancellationStopsTheCommand() async throws {
        let start = ContinuousClock.now
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Stopped by the cancellation, not by the thirty seconds of the child.
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    /// Quitting the app mid-turn: the command leads a group of its own, so only `ChildProcessGroups` can stop it.
    @Test func quittingStopsCommandsStillRunning() async throws {
        let pidFile = directory.appending(path: "pid-\(UUID().uuidString)")
        let task = Task {
            try await ProcessRunner.run("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; sleep 30"], timeout: .seconds(60))
        }
        var pid: pid_t = 0
        await waitUntil("the command to write its pid", timeout: .seconds(20)) {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return pid > 0
        }
        #expect(ChildProcessGroups.running.contains(pid))
        ChildProcessGroups.killAllNow(only: [pid])
        let result = try await task.value
        #expect(result.signal == SIGTERM)
        #expect(kill(-pid, 0) != 0)
        // A finished command is no longer registered.
        #expect(!ChildProcessGroups.running.contains(pid))
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
        // Links are kept as "text (url)" so the model can follow them.
        #expect(page.text == "# Hello world\n\nSee the docs (https://example.com) now — ok A.\n\n• One\n• Two")
    }

    // MARK: Catalog

    /// Anything that can change the Mac or send data out (web, open, saving to memory) must go through the
    /// approval gate. Searching the Orb's own memory, looking at the Mac (apps, clipboard, screen, the
    /// browser's front tab, Shortcuts names, another app's interface through ui_read) and showing a notification only read or notify.
    @Test func onlyLocalReadsRunWithoutAsking() {
        let safe = ToolBox.all.filter { $0.risk(.object(["target": .string("https://example.com")])) == .safe }
        #expect(Set(safe.map(\.spec.name)) == [
            "read_file", "list_directory", "search_files", "grep", "glob", "recall", "job_output", "job_stop",
            "shortcuts_list", "clipboard_read", "screenshot", "notify", "apps_list", "app_dictionary", "browser_tab", "ui_read",
            // It writes nothing but the plan of the task, kept with the conversation.
            "task_plan",
            // The Orb's own browser: they look at the page it already has open (which asked first), and "Só leitura" refuses them
            // all the same (`PermissionCall.readsLivePage`).
            "browse_snapshot", "browse_read", "browse_screenshot", "browse_scroll", "browse_back", "browse_tabs", "browse_close",
            // Without an action they only look: waiting, finding text, the dialog's and the proxy's status, the manual.
            "browse_wait", "browse_find", "browse_dialog", "browse_proxy", "browse_run",
        ])
    }

    @Test func rememberAndRecallUseTheOrbsMemory() async throws {
        let bank = MemoryBank(directory: directory.appending(path: "memoria"))
        let context = ToolContext(workingDirectory: directory, memory: bank)
        let saved = try await RememberTool().run(.object(["fact": .string("Prefere respostas curtas."),
                                                          "tipo": .string("preferencia")]), context: context)
        #expect(saved.hasPrefix("Guardado na memória (preferência)"))
        #expect(await bank.snapshot().items(.preferencia).map(\.body) == ["Prefere respostas curtas."])
        let found = try await RecallTool().run(.object(["query": .string("respostas curtas")]), context: context)
        #expect(found.contains("Prefere respostas curtas."))
        await #expect(throws: ToolError.self) {
            try await RememberTool().run(.object(["fact": .string("x")]), context: ToolContext(workingDirectory: directory))
        }
    }

    @Test func catalogIsWellFormed() {
        let names = ToolBox.all.map(\.spec.name)
        #expect(Set(names).count == names.count)
        #expect(names.first == "run_command")
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

