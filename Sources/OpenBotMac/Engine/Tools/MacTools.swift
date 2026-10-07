import AppKit

struct OpenTool: AgentTool {
    let spec = ToolSpec(
        name: "open",
        description: """
        Open a URL in the default browser, a file or folder in its default app, or launch an application by \
        name (e.g. "Safari", "Notes") or bundle identifier.
        """,
        parameters: .schema([
            "target": .property("string", "A full URL (https://…), a file path, or an application name."),
        ], required: ["target"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { nil }

    /// Web pages are harmless to open; files, apps and other URL schemes can run code.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        guard let url = URL(string: arguments["target"]?.string ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return .sensitive }
        return .safe
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Abrindo", arguments["target"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let target = try arguments.requiredString("target")
        let url = try resolve(target, context: context)
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw ToolError("Não consegui abrir \(target).")
        }
        return "Aberto: \(url.isFileURL ? url.path : url.absoluteString)"
    }

    private func resolve(_ target: String, context: ToolContext) throws -> URL {
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1 { return url }
        let file = context.url(for: target)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let app = Self.application(named: target) { return app }
        throw ToolError("Não encontrei \"\(target)\" como endereço, arquivo ou app.")
    }

    /// Looks up an app by bundle identifier, then by name in the usual Applications folders.
    static func application(named name: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let bundleName = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.lazy
            .map { URL(fileURLWithPath: $0).appending(path: bundleName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct AppleScriptTool: AgentTool {
    let spec = ToolSpec(
        name: "applescript",
        description: """
        Run an AppleScript with osascript and return its result. Use it to automate Mac apps such as Mail, \
        Calendar, Notes, Reminders, Contacts, Messages, Finder, Music, Safari and System Events. \
        Stops after 60 seconds.
        """,
        parameters: .schema([
            "script": .property("string", "AppleScript source; may span several lines."),
        ], required: ["script"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Usando o AppleScript", arguments["script"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let script = try arguments.requiredString("script")
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(60))
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { throw ToolError("O AppleScript passou de 60 s e foi interrompido.") }
        guard result.status == 0 else {
            throw ToolError(output.isEmpty ? "O AppleScript falhou (código \(result.status))." : output)
        }
        return output.isEmpty ? "(sem resultado)" : output
    }
}

struct RememberTool: AgentTool {
    let spec = ToolSpec(
        name: "remember",
        description: """
        Save a durable fact about the user or their work (preferences, names, ongoing projects) to long-term \
        memory so it is available in future conversations. One short, self-contained fact per call.
        """,
        parameters: .schema([
            "fact": .property("string", "The fact to remember, written as a complete sentence."),
        ], required: ["fact"]))

    var kind: ToolCall.Kind { .memory }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Guardando na memória", arguments["fact"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let fact = try arguments.requiredString("fact").trimmingCharacters(in: .whitespacesAndNewlines)
        await context.remember(fact)
        return "Guardado na memória: \(fact)"
    }
}
