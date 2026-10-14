import Foundation
import Testing
@testable import Orb

// Compaction as the app and the Claude Code engine see it: catch-up for a new session, the CLI's own compaction
// events, decisions in memory pages, and "Compactar agora" / the notices in AppModel.

private let firstRequest = "Construa o app Atlas com SQLite e rode os testes a cada mudança"

/// A turn: the request, a tool step answered by `output`, and a reply.
private func turn(_ request: String, output: String = "ok", reply: String = "feito", id: String = UUID().uuidString) -> [ChatMessage] {
    [.user(request), ChatMessage(role: .assistant, content: "", toolCalls: [call(id, "read_file", #"{"path":"/p/\#(id.prefix(4)).swift"}"#)]),
     .tool(id, output), ChatMessage(role: .assistant, content: reply)]
}

/// `longReplies`: old tool outputs are condensed before any turn is folded (`ContextCondensing`), so a history that has
/// to fold needs long answers too.
private func conversation(turns: Int, output: Int = 100, start: Int = 0, longReplies: Bool = false) -> Conversation {
    var conversation = Conversation()
    let tail = longReplies ? " " + String(repeating: "texto da resposta ", count: 200) : ""
    for index in start..<(start + turns) {
        conversation.messages += turn(index == 0 ? firstRequest : "pedido número \(index) do projeto",
                                      output: String(repeating: "x", count: output), reply: "resposta \(index)" + tail, id: "id\(index)")
    }
    return conversation
}

// MARK: - Decisions in memory pages

struct SessionDecisionsTests {
    private func items(_ said: String...) -> [TranscriptItem] {
        said.flatMap { [TranscriptItem(.user(text: $0, attachments: [])), TranscriptItem(.bot(text: "ok", isStreaming: false))] }
    }

    @Test func aSessionPageListsWhatTheUserDecided() throws {
        let page = try #require(SessionSummary.page(from: items("organize a pasta Fotos", "Decisão: use sempre a data no nome do arquivo.",
                                                                 "mostre o resultado", "nunca apague originais")))
        #expect(page.body.contains("## Decisões\n- Decisão: use sempre a data no nome do arquivo.\n- nunca apague originais"))
        let decisions = SessionSummary.section("Decisões", in: page.body)
        #expect(decisions.count == 2)
        // Pedidos still comes first.
        #expect(try #require(page.body.range(of: "## Pedidos")).lowerBound < (try #require(page.body.range(of: "## Decisões")).lowerBound))
    }

    @Test func aWordLikeSempreAloneIsNotADecisionForTheMemory() throws {
        let page = try #require(SessionSummary.page(from: items("o build sempre quebra quando mudo o Package.swift", "o projeto usa React",
                                                                 "isso nunca funcionou direito", "lembre de olhar o log")))
        #expect(!page.body.contains("## Decisões"))
        // The conversation's own summary keeps the broad rule.
        #expect(ConversationLedger.looksLikeDecision("o build sempre quebra quando mudo o Package.swift"))
    }

    @Test func noDecisionsNoSection() throws {
        let page = try #require(SessionSummary.page(from: items("organize a pasta Fotos", "mostre o resultado")))
        #expect(!page.body.contains("## Decisões"))
    }

    @Test func secretsInADecisionAreScrubbed() throws {
        let page = try #require(SessionSummary.page(from: items("a partir de agora use o token=abc123def456ghi789 nas chamadas")))
        #expect(page.body.contains("## Decisões"))
        #expect(!page.body.contains("abc123def456ghi789"))
    }
}

// MARK: - Connectors stay out of memory

struct SessionConnectorTests {
    /// What came from a connector (the tool, what was asked of it, the answer that restates it) is not remembered for good:
    /// only the fact that the connector was used.
    @Test func aSessionThatUsedAConnectorKeepsNoContentOfIt() throws {
        let secretMail = "Assunto: Proposta confidencial da Acme, valor R$ 480 mil"
        let items: [TranscriptItem] = [
            TranscriptItem(.user(text: "veja meus e-mails novos", attachments: [])),
            TranscriptItem(.tool(ToolCall(kind: .connector, title: "Usando Gmail", detail: "search_threads {\"query\":\"Acme proposta https://acme.example/contrato\"}",
                                          state: .done, output: secretMail))),
            TranscriptItem(.tool(ToolCall(kind: .connector, title: "Usando Gmail", detail: "get_message {\"id\":\"18f\"}", state: .failed))),
            TranscriptItem(.tool(ToolCall(kind: .file, title: "Lendo arquivo", detail: "/Users/x/notas.txt", state: .done))),
            TranscriptItem(.bot(text: "Você tem um e-mail da Acme com a proposta de R$ 480 mil.", isStreaming: false)),
        ]
        let page = try #require(SessionSummary.page(from: items))
        #expect(page.body.contains("- Usando Gmail"))
        #expect(page.body.contains("Usando Gmail (falhou)") && page.body.contains("Não deu certo: Usando Gmail"))
        for leaked in ["Acme", "480", "search_threads", "get_message", "acme.example", "Última resposta"] {
            #expect(!page.body.contains(leaked), Comment(rawValue: leaked))
        }
        // What the Orb itself did is kept as before, and so are the user's words.
        #expect(page.body.contains("/Users/x/notas.txt") && page.body.contains("veja meus e-mails novos"))
    }

    /// A denied card of a connector holds the tool and its arguments (the body of a message): the page keeps only the title.
    @Test func aDeniedConnectorCardKeepsOnlyItsTitle() throws {
        let body = #"send_message {"to":["ana@acme.example"],"body":"Segue a proposta de R$ 480 mil"}"#
        func denied(_ tool: String, title: String = "Usando Gmail", items: [ApprovalItem] = []) -> TranscriptItem {
            TranscriptItem(.approval(ApprovalRequest(toolName: tool, title: title, command: body, reason: "", decision: .deny, items: items)))
        }
        let user = TranscriptItem(.user(text: "manda a proposta", attachments: []))
        for tool in ["Gmail__send_message", "mcp__gmail__send_message", "connector_call"] {
            let page = try #require(SessionSummary.page(from: [user, denied(tool)]))
            #expect(page.body.contains("Você negou: Usando Gmail"), Comment(rawValue: tool))
            for leaked in ["Acme", "acme", "480", "send_message", "ana@"] { #expect(!page.body.contains(leaked), Comment(rawValue: tool + " " + leaked)) }
        }
        // A card that groups a connector's call with others is the same.
        let batch = denied("batch", title: "2 ações precisam da sua permissão", items: [ApprovalItem(toolName: "write_file", title: "Gravando", command: "a.txt"),
                                                                                            ApprovalItem(toolName: "Slack__post", title: "Usando Slack", command: body)])
        #expect(try #require(SessionSummary.page(from: [user, batch])).body.contains("Você negou: 2 ações precisam da sua permissão"))
        #expect(!(try #require(SessionSummary.page(from: [user, batch])).body.contains("480")))
        // A denied command of the Orb itself is kept as before.
        let shell = TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "git push", reason: "", decision: .deny)))
        #expect(try #require(SessionSummary.page(from: [user, shell])).body.contains("Você negou: Rodando no Terminal git push"))
    }

    @Test func aSessionWithoutConnectorsKeepsItsLastAnswer() throws {
        let items = [TranscriptItem(.user(text: "oi", attachments: [])), TranscriptItem(.bot(text: "Olá, tudo bem?", isStreaming: false))]
        #expect(try #require(SessionSummary.page(from: items)).body.contains("## Última resposta\nOlá, tudo bem?"))
    }
}

// MARK: - AppModel

@Suite final class CompactionAppTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbCompaction-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// Items for the messages of `conversation`: what the user said and what the Orb answered.
    private func transcript(for messages: [ChatMessage]) -> [TranscriptItem] {
        messages.compactMap { message in
            switch message.role {
            case .user where !message.content.hasPrefix(ContextSummary.marker): TranscriptItem(.user(text: message.content, attachments: []))
            case .assistant where !message.content.isEmpty: TranscriptItem(.bot(text: message.content, isStreaming: false))
            default: nil
            }
        }
    }

    @MainActor private func model(_ conversation: Conversation, claudeCode: Bool = false) -> (AppModel, UUID) {
        var conversation = conversation
        conversation.items = transcript(for: conversation.messages)
        let store = Store(directory: root)
        let state = AppState.initial
        let botID = state.bots[0].id
        store.save(state)
        store.save(conversation, for: botID)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)] // no address: a turn fails before any network call
        model.defaultModel = claudeCode ? "claudeCode/sonnet" : "custom/modelo"
        return (model, botID)
    }

    @MainActor private func lastNotice(_ model: AppModel, _ botID: UUID) -> String? {
        for item in model.transcript(botID).reversed() { if case .notice(let text) = item.kind { return text } }
        return nil
    }

    // MARK: Compactar agora

    @Test @MainActor func compactNowFoldsOldMessagesAndReportsTheNumbers() async throws {
        let (model, botID) = model(conversation(turns: 24, output: 20_000))
        let result = model.compactNow(botID: botID)

        #expect(result.status == .compacted && result.didCompact)
        #expect(result.foldedMessages > 0)
        #expect(result.tokensBefore > result.tokensAfter && result.tokensAfter > 0)
        #expect(result.savedToMemory)
        #expect(result.message.hasPrefix("Compactei a conversa: "))
        #expect(result.message.hasSuffix(" O essencial vai para a memória do Orb."))
        let notice = try #require(lastNotice(model, botID))
        #expect(result.message.hasPrefix(notice))
        #expect(model.lastCompaction[botID]?.kind == .manual)

        let conversation = try #require(model.conversations[botID])
        #expect(conversation.summary?.contains("Pedido original: " + firstRequest) == true)
        #expect(conversation.ledger != nil && conversation.compactions == 1)
        #expect(conversation.summaryCoveredCount == result.foldedMessages)
        // Saved as a session page before the old messages left the model's view.
        #expect(conversation.memorySavedCount == conversation.items.count)
        let bank = model.memory.bank(for: botID)
        await waitUntil("the session page") { await bank.snapshot().items.contains { $0.kind == .sessao } }
        // The conversation itself keeps every message.
        #expect(conversation.messages.count == 24 * 4)
    }

    @Test @MainActor func theFocusEntersTheSummaryAndTheSummaryCanBeRead() throws {
        let (model, botID) = model(conversation(turns: 24, output: 20_000))
        #expect(model.contextSummary(for: botID) == nil)
        let result = model.compactNow(botID: botID, focus: "o módulo de login")
        #expect(result.didCompact)
        let info = try #require(model.contextSummary(for: botID))
        #expect(info.text.contains("Dar atenção a: o módulo de login"))
        #expect(info.focus == "o módulo de login" && info.compactions == 1 && info.foldedMessages == result.foldedMessages)
        #expect(info.ledger?.original == firstRequest)
    }

    @Test @MainActor func aShortConversationHasNothingToCompact() {
        let (model, botID) = model(conversation(turns: 1))
        let result = model.compactNow(botID: botID)
        #expect(result.status == .nothingToCompact && !result.didCompact)
        #expect(result.message == ContextWords.nothingToFold)
        #expect(lastNotice(model, botID) == nil)
        #expect(model.lastCompaction[botID] == nil)
        #expect(model.conversations[botID]?.summary == nil)
    }

    @Test @MainActor func nothingIsCompactedWhileAMessageIsBeingAnswered() async {
        let (model, botID) = model(conversation(turns: 24, output: 20_000))
        #expect(model.send("oi de novo", to: botID))
        let busy = model.compactNow(botID: botID)
        #expect(busy.status == .busy && !busy.didCompact)
        await waitUntil("the turn to end") { !model.isWorking(botID) }
        #expect(model.compactNow(botID: botID).status == .compacted)
    }

    @Test @MainActor func anUnknownOrbIsReported() {
        let (model, _) = model(conversation(turns: 2))
        #expect(model.compactNow(botID: UUID()).status == .unavailable)
    }

    @Test @MainActor func compactingTwiceDoesNotShrinkTheSummaryPointer() throws {
        let (model, botID) = model(conversation(turns: 24, output: 20_000))
        _ = model.compactNow(botID: botID)
        let first = try #require(model.conversations[botID]?.summaryCoveredCount)
        _ = model.compactNow(botID: botID)
        #expect((model.conversations[botID]?.summaryCoveredCount ?? 0) >= first)
        #expect((model.conversations[botID]?.summaryCoveredCount ?? .max) < (model.conversations[botID]?.messages.count ?? 0))
    }

    @Test @MainActor func aClaudeCodeChatFoldsLikeAnyOther() async throws {
        let (model, botID) = model(conversation(turns: 24, output: 20_000), claudeCode: true)
        let result = model.compactNow(botID: botID, focus: "o login")

        #expect(result.status == .compacted && result.didCompact)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.summary?.contains("Dar atenção a: o login") == true)
        #expect(conversation.summaryCoveredCount == result.foldedMessages)
    }

    // MARK: Notices from the engine

    @Test @MainActor func aFoldInsideATurnIsKeptAndAnnouncedOnce() throws {
        let (model, botID) = model(conversation(turns: 10))
        _ = model.contextSummary(for: botID) // loads the conversation
        let ledger = ConversationLedger().absorbing(Array(model.conversations[botID]?.messages.prefix(8) ?? []))
        let first = CompactionReport(kind: .turns, foldedMessages: 8, tokensBefore: 60_000, tokensAfter: 30_000,
                                     fold: .init(summary: ledger.render(), ledger: ledger, turns: 2))
        model.apply(.compacted(first), to: botID)

        var conversation = try #require(model.conversations[botID])
        #expect(conversation.summary == ledger.render() && conversation.ledger == ledger)
        #expect(conversation.summaryCoveredCount == 8 && conversation.compactions == 1)
        // The notice counts your requests (two here, four messages each), not the model's messages.
        #expect(lastNotice(model, botID) == "Compactei a conversa: os 2 primeiros pedidos viraram um resumo (≈ 60 mil → 30 mil tokens).")
        var told = first
        told.foldedRequests = 2
        #expect(model.lastCompaction[botID] == told)

        // A later fold in the same turn adds to it.
        let more = CompactionReport(kind: .turns, foldedMessages: 4, tokensBefore: 50_000, tokensAfter: 30_000,
                                    fold: .init(summary: "resumo maior", ledger: nil, turns: 1))
        model.apply(.compacted(more), to: botID)
        conversation = try #require(model.conversations[botID])
        #expect(conversation.summary == "resumo maior" && conversation.summaryCoveredCount == 12 && conversation.compactions == 2)
        let notices = model.transcript(botID).filter { if case .notice = $0.kind { true } else { false } }
        #expect(notices.count == 2)
    }

    @Test @MainActor func aFoldNeverCoversTheLastMessage() throws {
        let (model, botID) = model(conversation(turns: 2))
        _ = model.contextSummary(for: botID)
        model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 500, tokensBefore: 1, tokensAfter: 1,
                                                fold: .init(summary: "resumo", ledger: nil, turns: 125))), to: botID)
        // 8 messages: the last one stays, and the cut is at the start of a turn.
        #expect(model.conversations[botID]?.summaryCoveredCount == 4)
    }

    @Test @MainActor func aFoldCountedPastAMadeUpReplyStillCutsAtTheStartOfATurn() throws {
        let (model, botID) = model(conversation(turns: 10))
        _ = model.contextSummary(for: botID)
        // The engine saw one message more than the conversation holds (a reply made up for an unanswered call): its
        // count of messages is not the conversation's, its count of turns is.
        model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 9, tokensBefore: 1, tokensAfter: 1,
                                                fold: .init(summary: "resumo", ledger: nil, turns: 2))), to: botID)
        let covered = try #require(model.conversations[botID]?.summaryCoveredCount)
        #expect(covered == 8)
        #expect(model.conversations[botID]?.messages[covered].role == .user)
    }

    @Test @MainActor func stepsSetAsideAreAnnouncedButNotKept() throws {
        let (model, botID) = model(conversation(turns: 2))
        _ = model.contextSummary(for: botID)
        model.apply(.compacted(CompactionReport(kind: .steps, foldedMessages: 18, tokensBefore: 60_000, tokensAfter: 40_000)), to: botID)
        #expect(lastNotice(model, botID)?.hasPrefix("Neste pedido, resumi os 18 primeiros passos") == true)
        #expect(model.conversations[botID]?.summary == nil && model.conversations[botID]?.compactions == nil)
    }

    // MARK: Sending

    /// Ten long requests: more than the 128k-token default window can hold once the history share is applied.
    private func hugeConversation() -> Conversation {
        var conversation = Conversation()
        for index in 0..<10 {
            conversation.messages += [.user((index == 0 ? firstRequest + " " : "pedido \(index) ") + String(repeating: "texto ", count: 5_000)),
                                      ChatMessage(role: .assistant, content: "resposta \(index)")]
        }
        return conversation
    }

    @Test @MainActor func sendingAnnouncesTheCompactionOnceAndSavesWhatCameBeforeToMemory() async throws {
        let seeded = hugeConversation()
        let (model, botID) = model(seeded)
        #expect(model.send("e agora, o que falta?", to: botID))
        await waitUntil("the turn to end") { !model.isWorking(botID) }

        let notices = model.transcript(botID).compactMap { item -> String? in
            if case .notice(let text) = item.kind, text.hasPrefix("Compactei a conversa:") { text } else { nil }
        }
        #expect(notices.count == 1)
        #expect(notices.first?.contains("primeiros pedidos viraram um resumo (≈ ") == true)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.summary?.contains("Pedido original: " + firstRequest) == true)
        // The stretch before the message just sent was saved; that message and the notice were not.
        #expect(conversation.memorySavedCount == seeded.messages.count)
        let bank = model.memory.bank(for: botID)
        await waitUntil("the session page") { await bank.snapshot().items.contains { $0.kind == .sessao } }

        // The next message finds the conversation already compacted: no second announcement, no second page.
        #expect(model.send("e depois?", to: botID))
        await waitUntil("the second turn to end") { !model.isWorking(botID) }
        let again = model.transcript(botID).filter { if case .notice(let text) = $0.kind { text.hasPrefix("Compactei a conversa:") } else { false } }
        #expect(again.count == 1)
    }

    @Test @MainActor func aTurnThatFoldedTurnsSavesTheConversationToMemoryWhenItEnds() async throws {
        let (model, botID) = model(conversation(turns: 10))
        #expect(model.send("novo pedido para o projeto", to: botID))
        // Reported by the engine while the turn runs.
        model.apply(.compacted(CompactionReport(kind: .turns, foldedMessages: 8, tokensBefore: 60_000, tokensAfter: 30_000,
                                                fold: .init(summary: "resumo", ledger: nil, turns: 2))), to: botID)
        await waitUntil("the turn to end") { !model.isWorking(botID) }
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.memorySavedCount == conversation.items.count)
    }

    @Test @MainActor func aTurnThatFoldedNothingLeavesTheMemoryForTheIdleTimer() async throws {
        let (model, botID) = model(conversation(turns: 10))
        #expect(model.send("novo pedido para o projeto", to: botID))
        await waitUntil("the turn to end") { !model.isWorking(botID) }
        #expect(model.conversations[botID]?.memorySavedCount == nil)
    }
}
