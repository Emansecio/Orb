import Foundation

/// Carries out a call of the `schedule` tool for the Orb that made it. The routines belong to the app, so the app does
/// the work (`AppModel.schedule`): the engine calls it directly.
typealias ScheduleHandler = @Sendable (JSONValue) async throws -> String

/// One call of `schedule`, checked: what was asked and, for a new task, when it runs.
enum ScheduleCommand: Equatable {
    /// `goal`: what success looks like, for a task that works toward one (`RoutineGoal`). `enabled`: false creates it
    /// paused. `runNow`: its first run starts at once (as soon as the Orb is free), not at the first scheduled time.
    case create(name: String, prompt: String, schedule: Schedule, goal: String? = nil, enabled: Bool = true, runNow: Bool = false)
    /// Changes what is given of an existing task and keeps the rest. `goal` "" removes the goal.
    case update(name: String, prompt: String? = nil, schedule: Schedule? = nil, goal: String? = nil)
    case list
    case setEnabled(String, Bool)
    /// Runs the task once now (as soon as the Orb is free), like the Rotinas page's button.
    case run(String)
    case delete(String)

    static let promptLimit = 4_000
    static let nameLimit = 80

    init(_ arguments: JSONValue) throws {
        let action = arguments["action"]?.string?.lowercased()
        switch action {
        case "create":
            let prompt = try Self.prompt(try arguments.requiredString("prompt"))
            let name = RoutineText.resolvedName(MemoryText.flatten(arguments["name"]?.string ?? ""), prompt: prompt)
            let goal = Self.goal(arguments["goal"]?.string ?? "")
            let runNow = arguments["run_now"]?.bool ?? false
            let enabled = arguments["enabled"]?.bool ?? true
            guard enabled || !runNow else { throw ToolError("Uma tarefa criada pausada não roda agora: use enabled ou run_now, não os dois.") }
            self = .create(name: String(name.prefix(Self.nameLimit)), prompt: prompt, schedule: try Self.schedule(arguments["when"]),
                           goal: goal.isEmpty ? nil : goal, enabled: enabled, runNow: runNow)
        case "update":
            let name = try Self.taskName(arguments)
            let prompt = try arguments["prompt"]?.string.map(Self.prompt)
            let schedule = try arguments["when"].map { try Self.schedule($0) }
            let goal = arguments["goal"]?.string.map(Self.goal)
            guard prompt != nil || schedule != nil || goal != nil else {
                throw ToolError("Para update, diga o que muda: prompt, when ou goal (goal vazio tira a meta).")
            }
            self = .update(name: name, prompt: prompt, schedule: schedule, goal: goal)
        case "list":
            self = .list
        case "pause", "resume":
            self = .setEnabled(try Self.taskName(arguments), action == "resume")
        case "run":
            self = .run(try Self.taskName(arguments))
        case "delete":
            self = .delete(try Self.taskName(arguments))
        default:
            throw ToolError("\"action\" deve ser create, update, list, pause, resume, run ou delete.")
        }
    }

    private static func prompt(_ text: String) throws -> String {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= promptLimit else {
            throw ToolError("O prompt precisa ter de 1 a \(promptLimit) caracteres.")
        }
        return prompt
    }

    private static func goal(_ text: String) -> String { MemoryText.clip(MemoryText.flatten(text), RoutineGoal.targetLimit) }

    private static func taskName(_ arguments: JSONValue) throws -> String {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolError("Faltou o argumento \"name\".") }
        return name
    }

    private static func schedule(_ when: JSONValue?) throws -> Schedule {
        guard let when, let kind = when["kind"]?.string else {
            throw ToolError("Faltou \"when\", com \"kind\": \(kinds).")
        }
        func number(_ key: String, _ range: ClosedRange<Int>, default value: Int? = nil, why: String = "") throws -> Int {
            let given = when[key]?.int ?? when[key]?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? value
            guard let given, range.contains(given) else {
                throw ToolError("\"\(key)\" deve ser de \(range.lowerBound) a \(range.upperBound).\(why)")
            }
            return given
        }
        switch kind.lowercased() {
        case "daily":
            return .daily(hour: try number("hour", 0...23), minute: try number("minute", 0...59, default: 0))
        case "weekly":
            return .weekly(weekday: try number("weekday", 1...7), hour: try number("hour", 0...23),
                           minute: try number("minute", 0...59, default: 0))
        case "every_minutes":
            let why = " Não agendo tarefas com intervalo menor que \(Schedule.minuteRange.lowerBound) minutos."
            return .everyMinutes(try number("n", Schedule.minuteRange, why: why))
        case "every_hours":
            return .everyHours(try number("n", 1...24))
        case "once":
            guard let text = when["at"]?.string, let moment = moment(text) else {
                throw ToolError("Para \"once\", \"at\" deve ser data e hora, como 2026-10-14T09:00 (hora do Mac) ou com fuso.")
            }
            return try checked(.once(moment))
        case "cron":
            let expression = (when["expression"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            let zone = (when["time_zone"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            return try checked(.cron(expression: expression, timeZone: zone.isEmpty ? nil : zone))
        default:
            throw ToolError("\"kind\" deve ser \(kinds).")
        }
    }

    private static let kinds = "daily, weekly, every_minutes, every_hours, once ou cron"

    private static func checked(_ schedule: Schedule) throws -> Schedule {
        if let problem = schedule.problem() { throw ToolError(problem) }
        return schedule
    }

    /// "2026-10-14T09:00" on the Mac's clock, or a full ISO 8601 moment with its offset ("…T09:00:00-03:00", "…Z").
    static func moment(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

/// Lets the Orb schedule tasks that repeat on their own (a task is a routine of the Orb, see `Routine`).
struct ScheduleTool: AgentTool {
    /// What `schedule` is in a run nobody watches (a routine's, a request from another Orb, a group's turn): the app refuses
    /// create, update, resume, run and delete there (`AppModel.sideRunRefusal`), so only list and pause are described, in a
    /// fifth of the characters (docs/REVISAO-TOKENS-PROMPT-2026-10-17.md). The same tool answers either way.
    static let sideRunSpec = ToolSpec(
        name: "schedule",
        description: """
        Your scheduled tasks (routines). From a run you can only list them and pause one (name); to create, change or \
        delete one, propose it in your final message and the user does it in the chat.
        """,
        parameters: .schema([
            "action": .object(["type": .string("string"), "enum": .array(["list", "pause"].map(JSONValue.string))]),
            "name": .property("string"),
        ], required: ["action"]))

    /// `sideRun`: the short description for a run nobody watches (`ToolBox.offered`).
    init(sideRun: Bool = false) {
        spec = sideRun ? Self.sideRunSpec : Self.fullSpec
    }

    let spec: ToolSpec

    private static let fullSpec = ToolSpec(
        name: "schedule",
        description: """
        Your scheduled tasks (routines), run while the app is open. create: prompt is what each run does, self-contained \
        (nobody answers in a run); goal (optional): what success looks like, pausing it once met. update: the \
        name and what changes (goal "" removes it); pause, resume, run (once now), delete: the name. At most 20 tasks, \
        15+ minutes apart; a run can only pause tasks. When the user describes something to do regularly or later, \
        propose it with ask_user (name, when, what) and create it once they agree, unless they asked for it already.
        """,
        parameters: .schema([
            "action": .object(["type": .string("string"),
                               "enum": .array(["create", "update", "list", "pause", "resume", "run", "delete"].map(JSONValue.string))]),
            "name": .property("string"),
            "prompt": .property("string"),
            "goal": .property("string"),
            "enabled": .property("boolean", "create: false = paused"),
            "run_now": .property("boolean", "create: true = also run once now"),
            "when": JSONValue.schema([
                "kind": .property("string", "daily, weekly, every_minutes, every_hours, once or cron"),
                "hour": .property("integer"),
                "minute": .property("integer"),
                "weekday": .property("integer", "1 = Sunday"),
                "n": .property("integer", "minutes 15-720, hours 1-24"),
                "at": .property("string", "once: 2026-10-14T09:00, Mac's clock"),
                "expression": .property("string", "cron: minute hour day month weekday"),
                "time_zone": .property("string", "cron: IANA name, else Mac's"),
            ], required: ["kind"]),
        ], required: ["action"]))

    var kind: ToolCall.Kind { .schedule }
    var capability: Capability? { nil }

    /// Listing only reads; creating, pausing, resuming and deleting change what the Orb does on its own later. A call
    /// that names an action but does not parse changes nothing and goes straight to its error, with no card to approve
    /// first. Without an action it is the tool as a whole being asked about: sensitive.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        guard arguments["action"] != nil else { return .sensitive }
        switch try? ScheduleCommand(arguments) {
        case .list?, nil: return .safe
        default: return .sensitive
        }
    }

    /// What the card says before the task exists, on one line: its name, when it runs and what it will be asked to do.
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch try? ScheduleCommand(arguments) {
        case .create(let name, let prompt, let schedule, let goal, let enabled, let runNow)?:
            return ("Agendando tarefa", "“\(name)” · \(schedule.label) · " + MemoryText.clip(MemoryText.flatten(prompt), 400)
                + (goal.map { " · Meta: " + MemoryText.clip($0, 200) } ?? "")
                + (enabled ? "" : " · Criada pausada") + (runNow ? " · Roda agora uma vez" : ""))
        case .update(let name, let prompt, let schedule, let goal)?:
            let changes = [schedule.map(\.label), prompt.map { "Faz: " + MemoryText.clip(MemoryText.flatten($0), 300) },
                           goal.map { $0.isEmpty ? "Sem meta" : "Meta: " + MemoryText.clip($0, 200) }].compactMap { $0 }
            return ("Alterando tarefa agendada", "“\(name)” · " + changes.joined(separator: " · "))
        case .list?: return ("Listando tarefas agendadas", "")
        case .setEnabled(let name, let on)?: return (on ? "Retomando tarefa agendada" : "Pausando tarefa agendada", name)
        case .run(let name)?: return ("Rodando tarefa agendada agora", name)
        case .delete(let name)?: return ("Apagando tarefa agendada", name)
        case nil: return ("Agendando tarefa", "")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let schedule = context.schedule else { throw ToolError("Agendar tarefas não está disponível agora.") }
        return try await schedule(arguments)
    }
}

extension ToolBox {
    static let scheduleTools: [any AgentTool] = [ScheduleTool()]
}
