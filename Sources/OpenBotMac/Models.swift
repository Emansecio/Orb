import Foundation

enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
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

enum Capability: String, CaseIterable, Identifiable, Sendable {
    case terminal, browser, computerUse, connectors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Comandos no Terminal"
        case .browser: "Navegador"
        case .computerUse: "Controlar o Mac"
        case .connectors: "Apps conectados"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "globe"
        case .computerUse: "cursorarrow.rays"
        case .connectors: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

struct Bot: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var role: String
    var orb: OrbConfig
    var model: String
    var permissionMode: PermissionMode
    var capabilities: Set<Capability>
    var unread = 0
    var memory: [MemoryFact] = []
}

struct MemoryFact: Identifiable, Hashable, Sendable {
    let id = UUID()
    var text: String
}

struct TranscriptItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case user(text: String, attachments: [String])
        case bot(text: String, isStreaming: Bool)
        case tool(ToolCall)
        case approval(ApprovalRequest)
        case notice(String)
    }

    let id: UUID
    var kind: Kind
    let date: Date

    init(_ kind: Kind, id: UUID = UUID(), date: Date = .now) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

struct ToolCall: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case shell, browser, file, search, computer, connector, memory

        var symbol: String {
            switch self {
            case .shell: "terminal"
            case .browser: "globe"
            case .file: "doc.text"
            case .search: "magnifyingglass"
            case .computer: "cursorarrow.rays"
            case .connector: "puzzlepiece.extension"
            case .memory: "brain"
            }
        }
    }

    enum State: Sendable, Equatable {
        case running, done, failed
    }

    let id: UUID
    var kind: Kind
    var title: String
    var detail: String
    var state: State
    var output: String?
    var startedAt: Date
    var finishedAt: Date?

    init(kind: Kind, title: String, detail: String, state: State = .running, output: String? = nil,
         startedAt: Date = .now, finishedAt: Date? = nil) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.output = output
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

enum ApprovalDecision: Sendable, Equatable {
    case deny, once, always

    var label: String {
        switch self {
        case .deny: "Negado"
        case .once: "Permitido uma vez"
        case .always: "Sempre permitido"
        }
    }
}

struct ApprovalRequest: Identifiable, Sendable {
    let id: UUID
    var title: String
    var command: String
    var reason: String
    var decision: ApprovalDecision?

    init(title: String, command: String, reason: String, decision: ApprovalDecision? = nil) {
        self.id = UUID()
        self.title = title
        self.command = command
        self.reason = reason
        self.decision = decision
    }
}

struct Routine: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var botID: UUID
    var schedule: String
    var nextRun: Date
    var isEnabled: Bool
    var pausedForInactivity: Bool
    var lastResult: String
}

struct Connector: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var symbol: String
    var category: String
    var summary: String
    var isConnected: Bool
}

struct Skill: Identifiable, Sendable {
    let id = UUID()
    var slug: String
    var name: String
    var summary: String
    var uses: Int
    var owner: String
}

enum SidebarItem: Hashable {
    case bot(UUID)
    case routines
    case connectors
    case skills
}

enum Catalog {
    static let models = ["grok-4.6", "grok-4.6-fast", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
}
