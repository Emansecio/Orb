import Foundation

/// Checks a reply that ends the turn against what the turn's own calls showed, without asking any model: a build or
/// test that failed last while the reply says the work is done, or a file the reply says it saved that is not there.
/// When one does not hold, the model is reminded (like `AgentEngine.stopReminder`, from the same allowance) to fix it or
/// tell the user. Only clear contradictions count: an edit with no build after it, or a failure the reply owns up to,
/// end the turn as before.
struct CompletionWatch: Sendable {
    /// The last build, test or lint command of the turn and whether it passed.
    private(set) var lastCheck: (command: String, passed: Bool)?

    /// Counts one call that ran (refusals never did). A command still running, sent to the background or started there,
    /// has no verdict yet and changes nothing; nor does one that never started (a folder that is not there).
    mutating func record(_ call: ToolCallRequest, result: String, failed: Bool) {
        guard call.name == "run_command", let command = JSONValue.parse(call.arguments)?["command"]?.string,
              Self.isCheck(command), result.hasPrefix("Código de saída:") || result.contains("[tempo esgotado após")
        else { return }
        lastCheck = (command, !failed)
    }

    /// What to remind the model of before `said` ends the turn, or nil when nothing contradicts it.
    func reminder(for said: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let check = lastCheck, !check.passed, Self.claimsDone(said), !Self.ownsUpToFailure(said) {
            return "Before you finish: the last check you ran (`\(check.command.clipped(to: 120))`) failed and has not passed "
                + "since. Fix it and run it again, or tell the user plainly that it still fails and why; do not report it as done."
        }
        let missing = Self.savedPaths(in: said).filter { !fileExists($0) }
        if !missing.isEmpty {
            return "Before you finish: your reply says you saved \(missing.prefix(3).joined(separator: ", ")), but nothing is "
                + "there. Find where it went or save it again, then give the user the real path."
        }
        return nil
    }

    // MARK: Reading commands and replies

    /// A build, test or lint at the start of a step, after the wrappers that only run it (`cd app && npx jest`,
    /// `nice -n 15 swift test`), not a word inside another command (`git commit -m "make it work"`).
    private static let check = try! NSRegularExpression(
        pattern: #"^\(?\s*(?:\w+=\S*\s+)*(?:(?:sudo|time|nice(?:\s+-n\s*-?\d+)?|caffeinate(?:\s+-\w+)*|npx|bunx|xcrun|(?:uv|poetry|pipenv) run"#
            + #"|python3? -m|bundle exec)\s+)*(?:\./)?(?:swift (?:build|test)|xcodebuild|(?:npm|yarn|pnpm|bun) (?:run )?(?:test|build|lint|typecheck)"#
            + #"|pytest|unittest|cargo (?:test|build|check|clippy)|go (?:test|build|vet)|make|tsc|jest|vitest|eslint|ruff|mypy|flake8|rspec"#
            + #"|phpunit|(?:gradlew?|mvn|dotnet)\b.*\b(?:build|test|verify|package|assemble\w*))\b"#)

    /// Whether `command` runs a check whose exit code is its own: piped into another program (`swift build | tail`),
    /// the last program's code would stand in for it, unless the shell was told `pipefail`.
    static func isCheck(_ command: String) -> Bool {
        let pipefail = command.contains("pipefail")
        let steps = command.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
        return steps.contains { step in
            let stages = step.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let at = stages.firstIndex(where: { matches(check, $0) }) else { return false }
            return pipefail || at == stages.count - 1
        }
    }

    /// "Pronto", "os testes passaram", "all set": the reply says the work is finished or working.
    private static let done = try! NSRegularExpression(
        pattern: #"(?<!não )(?<!nao )(?<!not )\b(pronto|feito|conclu[ií]d[oa]s?|terminei|finalizei|tudo certo|deu certo|funcionando"#
            + #"|funciona|passou|passaram|passando|compila|compilou|resolvid[oa]|corrigid[oa]|done|all set|works|working|passed"#
            + #"|passes|passing|succeeded|compiles|builds|fixed|resolved)\b"#,
        options: [.caseInsensitive])
    /// The reply tells of a failure ("o build falhou", "5 quebraram", "it isn't working"). Not a bare "erro" or
    /// "errors": a report of success says "corrigi os erros" as often.
    private static let failure = try! NSRegularExpression(
        pattern: #"\b(falh\w*|quebr(a|am|ou|aram|ando)|[1-9]\d* (erros?|testes? falh\w*)|ainda (dá erro|da erro)|vermelh[oa]s?"#
            + #"|(com|deu|dá|da) erros?|n[ãa]o (consegui|passou|passaram|compila|funciona)|n[ãa]o foi poss[ií]vel|bloque\w*"#
            + #"|failed|failing|fails|still (fail|break)s?|broken|couldn['’]t|could not|unable)\b|n['’]t (work|pass|build|compile)"#,
        options: [.caseInsensitive])

    static func claimsDone(_ text: String) -> Bool { matches(done, text) }

    static func ownsUpToFailure(_ text: String) -> Bool { matches(failure, text) }

    /// "Salvei / criei / exportei …": a sentence that says something was written somewhere.
    private static let saved = try! NSRegularExpression(
        pattern: #"\b(salvei|criei|gerei|exportei|gravei|escrevi|baixei|copiei|saved|created|wrote|generated|exported|downloaded"#
            + #"|copied)\b|\b(salv|cri|gerad|exportad|gravad)[oa]s? (em|no|na|in|at)\b"#,
        options: [.caseInsensitive])
    /// A sentence that also moves or removes something names paths that are rightly gone, and one that denies or
    /// promises ("não salvei", "vai gerar", "será salvo em") names paths that need not be there yet.
    private static let gone = try! NSRegularExpression(
        pattern: #"\b(mov\w*|apag\w*|remov\w*|exclu\w*|delet\w*|renome\w*|renam\w*|n[ãa]o|nem|vai|v[ãa]o|vou|ser[áa]|ser[ãa]o|quando"#
            + #"|assim que|not|will|once|when|until)\b|n['’]t\b"#, options: [.caseInsensitive])
    /// A path in the Mac's own places: in backticks, or bare with an extension. URL paths ("/api/users.json") stay out.
    private static let path = try! NSRegularExpression(
        pattern: #"`((?:~|/(?:Users|private|tmp|var|Volumes|Applications|opt))/[^`\n]+)`"#
            + #"|(?<![\w/`])((?:~|/(?:Users|private|tmp|Volumes))/[^\s`'"<>()\[\]]+\.[A-Za-z0-9]{1,8})"#)

    /// The paths a reply says it saved to, expanded (`~`) and without the punctuation that ends a sentence.
    static func savedPaths(in text: String) -> [String] {
        let sentences = text.split(whereSeparator: \.isNewline).flatMap { $0.components(separatedBy: ". ") }
        return sentences.filter { matches(saved, $0) && !matches(gone, $0) }.flatMap { sentence in
            path.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)).compactMap { match in
                let found = [1, 2].lazy.compactMap { Range(match.range(at: $0), in: sentence) }.first
                return found.map { (String(sentence[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) as NSString)
                    .expandingTildeInPath }
            }
        }
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
