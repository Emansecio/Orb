import Foundation

/// Lets an Orb create a new Orb. The tool opens no permission card of its own: `ToolContext.proposeOrb` either creates the Orb
/// at once ("Orbs criam Orbs sem perguntar") or shows the creation card, and nothing exists until the person accepts.
struct OrbProposeTool: AgentTool {
    static let name = "orb_propose"
    static let instructionsLimit = 1_500
    static let looks = ["color", "shape", "eyes", "mouth", "brows", "cheeks"]

    let spec = ToolSpec(
        name: OrbProposeTool.name,
        description: """
        Create a new Orb for the user's work. It inherits your model and never more access than you; it gets its own folder and \
        no connectors. If the user must approve, they see a card.
        """,
        parameters: .schema([
            "name": .property("string"),
            "role": .property("string", "One line."),
            "instructions": .property("string", "How it should work, up to \(OrbProposeTool.instructionsLimit) characters."),
            "capabilities": .object(["type": .string("array"),
                                     "description": .string("Only what the role needs: each adds tools to every request. Empty: all of yours."),
                                     "items": .object(["type": .string("string"),
                                                       "enum": .array(["terminal", "browser", "computerUse"].map(JSONValue.string))])]),
            "look": JSONValue.schema(Dictionary(uniqueKeysWithValues: OrbProposeTool.looks.map {
                ($0, $0 == "shape" ? JSONValue.property("string", "Body shape; default circulo.") : JSONValue.property("string"))
            })),
            "reason": .property("string", "Why, in one sentence."),
        ], required: ["name", "role", "instructions"]))

    /// The catalog's ids are Portuguese ("circulo", "pilulas") and cannot be guessed, but they stay out of the schema (it goes
    /// with every request): a wrong look field is answered with its list instead.
    static func lookWarning(_ look: JSONValue?) -> String {
        let ignored = OrbProposal.lookIssues(from: look)
        guard !ignored.isEmpty else { return "" }
        return "\nIgnored unknown look values (shape stays circulo, others random); valid ids: "
            + ignored.map { "\($0): \(lookIDs($0).joined(separator: ", "))" }.joined(separator: "; ") + "."
    }

    /// The catalog's ids for a look field.
    static func lookIDs(_ key: String) -> [String] {
        let category: OrbCategory = switch key {
        case "color": .color
        case "shape": .shape
        case "eyes": .eyes
        case "mouth": .mouth
        case "brows": .brows
        default: .cheeks
        }
        return OrbCatalog.shared.options(category).map(\.id)
    }

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// Safe for the permission check: the person's own card is the approval, and it opens even in "Sem pedir permissão".
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Propondo um Orb", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let support = context.orbCreation, let propose = context.proposeOrb else {
            throw ToolError("You cannot create an Orb here.")
        }
        if let refusal = OrbProposal.refusal(creatorMode: support.creator.permissionMode) { throw ToolError(refusal) }
        guard !OrbProposal.clippedName(arguments["name"]?.string ?? "").isEmpty else { throw ToolError("Give the Orb a name.") }
        guard !OrbProposal.cleanInstructions(arguments["instructions"]?.string ?? "").isEmpty else {
            throw ToolError("Say in instructions how the Orb should work.")
        }
        let proposal = OrbProposal.make(from: support.creator, args: arguments, existingNames: support.existingNames)
        let outcome = await propose(proposal)
        if case .failed(let reason) = outcome { throw ToolError(reason) }
        return outcome.modelText + Self.lookWarning(arguments["look"])
    }
}
