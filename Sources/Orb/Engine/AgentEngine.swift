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
    /// Something the user should know, shown in the transcript (not sent to the model).
    case notice(String)
    /// The Claude Code session this conversation continues in ("" = forget it and start a new one next time).
    case session(String)
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
    /// How much history the model's window takes (the system prompt and tool specs come on top).
    var budget = ContextBudget.fallback
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
        var budget = request.budget
        // History that already starts with a summary was announced when it was compacted (`AppModel.send`).
        var announcedCompaction = ContextSummary.leading(in: request.history) != nil
        let toolNames = Set(request.tools.map(\.spec.name))

        do {
            for _ in 0..<Self.maxSteps {
                out.yield(.status("Pensando"))
                var text = ""
                var calls: [ToolCallRequest] = []
                var reasoning: ReasoningTrace?
                var retried = false
                while true {
                    do {
                        let window = Self.fitted(messages, to: budget)
                        if !announcedCompaction, window.contains(where: { $0.role == .user && $0.content.hasPrefix(ContextSummary.marker) }) {
                            announcedCompaction = true
                            out.yield(.notice("Conversa compactada: o começo virou um resumo."))
                        }
                        for try await event in request.client.stream(model: request.model, messages: window, tools: specs) {
                            switch event {
                            case .text(let delta):
                                if text.isEmpty { out.yield(.status("Escrevendo")) }
                                text += delta
                                out.yield(.text(delta))
                            case .reasoning(let trace):
                                reasoning = trace
                            case .toolCalls(let requested):
                                calls = requested
                            case .finished:
                                break
                            }
                        }
                        break
                    } catch let error where !retried && text.isEmpty && calls.isEmpty && ContextOverflow.matches(error) {
                        // The window was smaller than estimated: try once more with half the history.
                        retried = true
                        budget = budget.scaled(by: 0.5)
                    }
                }
                try Task.checkCancellation()
                let reply = ChatMessage(role: .assistant, content: text, toolCalls: calls, reasoning: reasoning)
                messages.append(reply)
                out.yield(.message(reply))
                if calls.isEmpty { return }

                for call in calls {
                    let output = await execute(call, request: request, reason: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                               allowed: &allowed, out: out)
                    try Task.checkCancellation()
                    let result = ChatMessage.tool(call.id, ToolOutputCap.apply(output, botID: request.bot.id, callID: call.id,
                                                                                 toolNames: toolNames))
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

    /// What the model is sent: the system prompt and the turn so far, fitted to the budget. `messages` itself stays
    /// whole, so trimming is recomputed from the full record before every call.
    private static func fitted(_ messages: [ChatMessage], to budget: ContextBudget) -> [ChatMessage] {
        guard let system = messages.first, system.role == .system else { return messages }
        return [system] + ContextWindow.fit(Array(messages.dropFirst()), budget: budget).messages
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
        let summary = tool.summary(arguments, context: request.context)

        // A tool's own `danger` comes first; otherwise shell text it would run (commands, or AppleScript's
        // `do shell script`) is checked for destructive patterns.
        let danger = tool.danger(arguments)
            ?? (arguments["command"]?.string ?? arguments["script"]?.string).flatMap(DangerousCommand.reason)
        let risk = tool.risk(arguments)
        if risk != .safe {
            switch request.bot.permissionMode {
            case .bypass:
                break
            case .auto where danger == nil && risk == .sensitive,
                 .ask where danger == nil && risk == .sensitive && allowed.contains(call.name):
                break
            case .readOnly:
                // Read-only wins over any earlier "Sempre permitir".
                out.yield(.toolStarted(ToolCall(kind: tool.kind, title: summary.title, detail: summary.detail,
                                                state: .failed, output: "Bloqueado: o Orb está em modo Só leitura.",
                                                finishedAt: .now)))
                return "Not run: the user set you to read-only mode. Explain what you would do instead."
            case .ask, .auto:
                // The model's own explanation is already on screen right above the card.
                let why = danger.map { "Comando arriscado: \($0)." }
                    ?? (reason.isEmpty ? "\(request.bot.name) precisa da sua permissão para continuar." : "")
                let approval = ApprovalRequest(toolName: call.name, title: summary.title, command: summary.detail, reason: why)
                out.yield(.approval(approval))
                out.yield(.status("Esperando sua resposta"))
                let decision = await withCheckedContinuation { pending[approval.id] = (request.bot.id, $0) }
                switch decision {
                case .deny: return "Not run: the user denied this action. Do not retry it; ask or suggest an alternative."
                case .always: allowed.insert(call.name)
                case .once: break
                }
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
