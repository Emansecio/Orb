import AppKit
import UserNotifications

// The Orb's hands on the Mac: Shortcuts, clipboard, notifications, running apps, processes, Trash.
// Everything here needs the "Controlar apps do Mac" capability except `notify`.

// MARK: - Shortcuts

struct ShortcutsListTool: AgentTool {
    let spec = ToolSpec(
        name: "shortcuts_list",
        description: """
        List the user's Shortcuts by name, to see what exists before using applescript; run one with \
        shortcuts_run.
        """,
        parameters: .schema([
            "filter": .property("string"),
        ]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Listando atalhos", arguments["filter"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/shortcuts", ["list"], timeout: .seconds(20), outputLimit: 2_000_000)
        guard !result.timedOut, result.status == 0 else {
            throw ToolError("Não consegui listar os atalhos: \(result.output.isEmpty ? "o comando shortcuts não respondeu." : result.output)")
        }
        return ShortcutsFormatter.listing(result.output, filter: arguments["filter"]?.string)
    }
}

struct ShortcutsRunTool: AgentTool {
    let spec = ToolSpec(
        name: "shortcuts_run",
        description: """
        Run a Shortcut by exact name (see shortcuts_list), optionally with text input, and return the text it \
        produces. A Shortcut can do anything its author built in, so run only ones that match the request. Waits \
        up to timeout_seconds (default 60, max 300); a Shortcut that asks something on screen waits for the \
        answer.
        """,
        parameters: .schema([
            "name": .property("string"),
            "input": .property("string", "Text input for the Shortcut."),
            "timeout_seconds": .property("integer"),
        ], required: ["name"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let input = arguments["input"]?.string ?? ""
        let preview = input.count > 300 ? input.prefix(300) + "…" : input
        return ("Rodando o atalho \(arguments["name"]?.string ?? "")", preview)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        // The name is a command-line argument: one starting with "-" would be read as an option.
        guard !name.isEmpty, !name.hasPrefix("-") else { throw ToolError("Nome de atalho inválido: \"\(name)\".") }
        let seconds = arguments.integer("timeout_seconds", default: 60, in: 1...300)

        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbShortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputFile = folder.appending(path: "output")
        var command = ["run", name, "-o", outputFile.path]
        if let input = arguments.nonEmptyString("input") {
            let inputFile = folder.appending(path: "input.txt")
            try input.write(to: inputFile, atomically: true, encoding: .utf8)
            command += ["-i", inputFile.path]
        }

        let result = try await ProcessRunner.run("/usr/bin/shortcuts", command, timeout: .seconds(seconds))
        if result.timedOut {
            throw ToolError("O atalho \"\(name)\" passou de \(seconds) s e foi interrompido. Ele pode estar esperando uma "
                            + "resposta na tela ou ser demorado demais para rodar assim.")
        }
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError("O atalho \"\(name)\" falhou" + (detail.isEmpty ? "." : ": \(detail)")
                            + "\nConfira o nome exato com shortcuts_list.")
        }
        return ShortcutsFormatter.result(name: name, output: try? Data(contentsOf: outputFile),
                                         console: result.output)
    }
}

enum ShortcutsFormatter {
    static let maxListed = 300

    /// Shortcut names from `shortcuts list`, one per line, filtered and capped.
    static func listing(_ output: String, filter: String?) -> String {
        var names = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let total = names.count
        if let filter = filter?.trimmingCharacters(in: .whitespaces), !filter.isEmpty {
            names = names.filter { $0.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            if names.isEmpty { return "Nenhum atalho com \"\(filter)\" no nome (\(total) no total)." }
        }
        guard !names.isEmpty else { return "O usuário não tem nenhum atalho." }
        var text = "\(names.count) atalho\(names.count == 1 ? "" : "s"):\n" + names.prefix(maxListed).map { "- \($0)" }.joined(separator: "\n")
        if names.count > maxListed { text += "\n[... mais \(names.count - maxListed); use o filtro para achar um ...]" }
        return text
    }

    /// What the Shortcut produced: text, or a note when the output is a file or empty.
    static func result(name: String, output: Data?, console: String) -> String {
        let log = console.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else {
            return "O atalho \"\(name)\" rodou e não devolveu resultado." + (log.isEmpty ? "" : "\n\(log)")
        }
        guard let text = String(data: output, encoding: .utf8) else {
            return "O atalho \"\(name)\" rodou e devolveu um arquivo que não é texto (\(output.count) bytes)."
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 20_000)
    }
}

// MARK: - Clipboard

struct ClipboardReadTool: AgentTool {
    let spec = ToolSpec(
        name: "clipboard_read",
        description: """
        Read what the user last copied (⌘C): the text, and the paths of files copied in Finder. Text is cut at \
        20,000 characters; images are only reported.
        """,
        parameters: .schema([:]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Lendo a área de transferência", "") }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let snapshot = await MainActor.run { ClipboardSnapshot.read(from: .general) }
        return ClipboardFormatter.describe(snapshot)
    }
}

struct ClipboardWriteTool: AgentTool {
    let spec = ToolSpec(
        name: "clipboard_write",
        description: """
        Put text on the clipboard, replacing what the user copied, to hand over something short to paste (a \
        command, an address, a draft). It is lost when they copy something else.
        """,
        parameters: .schema(["text": .property("string")], required: ["text"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let text = arguments["text"]?.string ?? ""
        return ("Copiando para a área de transferência", text.count > 600 ? text.prefix(600) + "…" : text)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let text = try arguments.requiredString("text")
        guard await MainActor.run(body: { ClipboardSnapshot.write(text, to: .general) }) else {
            throw ToolError("Não consegui escrever na área de transferência.")
        }
        return "Copiado (\(text.count) caracteres). O usuário já pode colar com ⌘V."
    }
}

struct ClipboardSnapshot: Sendable, Equatable {
    var text: String?
    var files: [String] = []
    var hasImage = false

    @MainActor static func read(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        return ClipboardSnapshot(text: pasteboard.string(forType: .string), files: urls.map(\.path), hasImage: images)
    }

    @MainActor static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

enum ClipboardFormatter {
    static let textLimit = 20_000

    static func describe(_ snapshot: ClipboardSnapshot) -> String {
        var parts: [String] = []
        if let text = snapshot.text, !text.isEmpty {
            parts.append("Texto (\(text.count) caracteres):\n" + text.truncated(to: textLimit))
        }
        if !snapshot.files.isEmpty {
            parts.append("Arquivos copiados (\(snapshot.files.count)):\n" + snapshot.files.map { "- \($0)" }.joined(separator: "\n"))
        }
        if snapshot.hasImage && snapshot.files.isEmpty {
            parts.append("Há também uma imagem copiada (não dá para ler o conteúdo dela por aqui; use screenshot se precisar ver a tela).")
        }
        return parts.isEmpty ? "A área de transferência está vazia (ou tem algo que não é texto, arquivo nem imagem)."
            : parts.joined(separator: "\n\n")
    }
}

// MARK: - Notifications

struct NotifyTool: AgentTool {
    let spec = ToolSpec(
        name: "notify",
        description: """
        Show a macOS notification banner, to get the user's attention when a long task finishes or something \
        needs them; not for ordinary replies.
        """,
        parameters: .schema([
            "title": .property("string"),
            "body": .property("string"),
        ], required: ["title"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Enviando notificação", [arguments["title"]?.string, arguments["body"]?.string].compactMap { $0 }.joined(separator: "\n"))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let title = String(try arguments.requiredString("title").prefix(120))
        let body = String((arguments["body"]?.string ?? "").prefix(500))
        guard ApprovalNotifications.isAvailable else {
            throw ToolError("Notificações só funcionam no app Orb instalado (não em uma execução de desenvolvimento).")
        }
        guard await ApprovalNotifications.send(ApprovalNotifications.plainContent(title: title, body: body)) else {
            throw ToolError("As notificações do Orb estão desligadas. Peça ao usuário para ativar em Ajustes do Sistema → Notificações → Orb.")
        }
        return "Notificação enviada."
    }
}

/// The app's one notification delegate: it shows banners while the app is in front (without a delegate macOS hides
/// them, which is exactly when the user is chatting) and routes taps (`ApprovalNotifications`).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

// MARK: - Apps and processes

struct RunningAppInfo: Sendable, Equatable {
    var name: String
    var bundleID: String?
    var pid: Int32
    var isActive: Bool
    var isHidden: Bool
    /// Shows in the Dock; background agents and helpers are not.
    var isRegular: Bool

    @MainActor static func current(includeBackground: Bool) -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let regular = app.activationPolicy == .regular
            guard regular || includeBackground, let name = app.localizedName else { return nil }
            return RunningAppInfo(name: name, bundleID: app.bundleIdentifier, pid: app.processIdentifier,
                                  isActive: app.isActive, isHidden: app.isHidden, isRegular: regular)
        }
    }
}

enum RunningAppMatcher {
    enum Result: Equatable {
        case none
        case found([RunningAppInfo])
        /// Several different apps contain the text; the caller should ask which.
        case ambiguous([RunningAppInfo])
    }

    /// An exact name or bundle id (ignoring case and accents) wins; otherwise a name that contains the text,
    /// as long as only one app does. Several instances of the same app all match.
    /// With `exactOnly`, a partial match is never accepted (used before destructive actions); the caller can still ask
    /// for the partial ones to offer as suggestions.
    static func match(_ query: String, in apps: [RunningAppInfo], exactOnly: Bool = false) -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .none }
        func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let exact = apps.filter { same($0.name, query) || ($0.bundleID.map { same($0, query) } ?? false) }
        if !exact.isEmpty { return .found(exact) }
        if exactOnly { return .none }
        let partial = apps.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if partial.isEmpty { return .none }
        let distinct = Set(partial.map { $0.bundleID ?? $0.name })
        return distinct.count == 1 ? .found(partial) : .ambiguous(partial)
    }
}

enum AppListFormatter {
    static func format(_ apps: [RunningAppInfo]) -> String {
        guard !apps.isEmpty else { return "Nenhum app aberto." }
        let lines = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { app in
            var line = "- \(app.name)"
            if let id = app.bundleID { line += " (\(id))" }
            line += " · pid \(app.pid)"
            if app.isActive { line += " · em primeiro plano" }
            if app.isHidden { line += " · oculto" }
            if !app.isRegular { line += " · em segundo plano" }
            return line
        }
        return "\(apps.count) app\(apps.count == 1 ? "" : "s") aberto\(apps.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
    }
}

struct AppsListTool: AgentTool {
    let spec = ToolSpec(
        name: "apps_list",
        description: """
        List the running apps with bundle identifier, which is in front and which are hidden: what is open, or \
        the exact name for app_quit and open. `include_background` adds menu bar apps and helper agents.
        """,
        parameters: .schema([
            "include_background": .property("boolean"),
        ]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Listando apps abertos", "") }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let background = arguments["include_background"]?.bool ?? false
        let apps = await MainActor.run { RunningAppInfo.current(includeBackground: background) }
        return AppListFormatter.format(apps)
    }
}

struct ProcessInfoRow: Equatable, Sendable {
    var pid: Int
    var cpu: Double
    var memoryPercent: Double
    var residentKB: Int
    var command: String

    var name: String { command.split(separator: "/").last.map(String.init) ?? command }
}

enum ProcessListParser {
    /// Parses `ps -o pid=,pcpu=,pmem=,rss=,comm=`; the command is last because its path may contain spaces.
    static func parse(_ output: String) -> [ProcessInfoRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let memory = Double(fields[2].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int(fields[3]) else { return nil }
            return ProcessInfoRow(pid: pid, cpu: cpu, memoryPercent: memory, residentKB: rss,
                                  command: fields[4].trimmingCharacters(in: .whitespaces))
        }
    }

    static func megabytes(_ kilobytes: Int) -> String {
        kilobytes >= 1_048_576 ? String(format: "%.1f GB", Double(kilobytes) / 1_048_576) : "\(kilobytes / 1024) MB"
    }

    static func format(_ rows: [ProcessInfoRow], sortedBy sort: String) -> String {
        guard !rows.isEmpty else { return "Nenhum processo encontrado." }
        let header = "Maiores consumidores de \(sort == "memory" ? "memória" : "CPU") (PID · CPU · memória · nome):"
        let lines = rows.map { row in
            "\(row.pid) · \(String(format: "%.1f", row.cpu))% · \(megabytes(row.residentKB)) (\(String(format: "%.1f", row.memoryPercent))%) · \(row.name)"
        }
        return header + "\n" + lines.joined(separator: "\n")
    }
}

struct ProcessesTool: AgentTool {
    let spec = ToolSpec(
        name: "processes",
        description: """
        Show the processes using the most CPU or memory now (PID, CPU %, memory, name), to find what slows or \
        heats the Mac. Quit a culprit with app_quit.
        """,
        parameters: .schema([
            "sort": .object(["type": .string("string"),
                             "enum": .array(["cpu", "memory"].map(JSONValue.string))]),
            "limit": .property("integer", "Processes (default 15, max 50)."),
        ]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Vendo os processos", "") }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let sort = arguments["sort"]?.string == "memory" ? "memory" : "cpu"
        let limit = arguments.integer("limit", default: 15, in: 1...50)
        // The whole table is longer than the default output cap, and only its sorted head matters.
        let result = try await ProcessRunner.run("/bin/ps", ["-A", sort == "memory" ? "-m" : "-r", "-o", "pid=,pcpu=,pmem=,rss=,comm="],
                                                 timeout: .seconds(10), outputLimit: 2_000_000)
        guard !result.timedOut, result.status == 0 else { throw ToolError("Não consegui listar os processos.") }
        return ProcessListParser.format(Array(ProcessListParser.parse(result.output).prefix(limit)), sortedBy: sort)
    }
}

struct AppQuitTool: AgentTool {
    let spec = ToolSpec(
        name: "app_quit",
        description: """
        Quit a running app by exact name or bundle identifier (see apps_list), normally: with unsaved documents \
        it may show a Save dialog and stay open, so tell the user. `force` kills it and loses unsaved work (the \
        user is always asked to confirm); only for a frozen app. Cannot quit the Orb itself.
        """,
        parameters: .schema([
            "app": .property("string"),
            "force": .property("boolean"),
        ], required: ["app"]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    /// A forced quit loses unsaved work, so "Automático" still asks (and "Sempre permitir" never covers it).
    func danger(_ arguments: JSONValue) -> String? {
        arguments["force"]?.bool == true ? "encerra o app à força, sem deixar salvar" : nil
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        (arguments["force"]?.bool == true ? "Forçando o encerramento" : "Encerrando app", arguments["app"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let query = try arguments.requiredString("app")
        let force = arguments["force"]?.bool ?? false
        let apps = await MainActor.run { RunningAppInfo.current(includeBackground: true) }
        let targets = try Self.select(query, in: apps, ownPID: ProcessInfo.processInfo.processIdentifier)

        let outcome = await Self.quit(pids: targets.map(\.pid), force: force)
        let name = targets[0].name
        if outcome.allSatisfy(\.value) {
            return force ? "\(name) foi encerrado à força." : "\(name) foi encerrado."
        }
        return force ? "\(name) não encerrou nem à força (processo protegido do sistema?)."
            : "Pedi para \(name) encerrar, mas ele continua aberto. Pode estar perguntando se deve salvar um documento: "
            + "peça ao usuário para olhar a tela, ou use force se ele estiver travado (perde o que não foi salvo)."
    }

    /// The apps to quit for `query`. Only an exact name or bundle identifier counts: the approval card shows the
    /// query, so a partial match could end an app the user never saw ("Mail" must not quit Mailspring).
    static func select(_ query: String, in apps: [RunningAppInfo], ownPID: Int32) throws -> [RunningAppInfo] {
        guard case .found(let targets) = RunningAppMatcher.match(query, in: apps, exactOnly: true) else {
            var message = "Não há nenhum app aberto chamado \"\(query)\". Use apps_list para ver os nomes."
            let similar: [RunningAppInfo]
            switch RunningAppMatcher.match(query, in: apps) {
            case .found(let found), .ambiguous(let found): similar = found
            case .none: similar = []
            }
            if !similar.isEmpty {
                let names = Set(similar.map(\.name)).sorted().joined(separator: ", ")
                message += " Apps parecidos abertos: \(names). Diga o nome exato ou o bundle identifier."
            }
            throw ToolError(message)
        }
        if targets.contains(where: { $0.pid == ownPID }) { throw ToolError("Não posso encerrar o próprio Orb.") }
        return targets
    }

    /// Terminates the processes and waits briefly for each to go away. Returns pid → gone.
    @MainActor private static func quit(pids: [Int32], force: Bool) async -> [Int32: Bool] {
        let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        for app in apps { _ = force ? app.forceTerminate() : app.terminate() }
        for _ in 0..<(force ? 8 : 20) where apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0.isTerminated) })
    }
}

// MARK: - Trash

struct TrashTool: AgentTool {
    let spec = ToolSpec(
        name: "trash",
        description: """
        Move files or folders to the Trash (recoverable) and say where each went. Prefer it over `rm`. Up to 50 \
        paths per call. Refuses the home folder, its standard folders and system folders.
        """,
        parameters: .schema([
            "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        ], required: ["paths"]))

    /// Moves one item to the Trash and returns where it ended up; replaceable so tests never touch the real Trash.
    let trasher: @Sendable (URL) throws -> URL?

    init(trasher: @escaping @Sendable (URL) throws -> URL? = TrashTool.moveToSystemTrash) {
        self.trasher = trasher
    }

    var kind: ToolCall.Kind { .file }
    /// A file operation: moving to the Trash needs no Mac permission, so "Terminal e arquivos" is enough. "Controlar apps do
    /// Mac" offers it too, as it did before.
    var capability: Capability? { .terminal }
    var alsoWithCapability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Movendo para a Lixeira", Self.paths(in: arguments).joined(separator: "\n"))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let paths = Self.paths(in: arguments)
        guard !paths.isEmpty else { throw ToolError("Faltou o argumento \"paths\" (lista de caminhos).") }
        guard paths.count <= 50 else { throw ToolError("São caminhos demais (\(paths.count)); mande no máximo 50 por vez.") }

        var lines: [String] = []
        var moved = 0
        for path in paths {
            let url = context.url(for: path)
            if let refusal = TrashGuard.refusal(for: url) { lines.append("- \(url.path): não movido, \(refusal)"); continue }
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
                lines.append("- \(url.path): não movido, não existe"); continue
            }
            do {
                let destination = try trasher(url)
                moved += 1
                lines.append("- \(url.path) → \(destination?.path ?? "Lixeira")")
            } catch {
                lines.append("- \(url.path): não movido, \(error.localizedDescription)")
            }
        }
        let report = lines.joined(separator: "\n")
        guard moved > 0 else { throw ToolError("Nada foi movido para a Lixeira:\n" + report) }
        return "\(moved) de \(paths.count) \(paths.count == 1 ? "item" : "itens") na Lixeira (dá para recuperar de lá):\n" + report
    }

    private static func paths(in arguments: JSONValue) -> [String] {
        if let list = arguments["paths"]?.array { return list.compactMap(\.string).filter { !$0.isEmpty } }
        return arguments.nonEmptyString("paths").map { [$0] } ?? []
    }

    @Sendable static func moveToSystemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

enum TrashGuard {
    // Compared lowercased: the default macOS volume ignores case, so "~/documents" is the Documents folder.
    private static let systemFolders: Set<String> = [
        "/", "/system", "/applications", "/library", "/users", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
        "/opt", "/cores", "/volumes", "/tmp", "/private/etc", "/private/var", "/private/tmp",
    ]
    private static let homeFolders: Set<String> = [
        "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public", "applications",
    ]

    /// Why this path must not be trashed, or nil. Whole standard folders are almost always a slip, and trashing
    /// them would take everything inside along. The path is checked as typed and with symlinks resolved.
    static func refusal(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let candidates = [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()]
        let homes = [home.standardizedFileURL, home.standardizedFileURL.resolvingSymlinksInPath()]
        for candidate in candidates {
            let path = candidate.path.lowercased()
            if systemFolders.contains(path) || path.hasPrefix("/system/") { return "é uma pasta do sistema" }
            for homeURL in homes {
                let homePath = homeURL.path.lowercased()
                if path == homePath { return "é a pasta pessoal" }
                if path.hasPrefix(homePath + "/") {
                    let rest = String(path.dropFirst(homePath.count + 1))
                    if !rest.contains("/"), homeFolders.contains(rest) {
                        return "é uma das pastas padrão do usuário (mova os itens de dentro, um a um)"
                    }
                }
            }
        }
        return nil
    }
}

extension ToolBox {
    static let macAppTools: [any AgentTool] = [
        ShortcutsListTool(), ShortcutsRunTool(), ClipboardReadTool(), ClipboardWriteTool(), ScreenshotTool(),
        NotifyTool(), AppsListTool(), ProcessesTool(), AppQuitTool(), TrashTool(),
    ]
}
