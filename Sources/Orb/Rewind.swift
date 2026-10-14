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
enum RewindRefusal: Error, Equatable, Sendable {
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
    /// The message cannot be paired with the model's history without guessing (a conversation from before the link was
    /// kept, with the same words sent more than once and a request that never reached the model).
    case unmatched

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
        case .unmatched: "Não consegui ligar esta mensagem ao histórico do Orb (a conversa é de uma versão antiga); só as mais recentes podem ser editadas"
        }
    }

    /// The button is not shown at all (it is a matter of the moment, not of the message).
    var hidesButton: Bool {
        switch self {
        case .busy, .approvalPending, .routine, .preparingPictures, .noReply, .missing: true
        case .summarized, .steered, .steeredTurn, .unmatched: false
        }
    }
}

/// The words around the confirmation that comes before a cut drops tool actions.
enum RewindWords {
    static let editMessage = "Os passos depois desta mensagem saem da conversa; o que o Orb já fez no Mac não é desfeito."
    static let redoMessage = "Os passos desta resposta saem da conversa e o Orb faz o pedido de novo; o que ele já fez no Mac não é desfeito."
    /// Added when part of what goes was already saved to the Orb's memory, which a cut does not touch.
    static let savedToMemory = " O que já foi para a memória do Orb continua lá."
    static func editMessage(savedToMemory saved: Bool) -> String { editMessage + (saved ? savedToMemory : "") }
    static func redoMessage(savedToMemory saved: Bool) -> String { redoMessage + (saved ? savedToMemory : "") }
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
        case .orbs:
            return starts(["Falando", "Avisando", "Propondo"]) // another Orb was asked to work, or an Orb was proposed
        case .search, .memory, .connector, .plan:
            return false // a connector's calls count through the cards that were answered (see `Conversation.dropsChanges`)
        }
    }
}

/// How the messages of the transcript pair up with the requests in the model's history.
struct RequestLinks: Equatable, Sendable {
    /// For each of your messages (by item index), the index in `messages` of the request it became.
    var message: [Int: Int] = [:]
    /// Messages that certainly never reached the model (the turn failed or was stopped first).
    var unpaired: Set<Int> = []
    /// Messages that cannot be told apart (an old conversation, the same words sent more than once, and a request among
    /// them that did not reach the model): nothing is cut by a guess.
    var unknown: Set<Int> = []
}

extension Conversation {
    // MARK: Which message is which

    /// For each of your messages in the transcript (by item index), the index in `messages` of the request it became. A
    /// message that never reached the model (the turn failed first), or whose pairing cannot be told, has no entry.
    func requestMessageIndices(skills: [Skill]) -> [Int: Int] { requestLinks(skills: skills).message }

    /// Pairs your messages with the model's requests. The link is recorded when the request reaches the model
    /// (`ChatMessage.itemID` holds the id of the bubble), so a message is found by it and by nothing else: the model's copy
    /// carries the preface (date, folder, memory notes) and the words typed can repeat. Only the part of a conversation
    /// from before the link existed is matched by the words, and only when that is not a guess.
    func requestLinks(skills: [Skill]) -> RequestLinks {
        var links = RequestLinks()
        var bubbles: [UUID: Int] = [:]
        var typed: [Int] = []
        for index in items.indices {
            guard case .user = items[index].kind else { continue }
            typed.append(index)
            bubbles[items[index].id] = bubbles[items[index].id] ?? index
        }
        var firstLinkedMessage: Int?
        for index in messages.indices where messages[index].role == .user {
            guard let id = messages[index].itemID, let item = bubbles[id], links.message[item] == nil else { continue }
            links.message[item] = index
            firstLinkedMessage = min(firstLinkedMessage ?? index, index)
        }
        let firstLinkedItem = links.message.keys.min()
        // From the first linked message on every request is linked: a message with no link there never reached the model.
        let older = typed.filter { links.message[$0] == nil && $0 < (firstLinkedItem ?? Int.max) }
        links.unpaired = Set(typed.filter { links.message[$0] == nil && !older.contains($0) })
        guard !older.isEmpty else { return links }

        // The older part, by the words: the requests that have no link and could be the ones typed.
        let requests = messages.indices.filter {
            messages[$0].role == .user && messages[$0].itemID == nil && !messages[$0].content.hasPrefix(ContextSummary.marker)
                && $0 < (firstLinkedMessage ?? Int.max)
        }
        // No request without a link before the first linked one: these messages never reached the model.
        if requests.isEmpty {
            links.unpaired.formUnion(older)
            return links
        }
        // Who could be whom. Messages typed alike have the same candidates: they are told apart only when there are as many
        // candidates as messages (then they go in order); otherwise the pairing is a guess.
        var groups: [[Int]: [Int]] = [:]
        for item in older {
            guard case .user(let text, let attachments) = items[item].kind else { continue }
            let candidates = requests.filter { Self.isRequest(messages[$0], from: text, attachments: attachments, skills: skills) }
            groups[candidates, default: []].append(item)
        }
        var claimed: [Int: Int] = [:] // request → how many groups want it
        for candidates in groups.keys { for request in candidates { claimed[request, default: 0] += 1 } }
        let lastTyped = typed.last
        for (candidates, group) in groups {
            if candidates.isEmpty {
                // Nothing in the history has these words. Only the last message of the chat is surely a failed one: for an
                // earlier one the cut would depend on the pairing of what comes after it.
                for item in group { if item == lastTyped { links.unpaired.insert(item) } else { links.unknown.insert(item) } }
            } else if candidates.count == group.count, candidates.allSatisfy({ claimed[$0] == 1 }) {
                for (item, request) in zip(group.sorted(), candidates) { links.message[item] = request }
            } else {
                links.unknown.formUnion(group)
            }
        }
        return links
    }

    /// Whether the model message is what the transcript's message produced: its words (what is left without the preface,
    /// the list of attachments and the instruction to remember) are exactly the typed ones (or the skill they expanded
    /// to), or, for a message that was only attachments, the line the app writes for them with their paths.
    static func isRequest(_ message: ChatMessage, from text: String, attachments: [String], skills: [Skill]) -> Bool {
        guard message.role == .user else { return false }
        let words = TurnPreface.requestWords(message.content)
        if !text.isEmpty { return RetryPlan.isMessage(message, from: text, skills: skills) }
        guard words.isEmpty || words == AppModel.attachmentsOnlyPrompt else { return false }
        return attachments.isEmpty
            || attachments.contains { path in message.content.contains(path) || message.images.contains { $0.path == path } }
    }

    // MARK: Where to cut

    /// The cut that makes your message at `itemIndex` the end of the conversation (the message goes too), or why there is
    /// none: that item is not one of your messages, or the model's history cannot be paired with it without guessing.
    func rewindPoint(atItem itemIndex: Int, skills: [Skill]) -> Result<RewindCut, RewindRefusal> {
        guard items.indices.contains(itemIndex), case .user = items[itemIndex].kind else { return .failure(.missing) }
        let links = requestLinks(skills: skills)
        // A message that never reached the model has nothing of its own to drop: the cut is where the next one
        // that did begins (or the end), so the replies of earlier turns stay whole.
        for index in items.indices where index >= itemIndex {
            if let request = links.message[index] { return .success(RewindCut(itemIndex: itemIndex, messageIndex: request)) }
            if links.unknown.contains(index) { return .failure(.unmatched) }
        }
        return .success(RewindCut(itemIndex: itemIndex, messageIndex: messages.count))
    }

    /// `rewindPoint` without the reason: nil when there is no cut.
    func rewindCut(atItem itemIndex: Int, skills: [Skill]) -> RewindCut? {
        try? rewindPoint(atItem: itemIndex, skills: skills).get()
    }

    /// Whether the summary of the conversation stands for what the cut would keep only in part: the model has no
    /// message there any more to cut at, so the cut would be a guess.
    func isSummarized(_ cut: RewindCut) -> Bool { cut.messageIndex < coveredMessageCount }

    /// The item of the user's message the last reply belongs to: the last one that opened a turn (not one sent in the
    /// middle of a task). nil when the chat does not end with a reply.
    func lastTurnRequestItem() -> Int? {
        guard let reply = items.lastIndex(where: { if case .bot = $0.kind { true } else { false } }),
              let request = items.indices.last(where: {
                  if case .user = items[$0].kind { items[$0].duringTask != true } else { false }
              }), request < reply,
              !items[(request + 1)...].contains(where: { if case .user = $0.kind { $0.duringTask != true } else { false } }) else { return nil }
        return request
    }

    /// The user's message the last reply belongs to, with the cut that goes back to it. nil when the chat does not end
    /// with a reply, or when that message cannot be paired with the model's history.
    func lastTurnStart(skills: [Skill]) -> (cut: RewindCut, hasSteeredMessages: Bool)? {
        guard let request = lastTurnRequestItem(), let cut = rewindCut(atItem: request, skills: skills) else { return nil }
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

    /// Whether something of what leaves with the cut was already saved to the Orb's memory (the session's page, or a note
    /// the Orb took with `remember`). The memory is not touched by a cut: it stays, and may come back as a related note.
    func dropsSavedMemory(from itemIndex: Int) -> Bool {
        guard items.indices.contains(itemIndex) else { return false }
        if (memorySavedCount ?? 0) > itemIndex { return true }
        return items[itemIndex...].contains { if case .tool(let call) = $0.kind { call.kind == .memory } else { false } }
    }

    // MARK: Cutting

    /// Takes the conversation back to the cut: the transcript and the model's history end there, and whatever was
    /// derived from the part that goes is forgotten with it, so nothing refers to what is no longer there.
    mutating func rewind(to cut: RewindCut) {
        items.removeSubrange(min(cut.itemIndex, items.count)...)
        let dropped = messages[min(cut.messageIndex, messages.count)...]
        // The plan goes back to what the calls that are left made of it: gone when it was made after the cut. The
        // messages are never deleted otherwise, so the replay finds every call that is left.
        if TaskPlan.isChanged(by: dropped) { taskPlan = TaskPlan.replay(Array(messages[..<dropped.startIndex])) }
        messages.removeSubrange(dropped.startIndex...)
        // Whether the last task paused is read from the history that is left.
        taskPaused = nil
        memorySavedCount = memorySavedCount.map { min($0, items.count) }
        condensedCount = condensedCount.map { min($0, messages.count) }
        // A note on a stretch that is gone would fit the messages that take its place.
        chunkSummaries = chunkSummaries?.filter { $0.end <= messages.count }
        // The snapshot of the folder may have been in a message that left: it is sent again with the next one.
        workspaceHash = nil
        workspaceSeen = nil
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
