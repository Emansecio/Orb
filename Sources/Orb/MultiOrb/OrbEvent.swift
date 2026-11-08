import Foundation

/// Something that happened between Orbs or to them, written into a chat as a structured line (`TranscriptItem.Kind.event`).
/// The words are made when the line is shown (`sentence`), so a rename or a better phrasing reaches old conversations.
struct OrbEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case orbCreated, joinedGroup, leftGroup, groupCreated, routineCreated, renamed
        case orchestratorChanged, chainStopped, groupRunDone, groupStopped, delegationReceived, routineRun, tellFailed, groupWorked, planDone, pulseRan, pulseStopped
        /// The pulse took up a dropped plan in its own conversation (`detail`: the plan's goal); the turn follows it.
        case pulseResumed
        /// An Orb asked, in a turn nobody watched, to delete an Orb or a group (`DeletionAsk`): the line offers Apagar and
        /// Manter; `outcome` is set once the person answered (finished: deleted; failed: kept; attention: it no longer applied).
        case deletionAsked
        /// The person answered a `deletionAsked`: the Orb that asked is told in its next turn.
        case deletionAnswered
        case unknown

        /// A kind from a newer version reads as `unknown`.
        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .unknown) }
    }

    /// How a routine's run ended (`routineRun`): an ordinary run stays gray, the others are marked.
    enum Outcome: String, Codable, Sendable {
        case finished, failed, attention, goalReached

        /// One from a newer version reads as attention instead of losing the line: never as finished, which on a deletion's
        /// line would say something was deleted.
        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .attention) }
    }

    /// The `detail` of a `groupStopped` the pulse's daily budget caused; without it the person stopped the group.
    static let budgetStop = "budget"
    /// The `detail` of a `pulseStopped` because the pulse (or "Orbs agem por conta própria") was switched off.
    static let pulseOff = "off"

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
    /// For `routineRun`: the run (`RoutineRun.id`), whose report the chat's next turn is told (`SinceLastTurn`).
    var runID: UUID?
    /// For `groupWorked`: what the Orb's chat is told of its work in the group (the request, what it said, the result). Never
    /// shown: the line is the sentence.
    var context: String?
    /// For `planDone`: the plan the turn finished, kept whole so the line can show its steps later. Never sent to the
    /// model: like every event, the line is only for the screen.
    var plan: TaskPlan?

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
        case .orchestratorChanged:
            return "\(subject?.name ?? "Um Orb") agora orquestra o grupo \(detail)"
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
            return detail == Self.budgetStop ? "O teto diário do pulso parou o grupo"
                : detail == Self.pulseOff ? "O pulso foi desligado e parou o grupo" : "Você parou o grupo"
        case .delegationReceived:
            return "\(actorName) pediu ajuda \(PortugueseArticle.contraction(for: subjectName)) \(subjectName)"
        case .routineRun:
            return headline + (note.map { ": " + $0 } ?? "")
        case .tellFailed:
            return "\(actorName) não conseguiu fazer o que você pediu" + (detail.isEmpty ? "" : ": " + detail)
        case .groupWorked:
            return "\(subject?.name ?? "Um Orb") trabalhou no grupo \(detail)"
        case .planDone:
            // A version that does not know this kind reads it as `unknown` and shows `detail`, so it carries the same words.
            guard let count = plan?.steps.count else { return detail.isEmpty ? "Plano concluído" : detail }
            return "Plano concluído · \(count) \(count == 1 ? "etapa" : "etapas")"
        case .pulseRan:
            // `detail` holds the tokens the pulse turn spent; `note` what it said or did.
            let cost = Int(detail).map { $0 > 0 ? " · " + GroupUsageText.tokens($0) : "" } ?? ""
            let lead = outcome == .failed ? "\(actorName) acordou sozinho e não terminou" : "\(actorName) acordou sozinho"
            return lead + (note.map { ": " + $0 } ?? "") + cost
        case .pulseResumed:
            return "\(actorName) retomou sozinho o plano “\(detail)”"
        case .pulseStopped:
            if detail == Self.pulseOff { return "O pulso parou: foi desligado nos Ajustes" }
            let budget = Int(detail).map { " (" + GroupUsageText.tokens($0) + " por dia)" } ?? ""
            return "O pulso parou: o teto diário de tokens\(budget) foi atingido"
        case .deletionAsked:
            let how = switch outcome {
            case .finished: " · feito"
            case .failed: " · mantido"
            case .attention: " · não vale mais"
            case .goalReached, nil: ""
            }
            return "\(actorName) pede para \(deletionWhat)" + how
        case .deletionAnswered:
            switch outcome {
            case .finished: return "Você \(deletionDone), como \(actorName) pediu"
            case .attention: return "O pedido de \(actorName) para \(deletionWhat) não vale mais"
            default: return "Você não deixou \(actorName) \(deletionWhat)"
            }
        case .unknown:
            return detail
        }
    }

    /// "apagar o Revisor", "apagar o grupo “Vendas”", "tirar o Revisor do grupo “Vendas”".
    private var deletionWhat: String {
        let group = "o grupo “\(detail ?? "")”"
        switch (subject, groupID) {
        case (let orb?, _?): return "tirar \(PortugueseArticle.article(for: orb.name)) \(orb.name) do grupo “\(detail ?? "")”"
        case (let orb?, nil): return "apagar \(PortugueseArticle.article(for: orb.name)) \(orb.name)"
        default: return "apagar " + group
        }
    }

    /// "apagou o Revisor", "apagou o grupo “Vendas”", "tirou o Revisor do grupo “Vendas”".
    private var deletionDone: String {
        switch (subject, groupID) {
        case (let orb?, _?): "tirou \(PortugueseArticle.article(for: orb.name)) \(orb.name) do grupo “\(detail ?? "")”"
        case (let orb?, nil): "apagou \(PortugueseArticle.article(for: orb.name)) \(orb.name)"
        default: "apagou o grupo “\(detail ?? "")”"
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
        runID = (try? c.decodeIfPresent(UUID.self, forKey: .runID)) ?? nil
        context = (try? c.decodeIfPresent(String.self, forKey: .context)) ?? nil
        plan = (try? c.decodeIfPresent(TaskPlan.self, forKey: .plan)) ?? nil
    }

    /// The line for a plan whose steps are all done. Its `next` is dropped (nothing is next), and `detail` holds the words.
    init(planDone plan: TaskPlan) {
        var finished = plan
        finished.next = nil
        self.init(kind: .planDone, plan: finished)
        detail = sentence
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
