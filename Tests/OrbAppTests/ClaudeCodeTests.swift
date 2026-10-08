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
            toolUseID: "toolu_3"))])
        #expect(parser.parse(#"{"type":"control_request","request_id":"req_8","request":{"subtype":"hook_callback","callback_id":"hook_0"}}"#)
                == [.unsupportedRequest(requestID: "req_8", subtype: "hook_callback")])
        #expect(parser.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"req_1_abcd","response":{}}}"#)
                == [.controlResponse(requestID: "req_1_abcd", error: nil)])
    }

    @Test func errorAnswersCarryTheirReason() {
        var parser = ClaudeCodeParser()
        let refused = #"{"type":"control_response","response":{"subtype":"error","request_id":"req_1_abcd","error":"bad config"}}"#
        #expect(parser.parse(refused) == [.controlResponse(requestID: "req_1_abcd", error: "bad config")])
        let bare = #"{"type":"control_response","response":{"subtype":"error","request_id":"req_2"}}"#
        #expect(parser.parse(bare) == [.controlResponse(requestID: "req_2", error: "erro desconhecido")])
    }

    @Test func resultsReportUsageAndCost() {
        var parser = ClaudeCodeParser()
        let line = #"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","result":"Pronto.","total_cost_usd":0.0421,"usage":{"input_tokens":12,"output_tokens":340,"cache_read_input_tokens":9000,"cache_creation_input_tokens":150,"service_tier":"standard"}}"#
        #expect(parser.parse(line) == [.result(ClaudeCodeResult(
            isError: false, message: "Pronto.", sessionID: "s1",
            usage: TokenUsage(input: 12, output: 340, cacheRead: 9000, cacheWrite: 150), costUSD: 0.0421))])
        // Missing, empty or malformed usage never fails the turn.
        #expect(ClaudeCodeParser.result(.object(["usage": .object([:])])).usage == nil)
        #expect(ClaudeCodeParser.result(.object(["usage": .string("x")])).usage == nil)
        let partial = ClaudeCodeParser.result(.object(["usage": .object(["output_tokens": .number(5)])]))
        #expect(partial.usage == TokenUsage(output: 5))
        #expect(partial.costUSD == nil)
    }

    @Test func resultsPickTheMostInformativeText() {
        var parser = ClaudeCodeParser()
        let success = #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"s1","result":"Pronto.","total_cost_usd":0.01}"#
        #expect(parser.parse(success) == [.result(ClaudeCodeResult(isError: false, message: "Pronto.", sessionID: "s1", costUSD: 0.01))])
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
        // "Automático" must not let the CLI approve edits itself (`acceptEdits`): the Orb's policy sees every request.
        #expect(ClaudeCodePolicy.cliMode(.auto) == "default")
        #expect(ClaudeCodePolicy.cliMode(.bypass) == "bypassPermissions")
        #expect(PermissionMode.allCases.allSatisfy { ClaudeCodePolicy.cliMode($0) != "acceptEdits" })
        #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: "Bash") == .allow)
        // Edits in "Automático" go through the Orb's danger checks, like the native write_file / edit_file.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".ssh/authorized_keys", "Library/LaunchAgents/x.plist"] {
            for tool in ["Write", "Edit", "MultiEdit"] {
                let input = JSONValue.object(["file_path": .string(home.appending(path: name).path)])
                #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: tool, input: input) == nil, "\(tool) \(name)")
                #expect(ClaudeCodePolicy.answer(mode: .bypass, toolName: tool, input: input) == .allow)
            }
        }
        let notes = JSONValue.object(["file_path": .string(home.appending(path: "Projetos/notas.txt").path)])
        #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: "Edit", input: notes) == .allow)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: "Bash") == nil)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: "Bash", rules: PermissionPolicy.legacyRules(fromToolNames: ["Bash"])) == .allow)
        // Read-only wins over an earlier "Sempre permitir".
        #expect(ClaudeCodePolicy.answer(mode: .readOnly, toolName: "Bash", rules: PermissionPolicy.legacyRules(fromToolNames: ["Bash"])) == .deny(ClaudeCodePolicy.readOnlyDenial))
    }

    @Test func theMacToolsAskLikeTheNativeOnes() {
        let prefix = ClaudeCodeTools.memoryPrefix
        let quitForced = JSONValue.object(["app": .string("Pages"), "force": .bool(true)])
        let quit = JSONValue.object(["app": .string("Pages")])
        let rm = JSONValue.object(["script": .string(#"do shell script "rm -rf ~/Documents/x""#)])
        let harmless = JSONValue.object(["script": .string(#"tell application "Finder" to activate"#)])
        // A forced quit and a destructive `do shell script` ask in "Automático" and after "Sempre permitir".
        for (name, input) in [("app_quit", quitForced), ("applescript", rm)] {
            let tool = prefix + name
            #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: tool, input: input) == nil, "\(name)")
            #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: tool, input: input, rules: PermissionPolicy.legacyRules(fromToolNames: [tool])) == nil, "\(name)")
            #expect(ClaudeCodePolicy.answer(mode: .bypass, toolName: tool, input: input) == .allow, "\(name)")
            #expect(ClaudeCodePolicy.answer(mode: .readOnly, toolName: tool, input: input, rules: PermissionPolicy.legacyRules(fromToolNames: [tool])) == .deny(ClaudeCodePolicy.readOnlyDenial), "\(name)")
            #expect(PermissionPolicy.call(claudeCodeTool: tool, input: input, workspace: nil).danger != nil, "\(name)")
        }
        // The same tools without the danger behave as sensitive ones.
        let applescript = prefix + "applescript", appQuit = prefix + "app_quit"
        #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: applescript, input: harmless) == .allow)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: applescript, input: harmless) == nil)
        #expect(ClaudeCodePolicy.answer(mode: .ask, toolName: applescript, input: harmless, rules: PermissionPolicy.legacyRules(fromToolNames: [applescript])) == .allow)
        #expect(ClaudeCodePolicy.answer(mode: .auto, toolName: appQuit, input: quit) == .allow)
        #expect(PermissionPolicy.call(claudeCodeTool: applescript, input: harmless, workspace: nil).danger == nil)
        // Read-only tools run in every mode, "Só leitura" included.
        for name in ["apps_list", "processes", "screenshot", "clipboard_read", "shortcuts_list"] {
            for mode in PermissionMode.allCases {
                #expect(ClaudeCodePolicy.answer(mode: mode, toolName: prefix + name) == .allow, "\(name) \(mode)")
            }
        }
        // Claude Code's own tools keep checking `command` only.
        #expect(PermissionPolicy.call(claudeCodeTool: "Bash", input: .object(["command": .string("rm -rf ~")]), workspace: nil).danger != nil)
        #expect(PermissionPolicy.call(claudeCodeTool: "mcp__outro__run", input: rm, workspace: nil).danger == nil)
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

    @Test func claudeCodesOwnToolsGetPortugueseTitles() {
        let todos = JSONValue.object(["todos": .array([
            .object(["content": .string("Escrever testes"), "status": .string("completed"), "activeForm": .string("Escrevendo testes")]),
            .object(["content": .string("Rodar a suíte"), "status": .string("in_progress"), "activeForm": .string("Rodando a suíte")]),
        ])])
        #expect(ClaudeCodeTools.summary("TodoWrite", todos) == ("Atualizando a lista de tarefas", "Rodando a suíte"))
        #expect(ClaudeCodeTools.summary("TodoWrite", .object([:])).title == "Atualizando a lista de tarefas")
        for name in ["Task", "Agent"] {
            #expect(ClaudeCodeTools.summary(name, .object(["description": .string("Procurar usos")])) == ("Delegando a um subagente", "Procurar usos"))
        }
        #expect(ClaudeCodeTools.summary("ExitPlanMode", .object(["plan": .string("1. Fazer")])) == ("Apresentando o plano", "1. Fazer"))
        #expect(ClaudeCodeTools.summary("Skill", .object(["skill": .string("pdf")])) == ("Usando uma habilidade", "pdf"))
        #expect(ClaudeCodeTools.summary("NotebookRead", .object(["notebook_path": .string("/a.ipynb")])) == ("Lendo caderno", "/a.ipynb"))
        #expect(ClaudeCodeTools.kind("NotebookRead") == .file)
        // A tool this version does not know is named in Portuguese context, not shown bare.
        #expect(ClaudeCodeTools.summary("FuturoTool", .object(["a": .number(1)])) == ("Usando FuturoTool", #"{"a":1}"#))
    }

    @Test func macToolsOfTheOrbServerGetPortugueseTitles() {
        let prefix = ClaudeCodeTools.memoryPrefix
        // Same titles as the native tools; the kind comes from the tool itself.
        for tool in ToolBox.macTools {
            let name = prefix + tool.spec.name
            #expect(ClaudeCodeTools.kind(name) == tool.kind, "\(tool.spec.name)")
            let expected = tool.summary(.object([:]))
            #expect(ClaudeCodeTools.summary(name, .object([:])) == expected, "\(tool.spec.name)")
            #expect(!expected.title.isEmpty, "\(tool.spec.name)")
        }
        #expect(ClaudeCodeTools.summary(prefix + "processes", .object([:])) == ("Vendo os processos", ""))
        #expect(ClaudeCodeTools.summary(prefix + "trash", .object(["paths": .array([.string("/tmp/a")])])).title == "Movendo para a Lixeira")
        // A tool this version doesn't know under the Orb's server keeps the memory icon and a generic title.
        #expect(ClaudeCodeTools.kind(prefix + "futuro") == .memory)
        #expect(ClaudeCodeTools.summary(prefix + "futuro", .object([:])).title == "Usando orb_memoria")
    }

    @Test func theOrbReadsTheHomeFolderWithoutAskingUnlessItWorksThere() {
        let home = URL(fileURLWithPath: "/Users/ana")
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.workingDirectory = "/Users/ana/Projetos/site"
        var turn = ClaudeCodeTurn(bot: bot, executable: URL(fileURLWithPath: "/bin/claude"), model: "default",
                                  system: "s", prompt: "oi", sessionID: nil)
        turn.homeDirectory = home
        #expect(turn.arguments(newSessionID: "a", mcpConfig: nil).contains("--add-dir=/Users/ana"))
        // Already starting in the home folder (an empty folder means home): nothing to add.
        turn.bot.workingDirectory = "/Users/ana/"
        #expect(!turn.arguments(newSessionID: "a", mcpConfig: nil).contains { $0.hasPrefix("--add-dir") })
        turn.bot.workingDirectory = ""
        turn.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        #expect(!turn.arguments(newSessionID: "a", mcpConfig: nil).contains { $0.hasPrefix("--add-dir") })
    }

    @Test func aSessionIsResumedOnlyInTheFolderItStartedIn() throws {
        var conversation = Conversation()
        #expect(conversation.claudeSession(forFolder: "/a") == nil)
        conversation.claudeSessionID = "s-1"
        // Saved before the folder was tracked: still resumed.
        #expect(conversation.claudeSession(forFolder: "/a") == "s-1")
        conversation.claudeSessionFolder = "/a"
        #expect(conversation.claudeSession(forFolder: "/a") == "s-1")
        #expect(conversation.claudeSession(forFolder: "/b") == nil)

        // Persisted with the conversation, and an older file without the field still loads.
        let saved = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(saved.claudeSessionID == "s-1" && saved.claudeSessionFolder == "/a")
        let old = try JSONDecoder().decode(Conversation.self, from: Data(#"{"items":[],"messages":[],"claudeSessionID":"s-0"}"#.utf8))
        #expect(old.claudeSessionID == "s-0" && old.claudeSessionFolder == nil)
    }

    @Test func changingTheFolderStartsANewSessionThatGetsTheFullCatchUp() {
        var conversation = Conversation()
        conversation.messages = [ChatMessage(role: .user, content: "oi"), ChatMessage(role: .assistant, content: "olá")]
        // Turn in /a: its session is reported, and the turn ends having seen everything.
        conversation.claudeSessionReported("s-a", folder: "/a")
        conversation.claudeTurnFinished(folder: "/a")
        #expect(conversation.claudeSessionID == "s-a" && conversation.claudeSessionFolder == "/a" && conversation.claudeSeenCount == 2)

        // The folder changes: no session to resume, so the next turn is sent the whole conversation.
        conversation.messages.append(ChatMessage(role: .user, content: "e agora?"))
        let sessionID = conversation.claudeSession(forFolder: "/b")
        #expect(sessionID == nil)
        // The new session never starts (the turn failed): the leftover /a session has not seen this turn, so the
        // count stays where it was and nothing is marked as seen.
        conversation.claudeTurnFinished(folder: "/b")
        #expect(conversation.claudeSeenCount == 2)
        let seen = sessionID == nil ? 0 : min(conversation.claudeSeenCount ?? 0, conversation.messages.count)
        #expect(seen == 0)

        // A retry in /b whose session does start is stamped with /b and counts everything as seen.
        conversation.claudeSessionReported("s-b", folder: "/b")
        conversation.claudeTurnFinished(folder: "/b")
        #expect(conversation.claudeSession(forFolder: "/b") == "s-b" && conversation.claudeSession(forFolder: "/a") == nil)
        #expect(conversation.claudeSeenCount == 3)

        // A session the CLI says is gone clears its folder and count.
        conversation.claudeSessionReported("", folder: "/b")
        #expect(conversation.claudeSessionID == nil && conversation.claudeSessionFolder == nil && conversation.claudeSeenCount == nil)
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
        // Everything is on, so only the reads of private keys are refused.
        #expect(fresh.contains("--disallowedTools=" + ClaudeCodeTools.secretReads.joined(separator: ",")))

        bot.permissionMode = .readOnly
        bot.capabilities = [.connectors]
        let resumed = ClaudeCodeTurn(bot: bot, executable: turn.executable, model: "opus", system: "s", prompt: "oi",
                                     sessionID: "s-1").arguments(newSessionID: "abc", mcpConfig: URL(fileURLWithPath: "/tmp/m.json"))
        #expect(resumed.contains("--resume=s-1") && !resumed.contains("--session-id=abc"))
        #expect(resumed.contains("--model=opus"))
        #expect(resumed[resumed.firstIndex(of: "--permission-mode").map { $0 + 1 } ?? 0] == "plan")
        let removed = ClaudeCodeTools.terminal + ClaudeCodeTools.web + ClaudeCodeTools.secretReads
        #expect(resumed.contains("--disallowedTools=" + removed.joined(separator: ",")))
        #expect(resumed.last == "--mcp-config=/tmp/m.json")
    }

    @Test func withoutTheTerminalSwitchClaudeCodeKeepsNoShellNoFileSearchAndNoJobs() {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.capabilities = [.browser]
        let turn = ClaudeCodeTurn(bot: bot, executable: URL(fileURLWithPath: "/bin/claude"), model: nil, system: "s", prompt: "oi", sessionID: nil)
        let removed = (turn.arguments(newSessionID: "a", mcpConfig: nil).first { $0.hasPrefix("--disallowedTools=") } ?? "")
            .dropFirst("--disallowedTools=".count).split(separator: ",").map(String.init)
        for tool in ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS", "NotebookRead", "BashOutput", "TaskOutput",
                     "KillShell", "KillBash", "TaskStop"] {
            #expect(removed.contains(tool), Comment(rawValue: tool))
        }
        // Read stays: it is how Claude Code opens the pictures the user attached.
        #expect(!removed.contains("Read"))
        #expect(!removed.contains("WebFetch"))
    }

    @Test func privateKeysAreRefusedToClaudeCodeUnlessTheUserSaidNoQuestionsAsked() {
        func disallowed(_ mode: PermissionMode) -> [String] {
            var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
            bot.permissionMode = mode
            let turn = ClaudeCodeTurn(bot: bot, executable: URL(fileURLWithPath: "/bin/claude"), model: nil, system: "s", prompt: "oi", sessionID: nil)
            return (turn.arguments(newSessionID: "a", mcpConfig: nil).first { $0.hasPrefix("--disallowedTools=") } ?? "")
                .dropFirst("--disallowedTools=".count).split(separator: ",").map(String.init)
        }
        for mode in [PermissionMode.ask, .auto, .readOnly] {
            #expect(disallowed(mode).contains("Read(~/.ssh/**)"), Comment(rawValue: "\(mode)"))
            #expect(disallowed(mode).contains("Read(~/.aws/**)"))
        }
        #expect(disallowed(.bypass).isEmpty)
    }

    @Test func theProcessKeepsBashInTheProjectFolderAndTheTurnKeepsItsEnvironment() {
        var turn = ClaudeCodeTurn(bot: Bot(name: "Atlas", role: "", orb: OrbConfig()), executable: URL(fileURLWithPath: "/bin/claude"),
                                  model: nil, system: "s", prompt: "oi", sessionID: nil, environment: ["PATH": "/p"])
        #expect(turn.processEnvironment == ["PATH": "/p", "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR": "1"])
        turn.environment["CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR"] = "0" // the policy depends on it: ours wins
        #expect(turn.processEnvironment["CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR"] == "1")
    }

    private func mcpTool(_ config: MCPServerConfig, _ name: String, _ annotations: MCPToolAnnotations) -> MCPTool {
        var tool = MCPTool(serverName: config.name, remote: ToolSpec(name: name, description: "", parameters: .schema([:])),
                           connection: MCPConnection(config: config), annotations: annotations)
        tool.serverID = config.id
        return tool
    }

    @Test func destructiveConnectorToolsAreKeyedLikeTheCLIsNames() {
        let github = MCPServerConfig(name: "GitHub", command: "x"), meu = MCPServerConfig(name: "Meu Server", command: "x")
        let found = ClaudeCodeTurn.destructiveConnectors([
            mcpTool(github, "delete_repository", MCPToolAnnotations(destructive: true)),
            mcpTool(meu, "apagar-tudo", MCPToolAnnotations(destructive: true)),
            mcpTool(github, "list_issues", MCPToolAnnotations(readOnly: true)),
        ], cliNames: ClaudeCodeTurn.mcpNames([github, meu]))
        #expect(Set(found.keys) == ["github__delete_repository", "meu_server__apagar_tudo"])
        // The key is what the policy derives from the CLI's tool name.
        #expect(PermissionPolicy.connectorKey("mcp__meu-server__apagar-tudo") == "meu_server__apagar_tudo")
        #expect(found["github__delete_repository"] == "o conector marcou esta ferramenta como destrutiva")
    }

    /// The map is keyed by the name the CLI is given in `--mcp-config` (ASCII, with `-2` for a repeated name), not by the
    /// connector's own, or the tool of an accented or repeated connector would run without a card.
    @Test func destructiveToolsAreKeyedByTheNameInTheConfigForAccentedAndRepeatedConnectors() throws {
        let agenda = MCPServerConfig(name: "Calendário", command: "x")
        let first = MCPServerConfig(name: "GitHub", command: "x"), second = MCPServerConfig(name: "github", command: "y")
        let servers = [agenda, first, second]
        let names = ClaudeCodeTurn.mcpNames(servers)
        #expect(names[agenda.id] == "calend-rio" && names[first.id] == "github" && names[second.id] == "github-2")
        let config = try #require(ClaudeCodeTurn.mcpConfig(servers))
        guard case .object(let entries)? = config["mcpServers"] else { Issue.record("no servers"); return }
        #expect(Set(entries.keys) == ["calend-rio", "github", "github-2"])

        let destructive = MCPToolAnnotations(destructive: true)
        let found = ClaudeCodeTurn.destructiveConnectors([
            mcpTool(agenda, "apagar_evento", destructive), mcpTool(first, "x", destructive), mcpTool(second, "x", destructive),
        ], cliNames: names)
        // What the policy derives from the tool names the CLI really uses.
        for cli in ["mcp__calend-rio__apagar_evento", "mcp__github__x", "mcp__github-2__x"] {
            #expect(found[PermissionPolicy.connectorKey(cli)] != nil, Comment(rawValue: cli))
        }
        #expect(found.count == 3)
    }

    @Test func connectorsWithNoToolsInTheAppAreUnverified() {
        let listed = MCPServerConfig(name: "GitHub", command: "x"), silent = MCPServerConfig(name: "Calendário", command: "x")
        let names = ClaudeCodeTurn.mcpNames([listed, silent])
        let tools: [any AgentTool] = [mcpTool(listed, "list_issues", MCPToolAnnotations(readOnly: true))]
        let unverified = ClaudeCodeTurn.unverifiedConnectors([listed.id, silent.id], tools: tools, cliNames: names)
        #expect(unverified == [PermissionPolicy.connectorKey("calend-rio") + "__"])
        #expect(PermissionPolicy.connectorKey("mcp__calend-rio__apagar_evento").hasPrefix(try! #require(unverified.first)))
    }

    @Test func aDeadOwnersConnectorConfigGoesAndALiveOwnersStays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owned-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let me = ProcessInfo.processInfo.processIdentifier
        let alive = folder.appendingPathComponent("orb-mcp-p\(me)-A.json"), dead = folder.appendingPathComponent("orb-mcp-p2000000000-B.json")
        let nameless = folder.appendingPathComponent("orb-mcp-C.json")
        for url in [alive, dead, nameless] { try Data("{}".utf8).write(to: url) }
        // Old enough to be stale by age: only the one with no owner in its name goes by it.
        let long = Date(timeIntervalSinceNow: -3600)
        for url in [alive, dead, nameless] { try FileManager.default.setAttributes([.modificationDate: long], ofItemAtPath: url.path) }
        #expect(ClaudeCodeEngine.removeStaleMCPConfigs(in: folder) == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == [alive.lastPathComponent])
    }

    @Test func staleConnectorConfigsAreRemovedOnlyWhenOld() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stale-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Names without a process (older versions) go by age.
        let old = folder.appendingPathComponent("orb-mcp-A.json"), fresh = folder.appendingPathComponent("orb-mcp-B.json")
        let other = folder.appendingPathComponent("outro.json"), notes = folder.appendingPathComponent("orb-mcp-notes.txt")
        for url in [old, fresh, other, notes] { try Data("{}".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        #expect(ClaudeCodeEngine.removeStaleMCPConfigs(in: folder) == 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["orb-mcp-B.json", "outro.json", "orb-mcp-notes.txt"])
        // Everything of ours goes once it is old enough, whatever its name after the prefix.
        #expect(ClaudeCodeEngine.removeStaleMCPConfigs(in: folder, now: .now.addingTimeInterval(600)) == 1)
        #expect(ClaudeCodeEngine.removeStaleMCPConfigs(in: folder.appendingPathComponent("nao-existe")) == 0)
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
                                                  "CLAUDE_AGENT_SDK_VERSION": "1", "HTTPS_PROXY": "http://proxy:3128", "ANTHROPIC_MODEL": "m"], path: "/p")
        #expect(environment == ["HOME": "/h", "HTTPS_PROXY": "http://proxy:3128", "PATH": "/p"])
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

    @Test func theResultsUsageIsKeptForTheEngine() {
        var transcript = ClaudeCodeTranscript(isResuming: false)
        #expect(transcript.usage == nil && transcript.costUSD == nil)
        _ = transcript.apply(.started(sessionID: "s"))
        let events = transcript.apply(.result(ClaudeCodeResult(isError: false, message: "Oi", sessionID: "s",
                                                               usage: TokenUsage(input: 1, output: 2), costUSD: 0.5)))
        #expect(transcript.usage == TokenUsage(input: 1, output: 2) && transcript.costUSD == 0.5)
        // The usage reaches the app like the native engine's, so the meter shows Claude Code turns too.
        #expect(events.contains { if case .usage(let used) = $0 { used == TokenUsage(input: 1, output: 2) } else { false } })
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

    @Test func catchUpKeepsTheMostRecentMessagesWholeAndSummarizesTheRestWhenLong() {
        let long = (0..<200).map { ChatMessage.user("mensagem \($0) " + String(repeating: "x", count: 100)) }
        let text = ClaudeCodePrompt.catchUp(long, limit: 2_000)
        #expect(text.count < 2_400)
        #expect(text.contains("User: mensagem 199 "))
        #expect(!text.contains("User: mensagem 0 "))
        // The first request is not lost with the cut: it heads the summary of what did not fit.
        #expect(text.contains("Pedido original: mensagem 0 "))
        // Whole messages only: every listed line is complete.
        for line in text.components(separatedBy: "\n") where line.hasPrefix("User: ") {
            #expect(line.hasSuffix(String(repeating: "x", count: 100)))
        }
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

    /// Errors people hit most with a plan (the limit, the overload, billing) are told in Portuguese, the CLI's words last.
    @Test func commonFailuresAreToldInPortuguese() throws {
        func failure(_ message: String, apiError: String? = nil) -> String {
            var transcript = ClaudeCodeTranscript(isResuming: false)
            _ = transcript.apply(.started(sessionID: "s"))
            if let apiError { _ = transcript.apply(.apiError(apiError)) }
            guard case .failed(let text) = transcript.apply(.result(ClaudeCodeResult(isError: true, message: message, sessionID: "s"))).last
            else { Issue.record("expected failure"); return "" }
            return text
        }
        let limit = failure("Claude AI usage limit reached|1759874400", apiError: "rate_limit")
        #expect(limit.hasPrefix("Você chegou ao limite de uso do seu plano Claude."))
        #expect(!limit.contains("|1759874400") && limit.contains("por volta de") && limit.hasSuffix("Detalhe do Claude Code: Claude AI usage limit reached"))
        // A limit of the conversation is not the plan's, but "5-hour limit reached" is.
        #expect(failure("Context limit reached") == "Context limit reached")
        #expect(failure("Prompt is too long: token limit reached") == "Prompt is too long: token limit reached")
        #expect(failure("5-hour limit reached").hasPrefix("Você chegou ao limite de uso do seu plano Claude."))
        // Without the epoch, or recognised only by its words.
        let plain = failure("You've hit your limit")
        #expect(plain.hasPrefix("Você chegou ao limite") && !plain.contains("por volta de"))
        #expect(failure(#"API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}"#).hasPrefix("O serviço da Anthropic está instável"))
        #expect(failure("Internal error", apiError: "server_error").hasPrefix("O serviço da Anthropic está instável"))
        #expect(failure("Credit balance too low", apiError: "billing_error").hasPrefix("Há um problema de cobrança"))
        #expect(failure("error_during_execution") == "O Claude Code encerrou com erro (error_during_execution).")
        // Anything else is still shown as the CLI said it.
        #expect(failure("Something odd happened") == "Something odd happened")
        // The notice's actions only look at the app's own sentence, so a limit offers "Tentar de novo", not Ajustes.
        #expect(NoticeAction.actions(for: NoticeAction.failurePrefix + limit) == [.retry])
    }

    /// An error that passed (the CLI went on after it) does not describe a later, different failure.
    @Test func aPassingAPIErrorDoesNotColourTheFinalFailure() {
        func final(_ events: [ClaudeCodeMessage]) -> String {
            var transcript = ClaudeCodeTranscript(isResuming: false)
            for event in events { _ = transcript.apply(event) }
            guard case .failed(let text) = transcript.apply(.result(ClaudeCodeResult(isError: true, message: "error_max_turns", sessionID: "s"))).last
            else { Issue.record("expected failure"); return "" }
            return text
        }
        #expect(final([.started(sessionID: "s"), .apiError("server_error"), .text("Voltei."), .toolUse(id: "t", name: "Bash", input: .object([:]))])
            == "O Claude Code encerrou com erro (error_max_turns).")
        #expect(final([.started(sessionID: "s"), .text("Vou."), .apiError("server_error")]).hasPrefix("O serviço da Anthropic está instável"))
    }

    @Test func theResetTimeIsShownInLocalTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let resets = 1759874400.0 // 2025-10-07 22:00 UTC
        let now = Date(timeIntervalSince1970: resets - 3600)
        let sameDay = ClaudeCodeTranscript.failureText("usage limit reached|1759874400", apiError: nil, now: now, timeZone: utc)
        #expect(sameDay.contains("por volta de 22:00."))
        let later = ClaudeCodeTranscript.failureText("usage limit reached|1759874400", apiError: nil, now: now.addingTimeInterval(-86_400 * 3), timeZone: utc)
        #expect(later.contains("por volta de 07/10 às 22:00."))
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        #expect(ClaudeCodeTranscript.failureText("usage limit reached|1759874400", apiError: nil, now: now, timeZone: saoPaulo)
            .contains("por volta de 19:00."))
    }

    @Test func claudeCodeLearnsWhenTheInterfaceToolsAreHeldBack() {
        let base = ClaudeCodePrompt.make(bot: Bot(name: "Atlas", role: "", orb: OrbConfig()), skills: [], environment: .current())
        #expect(ClaudeCodePrompt.withAccessibilityNote(base, accessibilityGranted: true) == base)
        #expect(ClaudeCodePrompt.withAccessibilityNote(base, accessibilityGranted: nil) == base)
        let held = ClaudeCodePrompt.withAccessibilityNote(base, accessibilityGranted: false)
        #expect(held.hasPrefix(base) && held.contains("Acessibilidade") && held.contains("ui_read"))
    }
}

// MARK: - The CLI's environment and process

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
