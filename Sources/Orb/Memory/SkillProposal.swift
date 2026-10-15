import Foundation

// A skill the Orb proposes to learn (`remember` with tipo skill): a whole SKILL.md that waits in `_propostas/` until
// you read it in the editor and approve it. Nothing becomes a skill by itself, because a skill is an instruction the
// Orb follows from then on. So the proposal has to be worth your attention: the check below sends back, with the
// reasons, whatever is shallow, narrates a day, or repeats a skill that exists, and the model improves it or gives up.

/// A skill as the Orb's tools see it (`_skills.json`, written by the app, read by every process that has the memory).
struct SkillDigest: Codable, Equatable, Sendable {
    var slug: String
    var name: String
    var summary: String
    var instructions: String
    /// The Orb may propose a better version of it (`Skill.isImprovable`).
    var improvable: Bool
}

extension SkillDigest {
    init(_ skill: Skill) {
        self.init(slug: skill.slug, name: skill.name, summary: skill.summary, instructions: skill.instructions,
                  improvable: skill.isImprovable)
    }
}

enum SkillProposalOutcome: Equatable, Sendable {
    /// Waiting for your decision. `isUpdate`: it replaces the instructions of a skill that already exists.
    case proposed(slug: String, isUpdate: Bool)
    /// Not kept; the text says why, so the model can improve it or give up.
    case refused(String)
}

struct SkillRefusal: Error, Equatable, Sendable {
    var problems: [String]

    var message: String {
        "The skill was NOT proposed:\n" + problems.map { "- " + $0 }.joined(separator: "\n") + "\n\n" + SkillProposal.format
    }
}

struct SkillProposal: Equatable, Sendable {
    /// The command (`/slug`) and the file name.
    var slug: String
    /// What the skill does and when to use it: the line the prompt lists.
    var summary: String
    /// The body of the SKILL.md: the four sections.
    var instructions: String
    var modified = Date.distantPast

    /// "Publicar site" for `publicar-site`; you can change it in the editor.
    var name: String {
        let words = slug.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Limits

    static let maximumName = 32
    static let summaryLength = 20...160
    static let maximumBody = 12_000
    static let minimumBody = 500

    /// What the model gets back with a refusal, and what the review prompt asks for.
    static let format = """
        Send the whole file in fact: a --- frontmatter with name (lowercase-with-dashes, up to 32 characters, named for the \
        class of task, e.g. publicar-site) and description (one sentence of 20 to 160 characters: what it does and when to \
        use it), then the sections "## Quando usar", "## Passos" (numbered, imperative, with the exact commands, files or \
        tools, and "if X, do Y" where there is a decision), "## Armadilhas" (a list: each a rule and why) and "## Como verificar". Write in the user's language; the \
        titles may be English (When to use, Steps, Pitfalls, Verification).
        """

    // MARK: Sections

    fileprivate enum Section: CaseIterable {
        case when, steps, pitfalls, verify

        var titles: [String] {
            switch self {
            case .when: ["quando usar", "when to use"]
            case .steps: ["passos", "procedimento", "steps", "procedure"]
            case .pitfalls: ["armadilhas", "pitfalls"]
            case .verify: ["como verificar", "verificacao", "how to verify", "verification"]
            }
        }

        var heading: String { ["## Quando usar", "## Passos", "## Armadilhas", "## Como verificar"][Self.allCases.firstIndex(of: self) ?? 0] }
    }

    /// The text under each known heading (`##` or `###`), leaving code blocks alone (a `# comment` is no heading).
    private static func sections(in body: String) -> [Section: String] {
        var found: [Section: String] = [:]
        var current: Section?
        var inCode = false
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            if !inCode, trimmed.hasPrefix("#") {
                let title = MemoryText.fold(trimmed.drop { $0 == "#" }.trimmingCharacters(in: CharacterSet(charactersIn: " :.")))
                current = Section.allCases.first { $0.titles.contains(title) }
                continue
            }
            if let current { found[current, default: ""] += line + "\n" }
        }
        return found.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The list items of `text` (a number, or a dash too), without their marker and with the lines that follow them
    /// (the code block under a step is part of it).
    private static func items(in text: String, numbered: Bool) -> [String] {
        let marker = numbered ? #"^\s*\d+[.)]\s+"# : #"^\s*(?:\d+[.)]|[-*•])\s+"#
        var found: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let range = line.range(of: marker, options: .regularExpression) {
                found.append(String(line[range.upperBound...]))
            } else if !found.isEmpty {
                found[found.count - 1] += "\n" + line
            }
        }
        return found
    }

    // MARK: Checking

    /// What makes a proposal a diary entry and not a lesson: dates, ticket and session ids, "this session". A bare
    /// "hoje" or "#333" is no sign of it ("agenda de hoje" is a class of task; a color is a color).
    private static let narrative = try! NSRegularExpression(pattern: [
        #"\b\d{4}-\d{2}-\d{2}\b"#, #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
        #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
        #"\b(?:pr|issue|ticket|pull request|chamado)\s*#?\d+\b"#,
        #"\b(?:ontem|yesterday|nesta sessão|nessa sessão|this session|nesta conversa|this conversation)\b"#,
    ].joined(separator: "|"), options: .caseInsensitive)

    /// The day told as a story: the Orb or the user in the first person of the past ("eu rodei", "a usuária pediu"), the
    /// time of the day ("hoje de manhã", "às 14h30"). One of them can be a rule's example; two make a report.
    private static let report = try! NSRegularExpression(pattern: [
        #"\b(?:eu|I)\s+(?:rodei|tentei|fiz|subi|usei|corrigi|descobri|esqueci|ran|tried|did|fixed|found)\b"#,
        // Forms that only exist in the past count without the pronoun ("Primeiro rodei…", "rodamos"): a diary drops the "eu".
        #"\b(?:rodei|tentei|subi|usei|corrigi|descobri|esqueci|fiz|rodamos|corrigimos|tentamos)\b"#,
        // "a usuária pediu" in a rule in the present does not tell the day: "releia o que a usuária pediu", "pergunte se ela ficou…".
        #"(?<!\bque\s)(?<!\bse\s)(?<!\bquando\s)(?<!\bwhat\s)(?<!\bif\s)(?<!\bwhen\s)\b(?:a usuária|o usuário|the user)\s+(?:me\s+)?(?:pediu|disse|confirmou|ficou|reclamou|asked|said|confirmed)\b"#,
        #"\bhoje (?:de manhã|à tarde|à noite)\b|\bthis (?:morning|afternoon)\b|\bàs \d{1,2}h\d{0,2}\b"#,
    ].joined(separator: "|"), options: .caseInsensitive)
    static let reportSigns = 2

    /// A name for the kind of task, not for the day's incident: `fix-`/`debug-`, a ticket-like number (a segment of 3 digits
    /// or more, 4 digits anywhere, `bug123`), `-hoje`. "exportar-x265" and "mp3-para-wav" are classes of task.
    private static let incidentName = try! NSRegularExpression(
        pattern: #"^(?:fix|debug|hotfix|corrigir|consertar)-|(?:^|-)\d{3,}(?:-|$)|\d{4,}|(?:^|-)(?:pr|issue|ticket|chamado|bug)-?\d+|-(?:hoje|today)$"#)

    /// A name or description that covers everything: a skill that fits any task helps with none. "ajuda", "help" and "tudo"
    /// only say it alone (or as "ajuda-geral"): "ajuda-declaracao-irpf" and "help-desk-chamados" are classes of task.
    private static let broadName = try! NSRegularExpression(
        pattern: #"(?:^|-)(?:geral|gerais|general|generic|generico|misc|diversos|qualquer|any|everything)(?:-|$)|^(?:ajuda|help|tudo)$|^(?:tarefas?|tasks?)$"#)
    private static let broadSummary = try! NSRegularExpression(
        pattern: #"\b(?:qualquer|toda e qualquer|todas as|any|every|all)\s+(?:tarefas?|coisas?|pedidos?|assuntos?|requests?|tasks?|things?)\b|\b(?:tudo o que|anything)\b"#,
        options: .caseInsensitive)

    /// A literal in quotes worth naming: two words or more, or one that looks like an expected output (`"ok: 3"`, `"PASS"`, a
    /// path, a digit). `"Ok"` alone fits any task. `body`: what the literal may hold (no closing quote, no line break).
    private static func literal(open: String, close: String, body: String) -> String {
        // Every mark is matched on the literal's own characters, so nothing after the closing quote counts (`"Ok" e siga`),
        // and `.` or `-` only between letters or digits (`v1.2`, `a-b`), not as the end of a sentence (`"Pronto."`).
        open + #"(?=\#(body)*?(?:(?!\s)\#(body)\s+(?!\s)\#(body)|[0-9:=/_]|\w[.\-]\w|(?-i:[A-Z]{3})))"# + body + "{2,}" + close
    }
    private static let straightLiteral = literal(open: #"(?<![\p{L}\p{N}])""#, close: #""(?![\p{L}\p{N}])"#, body: #"[^"\n]"#)

    /// What the Orb's steps can hold that cannot be said of any task: a `command`, a URL, a path or file name, one of the
    /// Orb's tools, an option, a literal in quotes. At least one of them has to be in Passos.
    private static let strongAnchor = try! NSRegularExpression(pattern: [
        #"`[^`\n]+`"#, #"https?://"#, #"(?:^|[\s(])(?:~|\.{1,2})?/[\w.\-]+"#,
        #"\b[\w\-]+\.(?:swift|md|json|sh|py|js|ts|tsx|txt|csv|html|css|ya?ml|toml|plist|xlsx|docx|pdf|png|env)\b"#,
        #"\b(?:\#(toolNames))\b"#, #"(?:^|\s)--?[a-z][\w\-]*"#,
        straightLiteral, literal(open: "“", close: "”", body: "[^”\\n]"), literal(open: "«", close: "»", body: "[^»\\n]"),
    ].joined(separator: "|"), options: .caseInsensitive)
    /// A number with a unit or a format ("2 páginas", "10 min", "80%", "4 linhas"): concrete, but "reserve 5 minutos" is no
    /// procedure, so it only counts next to a strong anchor somewhere in Passos.
    private static let measure = try! NSRegularExpression(
        pattern: #"\b\d+(?:[.,]\d+)?\s?(?:%|(?:min|minutos?|minutes?|h|horas?|hours?|s|seg|segundos?|seconds?|ms|linhas?|lines?|p[aá]ginas?|pages?|px|pt|kb|mb|gb|tb|caracteres|chars?|palavras|words|itens|items|arquivos|files|t[oó]picos|par[aá]grafos|paragraphs)\b)"#,
        options: .caseInsensitive)
    /// A decision ("Se o teste falhar, pare."): the condition is group 1.
    private static let decision = try! NSRegularExpression(
        pattern: #"(?:^|[.;:!?]\s+)(?:se|caso|if|unless)\b([^\n]{3,}?)[,:→]\s*\S"#, options: .caseInsensitive)
    /// What a condition says when it says nothing ("se necessário", "se houver dúvida", "caso algo dê errado", "if needed").
    private static let vagueWords: Set<String> = [
        "houver", "haver", "ha", "for", "forem", "seja", "sejam", "estiver", "estiverem", "der", "dar", "precisar", "precisa", "preciso",
        "necessario", "necessaria", "possivel", "duvida", "duvidas", "incerteza", "problema", "problemas", "erro", "erros", "algo",
        "alguma", "algum", "coisa", "errado", "errada", "mal", "quiser", "querer", "desejar", "preferir", "aplicavel", "relevante",
        "cabivel", "tiver", "tem", "certeza", "ter", "whenever", "needed", "necessary", "possible", "applicable", "relevant", "there",
        "are", "any", "doubt", "doubts", "unsure", "uncertain", "something", "anything", "goes", "go", "wrong", "problem", "problems",
        "error", "errors", "issue", "issues", "want", "wish", "sure", "not", "nao", "you", "it", "its", "that", "dê", "de",
        // A condition on the task or the text itself ("caso a tarefa seja grande", "if the text is long") fits any task.
        "tarefa", "tarefas", "texto", "textos", "resposta", "grande", "grandes", "longo", "longa", "longos", "longas", "extenso",
        "extensa", "curto", "curta", "complexo", "complexa", "complicado", "complicada", "dificil", "dificeis", "facil", "simples",
        "task", "tasks", "text", "texts", "large", "big", "long", "short", "complex", "complicated", "hard", "difficult", "easy", "simple",
        "pedido", "pedidos", "documento", "documentos", "conteudo", "conteudos", "trabalho", "trabalhos", "assunto", "assuntos",
        "demanda", "demandas", "mensagem", "mensagens", "muito", "muita", "muitos", "muitas", "request", "requests", "document",
        "documents", "content", "work", "message", "messages", "very", "too",
    ]
    private static let toolNames = ToolBox.all.map(\.spec.name).filter { $0.contains("_") || $0 == "applescript" }.joined(separator: "|")

    private static func holdsADecision(_ step: String) -> Bool {
        decision.matches(in: step, range: NSRange(step.startIndex..., in: step)).contains { match in
            guard let range = Range(match.range(at: 1), in: step) else { return false }
            return !MemoryText.words(String(step[range])).allSatisfy(vagueWords.contains)
        }
    }

    private static func isConcrete(_ step: String) -> Bool {
        let whole = NSRange(step.startIndex..., in: step)
        return strongAnchor.firstMatch(in: step, range: whole) != nil || measure.firstMatch(in: step, range: whole) != nil || holdsADecision(step)
    }
    static let minimumConcreteSteps = 2

    /// The proposal `text` holds, or why it is not one. `skills`: the Orb's skills, to improve instead of repeating.
    static func validate(_ text: String, among skills: [SkillDigest]) -> Result<SkillProposal, SkillRefusal> {
        let parsed = SkillCatalog.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let slug = parsed.fields["name"] ?? ""
        let summary = MemoryText.flatten(parsed.fields["description"] ?? "")
        let body = parsed.body
        var problems: [String] = []
        func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }

        if parsed.fields.isEmpty { problems.append("There is no frontmatter: start with --- name and description ---.") }
        if slug.isEmpty || slug.count > maximumName || slug != Skill.cleanSlug(slug) || slug != slug.lowercased() {
            problems.append("name must be lowercase letters, digits and dashes, up to \(maximumName) characters (publicar-site), and name the class of task.")
        } else if matches(incidentName, slug) {
            problems.append("The name \"\(slug)\" names one incident (fix-/debug-, a number, today). Name the class of task instead.")
        }
        if matches(broadName, slug) || matches(broadSummary, summary) {
            problems.append("The name or description covers any task (\"geral\", \"qualquer tarefa\"), and a skill for everything helps with nothing. Say which kind of task it is for and what is different about it here.")
        }
        if !summaryLength.contains(summary.count) {
            problems.append("description must be one sentence of \(summaryLength.lowerBound) to \(summaryLength.upperBound) characters (it has \(summary.count)).")
        }
        if body.count < minimumBody || body.count > maximumBody {
            problems.append("The body has \(body.count) characters; a useful skill has \(minimumBody) to \(maximumBody.formatted(.number.grouping(.never))).")
        }

        let found = sections(in: body)
        let missing = Section.allCases.filter { found[$0] == nil }
        if !missing.isEmpty { problems.append("Missing sections: " + missing.map(\.heading).joined(separator: ", ") + ".") }
        if let when = found[.when], when.count < 40 { problems.append("Quando usar is too thin: say which requests and situations call for this skill.") }
        if let steps = found[.steps] {
            let numbered = items(in: steps, numbered: true)
            if numbered.count < 3 || steps.count < 150 {
                problems.append("Passos needs at least 3 numbered, imperative steps (150+ characters).")
            } else if numbered.filter(isConcrete).count < minimumConcreteSteps {
                problems.append("Passos is generic: at least \(minimumConcreteSteps) steps must hold something concrete (a `command`, a file or path, a URL, a tool, an option, a number with its unit, or a decision such as \"Se o teste falhar, pare\"). Say exactly what to do, not \"plan\" and \"review\".")
            } else if !matches(strongAnchor, steps) {
                problems.append("Passos is generic: no step names a `command`, a file or path, a URL, a tool, an option or a literal in quotes. Numbers and \"if needed\" fit any task; say exactly what to run, open or write.")
            }
        }
        if let pitfalls = found[.pitfalls], items(in: pitfalls, numbered: false).filter({ $0.count >= 25 }).count < 2 {
            problems.append("Armadilhas needs at least 2 list items, each a rule and the reason for it.")
        }
        if let verify = found[.verify], verify.count < 30 { problems.append("Como verificar must say how to confirm the result is right (a command, a file, an output).") }

        if matches(narrative, text) {
            problems.append("It narrates one day (a date, a session id, a PR or ticket number, \"ontem\", \"nesta sessão\"). Write rules that stand without the incident.")
        }
        if report.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= reportSigns {
            problems.append("It reads as a report of the day (\"eu rodei\", \"a usuária pediu\", \"hoje de manhã\"). Write the procedure as rules in the imperative, not what happened.")
        }
        if MemorySanitizer.scrub(text) != text {
            problems.append("It contains what looks like a literal secret (key, token, password). Never write the value in a skill: name where it is kept ($VARIABLE, a `security find-generic-password` command, the file).")
        }
        if let same = skills.first(where: { $0.slug == slug }) {
            if !same.improvable { problems.append("/\(slug) came with the app or the catalog and cannot be changed: propose another name.") }
        } else if let close = skills.first(where: { repeats($0, slug: slug, summary: summary, body: body) }) {
            problems.append(close.improvable
                ? "/\(close.slug) already covers this. Improve it: send the corrected whole file with name: \(close.slug)."
                : "/\(close.slug) (from the app or the catalog) already covers this.")
        }
        guard problems.isEmpty else { return .failure(SkillRefusal(problems: problems)) }
        return .success(SkillProposal(slug: slug, summary: summary, instructions: body))
    }

    // MARK: Repeating

    /// Whether the proposal is a skill that exists with other words: the same kind of task (name and summary), or the same
    /// body, because a paraphrase keeps the commands ("npm publish") and most of the vocabulary.
    private static func repeats(_ skill: SkillDigest, slug: String, summary: String, body: String) -> Bool {
        if MemoryText.similarity(skill.name + " " + skill.summary, slug.replacingOccurrences(of: "-", with: " ") + " " + summary) >= 0.5 { return true }
        if MemoryText.similarity(skill.instructions, body) >= 0.4 { return true }
        let mine = commands(in: body)
        let shared = mine.intersection(commands(in: skill.instructions)).count
        // One command in common is not enough alone (two skills may both `npm publish`), but with a quarter of the vocabulary
        // in common as well it is the same procedure in other words.
        if shared >= 1, MemoryText.similarity(skill.instructions, body) >= 0.25 { return true }
        guard mine.count >= 2 else { return false }
        return Double(shared) / Double(mine.count) >= 0.5
    }

    /// Everyday commands that two unrelated skills share.
    private static let everydayCommands: Set<String> = [
        "git status", "git diff", "git add", "git commit", "git push", "git pull", "git log", "git checkout", "git branch", "git stash",
        "git fetch", "git switch", "swift test", "swift build", "npm test", "npm install", "npm run", "pnpm install", "yarn install",
        "pip install", "brew install", "open .", "ls -la", "ls -l", "cd ..",
    ]

    /// The commands a body runs, each by its first two words ("npm publish --access public" is "npm publish"); a file or path
    /// alone counts too. Both the `inline` ones and the lines of a code block.
    private static func commands(in body: String) -> Set<String> {
        var spans: [String] = []
        var inCode = false
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") { spans.append(trimmed) }
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            for match in inlineCode.matches(in: line, range: range) {
                if let found = Range(match.range(at: 1), in: line) { spans.append(String(line[found])) }
            }
        }
        var keys: Set<String> = []
        for span in spans {
            var words = span.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, first == "$" || first == "sudo" { words.removeFirst() }
            if let first = words.first, first.hasPrefix("$"), first.count > 1, words.count > 1 { words[0] = String(first.dropFirst()) }
            let key: String
            if words.count >= 2 { key = words[0] + " " + words[1] }
            else if let only = words.first, only.contains("/") || only.contains(".") { key = only }
            else { continue }
            if !everydayCommands.contains(key) { keys.insert(key) }
        }
        return keys
    }

    private static let inlineCode = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)

    // MARK: File

    /// The SKILL.md as kept in `_propostas/`.
    func markdown() -> String {
        "---\nname: \(slug)\ndescription: \(summary)\n---\n\n\(instructions)\n"
    }

    /// A kept SKILL.md (nil when it was edited into something that is not one).
    static func read(_ text: String, modified: Date) -> SkillProposal? {
        let parsed = SkillCatalog.parse(text)
        guard let slug = parsed.fields["name"], !slug.isEmpty, slug == Skill.cleanSlug(slug), !parsed.body.isEmpty else { return nil }
        return SkillProposal(slug: slug, summary: parsed.fields["description"] ?? "", instructions: parsed.body, modified: modified)
    }
}
