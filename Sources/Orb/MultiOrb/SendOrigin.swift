import Foundation

/// Where the text of a turn comes from. `AppModel.send` treats the person's message as it always did; a request from another
/// Orb or the answers to its own requests enter the conversation as `.orbMessage` lines (never as the person's bubble),
/// read no memory request, expand no skill, clear no draft and carry the turn's grant for `orbs`.
enum SendOrigin: Sendable, Equatable {
    case user
    /// A request or a notice from another Orb. The text sent to the model is the envelope (`OrbEnvelopeText.request`).
    case orb(OrbEnvelope)
    /// The answers to requests this Orb made (`OrbEnvelopeText.reply`).
    case orbReply([OrbEnvelope])

    var isUser: Bool { if case .user = self { true } else { false } }

    /// The lines the conversation gets in place of the person's bubble.
    var items: [OrbMessageItem] {
        switch self {
        case .user:
            return []
        case .orb(let envelope):
            return [OrbMessageItem(direction: .received, kind: envelope.kind == .tell ? .tell : .ask, state: .open,
                                   from: envelope.from, to: envelope.to, text: envelope.text, requestID: envelope.id,
                                   chainID: envelope.chainID, groupID: envelope.groupID)]
        case .orbReply(let envelopes):
            return envelopes.map { envelope in
                OrbMessageItem(direction: .reply, kind: .reply, state: Self.state(of: envelope.status), from: envelope.from,
                               to: envelope.to, text: envelope.text, requestID: envelope.replyTo ?? envelope.id,
                               chainID: envelope.chainID, groupID: envelope.groupID, fromChat: envelope.fromChat ? true : nil)
            }
        }
    }

    static func state(of status: OrbEnvelope.ReplyStatus?) -> OrbMessageItem.State {
        switch status ?? .ok {
        case .ok: .replied
        case .failed: .failed
        case .cancelled: .cancelled
        case .refused: .refused
        }
    }
}

extension Array where Element == TranscriptItem {
    /// The lines this Orb sent for `requestID` that were still open now read `state`.
    mutating func settingSent(_ requestID: UUID, to state: OrbMessageItem.State) {
        for index in indices {
            if case .orbMessage(var message) = self[index].kind, message.direction == .sent, message.requestID == requestID,
               message.state == .open {
                message.state = state
                self[index].kind = .orbMessage(message)
            }
        }
    }

    /// The line that shows the request a run answers now reads `state`.
    mutating func settingReceived(_ requestID: UUID, to state: OrbMessageItem.State) {
        for index in indices {
            if case .orbMessage(var message) = self[index].kind, message.direction == .received, message.requestID == requestID {
                message.state = state
                self[index].kind = .orbMessage(message)
            }
        }
    }
}
