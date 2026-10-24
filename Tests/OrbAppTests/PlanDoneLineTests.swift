import Foundation
import Testing
@testable import Orb

// The line "Plano concluído · 5 etapas" (`OrbEvent.planDone`): when a turn leaves it, where it sits, and that it never
// reaches the model's history.

private func finishedPlan(steps: Int = 2) -> TaskPlan {
    TaskPlan(goal: "Publicar o site", steps: (1...steps).map { TaskPlan.Step(text: "Etapa \($0)", state: .done) }, next: "nada")
}

struct PlanDoneEventTests {
    @Test func aPlanFinishedInTheTurnIsReportedOnlyOnce() {
        let done = finishedPlan()
        var open = done
        open.steps[1].state = .inProgress
        // Made and finished in one turn, or open when the turn began.
        #expect(TaskPlan.finishedInTurn(from: nil, to: done) == done)
        #expect(TaskPlan.finishedInTurn(from: open, to: done) == done)
        // Open steps, no plan, or the finished plan the turn began with: nothing to say.
        #expect(TaskPlan.finishedInTurn(from: nil, to: open) == nil)
        #expect(TaskPlan.finishedInTurn(from: done, to: nil) == nil)
        #expect(TaskPlan.finishedInTurn(from: done, to: done) == nil)
        // A plan made again in the turn and finished is another plan.
        var other = done
        other.steps[0].text = "Outra etapa"
        #expect(TaskPlan.finishedInTurn(from: done, to: other) == other)
    }

    @Test func theSentenceCountsTheSteps() {
        #expect(OrbEvent(planDone: finishedPlan(steps: 5)).sentence == "Plano concluído · 5 etapas")
        #expect(OrbEvent(planDone: finishedPlan(steps: 1)).sentence == "Plano concluído · 1 etapa")
        // No steps to count (a plan that could not be read): the words alone.
        #expect(OrbEvent(kind: .planDone).sentence == "Plano concluído")
        // The plan is kept without its "next", and the line carries the words for a version that does not know the kind.
        let event = OrbEvent(planDone: finishedPlan())
        #expect(event.plan?.next == nil)
        #expect(event.detail == event.sentence)
    }

    @Test func theLineSurvivesSavingAndAnOlderOneStillOpens() throws {
        let item = TranscriptItem(.event(OrbEvent(planDone: finishedPlan(steps: 3))))
        let data = try JSONEncoder().encode(Conversation(items: [item]))
        let back = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(back.items == [item])
        // An event of before the plan was kept, a plan this version cannot read and a kind from a newer version all open.
        let old = try JSONDecoder().decode(OrbEvent.self, from: Data(#"{"kind": "orbCreated"}"#.utf8))
        #expect(old.kind == .orbCreated && old.plan == nil)
        let odd = try JSONDecoder().decode(OrbEvent.self, from: Data(#"{"kind": "planDone", "detail": "Plano concluído", "plan": 7}"#.utf8))
        #expect(odd.kind == .planDone && odd.plan == nil && odd.sentence == "Plano concluído")
        let future = try JSONDecoder().decode(OrbEvent.self, from: Data(#"{"kind": "somethingNew", "detail": "x"}"#.utf8))
        #expect(future.kind == .unknown)
    }
}

@Suite(.serialized) struct PlanDoneLineTests {
    private let folder = TempFolder("OrbPlanDone")

    @MainActor private func model() -> AppModel {
        AppModel(store: Store(directory: folder.url), runsBackgroundWork: false)
    }

    /// The `task_plan` call `id` and its result, as the engine reports them.
    private func call(_ id: String, _ json: String) -> [TurnEvent] {
        [.message(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: TaskPlanTool.name, arguments: json)])),
         .message(.tool(id, "ok"))]
    }

    private let set = #"{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Rodar os testes"]}"#
    private let first = #"{"action": "update", "updates": [{"step": 1, "state": "done"}]}"#
    private let second = #"{"action": "update", "updates": [{"step": 2, "state": "done"}]}"#

    /// Runs a turn that plays `events` and ends.
    @MainActor private func runTurn(_ model: AppModel, _ id: UUID, asking text: String, _ events: [TurnEvent], succeeded: Bool = true) {
        let session = model.session(id)
        session.append(.user(text: text, attachments: []))
        model.apply(.message(.user(text)), to: id)
        let turn = session.beginTurn()
        session.turnTask = Task {}
        model.setStatus("Pensando", of: id)
        for event in events { model.apply(event, to: id) }
        model.finishTurn(id, turn: turn, succeeded: succeeded)
    }

    @MainActor private func lines(_ model: AppModel, _ id: UUID) -> [OrbEvent] {
        (model.session(id).conversation?.items ?? []).compactMap { item in
            if case .event(let event) = item.kind, event.kind == .planDone { event } else { nil }
        }
    }

    /// What the model says at the end: the words in the chat and in its history.
    private func reply(_ text: String) -> [TurnEvent] { [.text(text), .message(ChatMessage(role: .assistant, content: text))] }

    @Test @MainActor func theLineComesOnceWhenThePlanEndsAndNeverWhileAStepIsOpen() {
        let model = model()
        let id = model.bots[0].id
        let session = model.session(id)
        runTurn(model, id, asking: "publica", call("c1", set) + call("c2", first) + reply("ok"))
        #expect(lines(model, id).isEmpty)
        #expect(session.conversation?.activePlan != nil)
        // The next turn finishes it: the line comes, after the reply.
        runTurn(model, id, asking: "segue", call("c3", second) + reply("Pronto."))
        #expect(lines(model, id).map(\.sentence) == ["Plano concluído · 2 etapas"])
        if case .event? = session.conversation?.items.last?.kind {} else { Issue.record("the line is the last item of the chat") }
        // A turn after that, with the plan left as it was, adds nothing.
        runTurn(model, id, asking: "obrigado", reply("De nada"))
        #expect(lines(model, id).count == 1)
        // The model's history never gets it: it holds only what the model said and what the tools answered.
        let history = session.conversation?.messages ?? []
        #expect(!history.contains { $0.content.contains("Plano concluído") })
        #expect(history.count == 12)
    }

    @Test @MainActor func aPlanOfOneStepMadeAndFinishedInOneTurnGetsTheLine() {
        let model = model()
        let id = model.bots[0].id
        let one = #"{"action": "set", "goal": "Só uma", "steps": ["Fazer"]}"#
        let done = #"{"action": "update", "updates": [{"step": 1, "state": "done"}]}"#
        runTurn(model, id, asking: "faz", call("c1", one) + call("c2", done))
        #expect(lines(model, id).first?.sentence == "Plano concluído · 1 etapa")
    }

    @Test @MainActor func aStoppedTurnWithAFinishedPlanKeepsItsNoticeAndGetsTheLineAfterIt() {
        let model = model()
        let id = model.bots[0].id
        runTurn(model, id, asking: "publica", call("c1", set) + call("c2", first) + call("c3", second)
                + [.notice(BotSession.stoppedNotice)], succeeded: false)
        let items = model.session(id).conversation?.items ?? []
        #expect(lines(model, id).count == 1)
        if case .notice(BotSession.stoppedNotice)? = items.dropLast().last?.kind {} else { Issue.record("the notice stays before the line") }
    }

    @Test @MainActor func aNoticeWithButtonsStaysTheLastItem() {
        let model = model()
        let id = model.bots[0].id
        runTurn(model, id, asking: "publica", call("c1", set) + call("c2", first) + call("c3", second)
                + [.failed("sem rede")], succeeded: false)
        #expect(lines(model, id).isEmpty)
        if case .notice? = model.session(id).conversation?.items.last?.kind {} else { Issue.record("the failure keeps its buttons") }
    }

    @Test @MainActor func goingBackOverTheTurnTakesTheLineWithIt() throws {
        let model = model()
        let id = model.bots[0].id
        runTurn(model, id, asking: "publica", call("c1", set) + call("c2", first) + reply("ok"))
        runTurn(model, id, asking: "segue", call("c3", second) + reply("Pronto."))
        #expect(lines(model, id).count == 1)
        var chat = try #require(model.session(id).conversation)
        let start = try #require(chat.items.lastIndex { if case .user(let text, _) = $0.kind { text == "segue" } else { false } })
        let cut = try #require(chat.rewindCut(atItem: start, skills: []))
        chat.rewind(to: cut)
        #expect(!chat.items.contains { if case .event = $0.kind { true } else { false } })
        // The plan is back to the one that was open, so finishing it again says so again.
        #expect(chat.activePlan != nil)
    }
}
