import Foundation

/// The calls of one step that all wait for the same ordinary permission, grouped on a single card so that four
/// writes mean one question instead of four. Only calls whose reason to ask is `.needsPermission` are grouped:
/// a destructive call, or one that changes the Orb's instructions, always gets a card of its own.
struct ApprovalBatch: Sendable {
    struct Member: Sendable {
        /// Position in the step's calls, so results go back in the order the model asked.
        var index: Int
        var item: ApprovalItem
        /// The standing rules that would cover this call alone.
        var suggestions: [PermissionRule]
    }

    var members: [Member]

    /// A card for fewer than two actions is just a card.
    static let minimumSize = 2
    /// The "Sempre…" menu offers at most this many rules.
    static let maxSuggestions = 3

    /// Judges every call of the step with the permissions as they are now and groups the ones that would ask.
    /// nil when fewer than `minimumSize` do.
    static func plan(calls: [ToolCallRequest], tools: [any AgentTool], context: ToolContext, state: PermissionState,
                     grants: [PermissionRule]) -> ApprovalBatch? {
        var members: [Member] = []
        for (index, call) in calls.enumerated() {
            guard let tool = tools.first(where: { $0.spec.name == call.name }),
                  let arguments = JSONValue.parse(call.arguments) else { continue }
            let permission = PermissionPolicy.call(for: tool, arguments: arguments, context: context)
            guard case .ask(.needsPermission) = PermissionPolicy.evaluate(
                mode: state.mode, call: permission, rules: state.rules, turnGrants: grants, workspace: context.workingDirectory)
            else { continue }
            let summary = tool.summary(arguments, context: context)
            members.append(Member(
                index: index,
                item: ApprovalItem(toolName: call.name, title: summary.title, command: summary.detail),
                suggestions: PermissionPolicy.suggestions(for: permission, existing: state.rules + grants,
                                                          workspace: context.workingDirectory)))
        }
        return members.count >= minimumSize ? ApprovalBatch(members: members) : nil
    }

    /// The rules the card offers: those of the members together, without repeats.
    var suggestions: [PermissionRule] {
        Array(PermissionPolicy.unique(members.flatMap(\.suggestions)).prefix(Self.maxSuggestions))
    }

    func request(botName: String, reason: String) -> ApprovalRequest {
        let items = members.map(\.item)
        return ApprovalRequest(
            toolName: "batch",
            title: "\(items.count) ações precisam da sua permissão",
            command: items.map { $0.command.isEmpty ? "• \($0.title)" : "• \($0.title): \($0.command)" }.joined(separator: "\n"),
            reason: reason.isEmpty ? "\(botName) precisa da sua permissão para continuar." : "",
            suggestions: suggestions,
            items: items)
    }
}
