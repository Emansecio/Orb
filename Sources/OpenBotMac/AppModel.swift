import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    var bots: [Bot]
    var transcripts: [UUID: [TranscriptItem]] = [:]
    var drafts: [UUID: String] = [:]
    var statusLine: [UUID: String] = [:]
    /// Bumped on every transcript mutation so chat views can keep the bottom in view.
    var scrollTick: [UUID: Int] = [:]
    var routines: [Routine]
    var connectors: [Connector]
    var skills: [Skill]
    var showInspector = true
    var showNewBot = false
    /// Bots that just finished a turn; their Orb celebrates for a moment.
    var celebrating: Set<UUID> = []
    /// Bots that just received a prompt (short "listening" beat before thinking).
    var listening: Set<UUID> = []
    /// Bots whose last turn was interrupted or failed (brief "error" expression).
    var failed: Set<UUID> = []
    /// Incremented when a prompt is sent; Orbs jump when it changes.
    var pokes: [UUID: Int] = [:]
    var selection: SidebarItem? {
        didSet {
            if case .bot(let id) = selection, let index = bots.firstIndex(where: { $0.id == id }) {
                bots[index].unread = 0
            }
        }
    }

    @ObservationIgnored private var turns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let gateway: any AgentGateway

    init(gateway: any AgentGateway = MockGateway()) {
        self.gateway = gateway
        let seed = SeedData.make()
        bots = seed.bots
        transcripts = seed.transcripts
        routines = seed.routines
        connectors = seed.connectors
        skills = seed.skills
        selection = seed.bots.first.map { .bot($0.id) }
    }

    // MARK: Queries

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    var selectedBot: Bot? {
        if case .bot(let id) = selection { bot(id) } else { nil }
    }

    func transcript(_ botID: UUID) -> [TranscriptItem] { transcripts[botID] ?? [] }

    func isWorking(_ botID: UUID) -> Bool { statusLine[botID] != nil }

    /// What the bot's Orb is doing right now (expression, gaze and motion follow this).
    func activity(for botID: UUID) -> OrbActivity {
        if hasPendingApproval(botID) { return .waiting }
        if failed.contains(botID) { return .error }
        if celebrating.contains(botID) { return .happy }
        guard isWorking(botID) else { return .idle }
        if let kind = runningToolKind(botID) {
            switch kind {
            case .shell: return .typing
            case .browser, .computer: return .browsing
            case .file: return .reading
            case .search: return .searching
            case .connector, .memory: return .thinking
            }
        }
        return listening.contains(botID) ? .listening : .thinking
    }

    private func runningToolKind(_ botID: UUID) -> ToolCall.Kind? {
        for item in transcript(botID).reversed().prefix(3) {
            if case .tool(let call) = item.kind, call.state == .running { return call.kind }
        }
        return nil
    }

    private func hasPendingApproval(_ botID: UUID) -> Bool {
        transcript(botID).reversed().prefix(4).contains { item in
            if case .approval(let request) = item.kind { request.decision == nil } else { false }
        }
    }

    func routines(for botID: UUID) -> [Routine] { routines.filter { $0.botID == botID } }

    // MARK: Bots

    func createBot(name: String, role: String, orb: OrbConfig, model: String, mode: PermissionMode) {
        let bot = Bot(id: UUID(), name: name, role: role, orb: orb, model: model,
                      permissionMode: mode, capabilities: [.terminal, .browser])
        bots.append(bot)
        selection = .bot(bot.id)
    }

    func update(_ botID: UUID, _ change: (inout Bot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        change(&bots[index])
    }

    func selectAdjacentBot(offset: Int) {
        guard !bots.isEmpty else { return }
        let current = selectedBot.flatMap { bot in bots.firstIndex { $0.id == bot.id } } ?? -offset
        let next = (current + offset + bots.count) % bots.count
        selection = .bot(bots[next].id)
    }

    func newConversation(_ botID: UUID) {
        stop(botID)
        transcripts[botID] = []
        drafts[botID] = ""
    }

    // MARK: Turns

    func send(_ text: String, attachments: [String] = [], to botID: UUID) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, turns[botID] == nil, let bot = bot(botID) else { return }

        append(.user(text: prompt, attachments: attachments), to: botID)
        drafts[botID] = ""
        statusLine[botID] = "Pensando"
        pokes[botID, default: 0] += 1
        flash(\.listening, botID, seconds: 1.4)

        turns[botID] = Task {
            for await event in gateway.runTurn(bot: bot, prompt: prompt) {
                apply(event, to: botID)
            }
            finishTurn(botID)
        }
    }

    func stop(_ botID: UUID) {
        guard let task = turns[botID] else { return }
        task.cancel()
        Task { await gateway.cancelPendingApprovals() }
        append(.notice("Você interrompeu esta resposta"), to: botID)
        finishTurn(botID)
        celebrating.remove(botID)
        flash(\.failed, botID, seconds: 2.5)
    }

    func decide(_ decision: ApprovalDecision, approvalID: UUID, botID: UUID) {
        mutateItems(of: botID) { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = decision
                    items[index].kind = .approval(request)
                }
            }
        }
        if decision == .always {
            update(botID) { $0.permissionMode = .auto }
        }
        Task { await gateway.resolve(approvalID: approvalID, decision: decision) }
    }

    private func apply(_ event: TurnEvent, to botID: UUID) {
        switch event {
        case .status(let text):
            statusLine[botID] = text
        case .text(let delta):
            mutateItems(of: botID) { items in
                if let last = items.indices.last, case .bot(let text, true) = items[last].kind {
                    items[last].kind = .bot(text: text + delta, isStreaming: true)
                } else {
                    items.append(TranscriptItem(.bot(text: delta.trimmingCharacters(in: .newlines), isStreaming: true)))
                }
            }
        case .toolStarted(let call):
            closeStreaming(botID)
            append(.tool(call), to: botID)
        case .toolFinished(let id, let state, let output):
            mutateItems(of: botID) { items in
                for index in items.indices {
                    if case .tool(var call) = items[index].kind, call.id == id {
                        call.state = state
                        call.output = output
                        call.finishedAt = .now
                        items[index].kind = .tool(call)
                    }
                }
            }
        case .approval(let request):
            closeStreaming(botID)
            append(.approval(request), to: botID)
        case .finished:
            break
        }
    }

    private func finishTurn(_ botID: UUID) {
        guard turns[botID] != nil else { return }
        turns[botID] = nil
        closeStreaming(botID)
        statusLine[botID] = nil
        flash(\.celebrating, botID, seconds: 3)
        if selection != .bot(botID) {
            update(botID) { $0.unread += 1 }
        }
    }

    /// Puts the bot in a transient state set for a few seconds.
    private func flash(_ keyPath: ReferenceWritableKeyPath<AppModel, Set<UUID>>, _ botID: UUID, seconds: Double) {
        self[keyPath: keyPath].insert(botID)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self[keyPath: keyPath].remove(botID)
        }
    }

    private func closeStreaming(_ botID: UUID) {
        mutateItems(of: botID) { items in
            if let last = items.indices.last, case .bot(let text, true) = items[last].kind {
                items[last].kind = .bot(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isStreaming: false)
            }
        }
    }

    private func append(_ kind: TranscriptItem.Kind, to botID: UUID) {
        mutateItems(of: botID) { $0.append(TranscriptItem(kind)) }
    }

    private func mutateItems(of botID: UUID, _ change: (inout [TranscriptItem]) -> Void) {
        change(&transcripts[botID, default: []])
        scrollTick[botID, default: 0] += 1
    }
}
