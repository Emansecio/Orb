import Foundation
import Testing
import UserNotifications
@testable import Orb

// The hand-off of `browse_show`: the Orb opens its browser in a window for something only the person can do, shows a card in the
// chat ("Pronto" / "Cancelar") and waits like it does for an approval; the tool then gives the model the person's answer.

/// A model that plays one scripted answer per call.
private actor HandoffScript {
    private var responses: [[LLMEvent]]
    init(_ responses: [[LLMEvent]]) { self.responses = responses }
    func next() -> [LLMEvent] { responses.isEmpty ? [.text("fim")] : responses.removeFirst() }
}

private struct HandoffLLM: LLMClient {
    let script: HandoffScript

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.next() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

struct BrowserHandoffEngineTests {
    private let setup = FakeBrowserSetup()
    private let showCall = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: "browse_show", arguments: "{}")])

    private func request(mode: PermissionMode = .bypass) -> TurnRequest {
        let bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), permissionMode: mode)
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "entre no site",
                           client: HandoffLLM(script: HandoffScript([[showCall], [.text("Pronto, entrei.")]])),
                           tools: ToolBox.browseTools, context: setup.context())
    }

    /// Plays the turn; `onApproval` is the person (or the app) answering the cards.
    private func drive(_ engine: AgentEngine, _ request: TurnRequest,
                       onApproval: @Sendable (ApprovalRequest) async -> Void) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in engine.run(request) {
            events.append(event)
            if case .approval(let approval) = event { await onApproval(approval) }
        }
        return events
    }

    private func cards(_ events: [TurnEvent]) -> [ApprovalRequest] {
        events.compactMap { if case .approval(let card) = $0 { card } else { nil } }
    }

    private func toolResult(_ events: [TurnEvent]) -> String? {
        events.compactMap { event -> String? in
            if case .message(let message) = event, message.role == .tool { message.content } else { nil }
        }.first
    }

    private func toolFinished(_ events: [TurnEvent]) -> ToolCall.State? {
        events.compactMap { event -> ToolCall.State? in
            if case .toolFinished(_, let state, _, _) = event { state } else { nil }
        }.first
    }

    // MARK: Pronto

    @Test func theCardWaitsAndProntoLetsTheModelContinueWithTheWindowOpen() async {
        let engine = AgentEngine()
        let turn = request()
        let events = await drive(engine, turn) { card in
            // The turn is stopped on the card, like on an approval: the gate holds it for this Orb.
            #expect(await engine.gate.openIDs(for: turn.bot.id) == [card.id])
            await engine.gate.resolve(approvalID: card.id, decision: .once)
        }
        let card = cards(events).first
        #expect(cards(events).count == 1 && card?.isHandoff == true)
        #expect(card?.title == "Atlas abriu o navegador para você" && card?.command == "https://example.com/ — “Example”")
        #expect(card?.reason.contains("Pronto") == true && card?.suggestions.isEmpty == true && card?.toolName == "browse_show")

        // The tool returned success: the model is told to look at the page again.
        let result = toolResult(events) ?? ""
        #expect(result.hasPrefix("The user says they are done") && result.contains("browse_snapshot"))
        #expect(toolFinished(events) == .done)
        #expect(setup.driver.calls == ["setHeaded true"], "the window stays open for the next step: \(setup.driver.calls)")
        #expect(setup.hub.existingSession(botID: setup.botID)?.isShowingWindow == true)
    }

    @Test func theWorkLineSaysItIsWaitingForYouWhileTheCardIsOpen() async {
        let engine = AgentEngine()
        let turn = request()
        var statuses: [String] = []
        for await event in engine.run(turn) {
            if case .status(let text) = event { statuses.append(text) }
            if case .approval(let card) = event { await engine.gate.resolve(approvalID: card.id, decision: .once) }
        }
        let waiting = statuses.firstIndex(of: "Esperando sua resposta")
        #expect(waiting != nil)
        // Back to the tool's own line once the person answered.
        #expect(statuses.dropFirst((waiting ?? 0) + 1).first == "Mostrando o navegador para você")
    }

    // MARK: Cancelar and Parar

    @Test func cancelarGivesTheModelTheDeclineAndClosesTheWindow() async {
        let engine = AgentEngine()
        let events = await drive(engine, request()) { card in
            await engine.gate.resolve(approvalID: card.id, decision: .deny)
        }
        let result = toolResult(events) ?? ""
        #expect(result.contains("cancelled") && result.contains("Do not retry"))
        #expect(toolFinished(events) == .failed)
        #expect(setup.driver.calls == ["setHeaded true", "setHeaded false"])
        #expect(setup.hub.existingSession(botID: setup.botID)?.isShowingWindow == false)
    }

    /// Parar for real: `AppModel.stop` cancels the task that is running the turn first and answers the open cards after, so the tool
    /// finds its own task cancelled when the card gives up. A cancelled task cannot run the command that closes the window, so the
    /// tool hides it from a task of its own.
    @Test func stoppingTheOrbAnswersTheOpenCardWithACancelAndHidesTheWindow() async throws {
        let engine = AgentEngine()
        let turn = request()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in engine.run(turn) { count += 1 }
            return count
        }
        await waitUntil("the card to open") { await engine.gate.openIDs(for: turn.bot.id).count == 1 }
        #expect(setup.driver.calls == ["setHeaded true"])
        consumer.cancel() // the task of the turn, not only its cards
        await waitUntil("the window to be hidden") { setup.driver.calls.contains("setHeaded false") }
        #expect(setup.driver.calls == ["setHeaded true", "setHeaded false"])
        let session = try #require(setup.hub.existingSession(botID: setup.botID))
        await waitUntil("the Orb to know it is hidden") { !session.isShowingWindow }
        await engine.gate.cancelApprovals(for: turn.bot.id) // and then the cards, as `stop` does
        _ = await consumer.value
        #expect(await engine.gate.openIDs(for: turn.bot.id).isEmpty)
    }

    /// The other way to end the card: the cards are answered without the task being cancelled (a mode change never does it, but
    /// the gate can).
    @Test func aCardAnsweredWithACancelGivesTheModelTheDecline() async {
        let engine = AgentEngine()
        let turn = request()
        let events = await drive(engine, turn) { _ in
            await engine.gate.cancelApprovals(for: turn.bot.id)
        }
        #expect((toolResult(events) ?? "").contains("cancelled"))
    }

    @Test func cancellingTheTaskWhileTheCardIsOpenCancelsIt() async {
        let gate = ApprovalGate()
        let botID = UUID()
        let waiting = Task { await gate.handoff(page: "https://a.test/", botName: "Atlas", botID: botID) { _ in } }
        await waitUntil("the card to open") { await gate.openIDs(for: botID).count == 1 }
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    // MARK: Permissions

    @Test func inPerguntarAntesThePermissionCardComesFirstAndTheHandoffCardAfterIt() async {
        let engine = AgentEngine()
        let events = await drive(engine, request(mode: .ask)) { card in
            await engine.gate.resolve(approvalID: card.id, decision: .once)
        }
        let asked = cards(events)
        #expect(asked.map(\.isHandoff) == [false, true])
        #expect(asked.map(\.title) == ["Mostrando o navegador para você", "Atlas abriu o navegador para você"])
        #expect(toolResult(events)?.hasPrefix("The user says they are done") == true)
    }

    @Test func aChangeOfPermissionModeNeverAnswersTheHandoff() async {
        let engine = AgentEngine()
        let turn = request()
        let events = await drive(engine, turn) { card in
            for mode in PermissionMode.allCases {
                let answered = await engine.gate.applyModeChange(to: mode, for: turn.bot.id)
                #expect(answered.isEmpty, "\(mode)")
            }
            #expect(await engine.gate.openIDs(for: turn.bot.id) == [card.id])
            await engine.gate.resolve(approvalID: card.id, decision: .once)
        }
        #expect(toolFinished(events) == .done)
    }

    @Test func withoutAHandlerTheToolFallsBackToTellingTheModelToAskAndStop() async throws {
        // A caller with nobody to answer (no engine around the tool): the old behavior.
        let text = try await BrowseShowTool().run(.object([:]), context: setup.context())
        #expect(text.contains("STOP") && text.contains("tell the user"))
    }
}

// MARK: - The card in the app

@Suite final class BrowserHandoffModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbHandoff-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func model() -> AppModel {
        var state = AppState.initial
        state.bots.append(Bot(name: "Atlas", role: "", orb: OrbConfig()))
        Store(directory: root).save(state)
        return AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    private func card() -> ApprovalRequest { .handoff(botName: "Atlas", page: "https://site.test/entrar") }

    @Test @MainActor func theOrbWaitsForYouAndTheMenuBarListsTheCard() async {
        let model = model()
        let botID = model.bots[0].id
        let handoff = card()
        await model.gate.open(handoff.id, botID: botID, alwaysAsks: true, isHandoff: true)
        model.apply(.approval(handoff), to: botID)
        #expect(model.needsYou(botID) && model.waitingIDs.contains(botID))
        #expect(model.pendingApprovals.map(\.request.id) == [handoff.id] && model.pendingApprovals.first?.request.isHandoff == true)
        #expect(model.newestPendingApprovalID(of: botID) == handoff.id)
    }

    @Test @MainActor func prontoAndCancelarAreRecordedAsSuchAndAnswerTheEngine() async {
        let model = model()
        let botID = model.bots[0].id
        let done = card(), cancelled = card()
        for card in [done, cancelled] {
            await model.gate.open(card.id, botID: botID, alwaysAsks: true, isHandoff: true)
            model.apply(.approval(card), to: botID)
        }
        let waitingForDone = Task { await model.gate.wait(for: done.id) }
        let waitingForCancel = Task { await model.gate.wait(for: cancelled.id) }
        model.decide(.once, approvalID: done.id, botID: botID)
        model.decide(.deny, approvalID: cancelled.id, botID: botID)
        let (first, second) = await (waitingForDone.value, waitingForCancel.value)
        #expect(first.decision == .once && second.decision == .deny)

        let items = model.transcript(botID).compactMap { item -> ApprovalRequest? in
            if case .approval(let request) = item.kind { request } else { nil }
        }
        #expect(items.map { ApprovalSummary.label($0) } == ["Pronto", "Cancelado"])
        #expect(!model.needsYou(botID))
    }

    @Test func theRecordOfAnOrdinaryCardKeepsItsWords() {
        var card = ApprovalRequest(toolName: "run_command", title: "Rodando", command: "ls", reason: "")
        card.decision = .once
        #expect(ApprovalSummary.label(card) == "Permitido")
        card.decision = .deny
        #expect(ApprovalSummary.label(card) == "Negado")
    }

    @Test func theCardSurvivesBeingSavedAndOldCardsDecodeAsOrdinary() throws {
        var original = card()
        original.decision = .deny
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(original))
        #expect(decoded == original && decoded.isHandoff)
        let old = #"{"id":"5F7E1D3A-0000-4000-8000-000000000001","toolName":"run_command","title":"T","command":"ls","reason":""}"#
        #expect(try !JSONDecoder().decode(ApprovalRequest.self, from: Data(old.utf8)).isHandoff)
    }
}

// MARK: - The banner

struct BrowserHandoffNotificationTests {
    @Test func theBannerSaysWhereTheOrbStoppedAndOffersProntoAndCancelar() throws {
        let botID = UUID(), card = ApprovalRequest.handoff(botName: "Atlas", page: "https://site.test/entrar")
        let payload = ApprovalNotifications.payload(botName: "Atlas", botID: botID, request: card)
        #expect(payload.title == "Atlas" && payload.category == ApprovalNotifications.handoffCategory)
        #expect(payload.body == "Atlas abriu o navegador para você: https://site.test/entrar")
        #expect(payload.userInfo == ["botID": botID.uuidString, "approvalID": card.id.uuidString])

        let category = try #require(ApprovalNotifications.categories().first { $0.identifier == ApprovalNotifications.handoffCategory })
        #expect(category.actions.map(\.title) == ["Pronto", "Cancelar"])
        // The same two actions as an approval, so a tap answers the same way: Pronto is the "once", Cancelar the denial.
        #expect(category.actions.map(\.identifier) == [ApprovalNotifications.allowAction, ApprovalNotifications.denyAction])
        #expect(!category.actions[0].options.contains(.authenticationRequired))
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.allowAction, userInfo: payload.userInfo)
                == .decide(.once, botID: botID, approvalID: card.id))
        #expect(ApprovalNotifications.route(actionIdentifier: ApprovalNotifications.denyAction, userInfo: payload.userInfo)
                == .decide(.deny, botID: botID, approvalID: card.id))
    }

    @Test func itBannersLikeAnyCardOnlyWhenYouAreNotLookingAtIt() {
        let bot = UUID()
        #expect(ApprovalNotifications.shouldPost(appIsActive: false, selectedBotID: bot, botID: bot, enabled: true))
        #expect(!ApprovalNotifications.shouldPost(appIsActive: true, selectedBotID: bot, botID: bot, enabled: true))
        #expect(ApprovalNotifications.shouldPost(appIsActive: true, selectedBotID: UUID(), botID: bot, enabled: true))
    }
}
