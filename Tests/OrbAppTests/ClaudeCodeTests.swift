import Foundation
import Testing
@testable import Orb

// Sample lines follow what Claude Code 2.1.292 printed in headless probes (logged out, isolated config dir)
// and the Agent SDK's parser (anthropics/claude-agent-sdk-python, `_internal/message_parser.py`).

struct ClaudeCodeParserTests {
    @Test func initStartsTheSession() {
        var parser = ClaudeCodeParser()
        let line = #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"c5f4616a-24aa-4aa0-aa5f-67a2d7d6f0c0","model":"claude-sonnet-5-5","permissionMode":"default","tools":["Bash","Read"],"mcp_servers":[]}"#
        #expect(parser.parse(line) == [.started(sessionID: "c5f4616a-24aa-4aa0-aa5f-67a2d7d6f0c0")])
        #expect(parser.parse(#"{"type":"system","subtype":"status","status":"requesting","session_id":"x"}"#) == [])
    }

    @Test func streamedTextIsNotRepeatedByTheFinalMessage() {
        var parser = ClaudeCodeParser()
        _ = parser.parse(#"{"type":"stream_event","uuid":"u1","session_id":"s","parent_tool_use_id":null,"event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}}"#)
        let delta = parser.parse(#"{"type":"stream_event","uuid":"u2","session_id":"s","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Olá"}}}"#)
        #expect(delta == [.text("Olá")])
        let final = parser.parse(#"{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"Olá"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":null,"session_id":"s"}"#)
        #expect(final == [.toolUse(id: "toolu_1", name: "Bash", input: .object(["command": .string("ls")]))])
    }

    @Test func unstreamedTextAndApiErrors() {
        var parser = ClaudeCodeParser()
        #expect(parser.parse(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Resumo"}]},"parent_tool_use_id":null}"#) == [.text("Resumo")])
        let failure = #"{"type":"assistant","message":{"id":"m3","model":"<synthetic>","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"parent_tool_use_id":null,"error":"authentication_failed","is_api_error_message":true}"#
        #expect(parser.parse(failure) == [.apiError("authentication_failed")])
    }

    @Test func toolResultsAndSubagents() {
        var parser = ClaudeCodeParser()
        let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"a.txt"},{"type":"text","text":"b.txt"}],"is_error":false}]},"parent_tool_use_id":null}"#
        #expect(parser.parse(result) == [.toolResult(id: "toolu_1", output: "a.txt\nb.txt", isError: false)])
        let failed = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"boom","is_error":true}]},"parent_tool_use_id":null}"#
        #expect(parser.parse(failed) == [.toolResult(id: "toolu_2", output: "boom", isError: true)])
        let subagent = #"{"type":"assistant","message":{"id":"m9","content":[{"type":"tool_use","id":"t9","name":"Read","input":{}}]},"parent_tool_use_id":"toolu_agent"}"#
        #expect(parser.parse(subagent) == [])
        #expect(parser.parse("not json") == [])
    }

    @Test func controlMessages() {
        var parser = ClaudeCodeParser()
        let ask = #"{"type":"control_request","request_id":"req_7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"permission_suggestions":null,"blocked_path":null,"tool_use_id":"toolu_3","decision_reason":"Comando que apaga arquivos"}}"#
        #expect(parser.parse(ask) == [.permission(ClaudeCodePermissionRequest(
            requestID: "req_7", toolName: "Bash", input: .object(["command": .string("rm -rf build")]),
            toolUseID: "toolu_3", reason: "Comando que apaga arquivos"))])
        #expect(parser.parse(#"{"type":"control_request","request_id":"req_8","request":{"subtype":"hook_callback","callback_id":"hook_0"}}"#)
                == [.unsupportedRequest(requestID: "req_8", subtype: "hook_callback")])
        #expect(parser.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"req_1_abcd","response":{}}}"#)
                == [.controlResponse(requestID: "req_1_abcd", isError: false)])
    }

    @Test func resultsPickTheMostInformativeText() {
        var parser = ClaudeCodeParser()
        let success = #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"s1","result":"Pronto.","total_cost_usd":0.01}"#
        #expect(parser.parse(success) == [.result(ClaudeCodeResult(isError: false, message: "Pronto.", sessionID: "s1"))])
        let missing = #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"1111","errors":["No conversation found with session ID: 1111"]}"#
        #expect(parser.parse(missing) == [.result(ClaudeCodeResult(isError: true, message: "No conversation found with session ID: 1111", sessionID: "1111"))])
        let apiFailure = #"{"type":"result","subtype":"success","is_error":true,"session_id":"s","result":"API Error: 529 overloaded"}"#
        #expect(parser.parse(apiFailure) == [.result(ClaudeCodeResult(isError: true, message: "API Error: 529 overloaded", sessionID: "s"))])
        #expect(ClaudeCodeParser.result(.object(["is_error": .bool(true), "subtype": .string("error_max_turns")])).message == "error_max_turns")
    }
}

struct ClaudeCodeWireTests {
    @Test func linesWeWrite() throws {
        let user = try #require(JSONValue.parse(ClaudeCodeWire.userMessage("oi")))
        #expect(user == .object(["type": .string("user"), "session_id": .string(""), "parent_tool_use_id": .null,
                                 "message": .object(["role": .string("user"), "content": .string("oi")])]))
        let initialize = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_1", subtype: "initialize")))
        #expect(initialize == .object(["type": .string("control_request"), "request_id": .string("req_1"),
                                       "request": .object(["subtype": .string("initialize"), "hooks": .null])]))
        let interrupt = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_2", subtype: "interrupt")))
        #expect(interrupt["request"] == .object(["subtype": .string("interrupt")]))
        #expect(ClaudeCodeWire.newRequestID().hasPrefix("req_1_"))
    }

    @Test func permissionRoundTrip() throws {
        var parser = ClaudeCodeParser()
        let line = #"{"type":"control_request","request_id":"req_5","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/a.txt","content":"x"},"tool_use_id":"toolu_9"}}"#
        guard case .permission(let request) = try #require(parser.parse(line).first) else {
            Issue.record("expected a permission request")
            return
        }
        let allow = try #require(JSONValue.parse(ClaudeCodeWire.permissionResponse(requestID: request.requestID, answer: .allow, input: request.input)))
        #expect(allow == .object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string("req_5"),
            "response": .object(["behavior": .string("allow"), "updatedInput": request.input]),
        ])]))
        let deny = try #require(JSONValue.parse(ClaudeCodeWire.permissionResponse(requestID: "req_5", answer: .deny("não"), input: request.input)))
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

struct ClaudeCodePolicyTests {
    @Test func permissionModes() {
        #expect(ClaudeCodePolicy.cliMode(.readOnly) == "plan")
        #expect(ClaudeCodePolicy.cliMode(.ask) == "default")
        #expect(ClaudeCodePolicy.cliMode(.auto) == "acceptEdits")
        #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: "Bash", allowed: []) == .allow)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: "Bash", allowed: []) == nil)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: "Bash", allowed: ["Bash"]) == .allow)
        // Read-only wins over an earlier "Sempre permitir".
        #expect(ClaudeCodePolicy.answer(mode: .readOnly, toolName: "Bash", allowed: ["Bash"]) == .deny(ClaudeCodePolicy.readOnlyDenial))
    }

    @Test func toolPresentation() {
        #expect(ClaudeCodeTools.kind("Bash") == .shell)
        #expect(ClaudeCodeTools.kind("Grep") == .search)
        #expect(ClaudeCodeTools.kind("MultiEdit") == .file)
        #expect(ClaudeCodeTools.kind("WebSearch") == .browser)
        #expect(ClaudeCodeTools.kind("mcp__github__get_issue") == .connector)
        #expect(ClaudeCodeTools.kind("TodoWrite") == .computer)
        #expect(ClaudeCodeTools.summary("Bash", .object(["command": .string("ls -la")])) == ("Rodando no Terminal", "ls -la"))
        #expect(ClaudeCodeTools.summary("Edit", .object(["file_path": .string("/a.swift")])) == ("Editando arquivo", "/a.swift"))
        let mcp = ClaudeCodeTools.summary("mcp__my_server__get_issue", .object(["id": .number(3)]))
        #expect(mcp.title == "Usando my_server")
        #expect(mcp.detail == #"get_issue {"id":3}"#)
    }

    @Test func argumentsFollowTheBot() {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        let turn = ClaudeCodeTurn(bot: bot, executable: URL(fileURLWithPath: "/bin/claude"), model: "default",
                                  system: "-persona", prompt: "oi", sessionID: nil)
        let fresh = turn.arguments(newSessionID: "abc", mcpConfig: nil)
        #expect(Array(fresh.prefix(7)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                           "--include-partial-messages", "--verbose"])
        #expect(fresh.contains("--permission-prompt-tool") && fresh.contains("stdio"))
        #expect(fresh.contains("--append-system-prompt=-persona"))
        #expect(fresh.contains("--session-id=abc"))
        #expect(!fresh.contains { $0.hasPrefix("--model") })
        // Connectors off: only the MCP servers we pass (the Orb's memory) load, none of the user's own.
        #expect(fresh.last == "--strict-mcp-config")
        #expect(!fresh.contains { $0.hasPrefix("--disallowedTools") })

        bot.permissionMode = .readOnly
        bot.capabilities = [.connectors]
        let resumed = ClaudeCodeTurn(bot: bot, executable: turn.executable, model: "opus", system: "s", prompt: "oi",
                                     sessionID: "s-1").arguments(newSessionID: "abc", mcpConfig: URL(fileURLWithPath: "/tmp/m.json"))
        #expect(resumed.contains("--resume=s-1") && !resumed.contains("--session-id=abc"))
        #expect(resumed.contains("--model=opus"))
        #expect(resumed[resumed.firstIndex(of: "--permission-mode").map { $0 + 1 } ?? 0] == "plan")
        #expect(resumed.contains("--disallowedTools=Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch"))
        #expect(resumed.last == "--mcp-config=/tmp/m.json")
    }

    @Test func connectorsBecomeAnMCPConfig() throws {
        let local = MCPServerConfig(name: "Meu Server", command: "npx", arguments: ["-y", "srv"], environment: ["K": "v"])
        let twin = MCPServerConfig(name: "meu server", command: "uvx")
        let remote = MCPServerConfig(name: "Docs", url: "https://example.com/mcp", headers: ["Authorization": "Bearer x"])
        let off = MCPServerConfig(name: "Off", command: "x", isEnabled: false)
        let config = try #require(ClaudeCodeTurn.mcpConfig([local, twin, remote, off]))
        let servers = try #require(config["mcpServers"])
        #expect(servers["meu-server"] == .object(["type": .string("stdio"), "command": .string("npx"),
                                                  "args": .array([.string("-y"), .string("srv")]), "env": .object(["K": .string("v")])]))
        #expect(servers["meu-server-2"]?["command"] == .string("uvx"))
        #expect(servers["docs"] == .object(["type": .string("http"), "url": .string("https://example.com/mcp"),
                                            "headers": .object(["Authorization": .string("Bearer x")])]))
        #expect(servers["off"] == nil)
        #expect(ClaudeCodeTurn.mcpConfig([off]) == nil)
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
                                                  "CLAUDE_AGENT_SDK_VERSION": "1", "ANTHROPIC_MODEL": "m"], path: "/p")
        #expect(environment == ["HOME": "/h", "ANTHROPIC_MODEL": "m", "PATH": "/p"])
    }
}

struct ClaudeCodeTranscriptTests {
    @Test func turnBecomesTranscriptEvents() {
        var transcript = ClaudeCodeTranscript(isResuming: false)
        var events: [TurnEvent] = []
        for message: ClaudeCodeMessage in [
            .started(sessionID: "s1"), .text("Vou "), .text("olhar."),
            .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")])),
            .toolResult(id: "t1", output: "a.txt", isError: false), .text("Pronto."),
            .result(ClaudeCodeResult(isError: false, message: "Pronto.", sessionID: "s1")),
        ] { events += transcript.apply(message) }
        #expect(transcript.isFinished)
        guard case .session("s1") = events.first else { Issue.record("no session event"); return }
        let texts = events.compactMap { if case .text(let t) = $0 { t } else { nil } }
        #expect(texts == ["Vou ", "olhar.", "Pronto."])
        let started = events.compactMap { if case .toolStarted(let call) = $0 { call } else { nil } }
        #expect(started.map(\.kind) == [.shell] && started.first?.detail == "ls")
        let finished = events.compactMap { if case .toolFinished(let id, let state, let output) = $0 { (id, state, output) } else { nil } }
        #expect(finished.count == 1 && finished[0].0 == started[0].id && finished[0].1 == .done && finished[0].2 == "a.txt")
        guard case .message(let reply) = events.last else { Issue.record("no reply message"); return }
        // The reply plus a short note of what was done, so other models taking over know.
        #expect(reply.content.hasPrefix("Vou olhar.\n\nPronto.\n\n(Actions taken in this turn: "))
        #expect(reply.content.contains("ls"))
    }

    @Test func replyWithoutToolsHasNoActionNote() {
        var transcript = ClaudeCodeTranscript(isResuming: false)
        var events: [TurnEvent] = []
        for message: ClaudeCodeMessage in [.started(sessionID: "s"), .text("Oi!"),
                                           .result(ClaudeCodeResult(isError: false, message: "Oi!", sessionID: "s"))] {
            events += transcript.apply(message)
        }
        guard case .message(let reply) = events.last else { Issue.record("no reply"); return }
        #expect(reply.content == "Oi!")
    }

    @Test func catchUpSummarizesWhatOtherModelsDid() {
        #expect(ClaudeCodePrompt.catchUp([]).isEmpty)
        let call = ToolCallRequest(id: "c1", name: "run_command", arguments: #"{"command":"npm test"}"#)
        let text = ClaudeCodePrompt.catchUp([
            .user("Rode os testes"), ChatMessage(role: .assistant, content: "Vou rodar.", toolCalls: [call]),
            .tool("c1", "12 passed"), ChatMessage(role: .assistant, content: "Todos passaram."),
        ])
        #expect(text.hasPrefix("Earlier in this Orb conversation"))
        #expect(text.contains("User: Rode os testes"))
        #expect(text.contains("run_command"))
        #expect(text.contains("Tool result: 12 passed"))
        #expect(text.hasSuffix("The user's new message:"))
    }

    @Test func catchUpKeepsTheMostRecentPartWhenLong() {
        let long = (0..<200).map { ChatMessage.user("mensagem \($0) " + String(repeating: "x", count: 100)) }
        let text = ClaudeCodePrompt.catchUp(long, limit: 2_000)
        #expect(text.contains("mensagem 199"))
        #expect(!text.contains("mensagem 0 "))
    }

    @Test func failuresAndDenials() {
        var resumed = ClaudeCodeTranscript(isResuming: true)
        let gone = resumed.apply(.result(ClaudeCodeResult(isError: true, message: "No conversation found", sessionID: "x")))
        guard case .session("") = gone.first, case .failed = gone.last else { Issue.record("expected reset + failure"); return }

        var loggedOut = ClaudeCodeTranscript(isResuming: false)
        _ = loggedOut.apply(.started(sessionID: "s"))
        _ = loggedOut.apply(.apiError("authentication_failed"))
        guard case .failed(let message) = loggedOut.apply(.result(ClaudeCodeResult(isError: true, message: "Failed", sessionID: "s"))).last
        else { Issue.record("expected failure"); return }
        #expect(message.contains("não está conectado"))

        var denied = ClaudeCodeTranscript(isResuming: false)
        _ = denied.apply(.toolUse(id: "t1", name: "Write", input: .object([:])))
        denied.noteDenied("t1", mode: .ask)
        let row = denied.apply(.toolResult(id: "t1", output: "The user denied…", isError: true))
        guard case .toolFinished(_, .failed, "Você negou esta ação.") = row.first else { Issue.record("expected denial row"); return }

        var crashed = ClaudeCodeTranscript(isResuming: false)
        _ = crashed.apply(.toolUse(id: "t2", name: "Bash", input: .object([:])))
        let ended = crashed.endedEarly(details: "error: unknown option")
        guard case .toolFinished(_, .failed, _) = ended.first, case .failed(let why) = ended.last else { Issue.record("expected close + failure"); return }
        #expect(why.contains("unknown option"))
    }
}
