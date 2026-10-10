import Foundation
import Testing
@testable import Orb

/// What a model call was given, and the answers it gives in order (the last repeats).
private actor Script {
    struct Call { var messages: [ChatMessage]; var tools: [String]; var system: String }
    private(set) var calls: [Call] = []
    private var answers: [[LLMEvent]]
    private let failsCall: Int?
    private let holdsCall: Int?
    private var released = false

    init(_ answers: [[LLMEvent]], failsCall: Int? = nil, holdsCall: Int? = nil) {
        self.answers = answers
        self.failsCall = failsCall
        self.holdsCall = holdsCall
    }

    func release() { released = true }

    func answer(_ messages: [ChatMessage], _ tools: [ToolSpec]) async -> [LLMEvent]? {
        calls.append(Call(messages: Array(messages.dropFirst()), tools: tools.map(\.name), system: messages.first?.content ?? ""))
        let number = calls.count
        if failsCall == number { return nil }
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
                guard let events = await script.answer(messages, tools) else {
                    continuation.finish(throwing: LLMError.notConfigured)
                    return
                }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}


/// A stand-in `claude` that plays the tools server's part: it reads the tools server's arguments from `--mcp-config`, and makes
/// the `orb_draft` call the way the server does (a file in the app's mailbox, the answer in a `.reply` beside it). It logs the answer.
private let bridgeCallingClaude = #"""
#!/usr/bin/python3
import json, os, sys, time, uuid

log = open(os.environ["FAKE_CLAUDE_LOG"], "a")
def note(text):
    log.write(text.rstrip("\n") + "\n"); log.flush()
def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

config_path = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--mcp-config="))
server = json.load(open(config_path))["mcpServers"]["orb_memoria"]
args = server["args"]
bridge = args[args.index("--bridge") + 1]
orb = args[args.index("--orb") + 1]
note("wizard:" + str("--wizard" in args))
session = next((a.split("=", 1)[1] for a in sys.argv if a.startswith(("--session-id=", "--resume="))), "none")
for raw in sys.stdin:
    msg = json.loads(raw)
    kind = msg.get("type")
    if kind == "control_request" and msg["request"]["subtype"] == "initialize":
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"models": []}}})
    elif kind == "user":
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test"})
        call_id = str(uuid.uuid4()).upper()
        call = {"v": 1, "id": call_id, "tool": "orb_draft", "orb": orb, "arguments": {"name": "Maia", "role": "Cuida da agenda"}}
        tmp = os.path.join(bridge, call_id + ".tmp")
        open(tmp, "w").write(json.dumps(call))
        os.rename(tmp, os.path.join(bridge, call_id + ".json"))
        reply = os.path.join(bridge, call_id + ".reply")
        for _ in range(200):
            if os.path.exists(reply): break
            time.sleep(0.05)
        note("reply:" + (open(reply).read() if os.path.exists(reply) else "none"))
        emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "session_id": session, "result": "ok"})
        break
note("eof")
"""#

private func said(_ text: String) -> [LLMEvent] { [.text(text), .finished(.done, nil)] }

private func drafting(_ json: String) -> [LLMEvent] {
    [.toolCalls([ToolCallRequest(id: UUID().uuidString, name: "orb_draft", arguments: json)]), .finished(.toolUse, nil)]
}

/// The "Criar conversando" assistant: a turn at a time, nothing kept until "Criar".
@Suite(.serialized) final class WizardRunnerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbWizard-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ script: Script) -> (AppModel, WizardRunner) {
        let store = Store(directory: root)
        var state = AppState.initial
        state.providers = [ProviderAccount(kind: .custom)]
        state.defaultModel = "custom/modelo"
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { ScriptedModel(script: script) }
        let runner = WizardRunner(model: model)
        runner.orbsBase = root.appending(path: "Orbs")
        return (model, runner)
    }

    @MainActor private func settled(_ runner: WizardRunner) async {
        await waitUntil("the assistant to finish answering") { !runner.isThinking && runner.liveText.isEmpty }
    }

    @MainActor private func botTexts(_ runner: WizardRunner) -> [String] {
        runner.messages.compactMap { if case .bot(let text, _) = $0.kind { text } else { nil } }
    }

    // MARK: Turns

    @MainActor @Test func theAssistantOpensAlreadySpeaking() {
        let (_, runner) = setUp(Script([said("oi")]))
        #expect(botTexts(runner) == [WizardPrompt.firstLine])
        #expect(runner.offersSuggestions && runner.draft.revision == 0)
        #expect(WizardPrompt.suggestions.count == 3)
    }

    @MainActor @Test func twoTurnsFillTheDraftAndGrowTheChat() async {
        let script = Script([drafting(#"{"name":"Maia","role":"Cuida da agenda"}"#), said("Como você prefere que ele trabalhe?"),
                             drafting(#"{"instructions":"Você é a Maia.","capabilities":["browser"],"ready":true}"#), said("Tudo certo, é só criar.")])
        let (_, runner) = setUp(script)

        #expect(runner.send(WizardPrompt.suggestions[0]))
        #expect(runner.isThinking && !runner.offersSuggestions)
        #expect(!runner.send("outra mensagem enquanto responde"), "one answer at a time")
        await settled(runner)
        #expect(runner.draft.name == "Maia" && runner.draft.role == "Cuida da agenda" && !runner.draft.ready)
        #expect(botTexts(runner).last == "Como você prefere que ele trabalhe?")
        #expect(runner.messages.count == 3)

        #expect(runner.send("Curtas e diretas."))
        // The second answer, not just a quiet moment between the tool call and the text (a loaded machine can show one).
        await waitUntil("the second answer") { runner.messages.count == 5 && !runner.isThinking && runner.liveText.isEmpty }
        #expect(runner.draft.instructions == "Você é a Maia." && runner.draft.capabilities == [.browser] && runner.draft.ready)
        #expect(runner.draft.revision == 2)
        #expect(botTexts(runner).last == "Tudo certo, é só criar.")
        #expect(runner.userMessageCount == 2 && runner.messages.count == 5)
        #expect(!runner.messages.contains { if case .tool = $0.kind { true } else { false } }, "only words reach the chat")

        // The model saw only `orb_draft`, the interview prompt and (second turn) the whole exchange.
        let calls = await script.calls
        #expect(calls.count == 4 && calls.allSatisfy { $0.tools == ["orb_draft"] })
        #expect(calls[0].system.contains("Interview them in Brazilian Portuguese"))
        #expect(calls[0].system.contains(WizardPrompt.firstLine))
        #expect(calls[2].messages.contains { $0.role == .user && $0.content == "Curtas e diretas." })
        #expect(calls[2].messages.contains { $0.role == .tool && $0.content.contains("name: Maia") }, "the model reads the draft back")
    }

    @MainActor @Test func talkingAgainTakesTheFinalCardAway() async {
        let script = Script([drafting(#"{"name":"Maia","ready":true}"#), said("Pronto."), said("Claro, mudo.")])
        let (_, runner) = setUp(script)
        runner.send("oi")
        await settled(runner)
        #expect(runner.draft.ready)
        runner.send("na verdade quero outro nome")
        #expect(!runner.draft.ready, "the card gives way while they talk")
        await settled(runner)
        _ = runner.applyDraft(.object(["ready": .bool(true)]))
        runner.backToChatting()
        #expect(!runner.draft.ready)
    }

    @MainActor @Test func theStepLimitClosesWithWhatThereIs() async {
        // The model never stops calling the tool: after 14 steps the app closes the interview itself.
        let script = Script([drafting(#"{"name":"Maia"}"#)])
        let (_, runner) = setUp(script)
        runner.send("oi")
        await settled(runner)
        let calls = await script.calls
        #expect(calls.count == WizardRunner.maxSteps)
        #expect(runner.hitLimit && botTexts(runner).last == WizardPrompt.closing)
        #expect(runner.draft.name == "Maia" && runner.draft.ready, "the final card shows what there is")
        #expect(!runner.canSend)
    }

    @MainActor @Test func theThirtiethMessageClosesTheSession() async {
        let script = Script([said("Mais uma pergunta?")])
        let (model, runner) = setUp(script)
        _ = runner.applyDraft(.object(["name": .string("Maia")]))
        for number in 1...WizardRunner.maxUserMessages {
            // The model stays connected however long the loop takes (the app may reload its settings meanwhile).
            model.providers = [ProviderAccount(kind: .custom)]
            model.defaultModel = "custom/modelo"
            #expect(runner.send("resposta \(number)"))
            await settled(runner)
        }
        #expect(runner.hitLimit && botTexts(runner).last == WizardPrompt.closing && runner.draft.ready)
        #expect(!runner.send("mais uma"))
        #expect(runner.userMessageCount == WizardRunner.maxUserMessages)
    }

    @MainActor @Test func aFailureCanBeTriedAgainFromTheSameState() async {
        let script = Script([said("Voltei."), said("Segue.")], failsCall: 1)
        let (_, runner) = setUp(script)
        runner.send("quero um Orb")
        await settled(runner)
        #expect(runner.failure != nil && !runner.canSend)
        #expect(runner.history.isEmpty, "the failed turn leaves no trace in what the model was told")
        #expect(runner.userMessageCount == 1)
        runner.retry()
        #expect(runner.failure == nil)
        await settled(runner)
        #expect(botTexts(runner).last == "Voltei.")
        #expect(runner.userMessageCount == 1, "the message is not sent twice to the chat")
        let calls = await script.calls
        #expect(calls.count == 2 && calls[1].messages.filter { $0.role == .user }.count == 1)
    }

    @MainActor @Test func withoutAUsableModelItSaysSo() {
        let (model, runner) = setUp(Script([said("oi")]))
        model.providers = []
        #expect(runner.send("oi"))
        #expect(runner.failure == WizardRunner.unavailable && !runner.isThinking)
    }

    // MARK: Ending

    @MainActor @Test func cancelDiscardsEverythingAndStopsTheTurn() async {
        let script = Script([drafting(#"{"name":"Maia"}"#), said("Ok.")], holdsCall: 2)
        let (model, runner) = setUp(script)
        let botsBefore = model.bots.map(\.id)
        runner.send("oi")
        await waitUntil("the draft to be filled in") { runner.draft.name == "Maia" }
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-assistente-\(runner.id.uuidString.lowercased())")
        #expect(FileManager.default.fileExists(atPath: folder.path), "the turn's working folder is temporary")
        runner.cancel()
        #expect(runner.isFinished && !runner.isThinking)
        #expect(runner.create() == nil)
        await script.release()
        #expect(model.bots.map(\.id) == botsBefore, "nothing was created")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Orbs").path))
        #expect(throws: (any Error).self) { try model.wizardDraft(runner.id, .object(["name": .string("Outro")])) }
        #expect(runner.draft.name == "Maia")
    }

    @MainActor @Test func criarMakesTheOrbTheDraftDescribes() async throws {
        let script = Script([drafting(#"{"name":"Maia","role":"Cuida da agenda","instructions":"Você é a Maia. Seja breve.","capabilities":["browser","connectors"],"mode":"auto","look":{"color":"menta","hair":"franja"}}"#), said("Pronto.")])
        let (model, runner) = setUp(script)
        runner.send("oi")
        await settled(runner)
        let botsBefore = model.bots.count
        let chosen = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", hair: "franja")
        let bot = try #require(runner.create(look: chosen))
        #expect(model.bots.count == botsBefore + 1 && model.bots.last?.id == bot.id)
        let made = try #require(model.bot(bot.id))
        #expect(made.name == "Maia" && made.role == "Cuida da agenda")
        #expect(made.createdBy == nil && made.createdByName == nil, "the person made it")
        #expect(made.permissionMode == .auto && made.model.isEmpty)
        #expect(made.capabilities == [.browser], "never connectors")
        #expect(made.orb.color == "rosa" && made.orb.eyes == "ovais" && made.orb.hair == "franja", "the look is the one the person chose, not the model's")
        #expect(model.selection == .bot(bot.id))
        #expect(made.workingURL.path.hasPrefix(root.appending(path: "Orbs").path))
        await waitUntil("the identity in the Orb's memory") { await model.memory.bank(for: bot.id).identity()?.body.contains("Seja breve") == true }
        #expect(runner.isFinished)
        #expect(runner.create() == nil, "once")
    }

    @MainActor @Test func criarNeedsAName() {
        let (model, runner) = setUp(Script([said("oi")]))
        let before = model.bots.count
        #expect(runner.create() == nil && model.bots.count == before)
    }

    @MainActor @Test func theCallsOfClaudeCodesToolsServerReachTheOpenAssistantOnly() throws {
        let (model, runner) = setUp(Script([said("oi")]))
        WizardRegistry.add(runner)
        let answer = try model.wizardDraft(runner.id, .object(["name": .string("Maia")]))
        #expect(answer.hasPrefix("name: Maia") && runner.draft.name == "Maia")
        #expect(throws: (any Error).self) { try WizardRegistry.draft(orb: runner.id, tool: "run_command", arguments: .object([:])) }
        #expect(throws: (any Error).self) { try model.wizardDraft(UUID(), .object([:])) }
        runner.cancel()
        #expect(throws: (any Error).self) { try model.wizardDraft(runner.id, .object([:])) }
    }


    /// The Claude Code path end to end: the assistant's tools server is configured for the app's own mailbox, a call that arrives
    /// there reaches the open assistant through `AppModel.bridgeCall`, and the draft shows it.
    @MainActor @Test func anOrbDraftCallThroughTheBridgeUpdatesTheDraftOfTheClaudeCodeAssistant() async throws {
        let (model, runner) = setUp(Script([said("oi")]))
        model.providers = [ProviderAccount(kind: .claudeCode)]
        model.publishConnections([.claudeCode])
        model.defaultModel = "claudeCode/sonnet"
        let fakeFolder = root.appending(path: "fake-claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeFolder, withIntermediateDirectories: true)
        let executable = fakeFolder.appending(path: "claude")
        FileManager.default.createFile(atPath: executable.path, contents: Data(bridgeCallingClaude.utf8), attributes: [.posixPermissions: 0o755])
        let log = fakeFolder.appending(path: "log.txt")
        runner.claudeLauncher = { (executable, ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LOG": log.path]) }
        #expect(runner.send("quero uma Maia"))
        await waitUntil("the call to reach the draft") { runner.draft.name == "Maia" }
        #expect(runner.draft.role == "Cuida da agenda")
        await settled(runner)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(text.contains("wizard:True"))
        #expect(text.contains("reply:{\"text\":\"name: Maia"), "the server gets the draft read back: \(text)")
        #expect(model.orbBridge.isListening)
        runner.cancel()
        #expect(throws: (any Error).self) { try model.wizardDraft(runner.id, .object(["name": .string("Outro")])) }
    }

    @MainActor @Test func theAssistantsCallsAreFiledUnderCriacaoDeOrb() async throws {
        let usage = TokenUsage(input: 120, output: 30)
        let script = Script([[.text("Oi!"), .finished(.done, usage)]])
        let (model, runner) = setUp(script)
        runner.send("oi")
        await settled(runner)
        await waitUntil("the assistant's usage in the history") {
            model.usageLog.flush()
            model.store.flush()
            let found = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).buckets
            return found.contains { $0.key.source == .creation && $0.key.orb == WizardRunner.usageOrbID && $0.totals.input == 120 }
        }
        let names = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).names
        #expect(names[WizardRunner.usageOrbID] == "Criação de Orb")
    }
}
