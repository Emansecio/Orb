import Foundation
import Testing
@testable import Orb

/// What each model request carries, with the real `AppModel` turn in the middle: the folder snapshot and the related
/// memory go once, then only what changed.

private actor Requests {
    private(set) var received: [[ChatMessage]] = []
    func record(_ messages: [ChatMessage]) { received.append(messages) }
}

private struct RecordingModel: LLMClient {
    var requests = Requests()

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.record(messages)
                continuation.yield(.text("feito"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

@Suite final class PrefaceFlowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbPrefaceFlow-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func setUp(_ stub: RecordingModel) throws -> (AppModel, Bot, URL) {
        let folder = root.appending(path: "pasta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<25 { try "x".write(to: folder.appending(path: "arquivo\(index).txt"), atomically: true, encoding: .utf8) }
        var state = AppState.initial
        state.bots[0].workingDirectory = folder.path
        let store = Store(directory: root.appending(path: "dados"))
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { stub }
        return (model, model.bots[0], folder)
    }

    @MainActor private func say(_ text: String, _ model: AppModel, _ bot: Bot) async {
        await WorkspaceSnapshots.shared.invalidate(bot.id) // the folder is read again, as it is a minute later
        #expect(model.send(text, to: bot.id))
        await waitUntil("the turn to end") { !model.isWorking(bot.id) && model.turns[bot.id] == nil }
    }

    /// The user messages of a request, newest last.
    private func userMessages(_ request: [ChatMessage]) -> [String] { request.filter { $0.role == .user }.map(\.content) }

    @Test @MainActor func theFolderAndTheMemoryGoOnceThenOnlyWhatChanged() async throws {
        let stub = RecordingModel()
        let (model, bot, folder) = try setUp(stub)
        let bank = model.memory.bank(for: bot.id)
        await bank.remember("O banco de dados do projeto Fênix é Postgres 16 hospedado na Hetzner.")
        await bank.remember("A reunião semanal com o cliente Acme acontece toda terça às 10h.")

        await say("Qual é o banco de dados do projeto Fênix?", model, bot)
        // The Orb (or anyone) adds a file; the next message says only that.
        try "novo".write(to: folder.appending(path: "relatorio.md"), atomically: true, encoding: .utf8)
        await say("Obrigado!", model, bot)
        await say("Quero rever o banco de dados do projeto Fênix de novo", model, bot)

        let requests = await stub.requests.received
        #expect(requests.count == 3)
        let first = try #require(userMessages(requests[0]).last)
        #expect(first.contains(WorkspaceSnapshot.openTag) && first.contains("Postgres 16"))

        let second = try #require(userMessages(requests[1]).last)
        #expect(second.contains(WorkspaceSnapshot.changesOpenTag) && second.contains("+relatorio.md"))
        #expect(!second.contains(WorkspaceSnapshot.openTag) && !second.contains("<memory_notes>")) // no snapshot again, nothing to look up in "Obrigado!"
        #expect(second.count < first.count / 3)

        // The same question as the first: the memory it brought is still in the last messages, so it is not sent again.
        let third = try #require(userMessages(requests[2]).last)
        #expect(!third.contains("<memory_notes>") && !third.contains(WorkspaceSnapshot.changesOpenTag) && !third.contains(WorkspaceSnapshot.openTag))
        #expect(model.conversations[bot.id]?.workspaceSeen?.entries.contains("relatorio.md") == true)
    }

    @Test @MainActor func aFileEditedInPlaceComesAsOneShortLineNotAWholeSnapshot() async throws {
        let stub = RecordingModel()
        let (model, bot, folder) = try setUp(stub)
        await say("Olá", model, bot)
        // Only a file's time changes: the snapshot's hash is the same, but the model is told which file was edited.
        try "mais".write(to: folder.appending(path: "arquivo3.txt"), atomically: true, encoding: .utf8)
        await say("e então?", model, bot)
        let second = try #require(await userMessages(stub.requests.received[1]).last)
        #expect(!second.contains(WorkspaceSnapshot.openTag))
        #expect(second.contains(WorkspaceSnapshot.changesOpenTag) && second.contains("Edited since: arquivo3.txt"))
        #expect(second.contains("re-list the folder"))
        // Said once: the next message has nothing new about the folder.
        await say("tudo certo?", model, bot)
        let third = try #require(await userMessages(stub.requests.received[2]).last)
        #expect(!third.contains(WorkspaceSnapshot.changesOpenTag) && !third.contains(WorkspaceSnapshot.openTag))
    }
}
