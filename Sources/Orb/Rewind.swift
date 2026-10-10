import Foundation

// Going back in a conversation: "Refazer" (the Orb's last reply is discarded and the same request runs again) and
// "Editar" (a message of yours is replaced by another version, and everything after it leaves the conversation).
// Both cut the transcript and the model's history at one point and then send a message as if the cut were the end of the
// conversation. This file is the pure part: where the cut goes, what it drops, what has to be forgotten with it, and why
// it is sometimes refused. `AppModel+Rewind` does the rest (the checks of the moment, the composer, the send).

/// Where a conversation is cut: the first item and the first model message that go. The two lists are not parallel
/// (notices, greetings and tool lines are screen only; a request that failed before it reached the model has no
/// message), so each has its own index.
struct RewindCut: Equatable, Sendable {
    var itemIndex: Int
    var messageIndex: Int
}

/// Why "Refazer" or "Editar" is not offered (or not possible) right now.
enum RewindRefusal: Equatable, Sendable {
    /// The Orb works, is loading, or another change of the chat is under way.
    case busy
    /// A permission card is waiting for an answer.
    case approvalPending
    /// A routine holds the Orb.
    case routine
    /// A picture of the composer is still being prepared.
    case preparingPictures
    /// The message is part of what the conversation's summary stands for: the model no longer has it.
    case summarized
    /// The message reached the Orb in the middle of a task: the request that began the task is the one to edit.
    case steered
    /// "Refazer": there is no reply of the Orb at the end of the chat.
    case noReply
    /// "Refazer": messages were sent during the task, which a new run would not have.
    case steeredTurn
    /// The message is not in the conversation (any more).
    case missing

    /// The hover text of a button that is shown but cannot be used; for the ones that hide the button, the reason is
    /// only for the tests and for whoever reads the code.
    var reason: String {
        switch self {
        case .busy: "O Orb está ocupado"
        case .approvalPending: "Responda ao pedido de permissão primeiro"
        case .routine: "Uma rotina está rodando"
        case .preparingPictures: "Espere a imagem terminar de ser preparada"
        case .summarized: "Esta mensagem já virou parte do resumo da conversa; só as mais recentes podem ser editadas"
        case .steered: "Esta mensagem entrou no meio de uma tarefa; edite o pedido que a começou"
        case .noReply: "Não há resposta para refazer"
        case .steeredTurn: "Você mandou mensagens no meio desta tarefa; edite o pedido para refazê-la"
        case .missing: "Esta mensagem não está mais na conversa"
        }
    }

    /// The button is not shown at all (it is a matter of the moment, not of the message).
    var hidesButton: Bool {
        switch self {
        case .busy, .approvalPending, .routine, .preparingPictures, .noReply, .missing: true
        case .summarized, .steered, .steeredTurn: false
        }
    }
}

/// The words around the confirmation that comes before a cut drops tool actions.
enum RewindWords {
    static let editMessage = "Os passos depois desta mensagem saem da conversa; o que o Orb já fez no Mac não é desfeito."
    static let redoMessage = "Os passos desta resposta saem da conversa e o Orb faz o pedido de novo; o que ele já fez no Mac não é desfeito."
    static let editTitle = "Editar esta mensagem?"
    static let redoTitle = "Refazer a resposta?"
    static let editConfirm = "Editar e enviar"
    static let redoConfirm = "Refazer"
    static let banner = "Editando mensagem · Esc cancela"
}

extension ToolCall {
    /// Whether this action may have changed something outside the conversation (a file written, a command that is not
    /// a plain look, an app operated, a task scheduled, a download). The test is on the words the app itself wrote for the
    /// call, and errs toward "yes": it only decides whether a confirmation is worth asking.
    var mayHaveChangedThings: Bool {
        if let files, !files.isEmpty { return true }
        let starts: ([String]) -> Bool = { prefixes in prefixes.contains { title.hasPrefix($0) } }
        switch kind {
        case .shell:
            // The command as typed (the card may add "em <pasta>" after it).
            let command = detail.components(separatedBy: "\n\nem ").first ?? detail
            let line = ShellCommandLine.parse(command)
            return !ReadOnlyCommand.isReadOnly(line, directory: FileManager.default.homeDirectoryForCurrentUser)
        case .file:
            return starts(["Gravando", "Editando", "Apagando", "Movendo", "Criando", "Copiando", "Renomeando"])
        case .computer:
            return !starts(["Lendo", "Capturando", "Listando", "Vendo", "Focando"])
        case .browser:
            return starts(["Baixando"])
        case .schedule:
            return starts(["Agendando", "Apagando"])
        case .search, .memory, .connector:
            return false // a connector's calls count through the cards that were answered (see `Conversation.dropsChanges`)
        }
    }
}

extension Conversation {
    // MARK: Which message is which

    /// For each of your messages in the transcript (by item index), the index in `messages` of the request it became. A
    /// message that never reached the model (the turn failed first) has no entry.
    ///
    /// Both lists only grow, in step, so when they count the same number of requests the n-th message is the n-th request.
    /// When they do not (a request failed before it was recorded), the requests are matched to the messages by what
    /// was typed, in order.
    func requestMessageIndices(skills: [Skill]) -> [Int: Int] {
        let typed: [(item: Int, text: String, attachments: [String])] = items.indices.compactMap { index in
            if case .user(let text, let attachments) = items[index].kind { (index, text, attachments) } else { nil }
        }
        let requests = messages.indices.filter { messages[$0].role == .user && !messages[$0].content.hasPrefix(ContextSummary.marker) }
        var found: [Int: Int] = [:]
        if typed.count == requests.count {
            for (message, request) in zip(typed, requests) { found[message.item] = request }
            return found
        }
        var next = 0
        for message in typed {
            guard let hit = requests[next...].firstIndex(where: {
                Self.isRequest(self.messages[$0], from: message.text, attachments: message.attachments, skills: skills)
            }) else { continue }
            found[message.item] = requests[hit]
            next = hit + 1
        }
        return found
    }

    /// Whether the model message is what the transcript's message produced: it holds the typed words (or the skill they
    /// expanded to), or, for a message that was only attachments, their paths or the line the app writes for them.
    static func isRequest(_ message: ChatMessage, from text: String, attachments: [String], skills: [Skill]) -> Bool {
        guard message.role == .user else { return false }
        if !text.isEmpty { return RetryPlan.isMessage(message, from: text, skills: skills) }
        if attachments.isEmpty { return true }
        return message.content.contains(AppModel.attachmentsOnlyPrompt)
            || attachments.contains { path in message.content.contains(path) || message.images.contains { $0.path == path } }
    }

    // MARK: Where to cut

    /// The cut that makes your message at `itemIndex` the end of the conversation (the message goes too). nil when
    /// that item is not one of your messages.
    func rewindCut(atItem itemIndex: Int, skills: [Skill]) -> RewindCut? {
        guard items.indices.contains(itemIndex), case .user = items[itemIndex].kind else { return nil }
        let indices = requestMessageIndices(skills: skills)
        // A message that never reached the model has nothing of its own to drop: the cut is where the next one
        // that did begins (or the end), so the replies of earlier turns stay whole.
        let first = items.indices.lazy.filter { $0 >= itemIndex }.compactMap { indices[$0] }.first
        return RewindCut(itemIndex: itemIndex, messageIndex: first ?? messages.count)
    }

    /// Whether the summary of the conversation stands for what the cut would keep only in part: the model has no
    /// message there any more to cut at, so the cut would be a guess.
    func isSummarized(_ cut: RewindCut) -> Bool { cut.messageIndex < coveredMessageCount }

    /// The user's message the last reply belongs to: the last one that opened a turn (not one sent in the middle of a
    /// task), with the cut that goes back to it. nil when the chat does not end with a reply.
    func lastTurnStart(skills: [Skill]) -> (cut: RewindCut, hasSteeredMessages: Bool)? {
        guard let reply = items.lastIndex(where: { if case .bot = $0.kind { true } else { false } }),
              let request = items.indices.last(where: {
                  if case .user = items[$0].kind { items[$0].duringTask != true } else { false }
              }), request < reply,
              !items[(request + 1)...].contains(where: { if case .user = $0.kind { $0.duringTask != true } else { false } }),
              let cut = rewindCut(atItem: request, skills: skills) else { return nil }
        let steered = items[(request + 1)...].contains { if case .user = $0.kind { true } else { false } }
        return (cut, steered)
    }

    // MARK: What the cut drops

    /// Whether what leaves with the cut includes actions that may have changed something outside the conversation. For
    /// connectors, whose calls cannot be told apart by their words, a permission card answered with "yes" counts.
    func dropsChanges(from itemIndex: Int) -> Bool {
        guard items.indices.contains(itemIndex) else { return false }
        var allowedConnector = false, connector = false
        for item in items[itemIndex...] {
            switch item.kind {
            case .tool(let call):
                if call.mayHaveChangedThings { return true }
                if call.kind == .connector { connector = true }
            case .approval(let request):
                if let decision = request.decision, decision != .deny { allowedConnector = true }
            default:
                break
            }
        }
        return connector && allowedConnector
    }

    // MARK: Cutting

    /// Takes the conversation back to the cut: the transcript and the model's history end there, and whatever was
    /// derived from the part that goes is forgotten with it, so nothing refers to what is no longer there.
    mutating func rewind(to cut: RewindCut) {
        items.removeSubrange(min(cut.itemIndex, items.count)...)
        messages.removeSubrange(min(cut.messageIndex, messages.count)...)
        // Whether the last task paused is read from the history that is left.
        taskPaused = nil
        memorySavedCount = memorySavedCount.map { min($0, items.count) }
        condensedCount = condensedCount.map { min($0, messages.count) }
        // A note on a stretch that is gone would fit the messages that take its place.
        chunkSummaries = chunkSummaries?.filter { $0.end <= messages.count }
        // The snapshot of the folder may have been in a message that left: it is sent again with the next one.
        workspaceHash = nil
        workspaceSeen = nil
        if claudeSessionID != nil {
            resetClaudeSession()
        } else {
            claudeSeenCount = claudeSeenCount.map { min($0, messages.count) }
        }
    }

    /// Claude Code keeps its own copy of the conversation, which has the discarded turns: the next message starts a new
    /// session, told what is left of the conversation (as after "Compactar agora").
    mutating func resetClaudeSession() {
        claudeSessionReported("", folder: nil)
        claudeMemoryPinned = nil
        claudeWorkspaceHash = nil
        claudeStandingHash = nil
        claudeWorkspaceSeen = nil
        claudeSystem = nil
    }
}

/// Which rows of the chat carry the rewind buttons (the buttons themselves decide, when hovered, whether they can be used).
enum RewindRows {
    /// The Orb's reply that "Refazer" belongs to: the last one of the chat, when the Orb is idle, it is finished, and
    /// nothing of yours came after it.
    static func redoTarget(in items: [TranscriptItem], isWorking: Bool) -> UUID? {
        guard !isWorking else { return nil }
        for item in items.reversed() {
            switch item.kind {
            case .user: return nil
            case .bot(_, let isStreaming): return isStreaming ? nil : item.id
            default: continue
            }
        }
        return nil
    }
}
