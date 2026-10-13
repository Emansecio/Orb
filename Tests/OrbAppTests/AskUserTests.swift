import Foundation
import Testing
@testable import Orb

// `ask_user`: the Orb asks the person something in its own chat and waits, on a card, for the answer; the tool gives the model
// what they picked or wrote, or that they skipped it.

/// A model that plays one scripted answer per call.
private actor QuestionScript {
    private var responses: [[LLMEvent]]
    init(_ responses: [[LLMEvent]]) { self.responses = responses }
    func next() -> [LLMEvent] { responses.isEmpty ? [.text("fim")] : responses.removeFirst() }
}

private struct QuestionLLM: LLMClient {
    let script: QuestionScript

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.next() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

struct AskUserEngineTests {
    private let askCall = LLMEvent.toolCalls([ToolCallRequest(
        id: "q1", name: AskUserTool.name,
        arguments: #"{"question":"Qual pasta organizo?","options":["Downloads"," Mesa ","Downloads",""]}"#)])

    private func request(mode: PermissionMode = .ask) -> TurnRequest {
        let bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), permissionMode: mode)
        return TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "organiza",
                           client: QuestionLLM(script: QuestionScript([[askCall], [.text("Certo.")]])),
                           tools: [AskUserTool()], context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
    }

    /// Plays the turn; `onCard` is the person answering.
    private func drive(_ engine: AgentEngine, _ request: TurnRequest,
                       onCard: @Sendable (ApprovalRequest) async -> Void) async -> (cards: [ApprovalRequest], result: String?) {
        var cards: [ApprovalRequest] = []
        var result: String?
        for await event in engine.run(request) {
            switch event {
            case .approval(let card):
                cards.append(card)
                await onCard(card)
            case .message(let message) where message.role == .tool:
                result = result ?? message.content
            default:
                break
            }
        }
        return (cards, result)
    }

    @Test func theCardAsksEvenInPerguntarAntesAndTheAnswerReachesTheModel() async throws {
        let engine = AgentEngine()
        let (cards, result) = await drive(engine, request()) { card in
            await engine.gate.resolve(approvalID: card.id, answer: ApprovalAnswer(decision: .once, reply: "  Mesa  "))
        }
        // One card, the question's own: asking needs no permission.
        let card = try #require(cards.first)
        #expect(cards.count == 1 && card.isQuestion && card.isHandoff == false)
        #expect(card.title == "Atlas pergunta" && card.command == "Qual pasta organizo?")
        #expect(card.question?.options == ["Downloads", "Mesa"]) // trimmed, without repeats or blanks
        #expect(result == "The user answered: Mesa")
    }

    @Test func twoQuestionsInOneStepAreAskedOneAfterTheOther() async {
        let two = LLMEvent.toolCalls([ToolCallRequest(id: "q1", name: AskUserTool.name, arguments: #"{"question":"Primeira?"}"#),
                                      ToolCallRequest(id: "q2", name: AskUserTool.name, arguments: #"{"question":"Segunda?"}"#)])
        let bot = Bot(name: "Atlas", role: "", orb: OrbConfig(), permissionMode: .ask)
        let turn = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "organiza",
                               client: QuestionLLM(script: QuestionScript([[two], [.text("Certo.")]])),
                               tools: [AskUserTool()], context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        let engine = AgentEngine()
        let (cards, _) = await drive(engine, turn) { card in
            // Only this card is open: the second question waits for the answer to the first.
            #expect(await engine.gate.openIDs(for: bot.id) == [card.id])
            await engine.gate.resolve(approvalID: card.id, answer: ApprovalAnswer(decision: .once, reply: "sim"))
        }
        #expect(cards.map(\.command) == ["Primeira?", "Segunda?"])
    }

    @Test func skippingTellsTheModelToCarryOn() async {
        let engine = AgentEngine()
        let (_, result) = await drive(engine, request()) { card in
            await engine.gate.resolve(approvalID: card.id, decision: .deny)
        }
        #expect(result?.contains(AskUserTool.skipped) == true)
    }

    @Test func aChangeOfPermissionModeNeverAnswersTheQuestion() async {
        let engine = AgentEngine()
        let turn = request()
        let (_, result) = await drive(engine, turn) { card in
            for mode in PermissionMode.allCases {
                #expect(await engine.gate.applyModeChange(to: mode, for: turn.bot.id).isEmpty, "\(mode)")
            }
            await engine.gate.resolve(approvalID: card.id, answer: ApprovalAnswer(decision: .once, reply: "Downloads"))
        }
        #expect(result == "The user answered: Downloads")
    }

    @Test func withoutAnyoneToAnswerTheToolSaysSo() async throws {
        await #expect(throws: ToolError.self) {
            try await AskUserTool().run(.object(["question": .string("Qual?")]),
                                        context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        }
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.askUser = { _ in "sim" }
        await #expect(throws: ToolError.self) { try await AskUserTool().run(.object(["question": .string("  ")]), context: context) }
        #expect(try await AskUserTool().run(.object(["question": .string("Posso?")]), context: context) == "The user answered: sim")
    }
}

struct AskUserOfferingTests {
    @Test func theToolIsOfferedOnlyWhereThePersonIs() {
        let names = { (multi: MultiOrbOffering) in
            ToolBox.offered(for: [.terminal], accessibilityGranted: true, multi: multi).map(\.spec.name)
        }
        #expect(names(MultiOrbOffering(askUser: true)).contains(AskUserTool.name))
        #expect(!names(MultiOrbOffering()).contains(AskUserTool.name))
    }

    @Test func aQuestionIsCleanedAndCapped() {
        let question = OrbQuestion(text: "  " + String(repeating: "a", count: 900) + " ",
                                   options: (1...9).map { "opção \($0)" } + [String(repeating: "b", count: 300)])
        #expect(question.text.count == OrbQuestion.textLimit)
        #expect(question.options.count == OrbQuestion.optionLimit)
        #expect(OrbQuestion(text: "?", options: [String(repeating: "b", count: 300)]).options[0].count == OrbQuestion.optionLength)
        #expect(OrbQuestion.clean("  \n ") == nil && OrbQuestion.clean(" ok ") == "ok")
    }

    @Test func anAnsweredQuestionStaysInViewInsteadOfJoiningTheActions() {
        var question = ApprovalRequest.question(OrbQuestion(text: "Qual?", options: ["A"]), botName: "Atlas")
        question.decision = .once
        question.question?.answer = "A"
        let permission = ApprovalRequest(toolName: "run_command", title: "Rodando", command: "ls", reason: "", decision: .once)
        #expect(!TranscriptFolding.joinsToolRun(TranscriptItem(.approval(question))))
        #expect(TranscriptFolding.joinsToolRun(TranscriptItem(.approval(permission))))
    }

    @Test func anOldVersionsCardStillReadsAndANewCardKeepsItsQuestion() throws {
        var card = ApprovalRequest.question(OrbQuestion(text: "Qual?", options: ["A", "B"]), botName: "Atlas")
        card.question?.answer = "B"
        let decoded = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(card))
        #expect(decoded.question == card.question)
        let old = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"toolName":"run_command","title":"t","command":"ls","reason":""}"#.utf8))
        #expect(old.question == nil)
    }
}
