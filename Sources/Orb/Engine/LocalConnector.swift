import Foundation

// Connectors that run inside the app, without a server to launch: Google Agenda and Lembretes (EventKit) and Gmail (Mail.app).
// They sit behind the same door as every other connector (`connector_tools` / `connector_call`), so they get the catalog, the
// approval cards and the "Sempre permitir" rules for free. To the rest of the app a local connector is an MCP server that
// answers in-process (`LocalTransport`).

/// One tool of a local connector: the same four things an MCP server says about a tool.
struct LocalTool: Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
    var annotations: MCPToolAnnotations

    /// A tool that only reads what is on this Mac.
    static func reading(_ name: String, _ description: String, _ parameters: JSONValue = .schema([:])) -> LocalTool {
        LocalTool(name: name, description: description, parameters: parameters, annotations: MCPToolAnnotations(readOnly: true, openWorld: false))
    }

    /// A tool that changes something.
    static func writing(_ name: String, _ description: String, _ parameters: JSONValue, destructive: Bool = false) -> LocalTool {
        LocalTool(name: name, description: description, parameters: parameters,
                  annotations: MCPToolAnnotations(readOnly: false, destructive: destructive, openWorld: false))
    }
}

protocol LocalConnector: Sendable {
    var tools: [LocalTool] { get }
    /// Runs a tool and returns its text; throws a `ToolError` that says what to do about it.
    func call(_ name: String, arguments: JSONValue) async throws -> String
    /// How long one call may take before the connector is taken for stuck. It must cover everything a call does in a row
    /// (Gmail runs two scripts), so the connector's own, clearer errors come first.
    var callTimeout: Duration { get }
}

extension LocalConnector {
    var callTimeout: Duration { .seconds(60) }
}

/// The local connectors there are. The raw value is what `MCPServerConfig.local` holds.
enum LocalConnectorKind: String, CaseIterable, Identifiable, Sendable {
    case agenda, lembretes, gmail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agenda: "Google Agenda"
        case .lembretes: "Lembretes"
        case .gmail: "Gmail"
        }
    }

    /// What the connector does, in the line the model reads about it (and the card shows).
    var summary: String {
        switch self {
        case .agenda: "Ver, criar, alterar e apagar eventos da Agenda do Mac, inclusive da sua conta Google."
        case .lembretes: "Ver e criar lembretes no app Lembretes."
        case .gmail: "Buscar e ler e-mails, criar rascunhos e enviar, pelo app Mail com a sua conta Google."
        }
    }

    /// A new connector of this kind, ready to install.
    var config: MCPServerConfig {
        var config = MCPServerConfig(name: title)
        config.local = rawValue
        config.summary = summary
        return config
    }
}

/// What the local connectors use to reach the Mac: the calendar database and Mail. Tests and snapshots replace it, so no
/// permission of macOS is ever asked outside the running app.
struct LocalConnectorEnvironment: Sendable {
    var calendar: any CalendarBackend
    var mail: any MailBackend

    static let live = LocalConnectorEnvironment(calendar: EventKitBackend(), mail: LiveMailBackend())

    /// The connector of `kind`.
    func connector(_ kind: LocalConnectorKind) -> any LocalConnector {
        switch kind {
        case .agenda: CalendarConnector(backend: calendar)
        case .lembretes: RemindersConnector(backend: calendar)
        case .gmail: GmailConnector(backend: mail)
        }
    }

    /// The connector a config stands for (nil for an ordinary server).
    func connector(for config: MCPServerConfig) -> (any LocalConnector)? {
        config.local.flatMap(LocalConnectorKind.init(rawValue:)).map(connector)
    }
}

// MARK: - Speaking MCP

/// The JSON-RPC side of a local connector: what `MCPStdioServer` needs to serve one, for the in-process transport.
enum LocalConnectorServer {
    /// The response to one message; nil for notifications.
    static func respond(to request: JSONValue, connector: any LocalConnector) async -> JSONValue? {
        await MCPStdioServer.respond(to: request, handler: Handler(connector: connector))
    }

    /// A local connector as an MCP server: its tools, listed with their annotations, and its calls.
    private struct Handler: MCPServerHandler {
        let connector: any LocalConnector
        var serverName: String { "orb-local" }

        func listedTools() -> [JSONValue] { connector.tools.map(listed) }

        func offers(_ tool: String) -> Bool { connector.tools.contains { $0.name == tool } }

        func call(_ tool: String, arguments: JSONValue) async -> JSONValue {
            do {
                return MCPStdioServer.textResult(try await connector.call(tool, arguments: arguments))
            } catch {
                return MCPStdioServer.textResult(error.localizedDescription, isError: true)
            }
        }

        private func listed(_ tool: LocalTool) -> JSONValue {
            var annotations: [String: JSONValue] = [:]
            if let readOnly = tool.annotations.readOnly { annotations["readOnlyHint"] = .bool(readOnly) }
            if let destructive = tool.annotations.destructive { annotations["destructiveHint"] = .bool(destructive) }
            if let openWorld = tool.annotations.openWorld { annotations["openWorldHint"] = .bool(openWorld) }
            return .object(["name": .string(tool.name), "description": .string(tool.description),
                            "inputSchema": tool.parameters, "annotations": .object(annotations)])
        }
    }
}

/// A local connector as a transport for `MCPConnection`: every request is answered in-process.
actor LocalTransport: MCPTransport {
    private let connector: any LocalConnector
    private var receive: (@Sendable (JSONValue) async -> Void)?

    init(connector: any LocalConnector) { self.connector = connector }

    func open(receive: @escaping @Sendable (JSONValue) async -> Void, closed: @escaping @Sendable (Error) async -> Void) {
        self.receive = receive
    }

    func send(_ message: JSONValue) async throws {
        guard let receive, let answer = await LocalConnectorServer.respond(to: message, connector: connector) else { return }
        await receive(answer)
    }

    func close() { receive = nil }

    var diagnostics: String { "" }
}

// MARK: - Dates

/// Dates as the model writes them: `2026-10-12`, `2026-10-12T09:00`, or with a zone (`…-03:00`, `…Z`). Without a zone the
/// time is the Mac's.
enum LocalDates {
    static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let zoned = ISO8601DateFormatter()
        zoned.formatOptions = [.withInternetDateTime]
        if let date = zoned.date(from: text) { return date }
        zoned.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = zoned.date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func required(_ arguments: JSONValue, _ key: String) throws -> Date {
        guard let text = arguments.nonEmptyString(key) else { throw ToolError("Faltou o argumento \"\(key)\".") }
        guard let date = parse(text) else { throw ToolError("Não entendi a data \"\(text)\" em \"\(key)\". Use o formato 2026-10-12 ou 2026-10-12T09:00.") }
        return date
    }

    /// The date a tool asked for in an optional argument; throws if it is there but unreadable.
    static func optional(_ arguments: JSONValue, _ key: String) throws -> Date? {
        arguments.nonEmptyString(key) == nil ? nil : try required(arguments, key)
    }

    /// Whether the text names a time of day (`2026-10-12T09:00`) and not only a day (`2026-10-12`).
    static func hasTime(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
    }

    /// The end of a period asked for in an argument. A day with no time ("to": "2026-10-10") means that whole day, so it ends
    /// where the next one starts; otherwise "what do I have tomorrow?" would search from midnight to midnight.
    static func requiredEnd(_ arguments: JSONValue, _ key: String) throws -> Date {
        let date = try required(arguments, key)
        return hasTime(arguments.nonEmptyString(key) ?? "") ? date : endOfDay(date)
    }

    static func optionalEnd(_ arguments: JSONValue, _ key: String) throws -> Date? {
        arguments.nonEmptyString(key) == nil ? nil : try requiredEnd(arguments, key)
    }

    private static func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(24 * 3600)
    }

    /// `2026-10-12 09:00` in the Mac's time zone, or `2026-10-12` for an all-day event: what the model reads back.
    static func text(_ date: Date, allDay: Bool = false) -> String {
        (allDay ? dayFormatter : minuteFormatter).string(from: date)
    }

    // Formatting with a shared DateFormatter is thread-safe (macOS 14+).
    private static let minuteFormatter = formatter("yyyy-MM-dd HH:mm")
    private static let dayFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
