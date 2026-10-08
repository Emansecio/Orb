import Foundation

// MARK: - Glob patterns

/// Shell-style glob: `*` and `?` stay inside a path component, `**` crosses folders, `[abc]` / `[!abc]` are
/// character classes and `{a,b}` alternatives. Matching ignores case, like the Mac's usual file systems.
struct GlobPattern: Sendable {
    private let regex: NSRegularExpression
    /// A pattern with a "/" is matched against the whole relative path; one without, against the file name only.
    private let usesFullPath: Bool

    init(_ glob: String) throws {
        let trimmed = glob.hasPrefix("./") ? String(glob.dropFirst(2)) : glob
        usesFullPath = trimmed.contains("/")
        do {
            regex = try NSRegularExpression(pattern: Self.regex(for: trimmed), options: .caseInsensitive)
        } catch {
            throw ToolError("Padrão glob inválido: \"\(glob)\".")
        }
    }

    func matches(name: String) -> Bool { test(name) }

    func matches(relativePath: String) -> Bool {
        usesFullPath ? test(relativePath) : test(relativePath.split(separator: "/").last.map(String.init) ?? relativePath)
    }

    private func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regex(for glob: String) -> String {
        let characters = Array(glob)
        var output = "^"
        var braces = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        output += "(?:.*/)?"
                        index += 3
                    } else {
                        output += ".*"
                        index += 2
                    }
                    continue
                }
                output += "[^/]*"
            case "?":
                output += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    output += "[" + body + "]"
                    index = close
                } else {
                    output += "\\["
                }
            case "{":
                braces += 1
                output += "(?:"
            case "}":
                if braces > 0 {
                    braces -= 1
                    output += ")"
                } else {
                    output += "\\}"
                }
            case ",":
                output += braces > 0 ? "|" : ","
            default:
                output += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return output + String(repeating: ")", count: braces) + "$"
    }
}

// MARK: - Folder walking

struct WalkedFile: Sendable {
    var url: URL
    /// Path below the folder that was walked, "/"-separated.
    var relativePath: String
    var modified: Date
    var size: Int
}

/// Lists regular files below a folder (links to files included, links to folders not entered), skipping folders that only hold
/// generated or vendored files.
enum FileWalker {
    static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "DerivedData", "Pods", ".venv", "__pycache__",
    ]
    static let maxFiles = 200_000

    /// `truncated` is set when the walk stopped early (too many files or out of time).
    static func files(under root: URL, deadline: ContinuousClock.Instant) throws -> (files: [WalkedFile], truncated: Bool) {
        let base = root.resolvingLinkChain
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return ([], false)
        }
        var files: [WalkedFile] = []
        var visited = 0
        while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited.isMultiple(of: 256) {
                try Task.checkCancellation()
                if ContinuousClock.now > deadline { return (files, true) }
            }
            guard var values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                // Resource values describe the link itself. A link to a file counts as that file (dotfiles repos are
                // full of them); links to folders are not entered.
                guard let target = try? item.resolvingLinkChain.resourceValues(forKeys: Set(keys)) else { continue }
                values = target
            } else if values.isDirectory == true {
                if skippedDirectories.contains(item.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, item.lastPathComponent != ".DS_Store" else { continue }
            // `level` is the depth below the root, which stays right whichever way the file system spells the prefix.
            let relative = item.pathComponents.suffix(enumerator.level).joined(separator: "/")
            files.append(WalkedFile(url: item, relativePath: relative, modified: values.contentModificationDate ?? .distantPast,
                                    size: values.fileSize ?? 0))
            if files.count >= maxFiles { return (files, true) }
        }
        return (files, false)
    }

    /// Path as shown to the model: relative to the working directory when inside it, so it can be passed straight
    /// to read_file and the other tools.
    static func display(_ root: URL, _ relative: String, workingDirectory: URL) -> String {
        let full = relative.isEmpty ? root.path : root.appending(path: relative).path
        let prefix = workingDirectory.path.hasSuffix("/") ? workingDirectory.path : workingDirectory.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }
}

// MARK: - grep

struct GrepTool: AgentTool {
    static let lineLimit = 300
    static let maxFileBytes = 5_000_000
    static let defaultTimeBudget = Duration.seconds(20)

    /// How long one search may run before it stops and says so.
    var timeBudget = Self.defaultTimeBudget

    let spec = ToolSpec(
        name: "grep",
        description: """
        Search file contents with a regex (ICU) and return `path:line: text` (a file with many matches is \
        grouped under a `path:` header, `  line: text` below it). Searches a folder recursively or one file; \
        skips .git, node_modules, build folders, binaries and files over 5 MB. Narrow with `path` or `include` \
        rather than raising `max_results`. Prefer it over run_command grep; for file names use glob.
        """,
        parameters: .schema([
            "pattern": .property("string"),
            "path": .property("string", "Folder or file (default: the working directory)."),
            "include": .property("string", "Glob on file names, e.g. \"*.swift\"."),
            "case_insensitive": .property("boolean"),
            "context": .property("integer", "Context lines around matches (0-10, default 0)."),
            "mode": .property("string", "content (default), files or count."),
            "max_results": .property("integer", "Matches or files (default 100, max 1000)."),
        ], required: ["pattern"]))

    var kind: ToolCall.Kind { .search }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Buscando no conteúdo", arguments["pattern"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let patternText = try arguments.requiredString("pattern")
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: patternText, options: arguments.flag("case_insensitive") ? [.caseInsensitive] : [])
        } catch {
            throw ToolError("Expressão regular inválida: \"\(patternText)\". Para texto literal, escape os caracteres especiais (por exemplo \\( ou \\.).")
        }
        let mode = arguments.nonEmptyString("mode")?.lowercased() ?? "content"
        guard ["content", "files", "count"].contains(mode) else { throw ToolError("mode deve ser \"content\", \"files\" ou \"count\".") }
        let contextLines = mode == "content" ? arguments.integer("context", default: 0, in: 0...10) : 0
        let limit = arguments.integer("max_results", default: 100, in: 1...1000)
        let include = try arguments.nonEmptyString("include").map { try GlobPattern($0) }

        let root = arguments.nonEmptyString("path").map(context.url(for:)) ?? context.workingDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { throw ToolError("Caminho não encontrado: \(root.path)") }
        let deadline = ContinuousClock.now + timeBudget
        let workingDirectory = context.workingDirectory

        // Walking, reading and matching are blocking work; keep them off the cooperative pool.
        return try await runDetached {
            try Self.search(regex: regex, patternText: patternText, mode: mode, contextLines: contextLines, limit: limit,
                            include: include, root: root, workingDirectory: workingDirectory, deadline: deadline)
        }
    }

    private static func search(regex: NSRegularExpression, patternText: String, mode: String, contextLines: Int, limit: Int,
                               include: GlobPattern?, root: URL, workingDirectory: URL,
                               deadline: ContinuousClock.Instant) throws -> String {
        var candidates: [WalkedFile]
        var truncated = false
        if root.isExistingDirectory {
            let walked = try FileWalker.files(under: root, deadline: deadline)
            candidates = walked.files.filter { include?.matches(relativePath: $0.relativePath) ?? true }
            truncated = walked.truncated
        } else {
            let target = root.resolvingLinkChain
            candidates = [WalkedFile(url: target, relativePath: "", modified: .distantPast,
                                     size: (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)]
        }
        candidates.sort { $0.relativePath < $1.relativePath }

        var output: [String] = []
        var results = 0
        var totalLines = 0
        var matchedFiles = 0
        var searched = 0
        var tooLarge = 0
        var limitReached = false

        scan: for candidate in candidates {
            try Task.checkCancellation()
            if ContinuousClock.now > deadline { truncated = true; break }
            guard candidate.size <= maxFileBytes else { tooLarge += 1; continue }
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe),
                  let file = TextFile.decode(data) else { continue }
            searched += 1

            let lines = TextFile.lines(of: file.text)
            var hits: [(index: Int, column: Int)] = []
            var timedOut = false
            for (index, line) in lines.enumerated() {
                guard let range = firstMatch(of: regex, in: line, deadline: deadline, timedOut: &timedOut) else {
                    if timedOut { break }
                    continue
                }
                hits.append((index, range.location))
                if mode == "files" { break }
            }
            if timedOut {
                // A pattern that backtracks without end would otherwise run past the time budget unchecked.
                try Task.checkCancellation()
                truncated = true
                break scan
            }
            guard !hits.isEmpty else { continue }
            if results >= limit {
                // Something more exists beyond the limit, so the output is truncated rather than just full.
                limitReached = true
                break scan
            }
            matchedFiles += 1
            totalLines += hits.count
            let name = FileWalker.display(root, candidate.relativePath, workingDirectory: workingDirectory)

            switch mode {
            case "files":
                output.append(name)
                results += 1
            case "count":
                output.append("\(name): \(hits.count)")
                results += 1
            default:
                if contextLines > 0, !output.isEmpty { output.append("--") }
                let room = limit - results
                if hits.count > room { limitReached = true }
                let kept = Array(hits.prefix(room))
                results += kept.count
                output += contentLines(name: name, lines: lines, hits: kept, context: contextLines)
            }
        }

        // However many results the limit allows, one call stays a page the model gets whole (see `ToolOutputBudget`).
        let fitted = ToolOutputBudget.fit(output)
        let cutBySize = fitted.omitted > 0
        output = fitted.kept

        guard !output.isEmpty else {
            return "Nenhum resultado para \"\(patternText)\" em \(FileWalker.display(root, "", workingDirectory: workingDirectory)) (\(searched) arquivos de texto pesquisados)."
                + (truncated ? " A busca parou antes de varrer tudo (tempo ou número de arquivos); restrinja path ou include." : "")
        }
        if mode == "count" { output.append("Total: \(totalLines) linhas em \(matchedFiles) arquivos.") }
        if limitReached {
            output.append("[... resultados truncados em \(limit); refine o padrão, use path ou include, ou aumente max_results ...]")
        }
        if cutBySize {
            output.append("[... saída cortada por tamanho; refine o padrão, use path ou include ...]")
        }
        if truncated {
            output.append("[... a busca parou antes de varrer tudo (tempo ou número de arquivos); restrinja path ou include ...]")
        }
        if tooLarge > 0 { output.append("[\(tooLarge) arquivos acima de 5 MB foram ignorados]") }
        return output.joined(separator: "\n")
    }

    /// First match in `line`. NSRegularExpression has no time limit of its own, so progress callbacks are used to
    /// give up (`timedOut`) when the deadline passes or the task is cancelled.
    private static func firstMatch(of regex: NSRegularExpression, in line: String, deadline: ContinuousClock.Instant,
                                   timedOut: inout Bool) -> NSRange? {
        var found: NSRange?
        var gaveUp = false
        regex.enumerateMatches(in: line, options: [.reportProgress], range: NSRange(line.startIndex..., in: line)) { result, _, stop in
            if let result {
                found = result.range
                stop.pointee = true
            } else if Task.isCancelled || ContinuousClock.now > deadline {
                gaveUp = true
                stop.pointee = true
            }
        }
        if gaveUp { timedOut = true }
        return found
    }

    /// A file with more matches than this is listed under a single `path:` header (`  line: text` below it), which
    /// spares repeating the path on every line.
    static let groupedAbove = 5

    /// `path:line: text` for matches and `path-line- text` for context lines, grep style.
    private static func contentLines(name: String, lines: [String], hits: [(index: Int, column: Int)], context: Int) -> [String] {
        if context == 0, hits.count > groupedAbove {
            return ["\(name):"] + hits.map { "  \($0.index + 1): \(clip(lines[$0.index], around: $0.column))" }
        }
        var output: [String] = []
        var nextToShow = 0
        let columns = Dictionary(hits.map { ($0.index, $0.column) }, uniquingKeysWith: { first, _ in first })
        for hit in hits {
            let start = max(hit.index - context, nextToShow)
            let end = min(hit.index + context, lines.count - 1)
            guard start <= end else { continue }
            if context > 0, !output.isEmpty, start > nextToShow { output.append("--") }
            for index in start...end {
                let isMatch = columns[index] != nil
                output.append("\(name)\(isMatch ? ":" : "-")\(index + 1)\(isMatch ? ":" : "-") \(clip(lines[index], around: columns[index]))")
            }
            nextToShow = end + 1
        }
        return output
    }

    /// At most 300 characters; a match far into a long line is kept in view.
    static func clip(_ line: String, around column: Int?) -> String {
        guard line.utf8.count > lineLimit, line.count > lineLimit else { return line }
        let characters = Array(line)
        var start = 0
        if let column, let position = Range(NSRange(location: column, length: 0), in: line) {
            start = max(0, min(line.distance(from: line.startIndex, to: position.lowerBound) - 80, characters.count - lineLimit))
        }
        let end = min(start + lineLimit, characters.count)
        return (start > 0 ? "…" : "") + String(characters[start..<end]) + (end < characters.count ? "…" : "")
    }
}

// MARK: - glob

struct GlobTool: AgentTool {
    let spec = ToolSpec(
        name: "glob",
        description: """
        Find files by name pattern, newest first. `**` crosses folders ("**/*.md", "src/**/*.swift"); a pattern \
        without "/" matches names at any depth. Skips .git, node_modules and build folders. Returns up to \
        `max_results` paths (default 200, max 1000). To search inside files use grep.
        """,
        parameters: .schema([
            "pattern": .property("string"),
            "path": .property("string", "Folder (default: the working directory)."),
            "max_results": .property("integer"),
        ], required: ["pattern"]))

    var kind: ToolCall.Kind { .search }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Procurando arquivos", arguments["pattern"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let pattern = try GlobPattern(try arguments.requiredString("pattern"))
        let limit = arguments.integer("max_results", default: 200, in: 1...1000)
        let root = arguments.nonEmptyString("path").map(context.url(for:)) ?? context.workingDirectory
        guard root.isExistingDirectory else { throw ToolError("Pasta não encontrada: \(root.path)") }

        let (walked, matches) = try await runDetached {
            let walked = try FileWalker.files(under: root, deadline: .now + .seconds(20))
            let matches = walked.files.filter { pattern.matches(relativePath: $0.relativePath) }
                .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.relativePath < $1.relativePath }
            return (walked, matches)
        }
        guard !matches.isEmpty else {
            return "Nenhum arquivo combina com \"\(arguments["pattern"]?.string ?? "")\" em \(root.path)."
                + (walked.truncated ? " (A busca parou antes de varrer tudo.)" : "")
        }
        let fitted = ToolOutputBudget.fit(matches.prefix(limit).map {
            FileWalker.display(root, $0.relativePath, workingDirectory: context.workingDirectory)
        })
        var lines = fitted.kept
        if matches.count > lines.count { lines.append("[... mais \(matches.count - lines.count) arquivos; refine o padrão ou o path ...]") }
        if walked.truncated { lines.append("[... a busca parou antes de varrer tudo; restrinja o path ...]") }
        return lines.joined(separator: "\n")
    }
}
