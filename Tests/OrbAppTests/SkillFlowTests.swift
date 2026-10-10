import Foundation
import Testing
@testable import Orb

/// What a model call was given, and the answers it gives in order (the last repeats): a turn of the app without a provider.
private actor Script {
    struct Call { var messages: [ChatMessage]; var tools: [String]; var system: String }
    private(set) var calls: [Call] = []
    private var answers: [[LLMEvent]]
    /// The model call (1 = the first) that waits for `release()` before it answers.
    private let holdsCall: Int?
    private var released = false

    init(_ answers: [[LLMEvent]], holdsCall: Int? = nil) {
        self.answers = answers
        self.holdsCall = holdsCall
    }

    func release() { released = true }

    /// Sets the answers after the init (when they need what `setUp` made).
    func setAnswers(_ new: [[LLMEvent]]) { answers = new }

    func answer(_ messages: [ChatMessage], _ tools: [ToolSpec]) async -> [LLMEvent] {
        calls.append(Call(messages: Array(messages.dropFirst()), tools: tools.map(\.name), system: messages.first?.content ?? ""))
        let number = calls.count
        let events = answers.count > 1 ? answers.removeFirst() : answers.first ?? []
        while holdsCall == number, !released { try? await Task.sleep(for: .milliseconds(5)) }
        return events
    }
}

private struct ScriptedModel: LLMClient {
    let script: Script

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.answer(messages, tools) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private func said(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func call(_ name: String, _ arguments: JSONValue, id: String = UUID().uuidString) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: id, name: name, arguments: arguments.jsonString)]), .finished(.toolUse, nil)]
}

/// The Orb's skills in its tools, and the skills it proposes while it works.
@Suite(.serialized) final class SkillFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSkillFlow-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ script: Script) -> (AppModel, UUID) {
        var state = AppState.initial
        let folder = root.appending(path: "pasta")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        state.bots[0].workingDirectory = folder.path
        state.bots[0].capabilities = [.terminal]
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { ScriptedModel(script: script) }
        return (model, state.bots[0].id)
    }

    @MainActor private func waitUntilIdle(_ model: AppModel, _ botID: UUID) async {
        await waitUntil("the Orb to finish its turn") { !model.isWorking(botID) && model.session(botID).turnTask == nil }
    }

    // MARK: The skills the tools can load

    @Test @MainActor func everyMessagePublishesTheSkillsTheOrbMayUse() async {
        let script = Script([said("oi")])
        let (model, botID) = setUp(script)
        let other = UUID()
        model.skills = [Skill(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma em 5 tópicos.", source: Skill.builtInSource),
                        Skill(slug: "desligada", name: "Desligada", summary: "", instructions: "x", isEnabled: false),
                        Skill(slug: "de-outro", name: "De outro", summary: "", instructions: "x", orbIDs: [other]),
                        Skill(slug: "meu", name: "Meu", summary: "", instructions: "y", source: Skill.learnedSource)]
        #expect(model.send("oi", to: botID))
        await waitUntilIdle(model, botID)
        let bank = model.memory.bank(for: botID)
        await waitUntil("the skills in the Orb's memory folder") { await bank.skillDigests().count == 2 }
        let digests = await bank.skillDigests()
        #expect(digests.map(\.slug) == ["resumir", "meu"])
        #expect(digests.map(\.improvable) == [false, true])
        #expect(await bank.skillText(named: "/resumir").contains("Resuma em 5 tópicos."))
    }

    // MARK: The review

    /// One model answer that asks for `count` recalls at once: one step, however many calls.
    private func recalls(_ count: Int) -> [LLMEvent] {
        let id = UUID().uuidString
        return [.toolCalls((0..<count).map { ToolCallRequest(id: "\(id)-\($0)", name: "recall", arguments: #"{"query":"deploy"}"#) }), .finished(.toolUse, nil)]
    }

    /// `count` model answers that each ask for one recall: `count` steps.
    private func steps(_ count: Int) -> [[LLMEvent]] { (0..<count).map { _ in recalls(1) } }

    private func proposing(_ text: String) -> [LLMEvent] {
        call("remember", .object(["fact": .string(text), "tipo": .string("skill")]))
    }

    @MainActor private func notices(_ model: AppModel, _ botID: UUID) -> [String] {
        model.transcript(botID).compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    @Test @MainActor func aLongTurnEndsWithAReviewThatKeepsAProposalAndTellsOnce() async throws {
        let script = Script(steps(10) + [said("pronto"), proposing(SkillSamples.good), said("Propus /publicar-site.")])
        let (model, botID) = setUp(script)
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        let bank = model.memory.bank(for: botID)
        await waitUntil("the proposal") { await bank.proposals().count == 1 }
        await waitUntil("the notice") { !notices(model, botID).isEmpty }
        #expect(notices(model, botID) == ["Skill proposta: /publicar-site — Publicar site"])

        // The review is one more call of the same conversation: same system prompt, same tools, the turn's whole
        // history as it was, and then the review's message (so the provider's cache is still good).
        let calls = await script.calls
        #expect(calls.count == 13)
        #expect(calls[11].system == calls[10].system && calls[11].tools == calls[10].tools && !calls[11].tools.isEmpty)
        #expect(Array(calls[11].messages.prefix(calls[10].messages.count)) == calls[10].messages)
        #expect(calls[11].messages.last?.role == .user && calls[11].messages.last?.content == SkillReview.prompt)
        #expect(calls[11].messages.dropLast().last?.content == "pronto")

        // Nothing of it is in the chat or in the model's history, and the count starts over.
        let session = model.session(botID)
        #expect(session.conversation?.messages.last?.content == "pronto")
        #expect(session.conversation?.messages.allSatisfy { !$0.content.contains("Review the conversation above") } == true)
        #expect(session.stepsSinceSkill == 0 && session.skillReview == nil)
        #expect(model.transcript(botID).filter { if case .bot = $0.kind { true } else { false } }.count == 1)
        await model.collectSkillProposals(botID)
        #expect(notices(model, botID).count == 1)
    }

    @Test @MainActor func theReviewSendsTheBigOutputsAndArgumentsOfTheTurnWholeLikeItsLastCall() async throws {
        // A file read bigger than a preview, and a call with arguments bigger than the shortened ones.
        let script = Script([])
        let (model, botID) = setUp(script)
        let file = root.appending(path: "pasta/grande.txt")
        try String(repeating: "linha de texto do arquivo\n", count: 400).write(to: file, atomically: true, encoding: .utf8)
        let read = call("read_file", .object(["path": .string(file.path), "nota": .string(String(repeating: "n", count: 1_500))]), id: "grande")
        await script.setAnswers([read] + steps(9) + [said("pronto"), said("Nothing to save.")])
        #expect(model.send("le o arquivo e publica", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to end") { await script.calls.count == 12 && model.session(botID).skillReview == nil }

        let calls = await script.calls
        let result = try #require(calls[10].messages.first { $0.role == .tool && $0.toolCallID == "grande" })
        #expect(result.content.count > ContextWindow.toolOutputPreview)
        #expect(calls[10].messages.contains { $0.toolCalls.contains { $0.id == "grande" && $0.arguments.count > 1_500 } })
        // Same prefix as the turn's last call, big output and arguments included.
        #expect(Array(calls[11].messages.prefix(calls[10].messages.count)) == calls[10].messages)
        #expect(calls[11].messages.last?.content == SkillReview.prompt)
    }

    @Test @MainActor func noReviewIsPaidForWhileFiveProposalsWait() async throws {
        let script = Script(steps(10) + [said("pronto"), said("Nothing to save.")])
        let (model, botID) = setUp(script)
        let bank = model.memory.bank(for: botID)
        for index in 0..<MemoryBank.maximumProposals {
            let skill = SkillSamples.good.replacingOccurrences(of: "publicar-site", with: "publicar-site-\(index)")
            guard case .proposed = await bank.proposeSkill(skill) else { Issue.record("proposal \(index) refused"); return }
        }
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to give up") { model.session(botID).skillReview == nil }
        #expect(await script.calls.count == 11)
        #expect(model.session(botID).stepsSinceSkill == 0)
    }

    @Test @MainActor func whatTheReviewCostsIsInTheUsageHistoryApartFromTheChat() async throws {
        func counted(_ events: [LLMEvent]) -> [LLMEvent] {
            events.map { if case .finished(let reason, nil) = $0 { .finished(reason, TokenUsage(input: 10, output: 5)) } else { $0 } }
        }
        let script = Script((steps(10) + [said("pronto"), proposing(SkillSamples.good), said("Propus /publicar-site.")]).map(counted))
        let (model, botID) = setUp(script)
        #expect(model.send("publica o site", to: botID))
        await waitUntilIdle(model, botID)
        let bank = model.memory.bank(for: botID)
        await waitUntil("the proposal") { await bank.proposals().count == 1 }
        await waitUntil("the review's usage") {
            model.usageLog.flush()
            model.store.flush()
            let found = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).buckets
            return found.contains { $0.key.source == .auxiliary && $0.totals.requests == 2 }
        }
        let buckets = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).buckets
        func total(_ source: UsageSource) -> UsageTotals {
            buckets.filter { $0.key.source == source && $0.key.orb == botID && $0.key.model == "custom/modelo" }
                .reduce(into: UsageTotals()) { $0.add($1.totals) }
        }
        #expect(total(.chat) == UsageTotals(requests: 11, input: 110, output: 55))
        #expect(total(.auxiliary) == UsageTotals(requests: 2, input: 20, output: 10))
    }

    @Test @MainActor func aShortTurnHasNoReview() async {
        let script = Script(steps(SkillReview.threshold - 1) + [said("pronto")])
        let (model, botID) = setUp(script)
        #expect(model.send("oi", to: botID))
        await waitUntilIdle(model, botID)
        #expect(model.session(botID).stepsSinceSkill == SkillReview.threshold - 1 && model.session(botID).skillReview == nil)
        #expect(await script.calls.count == SkillReview.threshold)
    }

    @Test @MainActor func tenCallsInOneStepAreOneStepNotAReview() async {
        // Independent reads run together (the prompt asks for it): the count is of the model's steps, as in Hermes.
        let script = Script([recalls(10), said("pronto")])
        let (model, botID) = setUp(script)
        #expect(model.send("oi", to: botID))
        await waitUntilIdle(model, botID)
        #expect(model.session(botID).stepsSinceSkill == 1 && model.session(botID).skillReview == nil)
        #expect(await script.calls.count == 2)
    }

    @Test @MainActor func theCountGrowsAcrossTurnsAndStartsOverAtTheReview() async {
        let script = Script(steps(6) + [said("um")] + steps(6) + [said("dois"), said("Nothing to save.")])
        let (model, botID) = setUp(script)
        #expect(model.send("primeiro", to: botID))
        await waitUntilIdle(model, botID)
        #expect(model.session(botID).stepsSinceSkill == 6 && model.session(botID).skillReview == nil)
        #expect(model.send("segundo", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to answer") { await script.calls.count == 15 && model.session(botID).skillReview == nil }
        #expect(model.session(botID).stepsSinceSkill == 0)
        #expect(notices(model, botID).isEmpty) // "Nothing to save." says nothing
    }

    @Test @MainActor func theSwitchInAjustesTurnsTheReviewOff() async {
        let script = Script(steps(10) + [said("pronto")])
        let (model, botID) = setUp(script)
        let suite = UserDefaults(suiteName: "OrbSkillFlow-\(UUID().uuidString)")!
        suite.set(false, forKey: SkillReview.settingKey)
        model.preferences = suite
        #expect(model.send("publica", to: botID))
        await waitUntilIdle(model, botID)
        #expect(model.session(botID).skillReview == nil && model.session(botID).stepsSinceSkill == 10)
        #expect(await script.calls.count == 11)
    }

    @Test @MainActor func anOrbThatOnlyReadsDoesNotReview() async {
        let script = Script(steps(10) + [said("pronto")])
        let (model, botID) = setUp(script)
        model.bots[0].permissionMode = .readOnly
        #expect(model.send("publica", to: botID))
        await waitUntilIdle(model, botID)
        #expect(model.session(botID).skillReview == nil)
        #expect(await script.calls.count == 11)
    }

    @Test @MainActor func aMessageFromTheUserStopsTheReview() async {
        // The review's model call (the third) waits; the user writes meanwhile.
        let script = Script(steps(10) + [said("pronto"), proposing(SkillSamples.good), said("ok"), said("segunda")], holdsCall: 12)
        let (model, botID) = setUp(script)
        #expect(model.send("publica", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to ask the model") { await script.calls.count == 12 }
        #expect(model.session(botID).skillReview != nil)
        #expect(model.send("e agora outra coisa", to: botID))
        #expect(model.session(botID).skillReview == nil)
        await script.release()
        await waitUntilIdle(model, botID)
        let bank = model.memory.bank(for: botID)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await bank.proposals().isEmpty)
        #expect(notices(model, botID).isEmpty)
    }

    @Test @MainActor func onlyStepsOfOrbsOwnEngineInConversationsCount() {
        let script = Script([])
        let (model, botID) = setUp(script)
        let session = model.session(botID)
        let read = ToolCallRequest(id: "a", name: "read_file", arguments: "{}")
        let step = ChatMessage(role: .assistant, content: "", toolCalls: [read, ToolCallRequest(id: "b", name: "read_file", arguments: "{}")])
        let base = TurnRequest(bot: model.bots[0], model: "m", system: "s", history: [], prompt: "",
                               client: ScriptedModel(script: script), tools: [], context: ToolContext(workingDirectory: root))
        // A turn of Claude Code keeps no request for a review: its steps are not counted.
        model.apply(.message(step), to: botID)
        #expect(session.stepsSinceSkill == 0)
        session.reviewBase = base
        // Two calls in one answer are one step; an answer with no tools, a tool result and a message of the user are none.
        model.apply(.message(step), to: botID)
        model.apply(.message(.tool("a", "x")), to: botID)
        model.apply(.message(ChatMessage(role: .assistant, content: "pronto")), to: botID)
        model.apply(.message(.user("e agora")), to: botID)
        #expect(session.stepsSinceSkill == 1)
        model.apply(.message(step), to: botID)
        #expect(session.stepsSinceSkill == 2)
        // A routine's run is nobody's lesson.
        session.routineID = UUID()
        model.apply(.message(step), to: botID)
        #expect(session.stepsSinceSkill == 2)
        session.routineID = nil
        // A proposal starts the count over.
        model.apply(.toolStarted(ToolCall(kind: .memory, title: RememberTool.skillTitle, detail: "publicar-site")), to: botID)
        #expect(session.stepsSinceSkill == 0)
    }

    @Test @MainActor func aTaskLeftHalfWayDoesNotStartAReview() async {
        let script = Script([said("Nothing to save.")])
        let (model, botID) = setUp(script)
        let session = model.session(botID)
        let base = TurnRequest(bot: model.bots[0], model: "m", system: "s", history: [], prompt: "",
                               client: ScriptedModel(script: script), tools: [], context: ToolContext(workingDirectory: root))
        func finish(paused: Bool) {
            let turn = session.beginTurn()
            session.reviewBase = base
            session.turnTask = Task {}
            session.stepsSinceSkill = SkillReview.threshold
            model.apply(.message(.user("tarefa")), to: botID)
            model.apply(.message(ChatMessage(role: .assistant, content: "parei")), to: botID)
            if paused { model.apply(.taskPaused, to: botID) }
            model.finishTurn(botID, turn: turn)
        }
        finish(paused: true)
        #expect(session.skillReview == nil && session.stepsSinceSkill == SkillReview.threshold)
        finish(paused: false)
        #expect(session.skillReview != nil && session.stepsSinceSkill == 0)
    }

    @Test @MainActor func aReviewInAnOrbInAskModeNeverOpensACard() async throws {
        // The model tries to save a preference in the review: nobody would see the card, so it is refused at once.
        let preference = call("remember", .object(["fact": .string("Gosta de respostas curtas."), "tipo": .string("preferencia")]))
        let script = Script(steps(10) + [said("pronto"), preference, said("Nothing to save.")])
        let (model, botID) = setUp(script)
        model.bots[0].permissionMode = .ask
        #expect(model.send("publica", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to end") { await script.calls.count == 13 && model.session(botID).skillReview == nil }
        #expect(await model.gate.openIDs(for: botID).isEmpty)
        let calls = await script.calls
        let answer = try #require(calls[12].messages.last)
        #expect(answer.role == .tool && answer.isError && answer.content.contains("This review only proposes skills"))
        #expect(await model.memory.bank(for: botID).snapshot().items.isEmpty)
        #expect(!model.isWorking(botID))
    }

    @Test @MainActor func aReviewOfACompactedConversationStartsWhereTheLastTurnEnded() async throws {
        // The turns before the summary are not sent again, and the summary is the one the turn sent: same prefix.
        let script = Script(steps(10) + [said("pronto"), said("Nothing to save.")])
        let (model, botID) = setUp(script)
        model.providers[0].models = [ProviderModel(id: "modelo", name: "Modelo", format: .chat, contextLength: 16_000)]
        var old = Conversation()
        for index in 0..<12 {
            let id = "velho\(index)"
            old.messages += [.user("pedido número \(index) do projeto"),
                             ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: "read_file", arguments: #"{"path":"/p/a.swift"}"#)]),
                             .tool(id, String(repeating: "x", count: 25_000)),
                             ChatMessage(role: .assistant, content: "resposta \(index) " + String(repeating: "texto da resposta ", count: 200))]
        }
        model.seedConversation(old, for: botID)
        #expect(model.send("agora publica", to: botID))
        await waitUntilIdle(model, botID)
        await waitUntil("the review to end") { await script.calls.count == 12 && model.session(botID).skillReview == nil }
        let conversation = try #require(model.session(botID).conversation)
        #expect(conversation.coveredMessageCount > 0)
        let calls = await script.calls
        let last = calls[10], review = calls[11]
        #expect(last.messages.count < conversation.messages.count) // the turn did not send what the summary stands for
        #expect(Array(review.messages.prefix(last.messages.count)) == last.messages)
        // Nothing of the preparation is kept: the conversation is as the turn left it.
        #expect(conversation.messages.last?.content == "pronto")
    }

    @Test @MainActor func resettingStopsAReviewInProgress() async {
        let (model, botID) = setUp(Script([said("oi")]))
        let review = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        model.session(botID).skillReview = review
        await model.stopForReset(wait: .milliseconds(200))
        #expect(review.isCancelled && model.session(botID).skillReview == nil)
    }

    @Test @MainActor func aProposalIsToldAfterTheRoutineThatHadTheOrbNotInsideIt() async {
        let (model, botID) = setUp(Script([said("oi")]))
        _ = await model.memory.bank(for: botID).proposeSkill(SkillSamples.good)
        let session = model.session(botID)
        session.routineID = UUID()
        await model.collectSkillProposals(botID)
        #expect(notices(model, botID).isEmpty && session.announcedProposals.isEmpty)
        session.routineID = nil
        await model.collectSkillProposals(botID)
        #expect(notices(model, botID) == ["Skill proposta: /publicar-site — Publicar site"])
    }

    // MARK: Deciding

    @MainActor private func propose(_ proposal: String, in model: AppModel, _ botID: UUID) async {
        let bank = model.memory.bank(for: botID)
        _ = await bank.proposeSkill(proposal)
    }

    @Test @MainActor func aNewProposalBecomesALearnedSkillOfTheOrbThatProposedIt() async throws {
        let (model, botID) = setUp(Script([said("oi")]))
        await propose(SkillSamples.good, in: model, botID)
        let draft = try #require(await model.skillDraft("publicar-site", from: botID))
        #expect(!draft.isUpdate && draft.orbName == model.bots[0].name)
        #expect(draft.skill.slug == "publicar-site" && draft.skill.name == "Publicar site")
        #expect(draft.skill.source == Skill.learnedSource && draft.skill.learnedBy == botID && draft.skill.orbIDs == [botID])
        #expect(draft.skill.instructions.hasPrefix("## Quando usar"))
        #expect(await model.hasSkillProposal("publicar-site", of: botID))
        model.skills.append(draft.skill)
        model.finishSkillDraft(draft, saved: draft.skill)
        await waitUntil("the proposal to go") { !(await model.hasSkillProposal("publicar-site", of: botID)) }
        #expect(model.skills(for: botID).contains { $0.slug == "publicar-site" })
        #expect(await model.skillDraft("publicar-site", from: botID) == nil)
    }

    @Test @MainActor func anImprovementKeepsTheSkillAndItsUsesAndScope() async throws {
        let (model, botID) = setUp(Script([said("oi")]))
        let other = UUID()
        var mine = Skill(slug: "publicar-site", name: "Meu deploy", summary: "antigo", instructions: "antigas", source: Skill.learnedSource)
        mine.uses = 7
        mine.orbIDs = [botID, other]
        model.skills.append(mine)
        await propose(SkillSamples.good, in: model, botID)
        let draft = try #require(await model.skillDraft("publicar-site", from: botID))
        #expect(draft.isUpdate && draft.skill.id == mine.id && draft.skill.uses == 7 && draft.skill.orbIDs == [botID, other])
        #expect(draft.skill.name == "Meu deploy" && draft.skill.instructions.hasPrefix("## Quando usar"))
        #expect(draft.skill.summary.hasPrefix("Publica o site"))
        // Not saved yet: the skill is as it was.
        #expect(model.skills.first { $0.id == mine.id }?.instructions == "antigas")
    }

    @Test @MainActor func aCommandTakenByAnotherSkillGetsANumber() async throws {
        let (model, botID) = setUp(Script([said("oi")]))
        model.skills.append(Skill(slug: "publicar-site", name: "Do app", summary: "", instructions: "x", source: Skill.builtInSource))
        model.skills.append(Skill(slug: "publicar-site-2", name: "Outra", summary: "", instructions: "x", source: Skill.builtInSource))
        let unrelated = SkillSamples.changed("name: publicar-site", "name: publicar-site-3")
        await propose(unrelated, in: model, botID)
        let draft = try #require(await model.skillDraft("publicar-site-3", from: botID))
        #expect(!draft.isUpdate && draft.skill.slug == "publicar-site-3")
        // The proposal's own command is taken: the skill is saved with the next free one.
        await propose(SkillSamples.good, in: model, botID)
        let renamed = try #require(await model.skillDraft("publicar-site", from: botID))
        #expect(!renamed.isUpdate && renamed.skill.slug == "publicar-site-3" && renamed.slug == "publicar-site")
    }

    @Test @MainActor func discardingKeepsTheSkillsAsTheyWere() async throws {
        let (model, botID) = setUp(Script([said("oi")]))
        await propose(SkillSamples.good, in: model, botID)
        let draft = try #require(await model.skillDraft("publicar-site", from: botID))
        let before = model.skills.count
        model.finishSkillDraft(draft)
        await waitUntil("the proposal to go") { !(await model.hasSkillProposal("publicar-site", of: botID)) }
        #expect(model.skills.count == before)
    }
}
