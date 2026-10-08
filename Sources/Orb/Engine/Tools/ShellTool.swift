import Foundation

struct RunCommandTool: AgentTool {
    let spec = ToolSpec(
        name: "run_command",
        description: """
        Run a shell command on the user's Mac with zsh (login shell) and return its exit code and combined \
        stdout/stderr. Use it for git, builds, scripts, package managers and anything without a dedicated tool. \
        Commands are non-interactive (stdin is empty) and are killed when the timeout expires; long output is \
        cut in the middle.
        """,
        parameters: .schema([
            "command": .property("string", "The command line to run."),
            "cwd": .property("string", "Directory to run in, absolute or relative to the working directory. Defaults to the working directory."),
            "timeout_seconds": .property("integer", "Seconds before the command is killed (default 120, max 600)."),
        ], required: ["command"]))

    var kind: ToolCall.Kind { .shell }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Rodando no Terminal", arguments["command"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let command = try arguments.requiredString("command")
        let directory = arguments.nonEmptyString("cwd").map(context.url(for:)) ?? context.workingDirectory
        guard directory.isExistingDirectory else { throw ToolError("Pasta não encontrada: \(directory.path)") }
        let seconds = arguments.integer("timeout_seconds", default: 120, in: 1...600)

        let result = try await ProcessRunner.run("/bin/zsh", ["-lc", command], directory: directory, timeout: .seconds(seconds))
        let output = result.output.isEmpty ? "(sem saída)" : result.output
        if result.timedOut {
            return output + "\n[tempo esgotado após \(seconds) s; o processo foi encerrado]"
        }
        return "Código de saída: \(result.status)\n\(output)"
    }
}
