import Foundation

/// Everything one Claude Code turn needs, captured up front.
struct ClaudeCodeTurn: Sendable {
    var bot: Bot
    var executable: URL
    /// `--model` value; nil or "default" keeps Claude Code's own choice.
    var model: String?
    /// Appended to Claude Code's system prompt (persona, memory, skills).
    var system: String
    var prompt: String
    /// Claude Code session to resume; nil starts a new one.
    var sessionID: String?
    /// Enabled connectors, passed with `--mcp-config` when the bot may use them.
    var connectors: [MCPServerConfig] = []
    var environment: [String: String] = [:]

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
        if !bot.capabilities.contains(.terminal) { removed += ClaudeCodeTools.terminal }
        if !bot.capabilities.contains(.browser) { removed += ClaudeCodeTools.web }
        if !bot.capabilities.contains(.connectors) { removed.append("mcp__*") }
        if !removed.isEmpty { arguments.append("--disallowedTools=\(removed.joined(separator: ","))") }
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
/// session. Same shape as `AgentEngine`; Claude Code's permission prompts become OpenBot approval cards.
actor ClaudeCodeEngine {
    private var pending: [UUID: (botID: UUID, continuation: CheckedContinuation<ApprovalDecision, Never>)] = [:]

    nonisolated func run(_ turn: ClaudeCodeTurn) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(turn, out: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resolve(approvalID: UUID, decision: ApprovalDecision) {
        pending.removeValue(forKey: approvalID)?.continuation.resume(returning: decision)
    }

    /// Denies the bot's open approvals (used when the user stops its turn).
    func cancelApprovals(for botID: UUID) {
        for (id, entry) in pending where entry.botID == botID {
            pending[id] = nil
            entry.continuation.resume(returning: .deny)
        }
    }

    // MARK: Turn

    private func play(_ turn: ClaudeCodeTurn, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }
        out.yield(.message(.user(turn.prompt)))
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
        var allowed = turn.bot.allowedTools

        for await line in process.lines {
            for message in parser.parse(line) {
                switch message {
                case .controlResponse(let id, _) where id == initializeID:
                    process.send(ClaudeCodeWire.userMessage(turn.prompt))
                case .permission(let request):
                    let answer = await permission(request, turn: turn, hasText: transcript.hasText, allowed: &allowed, out: out)
                    if case .deny = answer { transcript.noteDenied(request.toolUseID, mode: turn.bot.permissionMode) }
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
        for event in transcript.endedEarly(details: process.errorOutput) { out.yield(event) }
    }

    /// Answers a `can_use_tool` request: by the bot's mode and "Sempre permitir" list, or by asking the user.
    private func permission(_ request: ClaudeCodePermissionRequest, turn: ClaudeCodeTurn, hasText: Bool,
                            allowed: inout Set<String>, out: AsyncStream<TurnEvent>.Continuation) async -> ClaudeCodePermissionAnswer {
        if let answer = ClaudeCodePolicy.answer(mode: turn.bot.permissionMode, toolName: request.toolName, allowed: allowed) {
            return answer
        }
        guard !Task.isCancelled else { return .deny(ClaudeCodePolicy.userDenial) }
        let summary = ClaudeCodeTools.summary(request.toolName, request.input)
        let fallback = hasText ? "" : "\(turn.bot.name) precisa da sua permissão para continuar."
        let approval = ApprovalRequest(toolName: request.toolName, title: summary.title, command: summary.detail,
                                       reason: request.reason ?? fallback)
        out.yield(.approval(approval))
        out.yield(.status("Esperando sua resposta"))
        let decision = await withCheckedContinuation { pending[approval.id] = (turn.bot.id, $0) }
        switch decision {
        case .deny: return .deny(ClaudeCodePolicy.userDenial)
        case .always: allowed.insert(request.toolName)
        case .once: break
        }
        out.yield(.status("Pensando"))
        return .allow
    }

    /// Writes JSON readable only by the user, in a fresh temporary file.
    private static func writePrivate(_ json: JSONValue) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openbot-mcp-\(UUID().uuidString).json")
        let created = FileManager.default.createFile(atPath: url.path, contents: Data(json.jsonString.utf8),
                                                     attributes: [.posixPermissions: 0o600])
        return created ? url : nil
    }
}

/// Turns Claude Code messages into transcript events and tracks how the turn is going.
struct ClaudeCodeTranscript {
    let isResuming: Bool
    private(set) var isFinished = false
    private var didStart = false
    private var segments: [String] = []
    private var isWriting = false
    /// Claude Code tool-use id → transcript tool id, for calls still running.
    private var running: [String: UUID] = [:]
    private var denials: [String: String] = [:]
    private var apiError: String?

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
            var events = closeRunningTools()
            if !result.isError {
                let reply = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !reply.isEmpty { events.append(.message(ChatMessage(role: .assistant, content: reply.joined(separator: "\n\n")))) }
            } else if isResuming && !didStart {
                // The saved session is gone (e.g. deleted in Claude Code): forget it so the next message starts fresh.
                events += [.session(""), .failed("A conversa anterior não existe mais no Claude Code. Mande de novo para começar uma nova.")]
            } else if apiError == "authentication_failed" {
                events.append(.failed("O Claude Code não está conectado à sua conta. Entre em Ajustes → Modelos → Claude Code."))
            } else {
                events.append(.failed(result.message))
            }
            return events
        case .permission, .unsupportedRequest, .controlResponse:
            return []
        }
    }

    /// Shows a denial in Portuguese on the tool's row instead of Claude Code's English message.
    mutating func noteDenied(_ toolUseID: String?, mode: PermissionMode) {
        guard let toolUseID else { return }
        denials[toolUseID] = mode == .readOnly ? "Bloqueado: o bot está em modo Só leitura." : "Você negou esta ação."
    }

    /// The CLI closed its output without a result (crash, bad flag, killed).
    mutating func endedEarly(details: String) -> [TurnEvent] {
        isFinished = true
        let tail = details.count > 600 ? "…" + details.suffix(600) : details
        return closeRunningTools() + [.failed("O Claude Code parou sem terminar a resposta." + (tail.isEmpty ? "" : "\n\(tail)"))]
    }

    private mutating func closeRunningTools() -> [TurnEvent] {
        defer { running = [:] }
        return running.values.map { .toolFinished(id: $0, state: .failed, output: "Interrompido.") }
    }
}

// MARK: - System prompt

/// Text appended to Claude Code's own system prompt. No clock or other per-turn values: Claude Code records the
/// prompt on a session's first request and reuses it when resuming.
enum ClaudeCodePrompt {
    static func make(bot: Bot, skills: [Skill]) -> String {
        var lines = [
            "In this conversation you are \(bot.name), \(bot.role.isEmpty ? "a personal assistant" : bot.role), "
                + "talking to the user through the OpenBot app on their Mac.",
            "Reply in the user's language (Brazilian Portuguese unless they write otherwise). Be brief and concrete.",
            "Before a tool that changes something, say in one short sentence what you are about to do and why.",
        ]
        if !bot.memory.isEmpty {
            lines.append("\nWhat you remember about the user:")
            lines += bot.memory.map { "- \($0.text)" }
        }
        if !skills.isEmpty {
            lines.append("\nOpenBot skills the user can invoke with /name (the app expands them): "
                         + skills.map { "/\($0.slug)" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
