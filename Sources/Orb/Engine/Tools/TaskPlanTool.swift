import Foundation
import os

/// The plan of the task the turn works on, as the `task_plan` calls leave it. The app makes one per turn from the
/// conversation's plan (`ToolContext.taskPlan`); the engine reads it to recite the plan and to write it in the progress
/// record when the turn pauses at the step limit. The conversation keeps its own copy from the calls themselves
/// (`TaskPlan.absorbing`), so nothing here has to be saved.
final class TaskPlanBoard: Sendable {
    private let state: OSAllocatedUnfairLock<TaskPlan?>

    init(_ plan: TaskPlan? = nil) { state = OSAllocatedUnfairLock(initialState: plan) }

    var plan: TaskPlan? { state.withLock { $0 } }

    /// Applies one call, all of it or nothing, and returns the plan it leaves.
    func apply(_ arguments: JSONValue) throws -> TaskPlan? {
        try state.withLock { plan in
            plan = try TaskPlan.applying(arguments, to: plan)
            return plan
        }
    }
}

/// Lets the Orb keep the plan of a long task outside the conversation's text, where compaction cannot lose it: the
/// steps with their state and the next step. Offered to every Orb, read-only ones too: it only writes the plan.
struct TaskPlanTool: AgentTool {
    static let name = "task_plan"

    let spec = ToolSpec(
        name: TaskPlanTool.name,
        description: """
        Plan of a task with several steps (not a question or a quick request), shown to you again as you work. set: goal \
        and 1 to \(TaskPlan.maxSteps) steps (replaces the plan). update: steps by number (blocked needs a reason) and/or next. \
        clear: drop it.
        """,
        // No descriptions where the description above or the name says it: every character goes with every request.
        parameters: .schema([
            "action": .object(["type": .string("string"), "enum": .array(TaskPlan.Action.allNames.map(JSONValue.string))]),
            "goal": .property("string"),
            "steps": .object(["type": .string("array"), "items": .property("string")]),
            "updates": .object(["type": .string("array"), "items": .schema([
                "step": .property("integer"),
                "state": .object(["type": .string("string"), "enum": .array(TaskPlan.State.allCases.map { .string($0.rawValue) })]),
                "reason": .property("string"),
            ], required: ["step", "state"])]),
            "next": .property("string", "What you will do next (\"\" clears it)."),
        ], required: ["action"]))

    var kind: ToolCall.Kind { .plan }
    var capability: Capability? { nil }

    /// Safe for the permission check: it writes nothing but the plan.
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch TaskPlan.Action(rawValue: arguments["action"]?.string ?? "") {
        case .set: ("Planejando", arguments["goal"]?.string ?? "")
        case .clear: ("Encerrando o plano", "")
        case .update, nil: ("Atualizando o plano", arguments["next"]?.string ?? "")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let plan = try context.taskPlan.apply(arguments) else { return "The plan was cleared." }
        return plan.render()
    }
}

extension ToolBox {
    static let planTools: [any AgentTool] = [TaskPlanTool()]
}
