import Foundation
import Testing
@testable import Orb

// The model's note on a long stretch saved to the memory (`SessionNote`): asked only when you turned it on, only for a
// stretch with enough requests and no connector, and it joins the page written by rules instead of replacing it.

private actor NoteRequests {
    private(set) var count = 0
    func asked() { count += 1 }
}

private struct NoteModel: LLMClient {
    let requests: NoteRequests

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if messages.first?.content == ChunkSummarizer.instructions { await requests.asked() }
                continuation.yield(.text("O usuário montou o Atlas com SQLite na porta 4711; ficou faltando o certificado."))
                continuation.yield(.finished(.done, TokenUsage(input: 2_000, output: 40)))
                continuation.finish()
            }
        }
    }
}

@MainActor
final class SessionNoteTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSessionNote-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func stretch(requests: Int, connector: Bool = false) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for index in 0..<requests {
            items.append(TranscriptItem(.user(text: "pedido \(index) do Atlas", attachments: [])))
            if connector, index == 0 {
                items.append(TranscriptItem(.tool(ToolCall(kind: .connector, title: "Usando Gmail", detail: "ler e-mails", state: .done))))
            }
            items.append(TranscriptItem(.tool(ToolCall(kind: .memory, title: "Guardando na memória", detail: "x", state: .done))))
            items.append(TranscriptItem(.bot(text: "resposta \(index)", isStreaming: false)))
        }
        return items
    }

    @Test func onlyALongStretchWithoutConnectorsIsSent() throws {
        #expect(SessionNote.input(from: stretch(requests: SessionNote.minimumRequests - 1)) == nil)
        #expect(SessionNote.input(from: stretch(requests: SessionNote.minimumRequests, connector: true)) == nil)
        let input = try #require(SessionNote.input(from: stretch(requests: SessionNote.minimumRequests)))
        #expect(input.contains("User: pedido 0 do Atlas") && input.contains("Assistant: resposta 5"))
        #expect(!input.contains("Guardando")) // saving to the memory is not worth summarizing
    }

    private func setUp(on: Bool) throws -> (AppModel, UUID, NoteRequests) {
        var conversation = Conversation()
        conversation.items = stretch(requests: SessionNote.minimumRequests)
        let state = AppState.initial
        let store = Store(directory: root.appending(path: "dados"))
        store.save(state)
        store.save(conversation, for: state.bots[0].id)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.writesStretchNotes = true
        let requests = NoteRequests()
        model.clientOverride = { NoteModel(requests: requests) }
        let suite = UserDefaults(suiteName: "OrbSessionNote-\(UUID().uuidString)")!
        suite.set(on, forKey: SessionNote.settingKey)
        model.preferences = suite
        return (model, state.bots[0].id, requests)
    }

    private func sessionBodies(_ model: AppModel, _ botID: UUID) async -> [String] {
        await model.memory.bank(for: botID).snapshot().items(.sessao).map(\.body)
    }

    @Test func theNoteJoinsThePageWrittenByRules() async throws {
        let (model, botID, requests) = try setUp(on: true)
        await model.loadedConversation(botID)
        #expect(model.session(botID).saveMemory(summarize: true))
        await waitUntil("the note") { await self.sessionBodies(model, botID).first?.contains("## Resumo") == true }
        let bodies = await sessionBodies(model, botID)
        #expect(bodies.count == 1) // the same page, not a second one
        #expect(bodies[0].contains("porta 4711") && bodies[0].contains("## Pedidos"))
        #expect(await requests.count == 1)
    }

    @Test func offOrNotAPauseNothingIsAsked() async throws {
        for (on, summarize) in [(false, true), (true, false)] {
            let (model, botID, requests) = try setUp(on: on)
            await model.loadedConversation(botID)
            #expect(model.session(botID).saveMemory(summarize: summarize))
            await waitUntil("the page") { await !self.sessionBodies(model, botID).isEmpty }
            try await Task.sleep(for: .milliseconds(200))
            #expect(await requests.count == 0)
            #expect(await sessionBodies(model, botID).first?.contains("## Resumo") == false)
        }
    }

    @Test func aPageThatAlreadyHasASummaryIsNotReplaced() async throws {
        let bank = MemoryBank(directory: root.appending(path: "banco"))
        let page = try #require(SessionSummary.page(from: stretch(requests: 6), notes: ["nota da dobra"]))
        let path = try #require(await bank.saveSessionPath(page))
        var again = try #require(SessionSummary.page(from: stretch(requests: 6), notes: ["outra nota"]))
        again.path = path
        #expect(await bank.replaceSession(again) == false)
        #expect(await bank.read(path)?.body.contains("nota da dobra") == true)
    }

    @Test func anOpenedConversationShowsItsSummaryDecisionsAndWhatWasLeftOpen() throws {
        var items = stretch(requests: 2)
        items.append(TranscriptItem(.user(text: "Decidi usar o Postgres 16", attachments: [])))
        let page = try #require(SessionSummary.page(from: items, notes: ["nota velha", "Migrou para o Postgres 16."]))
        let item = MemorySnapshot.Item(path: page.path, kind: .sessao, title: page.title, body: page.body, date: .now, compacted: false)
        #expect(MemoryRow.details(of: item) == ["Migrou para o Postgres 16.", "Decidido: Decidi usar o Postgres 16",
                                                "Ficou sem resposta: Decidi usar o Postgres 16"])
        let plain = try #require(SessionSummary.page(from: [TranscriptItem(.user(text: "oi", attachments: [])),
                                                            TranscriptItem(.bot(text: "olá", isStreaming: false))]))
        #expect(MemoryRow.details(of: MemorySnapshot.Item(path: plain.path, kind: .sessao, title: plain.title, body: plain.body,
                                                          date: .now, compacted: false)).isEmpty)
    }
}
