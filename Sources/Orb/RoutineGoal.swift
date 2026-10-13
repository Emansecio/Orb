import Foundation

// A goal is not an engine of its own: it is an optional part of a routine. Each run checks where the goal stands, takes
// a small step when it is safe, and ends its report with one readable line ("Progresso: 35% · em dia · faltam 2
// faturas"). The app reads that line back, so the routine's history doubles as the goal's timeline.

/// How a goal stands after a check, in the words the report line and the cards use.
enum GoalStatus: String, Codable, Sendable {
    case onTrack, attention, done

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .onTrack) }

    /// What the progress line says and the cards show: "em dia", "atenção", "concluída".
    var label: String {
        switch self {
        case .onTrack: "em dia"
        case .attention: "atenção"
        case .done: "concluída"
        }
    }
}

/// One check of a goal: what a run's progress line said.
struct GoalCheck: Codable, Sendable, Equatable {
    /// 0–100; a goal reached is always 100.
    var progress: Int
    var status: GoalStatus
    var note: String = ""

    static let noteLimit = 160

    /// "35% · em dia"
    var label: String { "\(progress)% · \(status.label)" }
    /// "Meta: 35%, em dia", for VoiceOver.
    var spokenLabel: String { "Meta: \(progress)%, \(status.label)" }
}

extension GoalCheck {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        progress = min(max(try c.value(.progress, default: 0), 0), 100)
        status = try c.value(.status, default: .onTrack)
        note = try c.value(.note, default: "")
    }
}

/// What a routine with a goal is after, and where its last check left it.
struct RoutineGoal: Codable, Sendable, Equatable {
    /// What success looks like, in the user's words ("Como saber que deu certo").
    var target: String
    /// The last check a run reported; nil before the first.
    var check: GoalCheck?
    var updatedAt: Date?

    static let targetLimit = 300
}

extension RoutineGoal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.value(.target, default: "")
        check = (try? c.decodeIfPresent(GoalCheck.self, forKey: .check)) ?? nil
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

extension RoutineGoal {
    /// What VoiceOver says for the goal's bar: "Meta: 35%, em dia. Faltam 2 faturas" (what it is after is its value).
    var spokenSummary: String {
        guard let check else { return "Meta: ainda sem avaliação" }
        return check.spokenLabel + (check.note.isEmpty ? "" : ". \(check.note)")
    }
}

// MARK: - The progress line

extension GoalCheck {
    /// Reads the progress line of a report, from the bottom up: "Progresso: 35% · em dia · nota". Case, accents,
    /// Markdown around it and the spacing do not matter ("**PROGRESSO:** 35 % - Atencao"). A line quoted (`>`) or inside
    /// a code block is an example, not the report's own; and "concluída", which pauses the routine, counts only as the
    /// report's last line: an Orb that wrote more after it ("Ainda falta verificar a entrega") has not closed the goal.
    /// nil when no line has that shape: the goal then keeps its last check, rather than falling back to zero.
    static func parse(_ report: String?) -> GoalCheck? {
        guard let report else { return nil }
        var lines: [(text: Substring, quoted: Bool)] = []
        // The fence of the open code block ("```" or "~~~", which only closes its own kind) and the first line inside it.
        var fence: (marker: String, firstLine: Int)?
        for line in report.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }), fence == nil || fence?.marker == marker {
                fence = fence == nil ? (marker, lines.count) : nil
            } else if !trimmed.isEmpty {
                lines.append((line, fence != nil || trimmed.hasPrefix(">")))
            }
        }
        // A block never closed is no block: what follows its fence is the report's own text.
        if let open = fence {
            for index in open.firstLine..<lines.count {
                lines[index].quoted = lines[index].text.drop { $0 == " " || $0 == "\t" }.hasPrefix(">")
            }
        }
        for (index, line) in lines.enumerated().reversed() where !line.quoted {
            guard let check = parse(line: String(line.text)) else { continue }
            if check.status == .done, index != lines.count - 1 { continue }
            return check
        }
        return nil
    }

    private static func parse(line: String) -> GoalCheck? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = lineExpression.firstMatch(in: line, range: range),
              let number = Range(match.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
              let word = Range(match.range(at: 2), in: line).map({ line[$0].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
        else { return nil }
        let status: GoalStatus = word.hasPrefix("conclu") ? .done : word.hasPrefix("aten") ? .attention : .onTrack
        let note = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        return GoalCheck(progress: status == .done ? 100 : min(number, 100), status: status,
                         note: Conversation.clipped(note.trimmingCharacters(in: noteEdges), to: noteLimit))
    }

    /// "Progresso", a number with or without "%", a status word, and the note after any separator. Markdown marks and
    /// list bullets before it are skipped.
    private static let lineExpression = try! NSRegularExpression(
        pattern: #"^[\s*_`#\-•]*progresso[\s*_`:]*(\d{1,3})\s*%?[\s*_`·•|,;:\-–—]*(em\s+dia|aten[cç][aã]o|conclu[ií]d[ao])\b[\s*_`·•|,;:\-–—.]*(.*)$"#,
        options: [.caseInsensitive])

    private static let noteEdges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`"))
}

extension Routine {
    /// A finished run's report moves the goal: its progress line becomes the goal's last check. A goal reached pauses
    /// the routine, whose work is done. Returns the check read; nil without a goal or without a line (the goal stays
    /// where it was).
    mutating func recordGoalCheck(from report: String?, at date: Date) -> GoalCheck? {
        guard goal != nil, let check = GoalCheck.parse(report) else { return nil }
        goal?.check = check
        goal?.updatedAt = date
        if check.status == .done { isEnabled = false }
        return check
    }
}
