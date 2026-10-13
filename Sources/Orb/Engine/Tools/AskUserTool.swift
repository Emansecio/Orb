import Foundation

/// Lets the Orb ask the person something and wait for the answer: a card with the question and, when given, answers to
/// pick from (the person can always answer in their own words, or skip). Only offered in the Orb's own chat
/// (`MultiOrbOffering.askUser`); the engine shows the card (`ToolContext.askUser`).
struct AskUserTool: AgentTool {
    static let name = "ask_user"
    static let skipped = "The user skipped the question. Carry on with what you can decide yourself, or say in your reply what you need."

    let spec = ToolSpec(
        name: AskUserTool.name,
        description: """
        Ask the user one question and wait for the answer: a choice only they can make, a detail you cannot find out, or which of a \
        few ways to go. Give `options` when the answer is one of a few (2 to \(OrbQuestion.optionLimit), short); they can always \
        answer in their own words instead. Not for what you can look up or reasonably decide yourself, and not to ask permission: \
        actions that need it ask by themselves.
        """,
        parameters: .schema([
            "question": .property("string", "One question, as you would ask it in the chat."),
            "options": .object(["type": .string("array"), "description": .string("Answers to pick from, if any."),
                                "items": .property("string")]),
        ], required: ["question"]))

    var kind: ToolCall.Kind { .orbs }
    var capability: Capability? { nil }

    /// Safe for the permission check: it does nothing but ask, and the card asks in every mode.
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Perguntando", arguments["question"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let ask = context.askUser else {
            throw ToolError("Nobody is here to answer: decide yourself, or say in your reply what you need.")
        }
        let question = OrbQuestion(text: arguments["question"]?.string ?? "",
                                   options: (arguments["options"]?.array ?? []).compactMap(\.string))
        guard !question.text.isEmpty else { throw ToolError("Write the question.") }
        // A skipped question is an answer too, not a failure of the tool.
        guard let answer = await ask(question) else { return Self.skipped }
        return "The user answered: \(answer)"
    }
}
