import Foundation
import Testing
@testable import Orb

// The task plan (`task_plan`): what the tool does with each call, how the conversation keeps the plan through a save, a
// compaction and "Refazer", and how it reaches the model (with the message, in the progress record).

private func arguments(_ json: String) -> JSONValue { JSONValue.parse(json) ?? .null }

private let created = arguments("""
{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Rodar os testes", "Subir para o servidor"], \
"next": "começar pelo build"}
""")

private func plan(_ json: JSONValue = created) throws -> TaskPlan {
    try #require(try TaskPlan.applying(json, to: nil))
}

private func run(_ json: JSONValue, on board: TaskPlanBoard) async throws -> String {
    var context = ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    context.taskPlan = board
    return try await TaskPlanTool().run(json, context: context)
}

struct TaskPlanToolTests {
    @Test func creatingAPlanAnswersWithEveryStepPending() async throws {
        let board = TaskPlanBoard()
        let answer = try await run(created, on: board)
        #expect(answer == """
        [Plano da tarefa] Objetivo: Publicar o site
        1. [ ] Gerar o build
        2. [ ] Rodar os testes
        3. [ ] Subir para o servidor
        Próximo passo: começar pelo build
        """)
        #expect(board.plan?.steps.count == 3)
        #expect(board.plan?.isActive == true)
    }

    @Test func updatingStepsChangesTheirStateAndTheNextStep() async throws {
        let board = TaskPlanBoard(try plan())
        let answer = try await run(arguments("""
        {"action": "update", "updates": [{"step": 1, "state": "done"}, {"step": 2, "state": "in_progress"}, \
        {"step": 3, "state": "blocked", "reason": "falta a senha do servidor"}], "next": "rodar swift test"}
        """), on: board)
        #expect(answer.contains("1. [feita] Gerar o build"))
        #expect(answer.contains("2. [fazendo] Rodar os testes"))
        #expect(answer.contains("3. [bloqueada: falta a senha do servidor] Subir para o servidor"))
        #expect(answer.hasSuffix("Próximo passo: rodar swift test"))
        // A step that leaves "blocked" drops its reason; an empty `next` clears it.
        _ = try await run(arguments(#"{"action": "update", "updates": [{"step": 3, "state": "pending"}], "next": ""}"#), on: board)
        #expect(board.plan?.steps[2] == TaskPlan.Step(text: "Subir para o servidor"))
        #expect(board.plan?.next == nil)
    }

    @Test func anInvalidStepNumberIsRefusedAndChangesNothing() async throws {
        let before = try plan()
        let board = TaskPlanBoard(before)
        // The first update is fine, the second is not: neither is applied.
        let call = arguments(#"{"action": "update", "updates": [{"step": 1, "state": "done"}, {"step": 7, "state": "done"}]}"#)
        await #expect(throws: ToolError("There is no step 7: the plan has steps 1 to 3.")) { try await run(call, on: board) }
        await #expect(throws: ToolError.self) {
            try await run(arguments(#"{"action": "update", "updates": [{"step": 0, "state": "done"}]}"#), on: board)
        }
        #expect(board.plan == before)
    }

    @Test func moreStepsThanTheLimitAreRefused() async throws {
        let steps = (1...(TaskPlan.maxSteps + 1)).map { "\"etapa \($0)\"" }.joined(separator: ", ")
        let board = TaskPlanBoard()
        await #expect(throws: ToolError.self) {
            try await run(arguments(#"{"action": "set", "goal": "x", "steps": [\#(steps)]}"#), on: board)
        }
        #expect(board.plan == nil)
        let error = #expect(throws: ToolError.self) {
            try TaskPlan.applying(arguments(#"{"action": "set", "goal": "x", "steps": [\#(steps)]}"#), to: nil)
        }
        #expect(error?.message.hasPrefix("At most \(TaskPlan.maxSteps) steps") == true)
    }

    @Test func whatTheCallLeavesOutOrGetsWrongIsSaidPlainly() throws {
        let existing = try plan()
        func message(_ json: String, _ plan: TaskPlan? = nil) -> String? {
            #expect(throws: ToolError.self) { try TaskPlan.applying(arguments(json), to: plan) }?.message
        }
        #expect(message(#"{"action": "update", "next": "x"}"#) == "There is no plan: create one with action \"set\".")
        #expect(message(#"{"action": "update", "updates": [{"step": 3, "state": "blocked"}]}"#, existing)
            == "Say in `reason` why step 3 is blocked.")
        #expect(message(#"{"action": "update", "updates": [{"step": 1, "state": "finished"}]}"#, existing)
            == "`state` of step 1 is one of pending, in_progress, done, blocked.")
        #expect(message(#"{"action": "update"}"#, existing) == "Give `updates`, `checks`, `next`, or any of them.")
        #expect(message(#"{"action": "set", "steps": ["a"]}"#) == "Give the `goal`.")
        #expect(message(#"{"action": "set", "goal": "x", "steps": []}"#) == "Give the `steps`, 1 to \(TaskPlan.maxSteps).")
        #expect(message(#"{"action": "rename"}"#) == "`action` is one of set, update, done, clear, show.")
        #expect(message("{}") == "`action` is one of set, update, done, clear, show.")
        #expect(message(#"{"action": "done"}"#) == "There is no plan: create one with action \"set\".")
    }

    // What the models really sent, each of which was an error that left the plan as it was (and so open for good).

    @Test func aCallWithoutAnActionIsReadFromItsFields() throws {
        let made = try #require(try TaskPlan.applying(arguments(#"{"goal": "Ler os e-mails", "steps": ["Abrir", "Ler"]}"#), to: nil))
        #expect(made.goal == "Ler os e-mails" && made.steps.count == 2)
        let updated = try #require(try TaskPlan.applying(arguments(#"{"updates": [{"step": 1, "state": "done"}]}"#), to: made))
        #expect(updated.steps.map(\.state) == [.done, .pending])
        #expect(try TaskPlan.applying(arguments(#"{"next": "ler o segundo"}"#), to: made)?.next == "ler o segundo")
    }

    @Test func readingThePlanAnswersWithItAndChangesNothing() async throws {
        let existing = try plan()
        let board = TaskPlanBoard(existing)
        for action in ["show", "list", "get", "LIST"] {
            #expect(try await run(arguments(#"{"action": "\#(action)"}"#), on: board) == existing.render())
        }
        #expect(board.plan == existing)
        #expect(try await run(arguments(#"{"action": "list"}"#), on: TaskPlanBoard()) == "There is no plan: create one with action \"set\".")
    }

    @Test func doneClosesEveryStepInOneCall() throws {
        var existing = try plan()
        existing.steps[1].state = .blocked
        existing.steps[1].reason = "sem acesso"
        for action in ["done", "complete", "finish"] {
            let closed = try #require(try TaskPlan.applying(arguments(#"{"action": "\#(action)"}"#), to: existing))
            #expect(closed.steps.allSatisfy { $0.state == .done && $0.reason == nil })
            #expect(closed.next == nil && !closed.isActive && !closed.isUnfinished)
            #expect(TaskPlan.finishedInTurn(from: existing, to: closed) == closed, "the chat says the plan was finished")
        }
    }

    @Test func theWordsOfOtherPlanToolsMarkAStep() throws {
        let existing = try plan()
        let json = #"""
        {"action": "update", "updates": [{"step": 1, "state": "completed"}, {"step": 2, "state": "met", "criterion": 1},
        {"step": 3, "state": "In-Progress"}]}
        """#
        #expect(try TaskPlan.applying(arguments(json), to: existing)?.steps.map(\.state) == [.done, .done, .inProgress])
        #expect(TaskPlan.State.named("todo") == .pending && TaskPlan.State.named("open") == .pending)
        #expect(TaskPlan.State.named("blocked") == .blocked && TaskPlan.State.named("whatever") == nil)
    }

    @Test func aPlanSetAsideStopsSteeringUntilAnUpdateTakesItUp() throws {
        var existing = try plan()
        #expect(existing.isActive)
        existing.setAside()
        #expect(!existing.isActive && existing.isUnfinished)
        var conversation = Conversation()
        conversation.taskPlan = existing
        #expect(conversation.activePlan == nil)
        #expect(PulsePlan(conversation.activePlan, chat: UUID(), paused: false) == nil, "it wakes no pulse")
        #expect(TaskPlan.finishedInTurn(from: nil, to: existing) == nil, "set aside is not finished")
        // It survives a save as it is, and a plan saved before the count existed was never passed over.
        let saved = try JSONEncoder().encode(existing)
        #expect(try JSONDecoder().decode(TaskPlan.self, from: saved) == existing)
        var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object.removeValue(forKey: "passedOver")
        #expect(try JSONDecoder().decode(TaskPlan.self, from: JSONSerialization.data(withJSONObject: object)).isActive)
        // Reading it does not bring it back; working on it does.
        #expect(try TaskPlan.applying(arguments(#"{"action": "show"}"#), to: existing)?.isActive == false)
        let resumed = try TaskPlan.applying(arguments(#"{"action": "update", "updates": [{"step": 1, "state": "in_progress"}]}"#), to: existing)
        #expect(resumed?.isActive == true && resumed?.passedOver == 0)
    }

    @Test func clearingDropsThePlan() async throws {
        let board = TaskPlanBoard(try plan())
        #expect(try await run(arguments(#"{"action": "clear"}"#), on: board) == "The plan was cleared.")
        #expect(board.plan == nil)
    }

    @Test func textsAreKeptToTheirLimitsOnOneLine() throws {
        let long = String(repeating: "palavra ", count: 100)
        let made = try plan(arguments("""
        {"action": "set", "goal": "\(long)", "steps": ["linha um\\n# linha dois \(long)"], "next": "\(long)"}
        """))
        #expect(made.goal.count <= TaskPlan.goalLimit + 1)
        #expect(made.steps[0].text.count <= TaskPlan.stepLimit + 1)
        #expect(made.steps[0].text.hasPrefix("linha um # linha dois"))
        #expect(!made.steps[0].text.contains("\n"))
        #expect((made.next?.count ?? 0) <= TaskPlan.nextLimit + 1)
    }

    @Test func theToolIsSafeAndOfferedEvenToAReadOnlyOrb() {
        let tool = TaskPlanTool()
        #expect(tool.risk(created) == .safe)
        #expect(ToolBox.offered(for: [], accessibilityGranted: false).contains { $0.spec.name == TaskPlanTool.name })
        let call = PermissionCall(toolName: TaskPlanTool.name, family: nil, risk: tool.risk(created))
        #expect(PermissionPolicy.evaluate(mode: .readOnly, call: call, rules: [], workspace: nil,
                                          home: URL(fileURLWithPath: "/Users/teste")) == .allow)
    }

    @Test func theRingCountsTheStepsAndSaysWhatIsNext() throws {
        var made = try plan()
        // Nothing marked yet: no "0 de 3", which would never move if the model does not mark the steps.
        #expect(!TaskPlanRing.isTended(made))
        #expect(TaskPlanRing.summary(made) == "3 etapas, nenhuma marcada · Próximo: começar pelo build")
        made.steps[0].state = .inProgress
        #expect(TaskPlanRing.isTended(made))
        #expect(TaskPlanRing.summary(made) == "0 de 3 etapas · Próximo: começar pelo build")
        made.steps[0].state = .done
        made.steps[1].state = .inProgress
        made.next = nil
        #expect(TaskPlanRing.summary(made) == "1 de 3 etapas · Próximo: Rodar os testes")
        made.steps = [TaskPlan.Step(text: "Publicar")]
        #expect(TaskPlanRing.summary(made) == "1 etapa, não marcada · Próximo: Publicar")
    }
}

// MARK: - In the prompt

struct TaskPlanPromptTests {
    @Test func theCompactPlanCountsTheDoneStepsOnceThereAreMany() throws {
        let steps = (1...6).map { "\"etapa \($0)\"" }.joined(separator: ", ")
        var made = try plan(arguments(#"{"action": "set", "goal": "Migrar", "steps": [\#(steps)], "next": "etapa 6"}"#))
        for index in [0, 1, 2] { made.steps[index].state = .done }
        // Up to three done steps are written out.
        #expect(made.compact().contains("1. [feita] etapa 1"))
        made.steps[3].state = .done
        #expect(made.compact() == """
        [Plano da tarefa] Objetivo: Migrar
        Feitas 4 de 6: 1, 2, 3, 4
        5. [ ] etapa 5
        6. [ ] etapa 6
        Próximo passo: etapa 6
        """)
    }

    @Test func theLongestPlanStaysUnderItsCeiling() throws {
        let long = String(repeating: "x", count: 400)
        let steps = (1...TaskPlan.maxSteps).map { _ in "\"\(long)\"" }.joined(separator: ", ")
        var made = try plan(arguments(#"{"action": "set", "goal": "\#(long)", "steps": [\#(steps)], "next": "\#(long)"}"#))
        let blocked = (1...TaskPlan.maxSteps).map { #"{"step": \#($0), "state": "blocked", "reason": "\#(long)"}"# }
        made = try #require(try TaskPlan.applying(arguments(#"{"action": "update", "updates": [\#(blocked.joined(separator: ", "))]}"#), to: made))
        #expect(made.compact().count <= TaskPlan.maxCompactLength, "\(made.compact().count)")
        #expect(made.render().count <= TaskPlan.maxCompactLength, "\(made.render().count)")
    }

    private func inputs() -> TurnPromptInputs {
        var bot = Bot(name: "Atlas", role: "assistente", orb: OrbConfig())
        bot.workingDirectory = "/Users/maria/app"
        return TurnPromptInputs(bot: bot, skills: [], brief: MemoryBrief(), snapshot: WorkspaceSnapshot(path: "/Users/maria/app", entries: []),
                                instructions: nil, now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func anOpenPlanGoesWithTheMessageAndNothingElseDoes() throws {
        let made = try plan()
        let with = TurnPrompt.native(inputs(), history: [], lastWorkspaceHash: nil, plan: made)
        let without = TurnPrompt.native(inputs(), history: [], lastWorkspaceHash: nil)
        #expect(with.preface.contains(made.compact()))
        #expect(with.preface.hasSuffix(made.compact() + "\n" + TurnPreface.closeTag))
        #expect(!without.preface.contains(TaskPlan.heading))
        // The system prompt does not change with the plan (its cache would start over).
        #expect(with.system == without.system)
        // Once every step is done the plan steers nothing: it stays out.
        var finished = made
        for index in finished.steps.indices { finished.steps[index].state = .done }
        #expect(TurnPrompt.native(inputs(), history: [], lastWorkspaceHash: nil, plan: finished).preface == without.preface)
    }

    @Test func theSystemPromptSaysWhenToKeepAPlan() {
        #expect(PromptParts.workHabits.contains("task_plan"))
        #expect(PromptParts.workHabits.contains("not a question or a quick request"))
        #expect(PromptParts.workHabits.contains("never end a turn with a step in_progress"))
    }

    @Test func theProgressRecordStartsWithTheOpenPlan() throws {
        var made = try plan()
        made.steps[0].state = .done
        let task = [ChatMessage.user("publica o site"),
                    ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c1", name: "run_command", arguments: #"{"command": "make"}"#)]),
                    ChatMessage.tool("c1", "ok")]
        let record = try #require(ProgressRecord.text(task: task, plan: made))
        #expect(record.hasPrefix(ProgressRecord.marker + "\n" + made.compact() + "\n[usuário] «publica o site»\n[passo 1] "))
        #expect(record.contains("Próximo passo: começar pelo build"))
        // Without a plan, or with a finished one, the record is what it always was.
        #expect(ProgressRecord.text(task: task, plan: nil) == ProgressRecord.text(task: task))
        for index in made.steps.indices { made.steps[index].state = .done }
        #expect(ProgressRecord.text(task: task, plan: made) == ProgressRecord.text(task: task))
    }
}

// MARK: - Kept with the conversation

/// The messages of a task that made a plan (call c1) and then marked its first step done (call c2), and a later request.
private func plannedTask() -> [ChatMessage] {
    func call(_ id: String, _ json: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: id, name: TaskPlanTool.name, arguments: json)])
    }
    let set = #"{"action": "set", "goal": "Publicar o site", "steps": ["Gerar o build", "Rodar os testes"]}"#
    let update = #"{"action": "update", "updates": [{"step": 1, "state": "done"}], "next": "rodar os testes"}"#
    return [.user("publica o site"), call("c1", set), .tool("c1", "ok"), call("c2", update), .tool("c2", "ok"),
            ChatMessage(role: .assistant, content: "Build pronto."), .user("e agora?")]
}

struct TaskPlanConversationTests {
    private let folder = TempFolder("OrbTaskPlan")
    var root: URL { folder.url }

    @Test func theConversationTakesThePlanFromTheCallsThatRan() {
        var chat = Conversation()
        for message in plannedTask() { chat.absorb(message) }
        #expect(chat.messages == plannedTask())
        #expect(chat.taskPlan?.steps.map(\.state) == [.done, .pending])
        #expect(chat.taskPlan?.next == "rodar os testes")
        #expect(chat.activePlan != nil)
    }

    @Test func aSuccessfulClearDropsThePlanWhenAbsorbedAndReplayed() {
        var chat = Conversation()
        let clear = ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCallRequest(id: "c3", name: TaskPlanTool.name, arguments: #"{"action": "clear"}"#)])
        for message in plannedTask().dropLast(2) + [clear] { chat.absorb(message) }
        #expect(chat.taskPlan != nil)
        chat.absorb(.tool("c3", "The plan was cleared."))
        #expect(chat.taskPlan == nil)
        #expect(chat.activePlan == nil)
        #expect(TaskPlan.replay(chat.messages) == nil)
    }

    @Test func aCallThatFailedOrNeverRanLeavesThePlanAlone() {
        var chat = Conversation()
        let messages = plannedTask()
        for message in messages[..<4] { chat.absorb(message) }
        let before = chat.taskPlan
        var failed = messages[4]
        failed.isError = true
        chat.absorb(failed)
        #expect(chat.taskPlan == before)
        chat.absorb(.tool("c2", ChatMessage.interruptedResult))
        #expect(chat.taskPlan == before)
        // A result for another tool's call is not a plan's.
        chat.absorb(.tool("other", "ok"))
        #expect(chat.taskPlan == before)
    }

    @Test func thePlanSurvivesSavingAndReopening() throws {
        var chat = Conversation(messages: plannedTask())
        chat.taskPlan = TaskPlan.replay(chat.messages, now: Date(timeIntervalSince1970: 1_790_000_000))
        let id = UUID()
        let store = Store(directory: root)
        store.save(chat, for: id)
        store.flush()
        let loaded = try #require(store.loadConversation(id))
        #expect(loaded.taskPlan == chat.taskPlan)
        #expect(loaded.taskPlan != nil)
    }

    @Test func aConversationWithoutAPlanOrWithOneItCannotReadStillOpens() throws {
        let old = try JSONDecoder().decode(Conversation.self, from: Data(#"{"items": [], "messages": []}"#.utf8))
        #expect(old.taskPlan == nil)
        let broken = try JSONDecoder().decode(Conversation.self, from: Data(#"{"items": [], "messages": [], "taskPlan": 7}"#.utf8))
        #expect(broken.taskPlan == nil)
    }

    @Test func thePlanSurvivesACompaction() throws {
        var chat = Conversation()
        for turn in 0..<30 {
            chat.messages += [.user("pedido \(turn) " + String(repeating: "a", count: 1_750)),
                              ChatMessage(role: .assistant, content: "resposta \(turn) " + String(repeating: "b", count: 1_750))]
        }
        for message in plannedTask() { chat.absorb(message) }
        let before = chat.taskPlan
        let count = chat.messages.count
        _ = try #require(chat.prepareHistory(budget: ContextBudget(tokens: 20_000)).compaction)
        #expect(chat.summary != nil)
        #expect(chat.taskPlan == before)
        #expect(chat.messages.count == count)
    }

    @Test func goingBackToBeforeThePlanWasMadeDropsIt() {
        var chat = Conversation(messages: plannedTask())
        chat.taskPlan = TaskPlan.replay(chat.messages)
        chat.rewind(to: RewindCut(itemIndex: 0, messageIndex: 1))
        #expect(chat.taskPlan == nil)
    }

    @Test func goingBackBetweenUpdatesLeavesThePlanAsItWasThere() {
        var chat = Conversation(messages: plannedTask())
        chat.taskPlan = TaskPlan.replay(chat.messages)
        chat.rewind(to: RewindCut(itemIndex: 0, messageIndex: 3))
        #expect(chat.taskPlan?.steps.map(\.state) == [.pending, .pending])
        #expect(chat.taskPlan?.next == nil)
    }

    @Test func goingBackPastNoPlanCallKeepsThePlanAsItIs() {
        var chat = Conversation(messages: plannedTask())
        chat.taskPlan = TaskPlan.replay(chat.messages)
        let before = chat.taskPlan
        chat.rewind(to: RewindCut(itemIndex: 0, messageIndex: 6))
        #expect(chat.taskPlan == before)
    }

    @Test func aRoutineRunStartsWithoutAPlan() {
        var chat = Conversation(messages: plannedTask())
        chat.taskPlan = TaskPlan.replay(chat.messages)
        #expect(chat.startingRoutineRun(at: .now).taskPlan == nil)
    }
}

// MARK: - Acceptance criteria (`done_when` and `checks`)

struct TaskPlanCriteriaTests {
    private let withCriteria = arguments("""
    {"action": "set", "goal": "Corrigir o login", "steps": ["Ajustar", "Testar"], \
    "done_when": ["os testes passam", "  ", "o botão entra com Enter"]}
    """)

    private func update(_ json: String, on plan: TaskPlan?) throws -> TaskPlan {
        try #require(try TaskPlan.applying(arguments(json), to: plan))
    }

    @Test func setKeepsTheCriteriaOpenAndDropsEmptyOnes() throws {
        let made = try plan(withCriteria)
        #expect(made.criteria.map(\.text) == ["os testes passam", "o botão entra com Enter"])
        #expect(made.criteria.allSatisfy { $0.state == .open && $0.evidence == nil })
        #expect(try plan().criteria.isEmpty, "a set without done_when has none")
        #expect(made.render().contains("Done when:\n1 [open] os testes passam\n2 [open] o botão entra com Enter"))
        #expect(made.compact().contains("2 [open] o botão entra com Enter"))
    }

    @Test func aSetReplacesTheCriteria() throws {
        let again = try update(#"{"action": "set", "goal": "Outro", "steps": ["a"], "done_when": ["x"]}"#, on: try plan(withCriteria))
        #expect(again.criteria.map(\.text) == ["x"])
    }

    @Test func checksMarkACriterionWithItsEvidence() throws {
        let made = try update("""
        {"action": "update", "checks": [{"criterion": 1, "state": "met", "evidence": "swift test 12/12 ok"}, \
        {"criterion": 2, "state": "failed"}]}
        """, on: try plan(withCriteria))
        #expect(made.criteria[0].state == .met && made.criteria[0].evidence == "swift test 12/12 ok")
        #expect(made.criteria[1].state == .failed && made.criteria[1].evidence == nil)
        #expect(made.compact().contains("1 [met] os testes passam — swift test 12/12 ok"))
        let reopened = try update(#"{"action": "update", "checks": [{"criterion": 1, "state": "open"}]}"#, on: made)
        #expect(reopened.criteria[0].state == .open && reopened.criteria[0].evidence == nil)
    }

    @Test func metNeedsEvidenceAndABadCheckChangesNothing() throws {
        let base = try plan(withCriteria)
        let noEvidence = #"{"action": "update", "updates": [{"step": 1, "state": "done"}], "checks": [{"criterion": 1, "state": "met", "evidence": " "}]}"#
        #expect(throws: ToolError.self) { try TaskPlan.applying(arguments(noEvidence), to: base) }
        #expect(throws: ToolError.self) {
            try TaskPlan.applying(arguments(#"{"action": "update", "checks": [{"criterion": 3, "state": "failed"}]}"#), to: base)
        }
        #expect(throws: ToolError.self) {
            try TaskPlan.applying(arguments(#"{"action": "update", "checks": [{"criterion": 1, "state": "ok"}]}"#), to: base)
        }
        let bare = try plan()
        #expect(throws: ToolError.self) {
            try TaskPlan.applying(arguments(#"{"action": "update", "checks": [{"criterion": 1, "state": "met", "evidence": "x"}]}"#), to: bare)
        }
    }

    @Test func aRefusedCallLeavesTheBoardAsItWas() async throws {
        let board = TaskPlanBoard(try plan(withCriteria))
        await #expect(throws: ToolError.self) {
            try await run(arguments(#"{"action": "update", "updates": [{"step": 1, "state": "done"}], "checks": [{"criterion": 1, "state": "met"}]}"#), on: board)
        }
        #expect(board.plan?.steps[0].state == .pending)
    }

    @Test func criteriaAreLimitedInNumberAndLength() throws {
        let many = (1...(TaskPlan.maxCriteria + 1)).map { "\"c\($0)\"" }.joined(separator: ", ")
        #expect(throws: ToolError.self) {
            try TaskPlan.applying(arguments(#"{"action": "set", "goal": "g", "steps": ["a"], "done_when": [\#(many)]}"#), to: nil)
        }
        let long = String(repeating: "palavra ", count: 100)
        let made = try plan(arguments(#"{"action": "set", "goal": "g", "steps": ["a"], "done_when": ["\#(long)"]}"#))
        #expect(made.criteria[0].text.count <= TaskPlan.criterionLimit + 1)
        let checked = try update(#"{"action": "update", "checks": [{"criterion": 1, "state": "met", "evidence": "\#(long)"}]}"#, on: made)
        #expect((checked.criteria[0].evidence?.count ?? 0) <= TaskPlan.evidenceLimit + 1)
    }

    @Test func theLongestPlanWithCriteriaStaysUnderItsCeiling() throws {
        let long = String(repeating: "x", count: 400)
        let steps = (1...TaskPlan.maxSteps).map { _ in "\"\(long)\"" }.joined(separator: ", ")
        let criteria = (1...TaskPlan.maxCriteria).map { _ in "\"\(long)\"" }.joined(separator: ", ")
        var made = try plan(arguments(#"{"action": "set", "goal": "\#(long)", "steps": [\#(steps)], "next": "\#(long)", "done_when": [\#(criteria)]}"#))
        let checks = (1...TaskPlan.maxCriteria).map { #"{"criterion": \#($0), "state": "met", "evidence": "\#(long)"}"# }
        let blocked = (1...TaskPlan.maxSteps).map { #"{"step": \#($0), "state": "blocked", "reason": "\#(long)"}"# }
        made = try update(#"{"action": "update", "updates": [\#(blocked.joined(separator: ", "))], "checks": [\#(checks.joined(separator: ", "))]}"#, on: made)
        #expect(made.compact().count <= TaskPlan.maxCompactLength, "\(made.compact().count)")
        #expect(made.render().count <= TaskPlan.maxCompactLength, "\(made.render().count)")
    }

    @Test func aPlanSavedBeforeCriteriaExistedStillOpens() throws {
        let old = #"{"goal": "Publicar", "steps": [{"text": "a", "state": "done"}], "updatedAt": 0}"#
        let decoded = try JSONDecoder().decode(TaskPlan.self, from: Data(old.utf8))
        #expect(decoded.criteria.isEmpty && decoded.steps.count == 1)
        let odd = #"{"goal": "g", "steps": [], "criteria": [{"text": "x", "state": "weird"}, 7]}"#
        let tolerant = try JSONDecoder().decode(TaskPlan.self, from: Data(odd.utf8))
        #expect(tolerant.criteria == [TaskPlan.Criterion(text: "x")], "an unknown state reads as open, an unreadable item is dropped")
    }

    @Test func criteriaSurviveTheEncodeDecodeRoundTrip() throws {
        let made = try update(#"{"action": "update", "checks": [{"criterion": 1, "state": "met", "evidence": "ok"}]}"#, on: try plan(withCriteria))
        let back = try JSONDecoder().decode(TaskPlan.self, from: try JSONEncoder().encode(made))
        #expect(back == made)
    }

    @Test func theToolOffersTheNewFields() {
        let schema = TaskPlanTool().spec.parameters.jsonString
        #expect(schema.contains("done_when") && schema.contains("checks") && schema.contains("evidence"))
    }
}
