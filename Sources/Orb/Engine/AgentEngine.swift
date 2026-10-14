import Foundation

/// What a running turn reports to the UI.
enum TurnEvent: Sendable {
    case status(String)
    case text(String)
    case toolStarted(ToolCall)
    /// `files`: what the tool created or changed (shown under its line).
    case toolFinished(id: UUID, state: ToolCall.State, output: String?, files: [ProducedFile] = [])
    case approval(ApprovalRequest)
    /// A message to append to the model history (user, assistant or tool result).
    case message(ChatMessage)
    case failed(String)
    /// Something the user should know, shown in the transcript (not sent to the model).
    case notice(String)
    /// Tokens the turn has used so far, summed over its model calls (the last one is the turn's total).
    case usage(TokenUsage)
    /// Tokens of the model call that just ended, alone (`.usage` follows with the new total): the size of the prompt
    /// the model reads now, and how much of it the provider served from its cache.
    case requestUsage(TokenUsage)
    /// The provider has begun to bill a model call (its input tokens are known before the answer ends). `.requestUsage` follows
    /// with the final numbers; only a call that never ends (the user stopped it) is counted from this one.
    case pendingUsage(TokenUsage)
    /// The task stopped at the step limit and left a progress record: the next message picks it up.
    case taskPaused
    /// The turn runs stretch `stretch` of the `limit` its request may run (`AutoContinue`): past the first, it went on by
    /// itself at the step limit. 1 again when a message of the user gave the request a new allowance.
    case stretch(Int, of: Int)
    /// A message the user sent during the turn (see `SteeringQueue`) was just handed to the model: the transcript
    /// shows it now, in its place among the steps, instead of as queued.
    case steered(UUID)
    /// Part of the history was folded into a summary during the turn. The
    /// app tells the user once, with numbers, and keeps the summary when the fold is of older turns (`report.fold`).
    case compacted(CompactionReport)
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
    /// What the summary at the start of `history` was rendered from, so folding more turns during the turn extends it
    /// instead of starting over from its text.
    var ledger: ConversationLedger?
    /// The model's notes on stretches of `history` not folded yet, in the indexes of the engine's own input (see
    /// `Conversation.chunks(inHistory:)`): a fold made during the turn that takes a stretch whole carries its note.
    var chunks: [ChunkSummary] = []
    /// Upper bound on model calls in this turn, so a confused model cannot loop forever.
    var maxSteps = AgentEngine.defaultMaxSteps
    /// Stretches of `maxSteps` the turn may run: past the first, one starts by itself only while the task plan has open
    /// steps and moved forward in the stretch before (`PlanProgress`); otherwise the turn pauses at the limit as with 1.
    var stretches = 1
    /// Where the engine writes what the task plan made it do (`AutoContinue.writeLog`; tests read it).
    var planLog: @Sendable (String) -> Void = AutoContinue.writeLog
    /// Nobody reads the turn while it runs (a routine run): a reply that ends on a question or an offer would wait for
    /// an answer that never comes, so the engine treats it like a promise (`stopReminder`).
    var unattended = false
    /// Grants for this turn only that the user's own request already gave (saving to memory when asked to remember).
    var turnGrants: [PermissionRule] = []
    /// The permission mode and rules as they are now, read at every tool call. nil keeps the ones in `bot` as
    /// they were when the turn started.
    var permissions: PermissionSource?
    /// Pictures the user attached to this message.
    var images: [ImageAttachment] = []
    /// The row of the chat that holds the message: the model's copy of it is recorded tied to that row (`ChatMessage.itemID`).
    var requestItem: UUID?
    /// Whether the model takes pictures: false never sends them (their paths go instead), nil is unknown (they are
    /// sent, and dropped for the rest of the turn if the provider says it cannot read them).
    var supportsImages: Bool?
    /// Called when the provider rejected the pictures, so the app can remember it for this model.
    var onImagesRejected: (@Sendable () -> Void)?
    /// Where outputs too big for the conversation are saved for the model to read back (`ToolOutputCap`). The app
    /// points it into its data folder; by default the system's temporary folder.
    var outputsDirectory = ToolOutputCap.defaultDirectory
    /// Called with the window the model really has when a refusal for size taught it (and the smaller history then
    /// worked), so the app can remember it for this model.
    /// `stated`: the refusal named the window (otherwise it is only inferred from the refusal, and less certain).
    var onContextLearned: (@Sendable (_ tokens: Int, _ stated: Bool) -> Void)?
    /// Called with the tokens the system prompt and tool specs really take, so the next turn plans its history with
    /// them (planned with a guess, the history would be cut again inside every turn).
    var onOverheadMeasured: (@Sendable (Int) -> Void)?
    /// The last task stopped at the step limit and this message picks it up (nil: judge by the history itself).
    var picksUpTask: Bool?
    /// Messages the user sends while this turn runs. The engine hands them to the model at the next step boundary;
    /// nil means the turn takes none (they wait for the turn's end).
    var steering: SteeringQueue?
    /// The only tools the turn may run (the background review of the conversation, `SkillReview`): a call to any other
    /// is answered with "Not available" and never runs, and a call that would need the user's approval is refused with
    /// no card, while `tools` still lists them all, so the request is the one the provider already has in its cache.
    var onlyTools: Set<String>?
    /// The prompt only steers the turn (the review of the conversation): it is part of the task in progress, not the
    /// request that starts one, so the outputs of the steps before it stay whole, as in the turn's last call.
    var promptOnlySteers = false

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
    /// Pictures the tool returned.
    var images: [ImageAttachment] = []

    init(_ text: String, isError: Bool = false, images: [ImageAttachment] = []) {
        self.text = text
        self.isError = isError
        self.images = images
    }
}

/// Runs bot turns: the model ↔ tools loop, gated by the bot's permission mode.
actor AgentEngine {
    /// Model calls per turn for a conversation, and for a routine (nobody is there to say "continua").
    static let defaultMaxSteps = 100
    static let routineMaxSteps = 150

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
        var user = ChatMessage.user(request.prompt, images: request.images)
        user.itemID = request.requestItem
        var messages = [ChatMessage.system(request.system)] + request.history + [user]
        out.yield(.message(user))
        // Where the message that opened this turn sits; the ones the user queues later come after it and open nothing.
        let turnStart = messages.count - 1
        let specs = request.tools.map(\.spec)
        var allowed = request.turnGrants
        // The request carries the system prompt and the tool specs besides the history: the budget accounts for them.
        let overhead = ContextBudget.overheadTokens(system: request.system, specs: specs)
        var budget = request.budget.refined(overheadTokens: overhead)
        request.onOverheadMeasured?(overhead)
        // Where the fits of this turn cut the history, so the start of the request holds still between compactions.
        var cut = ContextCut(ledger: request.ledger)
        cut.chunks = request.chunks
        // What of it was already told: every fold once (a summary the history starts with was told when it was made,
        // see `AppModel.send`), steps set aside once per turn.
        var announced = Announced()
        // The last task stopped at the step limit and this message picks it up.
        let picksUpTask = request.picksUpTask ?? ProgressRecord.endsHistory(request.history)
        var learnedWindow: (tokens: Int, stated: Bool)?
        let toolNames = Set(request.tools.map(\.spec.name))
        let maxSteps = max(2, request.maxSteps)
        var usage: TokenUsage?
        var requestsWithUsage = 0
        /// A request that failed after the provider said what it used is billed anyway: counted, not shown as a reply.
        func countDiscarded(_ used: TokenUsage) {
            var total = usage ?? TokenUsage()
            total.add(used)
            usage = total
            out.yield(.requestUsage(used))
            out.yield(.usage(total))
        }
        var warnedAboutCache = false
        // The engine's own recoveries, each with its own allowance, so one used up does not leave the others without
        // theirs: the "continue" after replies cut at the output limit, one more try after an empty reply, and the
        // reminders after a reply that stopped short (`stopReminder`).
        var cutContinues = 0
        var retriedSilence = false
        var reminders = 0
        // The step the task plan was last in front of the model at: the message that opens the turn carries it
        // (`TurnPrompt.native`), and so does every `task_plan` result.
        var planShown = 0
        // Whether tools ran since the last reminder: a reminder only follows another one after real work, so a model
        // that keeps announcing without acting is not asked forever.
        var workedSinceReminder = false
        // Where in `messages` the engine's own messages went (they steer the turn; they start none).
        var nudges: [Int] = request.promptOnlySteers ? [messages.count - 1] : []
        // Where in `messages` the user's messages sent during the turn went (more steps of it, not new turns).
        var steered: [Int] = []
        // Whether the last step ended only because the user was steering: with nothing to hand over now (the message
        // was put back for after the task meanwhile), there is no step to take.
        var continuedForSteering = false
        // Counts repeated calls and failures; `circling`: the last step's results told the model it was going in circles.
        var watch = LoopWatch()
        var circling = false
        // What the calls showed, to check a reply that says the work is done (`CompletionWatch`).
        var completion = CompletionWatch()
        // Whether the task plan moved forward in this stretch, and which stretch of the request's allowance runs
        // (`AutoContinue`); `stretchStart`, the step the stretch began after.
        var advance = PlanProgress(plan: request.context.taskPlan.plan)
        var stretch = 1
        var stretchStart = 0
        // The plan's closing reminder is given once per request; a message asking to stop holds it and the stretches back.
        var remindedOfPlan = false
        var stopAsked = false
        var sendImages = request.supportsImages != false
        if !sendImages, !request.images.isEmpty { out.yield(.notice(ImageRejection.notice)) }

        do {
            var step = 0
            while true {
                step += 1
                // The step within the stretch: the limit, the warning before it and the record are the stretch's.
                let stretchStep = step - stretchStart
                guard stretchStep <= maxSteps else { return }
                // The last step answers in text (the tools stay listed, so the provider's cache still applies).
                let isLastStep = stretchStep == maxSteps
                // What the user said since the last call goes to the model now: a step boundary.
                let delivered = Self.deliverSteering(request.steering, into: &messages, out: out)
                if continuedForSteering, delivered.isEmpty { return }
                continuedForSteering = false
                steered += delivered
                if let last = delivered.last {
                    stopAsked = AutoContinue.asksToStop(messages[last].content)
                    // A message of the user is a new request for the allowance: it starts over from this stretch.
                    if stretch > 1 {
                        stretch = 1
                        out.yield(.stretch(1, of: request.stretches))
                    }
                }
                // While the model reads that it was going in circles, the working line says it is changing course.
                let thinking = circling ? Self.changingCourse : "Pensando"
                circling = false
                out.yield(.status(thinking))
                var reply = Reply()
                var contextRetried = false
                var refused: [ChatMessage]? // the request refused for size, so the same one is not sent again
                while true {
                    var windowHasImages = false
                    var sent: [ChatMessage] = []
                    do {
                        let (window, fit) = Self.fitted(messages, to: budget, cut: &cut, continuing: picksUpTask, nudges: nudges, steering: steered,
                                                           sendImages: sendImages)
                        guard window != refused else {
                            out.yield(.failed(budget.isCrowded ? budget.crowdedFailure : Self.doesNotFit))
                            return
                        }
                        sent = window
                        windowHasImages = window.contains { !$0.images.isEmpty }
                        if let fit {
                            for report in announced.reports(after: fit, cut: cut, input: messages.dropFirst()) { out.yield(.compacted(report)) }
                        }
                        reply = try await respond(to: window, request: request, specs: specs, thinking: thinking,
                                                  toolChoice: isLastStep ? .none : .auto, stableToolCallID: fit?.stableToolCallID,
                                                  out: out, onDiscardedUsage: countDiscarded)
                        // The smaller history worked: that is what this model's window really is.
                        if let learned = learnedWindow {
                            learnedWindow = nil
                            request.onContextLearned?(learned.tokens, learned.stated)
                        }
                        break
                    } catch let error where !contextRetried && ContextOverflow.matches(error) {
                        // The window was smaller than estimated: try once more with less history. A refusal that
                        // states a window smaller than the one assumed sets the budget by it; otherwise the
                        // history is halved (and, when the window is only guessed, the guess is lowered).
                        // Either way the retry is smaller than the request that failed: when the memory level
                        // already capped the history below what the stated window allows, resizing alone would
                        // send the same request again.
                        contextRetried = true
                        refused = sent
                        let reported = ContextOverflow.reportedWindow(error)
                        if let stated = reported, let window = budget.window, stated < window {
                            var resized = budget.resized(window: stated)
                            resized.tokens = min(resized.tokens, budget.scaled(by: 0.5).tokens)
                            budget = resized
                            learnedWindow = (stated, true)
                        } else {
                            budget = budget.scaled(by: 0.5)
                            // A refusal naming the very window assumed (or a bigger one) says the estimate of the
                            // history was off, not the window: it is remembered as a guess too, so the next turns
                            // plan below it instead of overflowing again at every cycle.
                            learnedWindow = budget.window.map { (Int(Double($0) * Self.unstatedWindowShare), false) }
                        }
                        // Never more than half the history refused: after a fold to the low-water mark it is already
                        // under half the budget, and the budget alone would send it again unchanged.
                        budget.tokens = min(budget.tokens, ContextBudget.tokens(forCharacters: sent.dropFirst().contextCharacters) / 2)
                    } catch let error where windowHasImages && ImageRejection.matches(error) {
                        // The model cannot read pictures: say so once, remember it, and go on with their paths.
                        sendImages = false
                        request.onImagesRejected?()
                        out.yield(.notice(ImageRejection.notice))
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
                    requestsWithUsage += 1
                    if CacheHealth.logsUsage { FileHandle.standardError.write(Data((CacheHealth.logLine(step: step, usage: reported) + "\n").utf8)) }
                    out.yield(.requestUsage(reported))
                    out.yield(.usage(total))
                    if !warnedAboutCache, request.client.arrangesPromptCache, CacheHealth.isFailing(total, requests: requestsWithUsage) {
                        warnedAboutCache = true
                        out.yield(.notice(CacheHealth.notice))
                    }
                }

                let said = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // On the last step the model was told not to call tools; if it did anyway, the calls are not run.
                let calls = isLastStep ? [] : reply.calls
                let assistant = ChatMessage(role: .assistant, content: reply.text, toolCalls: calls, reasoning: reply.reasoning)
                // Append-only, so the earlier part of the conversation still hits the provider's cache.
                // Where another stretch may follow, the warning asks for the plan to be current instead (it decides).
                let mayGoOn = stretch < request.stretches && advance.plan?.openSteps.isEmpty == false
                let warning = maxSteps - stretchStep != Self.warningSteps ? nil
                    : mayGoOn ? AutoContinue.stepWarning(remaining: Self.warningSteps) : Self.stepWarning(remaining: Self.warningSteps)
                let recital = Self.planRecital(request.context.taskPlan.plan, calls: calls, step: step, shown: &planShown)
                let notes = [warning, recital].compactMap { $0 }
                let note = notes.isEmpty ? nil : notes.joined(separator: "\n\n")

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
                    if cutContinues < Self.cutContinueLimit && !isLastStep {
                        cutContinues += 1
                        // Not recorded: it only steers this turn and is no message of the user's.
                        nudges.append(messages.count)
                        messages.append(.user(Self.continueNudge))
                        continue
                    }
                    out.yield(.notice(Self.cutShortNotice))
                    return
                case .done, .toolUse, .unknown:
                    break
                }

                // At the step limit the stretch ends: another one starts by itself while the plan moves forward, or the
                // task pauses with its record for the "continua" that follows.
                let end = isLastStep ? Self.stretchEnd(stretch: stretch, of: request.stretches, plan: request.context.taskPlan.plan,
                                                       advanced: advance.advanced, stopAsked: stopAsked) : nil
                /// Starts the next stretch: the model reads where it is (after the record) and what is left of the allowance.
                func beginNextStretch() {
                    stretch += 1
                    stretchStart = step
                    advance.startStretch()
                    cutContinues = 0
                    retriedSilence = false
                    nudges.append(messages.count)
                    messages.append(.user(AutoContinue.nudge(stretch: stretch, of: request.stretches, steps: maxSteps)))
                    out.yield(.stretch(stretch, of: request.stretches))
                    out.yield(.notice(AutoContinue.notice(stretch: stretch, of: request.stretches)))
                    request.planLog("trecho \(stretch) de \(request.stretches) começou sozinho, depois de \(step) passos")
                }
                if let end, end != .goOn { request.planLog(end.logLine(stretch: stretch, steps: maxSteps)) }

                if calls.isEmpty && said.isEmpty {
                    // On the last step the model may have only tried to call tools: that is the limit, not silence.
                    if let end, !reply.calls.isEmpty {
                        // Nothing else says where the task stands: leave a record for the "continua" (or the stretch) that follows.
                        if let progress = Self.progress(in: messages, pickedUp: picksUpTask, turnStart: turnStart, nudges: nudges, steering: steered,
                                                        plan: request.context.taskPlan.plan) {
                            record(ChatMessage(role: .assistant, content: progress), in: &messages, out: out)
                            if end != .goOn { out.yield(.taskPaused) }
                        }
                        if end == .goOn {
                            beginNextStretch()
                            continue
                        }
                        out.yield(.notice(end.notice(steps: maxSteps, stretches: request.stretches)))
                        return
                    }
                    // Silence is often a hiccup of the provider or the model (most often right after tool results): one
                    // more try, told so, before calling it a failure.
                    if !isLastStep, !retriedSilence {
                        retriedSilence = true
                        nudges.append(messages.count)
                        messages.append(.user(Self.silenceNudge))
                        continue
                    }
                    out.yield(.failed(Self.silenceFailure))
                    return
                }
                if calls.isEmpty && isLastStep, let progress = Self.progress(in: messages, pickedUp: picksUpTask, turnStart: turnStart, nudges: nudges, steering: steered,
                                                        plan: request.context.taskPlan.plan) {
                    // The model's closing words, with the record of the steps after them (one message, so the roles
                    // keep alternating; the transcript shows only what the model wrote).
                    var closing = assistant
                    closing.content += "\n\n" + progress
                    record(closing, in: &messages, out: out)
                    if end != .goOn { out.yield(.taskPaused) }
                } else {
                    record(assistant, in: &messages, out: out)
                }
                if calls.isEmpty {
                    // The user spoke while this answer was being written: it is one more step, not a new turn.
                    if !isLastStep, request.steering?.hasSteering == true {
                        continuedForSteering = true
                        continue
                    }
                    // A reply that stops short ("vou rodar…" with nothing run, or a question in a run nobody reads), or
                    // says the work is done when the calls showed otherwise (`CompletionWatch`), would end the turn with the
                    // work undone: the model is reminded, at most `reminderLimit` times, and again only after it did some work. Not in the wizard or a review (`onlyTools`: conversations, not tasks).
                    // Last, from the same allowance: a reply that ends the task with steps of its plan still open, once
                    // per request (`AutoContinue.reminder`).
                    if !isLastStep, request.onlyTools == nil, reminders < Self.reminderLimit(unattended: request.unattended),
                       reminders == 0 || workedSinceReminder {
                        let earlier = Self.stopReminder(said, workedBefore: step > 1, unattended: request.unattended) ?? completion.reminder(for: said)
                        // Only for a plan of this task (changed in this turn, or the paused one it picks up), and not
                        // when the reply asks the user something: then the user is the one to answer.
                        let skipsPlan = earlier != nil || remindedOfPlan || stopAsked || !(advance.touched || picksUpTask)
                            || Self.endsWaitingForUser(said)
                        let open = skipsPlan ? [] : request.context.taskPlan.plan?.openSteps ?? []
                        if let reminder = earlier ?? (open.isEmpty ? nil : AutoContinue.reminder(open: open)) {
                            if earlier == nil {
                                remindedOfPlan = true
                                request.planLog("lembrete de fechamento: etapas abertas " + open.map(String.init).joined(separator: ", "))
                            }
                            reminders += 1
                            workedSinceReminder = false
                            nudges.append(messages.count)
                            messages.append(.user(reminder))
                            continue
                        }
                    }
                    if let end {
                        if end == .goOn {
                            beginNextStretch()
                            continue
                        }
                        out.yield(.notice(end.notice(steps: maxSteps, stretches: request.stretches)))
                    }
                    return
                }

                circling = await runCalls(calls, request: request, reason: said, allowed: &allowed, toolNames: toolNames, note: note,
                                          watch: &watch, completion: &completion, advance: &advance, messages: &messages, out: out)
                workedSinceReminder = true
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            // The user stopped the turn; the UI already says so.
        } catch {
            guard !Task.isCancelled else { return }
            out.yield(.failed(ContextOverflow.matches(error) && budget.isCrowded ? budget.crowdedFailure : error.localizedDescription))
        }
    }

    /// Hands the messages the user sent during the turn (for the task in progress, not for after it) to the model, as user messages after whatever came before
    /// (tool results included: the providers merge consecutive user turns), and tells the UI each one arrived.
    /// Returns where in `messages` they went.
    @discardableResult
    static func deliverSteering(_ queue: SteeringQueue?, into messages: inout [ChatMessage], out: AsyncStream<TurnEvent>.Continuation) -> [Int] {
        guard let queue else { return [] }
        var indexes: [Int] = []
        for steered in queue.drainSteering() { // the ones meant for after the task stay
            // The chat shows it under the id it has in the queue (`AppModel.deliverSteered`).
            var message = ChatMessage.user(steered.prompt, images: steered.pictures)
            message.itemID = steered.id
            indexes.append(messages.count)
            messages.append(message)
            out.yield(.message(message))
            out.yield(.steered(steered.id))
        }
        return indexes
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
    private func respond(to window: [ChatMessage], request: TurnRequest, specs: [ToolSpec], thinking: String = "Pensando", toolChoice: ToolChoice,
                         stableToolCallID: String? = nil,
                         out: AsyncStream<TurnEvent>.Continuation, onDiscardedUsage: (TokenUsage) -> Void) async throws -> Reply {
        var reply = Reply()
        let client = request.client.markingStable(upTo: stableToolCallID)
        do {
            try await withRetries(sleep: retrySleep, onWait: { seconds, _, error in
                out.yield(.status(Retry.waitStatus(seconds: seconds, after: error)))
            }, operation: {
                if let used = reply.usage { onDiscardedUsage(used) } // an earlier attempt broke off after reporting its use
                reply = Reply() // an attempt that failed before showing anything leaves nothing behind
                out.yield(.status(thinking))
                do {
                    for try await event in client.stream(model: request.model, messages: window, tools: specs, toolChoice: toolChoice) {
                        switch event {
                        case .text(let delta):
                            if reply.text.isEmpty { out.yield(.status("Escrevendo")) }
                            reply.text += delta
                            out.yield(.text(delta))
                        case .reasoning(let trace):
                            reply.reasoning = trace
                        case .toolCalls(let requested):
                            reply.calls = requested
                        case .usage(let used):
                            reply.usage = used
                            out.yield(.pendingUsage(used))
                        case .finished(let reason, let used):
                            reply.stop = reason
                            reply.usage = used
                        }
                    }
                    if case .contextExceeded = reply.stop, !reply.emitted { throw LLMError.contextExceeded("model_context_window_exceeded") }
                    // Cut off before anything was shown: a dropped stream, worth another try like any transient failure.
                    if case .incomplete = reply.stop, !reply.emitted { throw LLMError.stream(type: "api_error", message: Self.cutShort) }
                } catch where reply.emitted && !(error is CancellationError) {
                    throw StreamInterrupted(underlying: error, partialText: reply.text)
                } catch where ContextOverflow.matches(error) {
                    // Not transient: skip the retries and let `play` try again with less history.
                    if case LLMError.contextExceeded = error { throw error }
                    throw LLMError.contextExceeded(error.localizedDescription)
                }
            })
        } catch LLMError.stream(_, let message) where message == Self.cutShort {
            return reply // every attempt was cut short: the caller reports the interrupted response
        } catch {
            if let used = reply.usage { onDiscardedUsage(used) } // the attempt that ended the response did not finish it
            throw error
        }
        return reply
    }

    /// Marks a response cut off before showing anything, so it is retried and, if every attempt is, reported as cut off.
    private static let cutShort = "o provedor encerrou a resposta antes do fim"

    /// What a refusal for size says when the history cannot get any smaller: what is left is the request itself.
    static let doesNotFit = "O pedido não cabe na janela deste modelo, mesmo sem o histórico que dava para resumir. "
        + "Encurte a mensagem (ou os anexos) ou use um modelo com janela maior."

    /// A refusal for size that names no window, answered by a request with half the history: the window is taken to be
    /// this share of the one assumed (a second refusal at the next turn lowers it again). The window may well have
    /// been right and only the estimate of the history wrong, so the share is mild.
    static let unstatedWindowShare = 0.85

    static let interruptedMarker = "\n\n[resposta interrompida]"
    static let continueNudge = "continue"
    /// Replies cut at the output limit that are continued in one turn (more would be a model that cannot finish).
    static let cutContinueLimit = 2
    static let silenceNudge = "Your last reply was empty. Reply now: carry on with your tools, or answer in text."
    static let silenceFailure = "O modelo não respondeu."
    static let promiseNudge = "You ended your reply on something you said you would do, without doing it. Do it now with your tools, "
        + "in this reply, without announcing it again; if it really needs the user first, say what in one sentence."
    static let unattendedNudge = "[Automatic run] Nobody reads this run while it works, so nobody will answer a question, approve an "
        + "offer or wait for a promise. If the task still has work it asks for, decide by yourself and do it now with your tools. "
        + "Do not do what the task does not ask for, above all what deletes, sends or cannot be undone: put it in the report as a "
        + "suggestion. If it is done, or something only the user can solve blocks it, write the final report now, with no question at the end."

    /// Reminders in one turn: a run nobody reads gets one more, since there nobody can say "continua".
    static func reminderLimit(unattended: Bool) -> Int { unattended ? 3 : 2 }

    /// What to remind the model of when its reply, with no tool calls, ends the turn too early (nil: the turn may end).
    /// `workedBefore`: the turn already made calls. Before any, "vou…" is often only a reply ("Entendido, vou ignorar
    /// essa parte"), so only a promise of the very next step counts ("Vou verificar agora.", "Deixa eu ver:").
    /// `unattended`: nobody will answer, so ending on a question or an offer stops the run too.
    static func stopReminder(_ said: String, workedBefore: Bool, unattended: Bool) -> String? {
        let promised = endsOnPromise(said)
        if unattended, promised || endsWaitingForUser(said) { return unattendedNudge }
        if promised, workedBefore || promisesNextStep(said) { return promiseNudge }
        return nil
    }

    /// A first-person future the model did not negate ("vou", "farei", "I'll"), or a sentence opening on what comes next
    /// ("Em seguida respondo…"), in the last sentence of a reply. Measured on real conversations: it catches the "Vou
    /// adaptar…" endings and passes "não vou iniciá-la sem o seu sim", "Let me know…" and a past "e em seguida corrigi".
    private static let promise = try! NSRegularExpression(
        pattern: #"(?<!não )(?<!nao )\b(vou|irei|vamos|farei|faremos|deixa eu|deixe-me|deixa-me)\b|^(em seguida|a seguir)\b"#
            + #"|\b(I['’]ll|I will|I['’]m going to|I am going to)\b|\blet me\b(?! know)"#,
        options: [.caseInsensitive])
    /// What waits for the user or holds from now on rather than promising a step: an offer ("Se você aprovar, vou
    /// publicar."), waiting ("Vou aguardar sua resposta."), a standing rule ("A partir de agora vou responder em inglês.").
    private static let notAStep = try! NSRegularExpression(
        pattern: #"\b(se (você|vc|quiser|preferir|aprovar|concordar)|if you|quando (você|vc)|assim que (você|vc)|when you"#
            + #"|depois que (você|vc)|após (a |sua )?(aprova|confirma)\w*|caso (você|vc|queira|prefira|aprove)|com (seu|sua|o seu|a sua) (ok|aprova\w*|sim)"#
            + #"|once you|after you|te aviso|avis(ar|o) quando|let you know"#
            + #"|aguard\w*|esper(ar|o|ando)|wait\w*|à disposição|a partir de agora|daqui (pra|para) frente|from now on)\b"#,
        options: [.caseInsensitive])
    /// The promise is of the very next step, not of something later or a habit.
    private static let nextStep = try! NSRegularExpression(
        pattern: #"\b(agora|já|now|right away|primeiro|first|deixa eu|deixe-me|deixa-me|let me)\b"#, options: [.caseInsensitive])
    /// An ending that hands the turn to the user: a question, or an offer to do more.
    private static let handsOver = try! NSRegularExpression(
        pattern: #"(?<!não )(?<!nao )\b(posso|quer que eu|deseja que eu|gostaria que eu|prefere|se (você|vc) quiser|se quiser|should I|shall I"#
            + #"|do you want|would you like|want me to|let me know)\b"#,
        options: [.caseInsensitive])

    static func endsOnPromise(_ text: String) -> Bool {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, !reply.hasSuffix("?") else { return false }
        let sentence = lastSentence(of: reply)
        let range = NSRange(sentence.startIndex..., in: sentence)
        return promise.firstMatch(in: sentence, range: range) != nil && notAStep.firstMatch(in: sentence, range: range) == nil
    }

    static func endsWaitingForUser(_ text: String) -> Bool {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return false }
        if reply.hasSuffix("?") { return true }
        let sentence = lastSentence(of: reply)
        return handsOver.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil
    }

    private static func promisesNextStep(_ text: String) -> Bool {
        let sentence = lastSentence(of: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return nextStep.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil
    }

    /// The last sentence of a reply, after the last end of sentence or line break before its closing mark. A reply that
    /// ends on a list is judged by the line that opens the list ("Vou fazer assim:" then the steps), keeping its colon.
    private static func lastSentence(of reply: String) -> String {
        var lines = reply.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let listed = lines.count > 1 && isListItem(lines.last ?? "")
        while listed, let last = lines.last, isListItem(last) || last.isEmpty { lines.removeLast() }
        let text = listed ? lines.last ?? "" : lines.joined(separator: "\n")
        let body = text.dropLast(".!".contains(text.last ?? " ") ? 1 : 0)
        let start = body.range(of: #"[.!?]\s+|\n"#, options: [.regularExpression, .backwards])?.upperBound ?? body.startIndex
        return String(body[start...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    /// What the turn says when the model's reply was cut off at its limit (the Orb sighs at the end of such a turn).
    static let cutShortNotice = "A resposta passou do limite do modelo e foi cortada. Diga “continua” para seguir."
    static let cutOffResult = "Error: your reply hit the output limit while writing this call, so it was NOT run. Split the work into "
        + "smaller steps: write long files in parts (write_file with append: true), change existing files with edit_file, "
        + "and keep each call short."
    /// Steps left when the model is told how many it has.
    static let warningSteps = 3
    /// The working line while the model reads that it was going in circles (`LoopWatch`).
    static let changingCourse = "Mudando de abordagem"
    /// Calls that run without asking (reads) of one reply that run at the same time; the rest start as these finish.
    static let parallelTools = 8

    static func stepWarning(remaining: Int) -> String {
        "[Orb: restam \(remaining) passos neste turno; priorize e termine com um resumo do que fez e do que falta]"
    }

    /// The steps of the task `messages` end with, written as a progress record (nil when it made no tool calls).
    /// `pickedUp`: the turn's request only picks up the task before it. `nudges`: the indexes of the messages the engine
    /// added, which is no request. `turnStart`: the index of the message that opened the turn; the messages sent during it
    /// (`steering`, and anything queued after `turnStart`) are no request starting a task either, but stay in its record.
    private static func progress(in messages: [ChatMessage], pickedUp: Bool, turnStart: Int, nudges: [Int] = [], steering: [Int] = [],
                                 plan: TaskPlan? = nil) -> String? {
        let users = messages.indices.filter {
            $0 <= turnStart && !nudges.contains($0) && !steering.contains($0) && messages[$0].isConversationRequest
        }
        guard let start = pickedUp && users.count >= 2 ? users[users.count - 2] : users.last else { return nil }
        return ProgressRecord.text(task: messages.indices.filter { $0 >= start && !nudges.contains($0) }.map { messages[$0] }, plan: plan)
    }

    /// Steps after which the task plan is put in front of the model again when nothing else showed it.
    static let planRecitalInterval = 8

    /// The plan, at the end of this step's results, when it is still open and the model has not seen it for
    /// `planRecitalInterval` steps (a step that calls `task_plan` sees it in the result). Append-only, like `stepWarning`,
    /// so it costs no cache; the plan never goes anywhere it would have to be taken out again.
    static func planRecital(_ plan: TaskPlan?, calls: [ToolCallRequest], step: Int, shown: inout Int) -> String? {
        guard !calls.isEmpty else { return nil }
        if calls.contains(where: { $0.name == TaskPlanTool.name }) {
            shown = step
            return nil
        }
        guard let plan, plan.isActive, step - shown >= planRecitalInterval else { return nil }
        shown = step
        return plan.compact()
    }

    /// The part of `pausedNotice` only the chat can act on: where the notice is read as why a run did not finish (a
    /// routine's history, another Orb's request), it is dropped.
    static let continueHint = " Diga “continua” e eu sigo de onde parei."

    static func pausedNotice(after steps: Int) -> String {
        "Pausei depois de \(steps) passos neste turno." + continueHint
    }

    /// How a stretch ends at the step limit (`AutoContinue`).
    enum StretchEnd: Equatable {
        /// Another stretch starts by itself.
        case goOn
        /// The turn pauses as it always did: one stretch only, no plan with open steps, or the user asked to stop.
        case pause
        /// The plan had open steps but none was done with real work in the whole stretch.
        case stalled
        /// The plan moved forward, but the request ran all the stretches it may.
        case capped

        func notice(steps: Int, stretches: Int) -> String {
            switch self {
            case .goOn, .pause: AgentEngine.pausedNotice(after: steps)
            case .stalled: AutoContinue.stalledNotice(after: steps)
            case .capped: AutoContinue.cappedNotice(stretches: stretches)
            }
        }

        func logLine(stretch: Int, steps: Int) -> String {
            switch self {
            case .goOn, .pause: "pausa no limite de \(steps) passos (trecho \(stretch))"
            case .stalled: "pausa por estagnação: o plano não avançou no trecho \(stretch)"
            case .capped: "pausa no teto: \(stretch) trechos seguidos"
            }
        }
    }

    static func stretchEnd(stretch: Int, of limit: Int, plan: TaskPlan?, advanced: Bool, stopAsked: Bool) -> StretchEnd {
        guard limit > 1, !stopAsked, plan?.openSteps.isEmpty == false else { return .pause }
        guard advanced else { return .stalled }
        return stretch < limit ? .goOn : .capped
    }

    // MARK: Tool calls

    /// Runs one step's tool calls and records their results in the order of the calls, each as soon as it and the
    /// ones before it are done. Consecutive calls that only look (risk `.safe`, so nothing to ask) run at the same
    /// time; everything else runs alone, in order. `note`, and what `watch` has to say about the turn going in circles,
    /// go at the end of the last result. Returns whether `watch` said something.
    private func runCalls(_ calls: [ToolCallRequest], request: TurnRequest, reason: String, allowed: inout [PermissionRule],
                          toolNames: Set<String>, note: String?, watch: inout LoopWatch, completion: inout CompletionWatch,
                          advance: inout PlanProgress, messages: inout [ChatMessage],
                          out: AsyncStream<TurnEvent>.Continuation) async -> Bool {
        let (calls, request) = await resolved(calls, in: request)
        var circling = false
        func append(_ outcome: ToolOutcome, for call: ToolCallRequest) {
            let kind = request.tools.first { $0.spec.name == call.name }?.kind
            // A file read is the file: asked for again, it comes back. Anything else may not, a failed build's log least.
            var text = ToolOutputCap.apply(outcome.text, botID: request.bot.id, callID: call.id, toolNames: toolNames,
                                           directory: request.outputsDirectory, keepsCopy: kind != .file)
            // A call the user refused never ran: it is no failure of its own, nor a result to compare.
            if !outcome.text.hasPrefix(PermissionPolicy.refusalPrefix) {
                watch.record(call, result: outcome.text, failed: outcome.isError, live: LoopWatch.isLive(call.name, kind: kind))
                completion.record(call, result: outcome.text, failed: outcome.isError)
                let unearned = advance.record(call, failed: outcome.isError)
                if !unearned.isEmpty {
                    request.planLog("etapa " + unearned.map(String.init).joined(separator: ", ") + " marcada como feita sem trabalho real: não conta como avanço")
                }
            }
            if call == calls.last {
                let loop = watch.note()
                circling = loop != nil
                for added in [note, loop].compactMap({ $0 }) { text += "\n\n" + added }
            }
            let message = ChatMessage.tool(call.id, text, isError: outcome.isError, images: outcome.images)
            messages.append(message)
            out.yield(.message(message))
        }

        let confirmed = await confirmBatch(calls, request: request, reason: reason, allowed: &allowed, out: out)
        // A command that went on in the background (`CommandRelease`) ends the step: the calls after it were asked for as
        // if it had ended, and the user wants the Orb back. They are answered without running, and the model asks again.
        let releasedBefore = request.context.release?.releasedCount ?? 0
        var index = 0
        while index < calls.count, !Task.isCancelled {
            if (request.context.release?.releasedCount ?? 0) > releasedBefore {
                for call in calls[index...] {
                    let message = ChatMessage.tool(call.id, Self.skippedAfterRelease)
                    messages.append(message)
                    out.yield(.message(message))
                }
                break
            }
            if let refused = confirmed.refused[index] {
                append(refused, for: calls[index])
                index += 1
                continue
            }
            var end = index
            while end < calls.count, Self.runsWithoutAsking(calls[end], request: request) { end += 1 }
            guard end - index > 1 else {
                let outcome = await execute(calls[index], request: request, reason: reason, allowed: &allowed, approved: confirmed.approved.contains(index), out: out)
                append(outcome, for: calls[index])
                index += 1
                continue
            }
            let batch = Array(calls[index..<end])
            let snapshot = allowed // looking never changes the approvals
            // At most `parallelTools` at a time: a reply with a hundred reads does not open a hundred processes at once.
            let outcomes = await withTaskGroup(of: (Int, ToolOutcome).self) { group in
                var calls = batch.enumerated().makeIterator()
                func startNext() {
                    guard let (offset, call) = calls.next() else { return }
                    group.addTask {
                        var local = snapshot
                        return (offset, await self.execute(call, request: request, reason: reason, allowed: &local, out: out))
                    }
                }
                for _ in 0..<Self.parallelTools { startNext() }
                var done: [Int: ToolOutcome] = [:]
                while let (offset, outcome) = await group.next() {
                    done[offset] = outcome
                    startNext()
                }
                return done
            }
            for (offset, call) in batch.enumerated() {
                append(outcomes[offset] ?? ToolOutcome("Error: the tool did not run.", isError: true), for: call)
            }
            index = end
        }
        return circling
    }

    /// What the model reads for a call of the step not run because a command before it went on in the background.
    static let skippedAfterRelease = "[Não executado: um comando anterior desta resposta foi para segundo plano antes de "
        + "terminar, e esta chamada pode depender do resultado dele. Chame de novo se ainda fizer sentido.]"

    /// The step's calls with each `connector_call` replaced by the call of the real tool it names (`GitHub__create_issue`,
    /// with the arguments inside), and the request with those tools added. Everything after this (the approval cards, the
    /// annotations, the rules "Sempre permitir", the activity line) sees the same call as if the model had made it directly.
    /// A call that does not resolve stays as it is: `connector_call` itself then fails with what is wrong.
    private func resolved(_ calls: [ToolCallRequest], in request: TurnRequest) async -> ([ToolCallRequest], TurnRequest) {
        guard let gateway = request.tools.first(where: { $0.spec.name == ConnectorGateway.callName }) as? ConnectorCallTool else {
            return (calls, request)
        }
        var request = request
        var resolved: [ToolCallRequest] = []
        for call in calls {
            guard call.name == ConnectorGateway.callName, let arguments = JSONValue.parse(call.arguments),
                  let found = try? await gateway.resolve(arguments) else {
                resolved.append(call)
                continue
            }
            if !request.tools.contains(where: { $0.spec.name == found.tool.spec.name }) { request.tools.append(found.tool) }
            resolved.append(ToolCallRequest(id: call.id, name: found.tool.spec.name, arguments: found.arguments.jsonString))
        }
        return (resolved, request)
    }

    /// Asks once for the step's calls that would each ask for ordinary permission (see `ApprovalBatch`). Returns the
    /// calls the user allowed (they run without asking again) and the ones refused. "Revisar uma a uma", and a switch
    /// to read-only while the card was open, leave both empty: every call then asks for itself, as without batching.
    private func confirmBatch(_ calls: [ToolCallRequest], request: TurnRequest, reason: String, allowed: inout [PermissionRule],
                              out: AsyncStream<TurnEvent>.Continuation) async -> (approved: Set<Int>, refused: [Int: ToolOutcome]) {
        guard request.onlyTools == nil else { return ([], [:]) } // the calls that can run need no card
        let live = await request.currentPermissions()
        guard let batch = ApprovalBatch.plan(calls: calls, tools: request.tools, context: request.context, state: live, grants: allowed)
        else { return ([], [:]) }
        let approval = batch.request(botName: request.bot.name, reason: reason)
        await gate.open(approval.id, botID: request.bot.id)
        out.yield(.approval(approval))
        out.yield(.status("Esperando sua resposta"))
        let answer = await gate.wait(for: approval.id)
        let indices = Set(batch.members.map(\.index))
        let rules = answer.rule.map { [$0] } ?? approval.suggestions
        switch answer.decision {
        case .review:
            return ([], [:])
        case .deny:
            if await request.currentPermissions().mode == .readOnly { return ([], [:]) }
            return ([], Dictionary(uniqueKeysWithValues: indices.map {
                ($0, ToolOutcome(PermissionPolicy.userDenial(note: answer.note), isError: true))
            }))
        case .task:
            allowed.append(contentsOf: rules)
        case .always:
            // The app saves the rule in the Orb; without a live source (nothing saves it) it is kept for this turn.
            if request.permissions == nil { allowed.append(contentsOf: rules) }
        case .once:
            break
        }
        return (indices, [:])
    }

    /// Whether the call is a known tool with valid arguments whose risk is `.safe`, so it never waits for the user. A tool
    /// whose whole work is a card for the person (`waitsForThePerson`) runs alone: two questions asked at once would be
    /// two cards, answered in whatever order they happened to open.
    private static func runsWithoutAsking(_ call: ToolCallRequest, request: TurnRequest) -> Bool {
        guard !waitsForThePerson.contains(call.name),
              let tool = request.tools.first(where: { $0.spec.name == call.name }),
              let arguments = JSONValue.parse(call.arguments) else { return false }
        // Judged as the policy will judge it: a read of a private key asks, a command that only looks does not.
        return PermissionPolicy.call(for: tool, arguments: arguments, context: request.context).risk == .safe
    }

    static let waitsForThePerson: Set<String> = [AskUserTool.name, OrbProposeTool.name]

    /// What the model is sent: the system prompt and the turn so far, fitted to the budget. `messages` itself stays
    /// whole, so trimming is recomputed from the full record before every call.
    /// `cut` is what earlier calls of this turn decided to leave out: it holds still until the history is over the
    /// budget again, and then moves in one go (see `ContextWindow.fit`), so most calls extend the previous request
    /// and the provider's cache keeps working.
    /// `nudges`: indexes in `messages` of the engine's own messages; `steering`: those of the user's messages sent during the
    /// turn (see `ContextWindow.fit`), which the model reads under `steeringFrame`. Only the request carries it: the
    /// chat, the history and the summary keep the user's own words.
    private static func fitted(_ messages: [ChatMessage], to budget: ContextBudget, cut: inout ContextCut, continuing: Bool = false,
                               nudges: [Int] = [], steering: [Int] = [], sendImages: Bool = true) -> (messages: [ChatMessage], fit: ContextWindow?) {
        guard let system = messages.first, system.role == .system else { return (messages, nil) }
        let fit = ContextWindow.fit(Array(messages.dropFirst()), budget: budget, cut: &cut, continuing: continuing,
                                    nudges: nudges.map { $0 - 1 }, steering: steering.map { $0 - 1 })
        let steered = Set(steering.compactMap { messages[$0].itemID })
        let window = [system] + fit.messages.map { message in
            guard message.role == .user, let id = message.itemID, steered.contains(id) else { return message }
            var framed = message
            framed.content = steeringFrame + "\n\n" + message.content
            return framed
        }
        return (sendImages ? window : window.strippingImages(), fit)
    }

    /// What a message the user sent during the turn is read under: without it, a weak model answers the new message and
    /// drops the work it was doing.
    static let steeringFrame = "[Sent while you were working on the request above. Read this first: it may change that work, add to it, "
        + "stop it, or be about something else. Then, unless it says otherwise, carry on with whatever part of that work is unfinished.]"

    /// What the compactions of one turn have told so far. The window is fitted again before every model call, so
    /// without this the same fold would be seen at every step: a fold is reported when the cut moves (and only the
    /// part that moved), steps set aside once per turn.
    struct Announced: Sendable {
        /// Messages of the fit's input already reported as folded.
        private var covered = 0
        private var steps = false
        /// Notes of the cut already reported with a fold.
        private var notes = 0

        mutating func reports(after window: ContextWindow, cut: ContextCut, input: ArraySlice<ChatMessage>) -> [CompactionReport] {
            var reports: [CompactionReport] = []
            let before = ContextBudget.tokens(forCharacters: window.charactersBefore)
            let after = ContextBudget.tokens(forCharacters: window.charactersAfter)
            if cut.covered > covered, let summary = cut.summary {
                // A summary pair the input starts with stands for what was folded before this turn: not counted again.
                let pair = covered == 0 && ContextSummary.inherited(in: Array(input.prefix(2))) != nil ? 2 : 0
                let own = Array(input.dropFirst(max(covered, pair)).prefix(max(cut.covered - max(covered, pair), 0)))
                reports.append(CompactionReport(kind: .turns, foldedMessages: own.count, tokensBefore: before, tokensAfter: after,
                                                fold: .init(summary: summary, ledger: cut.ledger,
                                                            turns: own.filter { $0.role == .user }.count),
                                                digests: Array(cut.attachedNotes.dropFirst(notes))))
                notes = cut.attachedNotes.count
                covered = cut.covered
            }
            if window.skippedSteps > 0, !steps {
                steps = true
                reports.append(CompactionReport(kind: .steps, foldedMessages: window.skippedSteps, tokensBefore: before, tokensAfter: after))
            }
            return reports
        }
    }

    /// Runs one tool call (asking first when needed) and returns the text the model receives. `allowed` holds the
    /// grants of this turn ("Só nesta tarefa"). `approved`: the user already allowed it on a card that grouped it.
    private func execute(_ call: ToolCallRequest, request: TurnRequest, reason: String, allowed: inout [PermissionRule],
                         approved: Bool = false, out: AsyncStream<TurnEvent>.Continuation) async -> ToolOutcome {
        if let only = request.onlyTools, !only.contains(call.name) { return ToolOutcome("Not available in this review.", isError: true) }
        guard let tool = request.tools.first(where: { $0.spec.name == call.name }) else {
            return ToolOutcome("Error: unknown tool \(call.name).", isError: true)
        }
        guard let arguments = JSONValue.parse(call.arguments) else {
            return ToolOutcome("Error: the arguments are not valid JSON. Send one JSON object"
                + tool.spec.argumentsHint + " and call \(call.name) again.", isError: true)
        }
        let summary = tool.summary(arguments, context: request.context)

        // The mode and rules as they are at this moment: the user may have changed them while the Orb worked.
        let live = await request.currentPermissions()
        let permission = PermissionPolicy.call(for: tool, arguments: arguments, context: request.context)
        var verdict = PermissionPolicy.evaluate(mode: live.mode, call: permission, rules: live.rules, turnGrants: allowed,
                                                workspace: request.context.workingDirectory)
        // The card already answered "ask": only that. A mode that blocks (read-only) still does, even for a call approved before.
        if approved, case .ask(.needsPermission) = verdict { verdict = .allow }
        switch verdict {
        case .allow:
            break
        case .deny(let message):
            return Self.block(tool, summary, message, out)
        case .ask(let why):
            // A review shows no card (nobody would see it): what it may run asks nothing, and the rest is refused.
            if request.onlyTools != nil { return ToolOutcome("This review only proposes skills: use remember with tipo skill.", isError: true) }
            // The model's own explanation is already on screen right above the card.
            let approval = ApprovalRequest(
                toolName: call.name, title: summary.title, command: summary.detail,
                reason: why.explanation ?? (reason.isEmpty ? "\(request.bot.name) precisa da sua permissão para continuar." : ""),
                suggestions: PermissionPolicy.suggestions(for: permission, existing: live.rules + allowed,
                                                          workspace: request.context.workingDirectory),
                isDangerous: why.isDangerous)
            await gate.open(approval.id, botID: request.bot.id, alwaysAsks: why != .needsPermission)
            out.yield(.approval(approval))
            out.yield(.status("Esperando sua resposta"))
            let answer = await gate.wait(for: approval.id)
            let rule = answer.rule ?? approval.suggestions.first
            switch answer.decision {
            case .deny, .review:
                // Switching to read-only answers open cards with a denial: say why.
                if await request.currentPermissions().mode == .readOnly {
                    return Self.block(tool, summary, PermissionPolicy.readOnlyDenial, out)
                }
                return ToolOutcome(PermissionPolicy.userDenial(note: answer.note), isError: true)
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
        // A connector that has to start first says so: an `npx` server can take many seconds.
        do {
            if let connecting = await tool.connectingNote(arguments) {
                out.yield(.status(connecting))
                try await tool.prepare(arguments)
                out.yield(.status(summary.title))
            }
            let target = Self.writeTarget(tool.spec.name, arguments, request.context)
            var context = request.context
            context.judgedDanger = permission.danger != nil
            context.handoff = { [self] page in
                await handoff(page: page, resuming: summary.title, request: request, out: out)
            }
            context.askUser = { [self] question in
                await ask(question, resuming: summary.title, request: request, out: out)
            }
            // MARK: MultiOrb (WP3)
            if tool.spec.name == OrbProposeTool.name, var creation = context.orbCreation {
                // The mode as it is now, not as it was when the turn began: the tool refuses to propose in read-only.
                creation.creator.permissionMode = live.mode
                context.orbCreation = creation
                let support = creation
                context.proposeOrb = { [self] proposal in
                    await propose(proposal, creation: support, resuming: summary.title, request: request, out: out)
                }
            }
            // MARK: end MultiOrb (WP3)
            let result = try await tool.runWithImages(arguments, context: context)
            let files = (target.map { [ProducedFile(path: $0.url.path, created: !$0.existed)] } ?? [])
                + result.images.map { ProducedFile(path: $0.path, created: true) }
            out.yield(.toolFinished(id: started.id, state: result.failed ? .failed : .done, output: Self.preview(result.text), files: files))
            return ToolOutcome(result.text, isError: result.failed, images: result.images)
        } catch {
            let message = error.localizedDescription
            out.yield(.toolFinished(id: started.id, state: .failed, output: message))
            return ToolOutcome("Error: \(message)", isError: true)
        }
    }

    /// The card of a tool that hands the browser to the person: it waits, like an approval, for "Pronto" or "Cancelar". True on
    /// "Pronto". Parar answers it with a refusal (the turn is cancelled anyway).
    private func handoff(page: String, resuming title: String, request: TurnRequest, out: AsyncStream<TurnEvent>.Continuation) async -> Bool {
        let done = await gate.handoff(page: page, botName: request.bot.name, botID: request.bot.id) { card in
            out.yield(.approval(card))
            out.yield(.status("Esperando sua resposta"))
        }
        out.yield(.status(title))
        return done
    }

    /// The card of `ask_user`: it waits, like an approval, for the person's answer; nil when they skipped it (or pressed Parar).
    private func ask(_ question: OrbQuestion, resuming title: String, request: TurnRequest,
                     out: AsyncStream<TurnEvent>.Continuation) async -> String? {
        let answer = await gate.ask(question, botName: request.bot.name, botID: request.bot.id) { card in
            out.yield(.approval(card))
            out.yield(.status("Esperando sua resposta"))
        }
        out.yield(.status(title))
        return answer
    }

    // MARK: MultiOrb (WP3)
    /// The creation card of `orb_propose`: it waits like an approval, even in "Sem pedir permissão", and the Orb is created when the
    /// person says "Criar".
    private func propose(_ proposal: OrbProposal, creation: OrbCreationSupport, resuming title: String, request: TurnRequest,
                         out: AsyncStream<TurnEvent>.Continuation) async -> ProposalOutcome {
        let outcome = await gate.proposeAndCreate(proposal, creation: creation, botName: request.bot.name, botID: request.bot.id) { card in
            out.yield(.approval(card))
            out.yield(.status("Esperando sua resposta"))
        }
        out.yield(.status(title))
        return outcome
    }
    // MARK: end MultiOrb (WP3)

    /// Where `write_file` or `edit_file` is about to write and whether a file was there already, to tell "novo" from "alterado".
    static func writeTarget(_ name: String, _ arguments: JSONValue, _ context: ToolContext) -> (url: URL, existed: Bool)? {
        guard name == "write_file" || name == "edit_file", let path = arguments["path"]?.string, !path.isEmpty else { return nil }
        let url = context.url(for: path)
        return (url, FileManager.default.fileExists(atPath: url.path))
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
