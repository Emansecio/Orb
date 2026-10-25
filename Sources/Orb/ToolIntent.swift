import Foundation

// What the Orb says an action is for, in words a person watching can read: the model describes a command in the
// infinitive ("Conferir se a vaga do Marcus já saiu") and the interface says it as it is happening ("Conferindo…") or as
// it was ("Conferiu…"). Where the model gave no description, `CommandGist` reads one off the command itself. All of it is
// plain, cheap logic on strings, tested without a view and safe to call from a row's body.

enum ToolIntent {
    /// The longest description kept: a status line, not a paragraph.
    static let limit = 80

    /// The `description` argument of the tools that take one, as the model reads it (the same text in both model paths: the
    /// Claude Code pipe declares the tools from the same `ToolSpec`). Every character is billed in every request: it is short.
    static let schemaText = "What this does, for the person watching: 3-8 words in Brazilian Portuguese, infinitive verb first "
        + "(\"Conferir se a vaga do Marcus já saiu\")."
    /// The same, for a second tool: the first one's text has explained it already.
    static let shortSchemaText = "For the person watching: 3-8 words, Brazilian Portuguese, infinitive verb first."

    /// The model's description as the interface keeps it: one line, white space collapsed, no final period, cut at
    /// `limit`. nil when nothing is left.
    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        var line = words.joined(separator: " ")
        while let last = line.last, last == "." || last == "。" { line.removeLast() }
        if line.count > limit {
            // Cut on a word, so no half word is left at the end.
            var cut = String(line.prefix(limit))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { cut = String(cut[..<space]) }
            line = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return line.isEmpty ? nil : line
    }

    /// `text` with its first word in the gerund ("Conferir se a vaga" → "Conferindo se a vaga"), and the verbs joined to it
    /// too ("Listar modelos e ver o uso" → "Listando modelos e vendo o uso"); as it came when the first word is not an
    /// infinitive.
    static func gerund(_ text: String) -> String {
        conjugate(text) { PortugueseVerb.gerund(of: $0) }
    }

    /// `text` with its first word in the preterite, third person ("Conferir se a vaga" → "Conferiu se a vaga"), and the
    /// verbs joined to it too.
    static func past(_ text: String) -> String {
        conjugate(text) { PortugueseVerb.past(of: $0) }
    }

    /// A tool's title, in the gerund, said as done ("Lendo arquivo" → "Leu arquivo", "Abrindo a pasta" → "Abriu a pasta");
    /// as it came when its first word is not a gerund.
    static func pastOfGerund(_ text: String) -> String {
        fromGerund(text) { PortugueseVerb.past(of: $0) } ?? text
    }

    /// A tool's title, in the gerund, said as what did not work ("Lendo arquivo" → "Falhou ao ler arquivo").
    static func failedGerund(_ text: String) -> String {
        guard let said = fromGerund(text, { $0 }) else { return "Falhou: \(text)" }
        return "Falhou ao " + said.prefix(1).lowercased() + said.dropFirst()
    }

    /// `text` with its first word, a gerund, in the form `form` makes of its infinitive; nil when it is not a gerund.
    private static func fromGerund(_ text: String, _ form: (String) -> String?) -> String? {
        let space = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let word = String(text[..<space])
        guard let infinitive = PortugueseVerb.infinitive(ofGerund: word.lowercased()), let said = form(infinitive) else { return nil }
        let capital = word.first?.isUppercase == true
        return (capital ? said.prefix(1).uppercased() + said.dropFirst() : said) + text[space...]
    }

    /// `past`, to open a sentence: "Conferiu se a vaga".
    static func pastOpening(_ text: String) -> String {
        let said = past(text)
        return said.prefix(1).uppercased() + said.dropFirst()
    }

    /// `past`, to sit in the middle of a sentence: "conferiu se a vaga" (an acronym or a name keeps its capital).
    static func pastInSentence(_ text: String) -> String {
        let said = past(text)
        guard let first = said.first, first.isUppercase else { return said }
        let second = said.dropFirst().first
        return second?.isLowercase == true ? first.lowercased() + said.dropFirst() : said
    }

    private static func conjugate(_ text: String, _ form: (String) -> String?) -> String {
        let space = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let word = String(text[..<space])
        let rest = text[space...]
        guard PortugueseVerb.mayBeInfinitive(word, rest: rest), let conjugated = form(word.lowercased()) else { return text }
        let capital = word.first?.isUppercase == true
        let said = capital ? conjugated.prefix(1).uppercased() + conjugated.dropFirst() : conjugated
        return said + joinedVerbs(rest, form)
    }

    /// The verbs joined to the first one take its form too: a lowercase word right after " e " or ", " that reads as an
    /// infinitive ("modelos e ver o uso", "áudio, transcrever e responder"). Only once the first word was a verb, so a
    /// phrase that does not start with one is left as it came. A capital is a name ("e Terminal"), never a verb.
    private static func joinedVerbs(_ rest: Substring, _ form: (String) -> String?) -> String {
        guard rest.contains(" e ") || rest.contains(", ") else { return String(rest) }
        var words = rest.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices.dropFirst() {
            let before = words[index - 1]
            guard before == "e" || (before.count > 1 && before.hasSuffix(",")) else { continue }
            let word = words[index]
            let comma = word.hasSuffix(",")
            let core = comma ? String(word.dropLast()) : word
            // "e por fim", "e por isso": after " e ", "por" is the preposition; the verb would be written "pôr".
            guard core.first?.isLowercase == true, core != "por",
                  PortugueseVerb.mayBeInfinitive(core, rest: Substring(words[(index + 1)...].joined(separator: " "))),
                  let conjugated = form(core) else { continue }
            words[index] = conjugated + (comma ? "," : "")
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Conjugation

/// The two forms of a Portuguese infinitive the interface needs. Regular verbs follow the endings; the irregular ones of
/// the preterite are a table. Conservative on purpose: a word that is not clearly an infinitive is left alone.
enum PortugueseVerb {
    /// The gerund: -ar → -ando, -er → -endo, -ir → -indo, and pôr and its family → -pondo.
    static func gerund(of infinitive: String) -> String? {
        if let stem = putStem(infinitive) { return stem + "ondo" }
        guard let (stem, ending) = split(infinitive) else { return nil }
        return stem + ending + "ndo"
    }

    /// The infinitive of a gerund: -ando → -ar, -endo → -er, -indo → -ir, and -pondo → -por for pôr and its family.
    static func infinitive(ofGerund word: String) -> String? {
        guard word.count >= 5, word.hasSuffix("ndo"), word.allSatisfy(\.isLetter) else { return nil }
        let stem = String(word.dropLast(4))
        switch word.dropLast(3).last {
        case "a": return stem + "ar"
        case "e": return stem + "er"
        case "i": return stem + "ir"
        case "o":
            let verb = stem + "or"
            return verb == "por" ? "pôr" : pôrFamily.contains(verb) ? verb : nil
        default: return nil
        }
    }

    /// The preterite, third person singular: -ar → -ou, -er → -eu, -ir → -iu, the irregular ones from `irregularPast`.
    static func past(of infinitive: String) -> String? {
        if let irregular = irregularPast[infinitive] { return irregular }
        guard let (stem, ending) = split(infinitive) else { return nil }
        switch ending {
        case "a": return stem + "ou"
        case "e": return stem + "eu"
        default: return stem + "iu"
        }
    }

    /// Whether the first word of a phrase reads as an infinitive: only letters, an -ar, -er, -ir (or pôr/por) ending, not a
    /// noun that happens to end alike, and a phrase that is not English ("Clear the cache" is not Portuguese).
    static func mayBeInfinitive(_ word: String, rest: Substring) -> Bool {
        let lower = word.lowercased()
        guard word.count >= 2, word.allSatisfy(\.isLetter), !notVerbs.contains(lower) else { return false }
        if lower == "por" || lower == "pôr" {
            // "Por que…", "Por causa…" is a preposition.
            let next = rest.split(whereSeparator: \.isWhitespace).first?.lowercased()
            return next != "que" && next != "quê" && next != "causa" && next != "favor"
        }
        guard irregularPast[lower] != nil || split(lower) != nil || putStem(lower) != nil else { return false }
        return !looksEnglish(rest)
    }

    // MARK: Pieces

    /// "confer" and "i" for "conferir"; nil unless it ends in -ar, -er or -ir with something before it (a short word is a
    /// noun: "mar", "par") or is one of the few short verbs ("ler", "rir").
    private static func split(_ word: String) -> (stem: String, ending: String)? {
        guard word.count >= 2 else { return nil }
        let ending = String(word.suffix(2))
        guard ending == "ar" || ending == "er" || ending == "ir" else { return nil }
        let stem = String(word.dropLast(2))
        guard stem.count >= 2 || shortVerbs.contains(word) else { return nil }
        return (stem, String(ending.first!))
    }

    /// "comp" for "compor", "p" for "pôr": the verbs of the family of pôr.
    private static func putStem(_ word: String) -> String? {
        guard pôrFamily.contains(word) else { return nil }
        return String(word.dropLast(2))
    }

    /// An English phrase would be read as Portuguese by its endings ("Filter", "Clear"): its small words give it away.
    private static func looksEnglish(_ rest: Substring) -> Bool {
        guard !rest.isEmpty else { return false }
        for word in rest.split(whereSeparator: { !$0.isLetter }).prefix(6) where englishWords.contains(word.lowercased()) { return true }
        return false
    }

    private static let shortVerbs: Set<String> = ["ir", "ler", "rir", "ver", "ter", "ser", "vir", "dar"]
    /// Nouns and adjectives that end like an infinitive, and English verbs that do (a description in English is left alone).
    private static let notVerbs: Set<String> = [
        "qualquer", "mulher", "colher", "lugar", "talher", "mar", "par", "bar", "lar", "ar", "pior", "melhor",
        // After " e " a noun is as likely as a verb: the ones that end like an infinitive, Portuguese and the English of code.
        "prazer", "celular", "popular", "similar", "familiar", "militar", "escolar", "particular", "solar",
        "nuclear", "linear", "avatar", "radar", "açúcar", "caráter", "líder", "titular", "exemplar", "milhar", "pilar", "dólar",
        "server", "worker", "docker", "container", "router", "parser", "header", "footer", "folder", "buffer", "timer", "user",
        "player", "browser", "manager", "cluster", "poster", "banner", "trigger", "logger", "helper", "compiler", "installer",
        "launcher", "scheduler", "printer", "scanner", "viewer", "adapter", "provider", "loader", "reader", "writer", "builder",
        "runner", "handler", "listener", "controller", "wrapper", "picker", "tracker", "checker", "linter", "formatter", "finder",
        "layer", "computer", "number", "member", "master", "paper", "power",
        "clear", "filter", "gather", "render", "enter", "answer", "offer", "order", "transfer", "consider", "deliver", "discover",
        "cover", "remember", "register", "repair", "appear", "alter", "prefer", "refer", "suffer", "wonder", "hover", "differ",
    ]
    private static let englishWords: Set<String> = ["the", "and", "of", "with", "from", "into", "to", "in", "on", "is", "are", "all", "that", "this", "your", "my"]

    private static let pôrFamily: Set<String> = [
        "pôr", "por", "compor", "repor", "propor", "supor", "dispor", "expor", "impor", "opor", "depor", "transpor", "sobrepor",
    ]

    private static let irregularPast: [String: String] = [
        "fazer": "fez", "desfazer": "desfez", "refazer": "refez", "satisfazer": "satisfez",
        "ver": "viu", "rever": "reviu", "prever": "previu", "antever": "anteviu", "entrever": "entreviu",
        "ter": "teve", "manter": "manteve", "obter": "obteve", "conter": "conteve", "deter": "deteve", "reter": "reteve",
        "pôr": "pôs", "por": "pôs", "compor": "compôs", "repor": "repôs", "propor": "propôs", "supor": "supôs",
        "dispor": "dispôs", "expor": "expôs", "impor": "impôs", "opor": "opôs", "depor": "depôs", "transpor": "transpôs",
        "sobrepor": "sobrepôs",
        "trazer": "trouxe", "dizer": "disse", "ir": "foi", "vir": "veio", "intervir": "interveio", "ser": "foi",
        "estar": "esteve", "poder": "pôde", "querer": "quis", "saber": "soube", "dar": "deu", "haver": "houve", "caber": "coube",
    ]
}

// MARK: - A command, said in a few words

/// What a shell command does, in words, for the line of a tool call that came with no description of its own: the
/// program and its first meaningful argument ("swift build"), or what kind of script runs ("um script Python").
enum CommandGist {
    struct Gist: Equatable {
        /// "um script Python", "swift build".
        var text: String
        /// A script of an interpreter (read as a phrase), not a program and its argument (read as code).
        var isScript: Bool
    }

    private static let skippedSteps: Set<String> = ["cd", "export", "set", "unset", "pushd", "popd", "true", ":"]
    private static let wrappers: Set<String> = ["sudo", "env", "nohup", "time", "exec", "command", "caffeinate"]
    private static let wrapperOptionsWithValue: Set<String> = ["-u", "-g", "-n", "-S", "-C"]
    /// Subcommands that only name a way to run something else: the thing is what tells two runs apart.
    private static let runners: Set<String> = ["run", "exec", "compose", "x", "dlx"]
    private static let interpreters: [String: String] = [
        "python": "Python", "python3": "Python", "node": "Node", "nodejs": "Node", "ruby": "Ruby",
        "sh": "shell", "bash": "shell", "zsh": "shell",
    ]
    private static let inlineFlags: Set<String> = ["-c", "-e", "-p", "-ec", "-lc", "-cl"]

    /// nil for a command with nothing to say.
    static func gist(of command: String) -> Gist? {
        guard let line = significantLine(of: command) else { return nil }
        var segments: [[String]] = [[]]
        for token in tokens(of: line) {
            switch token {
            case "&&", ";":
                if !segments[segments.count - 1].isEmpty { segments.append([]) }
            case "|", "||":
                // A pipe ends what is read: `cat x | head` is about `cat x`.
                if segments[segments.count - 1].isEmpty { continue }
                segments.append([])
                segments.append(["|"]) // marker: nothing after it counts
            default:
                segments[segments.count - 1].append(token)
            }
        }
        var chosen: [String]?
        for segment in segments {
            if segment.first == "|" { break }
            let words = withoutPrefixes(segment)
            guard let first = words.first else { continue }
            if skippedSteps.contains(first) { continue }
            chosen = words
            break
        }
        guard let words = chosen, let program = words.first else { return nil }
        let name = (program as NSString).lastPathComponent
        let rest = Array(words.dropFirst())

        if let language = interpreterLanguage(name) {
            let heredoc = line.contains("<<")
            let inline = rest.contains { inlineFlags.contains($0) }
            let stdin = rest.first == "-"
            if heredoc || inline || stdin || rest.isEmpty { return Gist(text: "um script \(language)", isScript: true) }
        }

        var arguments = rest
        // `git -C dir status`: the options with a value come first.
        if name == "git" {
            while arguments.count >= 2, arguments[0] == "-C" || arguments[0] == "-c" { arguments.removeFirst(2) }
        }
        var parts = [name]
        var index = 0
        if arguments.first == "-m", arguments.count >= 2 { // python -m pytest
            parts.append("-m")
            index = 1
        }
        if let first = arguments[index...].first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("<") && !$0.hasPrefix(">") && !isRedirect($0) }) {
            parts.append(shortened(first))
            if runners.contains(first),
               let next = arguments[(arguments.firstIndex(of: first)! + 1)...].first(where: { !$0.hasPrefix("-") && !isRedirect($0) }) {
                parts.append(shortened(next))
            }
        }
        return Gist(text: parts.joined(separator: " "), isScript: false)
    }

    /// The first line that holds a command: not blank, not a comment. A note the tools add after a blank line ("em ~/x") is
    /// not part of it.
    private static func significantLine(of command: String) -> String? {
        // The start is enough, and a pasted script can be long.
        for line in command.prefix(2_000).split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return trimmed
        }
        return nil
    }

    private static func withoutPrefixes(_ segment: [String]) -> [String] {
        var words = segment[...]
        while let first = words.first {
            if isAssignment(first) { words = words.dropFirst(); continue }
            if wrappers.contains(first) {
                words = words.dropFirst()
                // `sudo -u x cmd`, `env -i A=b cmd`: options and assignments after the wrapper.
                while let next = words.first, next.hasPrefix("-") || isAssignment(next) {
                    // `sudo -u deploy cmd`: the user is the option's value, not the program.
                    words = words.dropFirst(wrapperOptionsWithValue.contains(next) ? 2 : 1)
                }
                continue
            }
            break
        }
        return Array(words)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isRedirect(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        if first == ">" || first == "<" { return true }
        return first.isNumber && (word.contains(">") || word.contains("<")) && word.count <= 4
    }

    /// "python3.12" is Python.
    private static func interpreterLanguage(_ name: String) -> String? {
        if let language = interpreters[name] { return language }
        if name.hasPrefix("python"), name.dropFirst(6).allSatisfy({ $0.isNumber || $0 == "." }) { return "Python" }
        return nil
    }

    /// A path is its last component, a URL its host: what is left of "/Users/x/Projetos/Orb/README.md" is "README.md".
    private static func shortened(_ word: String) -> String {
        if word.contains("://") { return WorkPhrase.host(of: word) ?? word }
        if word.count > 1, word.contains("/") { return WorkPhrase.fileName(word.hasSuffix("/") ? String(word.dropLast()) : word) ?? word }
        return word
    }

    /// The words of one line of shell, quotes removed, the operators `&&`, `||`, `;` and `|` apart. Not a parser: enough to
    /// tell the program from its arguments.
    static func tokens(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        func flush() {
            if started { result.append(current) }
            current = ""
            started = false
        }
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            defer { index += 1 }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                started = true
            case "\\":
                if index + 1 < characters.count { current.append(characters[index + 1]); started = true; index += 1 }
            case " ", "\t":
                flush()
            case ";":
                flush()
                result.append(";")
            case "&" where index + 1 < characters.count && characters[index + 1] == "&":
                flush()
                result.append("&&")
                index += 1
            case "|":
                flush()
                if index + 1 < characters.count, characters[index + 1] == "|" { result.append("||"); index += 1 } else { result.append("|") }
            default:
                current.append(character)
                started = true
            }
        }
        flush()
        return result
    }
}

// MARK: - The words of a tool's line

extension ToolCall {
    /// What the line of the call says, in up to three parts: the words (`main`), what they were done to, written as code
    /// (`code`: the command, the file), and plain words after it (`rest`: a site, a searched phrase, "em segundo plano").
    /// With a description of its own (`intent`) the line is that, in the gerund while it runs and in the preterite after. A
    /// command is "Rodou" and the command itself; any other tool says its verb in the tense of its state and what it acted
    /// on (`WorkPhrase`), or its title and detail when it is not one `WorkPhrase` knows. `hidesDetail`: the detail is not
    /// all on the line and shows when the line opens.
    struct LineWords: Equatable {
        var main: String
        var code: String? = nil
        var rest: String? = nil
        var hidesDetail: Bool
    }

    var lineWords: LineWords {
        if let intent {
            return LineWords(main: state == .running ? ToolIntent.gerund(intent) : ToolIntent.past(intent), hidesDetail: true)
        }
        if let background = Self.commandTitles[title], let line = ShownCommand.line(of: detail) {
            // A script reads as what it is ("Rodou um script Python") before its first line.
            let script = CommandGist.gist(of: detail).flatMap { $0.isScript ? $0.text : nil }
            let main = switch state {
            case .running: script.map { "Rodando \($0)" } ?? "Rodando"
            case .done: script.map { "Rodou \($0)" } ?? "Rodou"
            case .failed: "Falhou"
            }
            return LineWords(main: main, code: line, rest: background ? "em segundo plano" : nil, hidesDetail: true)
        }
        let phrase = WorkPhrase.line(for: self)
        if let target = phrase.target, phrase.verb != title {
            let main = said(phrase.verb)
            let hides = target != detail
            return phrase.style == .code ? LineWords(main: main, code: target, hidesDetail: hides)
                : LineWords(main: main, rest: phrase.shownTarget, hidesDetail: hides)
        }
        return LineWords(main: said(title), rest: detail.isEmpty ? nil : detail, hidesDetail: false)
    }

    /// A verb in the gerund in the tense of the call's state: "Lendo", "Leu", "Falhou ao ler".
    private func said(_ gerund: String) -> String {
        switch state {
        case .running: gerund
        case .done: ToolIntent.pastOfGerund(gerund)
        case .failed: ToolIntent.failedGerund(gerund)
        }
    }

    /// The titles of `run_command`'s calls: true for the background one.
    static let commandTitles = ["Rodando no Terminal": false, "Rodando em segundo plano": true]

    /// Whether the call is a command run in the Terminal (its detail is the command, its output `ShellTool`'s).
    var isCommand: Bool { Self.commandTitles[title] != nil }

    /// The title and the detail the line leaves out, for when it opens (nil: the line says it all).
    var hiddenDetail: (title: String, detail: String)? {
        guard lineWords.hidesDetail, !detail.isEmpty else { return nil }
        return (title, detail)
    }
}

/// A command as the chat shows it: apart from the note the tool adds about where it ran (`RunCommandTool.folderNote`) and, on
/// the line of the call, its first line and how many lines it has.
enum ShownCommand {
    /// The command and the folder it ran in, when the tool noted one.
    static func split(_ detail: String) -> (command: String, folder: String?) {
        guard let note = detail.range(of: RunCommandTool.folderNote, options: .backwards) else { return (detail, nil) }
        let folder = detail[note.upperBound...]
        guard !folder.isEmpty, !folder.contains("\n") else { return (detail, nil) }
        return (String(detail[..<note.lowerBound]), String(folder))
    }

    /// "swift build", or "python3 - <<'EOF' … 18 linhas": the first line that holds a command, whole (the view cuts it in
    /// the middle), and how many lines the command has when it has more than one. nil when there is no command.
    static func line(of detail: String) -> String? {
        let lines = split(detail).command.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first(where: { !$0.hasPrefix("#") }) ?? lines.first else { return nil }
        return lines.count > 1 ? "\(first) … \(lines.count) linhas" : first
    }
}
