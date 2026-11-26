import Foundation

/// Lightweight coordination tool offered inside autonomous Team turns (`TeamHub.executeTurn`).
/// - `contract`: publishes a shared contract or architectural decision to `TeamBoard` (Block 3) so parallel members see it.
/// - `ask_member`: runs a short, bounded read-only consultation with another Team member without breaking stage isolation.
struct TeamNoteTool: AgentTool {
    static let actions = ["contract", "ask_member"]
    static let maxConsultsPerTurn = 3

    let handler: BridgeHandler

    let spec = ToolSpec(
        name: "team_note",
        description: """
        Coordinate with your Team. contract: publish a shared contract or decision to the live board (title + summary, \
        optionally supersedes to replace older contract titles and files to anchor key paths) so parallel members stay aligned. \
        ask_member: ask another member a short read-only question (up to \(Self.maxConsultsPerTurn) per turn) to clarify an interface or design detail.
        """,
        parameters: .schema([
            "action": .object(["type": .string("string"), "enum": .array(actions.map(JSONValue.string))]),
            "title": .property("string", "contract: short contract or decision title."),
            "summary": .property("string", "contract: concise contract details or interface."),
            "supersedes": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                   "description": .string("contract: optional titles of older contracts replaced by this one.")]),
            "files": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                              "description": .string("contract: optional file paths anchored to this contract (up to 4).")]),
            "to": .property("string", "ask_member: target member name."),
            "question": .property("string", "ask_member: concise question (up to 1200 characters)."),
        ], required: ["action"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        switch arguments["action"]?.string?.lowercased() {
        case "contract":
            let title = MemoryText.clip(MemoryText.flatten(arguments["title"]?.string ?? ""), 80)
            return ("Registrando contrato", title)
        case "ask_member":
            let to = arguments["to"]?.string ?? "colega"
            let q = MemoryText.clip(MemoryText.flatten(arguments["question"]?.string ?? ""), 100)
            return ("Consultando \(to)", q)
        default:
            return ("Coordenando com o time", "")
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let action = arguments["action"]?.string?.lowercased(), Self.actions.contains(action) else {
            throw ToolError("Use action contract or ask_member.")
        }
        return try await handler(arguments)
    }
}
