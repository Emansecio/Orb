import Foundation

/// The four ways an Orb is allowed to act. `allCases` is THE order in which every picker lists them (the Orb's panel,
/// the new-Orb sheet and the composer): the safest first, "Sem pedir permissão" last.
enum PermissionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ask, auto, readOnly, bypass

    var id: String { rawValue }

    /// A mode from a newer version falls back to the most cautious one.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .ask) }

    var label: String {
        switch self {
        case .ask: "Perguntar antes"
        case .auto: "Automático"
        case .readOnly: "Só leitura"
        case .bypass: "Sem pedir permissão"
        }
    }

    /// One line under the mode's name (the composer's picker, its tooltip).
    var shortSummary: String {
        switch self {
        case .ask: "Pede sua aprovação antes de mudar arquivos, rodar comandos ou usar a web."
        case .auto: "Trabalha sozinho e só pergunta antes do que reconhece como destrutivo (apagar, sudo, push --force). Não protege contra instruções escondidas no que o Orb lê."
        case .readOnly: "Só lê e pesquisa. Não muda nada no seu Mac."
        case .bypass: "Nunca pergunta, nem em ações destrutivas."
        }
    }

    /// What the mode does in full (the Orb's panel, the new-Orb sheet, a routine's explanation, the confirmation of
    /// "Sem pedir permissão"): always `shortSummary` first, then what it leaves out.
    var summary: String { shortSummary + " " + detail }

    private var detail: String {
        switch self {
        case .ask: "Ler e procurar em arquivos não pergunta (chaves e senhas são exceção)."
        case .auto: "Ler senhas e chaves, ou mudar a identidade ou as preferências do Orb, também pergunta."
        case .readOnly: "Para o Orb agir, troque de modo."
        case .bypass: "Roda qualquer comando e altera qualquer arquivo sem confirmação. Use só com Orbs e pastas em que você confia."
        }
    }

    /// Under "Liberações" (the Orb's panel and the composer's popover): the standing grants only count where the Orb
    /// asks, and risky actions ask everywhere except in "Sem pedir permissão".
    static let grantsNote = "Estas liberações valem em “\(PermissionMode.ask.label)”. "
        + "Comandos arriscados sempre perguntam (em “\(PermissionMode.readOnly.label)” são recusados), "
        + "exceto em “\(PermissionMode.bypass.label)”."

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

    /// The name of the switch in the Orb's panel ("O que <Orb> pode usar"), and the only one: the panel, the empty chat
    /// and every prompt that tells the user which switch to turn on read it from here.
    var label: String {
        switch self {
        case .terminal: "Terminal e arquivos"
        case .browser: "Navegar na web"
        case .computerUse: "Controlar apps do Mac"
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
    /// How hard the model thinks ("Esforço", a level as the provider names it, see `ReasoningEffort`); empty is the model's default.
    var effort = ""
    var permissionMode = PermissionMode.ask
    var capabilities: Set<Capability> = [.terminal, .browser, .computerUse]
    /// How the browser behind "Navegar na web" runs (see `BrowserMode`). Orbs saved before the modes existed (when the Orb chose an
    /// engine: Chrome, CloakBrowser, Obscura or only reading) get the background; the old `browserEngine` key is not read.
    var browserMode = BrowserMode.default
    /// The proxy the Orb's browser goes through (`scheme://[user@]host:port`), chosen by the Orb with `browse_proxy`; nil is direct.
    /// Never the password: that is in the Keychain (`BrowserProxy.keychainAccount`, see `AppModel.saveBrowserProxy`).
    var browserProxy: String?
    /// Where `web_search` goes.
    var searchProvider = SearchProvider.duckduckgo
    /// What the user chose "Sempre permitir" for, each grant narrowed by a scope (`PermissionRule`). Grants saved
    /// before scopes existed (`allowedTools`, tool names of either engine) are converted when the Orb loads.
    var permissionRules: [PermissionRule] = []
    /// Where commands run and relative paths resolve; empty means the home folder.
    var workingDirectory = ""
    /// Hash (see `FolderInstructions.hash`) of the folder's instruction file the user chose to trust. While the file
    /// still has this hash its text is given to the Orb as instructions; when it changes it is reference material
    /// again until the user trusts it anew.
    var trustedInstructionsHash: String?
    /// Memory list of versions before each Orb had its own memory bank; moved into the bank at launch.
    var memory: [MemoryFact] = []
    /// The Orb that created this one (`orb_propose`), and the name it had then; nil for an Orb the person made.
    var createdBy: UUID?
    var createdByName: String?
    var createdAt: Date?

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
        effort = try c.value(.effort, default: "")
        permissionMode = try c.value(.permissionMode, default: .ask)
        capabilities = Set(try c.lossyArray(.capabilities, default: [.terminal, .browser]))
        browserMode = (try? c.decodeIfPresent(BrowserMode.self, forKey: .browserMode)) ?? .default
        browserProxy = (try? c.decodeIfPresent(String.self, forKey: .browserProxy)).flatMap { $0 }
        searchProvider = (try? c.decodeIfPresent(SearchProvider.self, forKey: .searchProvider)) ?? .duckduckgo
        permissionRules = try c.lossyArray(.permissionRules)
        if let old = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([String].self, forKey: .allowedTools) {
            permissionRules = PermissionPolicy.unique(permissionRules + PermissionPolicy.legacyRules(fromToolNames: old))
        }
        workingDirectory = try c.value(.workingDirectory, default: "")
        trustedInstructionsHash = try c.decodeIfPresent(String.self, forKey: .trustedInstructionsHash)
        memory = try c.value(.memory, default: [])
        // Where the Orb came from is only a note: whatever cannot be read leaves the Orb as the person's own.
        createdBy = (try? c.decodeIfPresent(UUID.self, forKey: .createdBy)) ?? nil
        createdByName = (try? c.decodeIfPresent(String.self, forKey: .createdByName)) ?? nil
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
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
        /// What a new Orb says first, written by the app (`OrbGreeting`). Like a notice it is only for the screen: it is
        /// never one of the conversation's `messages`, so the model does not see it and nothing counts it.
        case greeting(String)
        /// Something that happened between Orbs or to them (an Orb created, a group joined…), written by the app.
        case event(OrbEvent)
        /// A message between Orbs: a request sent or received, a reply, a post in a group's thread.
        case orbMessage(OrbMessageItem)
        /// A group reached its budget and waits for the person to continue or end the request.
        case groupPause(GroupPauseItem)
    }

    var id = UUID()
    var kind: Kind
    var date = Date.now
    /// A message of the user's that reached the model in the middle of its task (steered, not sent as a request of its
    /// own): the chat marks it. nil for every other item and for conversations from before the mark existed.
    var duringTask: Bool?

    init(_ kind: Kind, duringTask: Bool = false) {
        self.kind = kind
        self.duringTask = duringTask ? true : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        kind = try c.decode(Kind.self, forKey: .kind)
        if case .notice(let text) = kind, let run = OrbEvent(routineNotice: text) { kind = .event(run) }
        date = try c.value(.date, default: Date.now)
        duringTask = try? c.decodeIfPresent(Bool.self, forKey: .duringTask) // a mark that cannot be read is no loss
    }
}

/// A bot's current conversation: what the UI shows and what the model sees.
struct Conversation: Codable, Sendable {
    var items: [TranscriptItem] = []
    var messages: [ChatMessage] = []
    /// How many of `items` are already saved in the Orb's memory as session pages.
    var memorySavedCount: Int?
    /// Summary standing in for the first `summaryCoveredCount` of `messages`, which no longer fit the model's
    /// window (see `ContextWindow`). The messages themselves stay.
    var summary: String?
    var summaryCoveredCount: Int?
    /// The data `summary` is rendered from (see `ConversationLedger`); a summary saved without one is carried as text.
    var ledger: ConversationLedger?
    /// How many times this conversation has been compacted (automatically or on request).
    var compactions: Int?
    /// What the model wrote about stretches of the conversation that were about to be folded (see `ChunkSummary`);
    /// the summary carries the ones that were folded. Only helps the summary: a note that cannot be read is no loss.
    var chunkSummaries: [ChunkSummary]?
    /// Messages before this index are sent to the model condensed (old prefaces, outputs and reasoning cut down; the
    /// messages themselves stay whole). It moves in batches (see `ContextCondensing`).
    var condensedCount: Int?
    /// Whether the last task stopped at the step limit and nothing was said since (set by the engine, cleared by the
    /// next user message). nil = recorded before this was tracked: then the record's marker in the last message decides.
    var taskPaused: Bool?
    /// When the model last answered in this conversation (the provider's cache is cold some minutes after it).
    var lastModelCall: Date?
    /// Hash of the workspace snapshot the model last got in this conversation (it is sent again only when it changes).
    var workspaceHash: String?
    /// Id this conversation sends gateways that key routing and prompt caching to a session (OpenCode's
    /// `x-opencode-session`). Born with the conversation, so a cleared chat or a routine run gets a new one.
    var gatewaySessionID: String?
    /// The snapshot behind `workspaceHash` (without its recent files), so a later message can say only what changed in the
    /// folder instead of sending the whole snapshot again. Nil in conversations from before it was kept.
    var workspaceSeen: WorkspaceSnapshot?
    /// The memory (`MemoryBrief.stable`) this conversation's system prompt carries: kept as it was so the provider's
    /// prompt cache lasts, while a change reaches the model in a message's preface (`TurnPreface.memoryUpdate`).
    var memoryInPrompt: String?
    /// The plan of the task in progress (`task_plan`), as the calls in `messages` left it: kept beside them so it does not
    /// depend on what the summary says, and worked out from them again when "Refazer" cuts some of them away.
    var taskPlan: TaskPlan?
    /// A turn was running when this was saved (set when it begins, cleared when it ends): read back after a crash, the
    /// chat says the turn was cut off even when the disk caught it at a quiet moment (nothing streaming or running).
    var turnOpen: Bool?

    /// After a quit or crash mid-turn: nothing is streaming, running or waiting anymore. `notice` goes at the end when a turn
    /// was cut off there (something was still going, or your message got no answer), so the chat says what happened.
    func closingInterruptedTurn(notice: String? = nil) -> Conversation {
        var copy = self
        var cutOff = if case .user = items.last?.kind { true } else { turnOpen == true }
        copy.turnOpen = nil
        for index in copy.items.indices {
            let before = copy.items[index].kind
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
            case .orbMessage(var message) where message.direction == .sent && message.state == .open:
                // Requests in flight do not survive the app closing (nobody is working on them anymore).
                message.state = .lost
                copy.items[index].kind = .orbMessage(message)
            case .groupPause(var pause) where pause.state == .open:
                pause.state = .ended
                copy.items[index].kind = .groupPause(pause)
            default:
                break
            }
            if copy.items[index].kind != before { cutOff = true }
        }
        if cutOff, let notice { copy.items.append(TranscriptItem(.notice(notice))) }
        return copy
    }
}

extension Conversation {
    mutating func record(_ marks: DeliveryMarks) { marks.record(in: &self) }

    /// Tolerant decoding: an item or message this version can't read (an unknown case after a downgrade) is
    /// skipped instead of sending the whole conversation to `.corrupt`, and the counts that point into the lists move
    /// back past it. A tool result whose call was skipped goes too: the provider refuses a result without its call.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedItems: [TranscriptItem?] = try c.lossyOptionals(.items)
        var storedMessages: [ChatMessage?] = try c.lossyOptionals(.messages)
        if storedMessages.contains(where: { $0 == nil }) {
            var calls: Set<String> = []
            for index in storedMessages.indices {
                guard let stored = storedMessages[index] else { continue }
                if stored.role == .assistant { calls.formUnion(stored.toolCalls.map(\.id)) }
                if stored.role == .tool, !calls.contains(stored.toolCallID ?? "") { storedMessages[index] = nil }
            }
        }
        items = storedItems.compactMap { $0 }
        messages = storedMessages.compactMap { $0 }
        let item = Self.kept(storedItems), message = Self.kept(storedMessages)
        memorySavedCount = try c.decodeIfPresent(Int.self, forKey: .memorySavedCount).map(item)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryCoveredCount = try c.decodeIfPresent(Int.self, forKey: .summaryCoveredCount).map(message)
        // A ledger this version cannot read is dropped (the summary text still stands) instead of losing the conversation.
        ledger = (try? c.decodeIfPresent(ConversationLedger.self, forKey: .ledger)) ?? nil
        compactions = (try? c.decodeIfPresent(Int.self, forKey: .compactions)) ?? nil
        chunkSummaries = ((try? c.decodeIfPresent([ChunkSummary].self, forKey: .chunkSummaries)) ?? nil)?.compactMap { note in
            let start = message(note.start), end = message(note.end)
            return start < end ? ChunkSummary(start: start, end: end, text: note.text) : nil
        }
        condensedCount = try c.decodeIfPresent(Int.self, forKey: .condensedCount).map(message)
        taskPaused = try c.decodeIfPresent(Bool.self, forKey: .taskPaused)
        lastModelCall = (try? c.decodeIfPresent(Date.self, forKey: .lastModelCall)) ?? nil
        workspaceHash = try c.decodeIfPresent(String.self, forKey: .workspaceHash)
        gatewaySessionID = try c.decodeIfPresent(String.self, forKey: .gatewaySessionID)
        // Only helps to save tokens: whatever cannot be read here is sent whole next time instead of failing the conversation.
        workspaceSeen = (try? c.decodeIfPresent(WorkspaceSnapshot.self, forKey: .workspaceSeen)) ?? nil
        memoryInPrompt = (try? c.decodeIfPresent(String.self, forKey: .memoryInPrompt)) ?? nil
        // A plan this version cannot read is dropped; the calls that made it are still in `messages`.
        taskPlan = (try? c.decodeIfPresent(TaskPlan.self, forKey: .taskPlan)) ?? nil
        turnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .turnOpen)) ?? nil
    }

    /// Where a position in the stored list lands once the elements that could not be read (nil) are left out.
    private static func kept<T>(_ stored: [T?]) -> (Int) -> Int {
        let lost = stored.indices.filter { stored[$0] == nil }
        return { position in position - lost.prefix { $0 < position }.count }
    }
}

struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case shell, browser, file, search, computer, connector, memory, schedule
        /// The tools that reach other Orbs (`orbs`, `orb_propose`, `orb_draft`).
        case orbs
        /// `task_plan`: the plan of the task, which only the conversation keeps.
        case plan

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
            case .schedule: "clock.arrow.circlepath"
            case .orbs: "bubble.left.and.bubble.right"
            case .plan: "checklist"
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
    /// Files the tool created or changed, shown under its line (nil: none, which is what older conversations have).
    var files: [ProducedFile]?

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
        // Only a convenience: whatever cannot be read leaves the line without cards instead of failing the conversation.
        files = (try? c.decodeIfPresent([ProducedFile].self, forKey: .files)) ?? nil
    }
}

enum ApprovalDecision: String, Codable, Sendable, Equatable {
    /// `task`: allowed until this turn ends. `always`: allowed from now on, by the rule chosen on the card.
    /// `review`: only on a card that groups several actions: "Revisar uma a uma" hands each one its own card.
    case deny, once, always, task, review

    /// A decision from a newer version counts as a refusal.
    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .deny) }

    var label: String {
        switch self {
        case .deny: "Negado"
        case .once: "Permitido uma vez"
        case .task: "Permitido nesta tarefa"
        case .always: "Sempre permitido"
        case .review: "Revisão uma a uma"
        }
    }
}

/// One action on a card that groups several (`ApprovalRequest.items`).
struct ApprovalItem: Codable, Sendable, Equatable, Hashable {
    var toolName: String
    var title: String
    var command: String
}

extension ApprovalItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.value(.toolName, default: "")
        title = try c.value(.title, default: "")
        command = try c.value(.command, default: "")
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
    /// The actions behind a card that groups several (two or more); empty for a card about one action.
    var items: [ApprovalItem] = []
    /// A destructive action: its notification asks for the Mac to be unlocked before "Permitir" works.
    var isDangerous = false
    /// What the user told the Orb to do instead when denying.
    var note: String?
    /// Not a permission: the Orb opened its browser in a window for something only the person can do (`browse_show`) and waits
    /// for "Pronto" (`.once`) or "Cancelar" (`.deny`). It has no rules to grant, never groups, and a change of permission
    /// mode does not answer it.
    var isHandoff = false
    /// An Orb proposes a new Orb (`orb_propose`): the card shows it and asks Criar / Editar antes / Não criar. Like a hand-off
    /// it is not a permission: it has no rules to grant, never groups, and a change of permission mode does not answer it.
    var proposal: OrbProposal?
    /// The Orb asks the person something (`ask_user`) and waits for the answer. Like a hand-off it is not a permission: it has no
    /// rules to grant, never groups, and a change of permission mode does not answer it.
    var question: OrbQuestion?

    var isBatch: Bool { items.count > 1 }
    var isProposal: Bool { proposal != nil }
    var isQuestion: Bool { question != nil }

    /// The card `browse_show` opens. `page` is the address (and title) of the page left open in the window.
    static func handoff(botName: String, page: String) -> ApprovalRequest {
        ApprovalRequest(toolName: "browse_show", title: "\(botName) abriu o navegador para você", command: page,
                        reason: "Termine lá o que falta (entrar no site, digitar um código, resolver a verificação) e clique em Pronto.",
                        isHandoff: true)
    }

    /// The card of `ask_user`.
    static func question(_ question: OrbQuestion, botName: String) -> ApprovalRequest {
        ApprovalRequest(toolName: AskUserTool.name, title: "\(botName) pergunta", command: question.text, reason: "", question: question)
    }
}

/// A question an Orb asks the person (`ask_user`): what it wants to know, the answers it offers to pick from (none: the
/// person writes one), and the answer given.
struct OrbQuestion: Codable, Sendable, Equatable {
    static let textLimit = 600
    static let optionLimit = 6
    static let optionLength = 120
    static let answerLimit = 2_000

    var text: String
    var options: [String] = []
    /// What the person answered: one of `options` or their own words. nil while open, and when they skipped it.
    var answer: String?

    /// Trimmed and cut to the limits; repeated or empty options are dropped.
    init(text: String, options: [String] = []) {
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.textLimit))
        var kept: [String] = []
        for option in options where kept.count < Self.optionLimit {
            let clean = String(option.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.optionLength))
            if !clean.isEmpty, !kept.contains(clean) { kept.append(clean) }
        }
        self.options = kept
    }

    /// An answer as it is kept and sent: trimmed and capped; nil when nothing is left.
    static func clean(_ answer: String?) -> String? {
        guard let text = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(answerLimit))
    }
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
        items = try c.lossyArray(.items)
        isDangerous = try c.value(.isDangerous, default: false)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isHandoff = try c.value(.isHandoff, default: false)
        // Only the card's contents: a proposal this version cannot read leaves a plain card the person can still answer.
        proposal = (try? c.decodeIfPresent(OrbProposal.self, forKey: .proposal)) ?? nil
        question = (try? c.decodeIfPresent(OrbQuestion.self, forKey: .question)) ?? nil
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
    /// Permission mode for this routine's runs; nil means the Orb's own. Nobody is there to answer cards during a
    /// run, so "Automático" or "Só leitura" usually fits better than "Perguntar antes".
    var permissionMode: PermissionMode?
    /// The most recent runs, newest first (`Routine.keptRuns` of them).
    var runs: [RoutineRun] = []
    /// What the routine works toward, checked on each run; nil for a plain routine.
    var goal: RoutineGoal?

    static let keptRuns = 10

    var nextRun: Date { schedule.next(after: lastRun ?? createdAt) }

    /// Turning a routine back on counts from now: its old `lastRun` would make it due right away.
    mutating func setEnabled(_ enabled: Bool, now: Date = .now) {
        if enabled && !isEnabled { lastRun = now }
        isEnabled = enabled
    }

    /// Whether turning it on would leave it a next run. A routine for one moment that has already passed would not: it would
    /// show as on and never run (its date has to change first).
    func canBeEnabled(now: Date = .now) -> Bool {
        guard !isEnabled else { return true }
        var switched = self
        switched.setEnabled(true, now: now)
        return switched.nextRun != .distantFuture
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
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        runs = try c.lossyArray(.runs)
        // A goal this version cannot read leaves a plain routine, never a routine that does not load.
        goal = (try? c.decodeIfPresent(RoutineGoal.self, forKey: .goal)) ?? nil
    }
}

/// What one run of a routine left behind: shown in the routine's history. The whole run is in the routine's
/// own conversation.
struct RoutineRun: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var date: Date
    var finishedAt: Date?
    var succeeded: Bool
    /// First line of the report (or why the run did not happen or finish).
    var summary: String
    /// The final report, shortened; the next run is told what the last one found.
    var report: String?
    /// Where the report was saved inside the Orb's folder (only Orbs with a folder of their own get one).
    var reportFile: String?
    /// The goal's check this run reported, for a routine with a goal: the history is the goal's timeline.
    var check: GoalCheck?
}

extension RoutineRun {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        date = try c.value(.date, default: Date.now)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        succeeded = try c.value(.succeeded, default: false)
        summary = try c.value(.summary, default: "")
        report = try c.decodeIfPresent(String.self, forKey: .report)
        reportFile = try c.decodeIfPresent(String.self, forKey: .reportFile)
        check = (try? c.decodeIfPresent(GoalCheck.self, forKey: .check)) ?? nil
    }
}

enum Schedule: Codable, Hashable, Sendable {
    case daily(hour: Int, minute: Int)
    /// `weekday` uses Calendar numbering (1 = domingo).
    case weekly(weekday: Int, hour: Int, minute: Int)
    case everyHours(Int)
    case everyMinutes(Int)
    /// Runs once, at that moment; the routine switches itself off after the run.
    case once(Date)
    /// A cron line (`CronExpression`) read in `timeZone` (an identifier, "America/Sao_Paulo"), or in the Mac's own when nil.
    case cron(expression: String, timeZone: String?)

    /// What `everyMinutes` accepts: never under 15, or a task would keep the Orb (and the provider's bill) busy.
    static let minuteRange = 15...720

    func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily(let hour, let minute):
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
                ?? date.addingTimeInterval(24 * 3600) // out-of-range values from a hand-edited file: never "now"
        case .weekly(let weekday, let hour, let minute):
            calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                              matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 24 * 3600)
        case .everyHours(let hours):
            date.addingTimeInterval(Double(max(1, hours)) * 3600)
        case .everyMinutes(let minutes):
            date.addingTimeInterval(Double(Self.clampedMinutes(minutes)) * 60)
        case .once(let moment):
            moment > date ? moment : .distantFuture
        case .cron(let expression, let timeZone):
            // A line that does not parse (a hand-edited file) or never matches does not run, rather than run at a wrong time.
            (try? CronExpression(expression))?.next(after: date, calendar: Self.calendar(calendar, in: timeZone)) ?? .distantFuture
        }
    }

    /// Why this schedule cannot be saved as it is (a moment already past, a cron line that does not parse or never
    /// happens, a time zone this Mac does not know), or nil.
    func problem(now: Date = .now) -> String? {
        switch self {
        case .once(let moment):
            return moment > now ? nil : "Escolha uma data e hora no futuro."
        case .cron(let expression, let timeZone):
            if let timeZone, TimeZone(identifier: timeZone) == nil {
                return "Fuso desconhecido: “\(timeZone)”. Use um nome como America/Sao_Paulo."
            }
            do { _ = try CronExpression(expression) } catch {
                return (error as? CronExpression.Invalid)?.reason ?? "Expressão cron inválida."
            }
            return next(after: now) == .distantFuture ? "Essa expressão cron nunca acontece." : nil
        default:
            return nil
        }
    }

    /// `base` in `timeZone`, when it names one this Mac knows.
    static func calendar(_ base: Calendar, in timeZone: String?) -> Calendar {
        var calendar = base
        if let zone = timeZone.flatMap(TimeZone.init(identifier:)) { calendar.timeZone = zone }
        return calendar
    }

    var label: String {
        switch self {
        case .daily(let hour, let minute):
            "Todo dia às \(Self.time(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            "\([1, 7].contains(weekday) ? "Todo" : "Toda") \(Calendar.app.weekdaySymbols[((weekday - 1) % 7 + 7) % 7]) às \(Self.time(hour, minute))"
        case .everyHours(let hours):
            hours == 1 ? "A cada hora" : "A cada \(hours) horas"
        case .everyMinutes(let minutes):
            "A cada \(Self.clampedMinutes(minutes)) minutos"
        case .once(let moment):
            "Uma vez, \(Self.dayAndTime(moment))"
        case .cron(let expression, let timeZone):
            "Cron “\(expression)”" + (timeZone.map { " (fuso \($0))" } ?? "")
        }
    }

    /// "em 14/10/2026 às 09:00", on this Mac's clock.
    private static func dayAndTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        return String(format: "em %02d/%02d/%04d às ", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
            + time(parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A file edited by hand (or by a version with another limit) never makes a task run every minute.
    static func clampedMinutes(_ minutes: Int) -> Int { min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound) }

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
    /// The Orbs that may use this skill; nil means every Orb (what skills did before they were scoped).
    var orbIDs: Set<UUID>?
    /// The Orb that proposed it, for a skill with `learnedSource` (you approved it before it was saved).
    var learnedBy: UUID?
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
        orbIDs = (try? c.decodeIfPresent(Set<UUID>.self, forKey: .orbIDs)) ?? nil
        learnedBy = (try? c.decodeIfPresent(UUID.self, forKey: .learnedBy)) ?? nil
    }

    /// `source` of the skills that ship with the app (`legacyBuiltInSource` in files saved while it was OpenBot).
    static let builtInSource = "orb"
    static let legacyBuiltInSource = "openbot"
    /// `source` of the skills made by "Importar de outro assistente".
    static let importedSource = "importado"

    /// `source` of the skills an Orb proposed and you approved (`SkillProposal`).
    static let learnedSource = "aprendida"

    /// An Orb may propose a better version of it: written by you or learned, not shipped with the app or installed from the catalog.
    var isImprovable: Bool { source == nil || source == Self.learnedSource }

    /// A slug from free text: lowercase letters, digits and dashes.
    static func slugify(_ text: String) -> String {
        String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(32))
    }

    /// A finished slug: `slugify`, without leading, trailing or doubled dashes ("Resumir texto!" -> "resumir-texto").
    static func cleanSlug(_ text: String) -> String {
        slugify(text).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    /// What the shortcut field should read while the user types the name: it follows the name until they edit the
    /// shortcut themselves (`edited`); a shortcut already saved never changes on its own.
    static func suggestedSlug(forName name: String, current: String, edited: Bool) -> String {
        edited ? current : cleanSlug(name)
    }
}

enum SidebarItem: Hashable {
    case bot(UUID)
    case group(UUID)
    case routines
    case connectors
    case skills
}
