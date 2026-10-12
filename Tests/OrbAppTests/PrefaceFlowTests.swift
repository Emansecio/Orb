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

    deinit { removeTestFolder(root) }

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

/// The prefaces rest on what stays in the history: a block of folder changes means something only next to the snapshot
/// it follows, and a memory counts as sent only while the message that carried it is still there. Trimming the history
/// (`ContextWindow.fit`) drops whole turns from the front, never from the middle, and `TurnPrompt.native` reads the
/// history it is given, so both hold by construction. These tests keep it that way.

private let mac = MacEnvironment(userName: "Maria", homePath: "/Users/maria", macOS: "macOS 15.1", locale: "pt_BR",
                                 languages: ["pt-BR"], timeZone: "UTC")

private let bulk = (0..<30).map { "modulo\($0)/" }

private func snapshot(_ step: Int) -> WorkspaceSnapshot {
    var snapshot = WorkspaceSnapshot(path: "/Users/maria/app", entries: bulk + ["arquivo\(step).txt"])
    snapshot.git = .init(branch: "main", commits: ["a1 2026-10-01 Primeiro"])
    return snapshot
}

private func brief(_ related: String) -> MemoryBrief {
    var brief = MemoryBrief(related: related)
    brief.notes = TurnPreface.relatedNotes(brief) // the first message takes the notes, later ones the related lines
    return brief
}

private func inputs(_ step: Int, related: String = "") -> TurnPromptInputs {
    var bot = Bot(name: "Atlas", role: "assistente", orb: OrbConfig())
    bot.workingDirectory = "/Users/maria/app"
    return TurnPromptInputs(bot: bot, skills: [], brief: brief(related), snapshot: snapshot(step), instructions: nil,
                            environment: mac, now: Date(timeIntervalSince1970: 1_790_000_000 + Double(step)))
}

/// A conversation of `turns` messages where the folder changes before each one, so the first message carries the whole
/// snapshot and each later one a block of changes. `related[turn]` is the memory line that message carries.
private func conversation(turns: Int, related: [Int: String] = [:], padding: Int = 0) -> [ChatMessage] {
    var history: [ChatMessage] = []
    var last: TurnPrompt.Native?
    for turn in 0..<turns {
        let built = TurnPrompt.native(inputs(turn, related: related[turn] ?? ""), history: history, lastWorkspaceHash: last?.workspaceHash,
                                      lastWorkspace: last?.workspace)
        let text = "pergunta \(turn) " + String(repeating: "x", count: padding)
        history += [.user(TurnPreface.prepend(built.preface, to: text)), ChatMessage(role: .assistant, content: "resposta \(turn)")]
        last = built
    }
    return history
}

struct PrefaceHistoryContractTests {
    @Test func theConversationHasTheChainTheTestsRelyOn() {
        let history = conversation(turns: 4)
        let users = history.filter { $0.role == .user }.map(\.content)
        #expect(users[0].contains(WorkspaceSnapshot.openTag))
        #expect(users.dropFirst().allSatisfy { $0.contains(WorkspaceSnapshot.changesOpenTag) && !$0.contains(WorkspaceSnapshot.openTag) })
    }

    @Test func trimmingTheHistoryDropsWholeTurnsFromTheFrontOnly() {
        let history = conversation(turns: 8, padding: 700)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 1_200))
        #expect(window.droppedCount > 0)
        let kept = window.messages.filter { $0.role == .user && $0.content.hasPrefix(TurnPreface.openTag) }.map(\.content)
        let all = history.filter { $0.role == .user }.map(\.content)
        // What is left is the end of the conversation, with no turn missing in the middle.
        #expect(!kept.isEmpty && kept == Array(all.suffix(kept.count)))
    }

    @Test func aChainWhoseSnapshotWasTrimmedAwayGetsTheWholeSnapshotAgain() {
        let history = conversation(turns: 8, padding: 700)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 1_200))
        let kept = window.messages
        #expect(!TurnPreface.hasSnapshot(in: kept)) // the snapshot was in the first message
        let last = TurnPrompt.native(inputs(7), history: history, lastWorkspaceHash: nil)
        let next = TurnPrompt.native(inputs(8), history: kept, lastWorkspaceHash: snapshot(7).hash, lastWorkspace: last.workspace)
        #expect(next.preface.contains(WorkspaceSnapshot.openTag) && !next.preface.contains(WorkspaceSnapshot.changesOpenTag))
    }

    @Test func aSnapshotThatSurvivesKeepsEveryBlockOfChangesAfterIt() {
        let history = conversation(turns: 4)
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 100_000))
        #expect(window.droppedCount == 0 && window.messages.count == history.count)
        let last = TurnPrompt.native(inputs(3), history: Array(history.prefix(6)), lastWorkspaceHash: nil)
        let next = TurnPrompt.native(inputs(4), history: window.messages, lastWorkspaceHash: snapshot(3).hash, lastWorkspace: last.workspace)
        #expect(TurnPreface.hasSnapshot(in: window.messages))
        #expect(next.preface.contains(WorkspaceSnapshot.changesOpenTag) && !next.preface.contains(WorkspaceSnapshot.openTag))
    }

    @Test func aMemoryCountsAsSentOnlyWhileItsMessageIsStillInTheHistory() {
        let line = "- [Fato, 07/10/2026 14:32 #a1b2] O banco é Postgres 16"
        let history = conversation(turns: 8, related: [0: line], padding: 700)
        // In the whole history the line is out of the window of the last three messages, so it is not "sent" anymore...
        #expect(TurnPreface.relatedLines(in: history).isEmpty)
        // ...and with a short history it is.
        #expect(TurnPreface.relatedLines(in: Array(history.prefix(4))) == [line])
        // Whatever the trimming keeps, a line only counts if its message was kept.
        let kept = ContextWindow.fit(conversation(turns: 8, related: [1: line], padding: 700), budget: ContextBudget(tokens: 1_200)).messages
        #expect(TurnPreface.relatedLines(in: kept).isEmpty)
    }

    @Test func theWindowOfRelatedMemoryIsWithinWhatTrimmingKeepsWhole() {
        // The window is counted in messages of the history that is actually sent, and the budget never trims below the
        // latest turn, so a window larger than the history just means "everything still there".
        let history = conversation(turns: 2, related: [0: "- [Fato, 07/10/2026 14:32 #a1b2] A"])
        #expect(TurnPreface.relatedLines(in: history).count == 1)
        #expect(TurnPreface.relatedWindow == 3)
    }
}
