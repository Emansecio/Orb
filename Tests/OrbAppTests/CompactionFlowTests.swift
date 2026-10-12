import Foundation
import Testing
@testable import Orb

// The whole path of a compaction through the app with the real engine: the engine decides when and how much to fold
// (`ContextWindow.fit`), the summary is the conversation's ledger extended with what left the window, the app keeps
// it, says so once with numbers and saves the conversation to the memory once; the next message starts from it.

private let firstRequest = "Construa o app Atlas com SQLite e rode os testes a cada mudança"
private let decision = "Decisão: a porta será 4711, não mude."

/// Answers each request with the next scripted reply, and keeps what it was sent.
private actor Script {
    private var replies: [[LLMEvent]]
    private(set) var received: [[ChatMessage]] = []

    init(_ replies: [[LLMEvent]]) { self.replies = replies }

    func next(_ messages: [ChatMessage]) -> [LLMEvent] {
        received.append(messages)
        return replies.isEmpty ? [.text("fim")] : replies.removeFirst()
    }
}

private struct ScriptedModel: LLMClient {
    let script: Script

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await script.next(messages) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func models() async throws -> [String] { ["modelo"] }
}

@MainActor
final class CompactionFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbCompactionFlow-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// An Orb whose model has a 32k window, a folder with a big file, and eight earlier turns with long answers (about
    /// 33,000 characters: under the budget, so sending folds nothing; the file read during the turn does not fit).
    private func setUp(_ script: Script) throws -> (AppModel, UUID, URL) {
        let folder = root.appending(path: "pasta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "grande.txt")
        try (0..<200).map { "linha \($0) " + String(repeating: "dado ", count: 18) }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var conversation = Conversation()
        for index in 0..<8 {
            let request = index == 0 ? firstRequest : index == 2 ? decision : "pedido número \(index) do projeto"
            conversation.messages += [.user(request),
                                      ChatMessage(role: .assistant, content: "resposta \(index) " + String(repeating: "texto ", count: 650))]
            conversation.items += [TranscriptItem(.user(text: request, attachments: [])),
                                   TranscriptItem(.bot(text: "resposta \(index)", isStreaming: false))]
        }
        var state = AppState.initial
        state.bots[0].workingDirectory = folder.path
        state.bots[0].permissionMode = .bypass
        let store = Store(directory: root.appending(path: "dados"))
        store.save(state)
        store.save(conversation, for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.learnContextWindow(32_000, of: "custom/modelo")
        model.clientOverride = { ScriptedModel(script: script) }
        return (model, state.bots[0].id, file)
    }

    private func read(_ file: URL, _ id: String) -> [LLMEvent] {
        [.toolCalls([ToolCallRequest(id: id, name: "read_file", arguments: #"{"path":"\#(file.path)"}"#)])]
    }

    private func notices(_ model: AppModel, _ botID: UUID) -> [String] {
        model.transcript(botID).compactMap { if case .notice(let text) = $0.kind, text.hasPrefix("Compactei a conversa:") { text } else { nil } }
    }

    @Test func aFoldInsideATurnExtendsTheLedgerIsToldOnceAndSavesTheMemoryOnce() async throws {
        let script = Script([])
        let (model, botID, file) = try setUp(script)
        await script.reset(with: [read(file, "c1"), read(file, "c2"), read(file, "c3"), [.text("pronto")], [.text("ok")]])
        let bank = model.memory.bank(for: botID)

        #expect(model.send("leia o arquivo grande três vezes", to: botID))
        await waitUntil("the turn to end") { !model.isWorking(botID) }

        // Nothing was folded at sending; the engine folded during the turn, and that was said once, with numbers.
        let told = notices(model, botID)
        #expect(told.count == 1)
        #expect(told.first?.contains("tokens).") == true)
        let items = model.transcript(botID)
        let asked = try #require(items.firstIndex { if case .user(let text, _) = $0.kind { text.hasPrefix("leia o arquivo") } else { false } })
        let said = try #require(items.firstIndex { if case .notice(let text) = $0.kind { text.hasPrefix("Compactei a conversa:") } else { false } })
        #expect(said > asked)
        // The chat folds everything before the request in progress into one line.
        let fold = model.orbTranscript(botID).fold
        #expect(fold.count == asked && fold.messages > 0)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.compactions == 1)
        // The summary is the conversation's ledger, extended with what left the window.
        let ledger = try #require(conversation.ledger)
        #expect(conversation.summary == ledger.render())
        #expect(ledger.original == firstRequest)
        #expect(conversation.summary?.contains("a porta será 4711") == true)
        // It covers everything before the turn in progress, and stops at its start.
        let current = try #require(conversation.messages.lastIndex { $0.role == .user })
        #expect(conversation.summaryCoveredCount == current)
        #expect(conversation.messages[current].content.contains("leia o arquivo grande"))
        // The memory got the conversation once, when the turn ended.
        #expect(conversation.memorySavedCount == conversation.items.count)
        await waitUntil("the session page") { await bank.snapshot().items.contains { $0.kind == .sessao } }
        #expect(await bank.snapshot().items.filter { $0.kind == .sessao }.count == 1)

        // The next message starts from the kept summary: no second fold, no second page, and the request begins with
        // the same summary the turn ended with (the provider's cache of it still applies).
        #expect(model.send("e agora?", to: botID))
        await waitUntil("the second turn to end") { !model.isWorking(botID) }
        #expect(notices(model, botID).count == 1)
        #expect(model.conversations[botID]?.compactions == 1)
        let requests = await script.received
        let lastOfTurn = try #require(requests.dropLast().last)
        let next = try #require(requests.last)
        #expect(lastOfTurn.dropFirst().first?.content.hasPrefix(ContextSummary.marker) == true)
        #expect(next.dropFirst().first?.content == lastOfTurn.dropFirst().first?.content)
        #expect(await bank.snapshot().items.filter { $0.kind == .sessao }.count == 1)
    }

    @Test func compactNowUsesTheSameMachineryAndTheMeterAgreesWithItsNumbers() throws {
        let (model, botID, _) = try setUp(Script([]))
        let bot = try #require(model.bot(botID))
        let budget = try #require(model.contextBudget(for: bot))
        let before = try #require(model.contextFill(for: botID))
        let preview = try #require(before.compaction)

        let result = model.compactNow(botID: botID, focus: "a migração")
        #expect(result.status == .compacted)
        #expect(result.tokensBefore == before.historyTokens)
        #expect(result.foldedMessages == preview.messages)
        let after = try #require(model.contextFill(for: botID))
        #expect(after.historyTokens == result.tokensAfter)
        #expect(Double(result.tokensAfter) <= Double(budget.tokens) * ContextMeter.compactingShare)
        let conversation = try #require(model.conversations[botID])
        #expect(conversation.summary?.contains("Pedido original: " + firstRequest) == true)
        #expect(conversation.summary?.contains("Dar atenção a: a migração") == true)
        #expect(conversation.memorySavedCount == conversation.items.count)
        #expect(notices(model, botID).count == 1)
    }
}

private extension Script {
    func reset(with replies: [[LLMEvent]]) { self.replies = replies }
}
