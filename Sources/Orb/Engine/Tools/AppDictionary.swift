import Foundation

// The AppleScript dictionary of an app, read only when the model needs it (`app_dictionary`): `sdef` prints XML that can run
// to hundreds of kilobytes, so what reaches the model is a compact listing, filtered by `search` or `suite` and paged.

/// One app's dictionary as the model reads it: suites with their commands, classes and enumerations.
struct AppDictionary: Sendable, Equatable {
    struct Command: Sendable, Equatable {
        var name: String
        var detail = ""
        var direct: String?
        var parameters: [Parameter] = []
        var result: String?
    }
    struct Parameter: Sendable, Equatable {
        var name: String
        var type: String
        var optional: Bool
    }
    struct Property: Sendable, Equatable {
        var name: String
        var type: String
        var readOnly: Bool
    }
    struct Class: Sendable, Equatable {
        var name: String
        var detail = ""
        var inherits: String?
        /// `class-extension`: it adds to a class defined elsewhere (usually `application`).
        var isExtension = false
        var properties: [Property] = []
        var elements: [String] = []
    }
    struct Enumeration: Sendable, Equatable {
        var name: String
        var values: [String] = []
    }
    struct Suite: Sendable, Equatable {
        var name: String
        var detail = ""
        var commands: [Command] = []
        var classes: [Class] = []
        var enumerations: [Enumeration] = []
    }

    var suites: [Suite]
    /// The sdef pulls in the system's Standard Suite (`xi:include`); `sdef` does not expand it.
    var includesStandardSuite = false

    // MARK: Parsing

    /// Reads the XML `sdef` prints. Hidden items are left out. Returns nil when it is not XML at all.
    static func parse(_ data: Data) -> AppDictionary? {
        // `sdef` can print warnings (its stderr is merged into the output) ahead of the XML.
        let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<dictionary".utf8))
        let reader = Reader()
        let parser = XMLParser(data: start.map { Data(data[$0.lowerBound...]) } ?? data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() || !reader.dictionary.suites.isEmpty else { return nil }
        return reader.dictionary
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var dictionary = AppDictionary(suites: [])
        private var suite: Suite?
        private var command: Command?
        private var cls: Class?
        private var enumeration: Enumeration?
        /// The parameter or result whose `<type>` children are being collected.
        private enum Slot { case direct, parameter(Int), result }
        private var slot: Slot?
        private var types: [String] = []
        /// Inside a `<property>` that lists its type as `<type>` children.
        private var propertyOpen = false
        private var hiddenDepth = 0
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            depth += 1
            if hiddenDepth > 0 { return }
            if a["hidden"] == "yes" { hiddenDepth = depth; return }
            switch name {
            case "xi:include": if a["href"]?.contains("CocoaStandard") == true { dictionary.includesStandardSuite = true }
            case "suite": suite = Suite(name: a["name"] ?? "", detail: a["description"] ?? "")
            case "command", "event": command = Command(name: a["name"] ?? "", detail: a["description"] ?? "")
            case "class", "record-type": cls = Class(name: a["name"] ?? "", detail: a["description"] ?? "", inherits: a["inherits"])
            case "class-extension": cls = Class(name: a["extends"] ?? "", detail: a["description"] ?? "", isExtension: true)
            case "enumeration": enumeration = Enumeration(name: a["name"] ?? "")
            case "enumerator": enumeration?.values.append(a["name"] ?? "")
            case "direct-parameter" where command != nil:
                slot = .direct; types = a["type"].map { [$0] } ?? []
            case "parameter" where command != nil:
                command?.parameters.append(Parameter(name: a["name"] ?? "", type: a["type"] ?? "", optional: a["optional"] == "yes"))
                slot = .parameter((command?.parameters.count ?? 1) - 1); types = []
            case "result" where command != nil:
                slot = .result; types = a["type"].map { [$0] } ?? []
            case "type" where slot != nil:
                if let type = a["type"] { types.append(a["list"] == "yes" ? "[\(type)]" : type) }
            case "property" where cls != nil:
                cls?.properties.append(Property(name: a["name"] ?? "", type: a["type"] ?? "", readOnly: a["access"] == "r"))
                slot = nil; types = []
                propertyOpen = true
            case "type" where propertyOpen:
                if let type = a["type"] { types.append(a["list"] == "yes" ? "[\(type)]" : type) }
            case "element" where cls != nil:
                if let type = a["type"] { cls?.elements.append(type) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            if hiddenDepth > 0 { if depth == hiddenDepth { hiddenDepth = 0 }; return }
            switch name {
            case "direct-parameter", "result", "parameter": closeSlot()
            case "property" where propertyOpen:
                if let last = cls?.properties.indices.last, !types.isEmpty, cls?.properties[last].type.isEmpty == true {
                    cls?.properties[last].type = types.joined(separator: "|")
                }
                propertyOpen = false; types = []
            case "command", "event":
                if let command { suite?.commands.append(command) }
                command = nil
            case "class", "record-type", "class-extension":
                if let cls { suite?.classes.append(cls) }
                cls = nil
            case "enumeration":
                if let enumeration { suite?.enumerations.append(enumeration) }
                enumeration = nil
            case "suite":
                if let suite { dictionary.suites.append(suite) }
                suite = nil
            default: break
            }
        }

        private func closeSlot() {
            let joined = types.joined(separator: "|")
            switch slot {
            case .direct: command?.direct = joined.isEmpty ? "any" : joined
            case .result: command?.result = joined.isEmpty ? nil : joined
            case .parameter(let index):
                if command?.parameters.indices.contains(index) == true, command?.parameters[index].type.isEmpty == true {
                    command?.parameters[index].type = joined.isEmpty ? "any" : joined
                }
            case nil: break
            }
            slot = nil; types = []
        }
    }
}

// MARK: - The listing

extension AppDictionary {
    /// Characters of one answer; the rest is asked for with `offset`.
    static let pageCharacters = 6_000

    /// The Standard Suite lives in a system file that `sdef` leaves as an include; its commands are the same in every app.
    static let standardSuiteNote = "Standard Suite (included, same in every app): open, close, save, print, quit, count, delete, "
        + "duplicate, exists, make, move, set; classes application, window, document, item."

    /// One line per command, class and enumeration. `suite` keeps the suites whose name contains it; `search` keeps what
    /// matches in a name, description, parameter, property or value (a class with only some matching properties lists just those).
    func lines(search: String? = nil, suite: String? = nil) -> [String] {
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
        let wanted = suite?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
        func matches(_ texts: String...) -> Bool {
            guard let needle else { return true }
            return texts.contains { $0.lowercased().contains(needle) }
        }
        var out: [String] = []
        for suite in suites where wanted == nil || suite.name.lowercased().contains(wanted ?? "") {
            var body: [String] = []
            for command in suite.commands {
                let parameterText = command.parameters.map { "\($0.name) \($0.type)" }.joined(separator: " ")
                guard matches(command.name, command.detail, parameterText, command.direct ?? "") else { continue }
                var line = "- cmd \(command.name)"
                if let direct = command.direct { line += " <\(direct)>" }
                for parameter in command.parameters { line += " \(parameter.name)\(parameter.optional ? "?" : ""):\(parameter.type)" }
                if let result = command.result { line += " -> \(result)" }
                body.append(line + Self.note(command.detail))
            }
            for cls in suite.classes {
                let header = cls.name + (cls.inherits.map { " " + $0 } ?? "") + " " + cls.detail + " " + cls.elements.joined(separator: " ")
                let whole = matches(header)
                let kept = whole ? cls.properties : cls.properties.filter { matches($0.name, $0.type) }
                guard whole || !kept.isEmpty else { continue }
                var line = "- class \(cls.name)" + (cls.isExtension ? "+" : "") + (cls.inherits.map { " (\($0))" } ?? "")
                if !kept.isEmpty {
                    line += ": " + kept.map { "\($0.name):\($0.type)\($0.readOnly ? " ro" : "")" }.joined(separator: ", ")
                }
                if whole, !cls.elements.isEmpty { line += "; elements: " + cls.elements.joined(separator: ", ") }
                body.append(line + (whole ? Self.note(cls.detail) : ""))
            }
            for enumeration in suite.enumerations where matches(enumeration.name, enumeration.values.joined(separator: " ")) {
                body.append("- enum \(enumeration.name): " + enumeration.values.joined(separator: "|"))
            }
            if !body.isEmpty { out.append("## \(suite.name)" + Self.note(suite.detail)); out += body }
        }
        return out
    }

    private static func note(_ detail: String) -> String {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return "  # " + (text.count > 70 ? String(text.prefix(70)) + "…" : text)
    }

    /// The lines from `offset` that fit in `limit` characters, and where the next page starts (nil at the end).
    static func page(_ lines: [String], offset: Int, limit: Int = pageCharacters) -> (text: String, next: Int?) {
        let start = min(max(offset, 0), lines.count)
        var used = 0
        var end = start
        while end < lines.count, end == start || used + lines[end].count + 1 <= limit {
            used += lines[end].count + 1
            end += 1
        }
        return (lines[start..<end].joined(separator: "\n"), end < lines.count ? end : nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - The tool

/// Parsed dictionaries by app path and version: an app's dictionary only changes when the app does.
actor AppDictionaryCache {
    static let shared = AppDictionaryCache()
    private var entries: [String: AppDictionary?] = [:]

    func lookup(_ key: String) -> AppDictionary?? { entries[key] }

    func store(_ dictionary: AppDictionary?, for key: String) {
        if entries.count >= 40 { entries.removeAll() }
        entries[key] = dictionary
    }
}

struct AppDictionaryTool: AgentTool {
    let spec = ToolSpec(
        name: "app_dictionary",
        description: """
        Read an app's AppleScript dictionary (commands, classes with properties and elements) before writing a script \
        for it. Compact; `search` or `suite` narrow it, `offset` continues a long one.
        """,
        parameters: .schema([
            "app": .property("string", "App name, bundle identifier or .app path."),
            "search": .property("string"),
            "suite": .property("string"),
            "offset": .property("integer"),
        ], required: ["app"]))

    /// `sdef`'s XML for an app, or nil when it has no dictionary. A seam for tests.
    var readSdef: @Sendable (URL) async throws -> Data? = AppDictionaryTool.liveSdef

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Lendo o dicionário do app", arguments["app"]?.string ?? "")
    }

    static func liveSdef(_ app: URL) async throws -> Data? {
        let result = try await ProcessRunner.run("/usr/bin/sdef", [app.path], timeout: .seconds(20), outputLimit: 8_000_000)
        // A timeout is not "no dictionary": it must not be remembered as one.
        if result.timedOut { throw ToolError("O sdef de \(app.deletingPathExtension().lastPathComponent) passou de 20 s. Tente de novo.") }
        guard result.status == 0 else { return nil }
        return Data(result.output.utf8)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let name = try arguments.requiredString("app")
        guard let url = await Self.appURL(name) else {
            throw ToolError("Não encontrei o app \"\(name)\" neste Mac. Use apps_list para ver os nomes.")
        }
        let bundle = Bundle(url: url)
        let display = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let key = [url.path, bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                   bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""].joined(separator: "|")
        let dictionary: AppDictionary?
        if let cached = await AppDictionaryCache.shared.lookup(key) {
            dictionary = cached
        } else {
            try Task.checkCancellation()
            let data = try await readSdef(url)
            dictionary = data.flatMap(AppDictionary.parse)
            try Task.checkCancellation()
            await AppDictionaryCache.shared.store(dictionary, for: key)
        }
        guard let dictionary, !dictionary.suites.isEmpty else {
            return "\(display) não tem dicionário de AppleScript: não aceita comandos de script. Procure um atalho dele com "
                + "shortcuts_list, ou use ui_read e ui_act."
        }
        let lines = dictionary.lines(search: arguments.nonEmptyString("search"), suite: arguments.nonEmptyString("suite"))
        let search = arguments.nonEmptyString("search")
        guard !lines.isEmpty else {
            let suites = dictionary.suites.map(\.name).joined(separator: ", ")
            return "Nada no dicionário de \(display) combina com \"\(search ?? arguments.nonEmptyString("suite") ?? "")\". Suítes: \(suites)."
        }
        let offset = arguments.integer("offset", default: 0, in: 0...Int.max)
        let page = AppDictionary.page(lines, offset: offset)
        var text = "Dicionário de \(display) (\(lines.count) linhas"
            + (search == nil && arguments.nonEmptyString("suite") == nil ? ", \(dictionary.suites.count) suítes" : "") + "). "
            + "cmd <direct> param:tipo ?=opcional; class (herda de); + estende; ro somente leitura.\n"
            + page.text
        if offset == 0, dictionary.includesStandardSuite { text += "\n" + AppDictionary.standardSuiteNote }
        if let next = page.next { text += "\n[... mais \(lines.count - next) linhas; offset \(next) continua, ou use search ou suite ...]" }
        return text
    }

    /// A path to an app, or a name the way `open` finds one.
    static func appURL(_ name: String) async -> URL? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            return path.hasSuffix(".app") && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return await OpenTool.application(named: text)
    }
}
