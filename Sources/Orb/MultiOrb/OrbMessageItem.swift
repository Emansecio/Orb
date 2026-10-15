import Foundation

/// One message between Orbs as a chat keeps it (`TranscriptItem.Kind.orbMessage`): the line the one who asked sees ("Atlas
/// pediu ajuda ao Revisor"), the one the target keeps in its side conversation, a reply, or a post in a group's thread.
struct OrbMessageItem: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Sendable {
        case sent, received, reply
        /// A post in a group's thread.
        case post

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .received) }
    }

    enum Kind: String, Codable, Sendable {
        case ask, tell, reply

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .tell) }
    }

    enum State: String, Codable, Sendable {
        case open, replied, failed, cancelled, refused, lost

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .lost) }
    }

    var direction: Direction
    var kind: Kind
    var state: State
    var from: OrbRef
    var to: OrbRef?
    /// Up to `DelegationLimits.messageLimit` characters (`replyLimit` for a reply).
    var text: String
    var requestID: UUID
    var chainID: UUID
    var groupID: UUID?
}

extension OrbMessageItem {
    /// Tolerant decoding: everything but the ids has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.value(.direction, default: Direction.received)
        kind = try c.value(.kind, default: Kind.tell)
        state = try c.value(.state, default: State.lost)
        from = try c.decode(OrbRef.self, forKey: .from)
        to = (try? c.decodeIfPresent(OrbRef.self, forKey: .to)) ?? nil
        text = try c.value(.text, default: "")
        requestID = try c.decode(UUID.self, forKey: .requestID)
        chainID = try c.decode(UUID.self, forKey: .chainID)
        groupID = (try? c.decodeIfPresent(UUID.self, forKey: .groupID)) ?? nil
    }
}
