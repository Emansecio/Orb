import Foundation

let filePathDescription = "Absolute path, ~/..., or relative to the working directory."

/// Text files above this are refused (the model should grep or page with the shell instead).
private let maxTextFileBytes = 20_000_000
/// PDFs, documents and images may be bigger than source files.
private let maxDocumentBytes = 100_000_000

struct ReadFileTool: AgentTool {
    /// Longer lines are clipped: minified bundles and data blobs would otherwise eat a whole call.
    static let maxLineLength = 2_000

    let spec = ToolSpec(
        name: "read_file",
        description: """
        Read a file and return its contents. Text files come back as numbered lines (`<number><tab><text>`, like \
        `cat -n`); the number prefix is NOT part of the file, never include it when editing. The encoding (UTF-8, \
        UTF-16, Windows-1252) is detected automatically. Lines longer than 2000 characters are clipped, and one \
        call returns at most ~50,000 characters or `limit` lines, whichever comes first: when it stops early a \
        note gives the `offset` to continue from. Also reads PDFs (text, optional `pages` range), Word/RTF/ODT \
        documents (as text) and images (size plus text found by OCR). Fails on directories and other binaries. \
        HTML is returned as source.
        """,
        parameters: .schema([
            "path": .property("string", filePathDescription),
            "offset": .property("integer", "Text files and documents: 1-based line to start at (default 1)."),
            "limit": .property("integer", "Text files and documents: maximum number of lines to return (default 2000)."),
            "pages": .property("string", "PDFs only: page or range such as \"3\", \"2-5\" or \"4-\" (default: from page 1)."),
        ], required: ["path"]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Lendo arquivo", arguments["path"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = context.url(for: try arguments.requiredString("path")).resolvingLinkChain
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("Arquivo não encontrado: \(url.path)") }
        guard !url.isExistingDirectory else { throw ToolError("\(url.path) é uma pasta; use list_directory.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        if DocumentReader.isPDF(url) || DocumentReader.isImage(url) || DocumentReader.isDocument(url) {
            guard size <= maxDocumentBytes else {
                throw ToolError("\(url.path) é grande demais (\(size) bytes); use run_command para extrair só o que precisa.")
            }
            if DocumentReader.isPDF(url) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let pages = arguments.nonEmptyString("pages")
                return try await runDetached { try DocumentReader.pdfText(data, pages: pages) }
            }
            if DocumentReader.isImage(url) {
                return try await Task.detached(priority: .userInitiated) { try DocumentReader.describeImage(at: url, size: size) }.value
            }
            let text = try await runDetached { try DocumentReader.documentText(at: url) }
            return Self.numbered(TextFile.lines(of: text), arguments: arguments, note: "documento .\(url.pathExtension.lowercased()) convertido em texto")
        }

        guard size <= maxTextFileBytes else {
            throw ToolError("\(url.path) é grande demais (\(size) bytes); use grep ou run_command com head, tail ou sed.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let file = TextFile.decode(data) else {
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            throw ToolError("\(url.path) é um arquivo binário (\(bytes)); não dá para ler como texto. Use run_command (file, strings, xxd) se precisar inspecioná-lo.")
        }
        var notes: [String] = []
        if file.encoding != .utf8 || file.hasBOM { notes.append("codificação \(file.encodingName)") }
        if file.lineEnding == .crlf { notes.append("linhas CRLF") }
        return Self.numbered(TextFile.lines(of: file.text), arguments: arguments, note: notes.isEmpty ? nil : notes.joined(separator: ", "))
    }

    /// `cat -n` style page of `lines`, stopping at the line limit or the character budget.
    static func numbered(_ lines: [String], arguments: JSONValue, note: String?) -> String {
        guard !lines.isEmpty else { return "(arquivo vazio)" }
        let offset = arguments.integer("offset", default: 1, in: 1...Int.max)
        guard offset <= lines.count else { return "O arquivo tem só \(lines.count) linhas; offset=\(offset) está além do fim." }
        let limit = arguments.integer("limit", default: 2000, in: 1...Int.max)

        var entries: [String] = []
        var characters = 0
        var number = offset
        while number <= lines.count, entries.count < limit {
            let label = String(number)
            let entry = String(repeating: " ", count: max(6 - label.count, 0)) + label + "\t" + clip(lines[number - 1])
            if characters + entry.count + 1 > DocumentReader.maxCharacters, !entries.isEmpty { break }
            entries.append(entry)
            characters += entry.count + 1
            number += 1
        }
        var text = (note.map { "(\($0))\n" } ?? "") + entries.joined(separator: "\n")
        if number <= lines.count {
            text += "\n[... mais \(lines.count - number + 1) linhas; use offset=\(number) para continuar ...]"
        }
        return text
    }

    private static func clip(_ line: String) -> String {
        guard line.utf8.count > maxLineLength, line.count > maxLineLength else { return line }
        return line.prefix(maxLineLength) + "… [+\(line.count - maxLineLength) caracteres nesta linha]"
    }
}

struct WriteFileTool: AgentTool {
    let spec = ToolSpec(
        name: "write_file",
        description: """
        Write text (always UTF-8) to a file, creating the file and any missing parent directories. Replaces the \
        whole existing content unless `append` is true; to change part of an existing file use edit_file, which \
        keeps its encoding and line endings. If the path is a symbolic link the link's target is written.
        """,
        parameters: .schema([
            "path": .property("string", filePathDescription),
            "content": .property("string", "Text to write."),
            "append": .property("boolean", "Add to the end of the file instead of replacing it (default false)."),
        ], required: ["path", "content"]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        describe(arguments, context: nil)
    }

    func summary(_ arguments: JSONValue, context: ToolContext) -> (title: String, detail: String) {
        describe(arguments, context: context)
    }

    /// Says whether the file is new or replaced, then shows the start of the content. A relative path can only be
    /// resolved with the context's working directory; without one the line is left out.
    private func describe(_ arguments: JSONValue, context: ToolContext?) -> (title: String, detail: String) {
        let path = arguments["path"]?.string ?? ""
        let content = arguments["content"]?.string ?? ""
        let preview = content.count > 600 ? content.prefix(600) + "\n…" : content
        var lines = [path]
        let resolved: URL? = if let context, !path.isEmpty {
            context.url(for: path)
        } else if path.hasPrefix("/") || path.hasPrefix("~") {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            nil
        }
        if let resolved {
            let target = resolved.resolvingLinkChain
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int
            let append = arguments.flag("append")
            if let size {
                let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                lines.append(append ? "Acrescenta ao final (hoje com \(formatted))" : "Substitui (\(formatted))")
            } else {
                lines.append("Novo arquivo")
            }
        }
        return ("Gravando arquivo", lines.joined(separator: "\n") + (preview.isEmpty ? "" : "\n\n" + preview))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = context.url(for: try arguments.requiredString("path"))
        let target = url.resolvingLinkChain
        var content = try arguments.requiredString("content", allowEmpty: true)
        let append = arguments.flag("append")
        guard !target.isExistingDirectory else { throw ToolError("\(url.path) é uma pasta.") }

        let written = Data(content.utf8)
        if append, FileManager.default.fileExists(atPath: target.path) {
            // Appending UTF-8 bytes to a UTF-16 or Windows-1252 file would corrupt it, so match the file.
            let existing = try Data(contentsOf: target, options: .mappedIfSafe)
            if existing.count <= maxTextFileBytes, let file = TextFile.decode(existing), file.encoding != .utf8 || file.lineEnding == .crlf {
                if file.lineEnding == .crlf {
                    content = content.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
                        .replacingOccurrences(of: "\n", with: "\r\n", options: .literal)
                }
                try FileWriter.write(try file.encoded(file.text + content), to: url)
                return "\(content.utf8.count) bytes acrescentados a \(Self.location(url, target))"
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: written)
        } else {
            try FileWriter.write(written, to: url)
        }
        return "\(written.count) bytes \(append ? "acrescentados a" : "gravados em") \(Self.location(url, target))"
    }

    static func location(_ url: URL, _ target: URL) -> String {
        url.path == target.path ? url.path : "\(url.path) (link simbólico para \(target.path))"
    }
}

struct EditFileTool: AgentTool {
    let spec = ToolSpec(
        name: "edit_file",
        description: """
        Replace an exact piece of text in an existing file. `old_text` must match the file exactly (indentation, \
        spaces, line breaks) and appear once, unless `replace_all` is true; include a few surrounding lines to make \
        it unique. Read the file first, and copy the text without the line-number prefix read_file shows. Keeps the \
        file's encoding, line endings (CRLF) and permissions, and follows symbolic links to the real file. Prefer \
        this over write_file for changes to existing files.
        """,
        parameters: .schema([
            "path": .property("string", filePathDescription),
            "old_text": .property("string", "The exact text to replace (must not be empty)."),
            "new_text": .property("string", "The replacement; empty deletes the old text."),
            "replace_all": .property("boolean", "Replace every occurrence instead of requiring exactly one (default false)."),
        ], required: ["path", "old_text", "new_text"]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    /// A short diff (`-` removed, `+` added) so the approval card shows the change itself.
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let path = arguments["path"]?.string ?? ""
        let diff = Self.diff(old: arguments["old_text"]?.string ?? "", new: arguments["new_text"]?.string ?? "")
        let scope = arguments.flag("replace_all") ? "Todas as ocorrências\n" : ""
        return ("Editando arquivo", path + "\n" + scope + diff)
    }

    static func diff(old: String, new: String, maxLines: Int = 8) -> String {
        func block(_ text: String, prefix: String) -> [String] {
            guard !text.isEmpty else { return [] }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
                .split(separator: "\n", omittingEmptySubsequences: false)
            var shown = lines.prefix(maxLines).map { line in prefix + (line.count > 160 ? line.prefix(160) + "…" : String(line)) }
            if lines.count > maxLines { shown.append(prefix + "… (+\(lines.count - maxLines) linhas)") }
            return shown
        }
        return (block(old, prefix: "- ") + block(new, prefix: "+ ")).joined(separator: "\n")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = context.url(for: try arguments.requiredString("path"))
        let target = url.resolvingLinkChain
        let old = try arguments.requiredString("old_text")
        let new = try arguments.requiredString("new_text", allowEmpty: true)
        let replaceAll = arguments.flag("replace_all")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ToolError("Arquivo não encontrado: \(url.path). Para criar um arquivo novo use write_file.")
        }
        guard !target.isExistingDirectory else { throw ToolError("\(url.path) é uma pasta.") }
        guard old != new else { throw ToolError("old_text e new_text são idênticos; não há nada para alterar.") }
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxTextFileBytes else { throw ToolError("\(url.path) é grande demais para editar (\(size) bytes).") }
        guard let file = TextFile.decode(try Data(contentsOf: target)) else {
            throw ToolError("\(url.path) é um arquivo binário; edit_file só edita texto.")
        }

        let text = file.text as NSString
        var found: (ranges: [NSRange], replacement: String)?
        for (candidateOld, candidateNew) in Self.candidates(old: old, new: new, lineEnding: file.lineEnding) {
            // Exact UTF-16 match first; then canonical equivalence (é as one character or as e + accent).
            for options in [NSString.CompareOptions.literal, []] {
                let ranges = Self.ranges(of: candidateOld, in: text, options: options)
                if !ranges.isEmpty { found = (ranges, candidateNew); break }
            }
            if found != nil { break }
        }
        guard let (ranges, replacement) = found else { throw ToolError(Self.notFoundMessage(path: url.path, old: old)) }
        if ranges.count > 1, !replaceAll {
            let lines = ranges.prefix(5).map { String(Self.lineNumber(of: $0, in: text)) }.joined(separator: ", ")
            throw ToolError("old_text aparece \(ranges.count) vezes (linhas \(lines)\(ranges.count > 5 ? ", …" : "")). Inclua mais linhas ao redor para torná-lo único, ou passe replace_all=true para trocar todas.")
        }

        let chosen = replaceAll ? ranges : [ranges[0]]
        let result = NSMutableString(string: file.text)
        for range in chosen.reversed() { result.replaceCharacters(in: range, with: replacement) }
        try FileWriter.write(try file.encoded(result as String), to: url)

        let first = Self.lineNumber(of: chosen[0], in: text)
        let count = chosen.count == 1 ? "1 trecho substituído (linha \(first))" : "\(chosen.count) trechos substituídos (a partir da linha \(first))"
        return "\(count) em \(WriteFileTool.location(url, target))"
    }

    /// `old`/`new` as the file would spell them: a CRLF file matches multi-line text given with plain newlines
    /// (and gets CRLF back), an LF file ignores stray CRs; the text exactly as given is the fallback.
    static func candidates(old: String, new: String, lineEnding: TextFile.LineEnding) -> [(String, String)] {
        func lf(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal) }
        func crlf(_ text: String) -> String { lf(text).replacingOccurrences(of: "\n", with: "\r\n", options: .literal) }
        let preferred = lineEnding == .crlf ? (crlf(old), crlf(new)) : (lf(old), lf(new))
        return preferred == (old, new) ? [preferred] : [preferred, (old, new)]
    }

    private static func ranges(of needle: String, in text: NSString, options: NSString.CompareOptions) -> [NSRange] {
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let range = text.range(of: needle, options: options, range: search)
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            search = NSRange(location: range.upperBound, length: text.length - range.upperBound)
        }
        return ranges
    }

    private static func lineNumber(of range: NSRange, in text: NSString) -> Int {
        text.substring(to: range.location).utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }

    private static func notFoundMessage(path: String, old: String) -> String {
        var message = "old_text não foi encontrado em \(path). Releia o arquivo com read_file e copie o trecho exatamente como está (indentação, espaços e quebras de linha)."
        if old.range(of: #"(?m)^ *\d+\t"#, options: .regularExpression) != nil {
            message += " O trecho parece incluir os números de linha do read_file, que não fazem parte do arquivo."
        }
        return message
    }
}

struct ListDirectoryTool: AgentTool {
    static let maxEntries = 500
    static let maxDepth = 3

    let spec = ToolSpec(
        name: "list_directory",
        description: """
        List a directory's entries sorted by name. Subdirectories (and symlinks to folders) end with "/"; every \
        entry shows its modification date and files their size. With `depth` above 1 the listing is recursive \
        (up to 3 levels; .git, node_modules and similar folders are not entered). `pattern` filters by name \
        (glob, e.g. "*.swift"). Returns at most 500 entries.
        """,
        parameters: .schema([
            "path": .property("string", filePathDescription + " Defaults to the working directory."),
            "show_hidden": .property("boolean", "Include hidden entries such as dotfiles (default false)."),
            "pattern": .property("string", "Glob on entry names, e.g. \"*.md\" or \"test_*\"."),
            "depth": .property("integer", "Levels to list (default 1, max 3)."),
        ]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Listando pasta", arguments["path"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = arguments.nonEmptyString("path").map(context.url(for:)) ?? context.workingDirectory
        guard url.isExistingDirectory else { throw ToolError("Pasta não encontrada: \(url.path)") }
        let depth = arguments.integer("depth", default: 1, in: 1...Self.maxDepth)
        let showHidden = arguments.flag("show_hidden")
        let pattern = try arguments.nonEmptyString("pattern").map { try GlobPattern($0) }

        var lines: [String] = []
        var total = 0
        var unreadable = 0
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy-MM-dd HH:mm"

        func list(_ directory: URL, prefix: String, level: Int) throws {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory.resolvingLinkChain, includingPropertiesForKeys: keys, options: showHidden ? [] : .skipsHiddenFiles)
            } catch {
                // The folder that was asked for must not read as empty when it cannot be read; a subfolder that
                // cannot be read is skipped and mentioned at the end.
                guard level > 1 else {
                    throw ToolError("Não consegui ler \(directory.path) (sem permissão ou pasta protegida pelo macOS).")
                }
                unreadable += 1
                return
            }
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                // A link to a folder reports isDirectory false; follow it to see what it points at.
                let isFolder = values?.isDirectory == true || (values?.isSymbolicLink == true && entry.isExistingDirectory)
                let name = entry.lastPathComponent
                if pattern?.matches(name: name) ?? true {
                    total += 1
                    if lines.count < Self.maxEntries {
                        let date = values?.contentModificationDate.map(dates.string(from:))
                        let details: String
                        if isFolder {
                            details = date ?? ""
                        } else {
                            let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
                            details = [size, date].compactMap { $0 }.joined(separator: ", ")
                        }
                        lines.append(prefix + name + (isFolder ? "/" : "") + (details.isEmpty ? "" : "  (\(details))"))
                    }
                }
                if isFolder, level < depth, values?.isSymbolicLink != true, !FileWalker.skippedDirectories.contains(name) {
                    try list(entry, prefix: prefix + name + "/", level: level + 1)
                }
            }
        }
        try list(url, prefix: "", level: 1)

        let skipped = unreadable == 0 ? "" : "\n[\(unreadable) subpasta\(unreadable == 1 ? "" : "s") sem permissão de leitura não \(unreadable == 1 ? "foi listada" : "foram listadas")]"
        guard total > 0 else {
            return (pattern == nil ? "\(url.path) está vazia." : "Nenhuma entrada de \(url.path) combina com o padrão.") + skipped
        }
        if total > Self.maxEntries { lines.append("[... mais \(total - Self.maxEntries) itens ...]") }
        return url.path + "\n" + lines.joined(separator: "\n") + skipped
    }
}

struct SearchFilesTool: AgentTool {
    let spec = ToolSpec(
        name: "search_files",
        description: """
        Search the Mac with Spotlight and return matching file paths. A filename-like query (e.g. "budget.xlsx") \
        matches file names; any other text matches names and contents. Spotlight has blind spots: it does not \
        index every folder (hidden or system folders, node_modules, external or network volumes, files too new to \
        be indexed), so an empty result does not prove the file is absent; fall back to glob (names) or grep (contents).
        """,
        parameters: .schema([
            "query": .property("string", "File name or words to look for."),
            "directory": .property("string", "Only search inside this directory. " + filePathDescription),
            "limit": .property("integer", "Maximum number of results (default 50, max 500)."),
        ], required: ["query"]))

    var kind: ToolCall.Kind { .search }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Procurando arquivos", arguments["query"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let query = try arguments.requiredString("query")
        guard !query.hasPrefix("-") else { throw ToolError("A busca não pode começar com \"-\".") }
        let limit = arguments.integer("limit", default: 50, in: 1...500)
        var mdfindArguments: [String] = []
        if let directory = arguments.nonEmptyString("directory") {
            mdfindArguments += ["-onlyin", context.url(for: directory).path]
        }
        mdfindArguments += Self.looksLikeFileName(query) ? ["-name", query] : [query]

        let result = try await ProcessRunner.run("/usr/bin/mdfind", mdfindArguments, timeout: .seconds(30), outputLimit: 1_000_000)
        // stderr is merged in (Spotlight logs noise there); results are the absolute paths.
        let paths = result.output.split(separator: "\n").filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else {
            if result.status != 0 { throw ToolError("A busca falhou: \(result.output)") }
            return "Nenhum arquivo encontrado. O Spotlight pode não indexar essa pasta (pastas ocultas, node_modules, volumes externos ou arquivos recentes); tente glob para nomes ou grep para conteúdo."
        }
        var lines = paths.prefix(limit).map(String.init)
        if paths.count > limit { lines.append("[... mais \(paths.count - limit) resultados; refine a busca ...]") }
        return lines.joined(separator: "\n")
    }

    static func looksLikeFileName(_ query: String) -> Bool {
        query.contains(".") && !query.contains(where: \.isWhitespace)
    }
}

extension ToolBox {
    static let fileTools: [any AgentTool] = [
        ReadFileTool(), WriteFileTool(), EditFileTool(), ListDirectoryTool(), SearchFilesTool(), GrepTool(), GlobTool(),
    ]
}
