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

    /// The request in `message`, if there is one.
    static func detect(_ message: String) -> MemoryIntent? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Matching runs on a lowercase, accent-free copy with the same characters, so ranges map back.
        let folded = String(text.map { character in
            let plain = String(character).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            return plain.count == 1 ? Character(plain) : character
        })
        guard folded.count == text.count,
              let match = trigger.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)),
              let foldedRange = Range(match.range, in: folded) else { return nil }
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

        let matched = text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)
        var rest = text[matched.upperBound...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for filler in fillers {
            if let found = rest.range(of: filler + " ", options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
                rest = String(rest[found.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        rest = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;,.-–— ")))
        // What came before the request counts too: "Meu cachorro se chama Thor, memorize isso".
        let before = text[..<matched.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:-–— ")))
        let pointsBack = rest.isEmpty || pointers.contains(MemoryText.fold(rest))
        let content = pointsBack ? (before.count >= 8 ? before : nil) : rest
        return MemoryIntent(content: content.map { String($0.prefix(600)) })
    }

    /// "Remember / save / don't forget", as requests to keep something (folded: no accents, lowercase).
    private static let trigger: NSRegularExpression = {
        let verbs = [
            #"memoriz(?:e|a|ar)\b"#,
            #"(?<!me )(?<!te )lembr(?:e|a)(?:-se| se)? (?:de que|que|disso|disto|sempre que)\b"#,
            #"guard(?:e|a|ar) (?:isso|isto|essa informacao|na (?:sua )?memoria|que)\b"#,
            #"anot(?:e|a|ar) (?:isso|isto|na (?:sua )?memoria)\b"#, #"anot(?:e|a) (?:ai|isso) que\b"#,
            #"nao (?:se )?esquec(?:a|e)(?:r)? (?:de que|que|disso|isso|dessa|desse)\b"#,
            #"(?:salv|grav)(?:e|a|ar) (?:isso |isto )?na (?:sua )?memoria"#,
            #"remember (?:that|this)\b"#, #"(?:save|store|keep) (?:this|that|it) (?:in|to) (?:your )?memory"#,
            #"don'?t forget (?:that|this)\b"#, #"memorize\b"#,
        ]
        return try! NSRegularExpression(pattern: #"(?<![\p{L}])(?:"# + verbs.joined(separator: "|") + ")")
    }()

    /// Words between the verb and the content ("memorize que …", "lembre-se de que …").
    private static let fillers = ["isso que", "isto que", "de que", "na sua memória que", "na memória que", "na sua memória",
                                  "na memória", "disso:", "isso:", "this:", "que", "that", "this"]
    /// Content that only points at something said before.
    private static let pointers: Set<String> = ["isso", "isto", "disso", "disto", "essa", "esse", "dessa", "desse",
                                                "essa informacao", "isso tambem", "isso tbm", "isso ai", "this", "that",
                                                "it", "this too", "tambem", "tbm", "por favor", "pfv", "pf", "please"]
}
