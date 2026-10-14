import Foundation

/// Whether the task plan moved forward in a stretch of a turn, measured by the calls themselves, without asking any
/// model: a step counts when it was marked done after real work (a call of another tool that ran) since it was last
/// opened in the stretch, or since the stretch began. A step marked done with only `task_plan` calls since then does
/// not: marking steps done is not how a task earns more steps.
struct PlanProgress: Sendable {
    /// The plan as the turn's calls left it, replayed here in the order of the calls (`TaskPlan.applying`).
    private(set) var plan: TaskPlan?
    /// A `task_plan` call ran in this turn: the plan is this turn's work, not one left from an earlier task.
    private(set) var touched = false
    /// A step became done after real work in this stretch.
    private(set) var advanced = false
    /// Calls of other tools that ran this turn.
    private var work = 0
    /// For each step, `work` when it was last opened (or the stretch began): the work after it is the step's.
    private var openedAt: [Int] = []

    init(plan: TaskPlan?) {
        self.plan = plan
        openedAt = Array(repeating: 0, count: plan?.steps.count ?? 0)
    }

    /// A new stretch: only what happens from now on counts for it.
    mutating func startStretch() {
        advanced = false
        openedAt = Array(repeating: work, count: plan?.steps.count ?? 0)
    }

    /// Counts one call that ran (refusals never did). Returns the numbers of the steps this call marked done without
    /// real work since they were opened, which do not count as moving forward.
    @discardableResult
    mutating func record(_ call: ToolCallRequest, failed: Bool) -> [Int] {
        guard call.name == TaskPlanTool.name else {
            work += 1
            return []
        }
        guard !failed, let arguments = JSONValue.parse(call.arguments) else { return [] }
        let after: TaskPlan?
        do { after = try TaskPlan.applying(arguments, to: plan) } catch { return [] }
        touched = true
        let before = plan
        plan = after
        guard let after else {
            openedAt = []
            return []
        }
        // A new plan (`set`) opens all its steps now; an update opens the ones it moves anywhere but done.
        guard arguments["action"]?.string == TaskPlan.Action.update.rawValue, let before, before.steps.count == after.steps.count else {
            openedAt = Array(repeating: work, count: after.steps.count)
            return []
        }
        var unearned: [Int] = []
        for index in after.steps.indices where after.steps[index].state != before.steps[index].state {
            guard after.steps[index].state == .done else {
                openedAt[index] = work
                continue
            }
            if work > openedAt[index] { advanced = true } else { unearned.append(index + 1) }
        }
        return unearned
    }
}

/// Going on by itself past the step limit, in stretches of `AgentEngine.defaultMaxSteps`, while the task plan moves
/// forward (`PlanProgress`); and what the turn says about it, to the model and to the user.
enum AutoContinue {
    /// Preference key of the switch in Ajustes (on by default).
    static let settingKey = "continueLongTasks"
    /// Stretches one request may run, the first one included (about 300 steps): enough for a long task that keeps
    /// moving to finish without "continua", short enough that a task that only seems to move pauses within the hour.
    static let maxStretches = 3

    /// What the model reads before the next stretch, after the progress record. Only appended, like the step warning.
    static func nudge(stretch: Int, of limit: Int, steps: Int) -> String {
        let after = stretch < limit ? " Another stretch follows only if the plan keeps moving."
            : " This is the last one: end it with a summary of what is done and what is left."
        return "[Orb] Stretch \(stretch) of \(limit): the plan moved forward, so the work goes on without the user saying "
            + "\"continua\". Up to \(steps) more steps.\(after) Pick up at the next open step of the plan (record above) "
            + "and keep task_plan current: only steps done with real work count."
    }

    /// The notice in the chat when a stretch starts by itself.
    static func notice(stretch: Int, of limit: Int) -> String {
        "O plano avançou: sigo sem pedir “continua” (trecho \(stretch) de \(limit))."
    }

    /// The line of the plan in the chat while a stretch after the first runs.
    static func stripLabel(stretch: Int, of limit: Int) -> String { "Continuando sozinho · trecho \(stretch) de \(limit)" }

    /// The pause when the plan did not move forward in a whole stretch.
    static func stalledNotice(after steps: Int) -> String {
        "Pausei: o plano não avançou nos últimos \(steps) passos." + AgentEngine.continueHint
    }

    /// The pause after the last stretch the request may run.
    static func cappedNotice(stretches: Int) -> String {
        "Pausei depois de \(stretches) trechos seguidos." + AgentEngine.continueHint
    }

    /// The step warning when the turn may go on in another stretch: the plan decides, so the model is told to keep it current.
    static func stepWarning(remaining: Int) -> String {
        "[Orb: restam \(remaining) passos neste trecho. Atualize o task_plan com o que concluiu: se o plano avançou com trabalho "
            + "feito, a tarefa segue em outro trecho sem pedir “continua”; se não, ela pausa. Termine com um resumo do que fez e do que falta]"
    }

    /// The closing reminder: the reply ends the turn while steps of the plan are still open.
    static func reminder(open steps: [Int]) -> String {
        let list = steps.map(String.init).joined(separator: ", ")
        return "Before you finish: step\(steps.count == 1 ? "" : "s") \(list) of your task plan \(steps.count == 1 ? "is" : "are") "
            + "still open. Go on with \(steps.count == 1 ? "it" : "them") now; or mark what you cannot do as blocked, with the "
            + "reason (task_plan update); or tell the user plainly why you stop here."
    }

    /// One line in the app's log (standard error), for measuring how the plan steers long tasks. Nothing leaves the Mac.
    @Sendable static func writeLog(_ line: String) {
        FileHandle.standardError.write(Data(("[plano] " + line + "\n").utf8))
    }

    /// A message the user sent during the task that asks it to stop ("para", "pode parar", "chega"): nothing goes on by
    /// itself after it, neither the closing reminder nor another stretch. Only what the user typed counts: what the app
    /// adds to a message (a picture's note, an attachment's text) comes after a blank line.
    static func asksToStop(_ text: String) -> Bool {
        let typed = text.components(separatedBy: "\n\n").first ?? text
        return typed.range(of: stopRequest, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let stopRequest = #"^\s*(pode |por favor,? |favor )?(para|pare|parar|pausa|pause|chega|cancela|cancele|interromp[ae]"#
        + #"|stop|n[ãa]o (continue|precisa continuar|siga))\b[\s.!]*$"#
}

/// Which stretch of its allowance a turn runs (`TurnEvent.stretch`).
struct TurnStretch: Equatable, Sendable {
    var number: Int
    var limit: Int

    /// "Continuando sozinho · trecho 2 de 3" while a stretch after the first runs.
    var label: String? { number > 1 ? AutoContinue.stripLabel(stretch: number, of: limit) : nil }
}

extension TaskPlan {
    /// The numbers of the steps still to do (pending or in progress); blocked ones wait for something else.
    var openSteps: [Int] { steps.indices.filter { [.pending, .inProgress].contains(steps[$0].state) }.map { $0 + 1 } }
}
