import Foundation

/// Proposal tool used exclusively by the Team Scouter (`Olheiro`) to populate and refine the live Team blueprint.
struct TeamProposalTool: AgentTool {
    static let name = "team_proposal"

    let spec = ToolSpec(
        name: TeamProposalTool.name,
        description: """
        Create or update the live editable Team proposal (name, objective, analysis_summary, scout_note, criteria, stages, members, ready). \
        Include 2 to 8 distinct members by default (up to 12 if requested), one marked is_orchestrator=true and at least one independent reviewer.
        """,
        parameters: .schema([
            "name": .property("string", "Short Team name in pt-BR sentence case."),
            "objective": .property("string", "Clear Mission goal."),
            "analysis_summary": .property("string", "1-2 sentences summarizing what you found in the project folder or idea."),
            "scout_note": .property("string", "Short friendly comment presenting the proposed squad."),
            "criteria": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "stages": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "members": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .property("string"),
                        "role": .property("string", "One crisp responsibility line."),
                        "instructions": .property("string", "Clear directives in second person."),
                        "color": .object([
                            "type": .string("string"),
                            "enum": .array(["indigo", "menta", "sol", "rosa", "grafite", "perola", "noite"].map(JSONValue.string)),
                        ]),
                        "model": .property("string", "Optional provider/model override; empty uses default."),
                        "capabilities": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"),
                                "enum": .array(["terminal", "browser", "computerUse"].map(JSONValue.string)),
                            ]),
                        ]),
                        "is_orchestrator": .property("boolean"),
                    ]),
                    "required": .array(["name", "role"].map(JSONValue.string)),
                ]),
            ]),
            "ready": .property("boolean"),
        ])
    )

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Escalando o time", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let handler = context.teamProposal else {
            throw ToolError("O Olheiro de times não está disponível agora.")
        }
        return try await handler(arguments)
    }
}

extension ToolBox {
    /// Read-only inspection tools + proposal tool reserved for the Team Scouter (`Olheiro`).
    static let teamScouterTools: [any AgentTool] = [
        TeamProposalTool(),
        ReadFileTool(),
        ListDirectoryTool(),
        GlobTool(),
        GrepTool(),
    ]

    static let teamScouterFolderToolNames: Set<String> = [
        TeamProposalTool.name, "read_file", "list_directory", "glob", "grep",
    ]
}
