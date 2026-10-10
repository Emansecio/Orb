import Foundation

/// Something that happened between Orbs or to them, written into a chat as a structured line (`TranscriptItem.Kind.event`).
/// The words are made when the line is shown (`sentence`), so a rename or a better phrasing reaches old conversations.
struct OrbEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case orbCreated, joinedGroup, leftGroup, groupCreated, routineCreated, renamed
        case chainStopped, groupRunDone, groupStopped, delegationReceived, unknown

        /// A kind from a newer version reads as `unknown`.
        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .unknown) }
    }

    var kind: Kind
    /// Who did it.
    var actor: OrbRef?
    /// About whom (the Orb created, the one who joined).
    var subject: OrbRef?
    /// The name of the group or the routine, the new name, "5 turnos · 42 mil tokens"; for `groupCreated`, "Nome · n".
    var detail: String?
    var requestID: UUID?
    var chainID: UUID?
    var groupID: UUID?

    init(kind: Kind, actor: OrbRef? = nil, subject: OrbRef? = nil, detail: String? = nil,
         requestID: UUID? = nil, chainID: UUID? = nil, groupID: UUID? = nil) {
        self.kind = kind
        self.actor = actor
        self.subject = subject
        self.detail = detail
        self.requestID = requestID
        self.chainID = chainID
        self.groupID = groupID
    }

    /// Tolerant decoding: a field this version cannot read is left out instead of losing the line.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.value(.kind, default: Kind.unknown)
        actor = (try? c.decodeIfPresent(OrbRef.self, forKey: .actor)) ?? nil
        subject = (try? c.decodeIfPresent(OrbRef.self, forKey: .subject)) ?? nil
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        requestID = (try? c.decodeIfPresent(UUID.self, forKey: .requestID)) ?? nil
        chainID = (try? c.decodeIfPresent(UUID.self, forKey: .chainID)) ?? nil
        groupID = (try? c.decodeIfPresent(UUID.self, forKey: .groupID)) ?? nil
    }

    /// The line as the chat shows it ("Atlas criou o Pesquisador"). Pure: the same event always reads the same.
    var sentence: String {
        let actorName = actor?.name ?? "Um Orb"
        let subjectName = subject?.name ?? "outro Orb"
        let detail = detail ?? ""
        switch kind {
        case .orbCreated:
            return "\(actorName) criou \(PortugueseArticle.article(for: subjectName)) \(subjectName)"
        case .joinedGroup:
            return "\(subject?.name ?? "Um Orb") entrou no grupo \(detail)"
        case .leftGroup:
            return "\(subject?.name ?? "Um Orb") saiu do grupo \(detail)"
        case .groupCreated:
            // `detail` is "Nome · n": the count is what follows the last separator.
            let parts = detail.components(separatedBy: " · ")
            guard parts.count > 1, let count = Int(parts[parts.count - 1].trimmingCharacters(in: .whitespaces)) else {
                return "Grupo \(detail) criado"
            }
            return "Grupo \(parts.dropLast().joined(separator: " · ")) criado com \(count) \(count == 1 ? "Orb" : "Orbs")"
        case .routineCreated:
            return "\(actorName) criou a rotina “\(detail)”"
        case .renamed:
            return "\(actorName) agora se chama \(detail)"
        case .chainStopped:
            return "Você parou a conversa entre Orbs"
        case .groupRunDone:
            return "Pedido concluído: \(detail)"
        case .groupStopped:
            return "Você parou o grupo"
        case .delegationReceived:
            return "\(actorName) pediu ajuda \(PortugueseArticle.contraction(for: subjectName)) \(subjectName)"
        case .unknown:
            return detail
        }
    }
}

/// "o Pesquisador", "a Lia": a heuristic from the end of the name (it ends in "a": feminine; anything else: masculine).
/// The worst case is a wrong article, never an error.
enum PortugueseArticle {
    /// "a" or "o".
    static func article(for name: String) -> String { isFeminine(name) ? "a" : "o" }

    /// "ao" or "à", as in "pediu ajuda ao Revisor" / "à Lia".
    static func contraction(for name: String) -> String { isFeminine(name) ? "à" : "ao" }

    private static func isFeminine(_ name: String) -> Bool {
        // The last letter counts: "Lia 2" and "Lia!" are still "a Lia"; accents do not matter ("Júlia").
        guard let last = name.last(where: \.isLetter) else { return false }
        return String(last).folding(options: .diacriticInsensitive, locale: nil).lowercased() == "a"
    }
}
