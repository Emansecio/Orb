import Foundation
import Testing
@testable import Orb

// Sample lines follow what Claude Code 2.1.292 printed in headless probes (logged out, isolated config dir)
// and the Agent SDK (anthropics/claude-agent-sdk-python).

struct ClaudeCodeResultTests {
    @Test func resultsPickTheMostInformativeText() {
        let success = ClaudeCodeParser.result(JSONValue.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Pronto."}"#)!)
        #expect(success == ClaudeCodeResult(isError: false, message: "Pronto."))
        let missing = ClaudeCodeParser.result(JSONValue.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: 1111"]}"#)!)
        #expect(missing == ClaudeCodeResult(isError: true, message: "No conversation found with session ID: 1111"))
        let apiFailure = ClaudeCodeParser.result(JSONValue.parse(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 overloaded"}"#)!)
        #expect(apiFailure == ClaudeCodeResult(isError: true, message: "API Error: 529 overloaded"))
        #expect(ClaudeCodeParser.result(.object(["is_error": .bool(true), "subtype": .string("error_max_turns")])).message == "error_max_turns")
        #expect(ClaudeCodeParser.result(.object(["is_error": .bool(true)])).message == "erro desconhecido")
    }
}

struct ClaudeCodeWireTests {
    @Test func linesWeWrite() throws {
        let initialize = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_1", subtype: "initialize")))
        #expect(initialize == .object(["type": .string("control_request"), "request_id": .string("req_1"),
                                       "request": .object(["subtype": .string("initialize"), "hooks": .null])]))
        let interrupt = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_2", subtype: "interrupt")))
        #expect(interrupt["request"] == .object(["subtype": .string("interrupt")]))
        #expect(ClaudeCodeWire.newRequestID().hasPrefix("req_1_"))
    }

    @Test func permissionRoundTrip() throws {
        let input: JSONValue = .object(["file_path": .string("/tmp/a.txt"), "content": .string("x")])
        let allow = try #require(JSONValue.parse(ClaudeCodeWire.permissionResponse(requestID: "req_5", answer: .allow, input: input)))
        #expect(allow == .object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string("req_5"),
            "response": .object(["behavior": .string("allow"), "updatedInput": input]),
        ])]))
        let deny = try #require(JSONValue.parse(ClaudeCodeWire.permissionResponse(requestID: "req_5", answer: .deny("não"), input: input)))
        #expect(deny["response"]?["response"] == .object(["behavior": .string("deny"), "message": .string("não")]))
        let error = try #require(JSONValue.parse(ClaudeCodeWire.errorResponse(requestID: "req_6", message: "nope")))
        #expect(error["response"] == .object(["subtype": .string("error"), "request_id": .string("req_6"), "error": .string("nope")]))
    }

    @Test func modelsComeFromTheInitializeAnswer() {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_1_abcd","response":{"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)"},{"value":"claude-fable-5-1[1m]","displayName":"Fable"},{"value":"sonnet","displayName":"Sonnet"},{"displayName":"sem valor"}]}}}"#
        let models = ClaudeCodeWire.models(fromInitializeResponse: line, requestID: "req_1_abcd")
        #expect(models?.map(\.id) == ["default", "claude-fable-5-1[1m]", "sonnet"])
        #expect(models?.map(\.name) == ["Padrão do Claude Code", "Fable", "Sonnet"])
        #expect(models?.allSatisfy { $0.format == .claudeCode } == true)
        #expect(ClaudeCodeWire.models(fromInitializeResponse: line, requestID: "other") == nil)
        #expect(ModelRef("claudeCode/claude-fable-5-1[1m]")?.model == "claude-fable-5-1[1m]")
    }
}

struct ClaudeCodeAccountTests {
    @Test func loggedOutStatus() {
        let output = """
        {
          "loggedIn": false,
          "authMethod": "none",
          "apiProvider": "firstParty",
          "analyticsDisabled": false
        }
        """
        let status = ClaudeCodeStatus.parse(output)
        #expect(status.isInstalled && !status.isLoggedIn)
        #expect(status.authMethod == "none")
    }

    @Test func loggedInStatusWithNoiseAround() {
        let output = """
        Warning: something
        {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"ana@example.com","orgId":"o1","orgName":"Ana","subscriptionType":"max"}
        """
        let status = ClaudeCodeStatus.parse(output)
        #expect(status.isLoggedIn)
        #expect(status.email == "ana@example.com" && status.plan == "max" && status.organization == "Ana")
        #expect(status.accountLabel == "ana@example.com · Claude Max")
        #expect(ClaudeCodeStatus.parse("garbage") == ClaudeCodeStatus(isInstalled: true))
    }

    @Test func shellProbeAndEnvironment() {
        let probe = ClaudeCode.parseShellProbe("Welcome!\n__orb__claude=/Users/a/.local/bin/claude\n__orb__path=/usr/bin:/bin\n")
        #expect(probe.claude == "/Users/a/.local/bin/claude" && probe.path == "/usr/bin:/bin")
        #expect(ClaudeCode.parseShellProbe("__orb__claude=\n").claude == nil)
        let environment = ClaudeCode.environment(["HOME": "/h", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "x",
                                                  "CLAUDE_AGENT_SDK_VERSION": "1", "HTTPS_PROXY": "http://proxy:3128", "ANTHROPIC_MODEL": "m"], path: "/p")
        #expect(environment == ["HOME": "/h", "HTTPS_PROXY": "http://proxy:3128", "PATH": "/p"])
    }
}

struct ClaudeCodeProcessTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OrbClaudeEnv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theCLIGetsTheUsersTerminalEnvironmentLikeTheNativeCommands() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A `.zshrc` that exports a variable and extends the PATH, which a plain login shell would not run.
        let rc = try FakeShell.make(in: directory, exports: ["ONLY_IN_ZSHRC": "ok", "JAVA_HOME": "/jdk", "PATH": "/rc/bin:/usr/bin:/bin"])
        let shell = ShellEnvironment(shell: rc, base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "CLAUDECODE": "1"], timeout: .seconds(60))
        let installation = ClaudeCode.Installation(executable: URL(fileURLWithPath: "/opt/claude/bin/claude"), path: "/probe/only")
        let environment = await ClaudeCode.shared.environment(for: installation, shell: shell)
        #expect(environment["ONLY_IN_ZSHRC"] == "ok" && environment["JAVA_HOME"] == "/jdk")
        // claude's own folder is in front, then what the shell had; the probe's PATH is not used.
        #expect(environment["PATH"] == "/opt/claude/bin:/rc/bin:/usr/bin:/bin")
        #expect(environment["CLAUDECODE"] == nil)
    }

    @Test func aClaudeInstalledThroughTheZshrcPathIsFound() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // npm, nvm, fnm and Volta extend the PATH in `.zshrc`, which the login (not interactive) probe never reads.
        let bin = directory.appending(path: "nvm/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\necho claude\n", to: bin.appending(path: "claude"))
        let home = directory.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let login = try FakeShell.make(in: directory, name: "loginshell", preamble: "PATH=/usr/bin:/bin; export PATH")
        let rc = try FakeShell.make(in: directory, exports: ["PATH": "\(bin.path):/usr/bin:/bin"])
        let shell = ShellEnvironment(shell: rc, base: ["PATH": "/usr/bin:/bin", "HOME": home.path], timeout: .seconds(60))
        let installation = try #require(await ClaudeCode().installation(refresh: true, shell: shell, environment: ["SHELL": login], home: home.path))
        #expect(installation.executable.path == bin.appending(path: "claude").path)
        #expect(installation.path.hasPrefix(bin.path))
    }

    @Test func theProvidersCredentialsOfTheUsersShellDoNotReachTheCLI() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A `.zshrc` exporting an API key would otherwise swap the claude.ai sign-in for API billing in `claude -p`.
        let rc = try FakeShell.make(in: directory, exports: ["ANTHROPIC_API_KEY": "sk-teste", "ANTHROPIC_BASE_URL": "https://outro.example",
                                                             "ANTHROPIC_AUTH_TOKEN": "tok", "JAVA_HOME": "/jdk"])
        let shell = ShellEnvironment(shell: rc, base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: .seconds(60))
        let installation = ClaudeCode.Installation(executable: URL(fileURLWithPath: "/opt/claude/bin/claude"), path: "/probe/only")
        let environment = await ClaudeCode.shared.environment(for: installation, shell: shell)
        #expect(environment["JAVA_HOME"] == "/jdk")
        #expect(environment.keys.filter { $0.hasPrefix("ANTHROPIC_") }.isEmpty)
        #expect(ClaudeCode.environment(["ANTHROPIC_API_KEY": "x", "FOO": "1"], path: "/p") == ["FOO": "1", "PATH": "/p"])
    }

    /// The CLI defers the connectors' tools by itself; a `.zshrc` that turns that off would send them all with every message.
    @Test func aShellThatTurnsToolSearchOffDoesNotReachTheCLI() {
        for off in ["false", "0", "FALSE", "off"] {
            #expect(ClaudeCode.environment(["ENABLE_TOOL_SEARCH": off, "FOO": "1"], path: "/p") == ["FOO": "1", "PATH": "/p"])
        }
        // Any other value is the user's own choice (`auto`, `true`) and stays.
        #expect(ClaudeCode.environment(["ENABLE_TOOL_SEARCH": "auto:10"], path: "/p")["ENABLE_TOOL_SEARCH"] == "auto:10")
    }

    @Test func withoutAnswerFromTheShellTheLoginPathStandsIn() async {
        let shell = ShellEnvironment(shell: "/nonexistent/shell", base: ["PATH": "/x"], timeout: .seconds(5))
        let installation = ClaudeCode.Installation(executable: URL(fileURLWithPath: "/opt/claude/bin/claude"), path: "/probe/only")
        let environment = await ClaudeCode.shared.environment(for: installation, shell: shell)
        #expect(environment["PATH"] == "/probe/only")
    }

    @Test func theFolderOfClaudeIsAddedOnlyWhenMissing() {
        let claude = URL(fileURLWithPath: "/a/bin/claude")
        #expect(ClaudeCode.path("/x:/y", including: claude) == "/a/bin:/x:/y")
        #expect(ClaudeCode.path("/x:/a/bin:/y", including: claude) == "/x:/a/bin:/y")
        #expect(ClaudeCode.path(nil, including: claude) == "/a/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// Foundation's `Process` decomposes accents (é becomes e + U+0301); the persona and memory sent to the CLI in
    /// `--append-system-prompt` must arrive as written.
    @Test func argumentsAndEnvironmentReachTheChildByteForByte() async throws {
        let process = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$1\" | xxd -p; printf %s \"$NOME\" | xxd -p", "sh", "Jo\u{00E3}o"],
            directory: FileManager.default.temporaryDirectory, environment: ["NOME": "Jo\u{00E3}o", "PATH": "/usr/bin:/bin"])
        process.closeInput()
        var lines: [String] = []
        for await line in process.lines { lines.append(line) }
        #expect(lines == ["4a6fc3a36f", "4a6fc3a36f"], Comment(rawValue: "\(lines)"))
    }

    @Test func linesFlowBothWaysAndStderrIsKept() async throws {
        let process = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo started; echo oops >&2; read line; echo \"got:$line\"; exit 3"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        var iterator = process.lines.makeAsyncIterator()
        #expect(await iterator.next() == "started")
        process.send("hello")
        #expect(await iterator.next() == "got:hello")
        #expect(await iterator.next() == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(process.errorOutput == "oops")
    }

    /// The child closes stdout and only then writes why it is leaving: reading `errorOutput` right after stdout ends would miss it.
    @Test func theReasonOnStderrIsAwaitedAfterStdoutCloses() async throws {
        let process = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 1>&-; sleep 0.3; echo motivo-final >&2; exit 3"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        process.closeInput()
        for await _ in process.lines {}
        #expect(await process.finalErrorOutput() == "motivo-final")
        // A stderr that never closes does not hold the caller for longer than the limit.
        let held = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 1>&-; sleep 5"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        let started = ContinuousClock.now
        for await _ in held.lines {}
        #expect(await held.finalErrorOutput(waitingUpTo: .milliseconds(200)) == "")
        #expect(ContinuousClock.now - started < .seconds(3))
        held.terminate(after: 0)
        held.closeInput()
    }

    @Test func quittingStopsTheCLIAndWhatItLaunched() async throws {
        let process = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $$; sleep 60 & echo $!; wait"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        var iterator = process.lines.makeAsyncIterator()
        let leader = try #require(await iterator.next().flatMap { pid_t($0) })
        let child = try #require(await iterator.next().flatMap { pid_t($0) })
        #expect(ChildProcessGroups.running.contains(leader))
        ChildProcessGroups.killAllNow(only: [leader])
        #expect(await iterator.next() == nil)
        for _ in 0..<50 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(child, 0) != 0)
        for _ in 0..<50 where ChildProcessGroups.running.contains(leader) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!ChildProcessGroups.running.contains(leader))
        process.closeInput()
    }

    @Test func aMissingExecutableThrowsInsteadOfLeavingPipesOpen() {
        #expect(throws: (any Error).self) {
            try LineProcess(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                            directory: FileManager.default.temporaryDirectory, environment: [:])
        }
    }

    @Test func terminateStopsTheChildAndWhatItLaunched() async throws {
        let process = try LineProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 60 & echo $!; wait"],
            directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        var iterator = process.lines.makeAsyncIterator()
        let child = try #require(await iterator.next().flatMap { pid_t($0) })
        #expect(kill(child, 0) == 0)
        process.terminate(after: 0)
        #expect(await iterator.next() == nil)
        for _ in 0..<50 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(child, 0) != 0, "the grandchild is gone too")
        process.closeInput()
    }
}
