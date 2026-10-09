import Foundation

struct RunCommandTool: AgentTool {
    static let defaultTimeout = 120
    static let maxTimeout = 600
    static let outputLimit = 20_000

    let spec = ToolSpec(
        name: "run_command",
        description: """
        Run a shell command as the user's own Terminal would (their PATH); returns \
        the exit code and combined stdout/stderr. For git, builds, scripts and anything without a dedicated \
        tool. Non-interactive (stdin is empty).
        Each call is a fresh shell: cd, export and aliases do NOT persist; use cwd or chain steps (cd x && make).
        Killed after timeout_seconds (default 120, max 600). Output over ~20 KB keeps its start and end; the \
        full text is saved to the file named at the end (read_file or grep it, do not rerun).
        For servers and watchers pass background: true: you get a job id and the first output; then job_output, \
        job_list, job_stop. A plain `cmd &` is untracked.
        """,
        parameters: .schema([
            "command": .property("string"),
            "cwd": .property("string", "Directory to run in (default: the working directory)."),
            "timeout_seconds": .property("integer", "Default 120, max 600; not with background."),
            "background": .property("boolean", "Leave it running and return at once (servers, watchers)."),
        ], required: ["command"]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        (arguments["background"]?.bool == true ? "Rodando em segundo plano" : "Rodando no Terminal",
         arguments["command"]?.string ?? "")
    }

    /// The approval card also says where the command runs when that is not the Orb's folder: `rm *.log` or `make install`
    /// mean something else in `/` than in the project.
    func summary(_ arguments: JSONValue, context: ToolContext) -> (title: String, detail: String) {
        var result = summary(arguments)
        if let cwd = arguments.nonEmptyString("cwd") {
            let directory = context.url(for: cwd).standardizedFileURL
            if directory.path != context.workingDirectory.standardizedFileURL.path {
                result.detail += "\n\nem \(Self.display(directory))"
            }
        }
        return result
    }

    /// The path with the home folder written as "~".
    static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if url.path == home { return "~" }
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
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
        let spill = Self.spillFile(context: context)
        let result = try await ProcessRunner.run(shell.shell, shell.arguments(for: command), directory: directory, environment: shell.environment,
                                                 timeout: .seconds(seconds), outputLimit: Self.outputLimit, spillTo: spill)
        var output = result.output.isEmpty ? "(sem saída)" : result.output
        if !shell.isFromUserShell {
            output += "\n[aviso: não consegui ler o PATH do Terminal; rodei com o perfil de login. Se um programa não foi "
                + "encontrado, ele pode estar instalado: tente de novo daqui a pouco]"
        }
        if result.isBinary {
            output = "[saída binária de \(ByteCountFormatter.string(fromByteCount: Int64(result.totalBytes), countStyle: .file)) omitida; "
                + "redirecione para um arquivo, ou use file, strings ou xxd]"
        } else if let file = result.fullOutputFile {
            // The same shape as the note of `ToolOutputCap`, so that shortening the conversation later keeps it whole.
            let cut = result.fullOutputCut
                ? ", file cut at \(ByteCountFormatter.string(fromByteCount: Int64(StreamCapture.maxSpillBytes), countStyle: .file))" : ""
            output += ContextText.savedNoteOpen + "\(file.path) (\(result.totalLines) lines, "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(result.totalBytes), countStyle: .file))\(cut)); "
                + "read it with read_file (offset/limit) or grep instead of running the command again]"
        }
        if result.leftoversAlive || result.leftOutputOpen {
            output += "\n[aviso: o comando deixou processos rodando (iniciados com &). O Orb não os acompanha nem os encerra"
                + (result.leftOutputOpen ? ", e um deles pode morrer ao escrever na saída que já foi fechada" : "")
                + "; para servidores e watchers use background: true, que dá um id para job_output e job_stop]"
        }
        if result.timedOut {
            return output + "\n[tempo esgotado após \(seconds) s; o processo foi encerrado. Para comandos longos use timeout_seconds "
                + "(máx. \(Self.maxTimeout)) ou background: true com job_output]"
        }
        if let signal = result.signal {
            return "Código de saída: encerrado pelo sinal \(Signals.describe(signal))\n\(output)"
        }
        return "Código de saída: \(result.status)\(Signals.hint(forExitCode: result.status))\n\(output)"
    }

    /// Where the whole output goes if it outgrows the limit: the Orb's folder of saved outputs, next to the files
    /// `ToolOutputCap` writes (and tidied with them).
    static func spillFile(context: ToolContext) -> URL {
        let folder = (context.outputsDirectory ?? ToolOutputCap.defaultDirectory).appending(path: (context.botID ?? UUID()).uuidString)
        return folder.appending(path: "comando-\(UUID().uuidString.prefix(8).lowercased()).txt")
    }

    private func startInBackground(_ command: String, directory: URL, shell: ShellEnvironment.Resolved,
                                   context: ToolContext) async throws -> String {
        guard let jobs = context.jobs, let botID = context.botID else {
            throw ToolError("Processos em segundo plano não estão disponíveis aqui; rode sem background.")
        }
        let started = try await jobs.start(botID: botID, command: command, directory: directory, shell: shell)
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
        description: "List the background processes, running or finished.",
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
        description: "Stop a background process and all it launched.",
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
