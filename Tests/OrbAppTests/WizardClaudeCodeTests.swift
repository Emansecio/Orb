import Foundation
import Testing
@testable import Orb

/// A stand-in `claude`: answers `initialize`, then asks permission for the tool named in the environment and reports what the
/// app answered. Logs its argv and the answers.
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
tool_name = os.environ["FAKE_CLAUDE_TOOL"]
for raw in sys.stdin:
    msg = json.loads(raw)
    kind = msg.get("type")
    if kind == "control_request" and msg["request"]["subtype"] == "initialize":
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"models": []}}})
    elif kind == "user":
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test"})
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
              "message": {"id": "msg_1", "model": "claude-test", "content": [{"type": "tool_use", "id": "toolu_1", "name": tool_name, "input": {"name": "Maia"}}]}})
        emit({"type": "control_request", "request_id": "perm_1", "request": {"subtype": "can_use_tool", "tool_name": tool_name,
              "input": {"name": "Maia"}, "tool_use_id": "toolu_1", "permission_suggestions": None, "blocked_path": None}})
        answer = json.loads(sys.stdin.readline())["response"]["response"]
        note("answer:" + answer["behavior"])
        emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "session_id": session, "result": "ok"})
        break
note("eof")
"""#

private struct Fake {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-wizard-\(UUID().uuidString)")
    var executable: URL { directory.appendingPathComponent("claude") }
    var log: URL { directory.appendingPathComponent("log.txt") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: Data(fakeClaude.utf8), attributes: [.posixPermissions: 0o755])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// The turn of the creation assistant, for a fake that calls `tool`.
    func turn(calling tool: String, mode: PermissionMode = .readOnly) -> ClaudeCodeTurn {
        var bot = Bot(name: "Assistente de criação", role: "", orb: OrbConfig(), permissionMode: mode)
        bot.capabilities = []
        bot.workingDirectory = directory.path
        var turn = ClaudeCodeTurn(bot: bot, executable: executable, model: "sonnet", system: WizardPrompt.system(), prompt: "oi",
                                  environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LOG": log.path, "FAKE_CLAUDE_TOOL": tool])
        turn.onlyTools = [ClaudeCodeTools.memoryPrefix + OrbDraftTool.name]
        return turn
    }

    func lines(waitingFor marker: String) async -> [String] {
        var text = ""
        await waitUntil("the fake CLI to log \"\(marker)\"") {
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.contains(marker)
        }
        return text.split(separator: "\n").map(String.init)
    }
}

/// The creation assistant through Claude Code: only `orb_draft` of the Orb's tools server, no built-in tool, and nothing else gets through.
@Suite struct WizardClaudeCodeTests {
    private func run(_ turn: ClaudeCodeTurn) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        let engine = ClaudeCodeEngine()
        for await event in engine.run(turn) {
            events.append(event)
            if case .approval(let approval) = event { await engine.gate.resolve(approvalID: approval.id, decision: .once) }
        }
        return events
    }

    @Test func theCLIStartsWithNoBuiltInTool() throws {
        let fake = try Fake()
        defer { fake.remove() }
        let arguments = fake.turn(calling: "x").arguments(newSessionID: "s", mcpConfig: nil)
        #expect(arguments.contains("--tools="))
        let disallowed = arguments.first { $0.hasPrefix("--disallowedTools=") } ?? ""
        for name in ["Read", "Bash", "Write", "Edit", "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite", "AskUserQuestion"] {
            #expect(disallowed.contains(name), "\(name) is out")
        }
        #expect(arguments.contains("--strict-mcp-config"))
        // A normal Orb's turn is as it was.
        var normal = fake.turn(calling: "x")
        normal.onlyTools = nil
        #expect(!normal.arguments(newSessionID: "s", mcpConfig: nil).contains("--tools="))
    }

    @Test func theToolsServerOfTheAssistantServesOrbDraftAlone() throws {
        let bridge = URL(fileURLWithPath: "/tmp/ponte-teste")
        let id = UUID()
        let config = OrbToolsMCPServer.config(directory: URL(fileURLWithPath: "/tmp/memoria-teste"), orb: id, wizardBridge: bridge)
        #expect(config.arguments.contains(OrbToolsMCPServer.wizardFlag))
        #expect(config.arguments.starts(with: [OrbToolsMCPServer.flag, "/tmp/memoria-teste"]))
        let options = try #require(OrbToolsMCPServer.Options(arguments: config.arguments, environment: [:]))
        #expect(options.wizard && options.bridge == bridge && options.orb == id)
        #expect(OrbToolsMCPServer.tools(mac: true, files: true, browser: .browser, wizard: true).map(\.spec.name) == ["orb_draft"])
        #expect(OrbToolsMCPServer.listedTools(mac: true, wizard: true).map(\.spec.name) == ["orb_draft"])
        #expect(OrbToolsMCPServer.tools(mac: false).contains { $0.spec.name == "orb_draft" } == false, "a normal Orb never gets it")
        // Without `--wizard` the server is the old one.
        let plain = OrbToolsMCPServer.config(directory: URL(fileURLWithPath: "/tmp/m"), orb: id)
        #expect(!plain.arguments.contains(OrbToolsMCPServer.wizardFlag))
        #expect(OrbToolsMCPServer.tool(claudeCodeName: ClaudeCodeTools.memoryPrefix + "orb_draft") != nil)
    }

    @Test func theDraftToolIsAllowedThroughTheBridgeName() async throws {
        let fake = try Fake()
        defer { fake.remove() }
        let events = await run(fake.turn(calling: ClaudeCodeTools.memoryPrefix + "orb_draft"))
        let lines = await fake.lines(waitingFor: "eof")
        #expect(lines.contains("answer:allow"))
        #expect(!events.contains { if case .approval = $0 { true } else { false } }, "no card for it, even in Só leitura")
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test(arguments: ["Read", "Bash", "WebFetch", "mcp__orb_memoria__remember", "mcp__orb_memoria__open", "mcp__other__tool"])
    func anyOtherToolIsDenied(_ tool: String) async throws {
        let fake = try Fake()
        defer { fake.remove() }
        // Even in "Sem pedir permissão", which allows everything else.
        let events = await run(fake.turn(calling: tool, mode: .bypass))
        let lines = await fake.lines(waitingFor: "eof")
        #expect(lines.contains("answer:deny"), "\(tool) must be refused")
        #expect(!events.contains { if case .approval = $0 { true } else { false } })
    }
}
