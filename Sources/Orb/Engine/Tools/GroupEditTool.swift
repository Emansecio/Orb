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
        // Only the user's card below may confirm, and only the target the app checked: whatever the model sent is dropped.
        for key in ConfirmedEdit.reservedKeys { fields[key] = nil }
        // The app checks the edit first and says whether it needs the user; asking happens here, where the turn's card can be shown.
        fields["action"] = .string("edit_group_plan")
        let plan = ConfirmedEdit(try await orbs(.object(fields)))
        if let needed = plan.confirmation {
            guard let confirm = context.confirm else {
                // Nobody watches this turn: the user is asked in the chat instead, and the turn goes on.
                guard context.unattended else {
                    throw ToolError("This needs the user's confirmation and none can be asked here: tell the user in your reply.")
                }
                fields["action"] = .string("edit_group_later")
                return try await orbs(.object(fields))
            }
            guard await confirm("Confirmar mudança no grupo", needed) else {
                return "The user did not confirm. Nothing changed."
            }
            fields["confirmed"] = .bool(true)
            plan.bind(&fields)
        }
        fields["action"] = .string("edit_group")
        return try await orbs(.object(fields))
    }
}

/// What the app's check of a deletion (`edit_group_plan`, `delete_orb_plan`) hands the tool: the text of the user's card, and the
/// ids of what it is about. After the card, the tool sends those ids back (`expect_group`, `expect_orb`): the app does the change
/// only if the names still lead to the same group and Orb, so a rename meanwhile cannot turn the yes into another deletion.
struct ConfirmedEdit {
    /// Keys only the tool writes; the model's are dropped.
    static let reservedKeys = ["confirmed", "expect_group", "expect_orb"]

    var confirmation: String?
    var group: String?
    var orb: String?

    init(_ text: String) {
        let value = JSONValue.parse(text)
        let confirmation = value?["confirmation"]?.string ?? ""
        self.confirmation = confirmation.isEmpty ? nil : confirmation
        group = value?["group"]?.string
        orb = value?["orb"]?.string
    }

    func bind(_ fields: inout [String: JSONValue]) {
        if let group { fields["expect_group"] = .string(group) }
        if let orb { fields["expect_orb"] = .string(orb) }
    }

    /// The bridge's answer to a check: the card's text and the ids.
    static func answer(confirmation: String?, group: UUID?, orb: UUID?) -> String {
        var fields: [String: JSONValue] = ["confirmation": .string(confirmation ?? "")]
        if let group { fields["group"] = .string(group.uuidString) }
        if let orb { fields["orb"] = .string(orb.uuidString) }
        return JSONValue.object(fields).jsonString
    }
}
