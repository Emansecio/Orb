import Foundation

/// Lets an Orb delete another Orb. It always waits for the user's card (`ToolContext.confirm`); the app checks the request first
/// (`DelegationHub`, same bridge as `group_edit`) and deletes only after the card says yes.
struct OrbDeleteTool: AgentTool {
    static let name = "orb_delete"

    let spec = ToolSpec(
        name: OrbDeleteTool.name,
        description: "Delete another Orb of the user's (never yourself). The user confirms first; its chat, memory and routines are lost.",
        parameters: .schema([
            "name": .property("string", "The Orb's whole name."),
            "reason": .property("string", "Why, in one sentence."),
        ], required: ["name"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// It changes the user's Orbs: sensitive, covered by the turn's grant like `group_edit` (refused in Só leitura).
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Propondo apagar um Orb", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let orbs = context.orbs, case .object(var fields) = arguments else {
            throw ToolError("Deleting Orbs is not available now.")
        }
        // Only the user's card below may confirm, and only the Orb the app checked: whatever the model sent is dropped.
        for key in ConfirmedEdit.reservedKeys { fields[key] = nil }
        fields["action"] = .string("delete_orb_plan")
        let plan = ConfirmedEdit(try await orbs(.object(fields)))
        guard let confirm = context.confirm else {
            // Nobody watches this turn: the user is asked in the chat instead, and the turn goes on.
            guard context.unattended else {
                throw ToolError("This needs the user's confirmation and none can be asked here: tell the user in your reply.")
            }
            fields["action"] = .string("delete_orb_later")
            return try await orbs(.object(fields))
        }
        guard await confirm("Apagar um Orb", plan.confirmation ?? "") else { return "The user did not confirm. Nothing was deleted." }
        fields["action"] = .string("delete_orb")
        fields["confirmed"] = .bool(true)
        plan.bind(&fields)
        return try await orbs(.object(fields))
    }
}
