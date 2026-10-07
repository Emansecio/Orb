import Foundation

enum PermissionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask, auto, readOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: "Perguntar antes"
        case .auto: "Automático"
        case .readOnly: "Só leitura"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .auto: "bolt"
        case .readOnly: "eye"
        }
    }
}

enum Capability: String, CaseIterable, Identifiable, Codable, Sendable {
    case terminal, browser, computerUse, connectors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Terminal e arquivos"
        case .browser: "Ler páginas da web"
        case .computerUse: "Apps do Mac (AppleScript)"
        case .connectors: "Conectores"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "globe"
        case .computerUse: "macwindow"
        case .connectors: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

struct Bot: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var role: String
    var orb: OrbConfig
    /// Model id; empty means the provider's default model.
    var model = ""
    var permissionMode = PermissionMode.ask
    var capabilities: Set<Capability> = [.terminal, .browser]
    /// Tools the user chose "Sempre permitir" for.
    var allowedTools: Set<String> = []
    /// Where commands run and relative paths resolve; empty means the home folder.
    var workingDirectory = ""
    var unread = 0
    var memory: [MemoryFact] = []

    var workingURL: URL {
        workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
    }
}

/// Tolerant decoding (see `KeyedDecodingContainer.value(_:default:)` in Store.swift).
extension Bot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.value(.role, default: "")
        orb = try c.value(.orb, default: OrbConfig())
        model = try c.value(.model, default: "")
        permissionMode = try c.value(.permissionMode, default: .ask)
        capabilities = try c.value(.capabilities, default: [.terminal, .browser])
        allowedTools = try c.value(.allowedTools, default: [])
        workingDirectory = try c.value(.workingDirectory, default: "")
        unread = try c.value(.unread, default: 0)
        memory = try c.value(.memory, default: [])
    }
}

struct MemoryFact: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var text: String
}

struct TranscriptItem: Identifiable, Codable, Sendable {
    enum Kind: Codable, Sendable {
        case user(text: String, attachments: [String])
        case bot(text: String, isStreaming: Bool)
        case tool(ToolCall)
        case approval(ApprovalRequest)
        case notice(String)
    }

    var id = UUID()
    var kind: Kind
    var date = Date.now

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// A bot's current conversation: what the UI shows and what the model sees.
struct Conversation: Codable, Sendable {
    var items: [TranscriptItem] = []
    var messages: [ChatMessage] = []

    /// After a quit or crash mid-turn: nothing is streaming, running or waiting anymore.
    func closingInterruptedTurn() -> Conversation {
        var copy = self
        for index in copy.items.indices {
            switch copy.items[index].kind {
            case .bot(let text, true):
                copy.items[index].kind = .bot(text: text, isStreaming: false)
            case .tool(var call) where call.state == .running:
                call.state = .failed
                call.output = call.output ?? "Interrompido."
                copy.items[index].kind = .tool(call)
            case .approval(var request) where request.decision == nil:
                request.decision = .deny
                copy.items[index].kind = .approval(request)
            default:
                break
            }
        }
        return copy
    }
}

struct ToolCall: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case shell, browser, file, search, computer, connector, memory

        var symbol: String {
            switch self {
            case .shell: "terminal"
            case .browser: "globe"
            case .file: "doc.text"
            case .search: "magnifyingglass"
            case .computer: "macwindow"
            case .connector: "puzzlepiece.extension"
            case .memory: "brain"
            }
        }
    }

    enum State: String, Codable, Sendable, Equatable {
        case running, done, failed
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var state = State.running
    var output: String?
    var startedAt = Date.now
    var finishedAt: Date?

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

enum ApprovalDecision: String, Codable, Sendable, Equatable {
    case deny, once, always

    var label: String {
        switch self {
        case .deny: "Negado"
        case .once: "Permitido uma vez"
        case .always: "Sempre permitido"
        }
    }
}

struct ApprovalRequest: Identifiable, Codable, Sendable {
    var id = UUID()
    /// Model-facing tool name ("Sempre permitir" remembers it per bot).
    var toolName: String
    var title: String
    var command: String
    var reason: String
    var decision: ApprovalDecision?
}

// MARK: - Routines

struct Routine: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var botID: UUID
    var prompt: String
    var schedule: Schedule
    var isEnabled = true
    var createdAt = Date.now
    var lastRun: Date?
    var lastResult: String?

    var nextRun: Date { schedule.next(after: lastRun ?? createdAt) }
}

enum Schedule: Codable, Hashable, Sendable {
    case daily(hour: Int, minute: Int)
    /// `weekday` uses Calendar numbering (1 = domingo).
    case weekly(weekday: Int, hour: Int, minute: Int)
    case everyHours(Int)

    func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily(let hour, let minute):
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? date
        case .weekly(let weekday, let hour, let minute):
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                              matchingPolicy: .nextTime) ?? date
        case .everyHours(let hours):
            date.addingTimeInterval(Double(max(1, hours)) * 3600)
        }
    }

    var label: String {
        switch self {
        case .daily(let hour, let minute):
            "Todo dia às \(Self.time(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            "\([1, 7].contains(weekday) ? "Todo" : "Toda") \(Calendar.current.weekdaySymbols[(weekday + 6) % 7]) às \(Self.time(hour, minute))"
        case .everyHours(let hours):
            hours == 1 ? "A cada hora" : "A cada \(hours) horas"
        }
    }

    private static func time(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

// MARK: - Skills

/// Reusable instructions, invoked with "/slug" at the start of a prompt.
struct Skill: Identifiable, Codable, Sendable {
    var id = UUID()
    var slug: String
    var name: String
    var summary: String
    var instructions: String
    var uses = 0
    /// Disabled skills stay installed but can't be invoked.
    var isEnabled = true
    /// Catalog id ("owner/repo/skill") when installed from the catalog.
    var source: String?
    /// GitHub folder of a catalog skill (its instructions may point to files there).
    var folderURL: URL?
}

extension Skill {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.value(.name, default: slug)
        summary = try c.value(.summary, default: "")
        instructions = try c.value(.instructions, default: "")
        uses = try c.value(.uses, default: 0)
        isEnabled = try c.value(.isEnabled, default: true)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        folderURL = try c.decodeIfPresent(URL.self, forKey: .folderURL)
    }

    /// `source` of the skills that ship with the app.
    static let builtInSource = "openbot"

    /// A slug from free text: lowercase letters, digits and dashes.
    static func slugify(_ text: String) -> String {
        String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(32))
    }
}

enum SidebarItem: Hashable {
    case bot(UUID)
    case routines
    case connectors
    case skills
}
