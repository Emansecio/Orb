import Foundation

// What you think of a reply or an action of an Orb, given with a click, and how it gets back to the Orb: with the next
// message of that chat (`SinceLastTurn`), and, for the turn that just ended with tools, as a question to the skill
// review at once, so the lesson does not wait for you to write again.

extension Reaction {
    /// A finished reply with something in it, or an action that ended.
    static func takes(_ item: TranscriptItem) -> Bool {
        switch item.kind {
        case .bot(let text, let isStreaming): !isStreaming && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tool(let call): call.state != .running
        default: false
        }
    }
}

extension AppModel {
    /// Keeps `reaction` on the line (nil takes it back) and, when it is about the turn that just ended, asks the skill review.
    func react(_ reaction: Reaction?, to itemID: UUID, of botID: UUID) {
        guard bot(botID) != nil else { return }
        let session = session(botID)
        var given = reaction
        let reason = given?.reason.map { String(MemoryText.flatten($0).prefix(Reaction.reasonLimit)) } ?? ""
        given?.reason = reason.isEmpty ? nil : reason
        given?.date = .now
        var index: Int?
        session.mutateItems { items in
            guard let at = items.firstIndex(where: { $0.id == itemID }), Reaction.takes(items[at]) else { return }
            items[at].reaction = given
            index = at
        }
        guard let index, let given, let conversation = session.conversation else { return }
        announceForAccessibility(given.isGood ? "Marcado como bom" : "Marcado como ruim")
        // Only the turn that just ended is still whole in `reviewBase` (and in the provider's cache), in the chat it worked on.
        let lastRequest = conversation.items.lastIndex { if case .user = $0.kind { true } else { false } } ?? -1
        guard index > lastRequest, session.reviewChat == session.conversationChat,
              let report = Reaction.report(on: index, in: conversation.items) else { return }
        let slugs = Set(skills(for: botID).map(\.slug))
        let used = Reaction.commandsUsed(inTurnOf: index, conversation.items).filter(slugs.contains)
        reviewSkillsIfDue(session, messages: conversation.messages, rated: report + Reaction.skillsLine(used))
    }
}
