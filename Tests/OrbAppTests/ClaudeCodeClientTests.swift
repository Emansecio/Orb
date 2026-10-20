import Foundation
import Testing
@testable import Orb

/// A stand-in `claude` that speaks the stream-json + control protocol like the real one does with the pipe flags: answers
/// `initialize`, streams Anthropic events, asks `can_use_tool` for the Orb's tools and, once allowed, reads the mailbox file
/// itself (as the MCP server would) before the next message. Every launch writes `launch-<pid>.json` (argv, cwd, the files it was
/// given) and every stdin line goes to `stdin-<pid>.log`.
private let fakeClaude = #"""
#!/usr/bin/python3
import json, os, sys, time

args = sys.argv[1:]
log_dir = os.environ["FAKE_LOG"]
scenario = os.environ.get("FAKE_SCENARIO", "text")
steps = int(os.environ.get("FAKE_TOOL_STEPS", "1"))
per_step = int(os.environ.get("FAKE_TOOLS_PER_STEP", "1"))
pid = os.getpid()

def opt(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None

def read_file(path):
    try:
        with open(path) as handle:
            return handle.read()
    except Exception:
        return None

record = {"args": args, "cwd": os.path.realpath(os.getcwd()),
          "env": {k: os.environ.get(k) for k in ["DISABLE_AUTO_COMPACT", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                                                  "DISABLE_NON_ESSENTIAL_MODEL_CALLS", "MAX_MCP_OUTPUT_TOKENS", "FAKE_SCENARIO"]}}
system_path = opt("--system-prompt-file")
record["systemPath"] = system_path
record["system"] = read_file(system_path) if system_path else None
resume = [a.split("=", 1)[1] for a in args if a.startswith("--resume=")]
if resume:
    record["sessionPath"] = os.path.join(os.environ["FAKE_PROJECT_DIR"], resume[0] + ".jsonl")
    record["session"] = read_file(record["sessionPath"])
mailbox = None
mcp_path = opt("--mcp-config")
if mcp_path:
    record["mcpPath"] = mcp_path
    config = json.loads(read_file(mcp_path))
    record["mcp"] = config
    server_args = config["mcpServers"]["orb"]["args"]
    declarations = server_args[server_args.index("--pipe-tools") + 1]
    mailbox = server_args[server_args.index("--pipe-mailbox") + 1]
    record["declarations"] = json.loads(read_file(declarations))
with open(os.path.join(log_dir, "launch-%d.json" % pid), "w") as handle:
    handle.write(json.dumps(record))

stdin_log = open(os.path.join(log_dir, "stdin-%d.log" % pid), "a")
def log(text):
    stdin_log.write(text.rstrip("\n") + "\n"); stdin_log.flush()

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

def event(e):
    emit({"type": "stream_event", "event": e, "session_id": "s", "parent_tool_use_id": None, "uuid": "u"})

def read_message():
    while True:
        raw = sys.stdin.readline()
        if raw == "":
            log("eof")
            return None
        raw = raw.strip()
        if not raw:
            continue
        log(raw)
        message = json.loads(raw)
        if message.get("type") == "control_request" and message["request"]["subtype"] == "interrupt":
            log("interrupt")
            sys.exit(0)
        return message

counter = [0]
def api_message(blocks, stop):
    counter[0] += 1
    mid = "msg_%d" % counter[0]
    event({"type": "message_start", "message": {"id": mid, "role": "assistant", "content": [], "usage": {
        "input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5,
        "cache_creation": {"ephemeral_1h_input_tokens": 2}}}})
    for index, block in enumerate(blocks):
        if block[0] == "text":
            event({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
            event({"type": "content_block_delta", "index": index, "delta": {"type": "thinking_delta", "thinking": "hmm"}})
            for piece in block[1]:
                event({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": piece}})
            event({"type": "content_block_stop", "index": index})
            emit({"type": "assistant", "message": {"id": mid, "role": "assistant", "content": [{"type": "text", "text": "".join(block[1])}], "stop_reason": None}})
        else:
            _, tool_id, name, pieces = block
            event({"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": tool_id, "name": name, "input": {}}})
            for piece in pieces:
                event({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": piece}})
            event({"type": "content_block_stop", "index": index})
            emit({"type": "assistant", "message": {"id": mid, "role": "assistant", "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": json.loads("".join(pieces))}], "stop_reason": None}})
    event({"type": "message_delta", "delta": {"stop_reason": stop}, "usage": {"output_tokens": 42}})
    event({"type": "message_stop"})

def result(text, **extra):
    body = {"type": "result", "subtype": "success", "is_error": False, "result": text, "session_id": "s",
            "usage": {"input_tokens": 10, "output_tokens": 42}, "total_cost_usd": 0.01}
    body.update(extra)
    emit(body)

def tool_step(step):
    ids = ["toolu_%d_%d" % (step, n) for n in range(per_step)]
    blocks = [("text", ["Vou ler. "])] if step == 0 else []
    for tool_id in ids:
        blocks.append(("tool", tool_id, "mcp__orb__read_file", ['{"path":', '"a.txt"}']))
    api_message(blocks, "tool_use")
    for tool_id in ids:
        emit({"type": "control_request", "request_id": "perm_" + tool_id, "request": {
            "subtype": "can_use_tool", "tool_name": "mcp__orb__read_file", "input": {"path": "a.txt"}, "tool_use_id": tool_id}})
    waiting = set("perm_" + tool_id for tool_id in ids)
    while waiting:
        message = read_message()
        if message is None:
            sys.exit(0)
        response = message.get("response") if message.get("type") == "control_response" else None
        if response and response["request_id"] in waiting and response["response"]["behavior"] == "allow":
            waiting.discard(response["request_id"])
    texts = []
    for tool_id in ids:
        path = os.path.join(mailbox, tool_id + ".json")
        deadline = time.time() + 5
        while not os.path.exists(path) and time.time() < deadline:
            time.sleep(0.02)
        found = json.loads(read_file(path)) if os.path.exists(path) else {"text": "MISSING"}
        if os.path.exists(path):
            os.remove(path)
        texts.append(found["text"])
    return texts

def turn():
    if scenario == "text":
        api_message([("text", ["Olá", ", mundo"])], "end_turn")
        result("Olá, mundo")
    elif scenario == "tool":
        texts = []
        for step in range(steps):
            texts = tool_step(step)
        final = "Resultado: " + " | ".join(texts)
        api_message([("text", [final])], "end_turn")
        result(final)
    elif scenario == "rate_limit":
        emit({"type": "assistant", "error": "rate_limit", "message": {"id": "e", "role": "assistant", "content": [{"type": "text", "text": "limite"}]}})
        result('API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Limite de uso"}}', is_error=True, api_error_status=429)
    elif scenario == "context":
        result("Prompt is too long", is_error=True, api_error_status=400)
    elif scenario == "auth":
        emit({"type": "assistant", "error": "authentication_failed", "message": {"id": "e", "role": "assistant", "content": [{"type": "text", "text": "Not logged in"}]}})
        result("Not logged in", is_error=True)
    elif scenario == "die":
        sys.stderr.write("boom: sem rede\n"); sys.stderr.flush()
        sys.exit(1)
    elif scenario == "hang":
        api_message_start = {"type": "message_start", "message": {"id": "h", "usage": {"input_tokens": 3}}}
        event(api_message_start)
        event({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "pensando"}})
        while read_message() is not None:
            pass
        sys.exit(0)

# initialize
while True:
    message = read_message()
    if message is None:
        sys.exit(0)
    if message.get("type") == "control_request" and message["request"]["subtype"] == "initialize":
        if scenario == "init_silent":
            time.sleep(300)
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {"models": []}}})
        break

served = False
while True:
    message = read_message()
    if message is None:
        sys.exit(0)
    if message.get("type") == "user" and (os.environ.get("FAKE_MULTI") == "1" or not served):
        served = True
        turn()
"""#

/// A fake CLI plus folders of its own, so tests run side by side.
private struct Rig {
    let root: URL
    let script: URL
    let logs: URL
    let folders: ClaudePipeFolders
    var environment: [String: String]

    init(scenario: String, toolSteps: Int = 1, toolsPerStep: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "orb-pipe-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        logs = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        script = root.appending(path: "claude")
        try fakeClaude.write(to: script, atomically: true, encoding: .utf8)
        try script.makeExecutable()
        folders = ClaudePipeFolders(workingDirectory: root.appending(path: "cwd", directoryHint: .isDirectory),
                                    scratch: root.appending(path: "runs", directoryHint: .isDirectory),
                                    home: root.appending(path: "home", directoryHint: .isDirectory))
        environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "FAKE_LOG": logs.path, "FAKE_SCENARIO": scenario,
                       "FAKE_TOOL_STEPS": String(toolSteps), "FAKE_TOOLS_PER_STEP": String(toolsPerStep),
                       "FAKE_PROJECT_DIR": folders.projectDirectory.path]
    }

    func client(initializeTimeout: Duration = .seconds(20), parkTimeout: Duration = .seconds(60), effort: String? = nil) -> ClaudeCodeClient {
        let launch = ClaudePipeLaunch(executable: script, environment: environment)
        return ClaudeCodeClient(launch: { launch }, orbBinary: URL(fileURLWithPath: "/fake/Orb"), folders: folders,
                                initializeTimeout: initializeTimeout, parkTimeout: parkTimeout, effort: effort)
    }

    /// A client per turn, as the app makes them, sharing `pool` (the process a turn leaves idle) for the conversation.
    func turnClient(pool: ClaudePipeIdlePool, conversation: String = "conv", idleTimeout: Duration = .seconds(60),
                    effort: String? = nil) -> ClaudeCodeClient {
        var environment = environment
        environment["FAKE_MULTI"] = "1"
        let launch = ClaudePipeLaunch(executable: script, environment: environment)
        return ClaudeCodeClient(launch: { launch }, orbBinary: URL(fileURLWithPath: "/fake/Orb"), folders: folders, effort: effort,
                                conversationID: conversation, idlePool: pool, idleTimeout: idleTimeout)
    }

    var metricsText: String { (try? String(contentsOf: root.appending(path: "cache-metrics.jsonl"), encoding: .utf8)) ?? "" }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// What each launch recorded, in launch order.
    var launches: [JSONValue] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter { $0.hasPrefix("launch-") }
        return names.compactMap { name in
            (try? Data(contentsOf: logs.appending(path: name))).flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// The stdin log of the launch with this index (`launches` order is by file name; with one or two launches the pid order is the launch order only
    /// by luck, so tests that need it use `stdinLogs`).
    var stdinLogs: [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter { $0.hasPrefix("stdin-") }.sorted()
        return names.map { (try? String(contentsOf: logs.appending(path: $0), encoding: .utf8)) ?? "" }
    }

    var scratchEntries: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folders.scratch.path)) ?? [] }
}

private func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func arguments(of launch: JSONValue?) -> [String] { (launch?["args"]?.array ?? []).compactMap { $0.string } }

private let readFile = ToolSpec(name: "read_file", description: "Reads a file", parameters: .schema(["path": .property("string")], required: ["path"]))
private let expectedUsage = TokenUsage(input: 10, output: 42, cacheRead: 100, cacheWrite: 5, cacheWrite1h: 2)

private func texts(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
}

struct ClaudeCodeClientTests {
    // MARK: Plain turn

    @Test func theOrbsEffortGoesToTheCLI() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        _ = try await collect(rig.client(effort: "xhigh").stream(model: "sonnet", messages: [.system("s"), .user("Oi")],
                                                                 tools: [], toolChoice: .auto))
        let args = arguments(of: rig.launches.first)
        #expect(args.contains("--effort=xhigh"))
        #expect(args.contains("--model=sonnet"))
    }

    @Test func plainTextTurnLaunchesTheCLIStrippedOfItsHarness() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let events = try await collect(rig.client().stream(model: "claude-sonnet-4-5", messages: [.system("Seja breve."), .user("Oi")],
                                                          tools: [], toolChoice: .auto))

        #expect(texts(events) == "Olá, mundo")
        #expect(events.first == .usage(TokenUsage(input: 10, output: 1, cacheRead: 100, cacheWrite: 5, cacheWrite1h: 2)))
        #expect(events.last == .finished(.done, expectedUsage))
        #expect(!events.contains { if case .toolCalls = $0 { true } else { false } })

        let launches = rig.launches
        #expect(launches.count == 1)
        let launch = try #require(launches.first)
        let args = arguments(of: launch)
        for flag in ["-p", "--include-partial-messages", "--verbose", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                     "--model=claude-sonnet-4-5"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        #expect(value(after: "--tools") == "")
        #expect(value(after: "--setting-sources") == "")
        #expect(value(after: "--input-format") == "stream-json")
        #expect(value(after: "--output-format") == "stream-json")
        #expect(value(after: "--permission-prompt-tool") == "stdio")
        #expect(value(after: "--permission-mode") == "default")
        #expect(!args.contains("--max-turns"), "no limit on turns")
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains { $0.hasPrefix("--resume") })
        #expect(!args.contains { $0.hasPrefix("--effort") })
        #expect(launch["system"]?.string == "Seja breve.")
        #expect(launch["cwd"]?.string == ClaudePipeFolders.realPath(rig.folders.workingDirectory))
        #expect(launch["env"]?["DISABLE_AUTO_COMPACT"]?.string == "1")
        #expect(launch["env"]?["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]?.string == "1")
        #expect(launch["env"]?["DISABLE_NON_ESSENTIAL_MODEL_CALLS"]?.string == "1")
        #expect(launch["env"]?["MAX_MCP_OUTPUT_TOKENS"]?.string == "200000")

        // stdin: initialize first, then the user message.
        let stdin = try #require(rig.stdinLogs.first).split(separator: "\n").map(String.init)
        #expect(stdin[0].contains(#""subtype":"initialize""#))
        let user = try #require(JSONValue.parse(stdin[1]))
        #expect(user["type"] == .string("user"))
        #expect(user["message"]?["content"]?.array?.first?["text"] == .string("Oi") || user["message"]?["content"] == .string("Oi"))
        // The per-run files are gone once the answer is complete.
        #expect(rig.scratchEntries.isEmpty)
    }

    @Test func theDefaultModelLeavesTheModelFlagOut() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        _ = try await collect(rig.client().stream(model: "default", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        let args = arguments(of: rig.launches.first)
        #expect(!args.contains { $0.hasPrefix("--model") })
    }

    @Test func historyGoesIntoASessionFileThatIsResumedThenDeleted() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let messages: [ChatMessage] = [.system("s"), .user("oi"), ChatMessage(role: .assistant, content: "olá, tudo bem"), .user("de novo")]
        _ = try await collect(rig.client().stream(model: "claude-x", messages: messages, tools: [], toolChoice: .auto))

        let launch = try #require(rig.launches.first)
        let resume = try #require(arguments(of: launch).first { $0.hasPrefix("--resume=") })
        let sessionID = String(resume.dropFirst("--resume=".count))
        #expect(sessionID == sessionID.lowercased() && UUID(uuidString: sessionID) != nil)
        // The CLI could read it when it started...
        let session = try #require(launch["session"]?.string)
        #expect(session.contains("olá, tudo bem") && session.contains(sessionID))
        // ...and the prompt is the last user message only.
        let stdin = try #require(rig.stdinLogs.first)
        #expect(stdin.contains("de novo") && !stdin.contains("olá, tudo bem"))
        // Nothing of it is left behind.
        let path = try #require(launch["sessionPath"]?.string)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(rig.scratchEntries.isEmpty)
    }

    @Test func sessionFilesAKilledAppLeftInTheProjectFolderAreSwept() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        // A crash skips `ClaudePipeRun.stop`, so the copy of the conversation stays in ~/.claude/projects until the next run clears it.
        let project = rig.folders.projectDirectory
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let old = project.appending(path: "old.jsonl"), recent = project.appending(path: "new.jsonl"), other = project.appending(path: "notes.txt")
        for url in [old, recent, other] { try Data("{}\n".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: other.path)
        _ = try await collect(rig.client().stream(model: "claude-x", messages: [.system("s"), .user("oi")], tools: [], toolChoice: .auto))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        // Only the CLI's session files: the folder may hold what is not ours.
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Tool steps

    @Test func aToolStepParksTheProcessAndTheResultsContinueItWithoutANewLaunch() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        let client = rig.client()
        let first: [ChatMessage] = [.system("s"), .user("Leia a.txt")]
        let call = ToolCallRequest(id: "toolu_0_0", name: "read_file", arguments: #"{"path":"a.txt"}"#)

        let step1 = try await collect(client.stream(model: "m", messages: first, tools: [readFile], toolChoice: .auto))
        #expect(texts(step1) == "Vou ler. ")
        #expect(step1.contains(.toolCalls([call])))
        #expect(step1.last == .finished(.toolUse, expectedUsage))
        // The calls come before the end of the stream, and the tool declarations were handed to the CLI.
        let launch = try #require(rig.launches.first)
        #expect(launch["mcp"]?["mcpServers"]?["orb"]?["command"] == .string("/fake/Orb"))
        #expect(launch["declarations"]?.array?.first?["name"] == .string("read_file"))
        #expect(launch["args"]?.array?.contains(.string("--mcp-config")) == true)
        // The process is alive and its run folder too.
        #expect(rig.scratchEntries.count == 1)

        let second = first + [ChatMessage(role: .assistant, content: "Vou ler. ", toolCalls: [call]), .tool("toolu_0_0", "conteúdo do a.txt")]
        let step2 = try await collect(client.stream(model: "m", messages: second, tools: [readFile], toolChoice: .auto))
        #expect(texts(step2) == "Resultado: conteúdo do a.txt")
        #expect(step2.last == .finished(.done, expectedUsage))

        #expect(rig.launches.count == 1)
        let stdin = try #require(rig.stdinLogs.first).split(separator: "\n").map(String.init)
        // initialize, the user message, then the answer to can_use_tool; nothing else was sent.
        #expect(stdin.count >= 3)
        let permission = try #require(JSONValue.parse(stdin[2]))
        #expect(permission["response"]?["request_id"] == .string("perm_toolu_0_0"))
        #expect(permission["response"]?["response"]?["behavior"] == .string("allow"))
        #expect(permission["response"]?["response"]?["updatedInput"]?["path"] == .string("a.txt"))
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    @Test func steeringMessagesGoToTheSameProcessAsUserMessages() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        let client = rig.client()
        let first: [ChatMessage] = [.system("s"), .user("Leia a.txt")]
        let call = ToolCallRequest(id: "toolu_0_0", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        _ = try await collect(client.stream(model: "m", messages: first, tools: [readFile], toolChoice: .auto))

        let second = first + [ChatMessage(role: .assistant, content: "Vou ler. ", toolCalls: [call]), .tool("toolu_0_0", "ok"),
                              .user("e depois leia b.txt")]
        let events = try await collect(client.stream(model: "m", messages: second, tools: [readFile], toolChoice: .auto))
        #expect(texts(events) == "Resultado: ok")
        #expect(rig.launches.count == 1)
        #expect(await waitUntil { rig.stdinLogs.first?.contains("e depois leia b.txt") == true && rig.stdinLogs.first?.contains("eof") == true })
    }

    @Test func parallelToolCallsAreAnsweredTogetherInAnyOrder() async throws {
        let rig = try Rig(scenario: "tool", toolsPerStep: 2)
        defer { rig.cleanUp() }
        let client = rig.client()
        let first: [ChatMessage] = [.system("s"), .user("Leia os dois")]
        let step1 = try await collect(client.stream(model: "m", messages: first, tools: [readFile], toolChoice: .auto))
        let calls = try #require(step1.compactMap { event -> [ToolCallRequest]? in if case .toolCalls(let calls) = event { calls } else { nil } }.first)
        #expect(calls.map(\.id) == ["toolu_0_0", "toolu_0_1"])

        // Results in the reverse order of the calls; the second one failed.
        let second = first + [ChatMessage(role: .assistant, content: "Vou ler. ", toolCalls: calls),
                              .tool("toolu_0_1", "erro b", isError: true), .tool("toolu_0_0", "texto a")]
        let events = try await collect(client.stream(model: "m", messages: second, tools: [readFile], toolChoice: .auto))
        #expect(texts(events) == "Resultado: texto a | erro b")
        #expect(rig.launches.count == 1)
    }

    @Test func severalToolStepsShareOneProcess() async throws {
        let rig = try Rig(scenario: "tool", toolSteps: 3)
        defer { rig.cleanUp() }
        let client = rig.client()
        var messages: [ChatMessage] = [.system("s"), .user("Leia")]
        for step in 0..<3 {
            let events = try await collect(client.stream(model: "m", messages: messages, tools: [readFile], toolChoice: .auto))
            let calls = try #require(events.compactMap { event -> [ToolCallRequest]? in if case .toolCalls(let calls) = event { calls } else { nil } }.first)
            #expect(calls.map(\.id) == ["toolu_\(step)_0"])
            messages += [ChatMessage(role: .assistant, content: texts(events), toolCalls: calls), .tool(calls[0].id, "r\(step)")]
        }
        let last = try await collect(client.stream(model: "m", messages: messages, tools: [readFile], toolChoice: .auto))
        #expect(texts(last) == "Resultado: r2")
        #expect(last.last == .finished(.done, expectedUsage))
        #expect(rig.launches.count == 1)
    }

    @Test func messagesThatDoNotContinueTheParkedStepStartAFreshProcess() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        let client = rig.client()
        let first: [ChatMessage] = [.system("s"), .user("Leia a.txt")]
        let call = ToolCallRequest(id: "toolu_0_0", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        _ = try await collect(client.stream(model: "m", messages: first, tools: [readFile], toolChoice: .auto))

        // The user edited the request: the old part of the conversation is not the one the process holds.
        let changed: [ChatMessage] = [.system("s"), .user("Leia b.txt"), ChatMessage(role: .assistant, content: "Vou ler. ", toolCalls: [call]),
                                      .tool("toolu_0_0", "conteúdo")]
        _ = try await collect(client.stream(model: "m", messages: changed, tools: [readFile], toolChoice: .auto))

        #expect(rig.launches.count == 2)
        // The abandoned process was told to stop (its stdin closed) and the new one got the results as text.
        #expect(await waitUntil { rig.stdinLogs.filter { $0.contains("eof") }.count == 1 })
        #expect(rig.stdinLogs.contains { $0.contains("conteúdo") && $0.contains("Leia b.txt") })
    }

    // MARK: Idle process between turns

    private let answered: [ChatMessage] = [.system("s"), .user("Oi"), ChatMessage(role: .assistant, content: "Olá, mundo")]

    @Test func theNextTurnReusesTheIdleProcessAndSendsOnlyTheNewMessage() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        let first = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        #expect(texts(first) == "Olá, mundo")
        #expect(pool.count == 1)
        #expect(rig.stdinLogs.first?.contains("eof") != true)

        // A new client, as the app makes one per turn; the history comes back as the Orb stores it (no itemID needed, reasoning dropped).
        var stored = answered
        stored[1].itemID = UUID()
        stored[2].reasoning = nil
        let second = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: stored + [.user("E agora?")], tools: [readFile], toolChoice: .auto))
        #expect(texts(second) == "Olá, mundo")
        #expect(rig.launches.count == 1)
        let stdin = try #require(rig.stdinLogs.first).split(separator: "\n").map(String.init)
        #expect(stdin.filter { $0.contains("\"type\":\"user\"") || $0.contains("\"type\": \"user\"") }.count == 2)
        #expect(stdin.last { $0.contains("E agora?") } != nil)
        #expect(!stdin.contains { $0.contains("E agora?") && $0.contains("Oi") })
        #expect(await waitUntil { rig.metricsText.contains(#""plan":"idle""#) })
        #expect(pool.count == 1)
    }

    @Test func anEditedHistoryEndsTheIdleProcessAndStartsANewOne() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        var edited = answered
        edited[1] = .user("Oi, editado")
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: edited + [.user("E agora?")], tools: [readFile], toolChoice: .auto))
        #expect(rig.launches.count == 2)
        #expect(await waitUntil { rig.stdinLogs.filter { $0.contains("eof") }.count == 1 })
    }

    @Test func anAnswerTheOrbStoredDifferentlyIsNotAContinuation() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        var other = answered
        other[2].content = "Outra resposta"
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: other + [.user("E agora?")], tools: [readFile], toolChoice: .auto))
        #expect(rig.launches.count == 2)
    }

    @Test func aChangeOfModelOrEffortStartsANewProcess() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "outro", messages: answered + [.user("E agora?")], tools: [readFile], toolChoice: .auto))
        #expect(rig.launches.count == 2)
        // The second process is idle now; the same model with another effort is not it either.
        let third: [ChatMessage] = answered + [.user("E agora?"), ChatMessage(role: .assistant, content: "Olá, mundo"), .user("Mais uma")]
        _ = try await collect(rig.turnClient(pool: pool, effort: "high").stream(model: "outro", messages: third, tools: [readFile], toolChoice: .auto))
        #expect(rig.launches.count == 3)
    }

    @Test func anIdleProcessNobodyComesBackForIsEnded() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        _ = try await collect(rig.turnClient(pool: pool, idleTimeout: .milliseconds(300)).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        #expect(await waitUntil { rig.stdinLogs.first?.contains("eof") == true })
        #expect(pool.count == 0)
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    @Test func aStoppedTurnLeavesNothingIdle() async throws {
        let rig = try Rig(scenario: "hang")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        let task = Task { try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto)) }
        #expect(await waitUntil { !rig.launches.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        #expect(pool.count == 0)
    }

    @Test func theLeastRecentlyUsedIdleProcessIsClosedPastTheLimit() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool(limit: 1)
        _ = try await collect(rig.turnClient(pool: pool, conversation: "a").stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        _ = try await collect(rig.turnClient(pool: pool, conversation: "b").stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        #expect(pool.count == 1)
        #expect(await waitUntil { rig.stdinLogs.filter { $0.contains("eof") }.count == 1 })
        pool.stop("b")
        #expect(pool.count == 0)
        #expect(await waitUntil { rig.stdinLogs.filter { $0.contains("eof") }.count == 2 })
    }

    @Test func anIdleProcessThatDiedFallsBackToANewOneWithoutAnError() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let pool = ClaudePipeIdlePool()
        _ = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: Array(answered.prefix(2)), tools: [readFile], toolChoice: .auto))
        let entry = try #require(pool.take("conv"))
        kill(entry.run.process.pid, SIGKILL)
        #expect(await waitUntil { entry.run.process.hasExited })
        pool.put("conv", run: entry.run, seen: entry.seen, setup: entry.setup, timeout: .seconds(60))
        let events = try await collect(rig.turnClient(pool: pool).stream(model: "m", messages: answered + [.user("E agora?")], tools: [readFile], toolChoice: .auto))
        #expect(texts(events) == "Olá, mundo")
        #expect(rig.launches.count == 2)
    }

    @Test func idleContinuationAcceptsOnlyNewUserMessagesAfterTheAnswer() {
        let seen = answered
        #expect(ClaudeCodeClient.idleContinuation(of: seen + [.user("x")], after: seen) == [.user("x")])
        #expect(ClaudeCodeClient.idleContinuation(of: seen + [.user("x"), .user("y")], after: seen)?.count == 2)
        #expect(ClaudeCodeClient.idleContinuation(of: seen, after: seen) == nil)
        #expect(ClaudeCodeClient.idleContinuation(of: seen + [ChatMessage(role: .assistant, content: "z")], after: seen) == nil)
        #expect(ClaudeCodeClient.idleContinuation(of: Array(seen.dropFirst()) + [.user("x")], after: seen) == nil)
        // The answer is compared by text, trimmed: the Orb keeps the model's text as it came.
        var padded = seen
        padded[2].content = "Olá, mundo\n"
        #expect(ClaudeCodeClient.idleContinuation(of: padded + [.user("x")], after: seen) != nil)
    }

    @Test func noToolsAtTheLastStepStartsAFreshProcessWithoutMCP() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        let client = rig.client()
        let first: [ChatMessage] = [.system("s"), .user("Leia a.txt")]
        let call = ToolCallRequest(id: "toolu_0_0", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        _ = try await collect(client.stream(model: "m", messages: first, tools: [readFile], toolChoice: .auto))

        let second = first + [ChatMessage(role: .assistant, content: "Vou ler. ", toolCalls: [call]), .tool("toolu_0_0", "ok")]
        // The "tool" scenario would call a tool again; what matters is how the second process was started.
        let events = try? await collect(client.stream(model: "m", messages: second, tools: [readFile], toolChoice: .none))
        _ = events
        let launches = rig.launches
        #expect(launches.count == 2)
        let withoutMCP = launches.filter { $0["mcp"] == nil }
        #expect(withoutMCP.count == 1)
        #expect(withoutMCP.first?["args"]?.array?.contains(.string("--mcp-config")) == false)
        #expect(withoutMCP.first?["args"]?.array?.contains(.string("--strict-mcp-config")) == true)
    }

    @Test func aParkedProcessNobodyContinuesIsEnded() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        let client = rig.client(parkTimeout: .milliseconds(300))
        _ = try await collect(client.stream(model: "m", messages: [.system("s"), .user("Leia")], tools: [readFile], toolChoice: .auto))
        #expect(await waitUntil { rig.stdinLogs.first?.contains("eof") == true })
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    @Test func droppingTheClientEndsAParkedProcess() async throws {
        let rig = try Rig(scenario: "tool")
        defer { rig.cleanUp() }
        do {
            let client = rig.client()
            _ = try await collect(client.stream(model: "m", messages: [.system("s"), .user("Leia")], tools: [readFile], toolChoice: .auto))
            #expect(rig.stdinLogs.first?.contains("eof") != true)
        }
        #expect(await waitUntil { rig.stdinLogs.first?.contains("eof") == true })
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    // MARK: Failures

    @Test func rateLimitBecomesAnHTTP429ThatTheEngineRetries() async throws {
        let rig = try Rig(scenario: "rate_limit")
        defer { rig.cleanUp() }
        let error = try #require(await #expect(throws: LLMError.self) {
            _ = try await collect(rig.client().stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        })
        #expect(error == .http(status: 429, message: "Limite de uso"))
        #expect(error.isRetryable)
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    @Test func promptTooLongBecomesContextExceeded() async throws {
        let rig = try Rig(scenario: "context")
        defer { rig.cleanUp() }
        let error = try #require(await #expect(throws: LLMError.self) {
            _ = try await collect(rig.client().stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        })
        #expect(error == .contextExceeded("Prompt is too long"))
    }

    @Test func aLoginErrorBecomesAnHTTP401() async throws {
        let rig = try Rig(scenario: "auth")
        defer { rig.cleanUp() }
        let error = try #require(await #expect(throws: LLMError.self) {
            _ = try await collect(rig.client().stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        })
        #expect(error == .http(status: 401, message: "Not logged in"))
    }

    @Test func aProcessThatDiesEarlyReportsItsStderr() async throws {
        let rig = try Rig(scenario: "die")
        defer { rig.cleanUp() }
        let error = try #require(await #expect(throws: LLMError.self) {
            _ = try await collect(rig.client().stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        })
        guard case .invalidResponse(let detail) = error else { Issue.record("wrong error \(error)"); return }
        #expect(detail.contains("boom: sem rede"))
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    @Test func aMissingInstallationSaysSoInPortuguese() async throws {
        let rig = try Rig(scenario: "text")
        defer { rig.cleanUp() }
        let client = ClaudeCodeClient(launch: { nil }, orbBinary: URL(fileURLWithPath: "/fake/Orb"), folders: rig.folders)
        let error = try #require(await #expect(throws: ClaudePipeError.self) {
            _ = try await collect(client.stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto))
        })
        #expect(error == .notInstalled)
        #expect(error.localizedDescription == "O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos.")
        #expect(rig.launches.isEmpty)
    }

    @Test func aSilentCLIIsGivenUpOnAfterTheInitializeTimeout() async throws {
        let rig = try Rig(scenario: "init_silent")
        defer { rig.cleanUp() }
        let started = ContinuousClock.now
        let error = try #require(await #expect(throws: LLMError.self) {
            _ = try await collect(rig.client(initializeTimeout: .milliseconds(400)).stream(model: "m", messages: [.system("s"), .user("Oi")],
                                                                                              tools: [], toolChoice: .auto))
        })
        guard case .invalidResponse(let detail) = error else { Issue.record("wrong error \(error)"); return }
        #expect(detail.contains("inicialização"))
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    // MARK: Cancellation

    @Test func cancellingTheStreamInterruptsAndEndsTheProcess() async throws {
        let rig = try Rig(scenario: "hang")
        defer { rig.cleanUp() }
        let client = rig.client()
        let stream = client.stream(model: "m", messages: [.system("s"), .user("Oi")], tools: [], toolChoice: .auto)
        let (seen, signal) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            for try await event in stream {
                if case .text = event { signal.yield(()) }
            }
        }
        var iterator = seen.makeAsyncIterator()
        _ = await iterator.next() // the first text arrived
        consumer.cancel()
        #expect(await waitUntil { rig.stdinLogs.first?.contains("interrupt") == true })
        #expect(await waitUntil { rig.scratchEntries.isEmpty })
    }

    // MARK: Pure parts

    @Test func continuationRequiresTheSameHistoryTheExactCallsAndTheirResults() throws {
        let call = ToolCallRequest(id: "t1", name: "read_file", arguments: "{}")
        let other = ToolCallRequest(id: "t2", name: "read_file", arguments: "{}")
        let previous: [ChatMessage] = [.system("s"), .user("oi")]
        let assistant = ChatMessage(role: .assistant, content: "x", toolCalls: [call, other])
        let ok = previous + [assistant, .tool("t2", "b"), .tool("t1", "a", isError: true), .user("steer")]

        let found = try #require(ClaudeCodeClient.continuation(of: ok, after: previous, toolIDs: ["t1", "t2"]))
        #expect(Set(found.results.map(\.id)) == ["t1", "t2"])
        #expect(found.results.first { $0.id == "t1" }?.result == ClaudePipeToolResult(text: "a", images: [], isError: true))
        #expect(found.extras.map(\.content) == ["steer"])

        func matches(_ messages: [ChatMessage], ids: [String] = ["t1", "t2"]) -> Bool {
            ClaudeCodeClient.continuation(of: messages, after: previous, toolIDs: ids) != nil
        }
        #expect(!matches(previous + [assistant, .tool("t1", "a")])) // a result is missing
        #expect(!matches(previous + [assistant, .tool("t1", "a"), .tool("t3", "c")])) // an unknown id
        #expect(!matches(previous + [assistant, .tool("t1", "a"), .tool("t2", "b"), ChatMessage(role: .assistant, content: "hm")])) // not a user message
        #expect(!matches([.system("s"), .user("outro")] + [assistant, .tool("t1", "a"), .tool("t2", "b")])) // old part differs
        #expect(!matches(previous + [ChatMessage(role: .assistant, content: "x", toolCalls: [call]), .tool("t1", "a"), .tool("t2", "b")])) // other calls
        #expect(!matches(previous + [assistant, .tool("t1", "a"), .user("steer"), .tool("t2", "b")])) // a user message between results
        #expect(!matches(ok, ids: [])) // nothing parked
        #expect(!matches(previous)) // nothing new at all
    }

    @Test func theStepStateReadsTextToolCallsUsageAndStop() throws {
        var state = ClaudePipeStepState()
        func feed(_ line: String) -> [LLMEvent] { state.ingest(JSONValue.parse(line)!) }
        #expect(feed(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":7,"cache_read_input_tokens":3}}}}"#)
            == [.usage(TokenUsage(input: 7, cacheRead: 3))])
        #expect(feed(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#).isEmpty)
        #expect(feed(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}}"#).isEmpty)
        #expect(feed(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}}"#) == [.text("ok")])
        _ = feed(#"{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t9","name":"mcp__orb__shell","input":{}}}}"#)
        _ = feed(#"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}}"#)
        _ = feed(#"{"type":"stream_event","event":{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"t10","name":"mcp__orb__noargs","input":{}}}}"#)
        // The finished block of the same call changes nothing; an unseen one is added.
        _ = feed(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t9","name":"mcp__orb__shell","input":{"command":"ls"}},{"type":"tool_use","id":"t11","name":"mcp__orb__late","input":{"a":1}}]}}"#)
        _ = feed(#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}}"#)

        let step = state.step
        #expect(step.stop == .toolUse)
        #expect(step.calls == [ToolCallRequest(id: "t9", name: "shell", arguments: #"{"command":"ls"}"#),
                               ToolCallRequest(id: "t10", name: "noargs", arguments: "{}"),
                               ToolCallRequest(id: "t11", name: "late", arguments: #"{"a":1}"#)])
        #expect(step.usage == TokenUsage(input: 7, output: 20, cacheRead: 3))
    }

    @Test func aCLIThatDoesNotStreamStillShowsItsTextAndCalls() {
        var state = ClaudePipeStepState()
        let events = state.ingest(JSONValue.parse(#"{"type":"assistant","message":{"id":"x","stop_reason":"end_turn","content":[{"type":"text","text":"Olá"}]}}"#)!)
        #expect(events == [.text("Olá")])
        #expect(state.step.stop == .done)
        // An error notice is not the model's text.
        var failing = ClaudePipeStepState()
        #expect(failing.ingest(JSONValue.parse(#"{"type":"assistant","error":"rate_limit","message":{"content":[{"type":"text","text":"limite"}]}}"#)!).isEmpty)
        #expect(failing.assistantError?.code == "rate_limit")
    }

    @Test func aReplyTheCLICarriesOnAfterACutIsOneStepWithSummedUsage() {
        var state = ClaudePipeStepState()
        func feed(_ line: String) -> [LLMEvent] { state.ingest(JSONValue.parse(line)!) }
        _ = feed(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"a","usage":{"input_tokens":5}}}}"#)
        _ = feed(#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":10}}}"#)
        #expect(state.step.stop == .maxTokens)
        _ = feed(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"b","usage":{"input_tokens":6}}}}"#)
        #expect(state.stop == nil)
        _ = feed(#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}}"#)
        #expect(state.step.stop == .done)
        #expect(state.step.usage == TokenUsage(input: 11, output: 14))
    }

    @Test func errorsMapOntoWhatTheEngineRetriesOrReports() throws {
        func map(_ json: String, code: String? = nil) throws -> LLMError {
            let value = try #require(JSONValue.parse(json))
            return try #require(ClaudePipeErrors.error(forResult: value, assistantError: code.map { ($0, "") }) as? LLMError)
        }
        #expect(try map(#"{"type":"result","is_error":true,"api_error_status":529,"result":"API Error: 529 {\"error\":{\"message\":\"Overloaded\"}}"}"#)
            == .http(status: 529, message: "Overloaded"))
        #expect(try map(#"{"type":"result","is_error":true,"result":"API Error: 503 Service Unavailable"}"#) == .http(status: 503, message: "API Error: 503 Service Unavailable"))
        #expect(try map(#"{"type":"result","is_error":true,"api_error_status":400,"result":"prompt is too long: 250000 tokens > 200000 maximum"}"#)
            == .contextExceeded("prompt is too long: 250000 tokens > 200000 maximum"))
        #expect(try map(#"{"type":"result","is_error":true,"subtype":"error_max_turns"}"#) == .invalidResponse("error_max_turns"))
        #expect(try map(#"{"type":"result","is_error":true,"result":"Please run /login"}"#, code: "authentication_failed")
            == .http(status: 401, message: "Please run /login"))
    }
}
