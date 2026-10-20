import Foundation
import os

// Claude Code as a pipe: the Orb's own engine (`AgentEngine`) drives the model and its tools; the user's unmodified `claude` CLI is
// only the transport to the model, through their Claude subscription. One live CLI process serves the steps of an Orb turn: it stops
// at the model's tool calls (parked), the engine runs the tools, and the next `stream` call hands the results back to the SAME process
// through the mailbox (the CLI's MCP server for "orb" returns them to the model). Anything that does not continue a parked step starts
// a fresh process, with the conversation replayed from a session file (see `ClaudePipeSession`). A turn that ends with an answer
// leaves its process idle in `ClaudePipeIdlePool`, and the conversation's next message goes to it as one more stdin line: the
// process still has the prompt as the provider cached it, which a replayed session cannot reproduce.

/// How to start the CLI: its executable and the environment it runs in.
struct ClaudePipeLaunch: Sendable {
    var executable: URL
    var environment: [String: String]
}

/// A failure that is not the provider's (so no `LLMError` fits), worded for the person.
struct ClaudePipeError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static let notInstalled = ClaudePipeError(message: "O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos.")
}

final class ClaudeCodeClient: LLMClient, @unchecked Sendable {
    typealias LaunchProvider = @Sendable () async -> ClaudePipeLaunch?

    /// The installed CLI and the environment the Orb's commands get, plus the switches that keep the CLI from doing anything of its own.
    static let installedLaunch: LaunchProvider = {
        guard let installation = await ClaudeCode.shared.installation() else { return nil }
        return ClaudePipeLaunch(executable: installation.executable, environment: await ClaudeCode.shared.environment(for: installation))
    }

    /// The app's own binary, which the CLI starts as the "orb" MCP server (`--pipe-tools` mode).
    static var currentBinary: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/bin/false")
    }

    /// Added to the CLI's environment: no compaction, no background calls, and room for big tool results.
    static let pipeEnvironment = [
        "DISABLE_AUTO_COMPACT": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1",
        "MAX_MCP_OUTPUT_TOKENS": "200000",
    ]

    /// The CLI's environment: the launch's, plus ours, plus the cache lifetime when the caller chose one.
    static func environment(_ base: [String: String], cacheTTL: String?) -> [String: String] {
        var added = pipeEnvironment
        if let cacheTTL { added["CLAUDE_CODE_PROMPT_CACHE_TTL"] = cacheTTL }
        return base.merging(added) { _, ours in ours }
    }

    private let launch: LaunchProvider
    private let orbBinary: URL
    private let folders: ClaudePipeFolders
    private let initializeTimeout: Duration
    private let parkTimeout: Duration
    /// Sent as `--effort` (a level the model lists, see `ReasoningEffort.sent`); nil leaves the CLI's default.
    private let effort: String?
    /// Sent as `CLAUDE_CODE_PROMPT_CACHE_TTL` ("5m" or "1h"); nil leaves the CLI's own choice (an hour on a subscription).
    private let cacheTTL: String?
    /// A short tag of the conversation for the cache metrics, when the caller has an id (see `ClaudePipeMetric.tag`).
    private let conversationTag: String?
    /// The conversation's id: the key of the process its finished turn leaves idle (nil: no process is kept between turns).
    private let conversationID: String?
    private let idlePool: ClaudePipeIdlePool
    private let idleTimeout: Duration
    private let metrics: ClaudePipeMetricsLog

    /// What a step left behind: the live process waiting at the model's tool calls, and the messages of the call that got there.
    private struct Parked {
        var run: ClaudePipeRun
        var previous: [ChatMessage]
        var toolIDs: [String]
        var expiry: Task<Void, Never>
    }

    private struct State {
        var parked: Parked?
        /// The process a stream is reading (or starting) right now.
        var active: ClaudePipeRun?
        /// Counts `stream` calls: a call that is no longer the latest gives way.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(launch: @escaping LaunchProvider = ClaudeCodeClient.installedLaunch, orbBinary: URL = ClaudeCodeClient.currentBinary,
         folders: ClaudePipeFolders = .standard, initializeTimeout: Duration = .seconds(60), parkTimeout: Duration = .seconds(30 * 60),
         effort: String? = nil, cacheTTL: String? = nil, conversationID: String? = nil,
         idlePool: ClaudePipeIdlePool = .shared, idleTimeout: Duration = ClaudePipeIdlePool.defaultTimeout,
         keepsIdleProcess: Bool = true) {
        self.conversationID = keepsIdleProcess ? conversationID : nil
        self.idlePool = idlePool
        self.idleTimeout = idleTimeout
        self.launch = launch
        self.effort = effort
        self.cacheTTL = cacheTTL
        self.conversationTag = conversationID.map(ClaudePipeMetric.tag(of:))
        // Next to `cwd` and `runs`, so a test's folders keep its metrics out of the real data folder.
        self.metrics = ClaudePipeMetricsLog(file: folders.scratch.deletingLastPathComponent().appending(path: "cache-metrics.jsonl"))
        self.orbBinary = orbBinary
        self.folders = folders
        self.initializeTimeout = initializeTimeout
        self.parkTimeout = parkTimeout
    }

    deinit {
        let (parked, active) = state.withLock { state in
            defer { state.parked = nil; state.active = nil; state.generation += 1 }
            return (state.parked, state.active)
        }
        parked?.expiry.cancel()
        parked?.run.stop(interrupt: false)
        active?.stop(interrupt: true)
    }

    /// The cache is the provider's (the CLI marks the prompt itself), so a miss is worth a notice.
    var arrangesPromptCache: Bool { true }

    // MARK: Streaming

    private enum Plan {
        case resume(ClaudePipeRun, results: [(id: String, result: ClaudePipeToolResult)], extras: [ChatMessage])
        /// The process a finished turn of this conversation left idle, and the user messages that came after its answer.
        case idle(ClaudePipeRun, extras: [ChatMessage])
        case fresh(ClaudePipeMetric.FreshReason)
    }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let setup = ClaudePipeSetup(model: model, effort: effort, cacheTTL: cacheTTL, tools: tools, toolChoice: toolChoice)
        let (plan, generation) = decide(messages: messages, setup: setup)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.produce(plan, generation: generation, model: model, messages: messages, tools: tools, toolChoice: toolChoice,
                                   setup: setup, into: continuation)
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Takes what is parked (or idle) and says whether this call continues it. Whatever else was running gives way: one stream at a time.
    private func decide(messages: [ChatMessage], setup: ClaudePipeSetup) -> (Plan, Int) {
        let toolChoice = setup.toolChoice
        let (parked, superseded, generation) = state.withLock { state -> (Parked?, ClaudePipeRun?, Int) in
            state.generation += 1
            defer { state.parked = nil; state.active = nil }
            return (state.parked, state.active, state.generation)
        }
        superseded?.stop(interrupt: true)
        let idle = conversationID.flatMap { idlePool.take($0) }
        guard let parked else {
            guard let idle else { return (.fresh(.noParked), generation) }
            if idle.setup == setup, !idle.run.process.hasExited, let extras = Self.idleContinuation(of: messages, after: idle.seen) {
                return (.idle(idle.run, extras: extras), generation)
            }
            idle.run.stop(interrupt: false)
            return (.fresh(toolChoice == .auto ? .notContinuation : .toolChoice), generation)
        }
        idle?.run.stop(interrupt: false)
        parked.expiry.cancel()
        if toolChoice == .auto, let found = Self.continuation(of: messages, after: parked.previous, toolIDs: parked.toolIDs) {
            return (.resume(parked.run, results: found.results, extras: found.extras), generation)
        }
        parked.run.stop(interrupt: false)
        return (.fresh(toolChoice == .auto ? .notContinuation : .toolChoice), generation)
    }

    /// Whether `messages` is a new message of the conversation after the answer that ended the last turn: what the process saw
    /// (`seen`: the messages of its last call, then the assistant's answer) and then only user messages. The comparison is on what
    /// the model reads (role, text, calls, pictures), not on the Orb's bookkeeping (bubble ids, the reasoning the CLI never sees);
    /// the answer is compared by its text alone, trimmed. Returns the new messages.
    static func idleContinuation(of messages: [ChatMessage], after seen: [ChatMessage]) -> [ChatMessage]? {
        guard let answer = seen.last, answer.role == .assistant, messages.count > seen.count else { return nil }
        let before = seen.dropLast()
        guard zip(messages, before).allSatisfy({ readsAlike($0, $1) }) else { return nil }
        let reply = messages[before.count]
        guard reply.role == .assistant, reply.toolCalls.isEmpty,
              reply.content.trimmingCharacters(in: .whitespacesAndNewlines) == answer.content.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let extras = Array(messages[seen.count...])
        guard extras.allSatisfy({ $0.role == .user && !($0.content.isEmpty && $0.images.isEmpty) }) else { return nil }
        return extras
    }

    private static func readsAlike(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.role == b.role && a.content == b.content && a.toolCalls == b.toolCalls && a.toolCallID == b.toolCallID
            && a.isError == b.isError && a.images == b.images
    }

    /// Whether `messages` is exactly what the engine sends after running the parked tool calls: the previous call's messages, the
    /// assistant message with those calls, a result for each of them (in any order), then only user messages (steering).
    static func continuation(of messages: [ChatMessage], after previous: [ChatMessage], toolIDs: [String])
        -> (results: [(id: String, result: ClaudePipeToolResult)], extras: [ChatMessage])? {
        guard !toolIDs.isEmpty, messages.count > previous.count + toolIDs.count, messages.starts(with: previous) else { return nil }
        let assistant = messages[previous.count]
        guard assistant.role == .assistant, assistant.toolCalls.count == toolIDs.count,
              Set(assistant.toolCalls.map(\.id)) == Set(toolIDs) else { return nil }
        let tail = messages[(previous.count + 1)...]
        let tools = tail.prefix { $0.role == .tool }
        let extras = Array(tail.dropFirst(tools.count))
        guard tools.count == toolIDs.count, Set(tools.compactMap(\.toolCallID)) == Set(toolIDs), extras.allSatisfy({ $0.role == .user })
        else { return nil }
        let results = tools.compactMap { message in
            message.toolCallID.map { (id: $0, result: ClaudePipeToolResult(text: message.content, images: message.images, isError: message.isError)) }
        }
        return (results, extras)
    }

    private func produce(_ plan: Plan, generation: Int, model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice,
                         setup: ClaudePipeSetup, into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async {
        var started: ClaudePipeRun?
        var freshReason: ClaudePipeMetric.FreshReason?
        var reusedIdle = false
        // What the caller was shown: the answer for the idle record, and whether anything was shown at all (a process that died
        // idle can be replaced only before that).
        let shown = OSAllocatedUnfairLock(initialState: (text: "", any: false))
        let emit: @Sendable (LLMEvent) -> Void = { event in
            shown.withLock { shown in
                shown.any = true
                if case .text(let delta) = event { shown.text += delta }
            }
            continuation.yield(event)
        }
        do {
            var run: ClaudePipeRun
            var step: ClaudePipeStep
            /// A new process for this call (the history replayed from a session file).
            func startFresh(_ reason: ClaudePipeMetric.FreshReason) async throws -> (ClaudePipeRun, ClaudePipeStep) {
                freshReason = reason
                reusedIdle = false
                let run = try await begin(model: model, messages: messages, tools: tools, toolChoice: toolChoice)
                started = run
                guard register(run, generation: generation) else { throw CancellationError() }
                await run.sendFirstMessage()
                return (run, try await run.readStep(emit: emit))
            }
            switch plan {
            case .resume(let parked, let results, let extras):
                run = parked
                started = parked
                guard register(parked, generation: generation) else { throw CancellationError() }
                try await parked.resume(results: results, extras: extras)
                step = try await run.readStep(emit: emit)
            case .idle(let idle, let extras):
                run = idle
                started = idle
                reusedIdle = true
                guard register(idle, generation: generation) else { throw CancellationError() }
                do {
                    try await idle.sendUser(extras)
                    step = try await idle.readStep(emit: emit)
                } catch where !(error is CancellationError) && idle.process.hasExited && !shown.withLock({ $0.any }) {
                    // The idle process died on its own: the user hears nothing of it, a new one answers.
                    release(idle, generation: generation)
                    idle.stop(interrupt: false)
                    (run, step) = try await startFresh(.idleLost)
                }
            case .fresh(let reason):
                (run, step) = try await startFresh(reason)
            }
            try Task.checkCancellation()
            metrics.record(ClaudePipeMetric(timestamp: Date(), conversation: conversationTag, model: model, fresh: freshReason,
                                            messageCount: messages.count, characterCount: messages.reduce(0) { $0 + $1.content.count },
                                            usage: step.usage, idle: reusedIdle))
            if step.stop == .toolUse, !step.calls.isEmpty {
                // Parked before the engine hears of the calls: its next `stream` call may come at once.
                guard park(run, messages: messages, toolIDs: step.calls.map(\.id), generation: generation) else { throw CancellationError() }
                continuation.yield(.toolCalls(step.calls))
                continuation.yield(.finished(.toolUse, step.usage))
            } else {
                release(run, generation: generation)
                if step.stop == .done, step.calls.isEmpty, let conversationID {
                    // The turn is over, the process is not: the conversation's next message goes to it (see `ClaudePipeIdlePool`).
                    let answer = ChatMessage(role: .assistant, content: shown.withLock { $0.text })
                    idlePool.put(conversationID, run: run, seen: messages + [answer], setup: setup, timeout: idleTimeout)
                } else {
                    run.stop(interrupt: false)
                }
                if !step.calls.isEmpty { continuation.yield(.toolCalls(step.calls)) }
                continuation.yield(.finished(step.stop, step.usage))
            }
            continuation.finish()
        } catch {
            if let started {
                release(started, generation: generation)
                started.stop(interrupt: error is CancellationError)
            }
            if error is CancellationError { continuation.finish() } else { continuation.finish(throwing: error) }
        }
    }

    /// Marks `run` as the one being read, unless a newer call has taken over.
    private func register(_ run: ClaudePipeRun, generation: Int) -> Bool {
        state.withLock { state in
            guard state.generation == generation else { return false }
            state.active = run
            return true
        }
    }

    private func release(_ run: ClaudePipeRun, generation: Int) {
        state.withLock { state in
            if state.active === run { state.active = nil }
        }
    }

    private func park(_ run: ClaudePipeRun, messages: [ChatMessage], toolIDs: [String], generation: Int) -> Bool {
        let timeout = parkTimeout
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(run)
        }
        let parked = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.active = nil
            state.parked = Parked(run: run, previous: messages, toolIDs: toolIDs, expiry: expiry)
            return true
        }
        if !parked { expiry.cancel() }
        return parked
    }

    /// A parked process nobody came back for.
    private func expire(_ run: ClaudePipeRun) {
        let expired = state.withLock { state -> Bool in
            guard state.parked?.run === run else { return false }
            state.parked = nil
            return true
        }
        if expired { run.stop(interrupt: false) }
    }

    // MARK: Starting a process

    /// Writes the per-run files, starts the CLI and waits for it to answer `initialize`. The process has the conversation only
    /// through them: the system prompt, the session file (history) and the tools' declarations.
    private func begin(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) async throws -> ClaudePipeRun {
        guard let launch = await launch() else { throw ClaudePipeError.notInstalled }
        let split = ClaudePipeSession.split(messages)
        let fileManager = FileManager.default
        let runFolder = folders.scratch.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        var created: [URL] = [runFolder]
        func fail(_ error: Error) -> Error {
            for url in created { try? fileManager.removeItem(at: url) }
            return error
        }
        do {
            Self.sweepStaleRuns(in: folders.scratch)
            Self.sweepStaleRuns(in: folders.projectDirectory, onlySessionFiles: true)
            try fileManager.createDirectory(at: runFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: folders.workingDirectory, withIntermediateDirectories: true)

            let systemFile = runFolder.appendingPathComponent("system.txt")
            try Data(split.system.utf8).write(to: systemFile, options: .atomic)
            var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
                             "--verbose", "--system-prompt-file", systemFile.path, "--tools", "", "--strict-mcp-config"]

            var mailbox: ClaudePipeMailbox?
            if toolChoice == .auto, !tools.isEmpty {
                let declarations = runFolder.appendingPathComponent("tools.json")
                let mailboxFolder = runFolder.appendingPathComponent("mailbox", isDirectory: true)
                let config = runFolder.appendingPathComponent("mcp.json")
                try ClaudePipeTools.writeDeclarations(tools, to: declarations)
                try fileManager.createDirectory(at: mailboxFolder, withIntermediateDirectories: true)
                try Data(ClaudePipeTools.mcpConfig(binary: orbBinary, declarations: declarations, mailbox: mailboxFolder).jsonString.utf8)
                    .write(to: config, options: .atomic)
                arguments += ["--mcp-config", config.path]
                mailbox = ClaudePipeMailbox(directory: mailboxFolder)
            }
            arguments += ["--setting-sources", "", "--disable-slash-commands", "--no-session-persistence", "--permission-prompt-tool", "stdio",
                          "--permission-mode", "default"]
            if model != "default", !model.isEmpty { arguments.append("--model=\(model)") }
            if let effort, !effort.isEmpty { arguments.append("--effort=\(effort)") }

            if !split.history.isEmpty {
                let sessionID = UUID().uuidString.lowercased()
                let lines = try ClaudePipeSession.sessionLines(split.history, sessionID: sessionID,
                                                               cwd: ClaudePipeFolders.realPath(folders.workingDirectory), model: model, now: Date())
                let project = folders.projectDirectory
                try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
                let file = project.appendingPathComponent(sessionID + ".jsonl")
                created.append(file)
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
                arguments.append("--resume=\(sessionID)")
            }

            let prompt = split.prompt.isEmpty && split.images.isEmpty ? "continue" : split.prompt
            let firstLine = try ClaudePipeSession.userLine(prompt, images: split.images)
            let process = try LineProcess(executable: launch.executable, arguments: arguments, directory: folders.workingDirectory,
                                          environment: Self.environment(launch.environment, cacheTTL: cacheTTL))
            let run = ClaudePipeRun(process: process, mailbox: mailbox, cleanup: created, firstLine: firstLine)
            do {
                try await run.initialize(timeout: initializeTimeout)
            } catch {
                run.stop(interrupt: false)
                throw error
            }
            return run
        } catch {
            throw fail(error)
        }
    }

    /// Run folders a crashed app left behind (older than a day). With `onlySessionFiles`, the folder is the CLI's project folder
    /// of the neutral cwd, and what a crash leaves there is a `<session>.jsonl` with the whole conversation, which "forget"
    /// promises not to keep.
    static func sweepStaleRuns(in scratch: URL, onlySessionFiles: Bool = false) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-24 * 3600)
        for url in entries where !onlySessionFiles || url.pathExtension == "jsonl" {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < limit {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - The live process

/// The CLI's stdout lines, read by one step after another. An async stream's iterator cannot be advanced from inside an actor, and
/// dropping it would end the stream, so it lives here; only one step reads at a time.
final class PipeLineReader: @unchecked Sendable {
    private var iterator: AsyncStream<String>.Iterator

    init(_ lines: AsyncStream<String>) { iterator = lines.makeAsyncIterator() }

    func next() async -> String? { await iterator.next() }
}

/// What a step produced once it ended.
struct ClaudePipeStep: Sendable, Equatable {
    var calls: [ToolCallRequest]
    var stop: StopReason
    var usage: TokenUsage?
}

/// One CLI process and its stdout. An actor because the line iterator is read by one step after another, from different tasks.
actor ClaudePipeRun {
    nonisolated let process: LineProcess
    private nonisolated let mailbox: ClaudePipeMailbox?
    private nonisolated let cleanup: [URL]
    private nonisolated let firstLine: String
    private nonisolated let closed = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let reader: PipeLineReader
    /// Permission requests of tool calls the engine has not answered yet: tool_use_id → (request id, input).
    private var pending: [String: (requestID: String, input: JSONValue)] = [:]
    /// Tool calls whose results are delivered: their permission requests are answered at once.
    private var approved: Set<String> = []

    init(process: LineProcess, mailbox: ClaudePipeMailbox?, cleanup: [URL], firstLine: String) {
        self.process = process
        self.mailbox = mailbox
        self.cleanup = cleanup
        self.firstLine = firstLine
        reader = PipeLineReader(process.lines)
    }

    /// Ends the process (once) and removes its files. `interrupt`: ask the CLI to drop what it is doing first.
    nonisolated func stop(interrupt: Bool) {
        guard closed.withLock({ done in defer { done = true }; return !done }) else { return }
        if interrupt { process.send(ClaudeCodeWire.controlRequest(id: ClaudeCodeWire.newRequestID(), subtype: "interrupt")) }
        process.closeInput()
        process.terminate(after: 3)
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    /// Sends `initialize` and waits for its answer; a CLI that stays silent is killed after `timeout`.
    func initialize(timeout: Duration) async throws {
        let id = ClaudeCodeWire.newRequestID()
        process.send(ClaudeCodeWire.controlRequest(id: id, subtype: "initialize"))
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task { [process] in
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            process.terminate(after: 0)
        }
        defer { watchdog.cancel() }
        while let line = await reader.next() {
            guard let json = JSONValue.parse(line), json["type"]?.string == "control_response",
                  json["response"]?["request_id"]?.string == id else { continue }
            if json["response"]?["subtype"]?.string == "error" {
                throw LLMError.invalidResponse(json["response"]?["error"]?.string ?? "o Claude Code recusou a inicialização.")
            }
            return
        }
        try Task.checkCancellation()
        if timedOut.withLock({ $0 }) { throw LLMError.invalidResponse("o Claude Code não respondeu à inicialização a tempo.") }
        throw await Self.died(process, assistantError: nil)
    }

    /// The user message that starts the turn (after `initialize`).
    func sendFirstMessage() {
        process.send(firstLine)
    }

    /// Sends the messages the user wrote after the answer that ended the last turn (the process was idle).
    func sendUser(_ messages: [ChatMessage]) throws {
        for message in messages {
            process.send(try ClaudePipeSession.userLine(message.content, images: message.images))
        }
    }

    /// Hands the tool results to the MCP server (through the mailbox), lets the CLI run the calls, and sends the messages the
    /// user wrote meanwhile.
    func resume(results: [(id: String, result: ClaudePipeToolResult)], extras: [ChatMessage]) throws {
        guard let mailbox else { throw LLMError.invalidResponse("o Claude Code não tem ferramentas neste passo.") }
        for (id, result) in results { try mailbox.deliver(result, toolUseID: id) }
        for (id, _) in results {
            approved.insert(id)
            if let request = pending.removeValue(forKey: id) {
                process.send(ClaudeCodeWire.permissionResponse(requestID: request.requestID, answer: .allow, input: request.input))
            }
        }
        for message in extras {
            process.send(try ClaudePipeSession.userLine(message.content, images: message.images))
        }
    }

    /// Reads the CLI's output until the model's step ends: its tool calls (the process then waits for the results), or its answer
    /// (after the CLI's `result` line).
    func readStep(emit: @Sendable (LLMEvent) -> Void) async throws -> ClaudePipeStep {
        var state = ClaudePipeStepState()
        while let line = await reader.next() {
            guard let json = JSONValue.parse(line), let type = json["type"]?.string else { continue }
            if let parent = json["parent_tool_use_id"], parent != .null { continue } // a subagent's traffic
            switch type {
            case "stream_event", "assistant":
                for event in state.ingest(json) { emit(event) }
                if state.stop == "tool_use" { return state.step }
            case "control_request":
                answer(json)
            case "result":
                if json["is_error"]?.bool == true || json["api_error_status"]?.int != nil {
                    throw ClaudePipeErrors.error(forResult: json, assistantError: state.assistantError)
                }
                return state.step
            default:
                continue
            }
        }
        try Task.checkCancellation()
        // The CLI ended without a `result`: fine after a complete answer, a failure otherwise.
        if state.stop != nil { return state.step }
        throw await Self.died(process, assistantError: state.assistantError)
    }

    /// Answers the CLI's control requests: the Orb's tools are allowed once the engine has run them (never before), anything
    /// else is refused, so the CLI never waits on us for a request it makes.
    private func answer(_ json: JSONValue) {
        guard let requestID = json["request_id"]?.string, let request = json["request"] else { return }
        guard request["subtype"]?.string == "can_use_tool" else {
            process.send(ClaudeCodeWire.errorResponse(requestID: requestID, message: "Não suportado."))
            return
        }
        let input = request["input"] ?? .object([:])
        guard let name = request["tool_name"]?.string, name.hasPrefix(ClaudePipeSession.toolPrefix), let toolUseID = request["tool_use_id"]?.string else {
            process.send(ClaudeCodeWire.permissionResponse(requestID: requestID, answer: .deny("Ferramenta indisponível."), input: input))
            return
        }
        if approved.contains(toolUseID) {
            process.send(ClaudeCodeWire.permissionResponse(requestID: requestID, answer: .allow, input: input))
        } else {
            pending[toolUseID] = (requestID, input)
        }
    }

    /// The error for a process that ended before its answer.
    private static func died(_ process: LineProcess, assistantError: (code: String, text: String)?) async -> Error {
        if let assistantError { return ClaudePipeErrors.error(code: assistantError.code, text: assistantError.text, status: nil) }
        let detail = await process.finalErrorOutput()
        return LLMError.invalidResponse("o Claude Code encerrou antes de responder." + (detail.isEmpty ? "" : " " + detail))
    }
}

// MARK: - Reading one step

/// The model's response as the CLI streams it (`stream_event` lines carry Anthropic's SSE events, `assistant` lines the finished
/// blocks): text, tool calls and usage of one step.
struct ClaudePipeStepState {
    private(set) var stop: String?
    private var usage: TokenUsage?
    /// Usage of messages that ended before this one (the CLI goes on by itself after a cut-off reply).
    private var carried: TokenUsage?
    private var blocks: [Int: ToolCallRequest] = [:]
    private var finished: [ToolCallRequest] = []
    private var currentMessageID: String?
    private var streamedMessages: Set<String> = []
    /// What an `assistant` line says went wrong (`authentication_failed`, `rate_limit`…) and the notice it carries.
    private(set) var assistantError: (code: String, text: String)?

    var calls: [ToolCallRequest] {
        let streamed = blocks.sorted { $0.key < $1.key }.map(\.value).map(Self.normalized)
        let known = Set(streamed.map(\.id))
        return streamed + finished.filter { !known.contains($0.id) }.map(Self.normalized)
    }

    var totalUsage: TokenUsage? {
        guard var total = carried else { return usage }
        if let usage { total.add(usage) }
        return total
    }

    var step: ClaudePipeStep {
        let calls = calls
        return ClaudePipeStep(calls: calls, stop: AnthropicStreamAssembler.stopReason(stop, hasToolCalls: !calls.isEmpty), usage: totalUsage)
    }

    mutating func ingest(_ json: JSONValue) -> [LLMEvent] {
        switch json["type"]?.string {
        case "stream_event": event(json["event"])
        case "assistant": assistant(json)
        default: []
        }
    }

    private static func normalized(_ call: ToolCallRequest) -> ToolCallRequest {
        var call = call
        if call.name.hasPrefix(ClaudePipeSession.toolPrefix) { call.name.removeFirst(ClaudePipeSession.toolPrefix.count) }
        if call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { call.arguments = "{}" }
        return call
    }

    private mutating func event(_ event: JSONValue?) -> [LLMEvent] {
        guard let event else { return [] }
        let index = event["index"]?.int ?? 0
        switch event["type"]?.string {
        case "message_start":
            if stop != nil, stop != "tool_use" {
                // The CLI is going on after a reply that was cut off: this is the same answer, continued.
                if let usage { carried = carried.map { var sum = $0; sum.add(usage); return sum } ?? usage }
                usage = nil
                stop = nil
                blocks = [:]
            }
            currentMessageID = event["message"]?["id"]?.string
            if let id = currentMessageID { streamedMessages.insert(id) }
            return record(usage: event["message"]?["usage"])
        case "content_block_start":
            guard let block = event["content_block"], block["type"]?.string == "tool_use" else { return [] }
            blocks[index] = ToolCallRequest(id: block["id"]?.string ?? "call_\(index)", name: block["name"]?.string ?? "", arguments: "")
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.string {
            case "text_delta":
                if let text = delta?["text"]?.string, !text.isEmpty { return [.text(text)] }
            case "input_json_delta":
                blocks[index]?.arguments += delta?["partial_json"]?.string ?? ""
            default:
                break
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stop = reason }
            return record(usage: event["usage"])
        default:
            break
        }
        return []
    }

    private mutating func assistant(_ json: JSONValue) -> [LLMEvent] {
        let message = json["message"]
        let content = message?["content"]?.array ?? []
        if let code = json["error"]?.string {
            let text = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
            assistantError = (code, text)
            return []
        }
        var events: [LLMEvent] = []
        let wasStreamed = message?["id"]?.string.map(streamedMessages.contains) ?? false
        for block in content {
            switch block["type"]?.string {
            case "text":
                // Only when partial messages were not streamed for it (a CLI that ignores the flag).
                if !wasStreamed, let text = block["text"]?.string, !text.isEmpty { events.append(.text(text)) }
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string, !finished.contains(where: { $0.id == id }) else { continue }
                finished.append(ToolCallRequest(id: id, name: name, arguments: (block["input"] ?? .object([:])).jsonString))
            default:
                break
            }
        }
        if !wasStreamed, stop == nil, let reason = message?["stop_reason"]?.string { stop = reason }
        return events
    }

    /// `message_start` carries the input counts, `message_delta` the final output count.
    private mutating func record(usage reported: JSONValue?) -> [LLMEvent] {
        guard let reported, case .object = reported else { return [] }
        var total = usage ?? TokenUsage()
        total.absorb(messages: reported)
        usage = total
        guard let shown = totalUsage else { return [] }
        return [.usage(shown)]
    }
}

// MARK: - Errors

/// The CLI reports a failed call as an `assistant` line with an `error` code and a `result` line with `is_error` and, for HTTP
/// failures, `api_error_status`. These become the errors the engine's retry logic knows.
enum ClaudePipeErrors {
    static func error(forResult json: JSONValue, assistantError: (code: String, text: String)?) -> Error {
        let result = ClaudeCodeParser.result(json)
        let text = result.message.isEmpty ? assistantError?.text ?? "" : result.message
        return error(code: assistantError?.code, text: text, status: json["api_error_status"]?.int)
    }

    static func error(code: String?, text: String, status: Int?) -> Error {
        let message = providerMessage(text)
        if LLMError.isContextOverflow(message) || LLMError.isContextOverflow(text) { return LLMError.contextExceeded(message) }
        let known = status ?? statusInText(text) ?? code.flatMap { codes[$0] }
        if let known { return LLMError.http(status: known, message: message) }
        return LLMError.invalidResponse(message.isEmpty ? "o Claude Code devolveu um erro sem detalhes." : message)
    }

    private static let codes = ["authentication_failed": 401, "billing_error": 402, "invalid_request": 400, "rate_limit": 429, "server_error": 500]

    /// "API Error: 429 {"type":"error","error":{"message":"…"}}" → the provider's message.
    static func providerMessage(_ text: String) -> String {
        guard let brace = text.firstIndex(of: "{"), let json = JSONValue.parse(String(text[brace...])) else { return text }
        return json["error"]?["message"]?.string ?? json["message"]?.string ?? text
    }

    private static func statusInText(_ text: String) -> Int? {
        let prefix = "API Error: "
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count).prefix(3)
        return digits.count == 3 ? Int(digits) : nil
    }
}
