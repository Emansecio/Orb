import Foundation

/// What the engine tells the model about the task plan (`task_plan`) when a reply would end the task with steps still open,
/// and when a message of the user asks to stop instead.
enum PlanReminder {
    /// The closing reminder: the reply ends the turn while steps of the plan are still open.
    static func text(open steps: [Int]) -> String {
        let list = steps.map(String.init).joined(separator: ", ")
        return "Before you finish: step\(steps.count == 1 ? "" : "s") \(list) of your task plan \(steps.count == 1 ? "is" : "are") "
            + "still open. Go on with \(steps.count == 1 ? "it" : "them") now; or mark what you cannot do as blocked, with the "
            + "reason (task_plan update); or tell the user plainly why you stop here."
    }

    /// A message the user sent during the task that asks it to stop ("para", "pode parar", "chega"): the closing reminder
    /// does not follow it. Only what the user typed counts: what the app adds to a message (a picture's note, an attachment's
    /// text) comes after a blank line.
    static func asksToStop(_ text: String) -> Bool {
        let typed = text.components(separatedBy: "\n\n").first ?? text
        return typed.range(of: stopRequest, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let stopRequest = #"^\s*(pode |por favor,? |favor )?(para|pare|parar|pausa|pause|chega|cancela|cancele|interromp[ae]"#
        + #"|stop|n[ãa]o (continue|precisa continuar|siga))\b[\s.!]*$"#
}

extension TaskPlan {
    /// The numbers of the steps still to do (pending or in progress); blocked ones wait for something else.
    var openSteps: [Int] { steps.indices.filter { [.pending, .inProgress].contains(steps[$0].state) }.map { $0 + 1 } }
}
