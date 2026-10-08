import Foundation
import Testing
@testable import Orb

/// A stand-in `claude` that speaks the stream-json + control protocol: answers `initialize`, then for the user
/// message streams text, asks permission for a Bash call and reports the result. Logs argv and stdin lines.
private let fakeClaude = #"""
#!/usr/bin/python3
import json, os, sys, time

log = open(os.environ["FAKE_CLAUDE_LOG"], "a")
def note(text):
    log.write(text.rstrip("\n") + "\n"); log.flush()
def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

note(json.dumps({"args": sys.argv[1:]}))
session = next((a.split("=", 1)[1] for a in sys.argv if a.startswith(("--session-id=", "--resume="))), "none")
scenario = os.environ.get("FAKE_CLAUDE_SCENARIO", "tool")
for raw in sys.stdin:
    note(raw)
    msg = json.loads(raw)
    kind = msg.get("type")
    if kind == "control_request" and msg["request"]["subtype"] == "initialize":
        if scenario == "init_silent":
            time.sleep(120)  # never answers, and ignores its stdin closing
        if scenario == "init_error":
            emit({"type": "control_response", "response": {"subtype": "error", "request_id": msg["request_id"], "error": "boom: config invalida"}})
            continue
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"models": []}}})
    elif kind == "user":
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test"})
        if scenario == "hang":
            continue
        if scenario == "no_result":
            emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
                  "message": {"id": "msg_9", "model": "claude-test", "content": [{"type": "text", "text": "Comecei, mas"}]}})
            break
        emit({"type": "stream_event", "parent_tool_use_id": None, "session_id": session, "uuid": "1",
              "event": {"type": "message_start", "message": {"id": "msg_1"}}})
        emit({"type": "stream_event", "parent_tool_use_id": None, "session_id": session, "uuid": "2",
              "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Vou listar."}}})
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_1", "model": "claude-test", "content": [{"type": "text", "text": "Vou listar."}]}})
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_1", "model": "claude-test", "content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}}]}})
        emit({"type": "control_request", "request_id": "perm_1", "request": {"subtype": "can_use_tool", "tool_name": "Bash",
              "input": {"command": "ls"}, "tool_use_id": "toolu_1", "permission_suggestions": None, "blocked_path": None}})
        answer = sys.stdin.readline()
        note(answer)
        response = json.loads(answer)["response"]["response"]
        if response["behavior"] == "allow":
            content, is_error = "a.txt", False
        else:
            content, is_error = response["message"], True
        emit({"type": "user", "parent_tool_use_id": None, "session_id": session,
              "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": content, "is_error": is_error}]}})
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_2", "model": "claude-test", "content": [{"type": "text", "text": "Pronto."}]}})
        emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "session_id": session, "result": "Pronto."})
note("eof")
"""#

private actor SessionFlag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

private struct FakeClaude {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("claude") }
    var log: URL { directory.appendingPathComponent("log.txt") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("claude").path, contents: Data(fakeClaude.utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    func turn(mode: PermissionMode, scenario: String = "tool", sessionID: String? = nil) -> ClaudeCodeTurn {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), permissionMode: mode)
        bot.workingDirectory = directory.path
        return ClaudeCodeTurn(bot: bot, executable: executable, model: "sonnet", system: "persona", prompt: "liste os arquivos",
                              sessionID: sessionID, environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LOG": log.path,
                                                                  "FAKE_CLAUDE_SCENARIO": scenario])
    }

    /// Logged lines, once one contains `marker`. The marker is something the fake always logs, so the wait is
    /// generous (an interpreter on a busy machine can take seconds to start) and ends as soon as it appears.
    func logLines(waitingFor marker: String, timeout: Duration = .seconds(30)) async -> [String] {
        var text = ""
        await waitUntil("the fake CLI to log \"\(marker)\"", timeout: timeout) {
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.contains(marker)
        }
        return text.split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct ClaudeCodeEngineTests {
    /// Collects a turn's events, answering every approval with `decision`.
    private func run(_ engine: ClaudeCodeEngine, _ turn: ClaudeCodeTurn, decision: ApprovalDecision = .once) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(turn) {
            events.append(event)
            if case .approval(let approval) = event { await engine.gate.resolve(approvalID: approval.id, decision: decision) }
        }
        return events
    }

    /// What other models did reaches Claude Code before the prompt, but the history keeps only the user's words.
    @Test func catchUpContextIsSentButNotRecorded() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        var turn = fake.turn(mode: .auto, sessionID: "sess-1")
        turn.context = "Earlier in this Orb conversation: CONTEXTO-DE-TESTE"
        let events = await run(ClaudeCodeEngine(), turn)

        guard case .message(let user) = events.first else { Issue.record("no user message"); return }
        #expect(user == .user("liste os arquivos"))
        let lines = await fake.logLines(waitingFor: "eof")
        let userLine = lines.dropFirst().compactMap { JSONValue.parse($0) }.first { $0["type"] == .string("user") }
        let sent = userLine?["message"]?["content"]?.string ?? userLine?.jsonString ?? ""
        #expect(sent.contains("CONTEXTO-DE-TESTE"))
        #expect(sent.contains("liste os arquivos"))
    }

    @Test func theUsersPicturesAreRecordedWithTheMessage() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let image = ImageAttachment(path: "/d/anexos/x/1.jpg", mediaType: "image/jpeg", width: 1, height: 1)
        var turn = fake.turn(mode: .auto, sessionID: "sess-1")
        turn.images = [image]
        let events = await run(ClaudeCodeEngine(), turn)
        guard case .message(let user) = events.first else { Issue.record("no user message"); return }
        #expect(user == .user("liste os arquivos", images: [image]))
    }

    @Test func approvedToolRunsEndToEnd() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .ask, sessionID: "sess-1"))

        guard case .message(let user) = events.first else { Issue.record("no user message"); return }
        #expect(user == .user("liste os arquivos"))
        #expect(events.contains { if case .session("sess-1") = $0 { true } else { false } })
        let approvals = events.compactMap { if case .approval(let request) = $0 { request } else { nil } }
        #expect(approvals.map(\.toolName) == ["Bash"] && approvals.first?.command == "ls")
        let finished = events.compactMap { if case .toolFinished(_, let state, let output) = $0 { (state, output) } else { nil } }
        #expect(finished.count == 1 && finished[0].0 == .done && finished[0].1 == "a.txt")
        guard case .message(let reply) = events.last else { Issue.record("no reply"); return }
        #expect(reply.content.hasPrefix("Vou listar.\n\nPronto.\n\n(Actions taken in this turn: "))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })

        let lines = await fake.logLines(waitingFor: "eof")
        let logged = lines.first.flatMap { JSONValue.parse($0) }
        let args = logged?["args"]?.array?.compactMap(\.string) ?? []
        #expect(args.contains("--resume=sess-1") && args.contains("--model=sonnet") && args.contains("--append-system-prompt=persona"))
        // The Orb works outside the home folder (here a temporary one), so reading the user's files does not prompt.
        #expect(args.contains("--add-dir=\(FileManager.default.homeDirectoryForCurrentUser.path)"))
        let sent = lines.dropFirst().compactMap { JSONValue.parse($0) }
        #expect(sent.first?["request"]?["subtype"] == .string("initialize"))
        #expect(sent.dropFirst().first?["type"] == .string("user"))
        let answer = try #require(sent.first { $0["type"] == .string("control_response") })
        #expect(answer["response"]?["request_id"] == .string("perm_1"))
        #expect(answer["response"]?["response"] == .object(["behavior": .string("allow"),
                                                              "updatedInput": .object(["command": .string("ls")])]))
        #expect(lines.last == "eof")
    }

    @Test func deniedToolIsReportedInPortuguese() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .ask), decision: .deny)
        let finished = events.compactMap { if case .toolFinished(_, let state, let output) = $0 { (state, output) } else { nil } }
        #expect(finished.count == 1 && finished[0].0 == .failed && finished[0].1 == "Você negou esta ação.")
        let lines = await fake.logLines(waitingFor: "eof")
        #expect(lines.contains { $0.contains(#""behavior":"deny""#) })
    }

    @Test func theNoteOnADenialIsInTheMessageClaudeCodeGets() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let engine = ClaudeCodeEngine()
        for await event in engine.run(fake.turn(mode: .ask)) {
            if case .approval(let approval) = event {
                await engine.gate.resolve(approvalID: approval.id, answer: ApprovalAnswer(decision: .deny, note: "  liste só os .swift  "))
            }
        }
        let lines = await fake.logLines(waitingFor: "eof")
        let answer = try #require(lines.compactMap { JSONValue.parse($0) }.first { $0["type"] == .string("control_response") && $0["response"]?["request_id"] == .string("perm_1") })
        let reply = answer["response"]?["response"]
        #expect(reply?["behavior"] == .string("deny"))
        #expect(reply?["message"] == .string(ClaudeCodePolicy.userDenial + " The user said: liste só os .swift"))
    }

    @Test func aDenialWithoutANoteKeepsTheUsualMessage() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        _ = await run(ClaudeCodeEngine(), fake.turn(mode: .ask), decision: .deny)
        let lines = await fake.logLines(waitingFor: "eof")
        let answer = try #require(lines.compactMap { JSONValue.parse($0) }.first { $0["type"] == .string("control_response") && $0["response"]?["request_id"] == .string("perm_1") })
        #expect(answer["response"]?["response"]?["message"] == .string(ClaudeCodePolicy.userDenial))
    }

    @Test func automaticModeNeverAsks() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .auto))
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        let lines = await fake.logLines(waitingFor: "eof")
        let args = lines.first ?? ""
        #expect(args.contains("acceptEdits") && args.contains("--session-id="))
    }

    @Test func theCardOffersRulesForWhatWasAsked() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .ask), decision: .deny)
        let approvals = events.compactMap { if case .approval(let request) = $0 { request } else { nil } }
        #expect(approvals.first?.suggestions == [.shell("ls")])
    }

    @Test func rulesAreReadWhenTheRequestArrivesNotWhenTheTurnStarts() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        // The turn started with no grants; the app has one by the time Claude Code asks.
        var turn = fake.turn(mode: .ask)
        turn.permissions = { PermissionState(mode: .ask, rules: [.shell("ls")]) }
        let events = await run(ClaudeCodeEngine(), turn, decision: .deny)
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        let finished = events.compactMap { if case .toolFinished(_, let state, _) = $0 { state } else { nil } }
        #expect(finished == [.done])
    }

    @Test func aModeChosenAfterTheTurnStartedWins() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        var turn = fake.turn(mode: .bypass)
        turn.permissions = { PermissionState(mode: .readOnly, rules: [.shell("ls")]) }
        let events = await run(ClaudeCodeEngine(), turn)
        let finished = events.compactMap { if case .toolFinished(_, let state, let output) = $0 { (state, output) } else { nil } }
        #expect(finished.count == 1 && finished[0].0 == .failed && finished[0].1 == "Bloqueado: o Orb está em modo Só leitura.")
        let lines = await fake.logLines(waitingFor: "eof")
        #expect(lines.contains { $0.contains(#""behavior":"deny""#) })
    }

    @Test func aGrantFromTheOtherEngineStillApplies() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        var turn = fake.turn(mode: .ask)
        turn.bot.permissionRules = PermissionPolicy.legacyRules(fromToolNames: ["run_command"])
        let events = await run(ClaudeCodeEngine(), turn, decision: .deny)
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
    }

    @Test func changingTheModeDuringTheTurnTellsClaudeCode() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let engine = ClaudeCodeEngine()
        let turn = fake.turn(mode: .bypass, scenario: "hang")
        let started = SessionFlag()
        let consumer = Task {
            for await event in engine.run(turn) {
                if case .session = event { await started.raise() }
            }
        }
        await waitUntil("the session to start") { await started.isRaised }
        #expect(await started.isRaised)
        // Another Orb's change reaches nobody; this Orb's reaches the running session.
        await engine.modeChanged(for: UUID(), to: .ask)
        await engine.modeChanged(for: turn.bot.id, to: .readOnly)
        let lines = await fake.logLines(waitingFor: "set_permission_mode")
        let requests = lines.compactMap { JSONValue.parse($0) }.filter { $0["request"]?["subtype"] == .string("set_permission_mode") }
        #expect(requests.count == 1)
        #expect(requests.first?["request"]?["mode"] == .string("plan"))
        consumer.cancel()
    }

    /// The pids of the processes started from this fake's folder (its interpreter shows the script path in its
    /// command line). Found by path rather than by a pid the fake writes: a freshly written script can take seconds
    /// to start on a busy Mac, and one killed before it ran would never have written anything.
    private func processes(of fake: FakeClaude) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", fake.directory.path]
        let output = Pipe()
        pgrep.standardOutput = output
        do { try pgrep.run() } catch {
            // Without pgrep "no process found" would be a vacuous answer, so the test must not pass on it.
            Issue.record("pgrep could not run: \(error)")
            return []
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pgrep.waitUntilExit()
        // 0: some matched, 1: none did. Anything else is pgrep failing.
        if pgrep.terminationStatus > 1 { Issue.record("pgrep failed with status \(pgrep.terminationStatus)") }
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    @Test func aCLIThatNeverAnswersInitializeIsGivenUpOnAndKilled() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        var turn = fake.turn(mode: .ask, scenario: "init_silent")
        turn.initializeTimeout = 3
        let started = Date.now
        let events = await run(ClaudeCodeEngine(), turn)

        // Given up on at the timeout, not when the fake's two minutes of silence are over.
        #expect(Date.now.timeIntervalSince(started) < 60)
        guard case .failed(let message) = events.last else { Issue.record("expected a failure, got \(events)"); return }
        #expect(message.contains("não respondeu") && message.contains("encerrado"))
        // The silent process is really gone, not left running.
        await waitUntil("the silent CLI process to be gone") { processes(of: fake).isEmpty }
    }

    @Test func anErrorAnswerToInitializeIsReported() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .ask, scenario: "init_error"))
        guard case .failed(let message) = events.last else { Issue.record("expected a failure, got \(events)"); return }
        #expect(message.contains("boom: config invalida"))
        // The prompt was never sent to a CLI that refused to start.
        let lines = await fake.logLines(waitingFor: "eof")
        #expect(!lines.dropFirst().compactMap { JSONValue.parse($0) }.contains { $0["type"] == .string("user") })
        #expect(!events.contains { if case .message(let m) = $0, m.role == .assistant { true } else { false } })
    }

    @Test func aStreamThatEndsWithoutAResultIsReported() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .ask, scenario: "no_result"))
        guard case .failed(let message) = events.last else { Issue.record("expected a failure, got \(events)"); return }
        #expect(message.contains("parou sem terminar"))
    }

    @Test func stoppingInterruptsAndEndsTheProcess() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let engine = ClaudeCodeEngine()
        let consumer = Task {
            for await event in engine.run(fake.turn(mode: .ask, scenario: "hang")) {
                if case .session = event { return true }
            }
            return false
        }
        #expect(await consumer.value)
        // Leaving the stream cancels the turn: the CLI gets an interrupt, then its input ends.
        let lines = await fake.logLines(waitingFor: "eof")
        #expect(lines.contains { $0.contains(#""subtype":"interrupt""#) })
        #expect(lines.last == "eof")
    }
}

/// Against the real `claude`, logged out, with an empty config folder: checks that the CLI accepts our flags and
/// handshake and that a logged-out turn fails with the sign-in message. Never runs a prompt on an account.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORB_LIVE_TESTS"] != nil))
struct ClaudeCodeLiveTests {
    @Test func loggedOutTurnAsksToSignIn() async throws {
        let installation = try #require(await ClaudeCode.shared.installation())
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }
        var environment = ClaudeCode.environment(ProcessInfo.processInfo.environment, path: installation.path)
        environment["CLAUDE_CONFIG_DIR"] = config.path

        let status = try LineProcess(executable: installation.executable, arguments: ["auth", "status", "--json"],
                                     directory: config, environment: environment)
        status.closeInput()
        var output = ""
        for await line in status.lines { output += line }
        try #require(!ClaudeCodeStatus.parse(output).isLoggedIn, "only runs while this config is logged out")

        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.workingDirectory = config.path
        let turn = ClaudeCodeTurn(bot: bot, executable: installation.executable, model: "default", system: "persona",
                                  prompt: "oi", sessionID: nil, environment: environment)
        var events: [TurnEvent] = []
        for await event in ClaudeCodeEngine().run(turn) { events.append(event) }
        #expect(events.contains { if case .session = $0 { true } else { false } })
        guard case .failed(let message) = events.last else { Issue.record("expected a failure"); return }
        #expect(message.contains("não está conectado"), "got: \(message)")
    }

    /// The `initialize` handshake alone (no prompt) lists the models.
    @Test func modelsComeFromTheCLI() async throws {
        let models = try await ClaudeCode.shared.models()
        #expect(models.first?.id == ClaudeCodeModels.defaultID)
        // The CLI's own list (with display names), not the documented-alias fallback.
        #expect(models != ClaudeCodeModels.fallback, "got: \(models.map(\.id))")
    }
}
