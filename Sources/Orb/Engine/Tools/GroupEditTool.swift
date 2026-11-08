import Foundation

/// Lets an Orb reorganize the user's groups on its own: members, orchestrator, name, objective, and deleting. The app does the
/// work (`DelegationHub.editGroup`), reached through the same bridge as `orbs`. What cannot be undone (deleting a group, or taking out
/// the member that would dissolve it) waits for the user's card first (`ToolContext.confirm`).
struct GroupEditTool: AgentTool {
    static let name = "group_edit"
    static let edits = ["add", "remove", "orchestrator", "rename", "objective", "delete"]

    let spec = ToolSpec(
        name: GroupEditTool.name,
        description: """
        Change one of the user's groups: add or remove a member, set the orchestrator, rename it, set its objective, or delete it \
        (the user confirms deleting). Use it whenever it helps the user's work.
        """,
        parameters: .schema([
            "group": .property("string", "The group's name."),
            "edit": .object(["type": .string("string"), "enum": .array(GroupEditTool.edits.map(JSONValue.string))]),
            "orb": .property("string", "For add, remove, orchestrator."),
            "name": .property("string", "For rename."),
            "objective": .property("string", "For objective."),
        ], required: ["group", "edit"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// It changes the user's groups: sensitive, covered by the turn's grant like `group_create` (refused in Só leitura).
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Organizando o grupo", arguments["group"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let orbs = context.orbs, case .object(var fields) = arguments else {
            throw ToolError("Editar grupos não está disponível agora.")
        }
        // The app checks the edit first and says whether it needs the user; asking happens here, where the turn's card can be shown.
        fields["action"] = .string("edit_group_plan")
        let needed = try await orbs(.object(fields))
        if !needed.isEmpty {
            guard let confirm = context.confirm else {
                throw ToolError("This needs the user's confirmation and none can be asked here: tell the user in your reply.")
            }
            guard await confirm("Confirmar mudança no grupo", needed) else {
                return "The user did not confirm. Nothing changed."
            }
            fields["confirmed"] = .bool(true)
        }
        fields["action"] = .string("edit_group")
        return try await orbs(.object(fields))
    }
}
