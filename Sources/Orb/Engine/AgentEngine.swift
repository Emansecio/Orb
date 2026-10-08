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
    /// Tokens the turn has used so far, summed over its model calls (the last one is the turn's total).
    case usage(TokenUsage)
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
    /// Upper bound on model calls in this turn, so a confused model cannot loop forever.
    var maxSteps = AgentEngine.defaultMaxSteps
    /// Grants for this turn only that the user's own request already gave (saving to memory when asked to remember).
    var turnGrants: [PermissionRule] = []
    /// The permission mode and rules as they are now, read at every tool call. nil keeps the ones in `bot` as
    /// they were when the turn started.
    var permissions: PermissionSource?

    func currentPermissions() async -> PermissionState {
        if let permissions { return await permissions() }
        return PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
    }
}

/// What a tool call gives back to the model.
struct ToolOutcome: Sendable {
    var text: String
    /// The call failed (an error, an unknown tool, a refusal): the model is told so.
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Runs bot turns: the model ↔ tools loop, gated by the bot's permission mode.
actor AgentEngine {
    /// Model calls per turn for a conversation, and for a routine (nobody is there to say "continua").
    static let defaultMaxSteps = 30
    static let routineMaxSteps = 60

    /// Waits between retries of a transient provider failure (tests skip the wait).
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void

    /// Open approval cards; shared with the other engine by passing the same gate.
    let gate: ApprovalGate

    init(gate: ApprovalGate = ApprovalGate(),
         retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.gate = gate
        self.retrySleep = retrySleep
    }

    nonisolated func run(_ request: TurnRequest) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(request, out: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Loop

    private func play(_ request: TurnRequest, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }
        let user = ChatMessage.user(request.prompt)
        var messages = [ChatMessage.system(request.system)] + request.history + [user]
        out.yield(.message(user))
        let specs = request.tools.map(\.spec)
        var allowed = request.turnGrants
        var budget = request.budget
        // History that already starts with a summary was announced when it was compacted (`AppModel.send`).
        var announcedCompaction = ContextSummary.leading(in: request.history) != nil
        let toolNames = Set(request.tools.map(\.spec.name))
        let maxSteps = max(2, request.maxSteps)
        var usage: TokenUsage?
        var continuedAfterCut = false

        do {
            for step in 1...maxSteps {
                // The last step answers in text (the tools stay listed, so the provider's cache still applies).
                let isLastStep = step == maxSteps
                out.yield(.status("Pensando"))
                var reply = Reply()
                var contextRetried = false
                while true {
                    do {
                        let window = Self.fitted(messages, to: budget)
                        if !announcedCompaction, window.contains(where: { $0.role == .user && $0.content.hasPrefix(ContextSummary.marker) }) {
                            announcedCompaction = true
                            out.yield(.notice("Conversa compactada: o começo virou um resumo."))
                        }
                        reply = try await respond(to: window, request: request, specs: specs,
                                                  toolChoice: isLastStep ? .none : .auto, out: out)
                        break
                    } catch let error where !contextRetried && ContextOverflow.matches(error) {
                        // The window was smaller than estimated: try once more with half the history.
                        contextRetried = true
                        budget = budget.scaled(by: 0.5)
                    } catch let interrupted as StreamInterrupted {
                        // What the user already read is part of the conversation, so the next turn must know it.
                        record(ChatMessage(role: .assistant, content: interrupted.partialText + Self.interruptedMarker),
                               in: &messages, out: out)
                        out.yield(.failed(interrupted.underlying.localizedDescription))
                        return
                    }
                }
                try Task.checkCancellation()
                if let reported = reply.usage {
                    var total = usage ?? TokenUsage()
                    total.add(reported)
                    usage = total
                    out.yield(.usage(total))
                }

                let said = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // On the last step the model was told not to call tools; if it did anyway, the calls are not run.
                let calls = isLastStep ? [] : reply.calls
                let assistant = ChatMessage(role: .assistant, content: reply.text, toolCalls: calls, reasoning: reply.reasoning)
                // Append-only, so the earlier part of the conversation still hits the provider's cache.
                let note = maxSteps - step == Self.warningSteps ? Self.stepWarning(remaining: Self.warningSteps) : nil

                switch reply.stop {
                case .refusal:
                    if !said.isEmpty { record(ChatMessage(role: .assistant, content: reply.text), in: &messages, out: out) }
                    out.yield(.failed("O modelo recusou continuar com este pedido."))
                    return
                case .incomplete:
                    if !said.isEmpty { record(ChatMessage(role: .assistant, content: reply.text + Self.interruptedMarker), in: &messages, out: out) }
                    out.yield(.failed("A resposta foi interrompida: o provedor encerrou antes do fim."))
                    return
                case .contextExceeded:
                    if !said.isEmpty { record(ChatMessage(role: .assistant, content: reply.text + Self.interruptedMarker), in: &messages, out: out) }
                    out.yield(.failed("A conversa ficou grande demais para este modelo. Comece uma conversa nova ou apague o que não precisa."))
                    return
                case .maxTokens where !calls.isEmpty:
                    // The arguments were cut off mid-way: running them would act on half a command or file.
                    record(assistant, in: &messages, out: out)
                    for call in calls {
                        let text = call == calls.last && note != nil ? Self.cutOffResult + "\n\n" + (note ?? "") : Self.cutOffResult
                        record(.tool(call.id, text, isError: true), in: &messages, out: out)
                    }
                    continue
                case .maxTokens:
                    // A reply with no text (all the budget went to reasoning) is no message: providers reject empty ones.
                    if !said.isEmpty { record(assistant, in: &messages, out: out) }
                    if !continuedAfterCut && !isLastStep {
                        continuedAfterCut = true
                        // Not recorded: it only steers this turn and is no message of the user's.
                        messages.append(.user(Self.continueNudge))
                        continue
                    }
                    out.yield(.notice("A resposta passou do limite do modelo e foi cortada. Diga “continua” para seguir."))
                    return
                case .done, .toolUse, .unknown:
                    break
                }

                if calls.isEmpty && said.isEmpty {
                    // On the last step the model may have only tried to call tools: that is the limit, not silence.
                    out.yield(isLastStep && !reply.calls.isEmpty ? .notice(Self.pausedNotice(after: maxSteps))
                              : .failed("O modelo não respondeu."))
                    return
                }
                record(assistant, in: &messages, out: out)
                if calls.isEmpty {
                    if isLastStep { out.yield(.notice(Self.pausedNotice(after: maxSteps))) }
                    return
                }

                await runCalls(calls, request: request, reason: said, allowed: &allowed, toolNames: toolNames, note: note,
                               messages: &messages, out: out)
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            // The user stopped the turn; the UI already says so.
        } catch {
            if !Task.isCancelled { out.yield(.failed(error.localizedDescription)) }
        }
    }

    /// Adds a message to the model history and tells the UI.
    private func record(_ message: ChatMessage, in messages: inout [ChatMessage], out: AsyncStream<TurnEvent>.Continuation) {
        messages.append(message)
        out.yield(.message(message))
    }

    // MARK: Model call

    /// One model response, as far as it got.
    private struct Reply {
        var text = ""
        var calls: [ToolCallRequest] = []
        var reasoning: ReasoningTrace?
        var stop: StopReason = .done
        var usage: TokenUsage?
        /// Something the user (or a tool) has already seen of this response.
        var emitted: Bool { !text.isEmpty || !calls.isEmpty }
    }

    /// A failure after part of the response was shown. Not retryable (a second attempt would repeat the text).
    private struct StreamInterrupted: Error {
        var underlying: Error
        var partialText: String
    }

    /// Streams one response, retrying transient provider failures while nothing has been shown yet.
    private func respond(to window: [ChatMessage], request: TurnRequest, specs: [ToolSpec], toolChoice: ToolChoice,
                         out: AsyncStream<TurnEvent>.Continuation) async throws -> Reply {
        var reply = Reply()
        try await withRetries(sleep: retrySleep, onWait: { seconds, _ in
            out.yield(.status("Provedor ocupado, tentando de novo em \(Int(seconds.rounded(.up))) s"))
        }, operation: {
            reply = Reply() // an attempt that failed before showing anything leaves nothing behind
            out.yield(.status("Pensando"))
            do {
                for try await event in request.client.stream(model: request.model, messages: window, tools: specs, toolChoice: toolChoice) {
                    switch event {
                    case .text(let delta):
                        if reply.text.isEmpty { out.yield(.status("Escrevendo")) }
                        reply.text += delta
                        out.yield(.text(delta))
                    case .reasoning(let trace):
                        reply.reasoning = trace
                    case .toolCalls(let requested):
                        reply.calls = requested
                    case .finished(let reason, let used):
                        reply.stop = reason
                        reply.usage = used
                    }
                }
                if case .contextExceeded = reply.stop, !reply.emitted { throw LLMError.contextExceeded("model_context_window_exceeded") }
            } catch where reply.emitted && !(error is CancellationError) {
                throw StreamInterrupted(underlying: error, partialText: reply.text)
            } catch where ContextOverflow.matches(error) {
                // Not transient: skip the retries and let `play` try again with less history.
                if case LLMError.contextExceeded = error { throw error }
                throw LLMError.contextExceeded(error.localizedDescription)
            }
        })
        return reply
    }

    static let interruptedMarker = "\n\n[resposta interrompida]"
    static let continueNudge = "continue"
    static let cutOffResult = "Error: your reply hit the output limit while writing this call, so it was NOT run. Split the work into "
        + "smaller steps: write long files in parts (write_file with append: true), change existing files with edit_file, "
        + "and keep each call short."
    /// Steps left when the model is told how many it has.
    static let warningSteps = 3

    static func stepWarning(remaining: Int) -> String {
        "[Orb: restam \(remaining) chamadas de ferramenta neste turno; priorize e termine com um resumo do que fez e do que falta]"
    }

    static func pausedNotice(after steps: Int) -> String {
        "Pausei depois de \(steps) passos neste turno. Diga “continua” e eu sigo de onde parei."
    }

    // MARK: Tool calls

    /// Runs one step's tool calls and records their results in the order of the calls, each as soon as it and the
    /// ones before it are done. Consecutive calls that only look (risk `.safe`, so nothing to ask) run at the same
    /// time; everything else runs alone, in order. `note` goes at the end of the last result.
    private func runCalls(_ calls: [ToolCallRequest], request: TurnRequest, reason: String, allowed: inout [PermissionRule],
                          toolNames: Set<String>, note: String?, messages: inout [ChatMessage],
                          out: AsyncStream<TurnEvent>.Continuation) async {
        func append(_ outcome: ToolOutcome, for call: ToolCallRequest) {
            var text = ToolOutputCap.apply(outcome.text, botID: request.bot.id, callID: call.id, toolNames: toolNames)
            if let note, call == calls.last { text += "\n\n" + note }
            let message = ChatMessage.tool(call.id, text, isError: outcome.isError)
            messages.append(message)
            out.yield(.message(message))
        }

        var index = 0
        while index < calls.count, !Task.isCancelled {
            var end = index
            while end < calls.count, Self.runsWithoutAsking(calls[end], request: request) { end += 1 }
            guard end - index > 1 else {
                let outcome = await execute(calls[index], request: request, reason: reason, allowed: &allowed, out: out)
                append(outcome, for: calls[index])
                index += 1
                continue
            }
            let batch = Array(calls[index..<end])
            let snapshot = allowed // looking never changes the approvals
            let outcomes = await withTaskGroup(of: (Int, ToolOutcome).self) { group in
                for (offset, call) in batch.enumerated() {
                    group.addTask {
                        var local = snapshot
                        return (offset, await self.execute(call, request: request, reason: reason, allowed: &local, out: out))
                    }
                }
                var done: [Int: ToolOutcome] = [:]
                for await (offset, outcome) in group { done[offset] = outcome }
                return done
            }
            for (offset, call) in batch.enumerated() {
                append(outcomes[offset] ?? ToolOutcome("Error: the tool did not run.", isError: true), for: call)
            }
            index = end
        }
    }

    /// Whether the call is a known tool with valid arguments whose risk is `.safe`, so it never waits for the user.
    private static func runsWithoutAsking(_ call: ToolCallRequest, request: TurnRequest) -> Bool {
        guard let tool = request.tools.first(where: { $0.spec.name == call.name }),
              let arguments = JSONValue.parse(call.arguments) else { return false }
        return tool.risk(arguments) == .safe
    }

    /// What the model is sent: the system prompt and the turn so far, fitted to the budget. `messages` itself stays
    /// whole, so trimming is recomputed from the full record before every call.
    private static func fitted(_ messages: [ChatMessage], to budget: ContextBudget) -> [ChatMessage] {
        guard let system = messages.first, system.role == .system else { return messages }
        return [system] + ContextWindow.fit(Array(messages.dropFirst()), budget: budget).messages
    }

    /// Runs one tool call (asking first when needed) and returns the text the model receives. `allowed` holds the
    /// grants of this turn ("Só nesta tarefa").
    private func execute(_ call: ToolCallRequest, request: TurnRequest, reason: String, allowed: inout [PermissionRule],
                         out: AsyncStream<TurnEvent>.Continuation) async -> ToolOutcome {
        guard let tool = request.tools.first(where: { $0.spec.name == call.name }) else {
            return ToolOutcome("Error: unknown tool \(call.name).", isError: true)
        }
        guard let arguments = JSONValue.parse(call.arguments) else {
            return ToolOutcome("Error: the arguments are not valid JSON.", isError: true)
        }
        let summary = tool.summary(arguments, context: request.context)

        // The mode and rules as they are at this moment: the user may have changed them while the Orb worked.
        let live = await request.currentPermissions()
        let permission = PermissionPolicy.call(for: tool, arguments: arguments, context: request.context)
        switch PermissionPolicy.evaluate(mode: live.mode, call: permission, rules: live.rules, turnGrants: allowed,
                                         workspace: request.context.workingDirectory) {
        case .allow:
            break
        case .deny(let message):
            return Self.block(tool, summary, message, out)
        case .ask(let why):
            // The model's own explanation is already on screen right above the card.
            let approval = ApprovalRequest(
                toolName: call.name, title: summary.title, command: summary.detail,
                reason: why.explanation ?? (reason.isEmpty ? "\(request.bot.name) precisa da sua permissão para continuar." : ""),
                suggestions: PermissionPolicy.suggestions(for: permission, existing: live.rules + allowed,
                                                          workspace: request.context.workingDirectory))
            await gate.open(approval.id, botID: request.bot.id, alwaysAsks: why != .needsPermission)
            out.yield(.approval(approval))
            out.yield(.status("Esperando sua resposta"))
            let answer = await gate.wait(for: approval.id)
            let rule = answer.rule ?? approval.suggestions.first
            switch answer.decision {
            case .deny:
                // Switching to read-only answers open cards with a denial: say why.
                if await request.currentPermissions().mode == .readOnly {
                    return Self.block(tool, summary, PermissionPolicy.readOnlyDenial, out)
                }
                return ToolOutcome(PermissionPolicy.userDenial, isError: true)
            case .task:
                if let rule { allowed.append(rule) }
            case .always:
                // The app saves the rule in the Orb, which the next call reads; without a live source (nothing
                // saves it) it is kept for this turn.
                if request.permissions == nil, let rule { allowed.append(rule) }
            case .once:
                break
            }
        }

        let started = ToolCall(kind: tool.kind, title: summary.title, detail: summary.detail)
        out.yield(.toolStarted(started))
        out.yield(.status(summary.title))
        do {
            let output = try await tool.run(arguments, context: request.context)
            out.yield(.toolFinished(id: started.id, state: .done, output: Self.preview(output)))
            return ToolOutcome(output)
        } catch {
            let message = error.localizedDescription
            out.yield(.toolFinished(id: started.id, state: .failed, output: message))
            return ToolOutcome("Error: \(message)", isError: true)
        }
    }

    /// A call refused by the mode: the row shows it as started and failed (so the Orb is not left "running" it).
    private static func block(_ tool: any AgentTool, _ summary: (title: String, detail: String), _ message: String,
                              _ out: AsyncStream<TurnEvent>.Continuation) -> ToolOutcome {
        let blocked = ToolCall(kind: tool.kind, title: summary.title, detail: summary.detail)
        out.yield(.toolStarted(blocked))
        out.yield(.toolFinished(id: blocked.id, state: .failed, output: "Bloqueado: o Orb está em modo Só leitura."))
        return ToolOutcome(message, isError: true)
    }

    /// Tool output shown in the transcript (the model always gets the full text).
    private static func preview(_ output: String) -> String {
        output.count > 4000 ? output.prefix(4000) + "\n…" : output
    }
}
