import Foundation

// MARK: - Glob patterns

/// Shell-style glob: `*` and `?` stay inside a path component, `**` crosses folders, `[abc]` / `[!abc]` are
/// character classes and `{a,b}` alternatives. Matching ignores case, like the Mac's usual file systems.
struct GlobPattern: Sendable {
    private let regex: NSRegularExpression
    /// A pattern with a "/" is matched against the whole relative path; one without, against the file name only.
    private let usesFullPath: Bool

    /// `anchored`: match the whole relative path even without a "/" (the pattern of an absolute glob, `/tmp/*.txt`, which
    /// means the files directly in /tmp).
    init(_ glob: String, anchored: Bool = false) throws {
        let trimmed = glob.hasPrefix("./") ? String(glob.dropFirst(2)) : glob
        usesFullPath = anchored || trimmed.contains("/")
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
        ".git", ".hg", ".svn", ".idea", "node_modules", ".build", "DerivedData", "Pods", ".venv", "__pycache__",
        // Build output and caches of the usual toolchains (Gradle, npm bundlers, Cargo, Python): thousands of generated
        // files that bury the real sources. Asking for the folder itself as `path` still searches it.
        "build", "dist", "out", "target", ".gradle", ".next", ".nuxt", "coverage", "venv", ".tox", ".mypy_cache", ".cache",
    ]
    /// Skipped only directly below the user's home folder.
    static let homeSkippedDirectories: Set<String> = ["Library", ".Trash"]
    static let maxFiles = 200_000

    /// `truncated` is set when the walk stopped early (too many files or out of time).
    static func files(under root: URL, deadline: ContinuousClock.Instant) throws -> (files: [WalkedFile], truncated: Bool) {
        let base = root.resolvingLinkChain
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else {
            return ([], false)
        }
        // Walking the home folder itself: ~/Library (caches, containers) and the Trash only bury the real files.
        let isHome = base.path == FileManager.default.homeDirectoryForCurrentUser.resolvingLinkChain.path
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
                if skippedDirectories.contains(item.lastPathComponent)
                    || (isHome && enumerator.level == 1 && homeSkippedDirectories.contains(item.lastPathComponent)) {
                    enumerator.skipDescendants()
                }
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
    /// The largest single file searched when it is named as `path`.
    static let maxStreamedBytes = 200_000_000
    static let defaultTimeBudget = Duration.seconds(20)

    /// How long one search may run before it stops and says so.
    var timeBudget = Self.defaultTimeBudget

    let spec = ToolSpec(
        name: "grep",
        description: """
        Search file contents with an ICU regex; returns `path:line: text`. Recursive in a folder, or one file; skips .git, node_modules, build/dist/target-style \
        folders (pass one as `path` to search it) and binaries. In a folder, files over 5 MB are skipped and named; \
        pass such a file as `path` (up to 200 MB). Narrow with `path` or `include` before raising \
        `max_results`. Prefer it over run_command grep; for file names use glob.
        """,
        parameters: .schema([
            "pattern": .property("string"),
            "path": .property("string", "Folder or file (default: the working directory)."),
            "include": .property("string", "Glob on file names, e.g. \"*.swift\"."),
            "case_insensitive": .property("boolean"),
            "context": .property("integer", "Lines around matches (0-10)."),
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
        guard FileManager.default.fileExists(atPath: root.path) else { throw ToolError.notFound("Caminho não encontrado", root) }
        if !root.isExistingDirectory { try root.requireRegularFile() }
        let deadline = ContinuousClock.now + timeBudget
        let workingDirectory = context.workingDirectory

        // Walking, reading and matching are blocking work; keep them off the cooperative pool.
        return try await runDetached {
            try Self.search(regex: regex, patternText: patternText, mode: mode, contextLines: contextLines, limit: limit,
                            include: include, root: root, workingDirectory: workingDirectory, deadline: deadline)
        }
    }

    /// What one file gave: the lines that matched, and the means to show them (with context) afterwards.
    private struct ScannedFile {
        /// Zero-based line index and the column of the first match. In streamed content mode, capped just past the room left.
        var hits: [(index: Int, column: Int)] = []
        /// How many lines matched (`hits.count` unless counting only).
        var hitCount = 0
        var lineCount = 0
        var line: (Int) -> String? = { _ in nil }
        var timedOut = false
    }

    private static func search(regex: NSRegularExpression, patternText: String, mode: String, contextLines: Int, limit: Int,
                               include: GlobPattern?, root: URL, workingDirectory: URL,
                               deadline: ContinuousClock.Instant) throws -> String {
        var candidates: [WalkedFile]
        var truncated = false
        var withheld = 0
        let singleFile = !root.isExistingDirectory
        if !singleFile {
            let walked = try FileWalker.files(under: root, deadline: deadline)
            candidates = walked.files.filter { include?.matches(relativePath: $0.relativePath) ?? true }
            truncated = walked.truncated
            // Private keys and saved passwords are not read in passing by a search of a folder around them; naming
            // such a folder or file as `path` is a deliberate request (and asks, see `PermissionPolicy`).
            let secrets = DangerousCommand.SensitiveFiles()
            if secrets.reason(for: root.path + "/x") == nil {
                let before = candidates.count
                candidates.removeAll { secrets.reason(for: $0.url.path) != nil }
                withheld = before - candidates.count
            }
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
        /// Files that were not searched because of their size, by the name the model can pass back as `path`.
        var tooLarge: [String] = []
        var limitReached = false

        scan: for candidate in candidates {
            try Task.checkCancellation()
            if ContinuousClock.now > deadline { truncated = true; break }
            let name = FileWalker.display(root, candidate.relativePath, workingDirectory: workingDirectory)
            let scanned: ScannedFile
            if candidate.size <= maxFileBytes {
                guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe),
                      let file = TextFile.decode(data) else { continue }
                let lines = TextFile.lines(of: file.text)
                scanned = scan(lines: lines, regex: regex, mode: mode, deadline: deadline)
            } else if singleFile, candidate.size <= maxStreamedBytes {
                // A log is what read_file sends the model here to search: look through it without loading it as text.
                guard let streamed = try stream(candidate.url, regex: regex, mode: mode, contextLines: contextLines,
                                                room: max(limit - results, 0) + 1, deadline: deadline) else { continue }
                scanned = streamed
            } else {
                tooLarge.append(name)
                continue
            }
            searched += 1
            // A pattern that backtracks without end would otherwise run past the time budget unchecked. What the file gave
            // before the time ran out is kept, and the search stops after it.
            let ranOutOfTime = scanned.timedOut
            if ranOutOfTime {
                try Task.checkCancellation()
                truncated = true
            }
            guard scanned.hitCount > 0 else {
                if ranOutOfTime { break scan }
                continue
            }
            if results >= limit {
                // Something more exists beyond the limit, so the output is truncated rather than just full.
                limitReached = true
                break scan
            }
            matchedFiles += 1
            totalLines += scanned.hitCount

            switch mode {
            case "files":
                output.append(name)
                results += 1
            case "count":
                output.append("\(name): \(scanned.hitCount)")
                results += 1
            default:
                if contextLines > 0, !output.isEmpty { output.append("--") }
                let room = limit - results
                if scanned.hits.count > room { limitReached = true }
                let kept = Array(scanned.hits.prefix(room))
                results += kept.count
                output += contentLines(name: name, lineCount: scanned.lineCount, line: scanned.line, hits: kept, context: contextLines)
            }
            if ranOutOfTime { break scan }
        }

        // However many results the limit allows, one call stays a page the model gets whole (see `ToolOutputBudget`).
        let fitted = ToolOutputBudget.fit(output)
        let cutBySize = fitted.omitted > 0
        output = fitted.kept
        var sizeNote = tooLargeNote(tooLarge, singleFile: singleFile)
        if withheld > 0 {
            let note = "[\(withheld) \(withheld == 1 ? "arquivo" : "arquivos") com chaves ou senhas (.env, .ssh, *.pem…) não \(withheld == 1 ? "foi pesquisado" : "foram pesquisados"); busque neles dando o arquivo como path]"
            sizeNote = [sizeNote, note].compactMap { $0 }.joined(separator: "\n")
        }

        guard !output.isEmpty else {
            var message = "Nenhum resultado para \"\(patternText)\" em \(FileWalker.display(root, "", workingDirectory: workingDirectory)) (\(searched) \(searched == 1 ? "arquivo de texto pesquisado" : "arquivos de texto pesquisados"))."
            if truncated { message += " A busca parou antes de varrer tudo (tempo ou número de arquivos); restrinja path ou include." }
            // An empty answer must not read as "not there" when a file that could hold it was skipped.
            if let sizeNote { message += "\n" + sizeNote }
            return message
        }
        if mode == "count" {
            output.append("Total\(limitReached || cutBySize ? " (até o limite)" : ""): \(totalLines) \(totalLines == 1 ? "linha" : "linhas") em \(matchedFiles) \(matchedFiles == 1 ? "arquivo" : "arquivos").")
        }
        if limitReached {
            output.append("[... resultados truncados em \(limit); refine o padrão, use path ou include, ou aumente max_results ...]")
        }
        if cutBySize {
            output.append("[... saída cortada por tamanho; refine o padrão, use path ou include ...]")
        }
        if truncated {
            output.append("[... a busca parou antes de varrer tudo (tempo ou número de arquivos); restrinja path ou include ...]")
        }
        if let sizeNote { output.append(sizeNote) }
        return output.joined(separator: "\n")
    }

    /// "[2 arquivos acima de 5 MB não foram pesquisados: a.log, b.log; ...]", naming at most three.
    private static func tooLargeNote(_ names: [String], singleFile: Bool) -> String? {
        guard !names.isEmpty else { return nil }
        if singleFile {
            return "[\(names[0]) tem mais de 200 MB e não foi pesquisado; use run_command (grep, rg, sed -n) nele]"
        }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " e mais \(names.count - 3)" : "")
        return "[\(names.count) \(names.count == 1 ? "arquivo acima de 5 MB não foi pesquisado" : "arquivos acima de 5 MB não foram pesquisados"): \(shown); "
            + "para buscar neles passe o arquivo como path]"
    }

    /// The matching lines of a file already split into lines.
    private static func scan(lines: [String], regex: NSRegularExpression, mode: String, deadline: ContinuousClock.Instant) -> ScannedFile {
        var scanned = ScannedFile(lineCount: lines.count, line: { lines.indices.contains($0) ? lines[$0] : nil })
        for (index, line) in lines.enumerated() {
            var timedOut = false
            guard let range = firstMatch(of: regex, in: line, deadline: deadline, timedOut: &timedOut) else {
                if timedOut {
                    scanned.timedOut = true
                    scanned.hitCount = scanned.hits.count
                    return scanned
                }
                continue
            }
            scanned.hits.append((index, range.location))
            if mode == "files" { break }
        }
        scanned.hitCount = scanned.hits.count
        return scanned
    }

    /// Looks through a big file line by line straight from the mapped bytes, keeping only the lines that are shown
    /// (matches and their context). Nil when it is not text this can read (binary, UTF-16): those are skipped like
    /// any binary. Latin-1 lines are decoded per line.
    private static func stream(_ url: URL, regex: NSRegularExpression, mode: String, contextLines: Int, room: Int,
                               deadline: ContinuousClock.Instant) throws -> ScannedFile? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let sample = [UInt8](data.prefix(8192))
        if sample.contains(0) || sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) { return nil }

        var kept: [Int: String] = [:]
        var scanned = ScannedFile()
        var recent: [(index: Int, text: String)] = []
        var afterRemaining = 0
        var cancelled = false
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            var index = 0
            while start < bytes.count {
                if index.isMultiple(of: 4096), Task.isCancelled || ContinuousClock.now > deadline {
                    cancelled = Task.isCancelled
                    scanned.timedOut = true
                    return
                }
                var end = bytes.count
                if let found = memchr(base + start, 10, bytes.count - start) { end = base.distance(to: found) }
                var lineEnd = end
                if lineEnd > start, bytes[lineEnd - 1] == 13 { lineEnd -= 1 }
                let slice = Data(bytes: base + start, count: lineEnd - start)
                let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .windowsCP1252)
                    ?? String(decoding: slice, as: UTF8.self)

                var timedOut = false
                if let range = firstMatch(of: regex, in: text, deadline: deadline, timedOut: &timedOut) {
                    scanned.hitCount += 1
                    if mode == "files" { scanned.lineCount = index + 1; return }
                    if mode == "content" {
                        scanned.hits.append((index, range.location))
                        kept[index] = text
                        for earlier in recent { kept[earlier.index] = earlier.text }
                        afterRemaining = contextLines
                        // `room` counts one hit past what is shown, which only tells that the list is cut.
                        if scanned.hits.count >= room { scanned.lineCount = index + 1; return }
                    }
                } else if timedOut {
                    scanned.timedOut = true
                    return
                } else if afterRemaining > 0 {
                    kept[index] = text
                    afterRemaining -= 1
                }
                if contextLines > 0 {
                    recent.append((index, text))
                    if recent.count > contextLines { recent.removeFirst() }
                }
                start = end + 1
                index += 1
            }
            scanned.lineCount = index
        }
        if cancelled { throw CancellationError() }
        scanned.line = { kept[$0] }
        if scanned.lineCount == 0 { scanned.lineCount = (kept.keys.max() ?? -1) + 1 }
        return scanned
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

    /// `path:line: text` for matches and `path-line- text` for context lines, grep style. `line` gives the text of a
    /// line (nil when it was not kept or is past the end).
    private static func contentLines(name: String, lineCount: Int, line: (Int) -> String?, hits: [(index: Int, column: Int)],
                                     context: Int) -> [String] {
        if context == 0, hits.count > groupedAbove {
            return ["\(name):"] + hits.map { "  \($0.index + 1): \(clip(line($0.index) ?? "", around: $0.column))" }
        }
        var output: [String] = []
        var nextToShow = 0
        let columns = Dictionary(hits.map { ($0.index, $0.column) }, uniquingKeysWith: { first, _ in first })
        for hit in hits {
            let start = max(hit.index - context, nextToShow)
            let end = min(hit.index + context, max(lineCount - 1, hit.index))
            guard start <= end else { continue }
            if context > 0, !output.isEmpty, start > nextToShow { output.append("--") }
            for index in start...end {
                guard let text = line(index) else { continue }
                let isMatch = columns[index] != nil
                output.append("\(name)\(isMatch ? ":" : "-")\(index + 1)\(isMatch ? ":" : "-") \(clip(text, around: columns[index]))")
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
        without "/" matches names at any depth. Skips .git, node_modules and build/dist/target-style folders \
        (pass one as `path` to look inside). Returns up to `max_results` paths (default 200, max 1000). To search \
        inside files use grep.
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
        let requested = try arguments.requiredString("pattern")
        // "/tmp/*.txt" or "~/Downloads/**/*.pdf": the folder part before the first wildcard is the search folder.
        let split = Self.splitAbsolute(requested)
        let patternText = split?.pattern ?? requested
        let root = split.map { URL(fileURLWithPath: $0.folder) }
            ?? arguments.nonEmptyString("path").map(context.url(for:)) ?? context.workingDirectory
        let pattern = try GlobPattern(patternText, anchored: split != nil)
        let limit = arguments.integer("max_results", default: 200, in: 1...1000)
        guard root.isExistingDirectory else { throw ToolError.notFound("Pasta não encontrada", root) }

        let (walked, matches) = try await runDetached {
            let walked = try FileWalker.files(under: root, deadline: .now + .seconds(20))
            let matches = walked.files.filter { pattern.matches(relativePath: $0.relativePath) }
                .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.relativePath < $1.relativePath }
            return (walked, matches)
        }
        guard !matches.isEmpty else {
            return "Nenhum arquivo combina com \"\(patternText)\" em \(root.path)."
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

    /// A pattern that starts with "/" or "~" split into the folder before its first wildcard and the relative pattern
    /// after it (`/tmp/*.txt` → `/tmp`, `*.txt`); nil for relative patterns. Without any wildcard the last component is
    /// the pattern, so an exact path still finds that file.
    static func splitAbsolute(_ pattern: String) -> (folder: String, pattern: String)? {
        guard pattern.hasPrefix("/") || pattern == "~" || pattern.hasPrefix("~/") else { return nil }
        let expanded = (pattern as NSString).expandingTildeInPath
        var parts = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var folder: [String] = []
        while let first = parts.first, !first.contains(where: { "*?[{".contains($0) }), parts.count > 1 {
            folder.append(first)
            parts.removeFirst()
        }
        return ("/" + folder.joined(separator: "/"), parts.joined(separator: "/"))
    }
}
