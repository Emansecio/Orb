import Foundation
import Testing
@testable import Orb

/// A stand-in for the user's login shell: `-lic <script>` runs the script after exporting some variables, the
/// way a `.zshrc` would. Lets the tests control exactly what "the user's environment" is.
enum FakeShell {
    static func make(in directory: URL, name: String = "fakeshell", exports: [String: String] = [:], preamble: String = "") throws -> String {
        let script = directory.appending(path: name)
        let lines = exports.map { "export \($0.key)='\($0.value)'" }.joined(separator: "\n")
        try "#!/bin/sh\n\(preamble)\n\(lines)\nexec /bin/sh -c \"$2\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OrbShellTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private let basicEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]

/// How long a fake shell that is expected to answer may take. Production gives the user's shell 5 seconds, which a
/// machine running many tests at once can exceed just starting a script; only tests of the timeout use a short one.
private let patientShell = Duration.seconds(60)

// MARK: - ShellEnvironment

struct ShellEnvironmentTests {
    private let marker = "__ORB_ENV_BEGIN__"

    @Test func parsesEnvOutputAfterTheMarker() {
        let output = "welcome banner\nfrom .zshrc\(marker)PATH=/a:/b\0LANG=pt_BR.UTF-8\0EMPTY=\0EQ=a=b\0MULTI=one\ntwo\0"
        #expect(ShellEnvironment.parse(output) == ["PATH": "/a:/b", "LANG": "pt_BR.UTF-8", "EMPTY": "", "EQ": "a=b", "MULTI": "one\ntwo"])
    }

    @Test func ignoresNoiseAfterTheLastEntryAndMalformedEntries() {
        let output = "\(marker)A=1\0not a variable\0=novalue\0B C=2\0D=4\0logout: bye\n"
        #expect(ShellEnvironment.parse(output) == ["A": "1", "D": "4"])
        #expect(ShellEnvironment.parse("no marker here\0A=1\0") == nil)
        #expect(ShellEnvironment.parse("\(marker)") == [:])
    }

    @Test func preparedEnvironmentIsCleanAndReadable() {
        let prepared = ShellEnvironment.prepared([
            "PATH": "/x", "HOME": "/h", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_AGENT_SDK_VERSION": "1",
            "ORB_DATA_DIR": "/d", "DYLD_INSERT_LIBRARIES": "/lib", "__CFBundleIdentifier": "app.orb", "PWD": "/old",
            "PAGER": "less", "TERM": "xterm-256color",
        ])
        #expect(prepared["PATH"] == "/x")
        #expect(prepared["HOME"] == "/h")
        for leaked in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_AGENT_SDK_VERSION", "ORB_DATA_DIR", "DYLD_INSERT_LIBRARIES",
                       "__CFBundleIdentifier", "PWD"] {
            #expect(prepared[leaked] == nil, "\(leaked)")
        }
        #expect(prepared["TERM"] == "dumb")
        #expect(prepared["PAGER"] == "cat")
        #expect(prepared["GIT_PAGER"] == "cat")
        #expect(prepared["GIT_EDITOR"] == "true" && prepared["GIT_SEQUENCE_EDITOR"] == "false")
        #expect(prepared["GIT_TERMINAL_PROMPT"] == "0")
        #expect(prepared["GIT_CONFIG_COUNT"] == "1")
        #expect(prepared["GIT_CONFIG_KEY_0"] == "core.quotepath")
        #expect(prepared["GIT_CONFIG_VALUE_0"] == "false")
    }

    @Test func gitConfigIsAppendedToTheUsersOwn() {
        let prepared = ShellEnvironment.prepared(["GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "1",
                                                  "GIT_CONFIG_KEY_1": "c.d", "GIT_CONFIG_VALUE_1": "2"])
        #expect(prepared["GIT_CONFIG_COUNT"] == "3")
        #expect(prepared["GIT_CONFIG_KEY_0"] == "a.b")
        #expect(prepared["GIT_CONFIG_KEY_2"] == "core.quotepath")
        #expect(prepared["GIT_CONFIG_VALUE_2"] == "false")
        #expect(ShellEnvironment.prepared(["GIT_CONFIG_COUNT": "junk"])["GIT_CONFIG_KEY_0"] == "core.quotepath")
    }

    @Test func claudeCodeKeepsDroppingItsSessionMarkers() {
        #expect(ShellEnvironment.isClaudeSessionVariable("CLAUDECODE"))
        #expect(ShellEnvironment.isClaudeSessionVariable("CLAUDE_CODE_SSE_PORT"))
        #expect(!ShellEnvironment.isClaudeSessionVariable("CLAUDE_CONFIG_DIR"))
    }

    @Test func choosesTheShellForCommands() throws {
        #expect(ShellEnvironment.commandShell(for: "/bin/zsh") == "/bin/zsh")
        #expect(ShellEnvironment.commandShell(for: "/bin/bash") == "/bin/bash")
        #expect(ShellEnvironment.commandShell(for: "/opt/homebrew/bin/fish") == "/bin/zsh")
        #expect(ShellEnvironment.commandShell(for: "/nonexistent/zsh") == "/bin/zsh")
        #expect(ShellEnvironment.loginShell(in: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(ShellEnvironment.loginShell(in: ["SHELL": "bash"]).hasPrefix("/"))
    }

    @Test func resolvesTheUsersShellEnvironment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = try FakeShell.make(in: directory, exports: ["JAVA_HOME": "/opt/java", "PATH": "/opt/npm/bin:/usr/bin:/bin"],
                                       preamble: "echo 'noisy rc output'")
        let resolved = await ShellEnvironment(shell: shell, base: basicEnvironment.merging(["CLAUDE_CODE_ENTRYPOINT": "x"]) { $1 },
                                          timeout: patientShell).resolved()
        #expect(resolved.isFromUserShell)
        #expect(resolved.shell == "/bin/zsh")
        #expect(resolved.environment["JAVA_HOME"] == "/opt/java")
        #expect(resolved.environment["PATH"] == "/opt/npm/bin:/usr/bin:/bin")
        #expect(resolved.environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(resolved.environment["GIT_PAGER"] == "cat")
    }

    @Test func asksTheShellOnlyOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appending(path: "count")
        let shell = try FakeShell.make(in: directory, preamble: "echo x >> '\(counter.path)'")
        let environment = ShellEnvironment(shell: shell, base: basicEnvironment, timeout: patientShell)
        async let first = environment.resolved()
        async let second = environment.resolved()
        _ = await (first, second, environment.resolved())
        let runs = try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        #expect(runs == 1)
    }

    @Test func fallsBackToTheAppEnvironment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = basicEnvironment.merging(["ORB_DATA_DIR": "/x", "MY_VAR": "kept"]) { $1 }

        let missing = await ShellEnvironment(shell: directory.appending(path: "nope").path, base: base).resolved()
        let failing = await ShellEnvironment(shell: try FakeShell.make(in: directory, name: "fails", preamble: "exit 1"), base: base).resolved()
        let hanging = await ShellEnvironment(shell: try FakeShell.make(in: directory, name: "hangs", preamble: "sleep 30"), base: base,
                                             timeout: .milliseconds(400)).resolved()
        let silent = await ShellEnvironment(shell: "/usr/bin/true", base: base).resolved()
        for fallback in [missing, failing, hanging, silent] {
            #expect(!fallback.isFromUserShell)
            #expect(fallback.environment["MY_VAR"] == "kept")
            #expect(fallback.environment["ORB_DATA_DIR"] == nil)
            #expect(fallback.environment["PAGER"] == "cat")
            #expect(fallback.shell == "/bin/zsh")
        }
    }

    @Test func fallbackCommandsRunWithALoginShell() {
        let user = ShellEnvironment.Resolved(environment: [:], shell: "/bin/zsh", isFromUserShell: true)
        var fallback = user
        fallback.isFromUserShell = false
        #expect(user.arguments(for: "npm test") == ["-c", "npm test"])
        #expect(fallback.arguments(for: "npm test") == ["-lc", "npm test"])
    }

    /// A shell that merely took too long is asked again soon, not 5 minutes later.
    @Test func aSlowShellIsAskedAgainSoon() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slowOnce = directory.appending(path: "slow-once")
        let shell = try FakeShell.make(in: directory, exports: ["FROM_PROFILE": "late"],
                                       preamble: "[ -e '\(slowOnce.path)' ] || { touch '\(slowOnce.path)'; sleep 30; }")
        let environment = ShellEnvironment(shell: shell, base: basicEnvironment, timeout: .seconds(1), retryAfterTimeout: .milliseconds(300),
                                           retryTimeout: .seconds(2))
        let first = await environment.resolved()
        #expect(!first.isFromUserShell)
        // A few tries: a loaded machine may kill the first run before it marks itself as slow, and the new answer
        // comes from the background try that the first of these calls starts.
        var second = first
        for _ in 0..<20 where !second.isFromUserShell {
            try await Task.sleep(for: .milliseconds(400))
            second = await environment.resolved()
        }
        #expect(second.isFromUserShell)
        #expect(second.environment["FROM_PROFILE"] == "late")
    }

    /// A shell that is always slow is not waited for again at every try, and is asked ever less often.
    @Test func anAlwaysSlowShellIsRetriedInTheBackgroundWithBackoff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appending(path: "count")
        let shell = try FakeShell.make(in: directory, preamble: "echo x >> '\(counter.path)'; sleep 5")
        let environment = ShellEnvironment(shell: shell, base: basicEnvironment, timeout: .milliseconds(400),
                                           retryAfterTimeout: .milliseconds(100), retryTimeout: .milliseconds(400))
        _ = await environment.resolved()
        var slowest = Duration.zero
        let end = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < end {
            let started = ContinuousClock.now
            let resolved = await environment.resolved()
            slowest = max(slowest, ContinuousClock.now - started)
            #expect(!resolved.isFromUserShell)
            try await Task.sleep(for: .milliseconds(20))
        }
        // Nobody waits for the new tries (a slow machine allows some margin), and doubling the wait keeps them few.
        #expect(slowest < .milliseconds(300), "\(slowest)")
        // A machine too busy to start the script at all runs it fewer times, never more (a constant wait would make 8).
        let runs = ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count
        #expect(runs <= 6, "\(runs) runs")
    }

    /// A shell that fails (rather than being slow) keeps the long wait, whatever the short one is.
    @Test func aFailingShellIsNotAskedAgainSoon() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appending(path: "count")
        let shell = try FakeShell.make(in: directory, preamble: "echo x >> '\(counter.path)'; exit 1")
        // Patient: on a busy machine the script may take seconds to start, and a timeout is not the failure this tests.
        let environment = ShellEnvironment(shell: shell, base: basicEnvironment, timeout: .seconds(30),
                                           retryAfterTimeout: .milliseconds(1))
        _ = await environment.resolved()
        try await Task.sleep(for: .milliseconds(50))
        _ = await environment.resolved()
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func theRealShellGivesACompleteEnvironment() async {
        // Patient: a timeout would fall back to the app's own environment and this would stop testing the real shell.
        let resolved = await ShellEnvironment(timeout: patientShell).resolved()
        #expect(resolved.environment["PATH"]?.isEmpty == false)
        #expect(resolved.environment["TERM"] == "dumb")
        #expect(resolved.environment["GIT_CONFIG_KEY_\((Int(resolved.environment["GIT_CONFIG_COUNT"] ?? "") ?? 1) - 1)"] == "core.quotepath")
        #expect(FileManager.default.isExecutableFile(atPath: resolved.shell))
    }
}

// MARK: - run_command

final class RunCommandTests {
    let directory: URL
    let context: ToolContext

    init() throws {
        directory = try temporaryDirectory()
        let shell = try FakeShell.make(in: directory, exports: ["FROM_PROFILE": "ok-\u{00E7}"])
        context = ToolContext(workingDirectory: directory, botID: UUID(),
                              jobs: BackgroundJobs(directory: directory.appending(path: "jobs"), firstOutputWindow: patientShell, endsAtFirstOutput: true),
                              shell: ShellEnvironment(shell: shell, base: basicEnvironment, timeout: patientShell),
                              outputsDirectory: directory.appending(path: "saidas"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func run(_ command: String, _ extra: [String: JSONValue] = [:]) async throws -> String {
        try await RunCommandTool().run(.object(extra.merging(["command": .string(command)]) { $1 }), context: context)
    }

    @Test func commandsSeeTheUsersEnvironment() async throws {
        let output = try await run("echo $FROM_PROFILE $TERM $PAGER $GIT_PAGER")
        #expect(output.contains("ok-ç dumb cat cat"))
    }

    @Test func aCommandThatEndsBadlyShowsAsFailedButANoIsAnAnswer() async throws {
        func result(_ command: String) async throws -> ToolResult {
            try await RunCommandTool().runWithImages(.object(["command": .string(command)]), context: context)
        }
        #expect(try await result("echo ok").failed == false)
        #expect(try await result("echo quebrou >&2; exit 2").failed)
        #expect(try await result("kill -TERM $$").failed)
        // `grep` finding nothing: exit 1, nothing printed.
        #expect(try await result("echo abc | grep xyz").failed == false)
        #expect(try await result("echo erro; exit 1").failed)
        #expect(try await result("exit 1").text.hasPrefix("Código de saída: 1"))
    }

    /// With launchd's bare PATH (the shell could not be asked), `-c` would not find tools set up by the login profile.
    private func fallbackContext() throws -> ToolContext {
        let bin = directory.appending(path: "fakebin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let program = bin.appending(path: "meucmd")
        try "#!/bin/sh\necho achei-o\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        try "export PATH='\(bin.path)':$PATH\n".write(to: directory.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        let base = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "ZDOTDIR": directory.path]
        return ToolContext(workingDirectory: directory, botID: UUID(),
                           jobs: BackgroundJobs(directory: directory.appending(path: "jobs"), firstOutputWindow: patientShell, endsAtFirstOutput: true),
                           shell: ShellEnvironment(shell: "/nonexistent/shell", base: base),
                           outputsDirectory: directory.appending(path: "saidas"))
    }

    @Test func commandsFindTheLoginProfilePathWhenTheEnvironmentFellBack() async throws {
        let fallback = try fallbackContext()
        let output = try await RunCommandTool().run(.object(["command": .string("meucmd")]), context: fallback)
        #expect(output.hasPrefix("Código de saída: 0"))
        #expect(output.contains("achei-o"))
        #expect(output.contains("não consegui ler o PATH do Terminal"))
        // The normal path stays quiet.
        #expect(!(try await run("true")).contains("PATH do Terminal"))
    }

    @Test func backgroundJobsFindTheLoginProfilePathWhenTheEnvironmentFellBack() async throws {
        let fallback = try fallbackContext()
        let output = try await RunCommandTool().run(.object(["command": .string("meucmd"), "background": .bool(true)]), context: fallback)
        #expect(output.contains("achei-o"))
        fallback.jobs?.killAllNow()
    }

    @Test func gitShowsAccentedNamesAsTheyAre() async throws {
        let output = try await run("git init -q . && touch ação.txt && git status --short")
        #expect(output.contains("ação.txt"))
        #expect(!output.contains("\\303"))
    }

    /// Foundation decomposes accented letters in process arguments; the command must reach the shell as written.
    @Test func accentedTextReachesTheShellByteForByte() async throws {
        let output = try await run("printf 'caf\u{00E9} a\u{00E7}\u{00E3}o' | xxd -p")
        #expect(output.contains("636166c3a92061c3a7c3a36f"))
    }

    /// Foundation decomposes accented letters in environment values too; they must reach the command as the user wrote them.
    @Test func accentedEnvironmentValuesReachTheCommandByteForByte() async throws {
        let output = try await run("printf %s \"$FROM_PROFILE\" | xxd -p")
        #expect(output.contains("6f6b2dc3a7"))
        #expect(!output.contains("63cca7"))
    }

    @Test func aCrashingProgramIsReportedAsASignal() async throws {
        let crashed = try await run("sh -c 'kill -SEGV $$'")
        #expect(crashed.hasPrefix("Código de saída: encerrado pelo sinal 11 (SIGSEGV)"))
        // Not the last command, so the shell reports 128 + signal; say what that probably is.
        let reported = try await run("sh -c 'kill -SEGV $$'; exit $?")
        #expect(reported.hasPrefix("Código de saída: 139 (provavelmente o sinal 11 (SIGSEGV))"))
        #expect(try await run("exit 200").hasPrefix("Código de saída: 200\n"))
        #expect(Signals.hint(forExitCode: 130) == " (provavelmente o sinal 2 (SIGINT))")
        #expect(Signals.hint(forExitCode: 128) == "" && Signals.hint(forExitCode: 99) == "" && Signals.hint(forExitCode: 255) == "")
    }

    @Test func aSignalIsNotAnExitCode() async throws {
        let terminated = try await run("kill -TERM $$")
        #expect(terminated.hasPrefix("Código de saída: encerrado pelo sinal 15 (SIGTERM)"))
        let killed = try await run("echo before; kill -KILL $$")
        #expect(killed.contains("encerrado pelo sinal 9 (SIGKILL)"))
        #expect(killed.contains("before"))
        #expect(try await run("exit 143").hasPrefix("Código de saída: 143"))
        #expect(Signals.describe(99) == "99")
    }

    @Test func truncationKeepsCharactersWhole() async throws {
        let output = try await run("yes '\u{00E9}' | head -n 30000")
        #expect(!output.contains("\u{FFFD}"))
        let notice = try #require(output.firstMatch(of: /\[\.\.\. (\d+) caracteres omitidos \.\.\.\]/))
        let omitted = try #require(Int(notice.1))
        // Unicode scalars: 30000 lines of "é\n".
        let withoutNote = output.replacing(/\n\[full output saved[^\]]*\]/, with: "")
        let kept = withoutNote.replacing(notice.0, with: "").replacing("Código de saída: 0\n", with: "").unicodeScalars.count
        // Plus the two line breaks that frame the notice.
        #expect(kept + omitted == 60_002)
        #expect(output.count < 20_400)
    }

    @Test func warnsWhenABackgroundChildHoldsTheOutput() async throws {
        // The child must outlive the one second the tool waits for the output to close, however slowly the shell starts.
        let output = try await run("sleep 30 & echo started=$!")
        defer { if let child = pids(in: output).first { kill(child, SIGKILL) } }
        #expect(output.contains("started"))
        #expect(output.contains("background: true"))
    }

    @Test func longOutputIsSavedWholeToAFileTheModelCanRead() async throws {
        let output = try await run("seq 1 100000")
        let note = try #require(output.firstMatch(of: /\[full output saved at ([^;]+?) \((\d+) lines, [^)]*\); read it with read_file/))
        #expect(note.2 == "100000")
        let file = URL(fileURLWithPath: String(note.1))
        #expect(file.path.hasPrefix(directory.appending(path: "saidas").path))
        let saved = try String(contentsOf: file, encoding: .utf8)
        let lines = saved.split(separator: "\n")
        #expect(lines.count == 100_000)
        #expect(lines[0] == "1" && lines[49_999] == "50000" && lines[99_999] == "100000")
        // The middle that the inline output dropped is in the file, and read_file can page to it.
        #expect(!output.contains("\n50000\n"))
        let page = try await ReadFileTool().run(.object(["path": .string(file.path), "offset": .number(50_000), "limit": .number(2)]), context: context)
        #expect(page.contains("50000") && page.contains("50001"))
    }

    @Test func theNoteAboutTheSavedFileSurvivesWhenOldResultsAreShortened() async throws {
        let output = try await run("seq 1 100000")
        let shortened = ContextText.preview(output, limit: 800)
        #expect(shortened.count < output.count / 10)
        #expect(shortened.contains("full output saved at") && shortened.hasSuffix("instead of running the command again]"))
    }

    @Test func theSavedFileStopsAtItsLimitWhenACommandNeverStops() async throws {
        var capture = StreamCapture(limit: 1_000, spillTo: directory.appending(path: "cap.txt"), spillLimit: 5_000)
        // Several chunks after the cut: the file must not be started over.
        var stream = Data()
        for index in 0..<20 {
            let chunk = Data(repeating: UInt8(ascii: "a") + UInt8(index), count: 700)
            stream.append(chunk)
            capture.append(chunk)
        }
        let done = capture.finish()
        #expect(done.fileCut && done.bytes == 14_000)
        #expect(try Data(contentsOf: directory.appending(path: "cap.txt")) == stream.prefix(5_000))
        // The real thing: more than the file holds, then a command that does not end. A fixed amount and a looser
        // timeout instead of `yes` for 3 s: with the whole suite running, fewer than the 50 MB the file holds were read.
        let output = try await run("yes | head -c 55000000; sleep 60", ["timeout_seconds": .number(6)])
        let note = try #require(output.firstMatch(of: /\[full output saved at ([^;]+?) \((\d+) lines, [^)]*file cut at [^)]*\); read it with read_file/))
        let size = try #require(FileManager.default.attributesOfItem(atPath: String(note.1))[.size] as? Int)
        #expect(size <= StreamCapture.maxSpillBytes && size > 1_000_000, "size \(size)")
        #expect(output.contains("tempo esgotado"))
    }

    @Test func shortOutputCreatesNoFile() async throws {
        let output = try await run("seq 1 100")
        #expect(!output.contains("full output saved"))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "saidas").path))
    }

    @Test func outputThatJustFitsIsNotSaved() async throws {
        // 6,000 lines of 3 bytes stay below the 20 KB limit: nothing is cut, nothing is saved.
        let output = try await run("yes ab | head -n 6000")
        #expect(!output.contains("omitidos") && !output.contains("full output saved"))
    }

    @Test func binaryOutputIsReplacedByAShortNote() async throws {
        let output = try await run("head -c 600 /bin/ls")
        #expect(output.contains("saída binária de"))
        #expect(output.contains("xxd"))
        #expect(output.count < 300)
        // Text in a legacy encoding is not binary.
        let latin = try await run("printf 'caf\\351 com acentua\\347\\365es em Latin-1, bem comum em arquivos antigos\\n'")
        #expect(!latin.contains("saída binária"))
    }

    @Test func timeoutMessageSaysHowToRunLongCommands() async throws {
        let output = try await run("sleep 30", ["timeout_seconds": .number(1)])
        #expect(output.contains("tempo esgotado após 1 s"))
        #expect(output.contains("timeout_seconds") && output.contains("background: true"))
    }

    @Test func tellsWhenACommandLeavesProcessesRunning() async throws {
        let output = try await run("nohup sleep 30 >/dev/null 2>&1 & echo started=$!")
        defer { if let child = pids(in: output).first { kill(child, SIGKILL) } }
        #expect(output.contains("started"))
        #expect(output.contains("deixou processos rodando"))
        #expect(output.contains("background: true"))
        // A command that cleans up after itself gets no warning.
        #expect(!(try await run("sleep 0.1 & wait; echo done")).contains("deixou processos"))
    }

    @Test func theApprovalCardSaysWhereTheCommandRuns() {
        let tool = RunCommandTool()
        let inFolder = tool.summary(.object(["command": .string("make")]), context: context)
        #expect(inFolder.detail == "make")
        let sameFolder = tool.summary(.object(["command": .string("make"), "cwd": .string(directory.path)]), context: context)
        #expect(sameFolder.detail == "make")
        let elsewhere = tool.summary(.object(["command": .string("rm *.log"), "cwd": .string("/")]), context: context)
        #expect(elsewhere.detail == "rm *.log\n\nem /")
        let home = tool.summary(.object(["command": .string("ls"), "cwd": .string("~/Documents")]), context: context)
        #expect(home.detail.hasSuffix("em ~/Documents"))
    }

    @Test func gitNeverWaitsForAnEditor() async throws {
        let output = try await run("echo $GIT_EDITOR $GIT_SEQUENCE_EDITOR $GIT_TERMINAL_PROMPT")
        #expect(output.contains("true false 0"))
    }

    @Test func describesWhatTheShellDoesNotKeep() {
        let description = RunCommandTool().spec.description
        for needle in ["cd, export", "cwd", "120", "600", "20 KB", "full text is saved", "background: true", "job_output", "job_stop"] {
            #expect(description.contains(needle), "\(needle)")
        }
    }

    // MARK: Background

    private func pids(in output: String) -> [pid_t] {
        output.split(separator: "\n").compactMap { line in line.split(separator: "=").last.flatMap { pid_t($0) } }
    }

    @Test func backgroundJobLifecycleThroughTheTools() async throws {
        let started = try await run("echo ready; sleep 60", ["background": .bool(true)])
        #expect(started.contains("Processo em segundo plano 1: rodando"))
        #expect(started.contains("ready"))

        let listing = try await JobOutputTool().run(.object([:]), context: context)
        #expect(listing.contains("1  rodando") && listing.contains("echo ready; sleep 60"))

        let output = try await JobOutputTool().run(.object(["id": .string("1"), "lines": .number(5)]), context: context)
        #expect(output.contains("ready") && output.contains("rodando"))
        // Models sometimes send the id as a number.
        #expect(try await JobOutputTool().run(.object(["id": .number(1)]), context: context).contains("ready"))

        let stopped = try await JobStopTool().run(.object(["id": .string("1")]), context: context)
        #expect(stopped.contains("parado"))
        #expect(try await JobOutputTool().run(.object([:]), context: context).contains("parado"))
        await #expect(throws: ToolError.self) { try await JobStopTool().run(.object(["id": .string("9")]), context: context) }
        await #expect(throws: ToolError.self) { try await JobStopTool().run(.object([:]), context: context) }
    }

    @Test func jobToolsNeedAnOrb() async throws {
        let bare = ToolContext(workingDirectory: directory)
        await #expect(throws: ToolError.self) { try await JobOutputTool().run(.object([:]), context: bare) }
        await #expect(throws: ToolError.self) {
            try await RunCommandTool().run(.object(["command": .string("true"), "background": .bool(true)]), context: bare)
        }
    }

    @Test func startingInTheBackgroundIsStillASensitiveCommand() {
        let arguments = JSONValue.object(["command": .string("rm -rf build"), "background": .bool(true)])
        #expect(RunCommandTool().risk(arguments) == .sensitive)
        #expect(RunCommandTool().summary(arguments).title == "Rodando em segundo plano")
        #expect(DangerousCommand.reason(for: arguments["command"]?.string ?? "") != nil)
    }
}

// MARK: - OutputBuffer

struct OutputBufferTests {
    /// Characters kept plus the number the notice reports as omitted.
    private func accounted(_ text: String) -> (kept: Int, omitted: Int)? {
        guard let notice = text.firstMatch(of: /\n\[\.\.\. (\d+) caracteres omitidos \.\.\.\]\n/), let omitted = Int(notice.1) else { return nil }
        return (text.replacing(notice.0, with: "").unicodeScalars.count, omitted)
    }

    @Test(arguments: [1, 2, 3, 5, 7, 4096], [20, 21, 22, 23, 100])
    func cutsNeverSplitACharacter(chunk: Int, limit: Int) throws {
        let text = String(repeating: "aé€😀ü", count: 40)
        let bytes = Array(text.utf8)
        var buffer = OutputBuffer(limit: limit)
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            buffer.append(Data(bytes[start..<min(start + chunk, bytes.count)]))
        }
        let result = buffer.text
        #expect(!result.contains("\u{FFFD}"))
        let counts = try #require(accounted(result))
        #expect(counts.kept + counts.omitted == text.unicodeScalars.count)
        #expect(result.hasPrefix("aé"))
        #expect(result.hasSuffix("ü"))
    }

    @Test func shortOutputIsKeptAsIs() {
        var buffer = OutputBuffer(limit: 100)
        buffer.append(Data("olá, mundo\n".utf8))
        #expect(buffer.text == "olá, mundo\n")
    }

    @Test func partialCharactersAreTrimmed() {
        let bytes = Data("é€😀".utf8)
        #expect(OutputBuffer.withoutPartialCharacter(bytes) == bytes)
        #expect(OutputBuffer.withoutPartialCharacter(bytes.dropLast()) == Data("é€".utf8))
        #expect(OutputBuffer.withoutPartialCharacter(bytes.dropLast(3)) == Data("é€".utf8))
        #expect(OutputBuffer.withoutPartialCharacter(Data("é€".utf8).dropLast()) == Data("é".utf8))
        #expect(OutputBuffer.withoutPartialCharacter(Data()) == Data())
    }
}

// MARK: - BackgroundJobs

final class BackgroundJobsTests {
    let directory: URL
    let jobs: BackgroundJobs
    let bot = UUID()

    init() throws {
        directory = try temporaryDirectory()
        jobs = BackgroundJobs(directory: directory.appending(path: "jobs"))
    }

    deinit { jobs.killAllNow(); try? FileManager.default.removeItem(at: directory) }

    private func start(_ command: String, as bot: UUID? = nil) async throws -> (job: BackgroundJobs.Snapshot, firstOutput: String) {
        try await jobs.start(botID: bot ?? self.bot, command: command, directory: directory, shell: "/bin/zsh", environment: basicEnvironment)
    }

    private func numbers(in output: String) -> [pid_t] {
        output.split(separator: "\n").compactMap { pid_t($0.split(separator: "=").last ?? "") }
    }

    private func isGone(_ pid: pid_t) async -> Bool {
        await waitUntil("process \(pid) to be gone") { !processIsAlive(pid) }
    }

    /// The job's log once it has a line with `marker`. `start` only looks at the log for about a second, which a
    /// machine running other work may spend before the shell has printed anything.
    private func output(of job: BackgroundJobs.Snapshot, as owner: UUID? = nil, containing marker: String, lines: Int = 10) async throws -> String {
        var text = ""
        await waitUntil("job \(job.id) to print \"\(marker)\"") {
            text = (try? await jobs.output(botID: owner ?? bot, id: job.id, lines: lines).text) ?? ""
            return text.contains(marker)
        }
        return text
    }

    /// Waits for the job to be in the state `matches` describes and returns it.
    @discardableResult
    private func waitForJob(_ id: String, as bot: UUID? = nil, _ what: String,
                            where matches: (BackgroundJobs.Snapshot) -> Bool) async -> BackgroundJobs.Snapshot? {
        var found: BackgroundJobs.Snapshot?
        await waitUntil("job \(id) to be \(what)") {
            found = await jobs.list(botID: bot ?? self.bot).first { $0.id == id }
            return found.map(matches) ?? false
        }
        return found
    }

    @Test func startReportsTheFirstOutputAndKeepsRunning() async throws {
        // A window that ends at the first output: how fast this machine starts a shell cannot empty the result.
        let patient = BackgroundJobs(directory: directory.appending(path: "patient"), firstOutputWindow: patientShell, endsAtFirstOutput: true)
        defer { patient.killAllNow() }
        let began = ContinuousClock.now
        let (job, first) = try await patient.start(botID: bot, command: "echo pid=$$; echo oi >&2; sleep 60", directory: directory,
                                                   shell: "/bin/zsh", environment: basicEnvironment)
        // It returns with the first output, not when the sixty seconds of the command are over.
        #expect(ContinuousClock.now - began < .seconds(30))
        #expect(job.isRunning && job.id == "1")
        #expect(first.contains("pid="))
        let pid = try #require(numbers(in: first).first)
        #expect(job.logPath == directory.appending(path: "patient/\(bot.uuidString)/1.log").path)
        #expect(FileManager.default.fileExists(atPath: job.logPath))

        // It outlives the call that started it.
        #expect(kill(pid, 0) == 0)
        #expect(await patient.list(botID: bot).map(\.isRunning) == [true])

        let stopped = try await patient.stop(botID: bot, id: "1")
        #expect(stopped.state == .stopped)
        #expect(await isGone(pid))
        #expect(try await patient.output(botID: bot, id: "1", lines: 10).text.contains("oi"))
    }

    @Test func stoppingKillsTheWholeProcessGroup() async throws {
        let (job, _) = try await start("sleep 300 & echo child=$!; echo shell=$$; wait")
        let found = numbers(in: try await output(of: job, containing: "shell="))
        let (child, shell) = try (#require(found.first), #require(found.last))
        #expect(getpgid(child) == shell)
        #expect(kill(child, 0) == 0)

        _ = try await jobs.stop(botID: bot, id: job.id)
        #expect(await isGone(child))
        #expect(await isGone(shell))
    }

    @Test func stoppingAJobWhoseShellEndedIsRecordedAsAStopEvenWhenTheWatcherNoticedFirst() async throws {
        // The group watcher looks every few milliseconds, so it sees the group empty between the kill and the end of
        // `stop`'s wait on almost every run, which is the order that used to leave the job reported as finished.
        let quick = BackgroundJobs(directory: directory.appending(path: "quick"), firstOutputWindow: patientShell,
                                   endsAtFirstOutput: true, watchInterval: .milliseconds(2))
        defer { quick.killAllNow() }
        for attempt in 1...5 {
            let (job, first) = try await quick.start(botID: bot, command: "sleep 300 & echo child=$!", directory: directory,
                                                     shell: "/bin/zsh", environment: basicEnvironment)
            let child = try #require(numbers(in: first).first)
            await waitUntil("job \(job.id) to finish with its child left running") {
                await quick.list(botID: bot).first { $0.id == job.id }.map { $0.state != .running && $0.leftoverRunning } ?? false
            }
            let stopped = try await quick.stop(botID: bot, id: job.id)
            #expect(stopped.state == .stopped && !stopped.leftoverRunning, "attempt \(attempt): \(stopped.statusText)")
            #expect(stopped.statusText == "parado")
            #expect(await isGone(child))
        }
    }

    @Test func aStubbornJobIsKilledAfterTheGracePeriod() async throws {
        let (job, _) = try await start("trap '' TERM; echo pid=$$; while true; do sleep 1; done")
        let pid = try #require(numbers(in: try await output(of: job, containing: "pid=")).first)
        let began = ContinuousClock.now
        let stopped = try await jobs.stop(botID: bot, id: job.id)
        // Killed after the two seconds of grace, not left running forever.
        #expect(ContinuousClock.now - began < .seconds(30))
        #expect(stopped.state == .stopped)
        #expect(await isGone(pid))
    }

    @Test func aJobThatEndsReportsHowItEnded() async throws {
        let (job, _) = try await start("echo feito; exit 3")
        #expect(try await output(of: job, containing: "feito").contains("feito"))
        let listed = try #require(await waitForJob(job.id, "finished") { $0.state != .running })
        #expect(listed.id == job.id)
        #expect(listed.state == .exited(3))
        #expect(listed.statusText == "terminou com código 3")

        let crashed = try await start("kill -SEGV $$")
        await waitForJob(crashed.job.id, "finished") { $0.state != .running }
        let state = try await jobs.output(botID: bot, id: crashed.job.id, lines: 5).job.state
        #expect(state == .signaled(SIGSEGV))

        // Stopping what already ended is harmless.
        #expect(try await jobs.stop(botID: bot, id: job.id).state == .exited(3))
    }

    @Test func aJobWhoseShellEndedButChildrenRunIsNotReportedAsFinished() async throws {
        let (job, _) = try await start("sleep 300 & echo child=$!")
        let child = try #require(numbers(in: try await output(of: job, containing: "child=")).first)
        let listed = try #require(await waitForJob(job.id, "finished") { $0.state != .running })
        #expect(listed.state == .exited(0))
        #expect(listed.leftoverRunning && listed.isActive && !listed.isRunning)
        #expect(listed.statusText.contains("continuam rodando"))

        let stopped = try await jobs.stop(botID: bot, id: listed.id)
        #expect(stopped.state == .stopped && !stopped.leftoverRunning)
        #expect(await isGone(child))
    }

    @Test func leftoverChildrenCountAgainstTheLimit() async throws {
        for _ in 0..<BackgroundJobs.maxRunningPerOrb { _ = try await start("sleep 300 &") }
        // Every shell is gone and only its child is left; those are the jobs that must still count.
        await waitUntil("every shell to end with its child left running") {
            let all = await jobs.list(botID: bot)
            return all.count == BackgroundJobs.maxRunningPerOrb && all.allSatisfy { $0.state != .running && $0.leftoverRunning }
        }
        await #expect(throws: ToolError.self) { try await self.start("sleep 60") }
    }

    @Test func noticesWhenTheLeftoverChildrenFinish() async throws {
        // The child lives until the test ends it, so how fast the machine is cannot make it finish early.
        let (job, _) = try await start("sleep 300 & echo child=$!")
        let child = try #require(numbers(in: try await output(of: job, containing: "child=")).first)
        let before = try #require(await waitForJob(job.id, "finished with its child left running") { $0.state != .running })
        #expect(before.leftoverRunning)
        kill(child, SIGKILL)
        await waitForJob(job.id, "free of leftover children") { !$0.leftoverRunning }
        let listed = try #require(await jobs.list(botID: bot).first)
        #expect(!listed.leftoverRunning && listed.state == .exited(0))
        #expect(listed.statusText == "terminou com código 0")
        // Nothing is left to signal: stopping now leaves the record as it is.
        #expect(try await jobs.stop(botID: bot, id: listed.id).state == .exited(0))
    }

    @Test func aCrashedJobIsReportedAsASignal() async throws {
        let crashed = try await start("sh -c 'kill -SEGV $$'")
        await waitForJob(crashed.job.id, "finished") { $0.state != .running }
        let job = try await jobs.output(botID: bot, id: crashed.job.id, lines: 5).job
        #expect(job.state == .signaled(SIGSEGV))
        #expect(job.statusText == "encerrado pelo sinal 11 (SIGSEGV)")
    }

    @Test func accentedEnvironmentAndArgumentsReachAJobUnchanged() async throws {
        let (job, _) = try await jobs.start(botID: bot, command: "printf '%s|caf\u{00E9}' \"$NOME\" | xxd -p", directory: directory,
                                            shell: "/bin/zsh", environment: basicEnvironment.merging(["NOME": "Jo\u{00E3}o"]) { $1 })
        let text = try await output(of: job, containing: "4a6fc3a36f7c636166c3a9", lines: 5)
        #expect(text.contains("4a6fc3a36f7c636166c3a9"), "\(text)")
    }

    @Test func jobsBelongToTheirOrb() async throws {
        let (job, _) = try await start("sleep 60")
        let other = UUID()
        await #expect(throws: ToolError.self) { try await jobs.output(botID: other, id: job.id, lines: 5) }
        await #expect(throws: ToolError.self) { try await jobs.stop(botID: other, id: job.id) }
        #expect(await jobs.list(botID: other).isEmpty)
        let second = try await start("sleep 60", as: other)
        #expect(second.job.id == "1")
        #expect(second.job.logPath != job.logPath)
    }

    @Test func deletingTheOrbEndsItsJobsAndLogs() async throws {
        let (job, _) = try await start("echo pid=$$; sleep 60")
        let pid = try #require(numbers(in: try await output(of: job, containing: "pid=")).first)
        await jobs.forget(botID: bot)
        #expect(await isGone(pid))
        #expect(await jobs.list(botID: bot).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: job.logPath))
    }

    @Test func quittingKillsEveryGroup() async throws {
        let other = UUID()
        let (firstJob, _) = try await start("sleep 300 & echo child=$!; echo shell=$$; wait")
        let (secondJob, _) = try await start("echo pid=$$; sleep 300", as: other)
        let first = try await output(of: firstJob, containing: "shell=")
        let second = try await output(of: secondJob, as: other, containing: "pid=")
        let pids = numbers(in: first) + numbers(in: second)
        #expect(pids.count == 3)
        jobs.killAllNow()
        for pid in pids { #expect(await isGone(pid)) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "jobs").path))
    }

    @Test func limitsRunningJobsPerOrb() async throws {
        let (jobs, bot, directory) = (jobs, bot, directory)
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<BackgroundJobs.maxRunningPerOrb {
                group.addTask {
                    _ = try await jobs.start(botID: bot, command: "sleep 60", directory: directory, shell: "/bin/zsh", environment: basicEnvironment)
                }
            }
        }
        #expect(await jobs.list(botID: bot).count == BackgroundJobs.maxRunningPerOrb)
        await #expect(throws: ToolError.self) { try await self.start("sleep 60") }
    }

    @Test func failsClearlyWhenTheShellIsMissing() async throws {
        await #expect(throws: ToolError.self) {
            try await self.jobs.start(botID: self.bot, command: "true", directory: self.directory, shell: "/nonexistent/sh", environment: [:])
        }
        #expect(await jobs.list(botID: bot).isEmpty)
    }

    @Test func tailKeepsWholeCharactersAndTheLastLines() throws {
        let log = directory.appending(path: "big.log")
        let line = "linha ação 😀 número\n"
        let text = (1...5000).map { "\($0) " + line }.joined()
        try text.write(to: log, atomically: true, encoding: .utf8)
        #expect(Int(try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0) > 64_000)

        let tail = BackgroundJobs.tail(of: log, lines: 3)
        #expect(tail == (4998...5000).map { "\($0) " + line.dropLast() }.joined(separator: "\n"))
        let wide = BackgroundJobs.tail(of: log, lines: 100_000)
        #expect(!wide.contains("\u{FFFD}"))
        #expect(wide.hasSuffix("5000 " + line.dropLast()))
        #expect(BackgroundJobs.tail(of: directory.appending(path: "missing.log"), lines: 3) == "")
        let small = directory.appending(path: "small.log")
        try "a\nb\n".write(to: small, atomically: true, encoding: .utf8)
        #expect(BackgroundJobs.tail(of: small, lines: 5) == "a\nb")
        #expect(BackgroundJobs.tail(of: small, lines: 1) == "b")
    }
}
