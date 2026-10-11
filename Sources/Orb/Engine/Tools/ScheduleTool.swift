import Foundation

/// Carries out a call of the `schedule` tool for the Orb that made it. The routines belong to the app, so the app does
/// the work (`AppModel.schedule`): the engine calls it directly.
typealias ScheduleHandler = @Sendable (JSONValue) async throws -> String

/// One call of `schedule`, checked: what was asked and, for a new task, when it runs.
enum ScheduleCommand: Equatable {
    case create(name: String, prompt: String, schedule: Schedule)
    case list
    case setEnabled(String, Bool)
    case delete(String)

    static let promptLimit = 4_000
    static let nameLimit = 80

    init(_ arguments: JSONValue) throws {
        let action = arguments["action"]?.string?.lowercased()
        switch action {
        case "create":
            let prompt = try arguments.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.count <= Self.promptLimit else {
                throw ToolError("O prompt precisa ter de 1 a \(Self.promptLimit) caracteres.")
            }
            let name = RoutineText.resolvedName(MemoryText.flatten(arguments["name"]?.string ?? ""), prompt: prompt)
            self = .create(name: String(name.prefix(Self.nameLimit)), prompt: prompt, schedule: try Self.schedule(arguments["when"]))
        case "list":
            self = .list
        case "pause", "resume":
            self = .setEnabled(try Self.taskName(arguments), action == "resume")
        case "delete":
            self = .delete(try Self.taskName(arguments))
        default:
            throw ToolError("\"action\" deve ser create, list, pause, resume ou delete.")
        }
    }

    private static func taskName(_ arguments: JSONValue) throws -> String {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolError("Faltou o argumento \"name\".") }
        return name
    }

    private static func schedule(_ when: JSONValue?) throws -> Schedule {
        guard let when, let kind = when["kind"]?.string else {
            throw ToolError("Faltou \"when\", com \"kind\": daily, weekly, every_minutes ou every_hours.")
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
        default:
            throw ToolError("\"kind\" deve ser daily, weekly, every_minutes ou every_hours.")
        }
    }
}

/// Lets the Orb schedule tasks that repeat on their own (a task is a routine of the Orb, see `Routine`).
struct ScheduleTool: AgentTool {
    let spec = ToolSpec(
        name: "schedule",
        description: """
        Your own recurring tasks (routines), run by themselves while the app is open. create: prompt is what to do on \
        each run, self-contained (nobody answers during a run). pause, resume and delete take the name. At most 20 \
        tasks, 15 minutes or more apart; a run cannot create tasks.
        """,
        parameters: .schema([
            "action": .object(["type": .string("string"), "enum": .array(["create", "list", "pause", "resume", "delete"].map(JSONValue.string))]),
            "name": .property("string"),
            "prompt": .property("string"),
            "when": JSONValue.schema([
                "kind": .property("string", "daily, weekly, every_minutes or every_hours"),
                "hour": .property("integer"),
                "minute": .property("integer"),
                "weekday": .property("integer", "1 = Sunday"),
                "n": .property("integer", "minutes 15-720, hours 1-24"),
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
        case .create(let name, let prompt, let schedule)?:
            return ("Agendando tarefa", "“\(name)” · \(schedule.label) · " + MemoryText.clip(MemoryText.flatten(prompt), 400))
        case .list?: return ("Listando tarefas agendadas", "")
        case .setEnabled(let name, let on)?: return (on ? "Retomando tarefa agendada" : "Pausando tarefa agendada", name)
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
