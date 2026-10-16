import Foundation

/// What travels between Orbs: a request, a notice or a reply, with where it stands in its chain (the Orbs that asked each
/// other, from the first to the last). Memory only: delegation state is not saved (`DelegationRequest`).
struct OrbEnvelope: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ask, tell, reply

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .tell) }
    }

    enum ReplyStatus: String, Codable, Sendable {
        case ok, failed, cancelled, refused

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .failed) }
    }

    /// The message id, for telling a repeat from a new message.
    var id: UUID = UUID()
    var chainID: UUID = UUID()
    var kind: Kind
    var from: OrbRef
    var to: OrbRef
    /// ask and tell: up to `DelegationLimits.messageLimit` characters; reply: up to `replyLimit`.
    var text: String
    /// 1 in the first request of a chain.
    var hop: Int = 1
    /// The Orbs of the chain, from the first to `from`.
    var path: [UUID] = []
    /// The request a reply closes.
    var replyTo: UUID?
    /// The request the asker was serving when it asked (a request that waits for its children).
    var servingRequest: UUID?
    /// Only in a reply.
    var status: ReplyStatus?
    var groupID: UUID?
    var sentAt: Date = .now
    /// A member asked its group from its own chat, at the person's request (`orbs ask` with the group's name): the group's
    /// orchestrator answers it, and the reply goes back to that chat even when the asker is the orchestrator itself.
    var fromChat = false
    /// The routine whose run asked (nil outside a routine): its answer resumes that run, not the chat.
    var servingRoutine: UUID?
}

extension OrbEnvelope {
    /// Tolerant decoding: everything but the ids has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        chainID = try c.decode(UUID.self, forKey: .chainID)
        kind = try c.value(.kind, default: Kind.tell)
        from = try c.decode(OrbRef.self, forKey: .from)
        to = try c.decode(OrbRef.self, forKey: .to)
        text = try c.value(.text, default: "")
        hop = try c.value(.hop, default: 1)
        path = try c.lossyArray(.path)
        replyTo = (try? c.decodeIfPresent(UUID.self, forKey: .replyTo)) ?? nil
        servingRequest = (try? c.decodeIfPresent(UUID.self, forKey: .servingRequest)) ?? nil
        status = (try? c.decodeIfPresent(ReplyStatus.self, forKey: .status)) ?? nil
        groupID = (try? c.decodeIfPresent(UUID.self, forKey: .groupID)) ?? nil
        sentAt = try c.value(.sentAt, default: Date.now)
        fromChat = try c.value(.fromChat, default: false)
        servingRoutine = (try? c.decodeIfPresent(UUID.self, forKey: .servingRoutine)) ?? nil
    }
}
