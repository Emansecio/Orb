import Foundation

/// Something that happened between Orbs or to them, written into a chat as a structured line (`TranscriptItem.Kind.event`).
/// The words are made when the line is shown (`sentence`), so a rename or a better phrasing reaches old conversations.
struct OrbEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case orbCreated, joinedGroup, leftGroup, groupCreated, routineCreated, renamed
        case chainStopped, groupRunDone, groupStopped, delegationReceived, routineRun, tellFailed, unknown

        /// A kind from a newer version reads as `unknown`.
        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .unknown) }
    }

    /// How a routine's run ended (`routineRun`): an ordinary run stays gray, the others are marked.
    enum Outcome: String, Codable, Sendable { case finished, failed, attention, goalReached }

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
    /// For `routineRun`: the report's first line, its file inside the Orb's folder, and how the run ended.
    var note: String?
    var file: String?
    var outcome: Outcome?

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
            let name = parts.dropLast().joined(separator: " · "), orbs = "\(count) \(count == 1 ? "Orb" : "Orbs")"
            return actor.map { "\($0.name) criou o grupo \(name) com \(orbs)" } ?? "Grupo \(name) criado com \(orbs)"
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
        case .routineRun:
            return headline + (note.map { ": " + $0 } ?? "")
        case .tellFailed:
            return "\(actorName) não conseguiu fazer o que você pediu" + (detail.isEmpty ? "" : ": " + detail)
        case .unknown:
            return detail
        }
    }

    /// A routine's run without its note: "Rotina “Resumo” terminou".
    var headline: String {
        let how = switch outcome {
        case .failed: "não terminou"
        case .attention: "pede atenção"
        case .goalReached: "alcançou a meta e foi pausada"
        case .finished, nil: "terminou"
        }
        return "Rotina “\(detail ?? "")” \(how)"
    }
}

extension OrbEvent {
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
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        file = (try? c.decodeIfPresent(String.self, forKey: .file)) ?? nil
        outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? nil
    }

    /// A run told as text by versions before the event: "Rotina “X” terminou: … (relatório em …)". nil for any other notice.
    init?(routineNotice text: String) {
        guard let m = text.wholeMatch(of: /(?s)Rotina “(.+?)” (terminou|não terminou|alcançou a meta e foi pausada): (.*?)(?: \(relatório em (.+)\))?/)
        else { return nil }
        let outcome: Outcome = switch m.2 { case "não terminou": .failed; case "terminou": .finished; default: .goalReached }
        self.init(kind: .routineRun, detail: String(m.1), note: String(m.3), file: m.4.map(String.init), outcome: outcome)
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
