import Foundation
import Testing
@testable import Orb

// The loop of a group (docs/MULTI-ORBS.md, 7.3), played with a fake delegation service: the person speaks, the orchestrator plans
// and assigns, the members work in parallel and talk to each other on their own, every answer wakes whoever asked, and the
// orchestrator closes the round. Plus the budget, the pause, Parar grupo, unread and the banners.

@MainActor
private func startOrchestratorTurn(_ world: GroupWorld, text: String = "Lance o produto") async -> DelegationRequest {
    world.model.postUserMessage(text, to: world.groupID)
    let turn = world.lastGroupTurn
    await world.fake.start(turn)
    return turn
}

struct GroupLoopTests {
    @Test @MainActor func aMessageWithoutMentionGoesToTheOrchestratorOnly() {
        let world = GroupWorld()
        #expect(world.model.postUserMessage("Lance o produto", to: world.groupID))
        #expect(world.fake.groupTurns.count == 1)
        let turn = world.lastGroupTurn
        #expect(turn.envelope.to.id == world.atlas.id && turn.envelope.text == "Lance o produto")
        #expect(turn.envelope.groupID == world.groupID && turn.envelope.chainID == world.hub.run(world.groupID)?.id)
        #expect(world.live.runState == .running)
        guard case .user(let text, _) = world.items.last?.kind else { Issue.record("the message is not in the thread"); return }
        #expect(text == "Lance o produto")
    }

    @Test @MainActor func aMentionCallsTheMemberDirectlyWithoutTheOrchestrator() {
        let world = GroupWorld()
        world.model.postUserMessage("@revisor olha esse texto", to: world.groupID)
        #expect(world.fake.groupTurns.map(\.envelope.to.id) == [world.revisor.id])
        world.model.postUserMessage("@Pesquisador e @Revisor, vejam", to: world.groupID)
        #expect(world.fake.groupTurns.map(\.envelope.to.id) == [world.revisor.id, world.pesquisador.id, world.revisor.id])
    }

    @Test @MainActor func everyoneIsCalledByTodos() {
        let world = GroupWorld()
        world.model.postUserMessage("@todos, bom dia", to: world.groupID)
        #expect(world.fake.groupTurns.map(\.envelope.to.id) == [world.atlas.id, world.pesquisador.id, world.revisor.id])
    }

    @Test @MainActor func anEmptyMessageOrAnUnknownGroupSendsNothing() {
        let world = GroupWorld()
        #expect(!world.model.postUserMessage("   ", to: world.groupID))
        #expect(!world.model.postUserMessage("oi", to: UUID()))
        #expect(world.fake.groupTurns.isEmpty && world.hub.run(world.groupID) == nil)
    }

    @Test @MainActor func theOrchestratorPlansAssignsAndTheMembersTalkWithoutAnyMention() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)

        // The orchestrator's first turn: the preface names the group, its role and the members; the person's message is the request, not the thread.
        let preface = world.fake.prefaces[first.envelope.id]?.first ?? ""
        #expect(preface.contains("<group name=\"Lançamento\" you=\"Atlas\" role=\"orchestrator\" budget=\"0 of 12 turns\">"))
        #expect(preface.contains("Members: Atlas (orchestrator), Pesquisador (Papel de Pesquisador), Revisor (Papel de Revisor)"))
        #expect(!preface.contains("<thread"))
        #expect(world.live.typing == [world.atlas.id])
        #expect(world.live.work?.phrase == "Atlas coordena…")

        // It splits the work: two asks, then ends its turn waiting for both.
        let research = try! world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise o mercado", parent: first)
        let review = try! world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "revise o texto", parent: first)
        world.fake.finish(first, reply: "Vou dividir: Pesquisador pesquisa e Revisor revisa.")
        #expect(world.fake.request(first.envelope.id).state == .awaitingChildren)
        #expect(world.live.typing.isEmpty)

        // The members work in parallel; the thread shows the assignments.
        await world.fake.start(research)
        await world.fake.start(review)
        #expect(Set(world.live.typing) == [world.pesquisador.id, world.revisor.id])
        #expect(world.live.work?.phrase == "Pesquisador e Revisor trabalhando…")
        let reviewPreface = world.fake.prefaces[review.envelope.id]?.first ?? ""
        #expect(reviewPreface.contains("role=\"member\""))
        #expect(reviewPreface.contains("[Você] Lance o produto"))
        #expect(reviewPreface.contains("[Atlas] <orb_message>Vou dividir: Pesquisador pesquisa e Revisor revisa.</orb_message>"))
        #expect(reviewPreface.contains("[Atlas → Pesquisador] <orb_message>pesquise o mercado</orb_message>"))
        #expect(!reviewPreface.contains("revise o texto")) // its own assignment is the request, not the thread

        // The researcher needs the reviewer and asks directly, on its own.
        let check = try! world.fake.ask(from: world.pesquisador.id, to: world.revisor.id, text: "valide estes números", parent: research)
        world.fake.finish(research, reply: "Preciso que o Revisor valide os números.")
        world.fake.finish(review, reply: "Texto revisado: 3 correções.")
        #expect(world.hub.run(world.groupID) != nil) // the check is still to run: the request is not over
        await world.fake.run(check, reply: "Números conferem.")
        await world.fake.wake(research, reply: "Pesquisa pronta, números validados.")
        #expect(world.hub.run(world.groupID) != nil) // the orchestrator still owes the final answer
        await world.fake.wake(first, reply: "Pronto: pesquisa e revisão concluídas.")
        await world.waitForFinish()

        // The thread: the person, the plan, the assignments, the answers, the final answer, the closing line.
        let posts = world.posts.map { "\($0.from)→\($0.to ?? "-"):\($0.kind)" }
        #expect(posts == ["Atlas→-:tell", "Atlas→Pesquisador:ask", "Atlas→Revisor:ask", "Pesquisador→Atlas:tell", "Revisor→Atlas:reply",
                          "Pesquisador→Revisor:ask", "Revisor→Pesquisador:reply", "Pesquisador→Atlas:reply", "Atlas→-:reply"])
        let final = world.posts.last
        #expect(final?.from == "Atlas" && final?.to == nil && final?.kind == .reply && final?.text == "Pronto: pesquisa e revisão concluídas.")
        let done = world.events.last
        #expect(done?.kind == .groupRunDone && done?.detail == "6 turnos · 0 tokens")
        #expect(done?.sentence == "Pedido concluído: 6 turnos · 0 tokens")
        #expect(world.live.runState == .idle && world.live.typing.isEmpty && world.live.work == nil && world.live.budget == nil)
        // The assignments got their answers.
        let states = world.items.compactMap { item -> OrbMessageItem.State? in
            if case .orbMessage(let message) = item.kind, message.kind == .ask { message.state } else { nil }
        }
        #expect(states == [.replied, .replied, .replied])
    }

    @Test @MainActor func theRoundClosesOnlyWhenEveryoneIsIdle() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let helper = try! world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "ajude", parent: first)
        world.fake.finish(first, reply: "Peço ajuda.")
        await world.fake.start(helper)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(world.hub.run(world.groupID) != nil && !world.events.contains { $0.kind == .groupRunDone })
        world.fake.finish(helper, reply: "Feito.")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(world.hub.run(world.groupID) != nil) // the answer waits for the orchestrator to be woken
        await world.fake.wake(first, reply: "Tudo certo.")
        await world.waitForFinish()
        #expect(world.events.filter { $0.kind == .groupRunDone }.count == 1)
    }

    @Test @MainActor func aQuickAnswerFromTheOrchestratorAloneIsTheFinalAnswer() async {
        let world = GroupWorld()
        let turn = await startOrchestratorTurn(world, text: "Qual é a capital da França?")
        world.fake.finish(turn, reply: "Paris.")
        await world.waitForFinish()
        #expect(world.posts.map(\.text) == ["Paris."] && world.posts[0].kind == .reply && world.posts[0].to == nil)
        #expect(world.events.last?.detail == "1 turno · 0 tokens")
    }

    @Test @MainActor func aMemberThatFailsIsToldInTheThreadAndTheRoundGoesOn() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let work = try! world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "revise", parent: first)
        world.fake.finish(first, reply: "Peço ao Revisor.")
        await world.fake.run(work, reply: "sem acesso ao arquivo", outcome: .failed)
        #expect(world.items.contains { if case .notice(let text) = $0.kind { text.hasPrefix("Revisor não conseguiu responder") } else { false } })
        let states = world.items.compactMap { item -> OrbMessageItem.State? in
            if case .orbMessage(let message) = item.kind, message.kind == .ask { message.state } else { nil }
        }
        #expect(states == [.failed])
        await world.fake.wake(first, reply: "O Revisor não conseguiu; segue o resto.")
        await world.waitForFinish()
    }

    @Test @MainActor func aMessageDuringTheRequestWakesTheOrchestratorWithoutResettingTheBudget() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let runID = world.hub.run(world.groupID)?.id
        #expect(world.hub.run(world.groupID)?.turnsUsed == 1)
        world.model.postUserMessage("Esqueci: use o tom informal", to: world.groupID)
        #expect(world.hub.run(world.groupID)?.id == runID && world.hub.run(world.groupID)?.turnsUsed == 1)
        #expect(world.fake.groupTurns.count == 2 && world.fake.groupTurns[1].envelope.to.id == world.atlas.id)
        #expect(world.fake.groupTurns[1].envelope.chainID == first.envelope.chainID)
    }

    @Test @MainActor func aNewMessageAfterTheEndStartsANewRequestWithAFreshBudget() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let firstRun = world.hub.run(world.groupID)?.id
        world.fake.finish(first, reply: "Feito.")
        await world.waitForFinish()
        world.model.postUserMessage("Outra coisa", to: world.groupID)
        let second = world.hub.run(world.groupID)
        #expect(second != nil && second?.id != firstRun && second?.turnsUsed == 0)
        #expect(world.fake.groupTurns.count == 2 && world.fake.groupTurns[1].envelope.chainID == second?.id)
    }

    @Test @MainActor func aTurnThatCouldNotBeAskedLeavesANoticeAndNoClosingLine() async {
        let world = GroupWorld()
        world.fake.failsGroupTurns = true
        world.model.postUserMessage("Oi", to: world.groupID)
        await world.waitForFinish()
        #expect(world.items.contains { if case .notice(let text) = $0.kind { text == "Atlas não pôde responder agora." } else { false } })
        #expect(!world.events.contains { $0.kind == .groupRunDone })
        #expect(world.live.runState == .idle)
    }

    @Test @MainActor func theMembersWhoWorkedAreOnTheBoardAsASessionPage() async throws {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world, text: "Planeje o lançamento da versão 2")
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.run(work, reply: "ok")
        await world.fake.wake(first, reply: "Plano pronto: lançar em outubro.")
        await world.waitForFinish()
        let bank = world.model.memory.groupBank(for: world.groupID)
        await waitUntil("the session page") { await bank.snapshot().items(.sessao).count == 1 }
        let page = try #require(await bank.snapshot().items(.sessao).first)
        #expect(page.title == "Planeje o lançamento da versão 2")
        #expect(page.body.contains("## Pedido\nPlaneje o lançamento da versão 2"))
        #expect(page.body.contains("## Resultado\nPlano pronto: lançar em outubro."))
        #expect(page.body.contains("- Atlas") && page.body.contains("- Pesquisador"))
        #expect(page.body.contains("3 turnos"))
    }
}

struct GroupPolicyAndExtrasTests {
    @Test @MainActor func membersCannotAskEachOtherWhenThePolicySaysSoButTheOrchestratorCan() async throws {
        let world = GroupWorld(policy: GroupPolicy(membersMayTalk: false))
        let first = await startOrchestratorTurn(world)
        let toMember = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "faça", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(toMember)
        #expect(throws: DelegationRefusal.notInGroup) {
            try world.fake.ask(from: world.pesquisador.id, to: world.revisor.id, text: "e você?", parent: toMember)
        }
        // And the Orb that cannot talk is not even offered the tool; the orchestrator is.
        #expect(world.model.groupTurnExtras(for: world.pesquisador.id)?.offering.orbs == false)
        world.fake.finish(toMember, reply: "feito")
        await world.fake.wake(first, reply: "ok")
        #expect(world.model.groupTurnExtras(for: world.atlas.id) == nil) // the turn ended
    }

    @Test @MainActor func aMembersTurnIsOfferedTheBoardAndTheGrantsThatCoverIt() async throws {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let extras = try #require(world.model.groupTurnExtras(for: world.atlas.id))
        #expect(extras.groupID == world.groupID && extras.offering == MultiOrbOffering(orbs: true, propose: false, groupMemory: true))
        #expect(extras.grants == [PermissionRule(family: .delegation), PermissionRule(family: .groupMemory)])
        #expect(extras.bankDirectory == world.model.memory.groupDirectory(for: world.groupID))
        #expect(extras.sideRun.kind == .group && extras.sideRun.chain?.groupID == world.groupID)
        let names = ToolBox.offered(for: [], accessibilityGranted: true, multi: extras.offering).map(\.spec.name)
        #expect(names.contains("orbs") && names.contains("group_remember") && names.contains("group_recall") && !names.contains("orb_propose"))
        let native = extras.system(claudeCode: false), claude = extras.system(claudeCode: true)
        #expect(native.hasPrefix("## Group \"Lançamento\""))
        #expect(native.contains("use orbs ask") && claude.contains("use \(ClaudeCodeTools.memoryPrefix)orbs ask"))
        #expect(world.model.groupTurnExtras(for: world.revisor.id) == nil) // not in a turn
        world.fake.finish(first, reply: "ok")
        #expect(world.model.groupTurnExtras(for: world.atlas.id) == nil)
    }

    @Test @MainActor func aMembersTurnIsFiledAsTheGroupsAndItsTokensCountAgainstTheBudget() async {
        let world = GroupWorld()
        _ = await startOrchestratorTurn(world)
        world.model.recordUsage(UsageTotals(requests: 1, input: 600, output: 400), botID: world.atlas.id, model: "custom/modelo", source: .group)
        #expect(world.hub.run(world.groupID)?.tokensUsed == 1_000)
        #expect(world.live.budget?.tokensUsed == 1_000)
        world.model.recordUsage(UsageTotals(requests: 1, input: 50), botID: world.atlas.id, model: "custom/modelo", source: .chat)
        #expect(world.hub.run(world.groupID)?.tokensUsed == 1_000) // a chat turn is not the group's
        world.hub.tokensUsed(10, chain: world.hub.run(world.groupID)!.id)
        #expect(world.hub.run(world.groupID)?.tokensUsed == 1_010)
        // Rereading the cache is not spending: Claude Code rereads tens of thousands of tokens every turn.
        world.model.recordUsage(UsageTotals(requests: 1, input: 5, cacheRead: 70_000, cacheWrite: 200, output: 95), botID: world.atlas.id,
                                model: "custom/modelo", source: .group)
        #expect(world.hub.run(world.groupID)?.tokensUsed == 1_310)
    }
}

struct GroupBudgetTests {
    @Test @MainActor func theTurnBudgetPausesAndDoesNotStartAnotherTurn() async throws {
        let world = GroupWorld(budget: GroupBudget(maxTurns: 2, maxTokens: 100_000))
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.run(work, reply: "feito") // the second turn
        #expect(world.hub.run(world.groupID)?.turnsUsed == 2)

        // The orchestrator would wake for the answer: the budget is spent, so the turn does not start and the group pauses.
        #expect(await world.fake.start(first) == false)
        #expect(world.hub.run(world.groupID)?.turnsUsed == 2)
        #expect(world.live.runState == .paused(.turns))
        #expect(world.live.work?.phrase == "Pausado: continuar?")
        let card = try #require(world.pauses.first)
        #expect(world.pauses.count == 1 && card.state == .open && card.reason == .turns && card.turnsUsed == 2 && card.turnLimit == 2)
        #expect(card.runID == world.hub.run(world.groupID)?.id && card.groupID == world.groupID)
        // Nobody can ask anyone now.
        #expect(throws: DelegationRefusal.budgetSpent) {
            try world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "mais um", parent: first)
        }
        #expect(world.pauses.count == 1) // the card is made once
        #expect(world.notices.map(\.body) == ["O grupo pausou: continuar?"] && world.notices[0].group == world.groupID)
        #expect(world.items.contains { if case .groupPause = $0.kind { true } else { false } })
    }

    @Test @MainActor func continuingAddsAnotherWindowAndLetsTheHeldTurnRun() async throws {
        let world = GroupWorld(budget: GroupBudget(maxTurns: 2, maxTokens: 100_000))
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.run(work, reply: "feito")
        #expect(await world.fake.start(first) == false)
        let chain = try #require(world.hub.run(world.groupID)?.id)

        world.model.continueRun(world.groupID)
        #expect(world.hub.run(world.groupID)?.turnLimit == 4 && world.hub.run(world.groupID)?.tokenLimit == 200_000)
        #expect(world.hub.run(world.groupID)?.phase == .active && world.live.runState == .running)
        #expect(world.pauses.first?.state == .continued)
        #expect(world.fake.resumed == [chain])
        await world.fake.wake(first, reply: "Concluído depois da pausa.")
        await world.waitForFinish()
        #expect(world.events.last?.kind == .groupRunDone && world.events.last?.detail == "3 turnos · 0 tokens")
    }

    @Test @MainActor func theTokenBudgetPausesToo() async throws {
        let world = GroupWorld(budget: GroupBudget(maxTurns: 12, maxTokens: 1_000))
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work)
        world.model.recordUsage(UsageTotals(requests: 1, input: 900, output: 300), botID: world.pesquisador.id, model: "m/x", source: .group)
        world.fake.finish(work, reply: "feito")
        #expect(world.hub.run(world.groupID)?.phase == .active) // spending does not pause by itself
        #expect(await world.fake.start(first) == false)
        #expect(world.live.runState == .paused(.tokens))
        let card = try #require(world.pauses.first)
        #expect(card.reason == .tokens && card.tokensUsed == 1_200 && card.tokenLimit == 1_000)
        world.model.continueRun(world.groupID)
        #expect(world.hub.run(world.groupID)?.tokenLimit == 2_000) // the 1.000 spent plus another window of 1.000
    }

    @Test @MainActor func aMessageWhilePausedWaitsInTheThreadForTheDecision() async throws {
        let world = GroupWorld(budget: GroupBudget(maxTurns: 2, maxTokens: 100_000))
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        let more = try world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "revise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work) // the second and last turn
        #expect(await world.fake.start(more) == false) // the turn limit is 2: spent
        #expect(world.live.runState == .paused(.turns))
        let before = world.fake.groupTurns.count
        world.model.postUserMessage("E aí?", to: world.groupID)
        #expect(world.fake.groupTurns.count == before) // nothing sent
        #expect(world.items.contains { if case .user(let text, _) = $0.kind { text == "E aí?" } else { false } })
        world.model.continueRun(world.groupID)
        #expect(world.fake.groupTurns.count == before + 1 && world.fake.groupTurns.last?.envelope.text == "E aí?")
    }

    @Test @MainActor func endingFromThePauseCancelsTheQueueAndClosesTheCard() async throws {
        let world = GroupWorld(budget: GroupBudget(maxTurns: 2, maxTokens: 100_000))
        let first = await startOrchestratorTurn(world)
        let chain = try #require(world.hub.run(world.groupID)?.id)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        let more = try world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "revise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work)
        #expect(await world.fake.start(more) == false)
        world.model.endRun(world.groupID)
        #expect(world.fake.cancelled.map(\.chain) == [chain] && world.fake.cancelled.first?.reason == .budget)
        #expect(world.pauses.first?.state == .ended)
        #expect(world.events.last?.kind == .groupStopped && world.events.last?.sentence == "Você parou o grupo")
        #expect(world.hub.run(world.groupID) == nil && world.live.runState == .idle)
        #expect(!world.events.contains { $0.kind == .groupRunDone })
    }

    @Test func theBudgetNumbersTheHeaderShows() {
        let low = GroupBudgetUsage(turnsUsed: 3, turnLimit: 12, tokensUsed: 30_000, tokenLimit: 150_000)
        #expect(low.turnFraction == 0.25 && low.tokenFraction == 0.2 && low.fraction == 0.25 && !low.isNearLimit)
        #expect(!GroupBudgetUsage(turnsUsed: 9, turnLimit: 12, tokensUsed: 0, tokenLimit: 100).isNearLimit) // 75 %: not yet
        #expect(!GroupBudgetUsage(turnsUsed: 79, turnLimit: 100, tokensUsed: 0, tokenLimit: 100).isNearLimit)
        #expect(GroupBudgetUsage(turnsUsed: 80, turnLimit: 100, tokensUsed: 0, tokenLimit: 100).isNearLimit)
        #expect(GroupBudgetUsage(turnsUsed: 0, turnLimit: 12, tokensUsed: 90_000, tokenLimit: 100_000).isNearLimit)
        #expect(GroupBudgetUsage(turnsUsed: 20, turnLimit: 12, tokensUsed: 0, tokenLimit: 100).fraction == 1)
    }
}

struct GroupStopTests {
    @Test @MainActor func stoppingTheGroupCancelsTheChainAndEveryTurnInProgress() async throws {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let chain = try #require(world.hub.run(world.groupID)?.id)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work)
        #expect(world.live.typing == [world.pesquisador.id])

        world.model.stopGroup(world.groupID)
        #expect(world.fake.cancelled.map(\.chain) == [chain] && world.fake.cancelled.first?.reason == .user)
        #expect(world.events.last?.kind == .groupStopped)
        #expect(world.hub.run(world.groupID) == nil && world.live.runState == .idle && world.live.typing.isEmpty)
        #expect(world.hub.activeGroup(of: world.pesquisador.id) == nil)
        // What the stopped turns report afterwards changes nothing.
        let items = world.items.count
        world.fake.finish(work, reply: "cheguei tarde", outcome: .cancelled)
        #expect(world.items.count == items)
    }

    @Test @MainActor func commandPeriodStopsTheOpenGroup() async {
        let world = GroupWorld()
        world.model.selection = .group(world.groupID)
        #expect(!world.model.canStopCurrent)
        _ = await startOrchestratorTurn(world)
        #expect(world.model.canStopCurrent && world.model.isGroupWorking(world.groupID))
        world.model.stopCurrent()
        #expect(world.hub.run(world.groupID) == nil && !world.model.canStopCurrent)
        #expect(world.events.last?.kind == .groupStopped)
    }

    @Test @MainActor func takingOutAMemberThatIsWorkingStopsTheRequestFirst() async throws {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.revisor.id, text: "revise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work)
        #expect(world.model.removeMember(world.revisor.id, from: world.groupID))
        #expect(world.events.suffix(2).map(\.kind) == [.groupStopped, .leftGroup])
        #expect(world.hub.run(world.groupID) == nil)
    }

    @Test @MainActor func anApprovalCardOfAMemberIsAnsweredInTheGroup() async throws {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        let work = try world.fake.ask(from: world.atlas.id, to: world.pesquisador.id, text: "pesquise", parent: first)
        world.fake.finish(first, reply: "Delego.")
        await world.fake.start(work)
        world.model.setAwaitingApproval(true, of: world.pesquisador.id)
        #expect(world.live.needsYou && world.live.waiting == [world.pesquisador.id])
        #expect(world.live.work?.phrase == "Pesquisador espera você" && world.live.work?.tone == .waiting)
        world.model.showApprovalOwner(world.pesquisador.id)
        #expect(world.model.selection == .group(world.groupID))
        world.model.setAwaitingApproval(false, of: world.pesquisador.id)
        #expect(!world.live.needsYou && world.live.waiting.isEmpty)
    }
}

struct GroupUnreadAndNoticeTests {
    @Test @MainActor func aMembersWordsAreUnreadUntilThePersonLooks() async {
        let world = GroupWorld()
        let first = await startOrchestratorTurn(world)
        world.fake.finish(first, reply: "Olá!")
        await world.waitForFinish()
        #expect(world.live.unread == 1 && world.session.unread == 1)
        world.model.selection = .group(world.groupID)
        #expect(world.live.unread == 0 && world.session.unread == 0)
    }

    @Test @MainActor func nothingIsUnreadWhileTheGroupIsInFront() async {
        let world = GroupWorld()
        world.hub.isFocused = { _ in true }
        let first = await startOrchestratorTurn(world)
        world.fake.finish(first, reply: "Olá!")
        await world.waitForFinish()
        #expect(world.live.unread == 0)
    }

    @Test @MainActor func aFinishedRequestIsBannerOnlyWithTheAppInTheBackground() async {
        let world = GroupWorld()
        world.hub.isAppActive = { true }
        let first = await startOrchestratorTurn(world)
        world.fake.finish(first, reply: "Olá!")
        await world.waitForFinish()
        #expect(world.notices.isEmpty)

        world.hub.isAppActive = { false }
        let second = await startOrchestratorTurn(world, text: "De novo")
        world.fake.finish(second, reply: "Aqui.")
        await world.waitForFinish()
        #expect(world.notices.count == 1 && world.notices[0].title == "Lançamento" && world.notices[0].body.hasPrefix("O grupo terminou"))
        #expect(world.notices[0].group == world.groupID)
    }

    @Test @MainActor func theBannersOfAGroupComeAtMostEveryFiveSeconds() async {
        let world = GroupWorld()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        world.hub.now = { clock }
        for round in 0..<3 {
            let turn = await startOrchestratorTurn(world, text: "Rodada \(round)")
            world.fake.finish(turn, reply: "ok \(round)")
            await world.waitForFinish()
            clock.addTimeInterval(round == 0 ? 2 : 6)
        }
        // Round 0 banners; round 1 comes 2 s later and is held back; round 2 comes 8 s after the first and banners again.
        #expect(world.notices.count == 2)
    }
}

struct GroupPresenceLineTests {
    @Test func theLineSaysWhoDoesWhat() {
        #expect(GroupPresence.line(typing: [], waiting: [], orchestratorOnly: false, orchestrator: "Atlas", paused: false) == nil)
        #expect(GroupPresence.line(typing: ["Atlas"], waiting: [], orchestratorOnly: true, orchestrator: "Atlas", paused: false)?.phrase == "Atlas coordena…")
        #expect(GroupPresence.line(typing: ["Lia"], waiting: [], orchestratorOnly: false, orchestrator: "Atlas", paused: false)?.phrase == "Lia trabalhando…")
        #expect(GroupPresence.line(typing: ["Lia", "Teo", "Ana"], waiting: [], orchestratorOnly: false, orchestrator: "Atlas", paused: false)?.phrase
                == "Lia, Teo e Ana trabalhando…")
        let waiting = GroupPresence.line(typing: ["Lia"], waiting: ["Lia"], orchestratorOnly: false, orchestrator: "Atlas", paused: false)
        #expect(waiting?.phrase == "Lia espera você" && waiting?.tone == .waiting)
        #expect(GroupPresence.line(typing: ["Lia", "Teo"], waiting: ["Lia", "Teo"], orchestratorOnly: false, orchestrator: "Atlas", paused: false)?.phrase
                == "Lia e Teo esperam você")
        #expect(GroupPresence.line(typing: ["Lia"], waiting: [], orchestratorOnly: false, orchestrator: "Atlas", paused: true)?.phrase == "Pausado: continuar?")
    }
}
