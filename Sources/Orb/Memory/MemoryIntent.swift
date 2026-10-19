import Foundation

/// You asking an Orb to remember something ("memorize isso", "lembra que…", "guarda na memória", "não esquece que…",
/// "remember that…"). Then saving is your decision, not the model's: the turn saves facts and procedures without an
/// approval card (identity and preferences still ask, see `ToolRisk.instructs`), and if the model doesn't save, the
/// app does.
///
/// Only your own words count: a request buried in the middle of a long or pasted text ("Resuma este e-mail: …
/// remember that…") is not one, and reminders ("me lembra de ligar…", "não esqueça de trazer…") are tasks, not
/// memories.
struct MemoryIntent: Equatable, Sendable {
    /// What to keep, when the message says it ("memorize que meu aniversário é 3 de maio" → "meu aniversário é 3 de
    /// maio"); nil when it points at something said before ("memorize isso").
    var content: String?

    /// What the app adds after your message when it asks the model to save (the transcript never shows it).
    static let instructionMarker = "\n\n(The user is asking you to remember something."

    /// The instruction added to a message that asks to remember, naming the tool that saves.
    static func instruction(tool: String) -> String {
        instructionMarker + " Save it now with the \(tool) tool, picking the right tipo; if it refers to something said earlier, "
            + "save that. Then confirm in one short sentence.)"
    }

    /// The request in `message`, if there is one.
    static func detect(_ message: String) -> MemoryIntent? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folded = matchingText(text) else { return nil }
        for match in trigger.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            if let range = Range(match.range, in: folded), let intent = intent(at: range, text: text, folded: folded) { return intent }
        }
        return nil
    }

    /// `text` as matching reads it: lowercase, without accents, and with typographic apostrophes ("Don’t forget", as Notes
    /// and macOS smart quotes write them) as the straight one; the same characters, so ranges map back. One `folding` call
    /// for the whole text: folding each character alone (to keep the copy the same length) builds a `String` and a `Locale`
    /// per character, which took ~0.2 s on a 200 000-character paste, on the main thread as the message is sent. A text whose
    /// folding changes its length (a ligature) takes the character-by-character way, as before.
    private static func matchingText(_ text: String) -> String? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .app)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        if folded.count == text.count { return folded }
        var kept = String()
        kept.reserveCapacity(text.count)
        for character in text {
            if character == "’" || character == "‘" {
                kept.append("'")
                continue
            }
            let plain = String(character).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .app)
            kept.append(plain.count == 1 ? plain : String(character))
        }
        return kept.count == text.count ? kept : nil
    }

    /// The request that the trigger found at `foldedRange`, unless it isn't one (negation, a pasted text, a question).
    private static func intent(at foldedRange: Range<String.Index>, text: String, folded: String) -> MemoryIntent? {
        // "O app não lembra que…", "I don't remember that…", "to memorize": the verb has to open the sentence, so
        // negations, third persons and infinitives never get here.
        guard opensClause(folded[..<foldedRange.lowerBound]) else { return nil }
        let start = folded.distance(from: folded.startIndex, to: foldedRange.lowerBound)
        let end = folded.distance(from: folded.startIndex, to: foldedRange.upperBound)
        // Your request opens the message or is its last sentence; one in the middle of a text belongs to that text.
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let after = folded[foldedRange.upperBound...]
        if start > 60, after.range(of: #"[.!?;]\s+\S"#, options: .regularExpression) != nil { return nil }
        if lines.count > 2 {
            let firstLine = lines.first?.count ?? 0, lastLine = lines.last?.count ?? 0
            if start > firstLine, text.count - end > lastLine { return nil }
        }
        // "Você lembra que eu moro em SP?" asks about memory; it doesn't ask to save.
        let verb = folded[foldedRange]
        if text.hasSuffix("?"), verb.hasPrefix("lembr") || verb.hasPrefix("remember") { return nil }
        // A bare "lembra que…" or "keep in mind that…" followed by more is context for a task ("lembra que ontem
        // mexemos no build; agora o deploy quebrou, investiga"); "lembre que", "lembre-se" and the memory verbs don't
        // have that doubt.
        if verb.range(of: #"^(?:lembra(?!-se| se)|keep in mind)"#, options: .regularExpression) != nil, carriesATask(after) { return nil }

        let matched = text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;,.-–— "))
        // Only the punctuation of a sentence is trimmed: "10%", "C#", "(Rafa)" and a closing quote belong to what is kept.
        var rest = text[matched.upperBound...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?¿¡…-–—")))
        // "Guarda isso na memória", "Memorize isto: …", "Memoriza aí: …", "…, por favor" are the request, not the content.
        while let next = dropComplement(from: rest) { rest = next }
        for filler in fillers {
            if let found = rest.range(of: filler + " ", options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
                rest = String(rest[found.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        rest = rest.replacingOccurrences(of: thanks, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: separators)
        // What came before the request counts too: "Meu cachorro se chama Thor, memorize isso tbm".
        let before = text[..<matched.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:-–— ")))
        let pointsBack = rest.isEmpty || pointers.contains(MemoryText.fold(rest))
        let content = pointsBack ? (before.count >= 8 ? before : nil) : rest
        return MemoryIntent(content: content.map { String($0.prefix(600)) })
    }

    /// A closing "obrigada", "valeu", "thanks" after the request, which is neither a task nor part of what to keep.
    private static let thanks = #"[.!?,]?\s*(?<![\p{L}])(?:obrigad[oa]|brigad[oa]|valeu|thanks|thank you)[\s.!]*$"#

    /// Whether what follows a loose "lembra que…" goes on to another sentence or a task ("…; investiga", "…, so add
    /// retries"), as opposed to ending there, with at most a thanks ("Lembra que o Dr. Silva é meu médico. Obrigada").
    private static func carriesATask(_ after: Substring) -> Bool {
        var text = String(after)
        text = text.replacingOccurrences(of: #"\b(dr|dra|sr|sra|srta|prof|profa|mr|mrs|ms)\."#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: thanks, with: "", options: .regularExpression)
        return text.range(of: #";|,\s*(?:so|then|entao)\b|[.!?]\s+\S"#, options: .regularExpression) != nil
    }

    /// Whether a verb right after `before` starts a sentence or clause: at the start of the text, after `. ! ? ; : ,`
    /// or a line break, or after nothing but courtesies ("por favor", "pode", "can you").
    private static func opensClause(_ before: Substring) -> Bool {
        let boundaries: Set<Character> = [".", "!", "?", ";", ":", ",", "\n"]
        let clause = before.lastIndex(where: boundaries.contains).map { before[before.index(after: $0)...] } ?? before
        var rest = clause.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while !rest.isEmpty, let lead = leads.first(where: { rest == $0 || rest.hasPrefix($0 + " ") }) {
            rest = String(rest.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        return rest.isEmpty
    }

    /// `rest` without a leading "isso", "na memória", "aí", "por favor"… when it's followed by a space, `: ; ,` or nothing.
    private static func dropComplement(from rest: String) -> String? {
        for complement in complements {
            guard let found = rest.range(of: complement, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else { continue }
            let tail = rest[found.upperBound...]
            guard tail.isEmpty || tail.first.map({ $0.isWhitespace || ":;,.".contains($0) }) == true else { continue }
            return tail.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;,.-–— ")))
        }
        return nil
    }

    /// "Remember / save / don't forget", as requests to keep something (folded: no accents, lowercase).
    private static let trigger: NSRegularExpression = {
        // The phrase ends there ("keep this in mind: …", "guarda isso."), or only a courtesy follows: otherwise it is
        // part of a task ("keep this in mind when refactoring", "guarda isso no cache").
        let closes = #"(?=[ \t]*(?:[:;,.!\n]|$)|\s+(?:por favor|pfv|pf|please|ai|tambem|tbm|too)\b)"#
        let verbs = [
            #"memoriz(?:e|a|ar)\b"#,
            #"(?<!me )(?<!te )lembr(?:e|a)(?:-se| se)? (?:de que|que|disso|disto|sempre que)\b"#,
            #"(?<!me )(?<!te )lembr(?:e|a)(?:-se| se)?\s*:"#,
            #"guard(?:e|a|ar) (?:essa informacao|na (?:sua )?memoria|que)\b"#,
            #"guard(?:e|a|ar) (?:isso|isto)"# + closes + #"|guard(?:e|a|ar) (?:isso|isto) na (?:sua )?memoria"#,
            #"guard(?:e|a) ai\b(?=\s*(?:[:;,.!]|$)|\s+que\b)"#,
            #"anot(?:e|a|ar) (?:isso|isto|na (?:sua )?memoria)\b"#, #"anot(?:e|a) (?:ai|isso) que\b"#,
            #"nao (?:se )?esquec(?:a|e)(?:r)? (?:de que|que|disso|isso|dessa|desse)\b"#,
            #"nao (?:se )?esquec(?:a|e)\s*:"#,
            #"(?:salv|grav)(?:e|a|ar) (?:isso |isto )?na (?:sua )?memoria"#,
            // "Salva isso." is saving a file, not remembering: only "salva isso: …" (with what to keep) counts.
            #"(?:salv|grav)(?:e|a) (?:isso|isto)(?=\s*:\s*\S)"#,
            #"remember(?= that\b)|remember this\b"#, #"remember\s*:"#, #"(?:save|store|keep) (?:this|that|it) (?:in|to) (?:your )?memory"#,
            #"keep (?:this|that|it) in mind"# + closes, #"keep in mind(?= that\b)"#,
            #"(?:don'?t|do not) forget(?= that\b)|(?:don'?t|do not) forget this\b"#, #"(?:don'?t|do not) forget\s*:"#, #"memorize\b"#,
        ]
        return try! NSRegularExpression(pattern: #"(?<![\p{L}])(?:"# + verbs.joined(separator: "|") + ")")
    }()

    /// Words that may come before the verb without taking away its place at the start of the sentence.
    private static let leads = ["por favor", "pfv", "pf", "please", "e", "ah", "tambem", "tbm", "entao", "ok", "agora", "pode", "poderia",
                                "voce pode", "voce poderia", "vc pode", "can you", "could you", "would you", "will you",
                                "also", "and", "then", "oi", "ola", "ei", "hey", "hi", "hello", "mas", "so que", "so", "but"]
    /// What can follow the verb without being the content ("guarda isso na memória", "memorize isto: …", "…, por favor").
    private static let complements = ["na sua memória", "na memória", "isso", "isto", "disso", "disto", "aí",
                                      "tambem", "tbm", "too", "por favor", "pfv", "pf", "please"]

    /// Words between the verb and the content ("memorize que …", "lembre-se de que …").
    private static let fillers = ["isso que", "isto que", "de que", "na sua memória que", "na memória que", "na sua memória",
                                  "na memória", "disso:", "isso:", "this:", "que", "that,", "that", "this"]
    /// Content that only points at something said before.
    private static let pointers: Set<String> = ["isso", "isto", "disso", "disto", "essa", "esse", "dessa", "desse",
                                                "essa informacao", "isso tambem", "isso tbm", "isso ai", "this", "that",
                                                "it", "this too", "tambem", "tbm", "por favor", "pfv", "pf", "please"]
}
