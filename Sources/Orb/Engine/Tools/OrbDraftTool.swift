import Foundation

/// The creation assistant's only tool: it fills in the draft the person watches (`OrbDraft`). It never reaches the model of a
/// normal Orb (`ToolBox.offered` does not list it); `run` waits for the package that wires it.
struct OrbDraftTool: AgentTool {
    static let name = "orb_draft"

    let spec = ToolSpec(
        name: OrbDraftTool.name,
        description: """
        Update the live preview of the Orb being created with what you know so far. Send only what changed. ready=true when \
        the draft is complete; the user presses Criar.
        """,
        parameters: .schema([
            "name": .property("string"),
            "role": .property("string", "One line."),
            "instructions": .property("string", "In the second person, up to 1500 characters."),
            "capabilities": .object(["type": .string("array"),
                                     "items": .object(["type": .string("string"),
                                                       "enum": .array(["terminal", "browser", "computerUse"].map(JSONValue.string))])]),
            "mode": .object(["type": .string("string"), "enum": .array(["ask", "auto", "readOnly"].map(JSONValue.string))]),
            "ready": .property("boolean"),
        ]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Montando o Orb", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let draft = context.draft else { throw ToolError("O assistente de criação não está disponível agora.") }
        return try await draft(arguments)
    }
}

extension ToolBox {
    /// The creation assistant's list (never part of `all` or of `offered`).
    static let wizardTools: [any AgentTool] = [OrbDraftTool()]
}
