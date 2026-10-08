import Foundation

enum PermissionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask, auto, bypass, readOnly

    var id: String { rawValue }

    /// A mode from a newer version falls back to the most cautious one.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .ask) }

    var label: String {
        switch self {
        case .ask: "Perguntar antes"
        case .auto: "Automático"
        case .bypass: "Sem pedir permissão"
        case .readOnly: "Só leitura"
        }
    }

    var summary: String {
        switch self {
        case .ask: "Pede sua aprovação antes de mudar algo, rodar comandos ou acessar a web."
        case .auto: "Faz tudo sozinho, mas pergunta antes de comandos destrutivos (rm -rf, sudo, push --force…)."
        case .bypass: "Nunca pergunta: roda qualquer comando e altera qualquer arquivo sem confirmação."
        case .readOnly: "Só lê e pesquisa; não muda nada no seu Mac."
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .auto: "bolt"
        case .bypass: "bolt.trianglebadge.exclamationmark"
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
    var capabilities: Set<Capability> = [.terminal, .browser, .computerUse]
    /// What the user chose "Sempre permitir" for, each grant narrowed by a scope (`PermissionRule`). Grants saved
    /// before scopes existed (`allowedTools`, tool names of either engine) are converted when the Orb loads.
    var permissionRules: [PermissionRule] = []
    /// Where commands run and relative paths resolve; empty means the home folder.
    var workingDirectory = ""
    /// Hash (see `FolderInstructions.hash`) of the folder's instruction file the user chose to trust. While the file
    /// still has this hash its text is given to the Orb as instructions; when it changes it is reference material
    /// again until the user trusts it anew.
    var trustedInstructionsHash: String?
    var unread = 0
    /// Memory list of versions before each Orb had its own memory bank; moved into the bank at launch.
    var memory: [MemoryFact] = []

    var workingURL: URL {
        workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser
            : URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
    }
}

/// Tolerant decoding (see `KeyedDecodingContainer.value(_:default:)` in Store.swift).
extension Bot {
    private enum LegacyKeys: String, CodingKey { case allowedTools }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.value(.role, default: "")
        orb = try c.value(.orb, default: OrbConfig())
        model = try c.value(.model, default: "")
        permissionMode = try c.value(.permissionMode, default: .ask)
        capabilities = Set(try c.lossyArray(.capabilities, default: [.terminal, .browser]))
        permissionRules = try c.lossyArray(.permissionRules)
        if let old = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([String].self, forKey: .allowedTools) {
            permissionRules = PermissionPolicy.unique(permissionRules + PermissionPolicy.legacyRules(fromToolNames: old))
        }
        workingDirectory = try c.value(.workingDirectory, default: "")
        trustedInstructionsHash = try c.decodeIfPresent(String.self, forKey: .trustedInstructionsHash)
        unread = try c.value(.unread, default: 0)
        memory = try c.value(.memory, default: [])
    }
}

struct MemoryFact: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var text: String
}

struct TranscriptItem: Identifiable, Codable, Sendable, Equatable {
    enum Kind: Codable, Sendable, Equatable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        kind = try c.decode(Kind.self, forKey: .kind)
        date = try c.value(.date, default: Date.now)
    }
}

/// A bot's current conversation: what the UI shows and what the model sees.
struct Conversation: Codable, Sendable {
    var items: [TranscriptItem] = []
    var messages: [ChatMessage] = []
    /// Claude Code keeps its own history; turns run through it resume this session.
    var claudeSessionID: String?
    /// The folder that session runs in. Claude Code stores sessions per folder, so after the Orb's folder
    /// changes the session can't be resumed and a new one starts (nil = recorded before this was tracked).
    var claudeSessionFolder: String?
    /// How many of `messages` that Claude Code session has seen; later ones (other models' turns) are
    /// handed to it as context on its next turn.
    var claudeSeenCount: Int?
    /// How many of `items` are already saved in the Orb's memory as session pages.
    var memorySavedCount: Int?
    /// Identity and preferences as the current Claude Code session's (frozen) system prompt has them.
    var claudeMemoryPinned: String?
    /// Summary standing in for the first `summaryCoveredCount` of `messages`, which no longer fit the model's
    /// window (see `ContextWindow`). The messages themselves stay.
    var summary: String?
    var summaryCoveredCount: Int?
    /// Hash of the workspace snapshot the model last got in this conversation (it is sent again only when it changes).
    var workspaceHash: String?
    /// The same for the current Claude Code session, which never sees the snapshots other models were given.
    var claudeWorkspaceHash: String?
    /// Hash of the permissions and folder instructions in the current Claude Code session's (frozen) system prompt.
    var claudeStandingHash: String?

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

extension Conversation {
    mutating func record(_ marks: DeliveryMarks) { marks.record(in: &self) }

    /// Tolerant decoding: an item or message this version can't read (an unknown case after a downgrade) is
    /// skipped instead of sending the whole conversation to `.corrupt`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.lossyArray(.items)
        messages = try c.lossyArray(.messages)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        claudeSessionFolder = try c.decodeIfPresent(String.self, forKey: .claudeSessionFolder)
        claudeSeenCount = try c.decodeIfPresent(Int.self, forKey: .claudeSeenCount)
        memorySavedCount = try c.decodeIfPresent(Int.self, forKey: .memorySavedCount)
        claudeMemoryPinned = try c.decodeIfPresent(String.self, forKey: .claudeMemoryPinned)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryCoveredCount = try c.decodeIfPresent(Int.self, forKey: .summaryCoveredCount)
        workspaceHash = try c.decodeIfPresent(String.self, forKey: .workspaceHash)
        claudeWorkspaceHash = try c.decodeIfPresent(String.self, forKey: .claudeWorkspaceHash)
        claudeStandingHash = try c.decodeIfPresent(String.self, forKey: .claudeStandingHash)
    }
}

struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case shell, browser, file, search, computer, connector, memory

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .connector) }

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

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .failed) }
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

extension ToolCall {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        kind = try c.value(.kind, default: Kind.connector)
        title = try c.value(.title, default: "")
        detail = try c.value(.detail, default: "")
        state = try c.value(.state, default: State.done)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        startedAt = try c.value(.startedAt, default: Date.now)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

enum ApprovalDecision: String, Codable, Sendable, Equatable {
    /// `task`: allowed until this turn ends. `always`: allowed from now on, by the rule chosen on the card.
    case deny, once, always, task

    /// A decision from a newer version counts as a refusal.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .deny) }

    var label: String {
        switch self {
        case .deny: "Negado"
        case .once: "Permitido uma vez"
        case .task: "Permitido nesta tarefa"
        case .always: "Sempre permitido"
        }
    }
}

struct ApprovalRequest: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    /// Model-facing tool name.
    var toolName: String
    var title: String
    var command: String
    var reason: String
    var decision: ApprovalDecision?
    /// Standing rules the card offers under "Sempre…" (also what "Só nesta tarefa" grants, the first one).
    /// Empty for calls that must always ask.
    var suggestions: [PermissionRule] = []
}

extension ApprovalRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        toolName = try c.value(.toolName, default: "")
        title = try c.value(.title, default: "")
        command = try c.value(.command, default: "")
        reason = try c.value(.reason, default: "")
        decision = try c.decodeIfPresent(ApprovalDecision.self, forKey: .decision)
        suggestions = try c.lossyArray(.suggestions)
    }
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

    /// Turning a routine back on counts from now: its old `lastRun` would make it due right away.
    mutating func setEnabled(_ enabled: Bool, now: Date = .now) {
        if enabled && !isEnabled { lastRun = now }
        isEnabled = enabled
    }
}

extension Routine {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.value(.name, default: "")
        botID = try c.decode(UUID.self, forKey: .botID)
        prompt = try c.value(.prompt, default: "")
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        isEnabled = try c.value(.isEnabled, default: true)
        createdAt = try c.value(.createdAt, default: Date.now)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
    }
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
        source = try c.decodeIfPresent(String.self, forKey: .source).map { $0 == Self.legacyBuiltInSource ? Self.builtInSource : $0 }
        folderURL = try c.decodeIfPresent(URL.self, forKey: .folderURL)
    }

    /// `source` of the skills that ship with the app (`legacyBuiltInSource` in files saved while it was OpenBot).
    static let builtInSource = "orb"
    static let legacyBuiltInSource = "openbot"

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
