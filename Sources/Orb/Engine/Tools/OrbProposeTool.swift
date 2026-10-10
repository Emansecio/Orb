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

    /// The token the app writes next to `orb_handled` for a Claude Code call, and the server holds in its environment: the model never
    /// sees it, so a result it wrote into the call itself is never taken for the app's (the same scheme as `UIActTool.cardKey`).
    static let handledKey = "orb_handled"
    static let handledTokenVariable = "ORB_PROPOSE_TOKEN"
    static let handledToken: String = ProcessInfo.processInfo.environment[handledTokenVariable].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString

    /// What the app writes into a Claude Code call after it ran the proposal itself: the token, a colon, the text for the model.
    static func handledMark(_ result: String, token: String = handledToken) -> String { token + ":" + result }

    /// The result the app handed over, or nil when the field is absent or was not written with `token` (the server's own).
    static func handledResult(in arguments: JSONValue, token: String?) -> String? {
        guard let token, !token.isEmpty, let mark = arguments[handledKey]?.string, mark.hasPrefix(token + ":") else { return nil }
        return String(mark.dropFirst(token.count + 1))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        // Claude Code: the app opened the card and created the Orb in its own process; the server only reports what happened.
        if let handled = Self.handledResult(in: arguments, token: ProcessInfo.processInfo.environment[Self.handledTokenVariable]) {
            return handled
        }
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
