import Foundation

// The plan of a long task, kept beside the conversation instead of only in its text: the model writes it with the
// `task_plan` tool, and the app and the engine keep it from the calls themselves. The text the model reads is rendered
// from it, so a compaction, a "continua" or a reopened app finds the steps as they were, never a summary of them.

struct TaskPlan: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case blocked

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .pending) }
    }

    struct Step: Codable, Sendable, Equatable {
        var text: String
        var state = State.pending
        /// Why the step is blocked; only for `.blocked`.
        var reason: String?

        init(text: String, state: State = .pending, reason: String? = nil) {
            self.text = text
            self.state = state
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.value(.text, default: "")
            state = try c.value(.state, default: .pending)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    // Limits of what is kept: the plan goes in front of the model again and again, so every character counts.
    static let maxSteps = 12
    static let goalLimit = 200
    static let stepLimit = 100
    static let reasonLimit = 60
    static let nextLimit = 160
    /// Done steps written out one by one; past this they are only numbered (`compact`).
    static let doneShown = 3
    /// The longest `compact` can be (all the limits at their worst), checked by the tests.
    static let maxCompactLength = 2_800

    var goal: String
    var steps: [Step]
    var next: String?
    var updatedAt: Date

    init(goal: String, steps: [Step], next: String? = nil, updatedAt: Date = .now) {
        self.goal = goal
        self.steps = steps
        self.next = next
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.value(.goal, default: "")
        steps = try c.lossyArray(.steps)
        next = try c.decodeIfPresent(String.self, forKey: .next)
        updatedAt = try c.value(.updatedAt, default: .distantPast)
    }

    /// Some step is not done yet: the plan still steers the work (it goes in the prompt and shows in the chat).
    var isActive: Bool { steps.contains { $0.state != .done } }
    var doneCount: Int { steps.count(where: { $0.state == .done }) }
    /// The step being worked on, else the first one still open.
    var current: Step? { steps.first { $0.state == .inProgress } ?? steps.first { $0.state != .done } }

    // MARK: Rendering

    static let heading = "[Plano da tarefa] "

    /// The whole plan, every step with its state: what the tool answers with.
    func render() -> String {
        var lines = [Self.heading + "Objetivo: " + goal]
        lines += steps.indices.map { line(for: $0) }
        if let next { lines.append("Próximo passo: " + next) }
        return lines.joined(separator: "\n")
    }

    /// The plan as it goes in front of the model with a message or a step: the open steps whole, the done ones counted
    /// once there are more than `doneShown`, and the next step. Numbers stay those of the plan, since updates use them.
    func compact() -> String {
        let done = steps.indices.filter { steps[$0].state == .done }
        var lines = [Self.heading + "Objetivo: " + goal]
        if done.count > Self.doneShown {
            lines.append("Feitas \(done.count) de \(steps.count): " + done.map { String($0 + 1) }.joined(separator: ", "))
            lines += steps.indices.filter { steps[$0].state != .done }.map { line(for: $0) }
        } else {
            lines += steps.indices.map { line(for: $0) }
        }
        if let next { lines.append("Próximo passo: " + next) }
        return lines.joined(separator: "\n")
    }

    private func line(for index: Int) -> String {
        let step = steps[index]
        let mark = switch step.state {
        case .pending: "[ ]"
        case .inProgress: "[fazendo]"
        case .done: "[feita]"
        case .blocked: "[bloqueada: \(step.reason ?? "")]"
        }
        return "\(index + 1). \(mark) \(step.text)"
    }

    // MARK: Changes

    enum Action: String, CaseIterable {
        case set, update, clear

        static var allNames: [String] { allCases.map(\.rawValue) }
    }

    /// The plan after a `task_plan` call with these arguments (nil: cleared). Throws, changing nothing, for anything
    /// the call cannot do; the tool and the replay of a conversation's calls both go through here, so they agree.
    static func applying(_ arguments: JSONValue, to plan: TaskPlan?, now: Date = .now) throws -> TaskPlan? {
        let action = arguments["action"]?.string ?? ""
        switch Action(rawValue: action) {
        case .set:
            let goal = clip(arguments["goal"]?.string ?? "", goalLimit)
            guard !goal.isEmpty else { throw ToolError("Give the `goal`.") }
            let texts = (arguments["steps"]?.array ?? []).compactMap(\.string).map { clip($0, stepLimit) }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { throw ToolError("Give the `steps`, 1 to \(maxSteps).") }
            guard texts.count <= maxSteps else {
                throw ToolError("At most \(maxSteps) steps (got \(texts.count)): merge some, or plan the next part when this one is done.")
            }
            let next = arguments["next"]?.string.map { clip($0, nextLimit) }
            return TaskPlan(goal: goal, steps: texts.map { Step(text: $0) }, next: next?.isEmpty == false ? next : nil, updatedAt: now)
        case .update:
            guard var plan else { throw ToolError("There is no plan: create one with action \"set\".") }
            let updates = arguments["updates"]?.array ?? []
            let next = arguments["next"]?.string
            guard !updates.isEmpty || next != nil else { throw ToolError("Give `updates`, `next`, or both.") }
            for update in updates {
                guard let number = update["step"]?.int, plan.steps.indices.contains(number - 1) else {
                    let given = update["step"]?.int.map(String.init) ?? "?"
                    throw ToolError("There is no step \(given): the plan has steps 1 to \(plan.steps.count).")
                }
                guard let state = update["state"]?.string.flatMap(State.init(rawValue:)) else {
                    throw ToolError("`state` of step \(number) is one of " + State.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                }
                let reason = clip(update["reason"]?.string ?? "", reasonLimit)
                guard state != .blocked || !reason.isEmpty else { throw ToolError("Say in `reason` why step \(number) is blocked.") }
                plan.steps[number - 1].state = state
                plan.steps[number - 1].reason = state == .blocked ? reason : nil
            }
            if let next {
                let clipped = clip(next, nextLimit)
                plan.next = clipped.isEmpty ? nil : clipped
            }
            plan.updatedAt = now
            return plan
        case .clear:
            return nil
        case nil:
            throw ToolError("`action` is one of set, update, clear.")
        }
    }

    /// The plan the `task_plan` calls in `messages` leave, replayed from the start: a call counts when its result says it
    /// ran (not an error, not a call the turn never got to).
    static func replay(_ messages: [ChatMessage], now: Date = .now) -> TaskPlan? {
        var calls: [String: ToolCallRequest] = [:]
        var plan: TaskPlan?
        for message in messages {
            for call in message.toolCalls where call.name == TaskPlanTool.name { calls[call.id] = call }
            guard let id = message.toolCallID, let call = calls[id], let arguments = ranArguments(of: call, result: message) else { continue }
            plan = (try? applying(arguments, to: plan, now: now)) ?? plan
        }
        return plan
    }

    /// The plan after one message is added to a conversation: changed only by the result of a `task_plan` call that ran.
    static func absorbing(_ message: ChatMessage, into plan: TaskPlan?, history: [ChatMessage], now: Date = .now) -> TaskPlan? {
        guard let id = message.toolCallID,
              let call = history.reversed().lazy.compactMap({ $0.toolCalls.first { $0.id == id } }).first,
              call.name == TaskPlanTool.name, let arguments = ranArguments(of: call, result: message) else { return plan }
        return (try? applying(arguments, to: plan, now: now)) ?? plan
    }

    /// Whether `messages` hold a `task_plan` call: a cut that drops one changes the plan.
    static func isChanged(by messages: some Sequence<ChatMessage>) -> Bool {
        messages.contains { $0.toolCalls.contains { $0.name == TaskPlanTool.name } }
    }

    private static func ranArguments(of call: ToolCallRequest, result: ChatMessage) -> JSONValue? {
        guard result.role == .tool, !result.isError, !result.content.hasPrefix("Not run:") else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
    }

    static func clip(_ text: String, _ limit: Int) -> String { MemoryText.clip(MemoryText.flatten(text), limit) }
}

extension Conversation {
    /// Adds a message of a turn to the model's history; the result of a `task_plan` call also changes the plan.
    mutating func absorb(_ message: ChatMessage) {
        if message.role == .tool { taskPlan = TaskPlan.absorbing(message, into: taskPlan, history: messages) }
        messages.append(message)
    }

    /// The plan, while it still steers the work.
    var activePlan: TaskPlan? { taskPlan?.isActive == true ? taskPlan : nil }
}
