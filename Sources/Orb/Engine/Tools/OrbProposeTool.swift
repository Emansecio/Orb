import Foundation

/// Lets an Orb propose a new Orb. The tool opens no permission card of its own: the engine shows the creation card
/// (`ToolContext.proposeOrb`) and nothing exists until the person accepts.
struct OrbProposeTool: AgentTool {
    static let name = "orb_propose"
    static let instructionsLimit = 1_500
    static let looks = ["color", "eyes", "mouth", "brows", "cheeks", "mustache", "hair", "accessories"]

    let spec = ToolSpec(
        name: OrbProposeTool.name,
        description: """
        Propose a new Orb for the user to approve. Shows them a card; nothing exists until they accept. The new Orb inherits \
        your model and never gets more access than you; it gets its own folder and no connectors.
        """,
        parameters: .schema([
            "name": .property("string"),
            "role": .property("string", "One line."),
            "instructions": .property("string", "How it should work, up to \(OrbProposeTool.instructionsLimit) characters."),
            "capabilities": .object(["type": .string("array"),
                                     "items": .object(["type": .string("string"),
                                                       "enum": .array(["terminal", "browser", "computerUse"].map(JSONValue.string))])]),
            "look": JSONValue.schema(Dictionary(uniqueKeysWithValues: OrbProposeTool.looks.map { key in
                (key, key == "accessories" ? JSONValue.object(["type": .string("array"), "items": .property("string")])
                    : JSONValue.property("string"))
            })),
            "reason": .property("string", "Why, in one sentence."),
        ], required: ["name", "role", "instructions"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// Safe for the permission check: the person's own card is the approval, and it opens even in "Sem pedir permissão".
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Propondo um Orb", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let support = context.orbCreation, let propose = context.proposeOrb else {
            throw ToolError("You cannot propose an Orb here: only in your own chat with the user, not in a routine, a request from another Orb or a group.")
        }
        if let refusal = OrbProposal.refusal(creatorMode: support.creator.permissionMode, createdByCreator: support.createdByCreator,
                                             createdTotal: support.createdTotal) {
            throw ToolError(refusal)
        }
        guard !OrbProposal.clippedName(arguments["name"]?.string ?? "").isEmpty else { throw ToolError("Give the Orb a name.") }
        guard !OrbProposal.cleanInstructions(arguments["instructions"]?.string ?? "").isEmpty else {
            throw ToolError("Say in instructions how the Orb should work.")
        }
        let proposal = OrbProposal.make(from: support.creator, args: arguments, existingNames: support.existingNames)
        let outcome = await propose(proposal)
        if case .failed(let reason) = outcome { throw ToolError(reason) }
        return outcome.modelText
    }
}
