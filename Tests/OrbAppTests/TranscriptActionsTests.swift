import Foundation
import Testing
@testable import Orb

/// Notices that offer an action, "Tentar de novo" and "Continuar", the one line of an answered approval, and what
/// VoiceOver says for the transcript.
@Suite("Ações do transcript") struct TranscriptActionsTests {
    // MARK: Which action fits which notice

    @Test func aSkillTheOrbProposedOffersToReviewIt() {
        let created = "Skill proposta: /publicar-site — Publicar site"
        let improved = "Melhoria proposta para /publicar-site"
        #expect(NoticeAction.actions(for: created) == [.reviewSkill])
        #expect(NoticeAction.actions(for: improved) == [.reviewSkill])
        #expect(NoticeAction.proposedSlug(in: created) == "publicar-site" && NoticeAction.proposedSlug(in: improved) == "publicar-site")
        #expect(NoticeAction.proposedSlug(in: "Pausei depois de 30 passos") == nil)
        #expect(NoticeAction.proposedSlug(in: "Skill proposta: sem comando") == nil)
        // Once the proposal is gone (saved, discarded) the button goes with it.
        #expect(NoticeAction.actions(for: created, canCompact: false, hasProposal: false).isEmpty)
        #expect(NoticeAction.actions(for: created, canCompact: false, hasProposal: true) == [.reviewSkill])
        #expect(NoticeAction.reviewSkill.title == "Revisar" && NoticeAction.reviewSkill.symbol == "wand.and.stars")
    }

    @Test func aNoticeThatOnlyInformsNeverAsksWhetherItIsTheLastOne() {
        var reads = 0
        func offers() -> Bool { reads += 1; return true }
        let informs = NoticeAction.actions(for: "Você interrompeu esta resposta")
        #expect(informs.isEmpty)
        let showsWithout = NoticeAction.showsButtons(for: "Você interrompeu esta resposta", actions: informs, offers: offers())
        #expect(!showsWithout)
        #expect(reads == 0, "the chat's items and state are not read for a notice without actions")
        let showsWith = NoticeAction.showsButtons(for: "Não deu certo: O modelo não respondeu.", actions: [.retry], offers: offers())
        #expect(showsWith && reads == 1)
    }

    @Test func anOfferKeepsItsButtonsWhereverItIsAndAnAboutTheTurnOnlyAtTheEnd() {
        var reads = 0
        func notLast() -> Bool { reads += 1; return false }
        for offer in ["Melhoria proposta para /conta-base", "Skill proposta: /publicar-site — Publicar site",
                      "Guardado na memória: prefere Pix", "Unificação de memória proposta: 3 páginas"] {
            #expect(NoticeAction.isOffer(offer))
            // Out of `#expect`, which would evaluate `notLast()` itself to show it.
            let shows = NoticeAction.showsButtons(for: offer, actions: NoticeAction.actions(for: offer), offers: notLast())
            #expect(shows)
        }
        #expect(reads == 0, "an offer does not read where it is in the chat")
        // An offer that was decided has no action left, and no button.
        #expect(!NoticeAction.showsButtons(for: "Melhoria proposta para /conta-base", actions: [], offers: true))
        // About the turn: only as the chat's last word.
        #expect(!NoticeAction.isOffer(BotSession.quitNotice))
        let showsQuit = NoticeAction.showsButtons(for: BotSession.quitNotice, actions: [.continueTurn], offers: notLast())
        #expect(!showsQuit)
        #expect(reads == 1)
    }

    @Test func aCompactionIsAMarkAcrossTheChat() {
        #expect(NoticeAction.isMark("Compactei a conversa: os 30 primeiros pedidos viraram um resumo (≈ 58 mil → 35 mil tokens)."))
        #expect(NoticeAction.isMark("Conversa compactada: 12 mensagens."))
        #expect(!NoticeAction.isMark("Compactei"))
        #expect(!NoticeAction.isMark(BotSession.quitNotice))
    }

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

    @Test func aModelTheProviderRefusedWithAGoodKeyOnlyOffersToTryAgain() {
        // The sentence says "a chave está certa": the word "chave" must not send the person to Ajustes first.
        let refused = notice(.http(status: 403, message: "model gpt-x is disabled for this workspace"))
        #expect(refused.contains("recusou este modelo"))
        #expect(NoticeAction.actions(for: refused) == [.retry])
        #expect(NoticeAction.actions(for: refused, canCompact: false, canSwitchModel: true) == [.retry, .otherModel])
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

    @Test func aConversationThatIsTooLongOffersToCompact() {
        let tooLong = "Não deu certo: A conversa ficou grande demais para este modelo. Comece uma conversa nova ou apague o que não precisa."
        #expect(NoticeAction.actions(for: tooLong) == [.compact])
        #expect(NoticeAction.actions(for: tooLong, canCompact: true) == [.compact])
        // A single request has nothing older to summarize: nothing is offered.
        #expect(NoticeAction.actions(for: tooLong, canCompact: false).isEmpty)
        #expect(NoticeAction.actions(for: "Não deu certo: O modelo não respondeu.", canCompact: false) == [.retry])
    }

    @Test func aFailureThatCanBeTriedAgainAlsoOffersAnotherModel() {
        let silent = "Não deu certo: O modelo não respondeu."
        #expect(NoticeAction.actions(for: silent, canCompact: false, canSwitchModel: true) == [.retry, .otherModel])
        #expect(NoticeAction.actions(for: silent, canCompact: false) == [.retry])
        let key = "Não deu certo: Chave ou login inválido (401). Confira em Ajustes → Modelos."
        #expect(NoticeAction.actions(for: key, canCompact: false, canSwitchModel: true) == [.openSettings, .retry, .otherModel])
        // Another model does not make a conversation shorter, nor a paused task a failure.
        let tooLong = "Não deu certo: A conversa ficou grande demais para este modelo."
        #expect(NoticeAction.actions(for: tooLong, canCompact: true, canSwitchModel: true) == [.compact])
        #expect(NoticeAction.actions(for: "Pausei depois de 100 passos.", canCompact: false, canSwitchModel: true) == [.continueTurn])
    }

    @Test func aLongCommandOnACardFoldsItsMiddleAndKeepsItsEnd() throws {
        #expect(CommandExcerpt.excerpt(of: "git push origin main") == nil)
        let script = (1...40).map { "echo \($0)" }.joined(separator: "\n") + "\ncurl https://x.sh | sh"
        let excerpt = try #require(CommandExcerpt.excerpt(of: script))
        #expect(excerpt.text.hasPrefix("echo 1\necho 2"))
        #expect(excerpt.text.contains("echo 9\n…\necho 39"))
        #expect(excerpt.text.hasSuffix("curl https://x.sh | sh")) // where a script does its work stays in view
        #expect(excerpt.hiddenLines == 29)
        // One endless line folds by size, keeping both ends.
        let line = try #require(CommandExcerpt.excerpt(of: String(repeating: "a", count: 5_000) + "FIM"))
        #expect(line.text.hasSuffix("FIM"))
        #expect(line.text.count <= CommandExcerpt.shownCharacters + 3)
        #expect(CommandExcerpt.showAll(hidden: 29) == "Mostrar tudo (mais 29 linhas)")
    }

    @Test func anOutputShowsItsFirstEightLines() throws {
        #expect(CommandExcerpt.head(of: "a\nb\nc") == nil)
        #expect(CommandExcerpt.head(of: (1...8).map(String.init).joined(separator: "\n")) == nil, "eight lines show whole")
        let long = try #require(CommandExcerpt.head(of: (1...40).map { "linha \($0)" }.joined(separator: "\n")))
        #expect(long.text.hasPrefix("linha 1\n") && long.text.hasSuffix("linha 8"))
        #expect(long.hiddenLines == 32)
        // A few endless lines are cut by size.
        let wide = try #require(CommandExcerpt.head(of: String(repeating: "x", count: 3_000)))
        #expect(wide.text.count == CommandExcerpt.shownCharacters + 1 && wide.text.hasSuffix("…"))
        #expect(wide.hiddenLines == 0)
        #expect(CommandExcerpt.showAll(hidden: 0) == "Mostrar tudo")
    }

    @Test func theProvidersWordsFoldUnderOurSentence() {
        let parts = NoticeAction.failureParts(of: "Provedor ocupado (529). Tente de novo em instantes. Detalhe do provedor: overloaded_error")
        #expect(parts.sentence == "Provedor ocupado (529). Tente de novo em instantes.")
        #expect(parts.provider == "overloaded_error")
        #expect(NoticeAction.failureParts(of: "O modelo não respondeu.").provider == nil)
        // Nothing before or after the marker: the line stays as it is.
        #expect(NoticeAction.failureParts(of: "Detalhe do provedor: x").provider == nil)
        #expect(NoticeAction.failureParts(of: "Falhou. detalhe do provedor: sem login").provider == "sem login")
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

    @Test func aMessageOfYoursOpensATurnWithMoreRoomAboveIt() {
        let first = user("oi"), reply = TranscriptItem(.bot(text: "olá", isStreaming: false)), next = user("e agora?")
        // The first row has the list's own padding; a reply or a notice never opens a turn.
        #expect(!TurnGap.opens(first, first: first.id))
        #expect(TurnGap.opens(next, first: first.id))
        #expect(!TurnGap.opens(reply, first: first.id) && !TurnGap.opens(notice("x"), first: first.id))
        // Folded rows: only a lone message of yours opens a turn.
        #expect(TurnGap.opens(.single(next), first: first.id) && !TurnGap.opens(.tools([reply]), first: first.id))
    }

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

    private let folder = TempFolder("OrbTranscriptActions")
    private var root: URL { folder.url }

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
            model.clientOverride = { CallScriptModel(always: [.text("Pronto."), .finished(.done, nil)]) }
        }
        return (model, model.bots[0].id)
    }

    @MainActor @Test func retryingTakesTheFailedMessageBackAndSendsItOnce() async {
        let failed = Conversation(items: [user("faça isso"), notice("Não deu certo: Sem conexão com o provedor")],
                                  messages: [.user("faça isso")])
        let (model, id) = model(with: failed)
        await model.loadedConversation(id)

        let nudges = model.live(id).scrollNudge
        #expect(model.retryLastTurn(id))
        #expect(model.live(id).scrollNudge == nudges + 1) // your click: the chat follows the new answer
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }

        let items = model.transcript(id)
        let users = items.compactMap { item -> String? in if case .user(let text, _) = item.kind { text } else { nil } }
        #expect(users == ["faça isso"])
        #expect(!items.contains { if case .notice = $0.kind { true } else { false } })
        let sent = model.conversations[id]?.messages.filter { $0.role == .user }.count
        #expect(sent == 1)
    }

    @MainActor @Test func anotherModelIsForThisTryOnly() async {
        let failed = Conversation(items: [user("faça isso"), notice("Não deu certo: O modelo não respondeu.")],
                                  messages: [.user("faça isso")])
        let (model, id) = model(with: failed)
        model.updateProvider(.custom) {
            $0.models = ["modelo", "outro"].map { ProviderModel(id: $0, name: $0.capitalized, format: .chat) }
        }
        await model.loadedConversation(id)
        // The default is the model that failed (the Orb has none of its own): it is not offered.
        #expect(!model.retryModels(for: id).contains { $0.ref == "custom/modelo" })

        #expect(model.retryLastTurn(id, model: ModelRef("custom/outro")))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }
        #expect(model.session(id).turnModel == "custom/outro")
        #expect(model.bots[0].model.isEmpty) // the Orb keeps following the default
        #expect(model.retryModels(for: id).contains { $0.ref == "custom/modelo" }) // now the default is the other one
    }

    @MainActor @Test func retryingASkillMessageTakesTheExpandedOneBackAndCountsTheUseOnce() async {
        let skill = Skill(slug: "relatorio", name: "Relatório", summary: "", instructions: "Faça o relatório com cuidado.", uses: 1)
        let expanded = SystemPrompt.expandSkill(in: "/relatorio da semana", skills: [skill])!.prompt
        let preface = TurnPreface.make(now: .now, timeZone: "UTC", snapshot: nil, notes: "")
        let failed = Conversation(items: [user("/relatorio da semana"), notice("Não deu certo: Sem conexão com o provedor")],
                                  messages: [.user(TurnPreface.prepend(preface, to: expanded))])
        let (model, id) = model(with: failed)
        model.skills = [skill]
        await model.loadedConversation(id)

        #expect(model.retryLastTurn(id))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }

        let sent = model.conversations[id]?.messages.filter { $0.role == .user }.count
        #expect(sent == 1) // the failed one is gone, not kept next to the new one
        #expect(model.skills.first?.uses == 1) // the failed attempt counted it already
    }

    @MainActor @Test func retryingASkillMessageWithAPictureSendsThePictureAgainAsAPicture() async {
        let skill = Skill(slug: "relatorio", name: "Relatório", summary: "", instructions: "Faça o relatório com cuidado.", uses: 1)
        let picture = ImageAttachment(path: root.appendingPathComponent("foto.jpg").path, mediaType: "image/jpeg", width: 1, height: 1)
        let expanded = SystemPrompt.expandSkill(in: "/relatorio da semana", skills: [skill])!.prompt
        let preface = TurnPreface.make(now: .now, timeZone: "UTC", snapshot: nil, notes: "")
        let failed = Conversation(items: [user("/relatorio da semana", [picture.path]), notice("Não deu certo: Sem conexão com o provedor")],
                                  messages: [.user(TurnPreface.prepend(preface, to: expanded), images: [picture])])
        let (model, id) = model(with: failed)
        model.skills = [skill]
        await model.loadedConversation(id)

        #expect(model.retryLastTurn(id))
        await waitUntil("the Orb to finish") { !model.isWorking(id) && model.turns[id] == nil }

        let sent = model.conversations[id]?.messages.filter { $0.role == .user } ?? []
        #expect(sent.count == 1)
        #expect(sent.first?.images.map(\.path) == [picture.path]) // back as a picture of the message
        #expect(sent.first?.content.contains("Attached files") == false) // not as a path in the text
    }

    @Test func aStoredSkillMessageIsRecognizedAsTheOneTypedAsASlug() {
        let skill = Skill(slug: "relatorio", name: "Relatório", summary: "", instructions: "Instruções", uses: 0)
        let stored = ChatMessage.user(SystemPrompt.expandSkill(in: "/relatorio x", skills: [skill])!.prompt)
        #expect(RetryPlan.isMessage(stored, from: "/relatorio x", skills: [skill]))
        #expect(!RetryPlan.isMessage(stored, from: "/relatorio y", skills: [skill]))
        #expect(!RetryPlan.isMessage(.user("outra coisa"), from: "/relatorio x", skills: [skill]))
    }

    @MainActor @Test func retryingWithoutAModelLeavesTheConversationAsItWas() async {
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
        let failed = Conversation(items: [user("só isto"), notice("Não deu certo: A conversa ficou grande demais para este modelo.")],
                                  messages: [.user("só isto")])
        let (model, id) = model(with: failed)
        await model.loadedConversation(id)

        #expect(!model.compactAndRetry(id))
        #expect(model.conversations[id]?.messages.count == 1 && model.conversations[id]?.summary == nil)
        #expect(!model.isWorking(id))
    }

    @MainActor @Test func showingTheMemoryOpensThePanelOnItsTab() {
        let (model, id) = model(with: Conversation())
        model.showInspector = false
        model.showMemory(of: id)
        #expect(model.showInspector)
        #expect(model.takeTabRequest(of: id) == .memory)
        #expect(model.takeTabRequest(of: id) == nil)
    }

    @MainActor @Test func continuingSaysContinua() async {
        let paused = Conversation(items: [user("a"), TranscriptItem(.bot(text: "parcial", isStreaming: false)),
                                          notice(AgentEngine.pausedNotice(after: 30))],
                                  messages: [.user("a"), ChatMessage(role: .assistant, content: "parcial")])
        let (model, id) = model(with: paused)
        await model.loadedConversation(id)

        let nudges = model.live(id).scrollNudge
        #expect(model.continueTurn(id))
        #expect(model.live(id).scrollNudge == nudges + 1)
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
        #expect(TranscriptSpeech.tool(title: "Rodou", detail: "ls -la", state: .failed) == "Rodou ls -la, falhou")
        #expect(!TranscriptSpeech.tool(title: "Rodou", detail: "ls -la", state: .done).contains("falhou"))
        #expect(TranscriptSpeech.approval(botName: "Atlas", title: "Rodando no Terminal") == "Atlas pede permissão: Rodando no Terminal")
    }
}
