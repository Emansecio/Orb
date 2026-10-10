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
    var id: UUID
    var chainID: UUID
    var kind: Kind
    var from: OrbRef
    var to: OrbRef
    /// ask and tell: up to `DelegationLimits.messageLimit` characters; reply: up to `replyLimit`.
    var text: String
    /// 1 in the first request of a chain.
    var hop: Int
    /// The Orbs of the chain, from the first to `from`.
    var path: [UUID]
    /// The request a reply closes.
    var replyTo: UUID?
    /// The request the asker was serving when it asked (a request that waits for its children).
    var servingRequest: UUID?
    /// Only in a reply.
    var status: ReplyStatus?
    var groupID: UUID?
    var sentAt: Date

    init(id: UUID = UUID(), chainID: UUID = UUID(), kind: Kind, from: OrbRef, to: OrbRef, text: String, hop: Int = 1,
         path: [UUID] = [], replyTo: UUID? = nil, servingRequest: UUID? = nil, status: ReplyStatus? = nil,
         groupID: UUID? = nil, sentAt: Date = .now) {
        self.id = id
        self.chainID = chainID
        self.kind = kind
        self.from = from
        self.to = to
        self.text = text
        self.hop = hop
        self.path = path
        self.replyTo = replyTo
        self.servingRequest = servingRequest
        self.status = status
        self.groupID = groupID
        self.sentAt = sentAt
    }

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
    }
}
