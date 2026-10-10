import Foundation

/// A group's board, shared by its members: the same kinds and folders as an Orb's memory, in the group's own bank
/// (`ToolContext.groupMemory`). Offered only in a group's turn; `run` waits for the package that wires the bank.
struct GroupRememberTool: AgentTool {
    static let kinds = ["fato", "procedimento", "preferencia"]

    let spec = ToolSpec(
        name: "group_remember",
        description: """
        Save to the group's shared board, which every member reads: a decision, a link, a convention. One short item per call; \
        near-duplicates refresh it. Your own memory stays yours.
        """,
        parameters: .schema([
            "fact": .property("string", "What to save."),
            "tipo": .object(["type": .string("string"), "enum": .array(kinds.map(JSONValue.string)),
                             "description": .string("Default fato. preferencia: a rule for the group.")]),
            "titulo": .property("string"),
        ], required: ["fact"]))

    var kind: ToolCall.Kind { .memory }
    var capability: Capability? { nil }

    /// A fact or a procedure is covered by the turn's grant (`PermissionFamily.groupMemory`); a preference is a standing
    /// rule for the group, so it still asks.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        (arguments["tipo"]?.string.flatMap(MemoryKind.init)?.isPinned ?? false) ? .instructs : .sensitive
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let kind = arguments["tipo"]?.string.flatMap(MemoryKind.init) ?? .fato
        return ("Guardando no quadro do grupo (\(kind.label.lowercased()))", arguments["fact"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        throw ToolError("O quadro do grupo não está disponível agora.")
    }
}

struct GroupRecallTool: AgentTool {
    let spec = ToolSpec(
        name: "group_recall",
        description: "Search the group's shared board: decisions, conventions and notes the members saved.",
        parameters: .schema([
            "query": .property("string"),
            "limite": .property("integer", "Results (default 5, max 10)."),
        ], required: ["query"]))

    var kind: ToolCall.Kind { .memory }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Buscando no quadro do grupo", arguments["query"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        throw ToolError("O quadro do grupo não está disponível agora.")
    }
}

extension ToolBox {
    static let groupMemoryTools: [any AgentTool] = [GroupRememberTool(), GroupRecallTool()]
}
