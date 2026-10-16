import Foundation
import Testing
@testable import Orb

// Orbs asking each other for work, end to end with a model that is a script: who asks whom, who is woken by what, what stops it.

private actor Counter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

/// What one model call was sent.
private struct Seen: Sendable {
    var who: String
    var user: String
    /// The result of the tool call the model is answering, when it is the second step of a turn.
    var toolResult: String?
    var tools: [String]
}

private actor Log {
    private(set) var seen: [Seen] = []
    func record(_ item: Seen) { seen.append(item) }
    func calls(by who: String) -> [Seen] { seen.filter { $0.who == who } }
    func count(by who: String) -> Int { seen.filter { $0.who == who }.count }
}

/// One model for every Orb: it knows who is speaking from the system prompt, and `rule` decides the answer.
private struct Brain: LLMClient {
    let log: Log
    let rule: @Sendable (Seen) async -> [LLMEvent]

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let system = messages.first { $0.role == .system }?.content ?? ""
        let who = ["Atlas", "Pesquisador", "Revisor"].first { system.contains("You are \($0),") } ?? "?"
        let user = messages.last { $0.role == .user }?.content ?? ""
        let result = messages.last?.role == .tool ? messages.last?.content : nil
        let seen = Seen(who: who, user: user, toolResult: result, tools: tools.map(\.name))
        return AsyncThrowingStream { continuation in
            Task {
                await log.record(seen)
                let events = await rule(seen)
                for event in events { continuation.yield(event) }
                let calls = events.contains { if case .toolCalls = $0 { true } else { false } }
                continuation.yield(.finished(calls ? .toolUse : .done, nil))
                continuation.finish()
            }
        }
    }
}

private func orbsCall(_ action: String, to: String, _ message: String, id: String = "c1") -> [LLMEvent] {
    let arguments = JSONValue.object(["action": .string(action), "to": .string(to), "message": .string(message)]).jsonString
    return [.toolCalls([ToolCallRequest(id: id, name: "orbs", arguments: arguments)])]
}

private func say(_ text: String) -> [LLMEvent] { [.text(text)] }

@MainActor
private final class Team {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbDelegation-\(UUID().uuidString)")
    let model: AppModel
    let log = Log()
    let suite = "OrbDelegation-\(UUID().uuidString)"
    var atlas: Bot, pesquisador: Bot, revisor: Bot

    init(modes: [PermissionMode] = [.ask, .ask, .ask], rule: @escaping @Sendable (Seen) async -> [LLMEvent]) {
        QuietNotifications.hold()
        func make(_ root: URL, _ name: String, _ role: String, _ mode: PermissionMode, color: String) -> Bot {
            var bot = Bot(name: name, role: role, orb: OrbConfig())
            bot.orb.color = color
            bot.permissionMode = mode
            bot.workingDirectory = root.appending(path: "pasta-\(name)").path
            try? FileManager.default.createDirectory(atPath: bot.workingDirectory, withIntermediateDirectories: true)
            return bot
        }
        atlas = make(root, "Atlas", "Coordena o trabalho", modes[0], color: "indigo")
        pesquisador = make(root, "Pesquisador", "Pesquisa e resume", modes[1], color: "teal")
        revisor = make(root, "Revisor", "Revisa o que foi feito", modes[2], color: "rose")
        var state = AppState.initial
        state.bots = [atlas, pesquisador, revisor]
        state.routines = []
        let store = Store(directory: root)
        store.save(state)
        for bot in state.bots { store.save(Conversation(), for: bot.id) }
        store.flush()
        model = AppModel(store: store, runsBackgroundWork: false)
        model.preferences = UserDefaults(suiteName: suite) ?? .standard // the switch of Ajustes is this test's own
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let brain = Brain(log: log, rule: rule)
        model.clientOverride = { brain }
    }

    deinit { QuietNotifications.release() }

    func cleanUp() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        removeTestFolder(root)
    }

    func items(_ bot: Bot) -> [TranscriptItem] { model.transcript(bot.id) }

    func botTexts(_ bot: Bot) -> [String] {
        items(bot).compactMap { if case .bot(let text, _) = $0.kind { text } else { nil } }
    }

    func orbMessages(_ bot: Bot) -> [OrbMessageItem] {
        items(bot).compactMap { if case .orbMessage(let message) = $0.kind { message } else { nil } }
    }

    func events(_ bot: Bot) -> [OrbEvent] {
        items(bot).compactMap { if case .event(let event) = $0.kind { event } else { nil } }
    }

    /// Nobody works, nothing waits: every turn is over and the hub holds no open request or answer.
    func isSettled() -> Bool {
        let hub = model.delegation
        return [atlas, pesquisador, revisor].allSatisfy { model.sessions[$0.id]?.turnTask == nil && !hub.isStarting($0.id) }
            && !hub.requests.values.contains { DelegationHub.isOpen($0.state) } && hub.inbox.isEmpty
            && !model.isStartingRoutine
    }

    func settle() async { await waitUntil("every turn to end") { self.isSettled() } }

    func request(from: Bot, to: Bot) -> DelegationRequest? {
        model.delegation.requests.values.filter { $0.envelope.from.id == from.id && $0.envelope.to.id == to.id }
            .sorted(by: DelegationHub.older).first
    }
}

@MainActor
private final class Hooks: GroupTurnHooks {
    var started: [UUID] = []
    var finished: [(reply: String?, outcome: OrbEnvelope.ReplyStatus)] = []
    func prompt(for request: DelegationRequest, member: UUID) async -> String { "Sua vez no grupo: \(request.envelope.text)" }
    func turnStarted(_ request: DelegationRequest) { started.append(request.id) }
    func turnFinished(_ request: DelegationRequest, reply: String?, outcome: OrbEnvelope.ReplyStatus) { finished.append((reply, outcome)) }
}

@Suite @MainActor struct DelegationHubTests {
    // MARK: Asking, answering, waking

    @Test func anAnswerWakesTheAskerWithTheRepliesEnvelope() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("O Pesquisador achou 42.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise o número.")
            case "Pesquisador": return say("Achei 42.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça ao Pesquisador", to: team.atlas.id, fromUser: true)
        await waitUntil("the asker to answer the person") { team.botTexts(team.atlas).contains("O Pesquisador achou 42.") }
        await team.settle()

        // The asker's chat: the person's bubble, the request sent (and answered), the reply that woke it.
        let lines = team.orbMessages(team.atlas)
        #expect(lines.count == 2)
        #expect(lines[0].direction == .sent && lines[0].state == .replied && lines[0].text == "Pesquise o número.")
        #expect(lines[0].from.name == "Atlas" && lines[0].to?.name == "Pesquisador")
        #expect(lines[1].direction == .reply && lines[1].text == "Achei 42." && lines[1].state == .replied)
        #expect(team.botTexts(team.atlas) == ["Pedi ao Pesquisador.", "O Pesquisador achou 42."])
        // The model of the asker was handed the reply as data, in a tag, and no approval card came up.
        let wake = try #require(await team.log.calls(by: "Atlas").last)
        #expect(wake.user.contains("<orb_reply from=\"Pesquisador\"") && wake.user.contains("status=\"ok\""))
        #expect(!team.items(team.atlas).contains { if case .approval = $0.kind { true } else { false } })
        // The asker's bubble for the reply is not the person's.
        #expect(team.items(team.atlas).filter { if case .user = $0.kind { true } else { false } }.count == 1)

        // The target did the work in a conversation of its own, with the request as data; its chat only got a line.
        let target = try #require(team.request(from: team.atlas, to: team.pesquisador))
        #expect(target.state == .replied)
        let saved = model.store.readSideConversation(prefix: Store.pedidoPrefix, id: target.id, for: team.pesquisador.id)
        let side = try #require(saved.value)
        #expect(side.items.contains { if case .orbMessage(let m) = $0.kind { m.direction == .received && m.state == .replied } else { false } })
        #expect(side.items.contains { if case .bot(let text, _) = $0.kind { text == "Achei 42." } else { false } })
        #expect(team.botTexts(team.pesquisador).isEmpty)
        let received = team.events(team.pesquisador)
        #expect(received.count == 1 && received[0].kind == .delegationReceived && received[0].sentence == "Atlas pediu ajuda ao Pesquisador")
        let request = try #require(await team.log.calls(by: "Pesquisador").first)
        #expect(request.user.contains("<orb_request from=\"Atlas\"") && request.user.contains("Pesquise o número."))
        // The target is back in its chat; nobody is left waiting, and the asker's wait line is gone.
        #expect(model.sessions[team.pesquisador.id]?.routineID == nil && model.sessions[team.pesquisador.id]?.parkedChat == nil)
        #expect(model.live(team.atlas.id).chainWork == nil && model.live(team.atlas.id).partner == nil && !model.live(team.atlas.id).isConversing)
        // The chat is asked to follow the turn the answer woke (once), and the one send of the person is the only scroll to the end.
        #expect(model.live(team.atlas.id).followNudge == 1 && model.live(team.atlas.id).scrollNudge == 1)
        #expect(model.live(team.pesquisador.id).followNudge == 0 && model.live(team.pesquisador.id).scrollNudge == 0)
    }

    @Test func theAskerWaitsOnScreenWhileTheTargetWorks() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Fim.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Pronto.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the asker to wait") { team.botTexts(team.atlas) == ["Pedi."] && model.live(team.atlas.id).chainWork != nil }
        #expect(model.live(team.atlas.id).chainWork?.text == "Esperando Pesquisador")
        #expect(model.live(team.atlas.id).isConversing)
        #expect(model.live(team.atlas.id).partner == PartnerTint(botID: team.pesquisador.id, color: "teal"))
        #expect(model.live(team.pesquisador.id).partner == PartnerTint(botID: team.atlas.id, color: "indigo"))
        #expect(model.delegation.openRequests(from: team.atlas.id).count == 1)
        #expect(model.requesterName(of: team.pesquisador.id) == "Atlas")
        #expect(model.isWorking(team.pesquisador.id))
        #expect(!model.isWorking(team.atlas.id)) // idle, waiting
        await valve.open()
        await team.settle()
        #expect(team.botTexts(team.atlas).last == "Fim.")
    }

    @Test func aBusyTargetQueuesTheRequestAndRunsItAfterItsOwnTurn() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Recebi.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                if seen.user.contains("<orb_request") { return say("Feito.") }
                await valve.wait()
                return say("Terminei a minha.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("trabalho demorado", to: team.pesquisador.id, fromUser: true)
        await waitUntil("the target to be busy") { model.sessions[team.pesquisador.id]?.turnTask != nil }
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to wait in the queue") { team.model.delegation.queues[team.pesquisador.id]?.count == 1 }
        #expect(team.model.delegation.teammatesText(for: team.atlas.id, groupID: nil).contains("Pesquisador: Pesquisa e resume (ocupado)"))
        #expect(await team.log.calls(by: "Pesquisador").count == 1) // only its own turn so far
        await valve.open()
        await team.settle()
        #expect(team.botTexts(team.pesquisador) == ["Terminei a minha."]) // its chat is its own
        #expect(team.botTexts(team.atlas).last == "Recebi.")
        #expect(team.model.delegation.queues[team.pesquisador.id] == nil)
    }

    @Test func aBusyAskerGetsTheAnswerWhenItsTurnEnds() async throws {
        let target = TestGate(), busy = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Voltei com a resposta.") }
                if seen.toolResult != nil { return say("Pedi.") }
                if seen.user.contains("outra coisa") { await busy.wait(); return say("Terminei a outra coisa.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await target.wait()
                return say("Achei.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the asker to wait for the answer") { team.botTexts(team.atlas).contains("Pedi.") }
        // The asker takes on something else and is busy when the answer comes.
        model.send("faça outra coisa", to: team.atlas.id, fromUser: true)
        await waitUntil("the asker to be busy") { model.sessions[team.atlas.id]?.turnTask != nil && model.isWorking(team.atlas.id) }
        await waitUntil("the asker's busy turn to reach the model") { await team.log.count(by: "Atlas") == 3 }
        let calls = await team.log.count(by: "Atlas")
        await target.open()
        await waitUntil("the answer to wait for the asker's turn to end") { model.delegation.inbox[team.atlas.id]?.count == 1 }
        #expect(await team.log.count(by: "Atlas") == calls) // not woken: it is working
        #expect(!team.botTexts(team.atlas).contains("Voltei com a resposta."))
        await busy.open()
        await team.settle()
        #expect(team.botTexts(team.atlas) == ["Pedi.", "Terminei a outra coisa.", "Voltei com a resposta."])
    }

    @Test func aTargetThatAsksInTurnWaitsForItsChildrenAndResumesItsConversation() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Tudo pronto: \(seen.user.contains("revisada") ? "com revisão" : "sem revisão").") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise e revise.")
            case "Pesquisador":
                if seen.user.contains("<orb_reply from=\"Revisor\"") { return say("Pesquisa revisada.") }
                if seen.toolResult != nil { return say("Aguardo o Revisor.") }
                return orbsCall("ask", to: "Revisor", "Revise isto.")
            default: return say("Revisado.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the asker to hear back") { team.botTexts(team.atlas).contains("Tudo pronto: com revisão.") }
        await team.settle()

        // The asker heard once, and only after the target heard from its own helper.
        let replies = team.orbMessages(team.atlas).filter { $0.direction == .reply }
        #expect(replies.count == 1 && replies[0].text == "Pesquisa revisada." && replies[0].from.name == "Pesquisador")
        let first = try #require(team.request(from: team.atlas, to: team.pesquisador))
        let child = try #require(team.request(from: team.pesquisador, to: team.revisor))
        #expect(first.state == .replied && child.state == .replied && child.envelope.servingRequest == first.id)
        #expect(child.envelope.hop == 2 && child.envelope.path == [team.atlas.id, team.pesquisador.id])
        // One conversation for the whole request: the question, the helper, the answer it came back with.
        let side = try #require(model.store.readSideConversation(prefix: Store.pedidoPrefix, id: first.id, for: team.pesquisador.id).value)
        let texts = side.items.compactMap { item -> String? in
            switch item.kind {
            case .bot(let text, _): text
            case .orbMessage(let message): "\(message.direction):\(message.state)"
            default: nil
            }
        }
        #expect(texts.contains("Aguardo o Revisor.") && texts.contains("Pesquisa revisada."))
        #expect(texts.contains("sent:replied") && texts.contains("reply:replied"))
        #expect(model.store.readSideConversation(prefix: Store.pedidoPrefix, id: child.id, for: team.revisor.id).value != nil)
        // The asker was not told "Aguardo o Revisor." — that was only the target waiting.
        #expect(!team.botTexts(team.atlas).contains("Aguardo o Revisor."))
    }

    @Test func aTellNeedsNoAnswer() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Avisei.") }
                return orbsCall("tell", to: "Revisor", "Já mudei o README.")
            default: return say("Anotado.")
            }
        }
        defer { team.cleanUp() }
        team.model.send("avise o Revisor", to: team.atlas.id, fromUser: true)
        await waitUntil("the notice to be handled") { team.request(from: team.atlas, to: team.revisor)?.state == .replied }
        await team.settle()
        #expect(team.orbMessages(team.atlas).count == 1)
        #expect(team.orbMessages(team.atlas)[0].kind == .tell)
        #expect(team.botTexts(team.atlas) == ["Avisei."]) // nothing woke it
        #expect(await team.log.count(by: "Atlas") == 2)
        let request = try #require(await team.log.calls(by: "Revisor").first)
        #expect(request.user.contains("No reply is expected."))
    }

    // MARK: Limits

    @Test func aModelThatKeepsAskingStopsAtTheLimitsAndEveryoneEndsIdle() async throws {
        let counter = Counter()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if let result = seen.toolResult { return say("Parei: \(result)") }
                // Each wake asks again with new words, so only the pair limit can stop it.
                return orbsCall("ask", to: "Pesquisador", "Mais uma vez (\(await counter.next()))")
            default: return say("Respondido.")
            }
        }
        defer { team.cleanUp() }
        team.model.send("comece", to: team.atlas.id, fromUser: true)
        await waitUntil("the loop to stop") { team.botTexts(team.atlas).contains { $0.contains("Você já falou 3 vezes") } }
        await team.settle()
        let asked = team.model.delegation.requests.values.filter { $0.envelope.from.id == team.atlas.id }
        #expect(asked.count == DelegationLimits.maxPerPair)
        #expect(await team.log.count(by: "Pesquisador") == DelegationLimits.maxPerPair)
    }

    @Test func aTargetCannotAskBackWhoIsWaitingForIt() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") || seen.toolResult != nil { return say("Ok.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            case "Pesquisador":
                if let result = seen.toolResult { return say("Recusado: \(result)") }
                return orbsCall("ask", to: "Atlas", "Esqueci de perguntar uma coisa.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        team.model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the loop to be refused") { team.orbMessages(team.atlas).contains { $0.direction == .reply } }
        await team.settle()
        let reply = try #require(team.orbMessages(team.atlas).first { $0.direction == .reply })
        #expect(reply.text.contains("Atlas já está esperando por você nesta conversa."))
        #expect(team.request(from: team.pesquisador, to: team.atlas) == nil)
    }

    @Test func theFourthOpenRequestAndTheFifthHopAreRefusedByTheHub() async throws {
        let valve = TestGate() // the targets are busy, so the requests stay open
        let team = Team { seen in
            await valve.wait()
            return say("x")
        }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        // Three open requests from one Orb, in any chain; the fourth waits for answers.
        for index in 1...3 {
            _ = try hub.submit(from: team.atlas.id, to: index == 3 ? "Revisor" : "Pesquisador", text: "pedido \(index)", kind: .ask,
                               messageID: UUID(), groupID: nil)
        }
        #expect(throws: DelegationRefusal.tooManyOpen) {
            try hub.submit(from: team.atlas.id, to: "Revisor", text: "pedido 4", kind: .ask, messageID: UUID(), groupID: nil)
        }
        #expect(hub.openRequests(from: team.atlas.id).count == 3)
        // A turn at hop 4 cannot ask again.
        team.model.session(team.revisor.id).chain = ChainContext(chainID: UUID(), hop: 4, path: [team.revisor.id])
        #expect(throws: DelegationRefusal.hopLimit) {
            try hub.submit(from: team.revisor.id, to: "Atlas", text: "x", kind: .ask, messageID: UUID(), groupID: nil)
        }
        team.model.session(team.revisor.id).chain = nil
        await valve.open()
        await team.settle()
    }

    @Test func theSameMessageTwiceIsOneRequestAndTheBudgetCountsTokens() async throws {
        let team = Team { _ in say("x") }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        let id = UUID()
        let first = try hub.submit(from: team.atlas.id, to: "Pesquisador", text: "Pesquise", kind: .ask, messageID: id, groupID: nil)
        #expect(throws: DelegationRefusal.duplicate) {
            try hub.submit(from: team.atlas.id, to: "Revisor", text: "Outra", kind: .ask, messageID: id, groupID: nil)
        }
        await team.settle()
        // The chain of the first request has spent its tokens: a turn in it cannot ask any more.
        hub.tokensUsed(DelegationLimits.maxTokensPerChain, chain: first.chainID)
        let session = team.model.session(team.atlas.id)
        session.chain = ChainContext(chainID: first.chainID, hop: 0, path: [team.atlas.id])
        #expect(throws: DelegationRefusal.budgetSpent) {
            try hub.submit(from: team.atlas.id, to: "Revisor", text: "Mais", kind: .ask, messageID: UUID(), groupID: nil)
        }
        session.chain = nil
    }

    @Test func aTurnsUsageCountsAgainstItsChain() async throws {
        let team = Team { _ in say("x") }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        let first = try hub.submit(from: team.atlas.id, to: "Pesquisador", text: "Pesquise", kind: .ask, messageID: UUID(), groupID: nil)
        await team.settle()
        let session = team.model.session(team.pesquisador.id)
        session.chain = ChainContext(chainID: first.chainID, hop: 1, path: [team.atlas.id, team.pesquisador.id])
        team.model.recordUsage(UsageTotals(input: 1_000, cacheRead: 50_000, cacheWrite: 500, output: 250), botID: team.pesquisador.id,
                               model: "custom/modelo", source: .delegation)
        session.chain = nil
        #expect(hub.chainStates[first.chainID]?.tokens == 1_750) // what is charged in full or written: not the cache reads
    }

    // MARK: Stopping

    @Test func stoppingTheIdleAskerCancelsTheWholeChain() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Não devia chegar.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Resposta tardia.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to run") { team.request(from: team.atlas, to: team.pesquisador)?.state == .running }
        await waitUntil("the asker to wait") { team.botTexts(team.atlas) == ["Pedi."] && model.live(team.atlas.id).chainWork != nil }
        model.stop(team.atlas.id) // the asker's turn is over: this is the Parar of the waiting line
        let request = try #require(team.request(from: team.atlas, to: team.pesquisador))
        #expect(request.state == .cancelled)
        #expect(!model.isWorking(team.pesquisador.id) && model.sessions[team.pesquisador.id]?.parkedChat == nil)
        #expect(team.orbMessages(team.atlas)[0].state == .cancelled)
        let stopped = team.events(team.atlas)
        #expect(stopped.count == 1 && stopped[0].kind == .chainStopped && stopped[0].sentence == "Você parou a conversa entre Orbs")
        #expect(model.live(team.atlas.id).chainWork == nil && model.live(team.atlas.id).partner == nil && model.live(team.pesquisador.id).partner == nil)
        await valve.open()
        await team.settle()
        #expect(team.botTexts(team.atlas) == ["Pedi."]) // the late answer was not delivered
        #expect(team.botTexts(team.pesquisador).isEmpty)
        #expect(model.delegation.inbox.isEmpty)
        // The side conversation shows it was cut short, and the target is free for the next request.
        let side = try #require(model.store.readSideConversation(prefix: Store.pedidoPrefix, id: request.id, for: team.pesquisador.id).value)
        #expect(side.items.contains { if case .notice(let text) = $0.kind { text.contains("interrompeu") } else { false } })
    }

    @Test func stoppingTheTargetStopsTheChainToo() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Não devia chegar.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        team.model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to run") { team.request(from: team.atlas, to: team.pesquisador)?.state == .running }
        team.model.stop(team.pesquisador.id)
        #expect(team.request(from: team.atlas, to: team.pesquisador)?.state == .cancelled)
        #expect(team.orbMessages(team.atlas)[0].state == .cancelled)
        #expect(team.events(team.atlas).map(\.kind) == [.chainStopped])
        await valve.open()
        await team.settle()
        #expect(team.botTexts(team.atlas) == ["Pedi."])
    }

    @Test func stoppingReachesNestedRequestsAndWaitingOrbs() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            case "Pesquisador":
                if seen.toolResult != nil { return say("Aguardo.") }
                return orbsCall("ask", to: "Revisor", "Revise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the helper to run") { team.request(from: team.pesquisador, to: team.revisor)?.state == .running }
        await waitUntil("the middle one to wait") { team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren }
        await waitUntil("the asker turn to end") { team.botTexts(team.atlas) == ["Pedi."] }
        model.stop(team.atlas.id)
        #expect(team.request(from: team.atlas, to: team.pesquisador)?.state == .cancelled)
        #expect(team.request(from: team.pesquisador, to: team.revisor)?.state == .cancelled)
        #expect(!model.isWorking(team.revisor.id))
        #expect(model.live(team.pesquisador.id).chainWork == nil)
        await valve.open()
        await team.settle()
        #expect(model.delegation.inbox.isEmpty && model.delegation.queues.values.allSatisfy(\.isEmpty))
    }

    /// Atlas asks Pesquisador, who asks Revisor and waits (Revisor is held on a valve): Pesquisador's side conversation is kept in memory.
    private func waitingMiddleTeam(_ valve: TestGate) -> Team {
        Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            case "Pesquisador":
                if seen.toolResult != nil { return say("Aguardo.") }
                return orbsCall("ask", to: "Revisor", "Revise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
    }

    private func openLines(of team: Team, request: DelegationRequest) throws -> [OrbMessageItem] {
        let side = try #require(team.model.store.readSideConversation(prefix: Store.pedidoPrefix, id: request.id, for: team.pesquisador.id).value)
        return side.items.compactMap { if case .orbMessage(let message) = $0.kind, message.state == .open { message } else { nil } }
    }

    @Test func stoppingTheChainClosesTheLinesOfARequestThatWaitedForItsChildren() async throws {
        let valve = TestGate()
        let team = waitingMiddleTeam(valve)
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the middle one to wait") { team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren }
        await waitUntil("the asker turn to end") { team.botTexts(team.atlas) == ["Pedi."] }
        let middle = try #require(team.request(from: team.atlas, to: team.pesquisador))
        #expect(try !openLines(of: team, request: middle).isEmpty) // "Aguardando resposta" is on disk while it waits
        model.stop(team.atlas.id)
        #expect(try openLines(of: team, request: middle).isEmpty)
        await valve.open()
        await team.settle()
    }

    @Test func aTimedOutRequestThatWaitedForItsChildrenClosesItsLines() async throws {
        let valve = TestGate()
        let team = waitingMiddleTeam(valve)
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the middle one to wait") { team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren }
        let middle = try #require(team.request(from: team.atlas, to: team.pesquisador))
        model.delegation.sweep(now: .now.addingTimeInterval(DelegationLimits.workTimeout + 60))
        #expect(model.delegation.requests[middle.id]?.state == .failed)
        #expect(try openLines(of: team, request: middle).isEmpty)
        await valve.open()
        await team.settle()
    }

    @Test func waitingForWorkThatGoesOnIsNotATimeoutUntilTheCeiling() async throws {
        let valve = TestGate()
        let team = waitingMiddleTeam(valve)
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("Pesquisador to wait for Revisor at work") {
            team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren
                && team.request(from: team.pesquisador, to: team.revisor)?.state == .running
        }
        let middle = try #require(team.request(from: team.atlas, to: team.pesquisador))
        // A second request to Revisor queues behind the turn it is in.
        let queued = try hub.submit(from: team.atlas.id, to: "Revisor", text: "Outra coisa.", kind: .ask, messageID: UUID(), groupID: nil)
        #expect(hub.requests[queued.id]?.state == .queued)
        // Past half an hour: Pesquisador waits for a child at work, and the queue waits for a turn in progress.
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.requestTimeout + 60))
        #expect(hub.requests[middle.id]?.state == .awaitingChildren)
        #expect(hub.requests[queued.id]?.state == .queued)
        // Past the ceiling, a turn that never ends no longer holds them.
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.workTimeout + 60))
        #expect(hub.requests[middle.id]?.state == .failed)
        #expect(hub.requests[queued.id]?.state == .failed)
        await valve.open()
        await team.settle()
    }

    @Test func anOrbDeletedMidChainAnswersFailedToWhoWaited() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Ele sumiu.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to run") { team.request(from: team.atlas, to: team.pesquisador)?.state == .running }
        let requestID = try #require(team.request(from: team.atlas, to: team.pesquisador)).id
        model.deleteBot(team.pesquisador.id)
        await waitUntil("the asker to hear") { team.botTexts(team.atlas).contains("Ele sumiu.") }
        let wake = try #require(await team.log.calls(by: "Atlas").last)
        #expect(wake.user.contains("status=\"failed\"") && wake.user.contains("Esse Orb foi apagado"))
        #expect(model.delegation.requests[requestID]?.state == .failed)
        #expect(team.orbMessages(team.atlas).first?.state == .failed)
        await valve.open()
        #expect(model.bot(team.pesquisador.id) == nil)
        // The roster no longer names it.
        #expect(model.delegation.roster(for: team.atlas.id, groupID: nil).map(\.name) == ["Revisor"])
        await waitUntil("nothing to be left running") { model.sessions[team.atlas.id]?.turnTask == nil }
    }

    // MARK: The switch, and the permissions

    @Test func theSwitchHidesTheToolAndTheTeammatesAndStopsWhatIsGoingOn() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Não devia chegar.") }
                if seen.toolResult != nil { return say("Pedi.") }
                if seen.user.contains("sem time") { return say("Sozinho.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to run") { team.request(from: team.atlas, to: team.pesquisador)?.state == .running }
        let first = try #require(await team.log.calls(by: "Atlas").first)
        #expect(first.tools.contains("orbs"))
        model.orbsCanTalk = false // switching it off stops the chain
        #expect(team.request(from: team.atlas, to: team.pesquisador)?.state == .cancelled)
        #expect(!model.isWorking(team.pesquisador.id))
        await valve.open()
        await team.settle()
        // From now on the tool is not offered and the model is told of no teammates.
        model.send("sem time", to: team.atlas.id, fromUser: true)
        await team.settle()
        let last = try #require(await team.log.calls(by: "Atlas").last)
        #expect(!last.tools.contains("orbs"))
        #expect(model.delegation.roster(for: team.atlas.id, groupID: nil).isEmpty)
        #expect(throws: DelegationRefusal.switchedOff) {
            try model.delegation.submit(from: team.atlas.id, to: "Revisor", text: "x", kind: .ask, messageID: UUID(), groupID: nil)
        }
        #expect(model.multiOrbOffering(for: team.atlas.id) == MultiOrbOffering(propose: true, askUser: true)) // only the creation tool stays (WP3), and asking you
        model.orbsCanTalk = true
        #expect(model.multiOrbOffering(for: team.atlas.id).orbs)
    }

    @Test func anAskerThatOnlyReadsCannotAsk() async throws {
        let team = Team(modes: [.readOnly, .ask, .ask]) { seen in
            switch seen.who {
            case "Atlas":
                if let result = seen.toolResult { return say("Resultado: \(result)") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default: return say("Não devia ser pedido.")
            }
        }
        defer { team.cleanUp() }
        team.model.send("peça", to: team.atlas.id, fromUser: true)
        await team.settle()
        #expect(team.model.delegation.requests.isEmpty)
        #expect(await team.log.count(by: "Pesquisador") == 0)
        #expect(team.botTexts(team.atlas).count == 1)
    }

    @Test func aTargetKeepsItsOwnPermissionsEvenWhenAskedByAnOrbThatMayDoMore() async throws {
        let team = Team(modes: [.auto, .readOnly, .ask]) { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") || seen.toolResult != nil { return say("Ok.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default: return say("Li, não mudei nada.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to end") { team.request(from: team.atlas, to: team.pesquisador)?.state == .replied }
        // The target's mode is its own; the run never used the asker's.
        #expect(model.bot(team.pesquisador.id)?.permissionMode == .readOnly)
        #expect(model.permissionState(of: team.pesquisador.id)?.mode == .readOnly)
        await team.settle()
    }

    // MARK: The tool

    @Test func listShowsTheTeammatesWithoutIdsAndRefusalsAreInPortuguese() async throws {
        let team = Team { _ in say("x") }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        let list = try await hub.handleTool(.object(["action": .string("list")]), orb: team.atlas.id)
        #expect(list == "- Pesquisador: Pesquisa e resume (livre)\n- Revisor: Revisa o que foi feito (livre)")
        let error = try #require(await #expect(throws: ToolError.self, "a request to nobody went through") {
            _ = try await hub.handleTool(.object(["action": .string("ask"), "to": .string("Zé"), "message": .string("x")]), orb: team.atlas.id)
        })
        #expect(error.localizedDescription.contains("Não existe um Orb chamado “Zé”"))
        let sent = try await hub.handleTool(.object(["action": .string("ask"), "to": .string("pesq"), "message": .string("Pesquise")]), orb: team.atlas.id,
                                            messageID: UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000000")!)
        #expect(sent == "Pedido enviado a Pesquisador (id a1b2). A resposta chega sozinha como mensagem; não espere nem repita o pedido. Termine o que puder sem ela.")
        #expect(try await hub.handleTool(.object(["action": .string("tell"), "to": .string("Revisor"), "message": .string("Oi")]), orb: team.atlas.id)
                == "Aviso enviado a Revisor.")
        await team.settle()
    }

    // MARK: Group turns

    @Test func aGroupTurnRunsInTheMembersGroupConversationAndTellsTheHooks() async throws {
        let team = Team { seen in say(seen.user.contains("Sua vez no grupo") ? "Falei no grupo." : "?") }
        defer { team.cleanUp() }
        let hooks = Hooks()
        let hub = team.model.delegation
        _ = team.model.groupHub // made (and hooked up) now, so the hooks below are the ones left in place
        hub.groupHooks = hooks
        let group = OrbGroup(name: "Equipe", memberIDs: [team.atlas.id, team.pesquisador.id], orchestratorID: team.atlas.id)
        team.model.groups = [group]
        let chain = ChainContext(chainID: UUID(), hop: 0, path: [], groupID: group.id)
        let request = hub.submitGroupTurn(member: team.pesquisador.id, text: "Ajude", chain: chain, groupID: group.id, askedBy: nil)
        #expect(request.state == .queued)
        await waitUntil("the turn to end") { !hooks.finished.isEmpty }
        await team.settle()
        #expect(hooks.started == [request.id])
        #expect(hooks.finished.count == 1 && hooks.finished[0].reply == "Falei no grupo." && hooks.finished[0].outcome == .ok)
        let side = try #require(team.model.store.readSideConversation(prefix: Store.grupoPrefix, id: group.id, for: team.pesquisador.id).value)
        #expect(side.items.contains { if case .bot(let text, _) = $0.kind { text == "Falei no grupo." } else { false } })
        #expect(team.botTexts(team.pesquisador).isEmpty) // its chat is untouched
        #expect(team.model.delegation.inbox.isEmpty) // the person asked: nobody to answer
    }
}

// MARK: Groups over the real delegation hub (WP1 + WP5)

private func twoCalls(_ calls: [(to: String, message: String)]) -> [LLMEvent] {
    [.toolCalls(calls.enumerated().map { index, call in
        ToolCallRequest(id: "c\(index)", name: "orbs",
                        arguments: JSONValue.object(["action": .string("ask"), "to": .string(call.to), "message": .string(call.message)]).jsonString)
    })]
}

private actor Names {
    private var names: Set<String> = []
    func add(_ name: String) -> Int { names.insert(name); return names.count }
}

@Suite @MainActor struct GroupsOverTheRealHubTests {
    private func group(_ team: Team, budget: GroupBudget = GroupBudget()) -> OrbGroup {
        let hub = team.model.groupHub
        hub.settle = .zero
        hub.isAppActive = { false }
        return team.model.createGroup(name: "Lançamento", members: [team.atlas.id, team.pesquisador.id, team.revisor.id], budget: budget)!
    }

    private func finalPosts(_ team: Team, _ group: OrbGroup, _ text: String) -> Int {
        (team.model.groupSession(group.id)?.items ?? []).filter {
            if case .orbMessage(let message) = $0.kind { message.direction == .post && message.kind == .reply && message.text == text } else { false }
        }.count
    }

    @Test func theOrchestratorAssignsTwoMembersTheyTalkAndTheWrapUpPostsOnce() async throws {
        let replies = Names()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") {
                    var count = 0
                    for name in ["Pesquisador", "Revisor"] where seen.user.contains("from=\"\(name)\"") { count = await replies.add(name) }
                    return say(count >= 2 ? "Pronto: mercado levantado e texto revisado." : "Ainda falta o outro.")
                }
                if seen.toolResult != nil { return say("Pedi aos dois.") }
                return twoCalls([("Pesquisador", "Levante o mercado."), ("Revisor", "Revise o texto.")])
            case "Pesquisador":
                if seen.user.contains("<orb_reply") { return say("Três concorrentes, preços conferidos.") }
                if seen.toolResult != nil { return say("Perguntei ao Revisor.") }
                return orbsCall("ask", to: "Revisor", "Os preços estão coerentes?")
            case "Revisor":
                return say(seen.user.contains("Os preços") ? "Estão coerentes." : "Texto revisado.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let group = group(team)
        #expect(team.model.postUserMessage("Preparar o lançamento", to: group.id))
        await waitUntil("the request to end") { team.model.groupHub.run(group.id) == nil && !(team.model.groupSession(group.id)?.items.isEmpty ?? true)
            && self.finalPosts(team, group, "Pronto: mercado levantado e texto revisado.") > 0 }
        await team.settle()
        let items = team.model.groupSession(group.id)?.items ?? []
        let posts: [(String, String?, OrbMessageItem.Kind, String)] = items.compactMap {
            if case .orbMessage(let message) = $0.kind, message.direction == .post { (message.from.name, message.to?.name, message.kind, message.text) } else { nil }
        }
        #expect(finalPosts(team, group, "Pronto: mercado levantado e texto revisado.") == 1)
        #expect(posts.contains { $0.0 == "Atlas" && $0.1 == "Pesquisador" && $0.2 == .ask })
        #expect(posts.contains { $0.0 == "Atlas" && $0.1 == "Revisor" && $0.2 == .ask })
        #expect(posts.contains { $0.0 == "Pesquisador" && $0.1 == "Revisor" && $0.2 == .ask }) // members talk to each other
        #expect(posts.contains { $0.0 == "Revisor" && $0.1 == "Pesquisador" && $0.3 == "Estão coerentes." })
        let done = items.filter { if case .event(let event) = $0.kind { event.kind == .groupRunDone } else { false } }
        #expect(done.count == 1)
        #expect(team.model.groupLive(group.id).runState == .idle && !team.model.isGroupWorking(group.id))
        #expect(team.model.delegation.requests.values.allSatisfy { !DelegationHub.isOpen($0.state) } && team.model.delegation.inbox.isEmpty)
        // The members' own chats are untouched: the work is in their group conversations.
        #expect(team.botTexts(team.pesquisador).isEmpty && team.botTexts(team.revisor).isEmpty)
        let side = team.model.store.readSideConversation(prefix: Store.grupoPrefix, id: group.id, for: team.pesquisador.id).value
        #expect(side != nil)
    }

    @Test func aSpentBudgetPausesAndContinuarResumesTheHeldAnswer() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Fechado com o que o Pesquisador achou.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default: return say("Achei 42.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team, budget: GroupBudget(maxTurns: 2, maxTokens: 1_000_000))
        team.model.postUserMessage("Descubra o número", to: group.id)
        await waitUntil("the group to pause") { team.model.groupLive(group.id).runState == .paused(.turns) }
        // The answer is held, not delivered: Atlas is not woken while the group waits for the person.
        #expect(team.model.groupSession(group.id)?.items.contains { if case .groupPause(let pause) = $0.kind { pause.state == .open } else { false } } == true)
        #expect(!team.botTexts(team.atlas).contains("Fechado com o que o Pesquisador achou."))
        #expect(await team.log.calls(by: "Atlas").count == 2) // its first turn (the ask and the words after it), not the wake
        team.model.continueRun(group.id)
        await waitUntil("the held answer to wake the orchestrator") { self.finalPosts(team, group, "Fechado com o que o Pesquisador achou.") == 1 }
        await waitUntil("the request to end") { team.model.groupHub.run(group.id) == nil }
        await team.settle()
        #expect(finalPosts(team, group, "Fechado com o que o Pesquisador achou.") == 1)
        #expect(team.model.groupSession(group.id)?.items.contains { if case .groupPause(let pause) = $0.kind { pause.state == .continued } else { false } } == true)
    }

    @Test func stoppingTheGroupCancelsEveryTurnAndPostsNothingMore() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Isto não devia aparecer.") }
                if seen.toolResult != nil { return say("Pedi aos dois.") }
                return twoCalls([("Pesquisador", "Levante o mercado."), ("Revisor", "Revise o texto.")])
            default:
                await valve.wait()
                return say("Isto também não.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team)
        team.model.postUserMessage("Preparar o lançamento", to: group.id)
        await waitUntil("both members to work") { team.model.isWorking(team.pesquisador.id) && team.model.isWorking(team.revisor.id) }
        team.model.stopGroup(group.id)
        await valve.open()
        await team.settle()
        await waitUntil("the group to be idle") { !team.model.isGroupWorking(group.id) }
        #expect(team.model.groupHub.run(group.id) == nil && team.model.groupLive(group.id).runState == .idle)
        #expect(team.model.delegation.requests.values.allSatisfy { !DelegationHub.isOpen($0.state) } && team.model.delegation.inbox.isEmpty)
        let items = team.model.groupSession(group.id)?.items ?? []
        #expect(items.contains { if case .event(let event) = $0.kind { event.kind == .groupStopped } else { false } })
        #expect(!items.contains { if case .orbMessage(let message) = $0.kind { message.text.contains("não") && message.direction == .post && message.kind == .reply } else { false } })
        #expect(team.botTexts(team.atlas).isEmpty)
        // The stop is told in the group's thread; the orchestrator's private chat gets no "conversa entre Orbs" line.
        #expect(!team.events(team.atlas).contains { $0.kind == .chainStopped })
    }

    @Test func endingFromThePauseDoesNotWriteInTheOrchestratorsPrivateChat() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Isto não devia aparecer.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default: return say("Achei 42.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team, budget: GroupBudget(maxTurns: 2, maxTokens: 1_000_000))
        team.model.postUserMessage("Descubra o número", to: group.id)
        await waitUntil("the group to pause") { team.model.groupLive(group.id).runState == .paused(.turns) }
        team.model.endRun(group.id)
        await team.settle()
        #expect(team.model.groupLive(group.id).runState == .idle)
        #expect(!team.events(team.atlas).contains { $0.kind == .chainStopped })
        #expect(team.model.groupSession(group.id)?.items.contains { if case .event(let event) = $0.kind { event.kind == .groupStopped } else { false } } == true)
    }

    @Test func aPausedGroupDoesNotTimeOutAndContinuarStillDeliversTheHeldAnswer() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Fechado com o que o Pesquisador achou.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default: return say("Achei 42.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team, budget: GroupBudget(maxTurns: 2, maxTokens: 1_000_000))
        team.model.postUserMessage("Descubra o número", to: group.id)
        await waitUntil("the group to pause") { team.model.groupLive(group.id).runState == .paused(.turns) }
        // Half an hour and more pass while the group waits for the person.
        team.model.delegation.sweep(now: .now.addingTimeInterval(DelegationLimits.requestTimeout + 60))
        #expect(team.model.delegation.requests.values.allSatisfy { $0.state != .failed })
        team.model.continueRun(group.id)
        await waitUntil("the held answer to wake the orchestrator") { self.finalPosts(team, group, "Fechado com o que o Pesquisador achou.") == 1 }
        await team.settle()
    }
}
