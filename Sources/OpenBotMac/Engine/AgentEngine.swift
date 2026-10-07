import Foundation

/// What a running turn reports to the UI.
enum TurnEvent: Sendable {
    case status(String)
    case text(String)
    case toolStarted(ToolCall)
    case toolFinished(id: UUID, state: ToolCall.State, output: String?)
    case approval(ApprovalRequest)
    /// A message to append to the model history (user, assistant or tool result).
    case message(ChatMessage)
    case failed(String)
}

/// Everything one turn needs, captured up front so the turn never reads UI state.
struct TurnRequest: Sendable {
    var bot: Bot
    var model: String
    var system: String
    var history: [ChatMessage]
    var prompt: String
    var client: any LLMClient
    var tools: [any AgentTool]
    var context: ToolContext
}

/// Runs bot turns: the model ↔ tools loop, gated by the bot's permission mode.
actor AgentEngine {
    /// Upper bound on model calls per turn, so a confused model cannot loop forever.
    static let maxSteps = 30

    private var pending: [UUID: (botID: UUID, continuation: CheckedContinuation<ApprovalDecision, Never>)] = [:]

    nonisolated func run(_ request: TurnRequest) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(request, out: continuation) }
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

    // MARK: Loop

    private func play(_ request: TurnRequest, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }
        let user = ChatMessage.user(request.prompt)
        var messages = [ChatMessage.system(request.system)] + request.history + [user]
        out.yield(.message(user))
        let specs = request.tools.map(\.spec)
        var allowed = request.bot.allowedTools

        do {
            for _ in 0..<Self.maxSteps {
                out.yield(.status("Pensando"))
                var text = ""
                var calls: [ToolCallRequest] = []
                for try await event in request.client.stream(model: request.model, messages: messages, tools: specs) {
                    switch event {
                    case .text(let delta):
                        if text.isEmpty { out.yield(.status("Escrevendo")) }
                        text += delta
                        out.yield(.text(delta))
                    case .toolCalls(let requested):
                        calls = requested
                    }
                }
                try Task.checkCancellation()
                let reply = ChatMessage(role: .assistant, content: text, toolCalls: calls)
                messages.append(reply)
                out.yield(.message(reply))
                if calls.isEmpty { return }

                for call in calls {
                    let output = await execute(call, request: request, reason: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                               allowed: &allowed, out: out)
                    try Task.checkCancellation()
                    let result = ChatMessage.tool(call.id, output)
                    messages.append(result)
                    out.yield(.message(result))
                }
            }
            out.yield(.failed("Parei depois de \(Self.maxSteps) passos para não entrar em loop."))
        } catch is CancellationError {
            // The user stopped the turn; the UI already says so.
        } catch {
            if !Task.isCancelled { out.yield(.failed(error.localizedDescription)) }
        }
    }

    /// Runs one tool call (asking first when needed) and returns the text the model receives.
    private func execute(_ call: ToolCallRequest, request: TurnRequest, reason: String, allowed: inout Set<String>,
                         out: AsyncStream<TurnEvent>.Continuation) async -> String {
        guard let tool = request.tools.first(where: { $0.spec.name == call.name }) else {
            return "Error: unknown tool \(call.name)."
        }
        guard let arguments = JSONValue.parse(call.arguments) else {
            return "Error: the arguments are not valid JSON."
        }
        let summary = tool.summary(arguments)

        if tool.risk(arguments) == .sensitive {
            switch request.bot.permissionMode {
            case .auto:
                break
            case .readOnly:
                // Read-only wins over any earlier "Sempre permitir".
                out.yield(.toolStarted(ToolCall(kind: tool.kind, title: summary.title, detail: summary.detail,
                                                state: .failed, output: "Bloqueado: o bot está em modo Só leitura.",
                                                finishedAt: .now)))
                return "Not run: the user set this bot to read-only mode. Explain what you would do instead."
            case .ask where !allowed.contains(call.name):
                // The model's own explanation is already on screen right above the card.
                let approval = ApprovalRequest(toolName: call.name, title: summary.title, command: summary.detail,
                                               reason: reason.isEmpty ? "\(request.bot.name) precisa da sua permissão para continuar." : "")
                out.yield(.approval(approval))
                out.yield(.status("Esperando sua resposta"))
                let decision = await withCheckedContinuation { pending[approval.id] = (request.bot.id, $0) }
                switch decision {
                case .deny: return "Not run: the user denied this action. Do not retry it; ask or suggest an alternative."
                case .always: allowed.insert(call.name)
                case .once: break
                }
            case .ask:
                break
            }
        }

        let started = ToolCall(kind: tool.kind, title: summary.title, detail: summary.detail)
        out.yield(.toolStarted(started))
        out.yield(.status(summary.title))
        do {
            let output = try await tool.run(arguments, context: request.context)
            out.yield(.toolFinished(id: started.id, state: .done, output: Self.preview(output)))
            return output
        } catch {
            let message = error.localizedDescription
            out.yield(.toolFinished(id: started.id, state: .failed, output: message))
            return "Error: \(message)"
        }
    }

    /// Tool output shown in the transcript (the model always gets the full text).
    private static func preview(_ output: String) -> String {
        output.count > 4000 ? output.prefix(4000) + "\n…" : output
    }
}

// MARK: - System prompt

enum SystemPrompt {
    static func make(bot: Bot, skills: [Skill], now: Date = .now) -> String {
        var lines = [
            "You are \(bot.name), \(bot.role.isEmpty ? "a personal assistant" : bot.role).",
            "You run natively on the user's Mac inside the OpenBot app and can act through your tools.",
            "Now: \(now.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier)).",
            "Home folder: \(FileManager.default.homeDirectoryForCurrentUser.path). Working directory: \(bot.workingURL.path).",
            "Reply in the user's language (Brazilian Portuguese unless they write otherwise). Be brief and concrete.",
            "Use tools to find out and to act instead of asking the user to do it. Read before you change things.",
            "Before a tool that changes something, say in one short sentence what you are about to do and why.",
            "When the user tells you a lasting preference or fact about themselves, save it with the remember tool.",
        ]
        if !bot.memory.isEmpty {
            lines.append("\nWhat you remember about the user:")
            lines += bot.memory.map { "- \($0.text)" }
        }
        if !skills.isEmpty {
            lines.append("\nThe user can invoke skills with /name: " + skills.map { "/\($0.slug)" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Expands "/slug rest" into the skill's instructions plus the request; nil if no skill matches.
    static func expandSkill(in prompt: String, skills: [Skill]) -> (skill: Skill, prompt: String)? {
        guard prompt.hasPrefix("/") else { return nil }
        let parts = prompt.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let slug = parts.first, let skill = skills.first(where: { $0.slug == slug }) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (skill, "Skill \"\(skill.name)\":\n\(skill.instructions)\n\nUser request: \(rest.isEmpty ? "(none)" : rest)")
    }
}
