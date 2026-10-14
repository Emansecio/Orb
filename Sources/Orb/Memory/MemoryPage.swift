import Foundation
import NaturalLanguage

// Each Orb's memory is a folder of plain markdown pages (the source of truth, editable by hand or in Obsidian)
// plus a derived SQLite index for search. The design follows akitaonrails/ai-memory, reduced to one Orb and
// run inside the app: no server, no LLM required.

/// What a page holds, which decides where it lives, whether it always reaches the prompt and whether it ages.
enum MemoryKind: String, CaseIterable, Sendable {
    /// Who the Orb is and how it should work (one page, set at creation, grown by the first-conversation interview).
    case identidade
    /// The user's preferences with this Orb. Always in the prompt (within its share of the budget).
    case preferencia
    /// Durable facts. Searched, never aged.
    case fato
    /// How the user likes things done ("para publicar, rode X e depois Y"). Searched, never aged.
    case procedimento
    /// One page per conversation stretch, written automatically. Ages and is compacted when cold.
    case sessao

    var folder: String {
        switch self {
        case .identidade: "nucleo"
        case .preferencia: "preferencias"
        case .fato: "fatos"
        case .procedimento: "procedimentos"
        case .sessao: "sessoes"
        }
    }

    var label: String {
        switch self {
        case .identidade: "Identidade"
        case .preferencia: "Preferência"
        case .fato: "Fato"
        case .procedimento: "Procedimento"
        case .sessao: "Conversa"
        }
    }

    /// Always reaches the prompt and never ages (ai-memory's pinned slots). These are standing instructions.
    var isPinned: Bool { self == .identidade || self == .preferencia }
}

/// Who wrote a page.
enum MemoryOrigin: String, Sendable {
    /// You, by hand, when creating the Orb or by asking it to remember.
    case voce
    /// The Orb, through `remember`.
    case orb
    /// Written by the app at the end of a conversation.
    case automatico
}

/// One markdown page: a small frontmatter block and a body.
struct MemoryPage: Equatable, Sendable {
    /// Path inside the Orb's memory folder, e.g. "fatos/mora-em-sao-paulo-1a2b.md".
    var path: String
    var kind: MemoryKind
    var title: String
    var body: String
    var created: Date
    var updated: Date
    var origin: MemoryOrigin
    /// Sessions only: replaced by a short version (the original is kept in `_arquivo/`).
    var compacted = false
    /// Identity only: the Orb still has to interview the user in its first conversation.
    var interviewPending = false
    /// Frontmatter lines the app doesn't use (e.g. Obsidian `tags`), kept as they were.
    var extraFields: [String] = []

    func markdown() -> String {
        var lines = ["---",
                     "tipo: \(kind.rawValue)",
                     "titulo: \(MemoryText.flatten(title))",
                     "criado: \(created.formatted(.iso8601))",
                     "atualizado: \(updated.formatted(.iso8601))",
                     "origem: \(origin.rawValue)"]
        if compacted { lines.append("compactado: sim") }
        if kind == .identidade { lines.append("entrevista: \(interviewPending ? "pendente" : "feita")") }
        lines += extraFields
        lines += ["---", "", body.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        return lines.joined(separator: "\n")
    }

    /// Reads a page written by `markdown()` or by hand (CRLF line endings, missing fields and plain notes without
    /// frontmatter all work).
    static func parse(_ text: String, path: String, modified: Date = .now) -> MemoryPage {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var fields: [String: String] = [:], extra: [String] = []
        var bodyLines = lines[...]
        // Frontmatter only when the block between the first two `---` lines looks like `key: value` lines (a
        // plain note may start with a horizontal rule).
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines[1..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains(":") || $0.hasPrefix(" ") || $0.hasPrefix("-") }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") else {
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { extra.append(line) }
                    continue
                }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                if known.contains(key) { fields[key] = value } else { extra.append(line) }
            }
            bodyLines = lines[(end + 1)...]
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = path.components(separatedBy: "/").first ?? ""
        let kind = fields["tipo"].flatMap { MemoryKind(rawValue: $0.lowercased()) }
            ?? MemoryKind.allCases.first { $0.folder == folder } ?? .fato
        let fallbackTitle = body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? path
        return MemoryPage(path: path, kind: kind,
                          title: fields["titulo"].flatMap { $0.isEmpty ? nil : $0 } ?? String(fallbackTitle.prefix(80)),
                          body: body,
                          created: fields["criado"].flatMap(date) ?? modified,
                          updated: fields["atualizado"].flatMap(date) ?? modified,
                          origin: fields["origem"].flatMap(MemoryOrigin.init) ?? .voce,
                          compacted: fields["compactado"] == "sim",
                          interviewPending: fields["entrevista"] == "pendente",
                          extraFields: extra)
    }

    private static let known: Set<String> = ["tipo", "titulo", "criado", "atualizado", "origem", "compactado", "entrevista"]

    /// ISO 8601 with or without fractional seconds, or a plain date ("2026-10-07").
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day()))
    }
}

// MARK: - Text helpers

enum MemoryText {
    /// File-name-safe slug: lowercase ASCII letters, digits and dashes.
    static func slug(_ text: String, limit: Int = 48) -> String {
        let folded = fold(text)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { slug.unicodeScalars.append(scalar) }
            else if !slug.hasSuffix("-") { slug.append("-") }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    /// Words for comparing and searching: lowercase, no accents, without common stopwords. Numbers and two-letter
    /// words count ("Node 20" ≠ "Node 22", "SP" ≠ "RJ").
    static func words(_ text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) && ($0.count >= 2 || $0.contains(where: \.isNumber)) }
    }

    /// Word-set overlap 0...1 (Jaccard) over light stems, so "reunião" and "reuniões" count as the same word.
    /// Near-duplicates score ≥ 0.75.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(words(a).map(stem)), y = Set(words(b).map(stem))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// FTS5 query matching any meaningful word of `text` by prefix, with its singular/plural variants ("reunião" ↔
    /// "reuniões", "animal" ↔ "animais", "papel" ↔ "papéis"). The longest words go first, so a long message keeps its
    /// topic within `limit` terms. Each term is quoted, so punctuation can't break the syntax.
    static func ftsQuery(_ text: String, limit: Int = 16) -> String? {
        var seen = Set<String>(), unique: [String] = [], terms: [String] = []
        for word in words(text) where seen.insert(word).inserted { unique.append(word) }
        seen = []
        for word in unique.sorted(by: { $0.count > $1.count }) {
            for variant in variants(word) where seen.insert(variant).inserted {
                terms.append(prefixes(variant) ? "\"\(variant)\"*" : "\"\(variant)\"")
            }
            if terms.count >= limit { break }
        }
        return terms.isEmpty ? nil : terms.prefix(limit).joined(separator: " OR ")
    }

    /// Whether a variant is long enough to match by prefix: "sp"* would match "sprint", so short ones match exactly.
    static func prefixes(_ variant: String) -> Bool { variant.count >= 4 }

    /// Acknowledgements and pleasantries (folded): a message made only of these, with `greetings`, says nothing to look up.
    private static let chatter: Set<String> = [
        "oi", "ola", "obrigado", "obrigada", "valeu", "vlw", "blz", "beleza", "ok", "okay", "certo", "sim", "nao", "tchau", "perfeito",
        "otimo", "otima", "legal", "show", "entendi", "entendido", "combinado", "fechado", "massa", "top", "maravilha", "excelente",
        "thanks", "thank", "thx", "yes", "nope", "sure", "great", "cool", "nice", "hello", "hi", "hey", "bye", "please", "pls",
    ]
    private static let greetings: Set<String> = ["bom", "boa", "dia", "tarde", "noite", "tudo", "bem", "morning", "afternoon", "evening"]

    /// The verbs, quantifiers and question words of everyday requests ("você lembra…", "pode me dizer…", "quantos…"):
    /// they say how the user asks, not what about, and a memory page rarely has them. They count for nothing when
    /// looking for related memories, or a natural question would need pages with words that are not its topic.
    private static let fillers: Set<String> = [
        "lembra", "lembrar", "lembro", "lembrou", "lembrando", "sabe", "saber", "sei", "sabia", "pode", "posso", "podia", "poderia",
        "dizer", "diz", "diga", "disse", "fala", "falar", "fale", "conta", "contar", "conte", "quero", "queria", "preciso", "precisa",
        "precisava", "gostaria", "fazer", "faz", "faca", "fez", "ver", "veja", "mostra", "mostrar", "mostre", "ajuda", "ajudar",
        "pergunta", "perguntar", "quantos", "quantas", "quanto", "quanta", "quem", "algo", "alguma", "algum", "coisa", "coisas",
        "tipo", "tudo", "nada", "todo", "toda", "todos", "todas", "agora", "sempre", "vez", "favor", "ser", "esta", "estou", "vou", "vai",
        "remember", "know", "tell", "say", "can", "could", "would", "will", "want", "need", "what", "how", "who", "does", "did",
        "many", "much", "about", "my", "your", "something", "anything",
    ]
    /// Nouns that often only complete a question ("o nome do meu cachorro", "quantos anos"): left out unless they are all
    /// the message has ("qual é o meu nome?").
    private static let weak: Set<String> = ["nome", "anos", "ano", "name", "years", "year"]

    /// The distinct words (by stem) of `text` that say what it is about, for finding related memories: without the
    /// pleasantries ("obrigado", "ok", "valeu"), the fillers of a question (see `fillers`) and a lone greeting or a lone
    /// two-letter word. Empty when the message has nothing to look up.
    static func topicTerms(_ text: String) -> [String] {
        let spoken = words(text).filter { !chatter.contains($0) }
        guard !spoken.allSatisfy(greetings.contains) else { return [] }
        let base = spoken.filter { !fillers.contains($0) }
        let strong = base.filter { !weak.contains($0) }
        let topic = strong.isEmpty ? base : strong
        if topic.count == 1, let only = topic.first, only.count < 3, !only.contains(where: \.isNumber) { return [] }
        var seen = Set<String>()
        return topic.filter { seen.insert(stem($0)).inserted }
    }

    /// The terms to look memories up by for `message` in a conversation about `context` (the task in progress): the
    /// message's own topic, unless it only points back at the task ("faz igual ao anterior", "continua", "de novo"), when
    /// the words of the task stand in for the ones it leaves out. A message with a topic of its own keeps it alone.
    static func lookupTerms(_ message: String, context: String) -> [String] {
        let own = topicTerms(message)
        let rest = own.filter { !pointers.contains($0) }
        // All the words, stopwords too: "isso" and "it" point back as well as "anterior" does.
        let tokens = fold(message).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let spaced = " " + tokens.joined(separator: " ") + " "
        guard rest.count < 2, tokens.contains(where: pointers.contains) || pointingPhrases.contains(where: { spaced.contains(" \($0) ") })
        else { return own }
        var seen = Set(rest.map(stem))
        let task = topicTerms(context).filter { !pointers.contains($0) && seen.insert(stem($0)).inserted }
        return rest + task.prefix(contextTerms)
    }

    /// How many of the task's words a message that points back borrows: the latest request comes first in `context`.
    static let contextTerms = 6
    /// Words (folded) a message uses to point at the task in progress instead of naming it.
    private static let pointers: Set<String> = [
        "anterior", "igual", "mesmo", "mesma", "mesmos", "mesmas", "novamente", "denovo", "continua", "continue", "continuar",
        "isso", "disso", "nisso", "aquilo", "daquilo", "dele", "dela", "deles", "delas", "again", "same", "previous", "that", "it",
    ]
    /// The same, said in two words ("faz de novo"; "novo" alone names something new).
    private static let pointingPhrases = ["de novo", "outra vez", "one more time"]

    /// How many of `terms` appear in `text` (as a word, or the start of one, singular or plural).
    static func matchCount(of terms: [String], in text: String) -> Int {
        let tokens = Set(words(text))
        return terms.filter { term in
            variants(term).contains { form in tokens.contains { prefixes(form) ? $0.hasPrefix(form) : $0 == form } }
        }.count
    }

    /// The words of `text` (folded, as in `words`) that name what it is about: nouns, plus words the tagger has no lemma
    /// for (proper names, foreign terms like "node" or "checkout"). Verbs, adverbs and the like are left out. Empty when
    /// the tagger recognizes nothing. `tagger` is reused by the caller (it needs `.lexicalClass` and `.lemma`).
    static func topicNouns(_ text: String, tagger: NLTagger) -> Set<String> {
        guard !text.isEmpty else { return [] }
        tagger.string = text
        tagger.setLanguage(.portuguese, range: text.startIndex..<text.endIndex)
        var nouns = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            let hasLemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0 != nil
            if tag == .noun || !hasLemma { nouns.formUnion(words(String(text[range]))) }
            return true
        }
        return nouns
    }

    /// Whether `term` is one of the topic words `nouns`: equal, or sharing the first four letters ("cachorros" ~ "cachorro").
    static func isTopic(_ term: String, in nouns: Set<String>) -> Bool {
        nouns.contains { $0 == term || ($0.count >= 4 && term.count >= 4 && $0.prefix(4) == term.prefix(4)) }
    }

    /// Light Portuguese stem used for comparing: plural and "-ão/-ões/-ães" endings removed.
    static func stem(_ word: String) -> String {
        for (suffix, keep) in [("oes", 2), ("aes", 2), ("ao", 2), ("ais", 3), ("eis", 3), ("es", 4), ("s", 3)]
        where word.hasSuffix(suffix) && word.count - suffix.count >= keep {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Search prefixes for a folded word: itself and its usual singular/plural partners.
    static func variants(_ word: String) -> [String] {
        var forms = [word]
        func swap(_ suffix: String, _ replacements: [String]) {
            guard word.hasSuffix(suffix), word.count > suffix.count + 1 else { return }
            let root = String(word.dropLast(suffix.count))
            forms += replacements.map { root + $0 }
        }
        swap("oes", ["ao"]); swap("aes", ["ao"]); swap("aos", ["ao"]); swap("ao", ["oes", "aes"])
        swap("ais", ["al"]); swap("al", ["ais"]); swap("eis", ["el"]); swap("el", ["eis"])
        if word.count > 4, word.hasSuffix("es") { forms.append(String(word.dropLast(2))) }
        if word.count > 3, word.hasSuffix("s") { forms.append(String(word.dropLast())) }
        return forms
    }

    /// Shortens to `limit` characters on a word boundary.
    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(limit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    /// One line: whitespace and newlines collapsed, control characters and leading `#` removed. Used for anything
    /// that came from a conversation before it goes into a title or the prompt, so it can't fake a section.
    static func flatten(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }))
        return cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    /// Paths, URLs and `code` spans: what a compacted page keeps (ai-memory's extractive tier-down).
    static func keepTokens(_ text: String, limit: Int = 20) -> [String] {
        var tokens: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for (index, regex) in tokenPatterns.enumerated() {
            for match in regex.matches(in: text, range: range) {
                guard let found = Range(match.range, in: text) else { continue }
                var token = String(text[found])
                if index == 0 { token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
                // A path inside a URL already found is the same reference.
                if index == 1, tokens.contains(where: { $0.contains(token) }) { continue }
                if !tokens.contains(token) { tokens.append(token) }
                if tokens.count == limit { return tokens }
            }
        }
        return tokens
    }

    private static let tokenPatterns = [#"https?://[^\s)>\]"'`]+"#, #"(?<![\w/.:])(?:~|/)[\w.\-]+(?:/[\w.\-]+)+"#, #"`[^`\n]{2,80}`"#]
        .map { try! NSRegularExpression(pattern: $0) }

    private static let stopwords: Set<String> = [
        "que", "para", "com", "uma", "por", "mais", "como", "mas", "foi", "ele", "ela", "das", "dos", "nos", "nas",
        "seu", "sua", "seus", "suas", "isso", "esse", "essa", "este", "esta", "aqui", "ali", "tem", "ter", "sao",
        "estao", "muito", "pra", "pro", "voce", "voces", "meu", "minha", "meus", "minhas", "quando", "onde",
        "qual", "quais", "sobre", "tambem", "ainda", "entao", "porque", "pois", "num", "numa", "pelo", "pela",
        "em", "de", "do", "da", "no", "na", "os", "as", "um", "ao", "se", "eu", "me", "te", "ou", "lhe", "ja", "so",
        "the", "and", "for", "with", "that", "this", "you", "are", "was", "from", "have", "not", "but",
        "to", "of", "in", "on", "at", "is", "it", "be", "an", "or", "by",
    ]
}

/// Removes secrets before anything reaches memory (the transcript can contain commands and outputs with keys). Only
/// literal ones: a value that is a reference (`$TOKEN`, `$(security find-generic-password …)`) or a placeholder
/// (`<chave>`) is no secret, and says where the credential is kept.
enum MemorySanitizer {
    /// What a value that only points at the credential looks like: a command (`$(…)`), `${NAME}`, a variable (`$NAME` or
    /// `$name`, whole: followed by the end, a quote, a space, `;`, `)`, `/` or `&`, or by a backtick, `,`, `.`, `]` or `}` that
    /// itself ends there: `--token=$NPM_TOKEN`, `$DB_PASSWORD,`, but not `$HUNTER.2024`) or a closed placeholder (`<chave>`). A value that
    /// merely starts with `$` or `<` is a literal one (`$enh@F0rte!`, `$3cr3t`, `$Lit3ral`, `<abc123def`): a variable is
    /// UPPER_CASE or lower_case, and a name that mixes cases (or a lower-case one with digits) is a password. (The rules are case-insensitive; `(?-i:` keeps these two cases apart.)
    private static let reference = #"(?-i:\$(?:\(|\{|(?:[A-Z_][A-Z0-9_]*|[a-z_]+)(?=["'\s;)/&]|[`,.\]}](?=["'`\s;)\]},.&]|$)|$))|<[^<>\n]{1,80}>)"#
    /// In a URL the password ends at the `@`, so only an upper-case variable is told apart there (`:$DB_PASSWORD@`).
    private static let urlReference = #"(?-i:\$(?:\(|\{|[A-Z_][A-Z0-9_]*(?=@))|<[^<>\n]{1,80}>)"#

    private static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[chave privada removida]"),
        (#"(?<![A-Za-z0-9])sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}"#, "[chave removida]"),
        (#"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "[token removido]"),
        (#"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9\-]{10,}"#, "[token removido]"),
        (#"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}"#, "[chave removida]"),
        (#"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{30,}"#, "[chave removida]"),
        (#"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "[token removido]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._\-+/=]{12,}"#, "$1 [removido]"),
        // user:password@ in URLs (postgres://, mysql://, https://…); the scheme starts where a scheme can start (see below)
        (#"(?i)(?<![a-z0-9+.\-])([a-z][a-z0-9+.\-]*://[^\s:/@]+):(?!\#(urlReference))[^\s@/]+@"#, "$1:[removido]@"),
        // curl -u user:pass
        (#"(?i)(\s-u\s+[^\s:]+):(?!["']?\#(reference))\S+"#, "$1:[removido]"),
        // KEY=value, MY_TOKEN: value, "password": "value", ?access_token=value (names containing the words below). The
        // name starts where a name can start: tried from every letter of a long run (a hash, base64), it took minutes.
        (#"(?i)(?<![\w.\-])([\w.\-]*(?:password|passwd|senha|secret|segredo|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credential)[\w.\-]*["']?\s*[:=]\s*)(["']?)(?!\#(reference))[^\s"',;&]+"#,
         "$1$2[removido]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func scrub(_ text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }
}
