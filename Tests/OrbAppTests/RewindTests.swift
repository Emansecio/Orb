import Foundation
import Testing
@testable import Orb

/// Answers every request with "Pronto." and keeps what it was sent, so the tests can see which history the model got.
private actor Received {
    private(set) var requests: [[ChatMessage]] = []
    func add(_ messages: [ChatMessage]) { requests.append(messages) }
}

private struct RecordingModel: LLMClient {
    let received: Received

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await received.add(messages)
                continuation.yield(.text("Pronto."))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

private func user(_ text: String, _ files: [String] = []) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: files)) }
private func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
private func notice(_ text: String) -> TranscriptItem { TranscriptItem(.notice(text)) }
private func tool(_ title: String, _ detail: String, kind: ToolCall.Kind = .shell) -> TranscriptItem {
    TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: .done)))
}

/// A conversation as the app records it: a greeting that is only on screen, then turns with their tool lines and
/// replies on the screen and their requests, answers and tool results in the model's history.
private func conversation(_ turns: [String], greeting: Bool = true) -> Conversation {
    var chat = Conversation()
    if greeting { chat.items.append(TranscriptItem(.greeting("Oi, eu sou o Orb."))) }
    for text in turns {
        chat.items += [user(text), bot("resposta a \(text)")]
        chat.messages += [.user(text), ChatMessage(role: .assistant, content: "resposta a \(text)")]
    }
    return chat
}

private func users(_ items: [TranscriptItem]) -> [String] {
    items.compactMap { if case .user(let text, _) = $0.kind { text } else { nil } }
}

private func bots(_ items: [TranscriptItem]) -> [String] {
    items.compactMap { if case .bot(let text, _) = $0.kind { text } else { nil } }
}

/// "Refazer" and "Editar": where the conversation is cut, what is forgotten with the cut, when they are refused, and what
/// the app does around them (the composer, the send, the saved conversation).
@Suite("Refazer e Editar") struct RewindTests {
    // MARK: Which message is which

    @Test func screenOnlyItemsDoNotShiftWhichMessageIsWhich() {
        var chat = conversation(["a", "b"])
        chat.items.insert(notice("Conversa compactada"), at: 2)
        chat.items.insert(tool("Rodando", "ls"), at: 3)
        let indices = chat.requestMessageIndices(skills: [])
        // items: greeting, a, notice, tool, resposta, b, resposta → "a" is item 1 (message 0), "b" is item 5 (message 2)
        #expect(indices == [1: 0, 5: 2])
        let cut = chat.rewindCut(atItem: 5, skills: [])
        #expect(cut == RewindCut(itemIndex: 5, messageIndex: 2))
    }

    @Test func aMessageThatNeverReachedTheModelIsMatchedByWhatWasTyped() {
        var chat = conversation(["primeira", "terceira"])
        // The second request failed before it was recorded: it is on the screen only.
        chat.items.insert(user("segunda"), at: 3)
        chat.items.insert(notice("Não deu certo: Sem conexão com o provedor"), at: 4)
        let indices = chat.requestMessageIndices(skills: [])
        #expect(indices[3] == nil)
        #expect(indices[1] == 0 && indices[chat.items.count - 2] == 2)
        // Cutting at the failed one drops from where the next recorded request begins: nothing of the first turn.
        let cut = chat.rewindCut(atItem: 3, skills: [])
        #expect(cut == RewindCut(itemIndex: 3, messageIndex: 2))
    }

    @Test func aFailedLastMessageCutsAtTheEndOfTheHistory() {
        var chat = conversation(["primeira"])
        chat.items += [user("quebrou"), notice("Não deu certo: x")]
        let cut = chat.rewindCut(atItem: 3, skills: [])
        #expect(cut == RewindCut(itemIndex: 3, messageIndex: 2))
    }

    @Test func aSkillMessageIsRecognizedByItsExpansion() {
        let skill = Skill(slug: "relatorio", name: "Relatório", summary: "", instructions: "Faça o relatório.", uses: 0)
        var chat = Conversation()
        chat.items = [user("antes"), bot("ok"), user("/relatorio da semana"), bot("feito"), user("depois")]
        chat.messages = [.user("antes"), ChatMessage(role: .assistant, content: "ok"),
                         .user(SystemPrompt.expandSkill(in: "/relatorio da semana", skills: [skill])!.prompt),
                         ChatMessage(role: .assistant, content: "feito"), .user("depois")]
        // One failed request among them (so the counts differ and the text decides).
        chat.items.insert(user("sumiu"), at: 1)
        let indices = chat.requestMessageIndices(skills: [skill])
        #expect(indices[0] == 0 && indices[1] == nil && indices[3] == 2 && indices[5] == 4)
    }

    @Test func anAttachmentsOnlyMessageIsMatchedByItsPaths() {
        var chat = Conversation()
        chat.items = [user("antes"), bot("ok"), user("", ["/tmp/a.pdf"]), bot("li")]
        chat.messages = [.user("antes"), ChatMessage(role: .assistant, content: "ok"),
                         .user("\(AppModel.attachmentsOnlyPrompt)\n\nAttached files (read them with your tools):\n- /tmp/a.pdf"),
                         ChatMessage(role: .assistant, content: "li")]
        chat.items.insert(user("falhou"), at: 1)
        #expect(chat.requestMessageIndices(skills: [])[3] == 2)
    }

    // MARK: Cutting

    @Test func cuttingEndsBothListsAtTheCutAndKeepsTheRest() {
        var chat = conversation(["a", "b", "c"])
        chat.items.insert(notice("aviso depois de b"), at: 6)
        let cut = chat.rewindCut(atItem: 3, skills: [])! // "b"
        chat.rewind(to: cut)
        #expect(users(chat.items) == ["a"] && bots(chat.items) == ["resposta a a"])
        #expect(chat.items.count == 3) // greeting, a, resposta
        #expect(chat.messages.map(\.content) == ["a", "resposta a a"])
    }

    @Test func cuttingForgetsWhatWasDerivedFromTheDroppedPart() {
        var chat = conversation(["a", "b", "c"])
        chat.taskPaused = true
        chat.memorySavedCount = 7
        chat.condensedCount = 6
        chat.chunkSummaries = [ChunkSummary(start: 0, end: 2, text: "nota do começo"), ChunkSummary(start: 2, end: 5, text: "nota que cruza o corte")]
        chat.workspaceHash = "w"
        chat.workspaceSeen = WorkspaceSnapshot(path: "/tmp/pasta")
        chat.claudeSeenCount = 6
        let cut = chat.rewindCut(atItem: 3, skills: [])!
        chat.rewind(to: cut)
        #expect(chat.taskPaused == nil) // read again from the history that is left
        #expect(chat.memorySavedCount == 3 && chat.condensedCount == 2 && chat.claudeSeenCount == 2)
        #expect(chat.chunkSummaries?.map(\.text) == ["nota do começo"])
        #expect(chat.workspaceHash == nil && chat.workspaceSeen == nil)
    }

    @Test func cuttingKeepsTheSummaryOfTheKeptPart() {
        var chat = conversation(["a", "b", "c", "d"])
        chat.summary = "Pedido original: a"
        chat.ledger = ConversationLedger()
        chat.summaryCoveredCount = 2 // "a" and its reply
        chat.compactions = 1
        let cut = chat.rewindCut(atItem: 5, skills: [])! // "c"
        #expect(!chat.isSummarized(cut))
        chat.rewind(to: cut)
        #expect(chat.summary == "Pedido original: a" && chat.summaryCoveredCount == 2 && chat.compactions == 1)
        #expect(chat.coveredMessageCount == 2 && chat.messages.count == 4)
    }

    @Test func aMessageInsideTheSummaryCannotBeCutAt() {
        var chat = conversation(["a", "b", "c", "d"])
        chat.summary = "resumo"
        chat.summaryCoveredCount = 4 // a, b and their replies
        #expect(chat.isSummarized(chat.rewindCut(atItem: 1, skills: [])!))
        #expect(chat.isSummarized(chat.rewindCut(atItem: 3, skills: [])!))
        #expect(!chat.isSummarized(chat.rewindCut(atItem: 5, skills: [])!)) // the first one after it
    }

    @Test func cuttingAClaudeCodeConversationDropsItsSession() {
        var chat = conversation(["a", "b"])
        chat.claudeSessionID = "sessao-abc"
        chat.claudeSessionFolder = "/tmp/pasta"
        chat.claudeSeenCount = 4
        chat.claudeMemoryPinned = "identidade"
        chat.claudeWorkspaceHash = "w"
        chat.claudeStandingHash = "s"
        chat.claudeSystem = "sistema"
        chat.claudeRelatedSent = [["x"]]
        chat.claudeWorkspaceSeen = WorkspaceSnapshot(path: "/tmp/pasta")
        chat.rewind(to: chat.rewindCut(atItem: 3, skills: [])!)
        #expect(chat.claudeSession(forFolder: "/tmp/pasta") == nil) // nothing to resume: a new session starts
        #expect(chat.claudeSessionID == nil && chat.claudeSessionFolder == nil && chat.claudeSeenCount == nil)
        #expect(chat.claudeMemoryPinned == nil && chat.claudeWorkspaceHash == nil && chat.claudeStandingHash == nil)
        #expect(chat.claudeSystem == nil && chat.claudeRelatedSent == nil && chat.claudeWorkspaceSeen == nil)
        // The new session is told what is left of the conversation, and nothing of the turn that went.
        let catchUp = ClaudeCodePrompt.catchUp(chat, seen: 0)
        #expect(catchUp.contains("User: a") && !catchUp.contains("User: b") && !catchUp.contains("resposta a b"))
    }

    // MARK: The last turn

    @Test func theLastTurnStartsAtTheLastRequestAndSteeredMessagesAreFlagged() {
        var chat = conversation(["a", "b"])
        let start = chat.lastTurnStart(skills: [])
        #expect(start?.cut == RewindCut(itemIndex: 3, messageIndex: 2) && start?.hasSteeredMessages == false)

        // A message sent in the middle of the task belongs to the turn it entered, not to a turn of its own.
        chat.items.insert(TranscriptItem(.user(text: "ah, e o rodapé", attachments: []), duringTask: true), at: 4)
        chat.messages.insert(.user("ah, e o rodapé"), at: 3)
        let steered = chat.lastTurnStart(skills: [])
        #expect(steered?.cut.itemIndex == 3 && steered?.hasSteeredMessages == true)
    }

    @Test func thereIsNoLastTurnWithoutAReply() {
        var chat = Conversation()
        #expect(chat.lastTurnStart(skills: []) == nil)
        chat.items = [user("a")]
        chat.messages = [.user("a")]
        #expect(chat.lastTurnStart(skills: []) == nil)
        chat.items.append(notice("Não deu certo: x"))
        #expect(chat.lastTurnStart(skills: []) == nil)
    }

    @Test func theRedoButtonBelongsToTheLastFinishedReplyOfAnIdleChat() {
        let chat = conversation(["a", "b"])
        let last = chat.items.last!
        #expect(RewindRows.redoTarget(in: chat.items, isWorking: false) == last.id)
        #expect(RewindRows.redoTarget(in: chat.items, isWorking: true) == nil)
        // Notices and tool lines after the reply do not take it away; a message of yours does; a reply still streaming has none.
        #expect(RewindRows.redoTarget(in: chat.items + [notice("Você interrompeu esta resposta")], isWorking: false) == last.id)
        #expect(RewindRows.redoTarget(in: chat.items + [user("c")], isWorking: false) == nil)
        #expect(RewindRows.redoTarget(in: Array(chat.items.dropLast()) + [TranscriptItem(.bot(text: "meio", isStreaming: true))], isWorking: false) == nil)
        #expect(RewindRows.redoTarget(in: [TranscriptItem(.greeting("Oi"))], isWorking: false) == nil)
    }

    // MARK: What would be dropped

    @Test func textOnlyTurnsDropNothingThatChangedAnything() {
        var chat = conversation(["a", "b"])
        chat.items.insert(tool("Rodando no Terminal", "git status"), at: 4)
        chat.items.insert(tool("Lendo arquivo", "/tmp/a.txt", kind: .file), at: 5)
        chat.items.insert(tool("Buscando no conteúdo", "TODO", kind: .search), at: 6)
        #expect(!chat.dropsChanges(from: 3))
    }

    @Test func aCommandThatIsNotAPlainLookCountsAsAChange() {
        var chat = conversation(["a"])
        chat.items.insert(tool("Rodando no Terminal", "swift build"), at: 2)
        #expect(chat.dropsChanges(from: 2))
        #expect(!chat.dropsChanges(from: 3)) // after the tool line
    }

    @Test func writtenFilesAndOperatedAppsCountAsChanges() {
        var chat = conversation(["a"])
        chat.items.insert(tool("Gravando arquivo", "/tmp/x.txt", kind: .file), at: 2)
        #expect(chat.dropsChanges(from: 1))
        chat.items[2] = tool("Clicando em Salvar", "", kind: .computer)
        #expect(chat.dropsChanges(from: 1))
        chat.items[2] = tool("Capturando a tela", "", kind: .computer)
        #expect(!chat.dropsChanges(from: 1))
        var produced = ToolCall(kind: .shell, title: "Lendo", detail: "cat a", state: .done)
        produced.files = [ProducedFile(path: "/tmp/novo", created: true)]
        chat.items[2] = TranscriptItem(.tool(produced))
        #expect(chat.dropsChanges(from: 1))
    }

    @Test func aConnectorCallCountsOnlyWhenACardWasAnsweredYes() {
        var chat = conversation(["a"])
        chat.items.insert(tool("Usando create_issue", "", kind: .connector), at: 2)
        #expect(!chat.dropsChanges(from: 1))
        var card = ApprovalRequest(toolName: "create_issue", title: "Usando create_issue", command: "", reason: "")
        card.decision = .once
        chat.items.insert(TranscriptItem(.approval(card)), at: 2)
        #expect(chat.dropsChanges(from: 1))
        card.decision = .deny
        chat.items[2] = TranscriptItem(.approval(card))
        #expect(!chat.dropsChanges(from: 1))
    }

    @Test func theRefusalsSayWhyAndOnlyTheOnesAboutTheMessageKeepTheButton() {
        for refusal in [RewindRefusal.busy, .approvalPending, .routine, .preparingPictures, .summarized, .steered, .noReply, .steeredTurn, .missing] {
            #expect(!refusal.reason.isEmpty)
        }
        #expect(RewindRefusal.busy.hidesButton && RewindRefusal.approvalPending.hidesButton && RewindRefusal.routine.hidesButton)
        #expect(!RewindRefusal.summarized.hidesButton && !RewindRefusal.steered.hidesButton && !RewindRefusal.steeredTurn.hidesButton)
        #expect(RewindWords.editMessage == "Os passos depois desta mensagem saem da conversa; o que o Orb já fez no Mac não é desfeito.")
    }

    // MARK: In the app

    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbRewind-\(UUID().uuidString)")

    @MainActor private func model(with chat: Conversation, connected: Bool = true, received: Received = Received()) -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots[0].workingDirectory = root.path
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root)
        store.save(state)
        store.save(chat, for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        if connected {
            model.providers = [ProviderAccount(kind: .custom)]
            model.defaultModel = "custom/modelo"
            model.clientOverride = { RecordingModel(received: received) }
        }
        return (model, model.bots[0].id)
    }

    @MainActor private func settle(_ model: AppModel, _ id: UUID) async {
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }
    }

    /// The item of the transcript with this text from you.
    @MainActor private func row(_ text: String, in model: AppModel, _ id: UUID) -> TranscriptItem? {
        model.transcript(id).first { if case .user(let typed, _) = $0.kind { typed == text } else { false } }
    }

    @MainActor @Test func redoingDropsTheLastTurnAndSendsTheSameRequestAgain() async throws {
        defer { removeTestFolder(root) }
        var chat = conversation(["a", "b"])
        chat.items.insert(tool("Rodando no Terminal", "touch x"), at: 4)
        chat.items.append(notice("Você interrompeu esta resposta"))
        let received = Received()
        let (model, id) = model(with: chat, received: received)
        await model.loadedConversation(id)
        let bubble = try #require(row("b", in: model, id))

        #expect(model.regenerateRefusal(id) == nil)
        #expect(model.regenerateDropsChanges(id)) // `touch x` ran
        let nudges = model.live(id).scrollNudge
        #expect(model.regenerateLastReply(id))
        #expect(model.live(id).scrollNudge == nudges + 1)
        await settle(model, id)

        let items = model.transcript(id)
        #expect(users(items) == ["a", "b"] && bots(items) == ["resposta a a", "Pronto."])
        #expect(!items.contains { if case .tool = $0.kind { true } else { false } })
        #expect(!items.contains { if case .notice = $0.kind { true } else { false } })
        #expect(items.first { if case .greeting = $0.kind { true } else { false } } != nil) // the greeting stays
        // Your bubble stays where it was: the same row, not one leaving and another arriving.
        #expect(row("b", in: model, id)?.id == bubble.id)
        // The model saw the conversation without the discarded turn, and "b" once.
        let sent = try #require(await received.requests.last)
        #expect(sent.map(\.content).contains("resposta a a") && !sent.map(\.content).contains("resposta a b"))
        #expect(sent.filter { $0.role == .user }.count == 2) // "a" and the new "b": the old "b" is not there as well
        let messages = try #require(model.conversations[id]).messages
        #expect(messages.filter { $0.role == .user }.count == 2 && messages.last?.content == "Pronto.")
    }

    @MainActor @Test func redoingKeepsThePicturesAndFilesOfTheRequest() async throws {
        defer { removeTestFolder(root) }
        let file = root.appendingPathComponent("relatorio.txt")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "dados".write(to: file, atomically: true, encoding: .utf8)
        let picture = ImageAttachment(path: root.appendingPathComponent("foto.jpg").path, mediaType: "image/jpeg", width: 1, height: 1)
        var chat = Conversation()
        chat.items = [user("veja isto", [file.path, picture.path]), bot("visto")]
        chat.messages = [.user("veja isto\n\nAttached files (read them with your tools):\n- \(file.path)", images: [picture]),
                         ChatMessage(role: .assistant, content: "visto")]
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)

        #expect(model.regenerateLastReply(id))
        await settle(model, id)
        let sent = try #require(model.conversations[id]).messages.filter { $0.role == .user }
        #expect(sent.count == 1 && sent[0].images.map(\.path) == [picture.path] && sent[0].content.contains(file.path))
        #expect(model.transcript(id).contains { if case .user(_, let attachments) = $0.kind { attachments == [picture.path, file.path] || attachments == [file.path, picture.path] } else { false } })
    }

    @MainActor @Test func redoingASkillRequestCountsItsUseOnce() async {
        defer { removeTestFolder(root) }
        let skill = Skill(slug: "relatorio", name: "Relatório", summary: "", instructions: "Faça o relatório.", uses: 1)
        var chat = Conversation()
        chat.items = [user("/relatorio da semana"), bot("feito")]
        chat.messages = [.user(SystemPrompt.expandSkill(in: "/relatorio da semana", skills: [skill])!.prompt),
                         ChatMessage(role: .assistant, content: "feito")]
        let (model, id) = model(with: chat)
        model.skills = [skill]
        await model.loadedConversation(id)

        #expect(model.regenerateLastReply(id))
        await settle(model, id)
        #expect(model.skills.first?.uses == 1)
        #expect(model.conversations[id]?.messages.filter { $0.role == .user }.count == 1)
    }

    @MainActor @Test func redoingFadesTheRowsThatGoAndThenCuts() async throws {
        defer { removeTestFolder(root) }
        let chat = conversation(["a", "b"])
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        let gone = try #require(model.transcript(id).last).id

        #expect(model.regenerateLastReply(id, animated: true))
        // At once nothing is cut: the reply is fading (a second press finds the Orb busy).
        #expect(model.live(id).dropping == [gone])
        #expect(model.transcript(id).count == chat.items.count)
        #expect(model.regenerateRefusal(id) == .busy)
        await waitUntil("the cut") { model.live(id).dropping.isEmpty }
        await settle(model, id)
        #expect(bots(model.transcript(id)) == ["resposta a a", "Pronto."])
    }

    @MainActor @Test func redoingIsRefusedWhileTheOrbWorksAWaitsOrARoutineRuns() async {
        defer { removeTestFolder(root) }
        var chat = conversation(["a"])
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        #expect(model.regenerateRefusal(id) == nil)

        model.setStatus("Pensando", of: id)
        #expect(model.regenerateRefusal(id) == .busy && !model.regenerateLastReply(id))
        model.setStatus(nil, of: id)

        model.session(id).routineID = UUID()
        #expect(model.regenerateRefusal(id) == .routine && !model.regenerateLastReply(id))
        model.session(id).routineID = nil

        chat = model.conversations[id]!
        model.append(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando", command: "ls", reason: "")), to: id)
        #expect(model.regenerateRefusal(id) == .approvalPending && !model.regenerateLastReply(id))
        #expect(model.transcript(id).count == chat.items.count + 1) // nothing was cut
    }

    @MainActor @Test func redoingIsRefusedWhenMessagesCameInTheMiddleOfTheTask() async {
        defer { removeTestFolder(root) }
        var chat = conversation(["a"])
        chat.items.insert(TranscriptItem(.user(text: "e mais isto", attachments: []), duringTask: true), at: 2)
        chat.messages.insert(.user("e mais isto"), at: 1)
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        #expect(model.regenerateRefusal(id) == .steeredTurn)
        #expect(model.editRefusal(itemID: chat.items[2].id, of: id) == .steered) // edit the request that began the task
        #expect(model.editRefusal(itemID: chat.items[1].id, of: id) == nil)
    }

    @MainActor @Test func redoingWithoutAModelLeavesTheChatAsItWas() async {
        defer { removeTestFolder(root) }
        let chat = conversation(["a"])
        let (model, id) = model(with: chat, connected: false)
        model.providers = []
        await model.loadedConversation(id)
        #expect(!model.regenerateLastReply(id))
        #expect(model.transcript(id).count == chat.items.count && model.conversations[id]?.messages.count == 2)
    }

    @MainActor @Test func editingPutsTheMessageInTheComposerAndKeepsWhatWasThere() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b", "c"]))
        await model.loadedConversation(id)
        model.setDraft("rascunho", for: id)
        let target = try #require(row("b", in: model, id))

        #expect(model.beginEditing(itemID: target.id, of: id))
        let lane = model.composerLane(id)
        #expect(model.isEditing(id) && model.drafts[id] == "b" && lane.editing?.stash.text == "rascunho")
        // Quitting in the middle of the edit keeps the draft that was there, not the half-edited message.
        #expect(model.composerDrafts()[id]?.text == "rascunho")
        // Nothing is cut until the edit is sent.
        #expect(users(model.transcript(id)) == ["a", "b", "c"])

        model.cancelEditing(id)
        #expect(!model.isEditing(id) && model.drafts[id] == "rascunho")
        #expect(users(model.transcript(id)) == ["a", "b", "c"])
    }

    @MainActor @Test func sendingAnEditReplacesTheMessageAndDropsEverythingAfterIt() async throws {
        defer { removeTestFolder(root) }
        var chat = conversation(["a", "b", "c"])
        chat.items.insert(notice("Você interrompeu esta resposta"), at: 4)
        chat.items.insert(tool("Gravando arquivo", "/tmp/x", kind: .file), at: 5)
        let received = Received()
        let (model, id) = model(with: chat, received: received)
        await model.loadedConversation(id)
        model.setDraft("rascunho", for: id)
        let target = try #require(row("b", in: model, id))
        model.apply(.requestUsage(TokenUsage(input: 100, output: 10, cacheRead: 0, cacheWrite: 0)), to: id)

        #expect(model.beginEditing(itemID: target.id, of: id))
        #expect(model.editDropsChanges(itemID: target.id, of: id)) // a file was written after it
        #expect(model.submit("b, mas melhor", to: id)) // the composer's own send goes through the edit
        await settle(model, id)

        let items = model.transcript(id)
        #expect(users(items) == ["a", "b, mas melhor"] && bots(items) == ["resposta a a", "Pronto."])
        #expect(!items.contains { if case .notice = $0.kind { true } else { false } })
        #expect(items.first.map { if case .greeting = $0.kind { true } else { false } } == true)
        #expect(row("b, mas melhor", in: model, id)?.id == target.id) // the bubble changed in place
        // The model's history was cut at the same message: no "b", "c" or their replies.
        let sent = try #require(await received.requests.last)
        let contents = sent.map(\.content)
        #expect(contents.contains("resposta a a") && !contents.contains("resposta a b") && !contents.contains("c"))
        #expect(sent.filter { $0.role == .user }.map(\.content).contains { $0.contains("b, mas melhor") })
        let messages = try #require(model.conversations[id]).messages
        #expect(messages.filter { $0.role == .user }.count == 2 && messages.map(\.content).last == "Pronto.")
        // What the composer held comes back, and the edit is over.
        #expect(!model.isEditing(id) && model.drafts[id] == "rascunho")
        // Usage already written stays.
        model.usageLog.flush()
        model.store.flush()
        let rows = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).buckets
        #expect(rows.reduce(0) { $0 + $1.totals.input } >= 100)
    }

    @MainActor @Test func theCutConversationIsSaved() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b", "c"]))
        await model.loadedConversation(id)
        let target = try #require(row("b", in: model, id))
        #expect(model.beginEditing(itemID: target.id, of: id))
        #expect(model.submitEdit("b2", to: id))
        await settle(model, id)
        model.saveNow()
        model.store.flush()

        let saved = try #require(Store(directory: root).readConversation(id).value)
        #expect(users(saved.items) == ["a", "b2"] && saved.messages.filter { $0.role == .user }.count == 2)
        #expect(!saved.messages.contains { $0.content == "c" || $0.content == "resposta a c" })
    }

    @MainActor @Test func editingTheFirstMessageStartsTheConversationOver() async throws {
        defer { removeTestFolder(root) }
        var chat = conversation(["a", "b"])
        chat.memorySavedCount = 5
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        let target = try #require(row("a", in: model, id))
        #expect(model.beginEditing(itemID: target.id, of: id))
        #expect(model.submitEdit("outra coisa", to: id))
        await settle(model, id)
        #expect(users(model.transcript(id)) == ["outra coisa"])
        let saved = try #require(model.conversations[id])
        #expect(saved.messages.filter { $0.role == .user }.count == 1)
        #expect((saved.memorySavedCount ?? 0) <= saved.items.count)
    }

    @MainActor @Test func editingBringsBackTheAttachmentsThatAreStillThere() async throws {
        defer { removeTestFolder(root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let photo = root.appendingPathComponent("foto.jpg")
        try Data([0xFF]).write(to: photo)
        let picture = ImageAttachment(path: photo.path, mediaType: "image/jpeg", width: 1, height: 1)
        var chat = Conversation()
        chat.items = [user("veja", [file.path, picture.path, "/sumiu/de/vez.pdf", "antigo.png"]), bot("visto")]
        chat.messages = [.user("veja", images: [picture]), ChatMessage(role: .assistant, content: "visto")]
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)

        #expect(model.beginEditing(itemID: chat.items[0].id, of: id))
        let lane = model.composerLane(id)
        #expect(lane.files.map(\.url.path) == [file.path] && lane.pictures.map(\.path) == [picture.path])
        #expect(lane.editing?.originalPictures == [picture.path])
        model.cancelEditing(id)
        #expect(lane.files.isEmpty && lane.pictures.isEmpty)
    }

    @MainActor @Test func anEditNeedsSomethingToSendAndAModel() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b"]), connected: false)
        model.providers = []
        await model.loadedConversation(id)
        let target = try #require(row("b", in: model, id))
        #expect(model.beginEditing(itemID: target.id, of: id))
        #expect(!model.submitEdit("b2", to: id)) // no usable model: the chat is as it was and the edit goes on
        #expect(users(model.transcript(id)) == ["a", "b"] && model.isEditing(id))
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { RecordingModel(received: Received()) }
        #expect(!model.submitEdit("   ", to: id)) // nothing to send
        #expect(model.submitEdit("b2", to: id))
        await settle(model, id)
        #expect(users(model.transcript(id)) == ["a", "b2"])
    }

    @MainActor @Test func editingIsRefusedWhileTheOrbWorksWaitsOrARoutineRuns() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b"]))
        await model.loadedConversation(id)
        let target = try #require(row("a", in: model, id))
        #expect(model.editRefusal(itemID: target.id, of: id) == nil)
        #expect(model.editRefusal(itemID: UUID(), of: id) == .missing)

        model.setStatus("Pensando", of: id)
        #expect(model.editRefusal(itemID: target.id, of: id) == .busy && !model.beginEditing(itemID: target.id, of: id))
        model.setStatus(nil, of: id)

        model.session(id).routineID = UUID()
        #expect(model.editRefusal(itemID: target.id, of: id) == .routine && !model.beginEditing(itemID: target.id, of: id))
        model.session(id).routineID = nil

        model.append(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando", command: "ls", reason: "")), to: id)
        #expect(model.editRefusal(itemID: target.id, of: id) == .approvalPending && !model.beginEditing(itemID: target.id, of: id))
        #expect(!model.isEditing(id))
    }

    @MainActor @Test func aTurnThatStartsDuringTheEditStopsTheSend() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b"]))
        await model.loadedConversation(id)
        let target = try #require(row("b", in: model, id))
        #expect(model.beginEditing(itemID: target.id, of: id))
        model.session(id).routineID = UUID() // a routine takes the Orb
        #expect(!model.submitEdit("b2", to: id))
        #expect(users(model.transcript(id)) == ["a", "b"])
    }

    @MainActor @Test func aMessageAlreadyInTheSummaryCannotBeEditedButALaterOneCan() async throws {
        defer { removeTestFolder(root) }
        var chat = conversation(["a", "b", "c", "d"])
        chat.summary = "Pedido original: a"
        chat.summaryCoveredCount = 4 // "a", "b" and their replies are in the summary
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        let inside = try #require(row("b", in: model, id))
        let outside = try #require(row("c", in: model, id))

        #expect(model.editRefusal(itemID: inside.id, of: id) == .summarized)
        #expect(!model.beginEditing(itemID: inside.id, of: id) && !model.isEditing(id))
        #expect(RewindRefusal.summarized.reason.contains("resumo") && !RewindRefusal.summarized.hidesButton) // dimmed, with the reason

        #expect(model.editRefusal(itemID: outside.id, of: id) == nil)
        #expect(model.beginEditing(itemID: outside.id, of: id))
        #expect(model.submitEdit("c2", to: id))
        await settle(model, id)
        let kept = try #require(model.conversations[id])
        #expect(kept.summary == "Pedido original: a" && kept.summaryCoveredCount == 4) // the summary still stands
        #expect(users(kept.items) == ["a", "b", "c2"])
    }

    @MainActor @Test func editingAfterAFailedRequestCutsWhereTheNextRecordedOneBegins() async throws {
        defer { removeTestFolder(root) }
        // A request that failed before it reached the model sits between two that did: editing the one after it cuts there.
        var chat = conversation(["a", "c"])
        chat.items.insert(user("falhou"), at: 3)
        chat.items.insert(notice("Não deu certo: x"), at: 4)
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        let target = try #require(row("c", in: model, id))
        #expect(model.beginEditing(itemID: target.id, of: id))
        #expect(model.submitEdit("c2", to: id))
        await settle(model, id)
        #expect(users(model.transcript(id)) == ["a", "falhou", "c2"])
        #expect(model.conversations[id]?.messages.filter { $0.role == .user }.map(\.content).count == 2)
    }

    @MainActor @Test func beginningAnotherEditPutsTheFirstStashBack() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b"]))
        await model.loadedConversation(id)
        model.setDraft("meu rascunho", for: id)
        let first = try #require(row("a", in: model, id)), second = try #require(row("b", in: model, id))
        #expect(model.beginEditing(itemID: first.id, of: id))
        #expect(model.beginEditing(itemID: second.id, of: id))
        #expect(model.drafts[id] == "b" && model.composerLane(id).editing?.stash.text == "meu rascunho")
        model.cancelEditing(id)
        #expect(model.drafts[id] == "meu rascunho")
    }

    @MainActor @Test func openingAnotherChatGivesTheEditUp() async throws {
        defer { removeTestFolder(root) }
        let (model, id) = model(with: conversation(["a", "b"]))
        await model.loadedConversation(id)
        model.setDraft("rascunho", for: id)
        #expect(model.beginEditing(itemID: try #require(row("b", in: model, id)).id, of: id))
        model.session(id).installChat(Conversation())
        #expect(!model.isEditing(id) && model.drafts[id] == "rascunho")
    }

    @MainActor @Test func theEditedPicturesStayOnDiskWhenTheyLeaveTheStrip() async throws {
        defer { removeTestFolder(root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("foto.jpg")
        try Data([0xFF]).write(to: photo)
        let picture = ImageAttachment(path: photo.path, mediaType: "image/jpeg", width: 1, height: 1)
        var chat = Conversation()
        chat.items = [user("veja", [picture.path]), bot("visto")]
        chat.messages = [.user("veja", images: [picture]), ChatMessage(role: .assistant, content: "visto")]
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)
        #expect(model.beginEditing(itemID: chat.items[0].id, of: id))
        // The strip's remove button keeps the file of a picture that belongs to the message (the view checks this).
        #expect(model.composerLane(id).editing?.originalPictures.contains(picture.path) == true)
    }
}
