import Foundation

/// What a reviewer's reply says about the work: the group prompt asks it to start the answer with `APPROVED` or `CHANGES:`.
/// The hub reads that first line to count the rounds and to show the verdict (the model is not asked again, so a reply that
/// starts some other way is simply not a verdict).
enum ReviewVerdict: String, Equatable, Sendable {
    case approved, changes

    /// The first non-empty line of a reply, with Markdown marks, case and accents ignored: "**APPROVED**", "Aprovado.",
    /// "changes: fix the login", "Alterações - o botão". The word must end the line or be followed by a separator, so
    /// prose that merely starts with it ("Changes were made to...") is not a verdict.
    static func read(_ reply: String) -> ReviewVerdict? {
        guard let first = reply.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let line = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range), let word = Range(match.range(at: 1), in: line) else { return nil }
        switch line[word] {
        case "approved", "aprovado", "aprovada": return .approved
        default: return .changes
        }
    }

    /// Leading Markdown/space, the word, then the end of the line or a separator (":", "-", ".", etc.).
    private static let pattern: NSRegularExpression = {
        let words = "approved|aprovad[oa]|changes|alteracoes|mudancas"
        return try! NSRegularExpression(pattern: #"^[\s*_`#>\-•]*("# + words + #")[\s*_`]*(?:$|[:\-–—.,;!|])"#)
    }()

    /// The line the thread shows when a verdict arrives ("Revisão: aprovado na rodada 2").
    static func eventLine(_ verdict: ReviewVerdict, round: Int) -> String {
        switch verdict {
        case .approved: return "Revisão: aprovado na rodada \(round)"
        case .changes: return "Revisão: pediu mudanças (rodada \(round))"
        }
    }

    /// What the board's session page says ("aprovada na rodada 2").
    static func pageLine(_ verdict: ReviewVerdict, round: Int) -> String {
        switch verdict {
        case .approved: return "aprovada na rodada \(round)"
        case .changes: return "mudanças pedidas na rodada \(round), sem nova aprovação"
        }
    }
}
