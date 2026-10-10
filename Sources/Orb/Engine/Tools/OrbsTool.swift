import Foundation

/// Lets an Orb hand work to the user's other Orbs (the runtime is `DelegationHub`; `run` waits for the package that wires it).
/// `ask` returns at once and the answer arrives later as a message that wakes the Orb.
struct OrbsTool: AgentTool {
    static let actions = ["list", "ask", "tell"]
    static let messageLimit = DelegationLimits.messageLimit

    let spec = ToolSpec(
        name: "orbs",
        description: """
        Work with the user's other Orbs. list: teammates and whether each is free. ask: send a request; returns at once and \
        the answer arrives later as a message that wakes you. tell: send information, no answer expected. A teammate has not \
        seen this chat: write self-contained messages.
        """,
        parameters: .schema([
            "action": .object(["type": .string("string"), "enum": .array(actions.map(JSONValue.string))]),
            "to": .property("string", "Teammate name."),
            "message": .property("string", "Up to \(DelegationLimits.messageLimit) characters."),
        ], required: ["action"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// Listing only reads. Asking and telling reach another Orb, so they are sensitive (the turn's grant covers them, see
    /// `PermissionFamily.delegation`); a missing or unknown action is the tool as a whole being asked about: sensitive.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        arguments["action"]?.string?.lowercased() == "list" ? .safe : .sensitive
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let target = arguments["to"]?.string ?? ""
        let message = MemoryText.clip(MemoryText.flatten(arguments["message"]?.string ?? ""), 120)
        switch arguments["action"]?.string?.lowercased() {
        case "ask": return ("Falando com \(target)", message)
        case "tell": return ("Avisando \(target)", message)
        case "list": return ("Vendo o time", "")
        default: return ("Falando com outro Orb", message)
        }
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let orbs = context.orbs else { throw ToolError("Falar com outros Orbs não está disponível agora.") }
        return try await orbs(arguments)
    }
}

extension ToolBox {
    /// The tools that exist only with more than one Orb (`MultiOrbOffering` says which an Orb is offered). Not in `all`, so
    /// an Orb that has none of them pays nothing for them.
    static let multiOrbTools: [any AgentTool] = [OrbsTool(), OrbProposeTool()] + groupMemoryTools
}
