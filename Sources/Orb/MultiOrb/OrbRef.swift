import Foundation

/// An Orb as a fact about the past: its id and the name it had then (an Orb renamed or deleted later still reads right in
/// the lines that mention it).
struct OrbRef: Codable, Hashable, Sendable {
    var id: UUID
    var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ bot: Bot) { self.init(id: bot.id, name: bot.name) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.value(.name, default: "")
    }
}
