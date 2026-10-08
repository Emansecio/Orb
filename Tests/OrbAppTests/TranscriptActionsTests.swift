import Foundation
import Testing
@testable import Orb

private struct EchoModel: LLMClient {
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("Pronto."))
            continuation.yield(.finished(.done, nil))
            continuation.finish()
        }
    }
}

/// Notices that offer an action, "Tentar de novo" and "Continuar", the one line of an answered approval, and what
/// VoiceOver says for the transcript.
@Suite("Ações do transcript") struct TranscriptActionsTests {
    // MARK: Which action fits which notice

    @Test func aFailureOffersToTryAgain() {
        #expect(NoticeAction.actions(for: "Não deu certo: Sem conexão com o provedor: tempo esgotado") == [.retry])
        #expect(NoticeAction.actions(for: "Não deu certo: O modelo não respondeu.") == [.retry])
        #expect(NoticeAction.actions(for: "Não deu certo: O provedor está sobrecarregado ou instável (503); tente de novo em instantes.") == [.retry])
    }

    @Test func aProviderOrKeyProblemOpensAjustesFirst() {
        #expect(NoticeAction.actions(for: "Não deu certo: Chave ou login inválido (401). Confira em Ajustes → Modelos.") == [.openSettings, .retry])
        #expect(NoticeAction.actions(for: "Não deu certo: Nenhum modelo configurado. Abra Ajustes → Modelos.") == [.openSettings, .retry])
        #expect(NoticeAction.actions(for: "Não deu certo: O Claude Code não foi encontrado neste Mac. Veja Ajustes → Modelos.") == [.openSettings, .retry])
        #expect(NoticeAction.actions(for: "Conecte um modelo em Ajustes → Modelos para começar.") == [.openSettings])
    }

    /// The notice as the app writes it for a provider error (the real `LLMError` text).
    private func notice(_ error: LLMError) -> String { NoticeAction.failurePrefix + (error.errorDescription ?? "") }

    @Test func aUsageLimitOrServerErrorOnlyOffersToTryAgain() {
        #expect(NoticeAction.actions(for: notice(.http(status: 429, message: "slow down"))) == [.retry])
        #expect(NoticeAction.actions(for: notice(.http(status: 503, message: "overloaded"))) == [.retry])
        #expect(NoticeAction.actions(for: notice(.stream(type: "overloaded_error", message: "x"))) == [.retry])
    }

    @Test func aMissingBalanceTriesAgainFirstAndOffersAjustesSecond() {
        #expect(NoticeAction.actions(for: notice(.http(status: 402, message: "pay"))) == [.retry, .openSettings])
        #expect(NoticeAction.actions(for: notice(.http(status: 401, message: "insufficient balance"))) == [.retry, .openSettings])
    }

    @Test func aBadKeyOpensAjustesFirst() {
        #expect(NoticeAction.actions(for: notice(.http(status: 401, message: "invalid x-api-key"))) == [.openSettings, .retry])
        #expect(NoticeAction.actions(for: notice(.http(status: 403, message: "forbidden"))) == [.openSettings, .retry])
        #expect(NoticeAction.actions(for: notice(.notConfigured)) == [.openSettings, .retry])
    }

    @Test func theProvidersOwnWordsDoNotChooseTheAction() {
        // "login" and "chave" in the provider's text must not turn a rate limit into a settings problem.
        #expect(NoticeAction.actions(for: notice(.http(status: 429, message: "faça login ou troque a chave, ajustes necessários"))) == [.retry])
        #expect(NoticeAction.actions(for: notice(.http(status: 500, message: "chave de cache inválida"))) == [.retry])
    }

    @Test func aPausedOrCutReplyOffersToContinue() {
        #expect(NoticeAction.actions(for: AgentEngine.pausedNotice(after: 30)) == [.continueTurn])
        #expect(NoticeAction.actions(for: "A resposta passou do limite do modelo e foi cortada. Diga “continua” para seguir.") == [.continueTurn])
    }

    @Test func aConversationThatIsTooLongOffersToCompactAndANewOne() {
        let tooLong = "Não deu certo: A conversa ficou grande demais para este modelo. Comece uma conversa nova ou apague o que não precisa."
        #expect(NoticeAction.actions(for: tooLong) == [.compact, .newConversation])
        #expect(NoticeAction.actions(for: tooLong, canCompact: true) == [.compact, .newConversation])
        // A single request has nothing older to summarize: only the new conversation is offered.
        #expect(NoticeAction.actions(for: tooLong, canCompact: false) == [.newConversation])
        #expect(NoticeAction.actions(for: "Não deu certo: O modelo não respondeu.", canCompact: false) == [.retry])
    }

    @Test func aFactTheAppKeptItselfOffersToShowItInMemory() {
        #expect(NoticeAction.actions(for: "Guardado na memória: gosto de café") == [.openMemory])
        #expect(NoticeAction.actions(for: "Não guardei na memória: você negou.").isEmpty)
        #expect(NoticeAction.actions(for: "Não deu para saber o que guardar na memória. Diga, por exemplo: “memorize que …”.").isEmpty)
    }

    @Test func noticesThatOnlyInformOfferNothing() {
        #expect(NoticeAction.actions(for: "Você interrompeu esta resposta").isEmpty)
        #expect(NoticeAction.actions(for: "Conversa compactada: o começo virou um resumo.").isEmpty)
        #expect(NoticeAction.failureDetail(of: "Não deu certo: X") == "X")
        #expect(NoticeAction.failureDetail(of: "Outro aviso") == nil)
    }

    // MARK: What "Tentar de novo" does

    private func user(_ text: String, _ files: [String] = []) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: files)) }
    private func notice(_ text: String) -> TranscriptItem { TranscriptItem(.notice(text)) }

    @Test func aTurnThatFailedBeforeDoingAnythingIsResent() {
        let items = [user("antes"), TranscriptItem(.bot(text: "ok", isStreaming: false)), user("faça isso", ["/tmp/a.txt"]), notice("Não deu certo: x")]
        #expect(RetryPlan.plan(for: items) == .resend(text: "faça isso", attachments: ["/tmp/a.txt"], itemRange: 2..<4))
    }

    @Test func aTurnThatAlreadyAnsweredIsContinuedNotRepeated() {
        let call = ToolCall(kind: .shell, title: "Rodando", detail: "ls")
        #expect(RetryPlan.plan(for: [user("a"), TranscriptItem(.tool(call)), notice("Não deu certo: x")]) == .continueTurn)
        #expect(RetryPlan.plan(for: [user("a"), TranscriptItem(.bot(text: "meio", isStreaming: false)), notice("Não deu certo: x")]) == .continueTurn)
        #expect(RetryPlan.plan(for: [notice("sem mensagem")]) == .none)
        #expect(RetryPlan.plan(for: []) == .none)
    }

    // MARK: The model

    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbTranscriptActions-\(UUID().uuidString)")

    @MainActor private func model(with conversation: Conversation, connected: Bool = true) -> (AppModel, UUID) {
        var state = AppState.initial
        state.bots[0].workingDirectory = root.path
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(directory: root)
        store.save(state)
        store.save(conversation, for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        if connected {
            model.providers = [ProviderAccount(kind: .custom)]
            model.defaultModel = "custom/modelo"
            model.clientOverride = { EchoModel() }
        }
        return (model, model.bots[0].id)
    }

    @MainActor @Test func retryingTakesTheFailedMessageBackAndSendsItOnce() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = Conversation(items: [user("faça isso"), notice("Não deu certo: Sem conexão com o provedor")],
                                  messages: [.user("faça isso")])
        let (model, id) = model(with: failed)
        await model.loadedConversation(id)

        #expect(model.retryLastTurn(id))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }

        let items = model.transcript(id)
        let users = items.compactMap { item -> String? in if case .user(let text, _) = item.kind { text } else { nil } }
        #expect(users == ["faça isso"])
        #expect(!items.contains { if case .notice = $0.kind { true } else { false } })
        let sent = model.conversations[id]?.messages.filter { $0.role == .user }.count
        #expect(sent == 1)
    }

    @MainActor @Test func retryingWithoutAModelLeavesTheConversationAsItWas() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = Conversation(items: [user("faça isso"), notice("Não deu certo: x")], messages: [.user("faça isso")])
        let (model, id) = model(with: failed, connected: false)
        model.providers = []
        await model.loadedConversation(id)

        #expect(!model.retryLastTurn(id))
        let items = model.transcript(id)
        #expect(items.contains { if case .user(let text, _) = $0.kind { text == "faça isso" } else { false } })
        #expect(model.conversations[id]?.messages.count == 1)
    }

    @MainActor @Test func compactingAndTryingAgainSummarizesTheStartAndResendsTheLastMessage() async {
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = Conversation()
        for turn in 0..<6 {
            chat.messages += [.user("pedido \(turn) " + String(repeating: "a", count: 3_500)),
                              ChatMessage(role: .assistant, content: "resposta \(turn) " + String(repeating: "b", count: 3_500))]
            chat.items += [user("pedido \(turn)"), TranscriptItem(.bot(text: "resposta \(turn)", isStreaming: false))]
        }
        chat.messages.append(.user("a pergunta que não coube"))
        chat.items += [user("a pergunta que não coube"), notice("Não deu certo: A conversa ficou grande demais para este modelo.")]
        let (model, id) = model(with: chat)
        await model.loadedConversation(id)

        #expect(model.compactAndRetry(id))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }
        let kept = model.conversations[id]
        #expect(kept?.summary != nil && kept?.compactions == 1)
        let users = model.transcript(id).compactMap { item -> String? in if case .user(let text, _) = item.kind { text } else { nil } }
        #expect(users.last == "a pergunta que não coube" && users.filter { $0 == "a pergunta que não coube" }.count == 1)
        #expect(model.transcript(id).contains { if case .bot(let text, _) = $0.kind { text == "Pronto." } else { false } })
        #expect(!model.transcript(id).contains { if case .notice(let text) = $0.kind { text.hasPrefix("Não deu certo") } else { false } })
        // The notice about the compaction stays, right above the message sent again.
        let items = model.transcript(id)
        let resent = items.lastIndex { if case .user(let text, _) = $0.kind { text == "a pergunta que não coube" } else { false } }
        let compacted = items.lastIndex { if case .notice(let text) = $0.kind { text.hasPrefix("Compactei a conversa") } else { false } }
        #expect(compacted != nil && resent != nil && compacted! < resent!)
        #expect(items.filter { if case .notice(let text) = $0.kind { text.hasPrefix("Compactei a conversa") } else { false } }.count == 1)
    }

    @MainActor @Test func compactingAndTryingAgainDoesNothingWithASingleRequest() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = Conversation(items: [user("só isto"), notice("Não deu certo: A conversa ficou grande demais para este modelo.")],
                                  messages: [.user("só isto")])
        let (model, id) = model(with: failed)
        await model.loadedConversation(id)

        #expect(!model.compactAndRetry(id))
        #expect(model.conversations[id]?.messages.count == 1 && model.conversations[id]?.summary == nil)
        #expect(!model.isWorking(id))
    }

    @MainActor @Test func showingTheMemoryOpensThePanelOnItsTab() {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = model(with: Conversation())
        model.showInspector = false
        model.showMemory(of: id)
        #expect(model.showInspector)
        #expect(model.takeTabRequest(of: id) == .memory)
        #expect(model.takeTabRequest(of: id) == nil)
    }

    @MainActor @Test func continuingSaysContinua() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let paused = Conversation(items: [user("a"), TranscriptItem(.bot(text: "parcial", isStreaming: false)),
                                          notice(AgentEngine.pausedNotice(after: 30))],
                                  messages: [.user("a"), ChatMessage(role: .assistant, content: "parcial")])
        let (model, id) = model(with: paused)
        await model.loadedConversation(id)

        #expect(model.continueTurn(id))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }
        let users = model.transcript(id).compactMap { item -> String? in if case .user(let text, _) = item.kind { text } else { nil } }
        #expect(users == ["a", "continua"])
    }

    // MARK: Answered approvals and speech

    @Test func anAnsweredApprovalIsOneLine() {
        var request = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade\n--greedy", reason: "")
        request.decision = .once
        #expect(ApprovalSummary.label(.once) == "Permitido")
        #expect(ApprovalSummary.label(.deny) == "Negado")
        #expect(ApprovalSummary.label(.always) == "Sempre permitido")
        #expect(ApprovalSummary.title(request) == "Rodando no Terminal")
        #expect(ApprovalSummary.detail(request) == "brew upgrade --greedy")

        request.decision = .deny
        request.note = "use a lixeira"
        #expect(ApprovalSummary.detail(request) == "Você disse: use a lixeira")

        let batch = ApprovalRequest(toolName: "batch", title: "3 ações", command: "", reason: "",
                                    items: [ApprovalItem(toolName: "w", title: "Gravando arquivo", command: "a.txt"),
                                            ApprovalItem(toolName: "w", title: "Gravando arquivo", command: "b.txt"),
                                            ApprovalItem(toolName: "r", title: "Rodando", command: "ls")])
        #expect(ApprovalSummary.title(batch) == "3 ações")
        #expect(ApprovalSummary.detail(batch) == "a.txt e mais 2")
    }

    @Test func theScreenReaderSaysWhoSpoke() {
        #expect(TranscriptSpeech.user(text: "oi", attachmentCount: 0) == "Você: oi")
        #expect(TranscriptSpeech.user(text: "veja", attachmentCount: 1) == "Você: veja, com 1 anexo")
        #expect(TranscriptSpeech.user(text: "veja", attachmentCount: 3) == "Você: veja, com 3 anexos")
        #expect(TranscriptSpeech.reply(of: "Atlas") == "Resposta de Atlas")
        #expect(TranscriptSpeech.notice("Pausei") == "Aviso: Pausei")
        #expect(TranscriptSpeech.approval(botName: "Atlas", title: "Rodando no Terminal") == "Atlas pede permissão: Rodando no Terminal")
    }
}
