import Foundation

struct RunCommandTool: AgentTool {
    static let defaultTimeout = 120
    static let maxTimeout = 600
    static let outputLimit = 20_000

    let spec = ToolSpec(
        name: "run_command",
        description: """
        Run a shell command the way the user's own Terminal would (their PATH and tools such as npm, adb, java) \
        and return the exit code and combined stdout/stderr. For git, builds, scripts and anything without a \
        dedicated tool. Non-interactive (stdin is empty).
        Every call is a fresh shell: cd, export and aliases do NOT persist. Use cwd, and chain related steps in \
        one command (cd x && make).
        Killed after timeout_seconds (default 120, max 600). Output over ~20 KB keeps its start and end.
        For servers and watchers pass background: true: you get a job id and the first output; read it later \
        with job_output, list jobs with job_list, stop one with job_stop. A plain `cmd &` does not survive the \
        call.
        """,
        parameters: .schema([
            "command": .property("string"),
            "cwd": .property("string", "Directory to run in (default: the working directory)."),
            "timeout_seconds": .property("integer", "Seconds before the kill (default 120, max 600); ignored with background."),
            "background": .property("boolean", "Leave it running and return at once (servers, watchers)."),
        ], required: ["command"]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        (arguments["background"]?.bool == true ? "Rodando em segundo plano" : "Rodando no Terminal",
         arguments["command"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let command = try arguments.requiredString("command")
        let directory = arguments.nonEmptyString("cwd").map(context.url(for:)) ?? context.workingDirectory
        guard directory.isExistingDirectory else { throw ToolError("Pasta não encontrada: \(directory.path)") }
        let shell = await context.shell.resolved()

        if arguments["background"]?.bool == true {
            return try await startInBackground(command, directory: directory, shell: shell, context: context)
        }
        let seconds = arguments.integer("timeout_seconds", default: Self.defaultTimeout, in: 1...Self.maxTimeout)
        let result = try await ProcessRunner.run(shell.shell, ["-c", command], directory: directory, environment: shell.environment,
                                                 timeout: .seconds(seconds), outputLimit: Self.outputLimit)
        var output = result.output.isEmpty ? "(sem saída)" : result.output
        if result.leftOutputOpen {
            output += "\n[aviso: um processo iniciado com & ainda segurava a saída e pode ser encerrado ao escrever nela; "
                + "para deixar algo rodando use background: true]"
        }
        if result.timedOut {
            return output + "\n[tempo esgotado após \(seconds) s; o processo foi encerrado]"
        }
        if let signal = result.signal {
            return "Código de saída: encerrado pelo sinal \(Signals.describe(signal))\n\(output)"
        }
        return "Código de saída: \(result.status)\(Signals.hint(forExitCode: result.status))\n\(output)"
    }

    private func startInBackground(_ command: String, directory: URL, shell: ShellEnvironment.Resolved,
                                   context: ToolContext) async throws -> String {
        guard let jobs = context.jobs, let botID = context.botID else {
            throw ToolError("Processos em segundo plano não estão disponíveis aqui; rode sem background.")
        }
        let started = try await jobs.start(botID: botID, command: command, directory: directory, shell: shell.shell,
                                           environment: shell.environment)
        let job = started.job
        let output = started.firstOutput.isEmpty ? "(sem saída ainda)" : started.firstOutput
        return """
        Processo em segundo plano \(job.id): \(job.statusText).
        Log completo: \(job.logPath)
        Primeira saída:
        \(output)

        job_output(id: "\(job.id)") mostra mais, job_stop(id: "\(job.id)") encerra.
        """
    }
}

// MARK: - Background jobs

private extension JSONValue {
    /// The `id` argument; models send it as a string or as a number.
    func jobID() throws -> String {
        if let text = nonEmptyString("id") { return text }
        if let number = self["id"]?.int { return String(number) }
        throw ToolError("Faltou o argumento \"id\". job_list mostra os processos em segundo plano.")
    }
}

private extension ToolContext {
    func backgroundJobs() throws -> (jobs: BackgroundJobs, botID: UUID) {
        guard let jobs, let botID else { throw ToolError("Processos em segundo plano não estão disponíveis aqui.") }
        return (jobs, botID)
    }
}

struct JobOutputTool: AgentTool {
    let spec = ToolSpec(
        name: "job_output",
        description: "Latest output of a background process (run_command with background: true) and whether it still runs.",
        parameters: .schema([
            "id": .property("string"),
            "lines": .property("integer", "Last lines to show (default 50, max 500)."),
        ], required: ["id"]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    /// Reads the log of a job this Orb started itself.
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Lendo a saída do processo", (try? arguments.jobID()) ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let (jobs, botID) = try context.backgroundJobs()
        let lines = arguments.integer("lines", default: 50, in: 1...500)
        let result = try await jobs.output(botID: botID, id: try arguments.jobID(), lines: lines)
        return "Processo \(result.job.id) (\(result.job.statusText)): \(result.job.command)\n"
            + (result.text.isEmpty ? "(sem saída)" : result.text)
    }
}

struct JobListTool: AgentTool {
    let spec = ToolSpec(
        name: "job_list",
        description: "List the background processes (run_command with background: true), running or finished.",
        parameters: .schema([:]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Listando processos em segundo plano", "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let (jobs, botID) = try context.backgroundJobs()
        let all = await jobs.list(botID: botID)
        guard !all.isEmpty else { return "Nenhum processo em segundo plano." }
        return all.map { "\($0.id)  \($0.statusText)  \($0.command)  (em \($0.directory))" }.joined(separator: "\n")
    }
}

struct JobStopTool: AgentTool {
    let spec = ToolSpec(
        name: "job_stop",
        description: "Stop a background process (run_command with background: true) and all it launched.",
        parameters: .schema([
            "id": .property("string"),
        ], required: ["id"]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    /// Only ever reaches jobs this Orb started, which already passed the approval for running the command.
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Parando o processo", (try? arguments.jobID()) ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let (jobs, botID) = try context.backgroundJobs()
        let job = try await jobs.stop(botID: botID, id: try arguments.jobID())
        return "Processo \(job.id) (\(job.statusText)): \(job.command)"
    }
}

extension ToolBox {
    static let shellTools: [any AgentTool] = [RunCommandTool(), JobOutputTool(), JobListTool(), JobStopTool()]
}
