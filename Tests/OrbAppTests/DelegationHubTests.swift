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
    var system: String = ""
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
    var names = ["Atlas", "Pesquisador", "Revisor"]
    let rule: @Sendable (Seen) async -> [LLMEvent]

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let system = messages.first { $0.role == .system }?.content ?? ""
        let who = names.first { system.contains("You are \($0),") } ?? "?"
        let user = messages.last { $0.role == .user }?.content ?? ""
        let result = messages.last?.role == .tool ? messages.last?.content : nil
        let seen = Seen(who: who, system: system, user: user, toolResult: result, tools: tools.map(\.name))
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
    /// More Orbs, after the three (`extra` of `init`).
    var others: [Bot] = []

    init(modes: [PermissionMode] = [.ask, .ask, .ask], extra: [String] = [], rule: @escaping @Sendable (Seen) async -> [LLMEvent]) {
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
        let folder = root
        var more: [Bot] = []
        for name in extra { more.append(make(folder, name, "Papel de \(name)", .ask, color: "amber")) }
        others = more
        var state = AppState.initial
        state.bots = [atlas, pesquisador, revisor] + others
        state.routines = []
        let store = Store(directory: root)
        store.save(state)
        for bot in state.bots { store.save(Conversation(), for: bot.id) }
        store.flush()
        model = AppModel(store: store, runsBackgroundWork: false)
        model.preferences = UserDefaults(suiteName: suite) ?? .standard // the switch of Ajustes is this test's own
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let brain = Brain(log: log, names: ["Atlas", "Pesquisador", "Revisor"] + extra, rule: rule)
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
        return ([atlas, pesquisador, revisor] + others).allSatisfy { model.sessions[$0.id]?.turnTask == nil && !hub.isStarting($0.id) }
            && !hub.requests.values.contains { DelegationHub.isOpen($0.state) } && hub.inbox.isEmpty
            && !model.isStartingRoutine && hub.waitingRoutines.isEmpty
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

    /// A notice (`tell`) wakes nobody: the target's chat shows it at once and its next turn, whatever starts it, reads it once.
    @Test func aRoutineThatAsksGetsTheAnswerInItsRunNotInTheChat() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Pesquisador":
                if seen.toolResult != nil { return say("Aguardo o Revisor.") }
                if seen.user.contains("Achei 3 erros.") { return say("Relatório: o Revisor achou 3 erros.") }
                return orbsCall("ask", to: "Revisor", "Revise o texto de hoje.")
            case "Revisor": return say("Achei 3 erros.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        let routine = Routine(name: "Revisão diária", botID: team.pesquisador.id, prompt: "Peça a revisão do texto de hoje.",
                              schedule: .daily(hour: 9, minute: 0))
        model.routines = [routine]
        model.runRoutine(routine.id)
        await waitUntil("the run to be recorded") { model.routines.first?.runs.isEmpty == false }
        await team.settle()
        // The ask said the answer resumes the run; the answer came back to the run, with the routine's closing words.
        let asked = try #require(await team.log.calls(by: "Pesquisador").first { $0.toolResult != nil }?.toolResult)
        #expect(asked.contains("e retoma esta execução da rotina"))
        let resumed = try #require(await team.log.calls(by: "Pesquisador").last)
        #expect(resumed.user.contains("Achei 3 erros.") && resumed.user.contains("Continue the routine's task"))
        // One run, recorded at its real end, with the final report; the chat got no turn of its own.
        let runs = try #require(model.routines.first?.runs)
        #expect(runs.count == 1)
        #expect(runs.first?.succeeded == true && runs.first?.report?.contains("o Revisor achou 3 erros") == true)
        #expect(team.botTexts(team.pesquisador).isEmpty)
        #expect(!team.orbMessages(team.pesquisador).contains { $0.kind == .reply })
        model.store.flush()
        let saved = try #require(model.store.readRoutineConversation(routine: routine.id, for: team.pesquisador.id).value)
        let said = saved.items.compactMap { if case .bot(let text, _) = $0.kind { text } else { nil } }
        #expect(said == ["Aguardo o Revisor.", "Relatório: o Revisor achou 3 erros."])
        #expect(hub.waitingRoutines.isEmpty)
    }

    @Test func aRoutineThatWaitsEndsWhenTheTalkIsStoppedAndIsNotRunTwice() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Pesquisador":
                if seen.toolResult != nil { return say("Aguardo o Revisor.") }
                return orbsCall("ask", to: "Revisor", "Revise o texto de hoje.")
            case "Revisor":
                await valve.wait()
                return say("Achei 3 erros.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        let routine = Routine(name: "Revisão diária", botID: team.pesquisador.id, prompt: "Peça a revisão do texto de hoje.",
                              schedule: .daily(hour: 9, minute: 0))
        model.routines = [routine]
        model.runRoutine(routine.id)
        await waitUntil("the run to wait") { hub.isWaiting(routine: routine.id) }
        // Waiting is not over: no run recorded yet, and the routine does not start again over it.
        #expect(model.routines.first?.runs.isEmpty == true)
        model.runRoutine(routine.id)
        #expect(model.sessions[team.pesquisador.id]?.routineID == nil && !model.isStartingRoutine)
        // The person stops the talk: the run ends, failed, with the reason; the answer that comes later is dropped.
        let chain = try #require(team.request(from: team.pesquisador, to: team.revisor)?.envelope.chainID)
        hub.cancelChain(chain, by: .user)
        await valve.open()
        await team.settle()
        let runs = try #require(model.routines.first?.runs)
        #expect(runs.count == 1 && runs.first?.succeeded == false)
        #expect(runs.first?.summary.contains("A resposta do outro Orb não veio") == true)
        #expect(await team.log.calls(by: "Pesquisador").count == 2)
    }

    @Test func theOpenTalksOutsideGroupsSayWhoWhatWhereAndStopWithParar() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise o preço do café")
            case "Pesquisador":
                if seen.toolResult != nil { return say("Aguardo.") }
                return orbsCall("ask", to: "Revisor", "Confira estes preços")
            default:
                await valve.wait()
                return say("Conferido.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        #expect(hub.openTalks().isEmpty)
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the reviewer at work") {
            team.request(from: team.pesquisador, to: team.revisor)?.state == .running
                && team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren
        }
        let talks = hub.openTalks()
        #expect(talks.map(\.title) == ["Atlas → Pesquisador", "Pesquisador → Revisor"])
        #expect(talks.first?.detail == "“Pesquise o preço do café” · esperando Revisor · há menos de 1 min")
        #expect(talks.last?.detail == "“Confira estes preços” · trabalhando · há menos de 1 min")
        // Parar stops the whole conversation: none is left.
        hub.cancelChain(try #require(talks.first?.chainID), by: .user)
        #expect(hub.openTalks().isEmpty)
        await valve.open()
        await team.settle()
    }

    @Test func aTellWakesNobodyAndIsReadOnceWithTheTargetsNextMessage() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Avisei.") }
                return orbsCall("tell", to: "Revisor", "Já mudei o README.")
            default: return say("Anotado.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("avise o Revisor", to: team.atlas.id, fromUser: true)
        await team.settle()
        #expect(await team.log.count(by: "Revisor") == 0) // no turn to read a notice
        #expect(model.delegation.requests.isEmpty && model.delegation.queues.isEmpty)
        #expect(team.orbMessages(team.atlas).map(\.kind) == [.tell])
        #expect(team.botTexts(team.atlas) == ["Avisei."]) // nothing woke the sender either
        let result = try #require(await team.log.calls(by: "Atlas").first { $0.toolResult != nil }?.toolResult)
        #expect(result.hasPrefix("Aviso deixado para Revisor: ele lê na próxima mensagem que receber. tell não acorda"))
        let received = team.orbMessages(team.revisor)
        #expect(received.count == 1 && received[0].direction == .received && received[0].kind == .tell)
        #expect(received[0].text == "Já mudei o README." && received[0].from.name == "Atlas")
        // The next turn carries it on top of the message, once.
        model.send("o que mudou?", to: team.revisor.id, fromUser: true)
        await team.settle()
        model.send("e agora?", to: team.revisor.id, fromUser: true)
        await team.settle()
        let calls = await team.log.calls(by: "Revisor")
        #expect(calls.count == 2)
        let notice = try #require(calls[0].user.range(of: "<orb_notice from=\"Atlas\""))
        let message = try #require(calls[0].user.range(of: "o que mudou?"))
        #expect(notice.lowerBound < message.lowerBound && calls[0].user.contains("Já mudei o README."))
        #expect(!calls[1].user.contains("orb_notice"))
        #expect(model.delegation.notices.isEmpty)
    }

    @Test func aTellToABusyOrbWaitsForItsNextTurnAndNeverTimesOut() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas": return say("Ok.")
            default:
                if seen.user.contains("depois") { return say("Vi o aviso.") }
                await valve.wait()
                return say("Terminei a minha.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        model.send("trabalhe", to: team.revisor.id, fromUser: true)
        await waitUntil("Revisor to work") { model.isWorking(team.revisor.id) }
        _ = try hub.submit(from: team.atlas.id, to: "Revisor", text: "Já mudei o README.", kind: .tell, messageID: UUID(), groupID: nil)
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.workTimeout + 60))
        #expect(!team.events(team.atlas).contains { $0.kind == .tellFailed }) // nothing to time out
        #expect(hub.notices[team.revisor.id]?.count == 1)
        await valve.open()
        await team.settle()
        #expect(await team.log.count(by: "Revisor") == 1) // its own turn only
        model.send("depois", to: team.revisor.id, fromUser: true)
        await team.settle()
        #expect(await team.log.calls(by: "Revisor").last?.user.contains("Já mudei o README.") == true)
    }

    @Test func switchingTheTalkOffDropsTheNoticesNotRead() async throws {
        let team = Team { _ in say("ok") }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        _ = try hub.submit(from: team.atlas.id, to: "Revisor", text: "Já mudei o README.", kind: .tell, messageID: UUID(), groupID: nil)
        #expect(hub.notices[team.revisor.id]?.count == 1)
        model.orbsCanTalk = false
        #expect(hub.notices.isEmpty)
        model.send("oi", to: team.revisor.id, fromUser: true)
        await team.settle()
        #expect(await team.log.calls(by: "Revisor").first?.user.contains("orb_notice") == false)
    }

    @Test func aCardNobodyAnsweredForADayIsNotCalledYourStop() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Grave o resumo.")
            default:
                if seen.toolResult != nil { return say("Feito.") }
                let arguments = JSONValue.object(["fact": .string("O resumo sai às sextas.")]).jsonString
                return [.toolCalls([ToolCallRequest(id: "m1", name: "remember", arguments: arguments)])] // asks first in mode ask
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the card") { !model.pendingApprovals(of: team.pesquisador.id).isEmpty }
        let card = try #require(model.pendingApprovals(of: team.pesquisador.id).first)
        model.giveUpWaiting(on: card.id, of: team.pesquisador.id)
        await team.settle()
        #expect(team.request(from: team.atlas, to: team.pesquisador)?.state == .cancelled)
        #expect(!team.events(team.atlas).contains { $0.kind == .chainStopped }) // nobody stopped it
    }

    // MARK: No limits

    @Test func aModelThatKeepsAskingIsNotCutOffAndEveryoneEndsIdle() async throws {
        let counter = Counter()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                // Each wake asks again with new words, more times than one pair could before; then it is done.
                let round = await counter.next()
                return round <= 6 ? orbsCall("ask", to: "Pesquisador", "Mais uma vez (\(round))") : say("Chega.")
            default: return say("Respondido.")
            }
        }
        defer { team.cleanUp() }
        team.model.send("comece", to: team.atlas.id, fromUser: true)
        await waitUntil("the asking to end") { team.botTexts(team.atlas).contains("Chega.") }
        await team.settle()
        let asked = team.model.delegation.requests.values.filter { $0.envelope.from.id == team.atlas.id }
        #expect(asked.count == 6)
        #expect(await team.log.count(by: "Pesquisador") == 6)
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
        #expect(reply.text.contains("Atlas já está esperando a resposta desta conversa: não peça de volta."))
        #expect(team.request(from: team.pesquisador, to: team.atlas) == nil)
    }

    @Test func manyOpenRequestsAndADeepChainAreAccepted() async throws {
        let valve = TestGate() // the targets are busy, so the requests stay open
        let team = Team { seen in
            await valve.wait()
            return say("x")
        }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        for index in 1...6 {
            _ = try hub.submit(from: team.atlas.id, to: index.isMultiple(of: 2) ? "Revisor" : "Pesquisador", text: "pedido \(index)",
                               kind: .ask, messageID: UUID(), groupID: nil)
        }
        #expect(hub.openRequests(from: team.atlas.id).count == 6)
        team.model.session(team.revisor.id).chain = ChainContext(chainID: UUID(), hop: 40, path: [team.revisor.id])
        #expect(try hub.submit(from: team.revisor.id, to: "Atlas", text: "x", kind: .ask, messageID: UUID(), groupID: nil).hop == 41)
        team.model.session(team.revisor.id).chain = nil
        await valve.open()
        await team.settle()
    }

    @Test func theSameMessageTwiceIsOneRequest() async throws {
        let team = Team { _ in say("x") }
        defer { team.cleanUp() }
        let hub = team.model.delegation
        let id = UUID()
        _ = try hub.submit(from: team.atlas.id, to: "Pesquisador", text: "Pesquise", kind: .ask, messageID: id, groupID: nil)
        #expect(throws: DelegationRefusal.duplicate) {
            try hub.submit(from: team.atlas.id, to: "Revisor", text: "Outra", kind: .ask, messageID: id, groupID: nil)
        }
        await team.settle()
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

    @Test func aRequestAtWorkPastTheCeilingIsToldOnceAndNotEnded() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the request to run") { team.request(from: team.atlas, to: team.pesquisador)?.state == .running }
        let request = try #require(team.request(from: team.atlas, to: team.pesquisador))
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.requestTimeout + 60))
        #expect(hub.toldStillRunning.isEmpty) // half an hour of work is nothing to tell
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.workTimeout + 60))
        #expect(hub.requests[request.id]?.state == .running) // no limit: told, not ended
        #expect(hub.toldStillRunning == [request.id])
        hub.sweep(now: .now.addingTimeInterval(DelegationLimits.workTimeout + 3600))
        #expect(hub.toldStillRunning == [request.id]) // once
        #expect(DelegationHub.stillRunningNotice(request, after: DelegationLimits.workTimeout + 60)
            == "Pesquisador está há 3 h no pedido de Atlas e continua trabalhando. Se não era para isso, use Parar.")
        // The banner's Parar stops it.
        model.handle(.stop(botID: team.pesquisador.id))
        await waitUntil("the request to end") { hub.requests[request.id]?.state == .cancelled }
        hub.sweep()
        #expect(hub.toldStillRunning.isEmpty)
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
                .hasPrefix("Aviso deixado para Revisor:"))
        await team.settle()
    }

    // MARK: What the Orb knows about its groups

    @Test func anOrbKnowsItsGroupsInItsChatAndInListAndAGroupsNameIsNotAnUnknownOrb() async throws {
        let team = Team { _ in say("ok") }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        _ = try #require(model.createGroup(name: "Estúdio", members: [team.atlas.id, team.pesquisador.id]))
        // An Orb without groups is told exactly what it was told before.
        #expect(model.orbsSection(for: team.revisor) == OrbsPrompt.section(for: team.revisor, roster: [team.atlas, team.pesquisador]))
        model.send("manda uma mensagem pro grupo Estúdio", to: team.atlas.id, fromUser: true)
        model.send("oi", to: team.revisor.id, fromUser: true)
        await team.settle()
        let atlas = try #require(await team.log.calls(by: "Atlas").first)
        #expect(atlas.system.contains("## Teammates\n") && atlas.system.contains("## Your groups\n"))
        #expect(atlas.system.contains("- Estúdio: you orchestrate; other members: Pesquisador\n"))
        let revisor = try #require(await team.log.calls(by: "Revisor").first)
        #expect(revisor.system.contains("## Teammates\n") && !revisor.system.contains("## Your groups"))
        // `list` says it too, after the teammates.
        let list = try await hub.handleTool(.object(["action": .string("list")]), orb: team.pesquisador.id)
        #expect(list == "- Atlas: Coordena o trabalho (livre)\n- Revisor: Revisa o que foi feito (livre)\n\n"
            + "Seus grupos (o usuário inicia o trabalho de um grupo na tela dele; você não escreve no fio):\n"
            + "- Estúdio: Atlas orquestra; outros membros: Atlas")
        // The group's name gets a refusal that says what to do, not "no such Orb, use list": a group is asked, not told; with
        // "Orbs podem acionar grupos" off, the person starts it on the group's screen.
        let error = try #require(await #expect(throws: ToolError.self) {
            _ = try await hub.handleTool(.object(["action": .string("tell"), "to": .string("estudio"), "message": .string("x")]),
                                         orb: team.atlas.id)
        })
        #expect(error.message.hasPrefix("Para um grupo, use ask"))
        model.orbsCanStartGroups = false
        let off = try #require(await #expect(throws: ToolError.self) {
            _ = try await hub.handleTool(.object(["action": .string("ask"), "to": .string("estudio"), "message": .string("x")]),
                                         orb: team.atlas.id)
        })
        #expect(off.message.contains("ele inicia o trabalho de “Estúdio” na tela do grupo"))
        #expect(hub.requests.isEmpty && model.groupHub.run(model.groups[0].id) == nil)
    }

    @Test func listSaysWhoWaitsForTheUsersApproval() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Grave o resumo.")
            default:
                if seen.toolResult != nil { return say("Feito.") }
                let arguments = JSONValue.object(["fact": .string("O resumo sai às sextas.")]).jsonString
                return [.toolCalls([ToolCallRequest(id: "m1", name: "remember", arguments: arguments)])] // asks first in mode ask
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        model.send("peça", to: team.atlas.id, fromUser: true)
        await waitUntil("the card") { !model.pendingApprovals(of: team.pesquisador.id).isEmpty && model.live(team.pesquisador.id).needsYou }
        let list = try await model.delegation.handleTool(.object(["action": .string("list")]), orb: team.atlas.id)
        #expect(list.contains("- Pesquisador: Pesquisa e resume (espera aprovação do usuário)"))
        let card = try #require(model.pendingApprovals(of: team.pesquisador.id).first)
        model.giveUpWaiting(on: card.id, of: team.pesquisador.id)
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
    private func group(_ team: Team) -> OrbGroup {
        let hub = team.model.groupHub
        hub.settle = .zero
        hub.isAppActive = { false }
        return team.model.createGroup(name: "Lançamento", members: [team.atlas.id, team.pesquisador.id, team.revisor.id])!
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

    @Test func theAnswerWakesTheOrchestratorWithNoPauseHoweverManyTurns() async throws {
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
        let group = group(team)
        team.model.postUserMessage("Descubra o número", to: group.id)
        await waitUntil("the answer to wake the orchestrator") { self.finalPosts(team, group, "Fechado com o que o Pesquisador achou.") == 1 }
        await waitUntil("the request to end") { team.model.groupHub.run(group.id) == nil }
        await team.settle()
        #expect(finalPosts(team, group, "Fechado com o que o Pesquisador achou.") == 1)
        #expect(team.model.groupSession(group.id)?.items.contains { if case .groupPause = $0.kind { true } else { false } } == false)
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

    @Test func listInTheGroupSaysWhatEachMemberIsDoingAndForWhom() async throws {
        let research = TestGate(), review = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Dividi o trabalho.") }
                if seen.user.contains("Mercado pesquisado") || seen.user.contains("Revisado") { return say("Pronto.") }
                return twoCalls([("Pesquisador", "Pesquise o mercado de cafés especiais"), ("Revisor", "Revise o texto")])
            case "Pesquisador":
                await research.wait()
                return say("Mercado pesquisado.")
            case "Revisor":
                if seen.toolResult != nil { return say("Revisado.") }
                await review.wait()
                return [.toolCalls([ToolCallRequest(id: "l1", name: "orbs", arguments: JSONValue.object(["action": .string("list")]).jsonString)])]
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        let group = group(team)
        model.postUserMessage("Preparar o lançamento", to: group.id)
        await waitUntil("the researcher at work and the orchestrator waiting") {
            team.request(from: team.atlas, to: team.pesquisador)?.state == .running
                && hub.requests.values.contains { $0.envelope.to.id == team.atlas.id && $0.state == .awaitingChildren }
        }
        await review.open()
        await waitUntil("the list") { await team.log.calls(by: "Revisor").contains { $0.toolResult != nil } }
        let list = try #require(await team.log.calls(by: "Revisor").first { $0.toolResult != nil }?.toolResult)
        #expect(list.contains("- Atlas: Coordena o trabalho (esperando Pesquisador e Revisor em “Preparar o lançamento” (pedido do usuário))"))
        #expect(list.contains("- Pesquisador: Pesquisa e resume (trabalhando em “Pesquise o mercado de cafés especiais” (pedido de Atlas, há menos de 1 min))"))
        await research.open()
        await waitUntil("the group to finish") { model.groupHub.run(group.id) == nil }
        await team.settle()
    }

    @Test func twoMessagesInARowToTheGroupAreOneTurnOfTheOrchestrator() async throws {
        let team = Team { seen in seen.who == "Atlas" ? say("Entendi as duas partes.") : say("?") }
        defer { team.cleanUp() }
        let model = team.model
        let group = group(team)
        model.postUserMessage("Decidam entre si quem faz o texto.", to: group.id)
        model.postUserMessage("Pra que eu autorize ou não.", to: group.id)
        await waitUntil("the group to finish") { model.groupHub.run(group.id) == nil }
        await team.settle()
        let calls = await team.log.calls(by: "Atlas")
        #expect(calls.count == 1)
        #expect(calls.first?.user.contains("Decidam entre si quem faz o texto.\n\nPra que eu autorize ou não.") == true)
    }

    @Test func aTellInTheGroupIsAPostInTheThreadAndRunsNoTurn() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Fechado.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Levante os preços.")
            case "Pesquisador":
                if seen.toolResult != nil { return say("Preços levantados.") }
                return orbsCall("tell", to: "Revisor", "Os preços mudaram.")
            default: return say("Vi que os preços mudaram.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        let group = group(team)
        model.postUserMessage("Levantem os preços", to: group.id)
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil && self.finalPosts(team, group, "Fechado.") == 1 }
        await team.settle()
        #expect(await team.log.count(by: "Revisor") == 0)
        let tell = try #require(posts(team, group).first { $0.kind == .tell && $0.to?.name == "Revisor" })
        #expect(tell.from.name == "Pesquisador" && tell.text == "Os preços mudaram." && tell.state == .replied)
        let done = (model.groupSession(group.id)?.items ?? []).compactMap { if case .event(let event) = $0.kind, event.kind == .groupRunDone { event } else { nil } }
        #expect(done.first?.detail?.hasPrefix("3 turnos") == true) // Atlas, Pesquisador, Atlas again: the notice cost none
        // The Revisor's next turn in the group reads it in the thread.
        model.postUserMessage("@Revisor o que mudou?", to: group.id)
        await waitUntil("the second request to end") { model.groupHub.run(group.id) == nil && (team.botTexts(team.revisor).isEmpty) }
        await waitUntil("the Revisor to answer") { await team.log.count(by: "Revisor") == 1 }
        await team.settle()
        let read = try #require(await team.log.calls(by: "Revisor").first)
        #expect(read.user.contains("[Pesquisador → Revisor] <orb_message>Os preços mudaram.</orb_message>"))
        #expect(!read.user.contains("<orb_notice"))
    }

    // MARK: The chain inside a group, and a member's conversation

    /// Inside a group a member deep in the chain still asks whom it needs (the limit of four that cut this is gone: `c3d8029`).
    @Test func aChainFourDeepInsideTheGroupGoesAndComesBack() async throws {
        let team = Team(extra: ["Dev"]) { seen in
            let answered = seen.user.contains("<orb_reply")
            switch seen.who {
            case "Atlas":
                if answered { return say("Entregue: soma testada e revisada.") }
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Implemente soma.")
            case "Pesquisador":
                if answered { return say("Soma pronta e testada.") }
                if seen.toolResult != nil { return say("Pedi teste.") }
                return orbsCall("ask", to: "Revisor", "Teste soma.")
            case "Revisor":
                if answered { return say("Testei; o Dev revisou.") }
                if let result = seen.toolResult { return say("Recusado: \(result)") }
                return orbsCall("ask", to: "Dev", "Revise o teste.")
            default: return say("Revisado.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, dev = team.others[0]
        let group = try #require(model.createGroup(name: "Estúdio", members: [team.atlas.id, team.pesquisador.id, team.revisor.id, dev.id]))
        model.groupHub.settle = .zero
        model.postUserMessage("Implementem soma e testem", to: group.id)
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil && self.finalPosts(team, group, "Entregue: soma testada e revisada.") == 1 }
        await team.settle()
        let deepest = try #require(team.request(from: team.revisor, to: dev))
        #expect(deepest.state == .replied && deepest.envelope.hop >= 4)
        #expect(!(await team.log.calls(by: "Revisor")).contains { $0.toolResult?.contains("Recusado") == true || $0.toolResult?.contains("Error") == true })
        #expect(posts(team, group).contains { $0.from.name == "Revisor" && $0.to?.name == "Dev" && $0.kind == .ask })
    }

    /// A member waiting for its helper (its conversation kept in memory) is given a second task in the same group: when the
    /// first resumes, the second turn is still in the member's conversation of the group.
    @Test func aSecondTurnOfAMemberWhileItsFirstWaitsIsNotLostWhenTheFirstResumes() async throws {
        let valve = TestGate()
        let team = Team { seen in
            let answered = seen.user.contains("<orb_reply")
            switch seen.who {
            case "Atlas":
                if answered { return say("Fechado.") }
                if seen.toolResult != nil { return say("Pedi.") }
                return orbsCall("ask", to: "Pesquisador", "Faça a parte 1.")
            case "Pesquisador":
                if answered { return say("Parte 1 revisada.") }
                if seen.user.contains("parte 2") { return say("Parte 2 feita.") }
                if seen.toolResult != nil { return say("Aguardo o Revisor.") }
                return orbsCall("ask", to: "Revisor", "Revise a parte 1.")
            default:
                await valve.wait()
                return say("Revisado.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        let group = group(team)
        model.postUserMessage("Façam a parte 1", to: group.id)
        await waitUntil("the member to wait for its helper") { team.request(from: team.atlas, to: team.pesquisador)?.state == .awaitingChildren }
        model.postUserMessage("@Pesquisador e a parte 2?", to: group.id)
        await waitUntil("the second turn to end") { self.finalPosts(team, group, "Parte 2 feita.") == 1 }
        await valve.open()
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil && self.finalPosts(team, group, "Fechado.") == 1 }
        await team.settle()
        let side = try #require(model.store.readSideConversation(prefix: Store.grupoPrefix, id: group.id, for: team.pesquisador.id).value)
        let said = side.items.compactMap { if case .bot(let text, _) = $0.kind { text } else { nil } }
        #expect(said == ["Aguardo o Revisor.", "Parte 2 feita.", "Parte 1 revisada."])
    }

    // MARK: A group asked from a member's chat

    private func posts(_ team: Team, _ group: OrbGroup) -> [OrbMessageItem] {
        (team.model.groupSession(group.id)?.items ?? []).compactMap {
            if case .orbMessage(let message) = $0.kind, message.direction == .post { message } else { nil }
        }
    }

    private func groupEvents(_ team: Team, _ group: OrbGroup) -> [OrbEvent.Kind] {
        (team.model.groupSession(group.id)?.items ?? []).compactMap { if case .event(let event) = $0.kind { event.kind } else { nil } }
    }

    @Test func aMemberAsksItsGroupFromItsChatAndTheGroupsFinalAnswerComesBack() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Pesquisador":
                if seen.user.contains("<orb_reply") { return say("O grupo respondeu.") }
                if seen.toolResult != nil { return say("Pedi ao grupo.") }
                return orbsCall("ask", to: "lançamento", "Levantem o mercado.")
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("Mercado levantado e revisado.") }
                if seen.toolResult != nil { return say("Pedi ao Revisor.") }
                return orbsCall("ask", to: "Revisor", "Revise o levantamento.")
            default: return say("Revisado.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team)
        team.model.send("pede pro grupo Lançamento levantar o mercado", to: team.pesquisador.id, fromUser: true)
        await waitUntil("the asker to hear from the group") { team.botTexts(team.pesquisador).contains("O grupo respondeu.") }
        await waitUntil("the request to end") { team.model.groupHub.run(group.id) == nil }
        await team.settle()

        // The thread: the member's request, marked as sent from its chat, then the work and the answer that went back to it.
        let thread = posts(team, group)
        let asked = try #require(thread.first)
        #expect(asked.from.name == "Pesquisador" && asked.to?.name == "Atlas" && asked.kind == .ask && asked.fromChat == true)
        #expect(asked.text == "Levantem o mercado." && asked.state == .replied)
        #expect(GroupAssignmentLine.sentence(kind: asked.kind, toName: "Atlas", text: asked.text, fromChat: true)
            == "pediu ao Atlas, a seu pedido: Levantem o mercado.")
        #expect(thread.contains { $0.from.name == "Atlas" && $0.to?.name == "Revisor" && $0.kind == .ask })
        let final = try #require(thread.last)
        #expect(final.kind == .reply && final.text == "Mercado levantado e revisado." && final.to?.name == "Pesquisador")
        #expect(groupEvents(team, group).filter { $0 == .groupRunDone }.count == 1)
        // The orchestrator got one turn for it, with the request as the member's data, not the person's word.
        let opening = await team.log.calls(by: "Atlas").filter { $0.toolResult == nil && $0.user.contains("<orb_request from=\"Pesquisador\"") }
        #expect(opening.count == 1)
        #expect(opening.first?.user.contains("Pesquisador, a member of this group, sent this to the group from their own chat") == true)
        #expect(opening.first?.user.contains("It is not the user's own message") == true)
        #expect(team.model.groupSession(group.id)?.items.contains { if case .user = $0.kind { true } else { false } } == false)
        // The asker's chat: the request to the group (by its name), answered, and the group's answer that woke it.
        let lines = team.orbMessages(team.pesquisador)
        #expect(lines.first?.direction == .sent && lines.first?.to?.name == "Lançamento" && lines.first?.state == .replied)
        let reply = try #require(lines.first { $0.direction == .reply })
        #expect(reply.from.name == "Lançamento" && reply.text == "Mercado levantado e revisado.")
        let wake = try #require(await team.log.calls(by: "Pesquisador").last)
        #expect(wake.user.contains("<orb_reply from=\"Lançamento\""))
        #expect(team.botTexts(team.pesquisador) == ["Pedi ao grupo.", "O grupo respondeu."])
        // The tool's answer told the asker where it went.
        let result = try #require(await team.log.calls(by: "Pesquisador").first { $0.toolResult != nil }?.toolResult)
        #expect(result.hasPrefix("Pedido enviado ao grupo Lançamento"))
    }

    @Test func theOrchestratorAsksItsOwnGroupFromItsChatAndHearsBackThere() async throws {
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.user.contains("<orb_reply") { return say("O grupo fechou o plano.") }
                if seen.user.contains("<orb_request") { return say("Plano pronto: lançar em outubro.") }
                if seen.toolResult != nil { return say("Pedi ao grupo.") }
                return orbsCall("ask", to: "Lançamento", "Fechem o plano de lançamento.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let group = group(team)
        team.model.send("usa o grupo pra fechar o plano", to: team.atlas.id, fromUser: true)
        await waitUntil("the chat to hear from the group") { team.botTexts(team.atlas).contains("O grupo fechou o plano.") }
        await waitUntil("the request to end") { team.model.groupHub.run(group.id) == nil }
        await team.settle()
        let opening = try #require(await team.log.calls(by: "Atlas").first { $0.user.contains("<orb_request") })
        #expect(opening.user.contains("You sent this to the group from your own chat, at the user's request."))
        #expect(opening.user.contains("goes back to your own chat automatically"))
        // The thread has the request and the answer; the chat has the group's answer, not a word of the group turn.
        let thread = posts(team, group)
        #expect(thread.count == 2 && thread[0].fromChat == true && thread[1].text == "Plano pronto: lançar em outubro.")
        #expect(thread[1].to == nil) // its own request: no arrow back to itself
        #expect(team.botTexts(team.atlas) == ["Pedi ao grupo.", "O grupo fechou o plano."])
        let reply = try #require(team.orbMessages(team.atlas).first { $0.direction == .reply })
        #expect(reply.from.name == "Lançamento" && reply.text == "Plano pronto: lançar em outubro.")
    }

    @Test func aGroupIsAskedOnlyFromTheChatAtThePersonsRequestAndEachRefusalSaysWhy() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Pesquisador":
                if let result = seen.toolResult { return say("Resultado: \(result)") }
                return orbsCall("ask", to: "Lançamento", "Avisem o grupo.")
            case "Atlas":
                await valve.wait()
                return say("Ok.")
            default: return say("?")
            }
        }
        defer { team.cleanUp() }
        let model = team.model, hub = model.delegation
        let group = group(team)
        func refusal(from bot: Bot, _ kind: String = "ask") async -> String {
            do {
                _ = try await hub.handleTool(.object(["action": .string(kind), "to": .string("Lançamento"), "message": .string("x")]),
                                             orb: bot.id)
                return ""
            } catch { return (error as? ToolError)?.message ?? "" }
        }
        // A routine's run is refused, with the reason, and no request reaches the group.
        model.routines = [Routine(name: "Aviso", botID: team.pesquisador.id, prompt: "Avise o grupo Lançamento.", schedule: .daily(hour: 9, minute: 0))]
        model.runRoutine(model.routines[0].id)
        await team.settle()
        let routine = try #require(await team.log.calls(by: "Pesquisador").first { $0.toolResult != nil }?.toolResult)
        #expect(routine.contains("Daqui não se aciona o grupo “Lançamento”: só do seu chat, a pedido do usuário"))
        #expect(model.groupHub.run(group.id) == nil && posts(team, group).isEmpty)
        // In the chat, a turn the person did not start (an answer woke it) is refused too; and so is a tell.
        let session = model.session(team.pesquisador.id)
        session.turnAskedByUser = false
        #expect(await refusal(from: team.pesquisador).hasPrefix("Você só aciona o grupo “Lançamento” quando o usuário pede"))
        session.turnAskedByUser = true
        #expect(await refusal(from: team.pesquisador, "tell").hasPrefix("Para um grupo, use ask"))
        // The switch of Ajustes.
        model.orbsCanStartGroups = false
        #expect(await refusal(from: team.pesquisador).hasPrefix("O usuário desligou “Orbs podem acionar grupos”"))
        model.orbsCanStartGroups = true
        // Not a member.
        let other = try #require(model.createGroup(name: "Dupla", members: [team.atlas.id, team.revisor.id]))
        do {
            _ = try await hub.handleTool(.object(["action": .string("ask"), "to": .string("Dupla"), "message": .string("x")]),
                                         orb: team.pesquisador.id)
            Issue.record("a group it is not in took the request")
        } catch { #expect((error as? ToolError)?.message.hasPrefix("Você não faz parte do grupo “Dupla”") == true) }
        // A group already at work.
        model.postUserMessage("Preparar o lançamento", to: group.id)
        await waitUntil("the orchestrator to work") { model.isWorking(team.atlas.id) }
        #expect(await refusal(from: team.pesquisador).hasPrefix("O grupo “Lançamento” já está trabalhando num pedido"))
        session.turnAskedByUser = false
        await valve.open()
        await waitUntil("the request to end") { model.groupHub.run(group.id) == nil }
        await team.settle()
        #expect(model.groupHub.run(other.id) == nil)
    }

    @Test func stoppingTheChatThatWaitsForItsGroupStopsTheGroup() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Pesquisador":
                if seen.user.contains("<orb_reply") { return say("Não devia chegar.") }
                if seen.toolResult != nil { return say("Pedi ao grupo.") }
                return orbsCall("ask", to: "Lançamento", "Levantem o mercado.")
            default:
                await valve.wait()
                return say("Tarde.")
            }
        }
        defer { team.cleanUp() }
        let model = team.model
        let group = group(team)
        model.send("pede pro grupo", to: team.pesquisador.id, fromUser: true)
        await waitUntil("the orchestrator to work") { model.isWorking(team.atlas.id) && team.botTexts(team.pesquisador) == ["Pedi ao grupo."] }
        #expect(model.live(team.pesquisador.id).chainWork?.text == "Esperando Lançamento")
        model.stop(team.pesquisador.id) // the Parar of its waiting line
        #expect(groupEvents(team, group).contains(.groupStopped))
        #expect(team.orbMessages(team.pesquisador).first?.state == .cancelled)
        await valve.open()
        await team.settle()
        await waitUntil("the group to be idle") { !model.isGroupWorking(group.id) }
        #expect(!groupEvents(team, group).contains(.groupRunDone))
        #expect(team.botTexts(team.pesquisador) == ["Pedi ao grupo."])
    }

    @Test func stoppingTheGroupDoesNotWriteInTheOrchestratorsPrivateChat() async throws {
        let valve = TestGate()
        let team = Team { seen in
            switch seen.who {
            case "Atlas":
                if seen.toolResult != nil { return say("Pedi ao Pesquisador.") }
                return orbsCall("ask", to: "Pesquisador", "Pesquise.")
            default:
                await valve.wait()
                return say("Achei 42.")
            }
        }
        defer { team.cleanUp() }
        let group = group(team)
        team.model.postUserMessage("Descubra o número", to: group.id)
        await waitUntil("the researcher to be asked") { team.request(from: team.atlas, to: team.pesquisador) != nil }
        team.model.stopGroup(group.id)
        await valve.open()
        await team.settle()
        #expect(team.model.groupLive(group.id).runState == .idle)
        #expect(!team.events(team.atlas).contains { $0.kind == .chainStopped })
        #expect(team.model.groupSession(group.id)?.items.contains { if case .event(let event) = $0.kind { event.kind == .groupStopped } else { false } } == true)
    }
}
