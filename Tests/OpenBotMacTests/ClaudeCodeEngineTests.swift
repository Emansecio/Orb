import Foundation
import Testing
@testable import OpenBotMac

/// A stand-in `claude` that speaks the stream-json + control protocol: answers `initialize`, then for the user
/// message streams text, asks permission for a Bash call and reports the result. Logs argv and stdin lines.
private let fakeClaude = #"""
#!/usr/bin/python3
import json, os, sys

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
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"models": []}}})
    elif kind == "user":
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test"})
        if scenario == "hang":
            continue
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

    /// Logged lines, waiting up to `timeout` seconds for one containing `marker`.
    func logLines(waitingFor marker: String, timeout: Double = 5) async -> [String] {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.contains(marker) || Date.now > deadline { return text.split(separator: "\n").map(String.init) }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct ClaudeCodeEngineTests {
    /// Collects a turn's events, answering every approval with `decision`.
    private func run(_ engine: ClaudeCodeEngine, _ turn: ClaudeCodeTurn, decision: ApprovalDecision = .once) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(turn) {
            events.append(event)
            if case .approval(let approval) = event { await engine.resolve(approvalID: approval.id, decision: decision) }
        }
        return events
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
        #expect(reply.content == "Vou listar.\n\nPronto.")
        #expect(!events.contains { if case .failed = $0 { true } else { false } })

        let lines = await fake.logLines(waitingFor: "eof")
        let logged = lines.first.flatMap { JSONValue.parse($0) }
        let args = logged?["args"]?.array?.compactMap(\.string) ?? []
        #expect(args.contains("--resume=sess-1") && args.contains("--model=sonnet") && args.contains("--append-system-prompt=persona"))
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

    @Test func automaticModeNeverAsks() async throws {
        let fake = try FakeClaude()
        defer { fake.remove() }
        let events = await run(ClaudeCodeEngine(), fake.turn(mode: .auto))
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
        let lines = await fake.logLines(waitingFor: "eof")
        let args = lines.first ?? ""
        #expect(args.contains("acceptEdits") && args.contains("--session-id="))
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
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENBOT_LIVE_TESTS"] != nil))
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
