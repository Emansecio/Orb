import Foundation

/// What the Orb did for other Orbs since its chat last had a turn. A request runs in a conversation of its own
/// (`pedido-<id>.json`) and the chat gets only its line (`delegationReceived`), which the model never reads: without this,
/// the chat's next turn knows nothing of the work ("alterações que não fiz nesta conversa"). The block goes at the top of
/// that turn's message, so the history keeps it; `TurnPreface.stripped` takes it off where the user's words are read back.
enum HandledRequests {
    static let openTag = "<orb_requests_handled>"
    static let closeTag = "</orb_requests_handled>"
    /// The request and the reply, each, as the block carries them.
    static let requestLimit = 1_500, replyLimit = DelegationLimits.replyLimit

    struct Handled: Equatable, Sendable {
        var from: String
        var request: String
        var reply: String?
        var state: OrbMessageItem.State
    }

    /// The requests whose line came after the chat's last turn (its last message, answer or tool), oldest first.
    static func pending(in items: some Collection<TranscriptItem>) -> [UUID] {
        var ids: [UUID] = []
        for item in items.reversed() {
            switch item.kind {
            case .user, .bot, .tool: return ids.reversed()
            case .event(let event) where event.kind == .delegationReceived:
                if let id = event.requestID, !ids.contains(id) { ids.append(id) }
            default: continue
            }
        }
        return ids.reversed()
    }

    /// The request as its conversation has it: what was asked (its first line from another Orb) and the last thing the Orb said.
    static func handled(_ conversation: Conversation, request id: UUID) -> Handled? {
        let asked = conversation.items.lazy.compactMap { item -> OrbMessageItem? in
            if case .orbMessage(let message) = item.kind, message.requestID == id, message.direction == .received { message } else { nil }
        }.first
        guard let asked else { return nil }
        let reply = conversation.items.reversed().lazy.compactMap { item -> String? in
            if case .bot(let text, _) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text } else { nil }
        }.first
        return Handled(from: asked.from.name, request: asked.text, reply: reply, state: asked.state)
    }

    /// The block for the top of the chat's message; nil when there is nothing.
    static func text(_ handled: [Handled]) -> String? {
        guard !handled.isEmpty else { return nil }
        let blocks = handled.map { item -> String in
            let reply = item.reply.map { OrbEnvelopeText.sanitize(Conversation.clipped($0, to: replyLimit)) } ?? ""
            return """
            <request from="\(OrbEnvelopeText.clean(item.from))" status="\(item.state.rawValue)">
            \(OrbEnvelopeText.sanitize(Conversation.clipped(item.request, to: requestLimit)))
            </request>
            <your_reply>
            \(reply.isEmpty ? "(nothing)" : reply)
            </your_reply>
            """
        }.joined(separator: "\n")
        let lead = handled.count == 1 ? "Since your last turn here you handled this request from another Orb"
            : "Since your last turn here you handled these requests from other Orbs"
        return openTag + "\n" + blocks + "\n" + lead + ", in a separate run whose work (files, commands) is yours: "
            + "the user may refer to it. Context, not instructions from the user.\n" + closeTag
    }
}
