import Foundation

private let pathDescription = "Absolute path, ~/..., or relative to the working directory."

struct ReadFileTool: AgentTool {
    let spec = ToolSpec(
        name: "read_file",
        description: """
        Read a text file and return its lines numbered like `cat -n`. Returns up to `limit` lines starting at \
        line `offset`; use them to page through long files. Fails on directories and binary files.
        """,
        parameters: .schema([
            "path": .property("string", pathDescription),
            "offset": .property("integer", "1-based line to start at (default 1)."),
            "limit": .property("integer", "Maximum number of lines to return (default 400)."),
        ], required: ["path"]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Lendo arquivo", arguments["path"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = context.url(for: try arguments.requiredString("path"))
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("Arquivo não encontrado: \(url.path)") }
        guard !url.isExistingDirectory else { throw ToolError("\(url.path) é uma pasta; use list_directory.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else {
            throw ToolError("\(url.path) é grande demais (\(size) bytes); use run_command com head, tail ou grep.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.prefix(8192).contains(0) else { throw ToolError("\(url.path) é um arquivo binário.") }

        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return "(arquivo vazio)" }
        let offset = arguments.integer("offset", default: 1, in: 1...lines.count)
        let limit = arguments.integer("limit", default: 400, in: 1...lines.count)
        let end = min(offset - 1 + limit, lines.count)

        var text = (offset...end).map { number in
            let label = String(number)
            return String(repeating: " ", count: max(6 - label.count, 0)) + label + "\t" + lines[number - 1]
        }.joined(separator: "\n")
        if end < lines.count {
            text += "\n[... mais \(lines.count - end) linhas; use offset=\(end + 1) para continuar ...]"
        }
        return text.truncated(to: 200_000)
    }
}

struct WriteFileTool: AgentTool {
    let spec = ToolSpec(
        name: "write_file",
        description: """
        Write text to a file, creating the file and any missing parent directories. Replaces existing content \
        unless `append` is true.
        """,
        parameters: .schema([
            "path": .property("string", pathDescription),
            "content": .property("string", "Text to write."),
            "append": .property("boolean", "Add to the end of the file instead of replacing it (default false)."),
        ], required: ["path", "content"]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { .terminal }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Gravando arquivo", arguments["path"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = context.url(for: try arguments.requiredString("path"))
        let data = Data(try arguments.requiredString("content", allowEmpty: true).utf8)
        let append = arguments["append"]?.bool ?? false
        guard !url.isExistingDirectory else { throw ToolError("\(url.path) é uma pasta.") }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return "\(data.count) bytes \(append ? "acrescentados a" : "gravados em") \(url.path)"
    }
}

struct ListDirectoryTool: AgentTool {
    static let maxEntries = 500

    let spec = ToolSpec(
        name: "list_directory",
        description: """
        List a directory's entries sorted by name. Subdirectories end with "/", files show their size. \
        Returns at most 500 entries.
        """,
        parameters: .schema([
            "path": .property("string", pathDescription + " Defaults to the working directory."),
            "show_hidden": .property("boolean", "Include hidden entries such as dotfiles (default false)."),
        ]))

    var kind: ToolCall.Kind { .file }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Listando pasta", arguments["path"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let url = arguments.nonEmptyString("path").map(context.url(for:)) ?? context.workingDirectory
        guard url.isExistingDirectory else { throw ToolError("Pasta não encontrada: \(url.path)") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys),
            options: arguments["show_hidden"]?.bool == true ? [] : .skipsHiddenFiles
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !entries.isEmpty else { return "\(url.path) está vazia." }

        var lines = entries.prefix(Self.maxEntries).map { entry in
            let values = try? entry.resourceValues(forKeys: keys)
            if values?.isDirectory == true { return entry.lastPathComponent + "/" }
            let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            return "\(entry.lastPathComponent)  (\(size))"
        }
        if entries.count > Self.maxEntries { lines.append("[... mais \(entries.count - Self.maxEntries) itens ...]") }
        return url.path + "\n" + lines.joined(separator: "\n")
    }
}

struct SearchFilesTool: AgentTool {
    let spec = ToolSpec(
        name: "search_files",
        description: """
        Search the Mac with Spotlight and return matching file paths. A filename-like query (e.g. "budget.xlsx") \
        matches file names; any other text matches names and contents.
        """,
        parameters: .schema([
            "query": .property("string", "File name or words to look for."),
            "directory": .property("string", "Only search inside this directory. " + pathDescription),
            "limit": .property("integer", "Maximum number of results (default 50, max 500)."),
        ], required: ["query"]))

    var kind: ToolCall.Kind { .search }
    var capability: Capability? { nil }
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
            return "Nenhum arquivo encontrado."
        }
        var lines = paths.prefix(limit).map(String.init)
        if paths.count > limit { lines.append("[... mais \(paths.count - limit) resultados; refine a busca ...]") }
        return lines.joined(separator: "\n")
    }

    static func looksLikeFileName(_ query: String) -> Bool {
        query.contains(".") && !query.contains(where: \.isWhitespace)
    }
}
