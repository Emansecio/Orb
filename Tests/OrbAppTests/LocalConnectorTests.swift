import Foundation
import Testing
@testable import Orb

// The connectors that run on this Mac (Google Agenda, Lembretes, Gmail) with fakes in place of EventKit and Mail: nothing here
// asks macOS for a permission or reads a real calendar or mailbox.

// MARK: - Fakes

final class FakeCalendar: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()
    private struct State {
        var eventsAccess = CalendarAccess.granted
        var remindersAccess = CalendarAccess.granted
        var requests: [String] = []
        var calendars = [CalendarInfo(id: "cal-g", title: "Trabalho", account: "Google", isWritable: true),
                         CalendarInfo(id: "cal-i", title: "Casa", account: "iCloud", isWritable: true),
                         CalendarInfo(id: "cal-r", title: "Feriados", account: "Google", isWritable: false)]
        var events: [EventInfo] = []
        var reminders: [ReminderInfo] = []
        var created: [EventDraft] = []
        var updated: [(String, EventDraft)] = []
        var deleted: [String] = []
        var createdReminders: [ReminderDraft] = []
    }

    private func read<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }

    var eventsAccess: CalendarAccess { get { read { $0.eventsAccess } } set { read { $0.eventsAccess = newValue } } }
    var remindersAccess: CalendarAccess { get { read { $0.remindersAccess } } set { read { $0.remindersAccess = newValue } } }
    var requests: [String] { read { $0.requests } }
    var calendarList: [CalendarInfo] { get { read { $0.calendars } } set { read { $0.calendars = newValue } } }
    var eventList: [EventInfo] { get { read { $0.events } } set { read { $0.events = newValue } } }
    var reminderList: [ReminderInfo] { get { read { $0.reminders } } set { read { $0.reminders = newValue } } }
    var created: [EventDraft] { read { $0.created } }
    var updated: [(String, EventDraft)] { read { $0.updated } }
    var deleted: [String] { read { $0.deleted } }
    var createdReminders: [ReminderDraft] { read { $0.createdReminders } }
    /// What a request for access ends as (the person's answer to the dialog).
    var answer = CalendarAccess.granted

    func access(_ entity: CalendarEntity) -> CalendarAccess { read { entity == .events ? $0.eventsAccess : $0.remindersAccess } }

    func requestAccess(_ entity: CalendarEntity) async -> CalendarAccess {
        read { $0.requests.append(entity == .events ? "events" : "reminders") }
        guard access(entity) == .notDetermined else { return access(entity) }
        read { if entity == .events { $0.eventsAccess = answer } else { $0.remindersAccess = answer } }
        return access(entity)
    }

    private func require(_ entity: CalendarEntity) throws {
        if access(entity) != .granted { throw ToolError("sem permissão") }
    }

    func calendars() async throws -> [CalendarInfo] { try require(.events); return calendarList }

    func events(from: Date, to: Date, calendar: String?, query: String?, limit: Int) async throws -> [EventInfo] {
        try require(.events)
        return eventList.filter { $0.start >= from && $0.start <= to && (calendar == nil || $0.calendar == calendar)
            && (query == nil || $0.title.localizedCaseInsensitiveContains(query!)) }.prefix(limit).map { $0 }
    }

    func event(id: String) async throws -> EventInfo {
        guard let found = eventList.first(where: { $0.id == id }) else { throw ToolError("Não achei o evento \(id).") }
        return found
    }

    func createEvent(_ draft: EventDraft) async throws -> EventInfo {
        try require(.events)
        read { $0.created.append(draft) }
        let start = draft.start ?? Date(), made = EventInfo(id: "novo", title: draft.title ?? "", start: start, end: draft.end ?? start.addingTimeInterval(3600),
                                                            isAllDay: draft.isAllDay ?? false, location: draft.location ?? "", notes: draft.notes ?? "",
                                                            calendar: draft.calendar ?? "Trabalho", isRecurring: false)
        eventList.append(made)
        return made
    }

    func updateEvent(id: String, _ draft: EventDraft) async throws -> EventInfo {
        var found = try await event(id: id)
        read { $0.updated.append((id, draft)) }
        found.title = draft.title ?? found.title
        return found
    }

    func deleteEvent(id: String) async throws -> EventInfo {
        let found = try await event(id: id)
        read { $0.deleted.append(id) }
        return found
    }

    func reminderLists() async throws -> [ReminderListInfo] { try require(.reminders); return [ReminderListInfo(id: "l1", title: "Mercado", account: "iCloud")] }

    func reminders(list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderInfo] {
        try require(.reminders)
        return reminderList.filter { includeCompleted || !$0.isCompleted }.prefix(limit).map { $0 }
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderInfo {
        try require(.reminders)
        read { $0.createdReminders.append(draft) }
        return ReminderInfo(id: "r-novo", title: draft.title, list: draft.list ?? "Lembretes", due: draft.due, dueHasTime: draft.dueHasTime, isCompleted: false, notes: draft.notes ?? "")
    }
}

final class FakeMail: MailBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    private var status = MacPermissionStatus.granted
    private var requested = 0
    /// The answer for a script that contains the key (the first key that does).
    private var answers: [(String, String)] = []
    var failure: ToolError?
    /// How long each script takes (Mail is slow when it has to open and sync).
    var delay = Duration.zero
    private var scriptFailures: [(String, ToolError)] = []
    /// The error for a script that contains the key.
    func fail(containing key: String, with error: ToolError) { lock.withLock { scriptFailures.append((key, error)) } }

    var ran: [String] { lock.withLock { scripts } }
    var requestCount: Int { lock.withLock { requested } }
    var permission: MacPermissionStatus { get { lock.withLock { status } } set { lock.withLock { status = newValue } } }
    var answer = MacPermissionStatus.granted
    func reply(containing key: String, with text: String) { lock.withLock { answers.append((key, text)) } }

    /// The accounts script's answer for one Google and one iCloud account.
    static let accountsAnswer = ["g1", "Google", "imap.gmail.com", "maria@gmail.com"].joined(separator: "\u{1F}") + "\u{1E}"
        + ["i1", "iCloud", "", "maria@icloud.com"].joined(separator: "\u{1F}") + "\u{1E}"

    func automation() async -> MacPermissionStatus { permission }

    func requestAutomation() async -> MacPermissionStatus {
        lock.withLock { requested += 1 }
        if permission == .notDetermined { permission = answer }
        return permission
    }

    func run(_ script: String) async throws -> String {
        lock.withLock { scripts.append(script) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        if let error = lock.withLock({ scriptFailures.first { script.contains($0.0) }?.1 }) { throw error }
        return lock.withLock { answers.first { script.contains($0.0) }?.1 } ?? ""
    }
}

private func event(_ id: String, _ title: String, _ start: Date, hours: Double = 1, calendar: String = "Trabalho", location: String = "",
                   notes: String = "", allDay: Bool = false, recurring: Bool = false) -> EventInfo {
    EventInfo(id: id, title: title, start: start, end: start.addingTimeInterval(hours * 3600), isAllDay: allDay, location: location, notes: notes,
              calendar: calendar, isRecurring: recurring)
}

private func at(_ text: String) -> Date { LocalDates.parse(text)! }

private func call(_ connector: any LocalConnector, _ tool: String, _ arguments: [String: JSONValue] = [:]) async throws -> String {
    try await connector.call(tool, arguments: .object(arguments))
}

// MARK: - Speaking MCP

struct LocalConnectorServerTests {
    private let connector = CalendarConnector(backend: FakeCalendar())

    @Test func itAnswersTheHandshakeTheListAndTheCalls() async throws {
        let initialize = try #require(await LocalConnectorServer.respond(to: .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-06-18")])]), connector: connector))
        #expect(initialize["result"]?["protocolVersion"]?.string == "2025-06-18" && initialize["result"]?["capabilities"]?["tools"] != nil)

        let list = try #require(await LocalConnectorServer.respond(to: .object(["id": .number(2), "method": .string("tools/list")]), connector: connector))
        let tools = try #require(list["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == connector.tools.map(\.name))
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"]?.string ?? "", $0) })
        #expect(byName["search_events"]?["annotations"]?["readOnlyHint"]?.bool == true && byName["search_events"]?["annotations"]?["openWorldHint"]?.bool == false)
        #expect(byName["delete_event"]?["annotations"]?["destructiveHint"]?.bool == true)
        #expect(byName["create_event"]?["annotations"]?["readOnlyHint"]?.bool == false)

        let called = try #require(await LocalConnectorServer.respond(to: .object([
            "id": .number(3), "method": .string("tools/call"),
            "params": .object(["name": .string("list_calendars"), "arguments": .object([:])])]), connector: connector))
        #expect(called["result"]?["isError"]?.bool == false)
        #expect(called["result"]?["content"]?.array?.first?["text"]?.string?.contains("Trabalho — conta: Google") == true)

        // A tool that fails is an error result the model can read, not a protocol error.
        let failed = try #require(await LocalConnectorServer.respond(to: .object([
            "id": .number(4), "method": .string("tools/call"),
            "params": .object(["name": .string("get_event"), "arguments": .object(["id": .string("x")])])]), connector: connector))
        #expect(failed["result"]?["isError"]?.bool == true && failed["error"] == nil)

        let unknown = try #require(await LocalConnectorServer.respond(to: .object([
            "id": .number(5), "method": .string("tools/call"), "params": .object(["name": .string("nope")])]), connector: connector))
        #expect(unknown["error"]?["code"]?.int == -32602)
        // A notification has no answer.
        #expect(await LocalConnectorServer.respond(to: .object(["method": .string("notifications/initialized")]), connector: connector) == nil)
    }

    private struct Quiet: MCPServerHandler {
        var serverName: String { "quiet" }
        var answersParseErrors: Bool { false }
        func listedTools() -> [JSONValue] { [] }
        func offers(_ tool: String) -> Bool { false }
        func call(_ tool: String, arguments: JSONValue) async -> JSONValue { MCPStdioServer.textResult("") }
    }

    @Test func aLineThatIsNotJSONIsSkippedWhenTheHandlerSaysSoAndAnUnknownMethodIsAnError() async throws {
        #expect(await MCPStdioServer.respond(toLine: "{nao é json", handler: Quiet()) == nil)
        #expect(await LocalConnectorServer.respond(toLine: "{nao é json", connector: connector) == nil)
        #expect(await LocalConnectorServer.respond(toLine: "[1, 2]", connector: connector) == nil)
        let unknown = try #require(await LocalConnectorServer.respond(to: .object(["id": .number(7), "method": .string("resources/list")]), connector: connector))
        #expect(unknown["error"]?["code"]?.int == -32601 && unknown["id"] == .number(7))
        let ping = try #require(await LocalConnectorServer.respond(to: .object(["id": .number(8), "method": .string("ping")]), connector: connector))
        #expect(ping["result"] == .object([:]))
    }

    @Test func theCommandLineNamesTheConnector() {
        #expect(LocalConnectorServer.kind(arguments: ["Orb", "--local-connector", "gmail"]) == .gmail)
        #expect(LocalConnectorServer.kind(arguments: ["Orb", "--local-connector", "outro"]) == nil)
        #expect(LocalConnectorServer.kind(arguments: ["Orb", "--local-connector"]) == nil)
        #expect(LocalConnectorServer.kind(arguments: ["Orb"]) == nil)
    }

    @Test func claudeCodeStartsTheAppsOwnBinaryForALocalConnector() throws {
        let agenda = LocalConnectorKind.agenda.config
        let github = MCPServerConfig(name: "GitHub", url: "https://api.githubcopilot.com/mcp/")
        #expect(ClaudeCodeTurn.mcpNames([agenda, github]) == [agenda.id: "google-agenda", github.id: "github"])
        let config = try #require(ClaudeCodeTurn.mcpConfig([agenda, github]))
        let entry = try #require(config["mcpServers"]?["google-agenda"])
        #expect(entry["type"]?.string == "stdio" && entry["args"]?.array?.compactMap(\.string) == ["--local-connector", "agenda"])
        #expect(entry["command"]?.string?.isEmpty == false)
        // A disabled one is left out, like any connector.
        var off = LocalConnectorKind.gmail.config
        off.isEnabled = false
        #expect(ClaudeCodeTurn.mcpNames([off]).isEmpty)
    }

    @Test func aLocalConnectorSurvivesTheDataFileAndOldFilesLackTheField() throws {
        let config = LocalConnectorKind.gmail.config
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        #expect(back.local == "gmail" && back == config && back.command.isEmpty && !back.isRemote)
        let old = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"GitHub","url":"https://x.example/mcp"}"#.utf8))
        #expect(old.local == nil)
        #expect(LocalConnectorKind.allCases.allSatisfy { $0.config.name == $0.title && $0.config.summary == $0.summary && $0.config.local == $0.rawValue })
    }
}

// MARK: - Through the manager and the gateway

struct LocalConnectorManagerTests {
    @Test func aLocalConnectorStartsOnUseAnswersInProcessAndKeepsItsCatalog() async throws {
        let fake = FakeCalendar()
        fake.eventList = [event("e1", "Reunião", at("2026-10-12T09:00"))]
        let manager = MCPManager(locals: LocalConnectorEnvironment(calendar: fake, mail: FakeMail()))
        let config = LocalConnectorKind.agenda.config
        await manager.sync([config])
        // Registering starts nothing.
        #expect(await manager.status()[config.id] == .idle(toolCount: nil))
        let text = try await manager.call(config.id, tool: "search_events", arguments: .object(["from": .string("2026-10-12"), "to": .string("2026-10-13")]))
        #expect(text.contains("Reunião") && text.contains("id: e1"))
        let catalog = try #require(await manager.catalog(config.id))
        #expect(catalog.tools.map(\.name) == CalendarConnector(backend: fake).tools.map(\.name))
        #expect(catalog.tools.first { $0.name == "list_calendars" }?.annotations.readOnly == true)
        #expect(await manager.status()[config.id] == .ready(toolCount: 6))
        // A tool that throws reaches the model as an error.
        await #expect(throws: ToolError("Não achei o evento zzz.")) { try await manager.call(config.id, tool: "get_event", arguments: .object(["id": .string("zzz")])) }
    }

    @Test func theGatewayReachesALocalConnectorLikeAnyOther() async throws {
        let fake = FakeCalendar()
        fake.eventList = [event("e1", "Dentista", at("2026-10-14T15:00"))]
        let manager = MCPManager(locals: LocalConnectorEnvironment(calendar: fake, mail: FakeMail()))
        let config = LocalConnectorKind.agenda.config
        await manager.sync([config])
        let listing = ConnectorToolsTool(connectors: [config], manager: manager)
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(listing.spec.description.contains("- Google Agenda: Ver, criar, alterar e apagar eventos da Agenda do Mac"))
        let tools = try await listing.run(.object(["connector": .string("Google Agenda")]), context: context)
        #expect(tools.contains("search_events — Finds events") && tools.contains("delete_event — Deletes an event"))
        let resolved = try await ConnectorCallTool(connectors: [config], manager: manager).resolve(.object([
            "connector": .string("google agenda"), "tool": .string("get_event"), "arguments": .object(["id": .string("e1")])]))
        #expect(resolved.tool.spec.name == "Google_Agenda__get_event")
        #expect(try await resolved.tool.run(resolved.arguments, context: context).contains("Dentista"))
    }

    @Test func readingIsFreeAndSendingOrDeletingAsksEvenInAutomaticMode() async throws {
        let manager = MCPManager(locals: LocalConnectorEnvironment(calendar: FakeCalendar(), mail: FakeMail()))
        let agenda = LocalConnectorKind.agenda.config, gmail = LocalConnectorKind.gmail.config, lembretes = LocalConnectorKind.lembretes.config
        await manager.sync([agenda, gmail, lembretes])
        for config in [agenda, gmail, lembretes] { try await manager.ensureStarted(config.id) }
        func verdict(_ config: MCPServerConfig, _ tool: String, mode: PermissionMode = .auto) async throws -> PermissionVerdict {
            let catalog = try #require(await manager.catalog(config.id))
            let mcp = try #require(catalog.mcpTools(serverName: config.name, serverID: config.id, manager: manager).first { $0.toolName == tool })
            let call = PermissionPolicy.call(for: mcp, arguments: .object([:]), context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
            return PermissionPolicy.evaluate(mode: mode, call: call, rules: [], workspace: nil)
        }
        // Reading needs no card.
        for (config, tool) in [(agenda, "list_calendars"), (agenda, "search_events"), (gmail, "search_messages"), (gmail, "read_message"), (lembretes, "list_reminders")] {
            #expect(try await verdict(config, tool, mode: .ask) == .allow, Comment(rawValue: tool))
        }
        // Writing asks when the Orb is set to ask; deleting and sending ask in every mode but "Sem pedir permissão".
        for (config, tool) in [(agenda, "create_event"), (gmail, "create_draft"), (lembretes, "create_reminder")] {
            #expect(try await verdict(config, tool, mode: .ask) == .ask(.needsPermission), Comment(rawValue: tool))
            #expect(try await verdict(config, tool, mode: .auto) == .allow, Comment(rawValue: tool))
        }
        // Changing an event makes Google tell its guests, so it is a sending too.
        for (config, tool) in [(agenda, "update_event"), (agenda, "delete_event"), (gmail, "send_message")] {
            guard case .ask(.dangerous) = try await verdict(config, tool, mode: .auto) else { Issue.record("\(tool) did not ask in Automático"); continue }
            #expect(try await verdict(config, tool, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
        }
    }
}

// MARK: - Google Agenda and Lembretes

struct CalendarConnectorTests {
    @Test func listsTheCalendarsWithTheirAccounts() async throws {
        let connector = CalendarConnector(backend: FakeCalendar())
        let text = try await call(connector, "list_calendars")
        #expect(text == "Trabalho — conta: Google — id: cal-g\nCasa — conta: iCloud — id: cal-i\nFeriados — conta: Google (só leitura) — id: cal-r")
    }

    @Test func searchesByPeriodTextAndCalendarAndReadsTheDates() async throws {
        let fake = FakeCalendar()
        fake.eventList = [event("a", "Reunião de produto", at("2026-10-12T09:00"), location: "Sala 3", notes: "Levar o roteiro"),
                          event("b", "Almoço", at("2026-10-12T12:30"), calendar: "Casa"),
                          event("c", "Aniversário", at("2026-10-15"), allDay: true),
                          event("d", "Depois", at("2026-11-20T10:00"))]
        let connector = CalendarConnector(backend: fake)
        let week = try await call(connector, "search_events", ["from": .string("2026-10-12"), "to": .string("2026-10-18")])
        #expect(week.contains("Reunião de produto — 2026-10-12 09:00 a 10:00") && week.contains("  onde: Sala 3") && week.contains("  notas: Levar o roteiro"))
        #expect(week.contains("Aniversário — dia inteiro, 2026-10-15") && !week.contains("Depois"))
        let only = try await call(connector, "search_events", ["from": .string("2026-10-12"), "to": .string("2026-10-18"), "query": .string("almoço"), "calendar": .string("Casa")])
        #expect(only.contains("Almoço") && !only.contains("Reunião"))
        let none = try await call(connector, "search_events", ["from": .string("2027-01-01"), "to": .string("2027-01-02")])
        #expect(none == "Nenhum evento entre 2027-01-01 00:00 e 2027-01-03 00:00.")
        // Dates with an offset and a limit given as text work too.
        let zoned = try await call(connector, "search_events", ["from": .string("2026-10-12T00:00:00-03:00"), "to": .string("2026-10-31T00:00:00Z"), "limit": .string("1")])
        #expect(zoned.components(separatedBy: "\n\n").count == 1)
    }

    /// "What do I have tomorrow?" is one day on both ends: a date with no time includes that whole day.
    @Test func aPeriodGivenAsDatesIncludesTheLastDay() async throws {
        let fake = FakeCalendar()
        fake.eventList = [event("a", "Reunião", at("2026-10-10T09:00")), event("b", "Ontem", at("2026-10-09T09:00")), event("c", "Depois", at("2026-10-11T09:00"))]
        let connector = CalendarConnector(backend: fake)
        let day = try await call(connector, "search_events", ["from": .string("2026-10-10"), "to": .string("2026-10-10")])
        #expect(day.contains("Reunião") && !day.contains("Ontem") && !day.contains("Depois"))
        // With a time, the end is exactly what was asked.
        let early = try await call(connector, "search_events", ["from": .string("2026-10-10T00:00"), "to": .string("2026-10-10T08:00")])
        #expect(early.hasPrefix("Nenhum evento"))
        #expect(connector.tools.first { $0.name == "search_events" }?.description.contains("Finds events") == true)
        #expect(LocalDates.hasTime("2026-10-10T08:00") && !LocalDates.hasTime(" 2026-10-10 "))
    }

    @Test func badPeriodsAreExplained() async {
        let connector = CalendarConnector(backend: FakeCalendar())
        await #expect(throws: ToolError("Não entendi a data \"amanhã\" em \"from\". Use o formato 2026-10-12 ou 2026-10-12T09:00.")) {
            try await call(connector, "search_events", ["from": .string("amanhã"), "to": .string("2026-10-12")])
        }
        await #expect(throws: ToolError("\"to\" vem antes de \"from\".")) {
            try await call(connector, "search_events", ["from": .string("2026-10-12"), "to": .string("2026-10-01")])
        }
        await #expect(throws: ToolError("O período passa de dois anos: busque em partes.")) {
            try await call(connector, "search_events", ["from": .string("2020-01-01"), "to": .string("2026-10-01")])
        }
        await #expect(throws: ToolError("Faltou o argumento \"to\".")) { try await call(connector, "search_events", ["from": .string("2026-10-01")]) }
    }

    @Test func createsChangesAndDeletesWhatItIsToldTo() async throws {
        let fake = FakeCalendar()
        fake.eventList = [event("a", "Reunião", at("2026-10-12T09:00"))]
        let connector = CalendarConnector(backend: fake)
        let made = try await call(connector, "create_event", ["title": .string("Dentista"), "start": .string("2026-10-14T15:00"), "location": .string("Rua A"),
                                                              "notes": .string("Levar exames"), "calendar": .string("Trabalho")])
        #expect(made.hasPrefix("Evento criado.\nDentista — 2026-10-14 15:00 a 16:00"))
        #expect(fake.created == [EventDraft(title: "Dentista", start: at("2026-10-14T15:00"), end: nil, isAllDay: false, location: "Rua A", notes: "Levar exames", calendar: "Trabalho")])
        #expect(try await call(connector, "update_event", ["id": .string("a"), "title": .string("Reunião 2")]).hasPrefix("Evento alterado.\nReunião 2"))
        // The calendar tells the guests about a change, so the tool is marked destructive and the event shows how many there are.
        #expect(connector.tools.first { $0.name == "update_event" }?.annotations.destructive == true)
        var invited = event("g", "Cliente", at("2026-10-13T10:00"))
        invited.guests = 3
        #expect(CalendarConnector.describe(invited).contains("convidados: 3 (mudar ou apagar avisa os convidados)"))
        #expect(!CalendarConnector.describe(event("h", "Sozinho", at("2026-10-13T10:00"))).contains("convidados"))
        #expect(fake.updated.first?.1 == EventDraft(title: "Reunião 2", start: nil, end: nil, isAllDay: nil, location: nil, notes: nil, calendar: nil))
        #expect(try await call(connector, "delete_event", ["id": .string("a")]).hasPrefix("Evento apagado: Reunião"))
        #expect(fake.deleted == ["a"])
        await #expect(throws: ToolError("\"end\" vem antes de \"start\".")) {
            try await call(connector, "create_event", ["title": .string("X"), "start": .string("2026-10-14T15:00"), "end": .string("2026-10-14T14:00")])
        }
        await #expect(throws: ToolError("Faltou o argumento \"title\".")) { try await call(connector, "create_event", ["start": .string("2026-10-14")]) }
        // No guests, no Meet: the description says so, so the model does not promise them.
        #expect(connector.tools.first { $0.name == "create_event" }?.description.contains("Cannot add guests or a Meet link") == true)
    }

    @Test func noPermissionIsSaidInPlainWords() async {
        let fake = FakeCalendar()
        fake.eventsAccess = .denied
        await #expect(throws: ToolError("sem permissão")) { try await call(CalendarConnector(backend: fake), "list_calendars") }
    }

    @Test func remindersListAndCreate() async throws {
        let fake = FakeCalendar()
        fake.reminderList = [ReminderInfo(id: "r1", title: "Comprar leite", list: "Mercado", due: at("2026-10-10T18:00"), isCompleted: false, notes: ""),
                             ReminderInfo(id: "r2", title: "Pagar luz", list: "Casa", due: nil, isCompleted: true, notes: "")]
        let connector = RemindersConnector(backend: fake)
        #expect(try await call(connector, "list_reminder_lists") == "Mercado — conta: iCloud — id: l1")
        #expect(try await call(connector, "list_reminders") == "[ ] Comprar leite — lista: Mercado — para: 2026-10-10 18:00 — id: r1")
        #expect(try await call(connector, "list_reminders", ["include_completed": .bool(true)]).contains("[feito] Pagar luz"))
        let made = try await call(connector, "create_reminder", ["title": .string("Ligar para a Ana"), "due": .string("2026-10-11T09:00"), "list": .string("Mercado")])
        #expect(made.hasPrefix("Lembrete criado: [ ] Ligar para a Ana — lista: Mercado — para: 2026-10-11 09:00"))
        #expect(fake.createdReminders == [ReminderDraft(title: "Ligar para a Ana", list: "Mercado", due: at("2026-10-11T09:00"), notes: nil)])
        // A reminder for a day has no time: it is saved and shown as the day.
        let allDay = try await call(connector, "create_reminder", ["title": .string("Renovar CNH"), "due": .string("2026-10-12")])
        #expect(fake.createdReminders.last?.dueHasTime == false && fake.createdReminders.first?.dueHasTime == true)
        #expect(allDay.contains("para: 2026-10-12") && !allDay.contains("00:00"))
        // There is no way to delete a reminder: the Orb can only add.
        #expect(!connector.tools.contains { $0.name.contains("delete") })
    }

    @Test func datesAreReadTheWayTheModelWritesThem() {
        #expect(LocalDates.parse("2026-10-12T09:00:00-03:00") == Date(timeIntervalSince1970: 1_791_806_400))
        #expect(LocalDates.parse("2026-10-12T12:00:00Z") == Date(timeIntervalSince1970: 1_791_806_400))
        #expect(LocalDates.parse("2026-10-12") == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        #expect(LocalDates.parse("2026-10-12 09:30") == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 30)))
        #expect(LocalDates.parse("") == nil && LocalDates.parse(nil) == nil && LocalDates.parse("12/10/2026") == nil)
        #expect(CalendarInfo(id: "", title: "", account: "Gmail - maria", isWritable: true).isGoogle)
        #expect(!CalendarInfo(id: "", title: "", account: "iCloud", isWritable: true).isGoogle)
    }
}

// MARK: - Gmail

struct GmailConnectorTests {
    private let draft: [String: JSONValue] = ["to": .string("ana@x.com"), "subject": .string("Oi"), "body": .string("Olá")]

    @Test func aSlowMailIsNotCutOffByTheGenericDeadlineOfTheServers() async throws {
        // Each call runs two scripts (the accounts, then the action), 80 ms each: more than the 100 ms every other connector gets.
        let mail = FakeMail()
        mail.reply(containing: "repeat with a in accounts", with: FakeMail.accountsAnswer)
        mail.delay = .milliseconds(80)
        let manager = MCPManager(locals: LocalConnectorEnvironment(calendar: FakeCalendar(), mail: mail), callTimeout: .milliseconds(100))
        let config = LocalConnectorKind.gmail.config
        await manager.sync([config])
        let text = try await manager.call(config.id, tool: "create_draft", arguments: .object(draft))
        #expect(text.hasPrefix("Rascunho salvo"))
        await manager.sync([])
    }

    @Test func aSendThatRanOutOfTimeSaysTheMessageMayHaveLeft() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.fail(containing: "send msg", with: ToolError(AppleScript.timeoutMessage(seconds: 90)))
        do {
            _ = try await call(gmail, "send_message", draft)
            Issue.record("expected an error")
        } catch {
            let text = (error as? ToolError)?.message ?? ""
            #expect(text.contains("pode ter sido enviado") && text.contains("Enviados"), "\(text)")
        }
        // A draft that ran out of time is just an error: nothing could have left.
        mail.fail(containing: "save msg", with: ToolError(AppleScript.timeoutMessage(seconds: 90)))
        await #expect(throws: ToolError(AppleScript.timeoutMessage(seconds: 90))) { try await call(gmail, "create_draft", draft) }
    }

    private func connector(_ mail: FakeMail) -> GmailConnector {
        mail.reply(containing: "repeat with a in accounts", with: FakeMail.accountsAnswer)
        return GmailConnector(backend: mail)
    }

    private func row(_ fields: String...) -> String { fields.joined(separator: "\u{1F}") + "\u{1E}" }

    @Test func onlyGoogleAccountsCount() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        let accounts = try await gmail.googleAccounts(named: nil, all: true)
        #expect(accounts == [MailAccount(id: "g1", name: "Google", host: "imap.gmail.com", address: "maria@gmail.com")])
        #expect(MailAccount(id: "", name: "Trabalho", host: "imap.gmail.com", address: "x@empresa.com.br").isGoogle)
        #expect(MailAccount(id: "", name: "Pessoal", host: "", address: "x@googlemail.com").isGoogle)
        #expect(!MailAccount(id: "", name: "iCloud", host: "imap.mail.me.com", address: "x@icloud.com").isGoogle)
        await #expect(throws: ToolError("Não achei a conta \"zzz\". As contas Google no Mail: maria@gmail.com.")) { try await gmail.googleAccounts(named: "zzz") }
        // Without a Google account the connector says how to add one.
        let empty = FakeMail()
        empty.reply(containing: "repeat with a in accounts", with: row("i1", "iCloud", "", "x@icloud.com"))
        await #expect(throws: ToolError("O Mail não tem uma conta Google. Peça para a pessoa adicionar em Ajustes do Sistema → Contas de Internet → Google e marcar Mail.")) {
            try await GmailConnector(backend: empty).googleAccounts(named: nil)
        }
    }

    @Test func moreThanOneGoogleAccountAsksWhich() async {
        let mail = FakeMail()
        mail.reply(containing: "repeat with a in accounts", with: row("g1", "A", "imap.gmail.com", "a@gmail.com") + row("g2", "B", "imap.gmail.com", "b@gmail.com"))
        await #expect(throws: ToolError("Há mais de uma conta Google no Mail (a@gmail.com, b@gmail.com). Diga qual em \"account\".")) {
            try await call(GmailConnector(backend: mail), "search_messages")
        }
    }

    @Test func listsTheMailboxesWithUnreadCounts() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "repeat with m in mailboxes of acc", with: row("INBOX", "3") + row("[Gmail]", "0") + row("[Gmail]/All Mail", "0") + row("[Gmail]/Sent Mail", "0"))
        let text = try await call(gmail, "list_mailboxes")
        #expect(text == "Conta: maria@gmail.com\n  INBOX (3 não lidas)\n  [Gmail]\n  [Gmail]/All Mail\n  [Gmail]/Sent Mail")
        #expect(mail.ran.last?.contains(#"first account whose id is "g1""#) == true)
    }

    @Test func searchSortsNewestFirstCutsToTheLimitAndSaysWhatToDoNext() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "set found to", with: "5\u{1E}" + row("101", "2026-10-08T10:00:00", "Ana <ana@x.com>", "Oi", "true")
                   + row("103", "2026-10-09T08:30:00", "Banco <b@banco.com>", "Fatura", "false") + row("102", "2026-10-08T18:00:00", "Rui <rui@x.com>", "Reunião", "true"))
        let text = try await call(gmail, "search_messages", ["since": .string("2026-10-01"), "query": .string("a\"b"), "limit": .number(2)])
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "[não lida] 2026-10-09 08:30 — Banco <b@banco.com> — Fatura — id: 103")
        #expect(lines[1] == "2026-10-08 18:00 — Rui <rui@x.com> — Reunião — id: 102")
        #expect(!text.contains("id: 101"))
        #expect(text.contains("Conta: maria@gmail.com, caixa: INBOX.") && text.contains("Havia 5 mensagens no período; só as 3 primeiras foram lidas"))
        // The script filters by period and text, in a quoted literal that cannot break out.
        let script = try #require(mail.ran.last { $0.contains("set found to") })
        #expect(script.contains("set year of sinceDate to 2026") && script.contains("set month of sinceDate to 10") && script.contains("set day of sinceDate to 1\n"))
        #expect(script.contains(#"(subject contains "a\"b" or sender contains "a\"b")"#) && script.contains(#"mailbox "INBOX" of acc"#))
        #expect(!script.contains("untilDate") && !script.contains("read status is false"))
        _ = try await call(gmail, "search_messages", ["since": .string("2026-10-01"), "until": .string("2026-10-05"), "unread_only": .bool(true), "mailbox": .string("[Gmail]/All Mail")])
        // "until" with a date only includes that day: the script stops at the start of the next one.
        let narrower = try #require(mail.ran.last { $0.contains("set found to") })
        #expect(narrower.contains("set day of untilDate to 6\n"))
        #expect(narrower.contains("date received ≤ untilDate") && narrower.contains("read status is false") && narrower.contains(#"mailbox "[Gmail]/All Mail" of acc"#))
    }

    @Test func anEmptySearchSaysSo() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "set found to", with: "0\u{1E}")
        #expect(try await call(gmail, "search_messages", ["since": .string("2026-10-01")]) == "Nenhuma mensagem em INBOX de maria@gmail.com desde 2026-10-01 00:00.")
    }

    @Test func readingAMessageGivesHeadersAndText() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "set body to content of m", with: ["Proposta", "Ana <ana@x.com>", "maria@gmail.com, ", "chefe@x.com, ", "2026-10-09T08:30:00", "contrato.pdf, ", "Olá,\n\nSegue a proposta.\n"].joined(separator: "\u{1F}"))
        let text = try await call(gmail, "read_message", ["mailbox": .string("INBOX"), "id": .number(103)])
        #expect(text == "Assunto: Proposta\nDe: Ana <ana@x.com>\nPara: maria@gmail.com\nCc: chefe@x.com\nData: 2026-10-09 08:30\nAnexos: contrato.pdf\n\nOlá,\n\nSegue a proposta.")
        let script = try #require(mail.ran.last { $0.contains("set body to content of m") })
        #expect(script.contains("first message of mb whose id is 103") && script.contains("text 1 thru 12000 of body"))
        await #expect(throws: ToolError("Faltou o argumento \"id\".")) { try await call(gmail, "read_message", ["mailbox": .string("INBOX")]) }
    }

    @Test func aDraftIsSavedAndNeverSent() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "make new outgoing message", with: "ok")
        let text = try await call(gmail, "create_draft", ["to": .array([.string("ana@x.com")]), "cc": .string("rui@x.com; lia@x.com"),
                                                         "subject": .string("Oi \"você\""), "body": .string("Linha 1\nLinha 2 \\ fim")])
        #expect(text == "Rascunho salvo em maria@gmail.com para ana@x.com. Nada foi enviado.")
        let script = try #require(mail.ran.last { $0.contains("make new outgoing message") })
        #expect(script.contains("save msg") && !script.contains("send msg"))
        #expect(script.contains(#"subject:"Oi \"você\"""#) && script.contains("Linha 1\nLinha 2 \\\\ fim"))
        #expect(script.contains(#"make new to recipient at end of to recipients with properties {address:"ana@x.com"}"#))
        #expect(script.contains(#"make new cc recipient at end of cc recipients with properties {address:"rui@x.com"}"#) && script.contains(#"{address:"lia@x.com"}"#))
        #expect(script.contains(#"set sender of msg to "maria@gmail.com""#))
    }

    @Test func sendingIsItsOwnToolAndSaysSoInItsName() async throws {
        let mail = FakeMail()
        let gmail = connector(mail)
        mail.reply(containing: "make new outgoing message", with: "ok")
        #expect(try await call(gmail, "send_message", ["to": .string("ana@x.com"), "subject": .string("Oi"), "body": .string("Olá")])
                == "E-mail enviado de maria@gmail.com para ana@x.com.")
        #expect(mail.ran.last?.contains("send msg") == true)
        // The name is what makes it ask in every mode (see PermissionPolicy.connectorDanger).
        #expect(PermissionPolicy.connectorDanger(toolName: "send_message", annotations: .none) != nil)
        #expect(PermissionPolicy.connectorDanger(toolName: "create_draft", annotations: .none) == nil)
        // Nothing goes out to something that is not an address, or to nobody.
        await #expect(throws: ToolError("\"ana\" não parece um endereço de e-mail.")) {
            try await call(gmail, "send_message", ["to": .string("ana"), "subject": .string("Oi"), "body": .string("x")])
        }
        await #expect(throws: ToolError("Faltou o argumento \"to\".")) { try await call(gmail, "send_message", ["subject": .string("Oi"), "body": .string("x")]) }
        #expect(mail.ran.filter { $0.contains("send msg") }.count == 1)
    }

    /// The scripts are real AppleScript: `osacompile` accepts them (it compiles, it never runs them or asks for a permission).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile")))
    func everyScriptCompiles() throws {
        let scripts = [MailScripts.accounts, MailScripts.mailboxes(accountID: "g1"),
                       MailScripts.search(accountID: "g1", mailbox: "INBOX", since: at("2026-10-01"), until: at("2026-10-08"), query: "a\"b\\c", unreadOnly: true, fetch: 200),
                       MailScripts.search(accountID: "g1", mailbox: "[Gmail]/All Mail", since: at("2026-10-01"), until: nil, query: nil, unreadOnly: false, fetch: 200),
                       MailScripts.read(accountID: "g1", mailbox: "INBOX", messageID: 7, characters: 12_000),
                       MailScripts.compose(from: "a@gmail.com", to: ["b@x.com"], cc: ["c@x.com"], subject: "Oi \"x\"", body: "a\nb", send: false),
                       MailScripts.compose(from: "a@gmail.com", to: ["b@x.com"], cc: [], subject: "Oi", body: "", send: true)]
        for script in scripts {
            let directory = FileManager.default.temporaryDirectory.appending(path: "osa-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appending(path: "s.applescript")
            try script.write(to: source, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", directory.appending(path: "s.scpt").path, source.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 0, Comment(rawValue: message + "\n" + script))
        }
    }

    @Test func anAppleScriptLiteralCannotBeBrokenOutOf() {
        #expect(MailScripts.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        let hostile = #"x" & (do shell script "touch /tmp/pwned") & ""#
        let script = MailScripts.compose(from: "a@gmail.com", to: ["b@x.com"], cc: [], subject: hostile, body: hostile, send: false)
        #expect(script.contains(#"subject:"x\" & (do shell script \"touch /tmp/pwned\") & \"""#))
    }
}

// MARK: - Setup

struct LocalConnectorSetupTests {
    private func makeSetup(_ calendar: FakeCalendar = FakeCalendar(), _ mail: FakeMail = FakeMail()) -> LocalConnectorSetup {
        LocalConnectorSetup(environment: LocalConnectorEnvironment(calendar: calendar, mail: mail))
    }

    @Test func checkingNeverAsksButConnectingDoes() async {
        let calendar = FakeCalendar(), mail = FakeMail()
        calendar.eventsAccess = .notDetermined
        calendar.remindersAccess = .notDetermined
        mail.permission = .notDetermined
        let setup = makeSetup(calendar, mail)
        #expect(await setup.state(of: .agenda) == .needsPermission)
        #expect(await setup.state(of: .lembretes) == .needsPermission)
        #expect(await setup.state(of: .gmail) == .needsPermission)
        #expect(calendar.requests.isEmpty && mail.requestCount == 0)

        // One click, one dialog: the person answers yes.
        #expect(await setup.connect(.agenda) == .ready)
        #expect(calendar.requests == ["events"])
        #expect(await setup.connect(.lembretes) == .ready)
        #expect(calendar.requests == ["events", "reminders"])
        mail.reply(containing: "repeat with a in accounts", with: FakeMail.accountsAnswer)
        #expect(await setup.connect(.gmail) == .ready)
        #expect(mail.requestCount == 1)
    }

    @Test func aRefusalIsNotAskedAgain() async {
        let calendar = FakeCalendar(), mail = FakeMail()
        calendar.eventsAccess = .notDetermined
        calendar.answer = .denied
        mail.permission = .denied
        let setup = makeSetup(calendar, mail)
        #expect(await setup.connect(.agenda) == .denied)
        #expect(await setup.state(of: .agenda) == .denied)
        #expect(await setup.state(of: .gmail) == .denied)
        let denied = LocalConnectorState.denied
        #expect(denied.needsAttention && denied.message.contains("Ajustes do Sistema"))
    }

    @Test func withoutAGoogleAccountTheCardSaysSo() async {
        let calendar = FakeCalendar(), mail = FakeMail()
        calendar.calendarList = [CalendarInfo(id: "i", title: "Casa", account: "iCloud", isWritable: true)]
        mail.reply(containing: "repeat with a in accounts", with: "i1\u{1F}iCloud\u{1F}\u{1F}x@icloud.com\u{1E}")
        let setup = makeSetup(calendar, mail)
        #expect(await setup.state(of: .agenda) == .noAccount)
        #expect(await setup.state(of: .gmail) == .noAccount)
        // Reminders have nothing to do with Google.
        #expect(await setup.state(of: .lembretes) == .ready)
        #expect(LocalConnectorState.noAccount.needsAttention && LocalConnectorState.noAccount.message.contains("Contas de Internet"))
        #expect(LocalConnectorSetup.internetAccountsURL.absoluteString == "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
    }

    /// A Google Workspace account is named by its address in the calendar, so its name does not say Google.
    @Test func aWorkspaceAccountIsTakenOnTheWordOfThePerson() async {
        let calendar = FakeCalendar()
        calendar.calendarList = [CalendarInfo(id: "w", title: "Trabalho", account: "maria@empresa.com.br", isWritable: true)]
        let setup = makeSetup(calendar)
        #expect(await setup.state(of: .agenda) == .noAccount)
        #expect(await setup.connect(.agenda) == .noAccount)
        // "Conectar assim mesmo" is remembered on the connector, so the card stops asking.
        #expect(await setup.state(of: .agenda, anyAccount: true) == .ready)
        #expect(await setup.connect(.agenda, anyAccount: true) == .ready)
    }

    @Test func readyWhenThePermissionAndTheAccountAreThere() async {
        let mail = FakeMail()
        mail.reply(containing: "repeat with a in accounts", with: FakeMail.accountsAnswer)
        let setup = makeSetup(FakeCalendar(), mail)
        #expect(await setup.state(of: .agenda) == .ready)
        #expect(await setup.state(of: .gmail) == .ready)
        #expect(!LocalConnectorState.ready.needsAttention)
    }

    @Test func aClosedMailIsNotAProblem() async {
        let mail = FakeMail()
        mail.permission = .appNotRunning
        let setup = makeSetup(FakeCalendar(), mail)
        #expect(await setup.state(of: .gmail) == .unchecked)
        #expect(!LocalConnectorState.unchecked.needsAttention)
        #expect(mail.ran.isEmpty)
    }

    @Test func restrictionsAndABareBinaryAreExplained() async {
        let calendar = FakeCalendar()
        calendar.eventsAccess = .restricted
        calendar.remindersAccess = .unsupported
        let setup = makeSetup(calendar)
        #expect(await setup.state(of: .agenda) == .unavailable("O macOS não deixa o Orb usar a Agenda neste Mac."))
        guard case .unavailable(let reason) = await setup.state(of: .lembretes) else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("scripts/bundle.sh"))
        let mail = FakeMail()
        mail.failure = ToolError("Mail travou")
        #expect(await makeSetup(FakeCalendar(), mail).state(of: .gmail) == .unavailable("Mail travou"))
    }
}
