import Foundation

/// Lets an Orb create a group of the user's Orbs when one would help (always when the user asks). The app does the work
/// (`DelegationHub.createGroup`), reached through the same bridge as `orbs`.
struct GroupCreateTool: AgentTool {
    static let name = "group_create"

    let spec = ToolSpec(
        name: GroupCreateTool.name,
        description: """
        Create a group of the user's Orbs when one would help the user's work. A group has a shared thread on its own \
        screen and an orchestrator that hands out the work of each request. If you are a member, send it the first \
        request with orbs ask, the group's name as to. Software: add a builder and a reviewer.
        """,
        parameters: .schema([
            "name": .property("string", "Short, like a project's: Lançamento."),
            "members": .object(["type": .string("array"), "items": .property("string"),
                                "description": .string("The Orbs' names, \(OrbGroup.memberLimits.lowerBound) to \(OrbGroup.memberLimits.upperBound). You are in it only if you name yourself.")]),
            "orchestrator": .property("string", "One of the members. Default: the first."),
            "objective": .property("string", "What the group should deliver, if the user said."),
            "folder": .property("string", "Project folder; in git, a branch per member."),
        ], required: ["name", "members"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// It changes the user's groups: sensitive, covered by the turn's grant like `orbs ask` (refused in Só leitura).
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Criando um grupo", arguments["name"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let orbs = context.orbs, case .object(var fields) = arguments else {
            throw ToolError("Criar grupos não está disponível agora.")
        }
        fields["action"] = .string("create_group")
        return try await orbs(.object(fields))
    }
}
