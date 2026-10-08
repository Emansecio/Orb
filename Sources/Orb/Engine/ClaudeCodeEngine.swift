import Foundation
import os

/// Everything one Claude Code turn needs, captured up front.
struct ClaudeCodeTurn: Sendable {
    var bot: Bot
    var executable: URL
    /// `--model` value; nil or "default" keeps Claude Code's own choice.
    var model: String?
    /// Appended to Claude Code's system prompt (persona, memory, skills).
    var system: String
    var prompt: String
    /// The user's pictures, recorded with the message so a later turn by another model still has them as pictures
    /// (Claude Code itself opens the files named in `prompt`).
    var images: [ImageAttachment] = []
    /// What happened in the conversation that this Claude Code session has not seen; sent before the prompt.
    var context = ""
    /// Claude Code session to resume; nil starts a new one.
    var sessionID: String?
    /// MCP servers for `--mcp-config`: the Orb's tools server (memory, and the Mac tools with "Controlar apps do Mac"), plus
    /// the enabled connectors when the bot may use them. With "Conectores" off, `--strict-mcp-config` keeps the
    /// user's own Claude Code MCP servers out.
    var connectors: [MCPServerConfig] = []
    var environment: [String: String] = [:]
    /// Grants for this turn only that the user's own request already gave (saving to memory when asked to remember).
    var turnGrants: [PermissionRule] = []
    /// The permission mode and rules as they are now, read at every permission request. nil keeps the ones in
    /// `bot` as they were when the turn started.
    var permissions: PermissionSource?
    /// Folder that gets `--add-dir` when the Orb works somewhere else, so reading across the user's files does not
    /// prompt for every folder (Claude Code only trusts the folder it starts in).
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    /// How long Claude Code has to answer `initialize` before the turn is given up. Generous: a cold first launch
    /// may be starting the Orb's tools server and the user's connectors (some remote) before it answers.
    var initializeTimeout: TimeInterval = 60

    func currentPermissions() async -> PermissionState {
        if let permissions { return await permissions() }
        return PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
    }

    /// Command line for this turn. Values use the `--flag=value` form so text starting with "-" is never read
    /// as a flag (as the SDK does for `--resume`).
    func arguments(newSessionID: String, mcpConfig: URL?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                         "--include-partial-messages", "--verbose",
                         // Permission prompts come to us as `can_use_tool` control requests (SDK: subprocess_cli.py).
                         "--permission-prompt-tool", "stdio",
                         "--permission-mode", ClaudeCodePolicy.cliMode(bot.permissionMode),
                         "--append-system-prompt=\(system)"]
        if let model, !model.isEmpty, model != ClaudeCodeModels.defaultID { arguments.append("--model=\(model)") }
        arguments.append(sessionID.map { "--resume=\($0)" } ?? "--session-id=\(newSessionID)")
        var removed: [String] = []
        if bot.workingURL.standardizedFileURL.path != homeDirectory.standardizedFileURL.path {
            arguments.append("--add-dir=\(homeDirectory.path)")
        }
        if !bot.capabilities.contains(.terminal) { removed += ClaudeCodeTools.terminal }
        if !bot.capabilities.contains(.browser) { removed += ClaudeCodeTools.web }
        if bot.permissionMode != .bypass { removed += ClaudeCodeTools.secretReads }
        if !removed.isEmpty { arguments.append("--disallowedTools=\(removed.joined(separator: ","))") }
        if !bot.capabilities.contains(.connectors) { arguments.append("--strict-mcp-config") }
        if let mcpConfig { arguments.append("--mcp-config=\(mcpConfig.path)") }
        return arguments
    }

    /// `{"mcpServers": {name: {type: stdio, command, args, env} | {type: http, url, headers}}}`; nil when empty.
    static func mcpConfig(_ servers: [MCPServerConfig]) -> JSONValue? {
        var entries: [String: JSONValue] = [:]
        for server in servers where server.isEnabled && (server.isRemote || !server.command.isEmpty) {
            let base = String(server.name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
            var name = base.isEmpty ? "conector" : base, suffix = 2
            while entries[name] != nil { name = "\(base)-\(suffix)"; suffix += 1 }
            entries[name] = server.isRemote
                ? .object(["type": .string("http"), "url": .string(server.url),
                           "headers": .object(server.headers.mapValues(JSONValue.string))])
                : .object(["type": .string("stdio"), "command": .string(server.command),
                           "args": .array(server.arguments.map(JSONValue.string)),
                           "env": .object(server.environment.mapValues(JSONValue.string))])
        }
        return entries.isEmpty ? nil : .object(["mcpServers": .object(entries)])
    }
}

/// Runs bot turns through the user's Claude Code: one `claude -p` process per turn, resuming the bot's
/// session. Same shape as `AgentEngine`; Claude Code's permission prompts become Orb approval cards.
actor ClaudeCodeEngine {
    /// Open approval cards; shared with the other engine by passing the same gate.
    let gate: ApprovalGate
    /// The running process of each Orb's turn, to tell it when the permission mode changes.
    private var running: [UUID: LineProcess] = [:]

    init(gate: ApprovalGate = ApprovalGate()) { self.gate = gate }

    nonisolated func run(_ turn: ClaudeCodeTurn) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(turn, out: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The Orb's permission mode changed during its turn: Claude Code decides some things itself (a session
    /// started in `bypassPermissions` never asks Orb), so it is told too. Orb's own check runs on every request
    /// either way; a CLI that refuses the switch is ignored.
    func modeChanged(for botID: UUID, to mode: PermissionMode) {
        running[botID]?.send(ClaudeCodeWire.setPermissionMode(id: ClaudeCodeWire.newRequestID(), mode: ClaudeCodePolicy.cliMode(mode)))
    }

    // MARK: Turn

    private func play(_ turn: ClaudeCodeTurn, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }
        out.yield(.message(.user(turn.prompt, images: turn.images)))
        out.yield(.status("Pensando"))
        // Connector secrets go in a private temporary file, not on the command line.
        let mcpFile = ClaudeCodeTurn.mcpConfig(turn.connectors).flatMap(Self.writePrivate)
        defer { mcpFile.map { try? FileManager.default.removeItem(at: $0) } }
        let process: LineProcess
        do {
            process = try LineProcess(executable: turn.executable,
                                      arguments: turn.arguments(newSessionID: UUID().uuidString.lowercased(), mcpConfig: mcpFile),
                                      directory: turn.bot.workingURL, environment: turn.environment)
        } catch {
            out.yield(.failed("Não consegui abrir o Claude Code: \(error.localizedDescription)"))
            return
        }
        running[turn.bot.id] = process
        defer { running[turn.bot.id] = nil }
        await withTaskCancellationHandler {
            await converse(turn, process: process, out: out)
        } onCancel: {
            // End the turn the way the SDK does: interrupt, end input, then stop the process if it lingers.
            process.send(ClaudeCodeWire.controlRequest(id: ClaudeCodeWire.newRequestID(), subtype: "interrupt"))
            process.closeInput()
            process.terminate(after: 3)
        }
    }

    private func converse(_ turn: ClaudeCodeTurn, process: LineProcess, out: AsyncStream<TurnEvent>.Continuation) async {
        let initializeID = ClaudeCodeWire.newRequestID()
        process.send(ClaudeCodeWire.controlRequest(id: initializeID, subtype: "initialize"))
        var parser = ClaudeCodeParser()
        var transcript = ClaudeCodeTranscript(isResuming: turn.sessionID != nil)
        var granted = turn.turnGrants
        // A CLI that never answers `initialize` (stuck on a prompt, a broken install) would hold the turn forever.
        let handshake = Handshake()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(turn.initializeTimeout))
            guard !Task.isCancelled, handshake.expire() else { return }
            process.closeInput()
            process.terminate(after: 0)
        }
        defer { watchdog.cancel() }

        for await line in process.lines {
            for message in parser.parse(line) {
                switch message {
                case .controlResponse(let id, let error) where id == initializeID:
                    guard handshake.answer() else { continue }
                    if let error {
                        out.yield(.failed("O Claude Code recusou iniciar a conversa: \(error)"))
                        process.closeInput()
                        process.terminate(after: 3)
                        return
                    }
                    process.send(ClaudeCodeWire.userMessage(turn.context.isEmpty ? turn.prompt : turn.context + "\n\n" + turn.prompt))
                case .permission(let request):
                    let answer = await permission(request, turn: turn, hasText: transcript.hasText, granted: &granted, out: out)
                    if case .deny = answer { transcript.noteDenied(request.toolUseID, mode: await turn.currentPermissions().mode) }
                    process.send(ClaudeCodeWire.permissionResponse(requestID: request.requestID, answer: answer, input: request.input))
                case .unsupportedRequest(let id, let subtype):
                    process.send(ClaudeCodeWire.errorResponse(requestID: id, message: "Unsupported control request: \(subtype)"))
                default:
                    for event in transcript.apply(message) { out.yield(event) }
                    if transcript.isFinished {
                        // One turn per process: let it exit on its own, but not linger.
                        process.closeInput()
                        process.terminate(after: 10)
                        return
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }
        switch handshake.state {
        case .expired:
            out.yield(.failed("O Claude Code não respondeu em \(Int(turn.initializeTimeout)) segundos e foi encerrado. "
                              + "Tente de novo; se continuar, confira o Claude Code em Ajustes → Modelos." + Self.details(process.errorOutput)))
        case .waiting:
            out.yield(.failed("O Claude Code fechou antes de começar a conversa." + Self.details(process.errorOutput)))
        case .answered:
            for event in transcript.endedEarly(details: process.errorOutput) { out.yield(event) }
        }
    }

    private static func details(_ errorOutput: String) -> String {
        let tail = ClaudeCodeTranscript.tail(errorOutput)
        return tail.isEmpty ? "" : "\n" + tail
    }

    /// Whether Claude Code has answered `initialize`; the watchdog and the message loop race to settle it.
    private final class Handshake: Sendable {
        enum State { case waiting, answered, expired }
        private let current = OSAllocatedUnfairLock(initialState: State.waiting)
        var state: State { current.withLock { $0 } }

        /// False when the time already ran out.
        func answer() -> Bool {
            current.withLock { state in
                if state == .waiting { state = .answered }
                return state == .answered
            }
        }

        /// True when this call is the one that gave up (the answer had not come).
        func expire() -> Bool {
            current.withLock { state in
                guard state == .waiting else { return false }
                state = .expired
                return true
            }
        }
    }

    /// Answers a `can_use_tool` request: by the Orb's mode and rules as they are now, or by asking the user.
    /// `granted` holds the grants of this turn ("Só nesta tarefa").
    private func permission(_ request: ClaudeCodePermissionRequest, turn: ClaudeCodeTurn, hasText: Bool,
                            granted: inout [PermissionRule], out: AsyncStream<TurnEvent>.Continuation) async -> ClaudeCodePermissionAnswer {
        let live = await turn.currentPermissions()
        let workspace = turn.bot.workingURL
        let call = PermissionPolicy.call(claudeCodeTool: request.toolName, input: request.input, workspace: workspace)
        let why: PermissionVerdict.AskReason
        switch PermissionPolicy.evaluate(mode: live.mode, call: call, rules: live.rules, turnGrants: granted, workspace: workspace) {
        case .allow: return .allow
        case .deny(let message): return .deny(message)
        case .ask(let reason): why = reason
        }
        guard !Task.isCancelled else { return .deny(ClaudeCodePolicy.userDenial) }
        let summary = ClaudeCodeTools.summary(request.toolName, request.input)
        let fallback = hasText ? "" : "\(turn.bot.name) precisa da sua permissão para continuar."
        let approval = ApprovalRequest(
            toolName: request.toolName, title: summary.title, command: summary.detail,
            reason: why.explanation ?? request.reason ?? fallback,
            suggestions: PermissionPolicy.suggestions(for: call, existing: live.rules + granted, workspace: workspace,
                                                      extra: request.suggestions),
            isDangerous: why.isDangerous)
        await gate.open(approval.id, botID: turn.bot.id, alwaysAsks: why != .needsPermission)
        out.yield(.approval(approval))
        out.yield(.status("Esperando sua resposta"))
        let answer = await gate.wait(for: approval.id)
        let rule = answer.rule ?? approval.suggestions.first
        switch answer.decision {
        case .deny, .review:
            // Switching to read-only answers open cards with a denial.
            return .deny(await turn.currentPermissions().mode == .readOnly ? ClaudeCodePolicy.readOnlyDenial
                         : ClaudeCodePolicy.userDenial(note: answer.note))
        case .task:
            if let rule { granted.append(rule) }
        case .always:
            // The app saves the rule in the Orb, which the next request reads; without a live source (nothing
            // saves it) it is kept for this turn.
            if turn.permissions == nil, let rule { granted.append(rule) }
        case .once:
            break
        }
        out.yield(.status("Pensando"))
        return .allow
    }

    /// Writes JSON readable only by the user, in a fresh temporary file.
    private static func writePrivate(_ json: JSONValue) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-mcp-\(UUID().uuidString).json")
        let created = FileManager.default.createFile(atPath: url.path, contents: Data(json.jsonString.utf8),
                                                     attributes: [.posixPermissions: 0o600])
        return created ? url : nil
    }
}

/// Turns Claude Code messages into transcript events and tracks how the turn is going.
struct ClaudeCodeTranscript {
    let isResuming: Bool
    private(set) var isFinished = false
    /// What the turn used and cost, from the CLI's result message (nil until it arrives, or if it reports none).
    /// The usage also goes out as a `.usage` event, like the native engine's.
    private(set) var usage: TokenUsage?
    private(set) var costUSD: Double?
    private var didStart = false
    private var segments: [String] = []
    private var isWriting = false
    /// Claude Code tool-use id → transcript tool id, for calls still running.
    private var running: [String: UUID] = [:]
    private var denials: [String: String] = [:]
    private var apiError: String?
    /// Short notes of what Claude Code did this turn, kept in the history so other models know.
    private var actions: [String] = []

    init(isResuming: Bool) { self.isResuming = isResuming }

    var hasText: Bool { segments.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    mutating func apply(_ message: ClaudeCodeMessage) -> [TurnEvent] {
        switch message {
        case .started(let id):
            didStart = true
            return [.session(id)]
        case .text(let delta):
            var events: [TurnEvent] = []
            if !isWriting {
                isWriting = true
                segments.append("")
                events.append(.status("Escrevendo"))
            }
            segments[segments.count - 1] += delta
            return events + [.text(delta)]
        case .toolUse(let id, let name, let input):
            isWriting = false
            let summary = ClaudeCodeTools.summary(name, input)
            let call = ToolCall(kind: ClaudeCodeTools.kind(name), title: summary.title, detail: summary.detail)
            running[id] = call.id
            if actions.count < 20 { actions.append("\(summary.title): \(summary.detail.prefix(120))") }
            return [.toolStarted(call), .status(summary.title)]
        case .toolResult(let id, let output, let isError):
            guard let callID = running.removeValue(forKey: id) else { return [] }
            let shown = denials[id] ?? (output.count > 4000 ? output.prefix(4000) + "\n…" : output)
            return [.toolFinished(id: callID, state: isError ? .failed : .done, output: shown), .status("Pensando")]
        case .apiError(let code):
            apiError = code
            return []
        case .result(let result):
            isFinished = true
            usage = result.usage
            costUSD = result.costUSD
            var events = closeRunningTools()
            if let used = result.usage { events.insert(.usage(used), at: 0) }
            if !result.isError {
                let reply = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var content = reply.joined(separator: "\n\n")
                if !actions.isEmpty {
                    content += (content.isEmpty ? "" : "\n\n") + "(Actions taken in this turn: " + actions.joined(separator: "; ") + ")"
                }
                if !content.isEmpty { events.append(.message(ChatMessage(role: .assistant, content: content))) }
            } else if isResuming && !didStart {
                // The saved session is gone (e.g. deleted in Claude Code): forget it so the next message starts fresh.
                events += [.session(""), .failed("A conversa anterior não existe mais no Claude Code. Mande de novo para começar uma nova.")]
            } else if apiError == "authentication_failed" {
                events.append(.failed("O Claude Code não está conectado à sua conta. Entre em Ajustes → Modelos → Claude Code."))
            } else {
                events.append(.failed(result.message))
            }
            return events
        case .compacted(let trigger, let before, let after):
            return [.compacted(CompactionReport(kind: .claudeCode, foldedMessages: 0, tokensBefore: before, tokensAfter: after,
                                                trigger: trigger))]
        case .permission, .unsupportedRequest, .controlResponse:
            return []
        }
    }

    /// Shows a denial in Portuguese on the tool's row instead of Claude Code's English message.
    mutating func noteDenied(_ toolUseID: String?, mode: PermissionMode) {
        guard let toolUseID else { return }
        denials[toolUseID] = mode == .readOnly ? "Bloqueado: o Orb está em modo Só leitura." : "Você negou esta ação."
    }

    /// The last 600 characters of the CLI's stderr, enough to show why it stopped.
    static func tail(_ errorOutput: String) -> String {
        errorOutput.count > 600 ? "…" + errorOutput.suffix(600) : errorOutput
    }

    /// The CLI closed its output without a result (crash, bad flag, killed).
    mutating func endedEarly(details: String) -> [TurnEvent] {
        isFinished = true
        let tail = Self.tail(details)
        return closeRunningTools() + [.failed("O Claude Code parou sem terminar a resposta." + (tail.isEmpty ? "" : "\n\(tail)"))]
    }

    private mutating func closeRunningTools() -> [TurnEvent] {
        defer { running = [:] }
        return running.values.map { .toolFinished(id: $0, state: .failed, output: "Interrompido.") }
    }
}
