import Foundation
import Testing
@testable import Orb

/// Persistence: unreadable files are kept, never overwritten; decoding skips what it can't read; old tool
/// outputs are pruned on save; conversations load lazily; drafts and routines behave.
@Suite final class StoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbStore-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        removeTestFolder(root)
    }

    private var stateURL: URL { root.appending(path: "state.json") }

    private func conversationURL(_ id: UUID) -> URL { root.appending(path: "conversations/\(id.uuidString).json") }

    private func siblings(of url: URL, withPrefix prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { url.deletingLastPathComponent().appending(path: $0) }
    }

    // MARK: Unreadable files

    @Test func unreadableStateIsKeptAsATimestampedCopy() throws {
        try put("{ not json", at: stateURL)
        let read = Store(directory: root).readState()
        #expect(read.value == nil)
        let copy = try #require(read.notice?.copy)
        #expect(copy.lastPathComponent.hasPrefix("state.json.corrupt-"))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test func anExistingCorruptFileDoesNotBlockTheNextOne() throws {
        let store = Store(directory: root)
        try put("old .corrupt from an earlier version", at: root.appending(path: "state.json.corrupt"))
        try put("first", at: stateURL)
        _ = store.readState()
        try put("second", at: stateURL) // same second: the name is taken
        let read = store.readState()
        #expect(read.notice?.copy != nil)
        let copies = siblings(of: stateURL, withPrefix: "state.json.corrupt-")
        #expect(copies.count == 2)
        #expect(Set(try copies.map { try String(contentsOf: $0, encoding: .utf8) }) == ["first", "second"])
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    }

    @Test @MainActor func launchWithAnUnreadableStateKeepsTheOriginalAndTellsTheUser() throws {
        try put("{ not json", at: stateURL)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(model.bots.map(\.name) == ["Atlas"]) // the initial state, in memory
        let notice = try #require(model.dataNotices.first)
        let copy = try #require(notice.copy)
        #expect(notice.message.contains(copy.lastPathComponent))

        model.saveNow() // writes the new state next to the copy, never over it
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{ not json")
        #expect(Store(directory: root).loadState()?.bots.map(\.name) == ["Atlas"])

        model.dismissDataNotice()
        #expect(model.dataNotices.isEmpty)
    }

    @Test func aFileThatCannotBeMovedAsideIsNeverWrittenOver() throws {
        try put("{ not json", at: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path) // no moving or replacing
        let failures = LockedBox<[String]>([])
        let store = Store(directory: root) { failures.append($0.message) }
        let read = store.readState()
        #expect(read.value == nil && read.notice?.copy == nil && read.notice != nil)

        store.save(AppState.initial)
        store.flush()
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == "{ not json")
        #expect(failures.value.count == 1)
    }

    @Test func aFileThatCannotBeReadIsBlockedFromWrites() throws {
        try put("precious", at: stateURL)
        // The folder stays writable: only the guard (not the filesystem) can stop the write.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stateURL.path)
        let failures = LockedBox<[String]>([])
        let store = Store(directory: root) { failures.append($0.message) }
        let read = store.readState()
        guard read.value == nil, read.notice != nil else { // running as root can read it anyway
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
            return
        }
        #expect(read.notice?.copy == nil)

        store.save(AppState.initial)
        store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == "precious")
        #expect(failures.value.count == 1)
    }

    @Test func saveFailuresAreReported() throws {
        try put("a file, not a folder", at: root.appending(path: "data"))
        let failures = LockedBox<[String]>([])
        let store = Store(directory: root.appending(path: "data")) { failures.append($0.message) }
        store.save(AppState.initial)
        store.flush()
        #expect(failures.value.count == 1)
        #expect(failures.value.first?.contains("state.json") == true)
    }

    // MARK: Tolerant decoding

    @Test func unknownCasesAreSkippedOrFallBackInsteadOfLosingTheConversation() throws {
        let id = UUID()
        let conversation = Conversation(
            items: [TranscriptItem(.user(text: "oi", attachments: [])), TranscriptItem(.notice("fim"))],
            messages: [.user("oi"), ChatMessage(role: .assistant, content: "olá")])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any])
        let tool = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ToolCall(kind: .shell, title: "Rodando", detail: "ls", state: .done, output: "ok")))
        var future = try #require(tool as? [String: Any])
        future["kind"] = "teleport"
        future["state"] = "paused"
        json["items"] = (json["items"] as? [Any] ?? [])
            + [["id": UUID().uuidString, "kind": ["hologram": ["text": "?"]], "date": 0],
               ["id": UUID().uuidString, "kind": ["tool": ["_0": future]], "date": 0]]
        json["messages"] = (json["messages"] as? [Any] ?? []) + [["role": "oracle", "content": "?"]]
        let original = try JSONSerialization.data(withJSONObject: json)
        try put(String(decoding: original, as: UTF8.self), at: conversationURL(id))

        let read = Store(directory: root).readConversation(id)
        let loaded = try #require(read.value)
        #expect(loaded.messages.map(\.content) == ["oi", "olá"])
        guard loaded.items.count == 3 else { // the unknown kind of item is gone, the rest stays
            Issue.record("expected 3 items, got \(loaded.items.count)")
            return
        }
        guard case .tool(let call) = loaded.items[2].kind else { Issue.record("tool item lost"); return }
        #expect(call.kind == .connector && call.state == .failed && call.output == "ok")
        // What was dropped disappears on the next save, so the original is kept beside it.
        let copy = try #require(read.notice?.copy)
        #expect(try Data(contentsOf: copy) == original)
        #expect(FileManager.default.fileExists(atPath: conversationURL(id).path))
    }

    @Test func anUnknownSettingValueKeepsACopyOfTheFile() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any])
        var bots = try #require(json["bots"] as? [[String: Any]])
        bots[0]["permissionMode"] = "auto-plus"
        json["bots"] = bots
        let original = try JSONSerialization.data(withJSONObject: json)
        try put(String(decoding: original, as: UTF8.self), at: stateURL)

        let store = Store(directory: root)
        let read = store.readState()
        #expect(read.value?.bots[0].permissionMode == .ask)
        let copy = try #require(read.notice?.copy)
        #expect(try Data(contentsOf: copy) == original)
        _ = store.readState() // read again: the same copy, not another one
        #expect(siblings(of: stateURL, withPrefix: "state.json.corrupt-").count == 1)
    }

    @Test func anItemSkippedWhenNoCopyCanBeKeptBlocksTheWritesAndSaysSo() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any])
        var bots = try #require(json["bots"] as? [[String: Any]])
        bots.append(["name": "Sem id"]) // unreadable bot: skipped
        json["bots"] = bots
        let original = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        try put(original, at: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path) // no new files: no copy
        let failures = LockedBox<[String]>([])
        let store = Store(directory: root) { failures.append($0.message) }
        let read = store.readState()
        guard getuid() != 0 else { return } // root can write there anyway
        #expect(read.value != nil && read.notice?.copy == nil)
        #expect(read.notice?.message.contains("não foi possível guardar uma cópia") == true)
        #expect(Store.gate.isBlocked(stateURL))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        store.save(AppState.initial)
        store.flush()
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == original) // the skipped bot is still in the file
    }

    @Test func unknownValuesInTheStateKeepTheRestOfIt() throws {
        let state = AppState.initial
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var bots = try #require(json["bots"] as? [[String: Any]])
        bots[0]["permissionMode"] = "godMode"
        bots[0]["capabilities"] = ["terminal", "telepathy"]
        bots.append(["name": "Sem id"]) // unreadable bot: skipped
        json["bots"] = bots
        json["providers"] = [["kind": "skynet"]]
        json["routines"] = [["id": UUID().uuidString, "name": "x", "botID": UUID().uuidString, "schedule": ["lunar": [:]]]]
        try put(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), at: stateURL)

        let read = Store(directory: root).readState()
        let loaded = try #require(read.value)
        #expect(loaded.bots.map(\.name) == ["Atlas"])
        #expect(loaded.bots[0].permissionMode == .ask)
        #expect(loaded.bots[0].capabilities == [.terminal])
        #expect(loaded.providers.isEmpty && loaded.routines.isEmpty)
        #expect(read.notice?.copy != nil)
    }

    @Test func aTemperamentOrAPIFormatFromANewerBuildKeepsTheOrbAndTheProvider() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any])
        var bots = try #require(json["bots"] as? [[String: Any]])
        var look = try #require(bots[0]["orb"] as? [String: Any])
        look["temperament"] = "sonolento"
        bots[0]["orb"] = look
        json["bots"] = bots
        let models: [[String: Any]] = [["id": "g1", "name": "Gemini", "format": "gemini"], ["id": "m1", "name": "Modelo", "format": "chat"]]
        json["providers"] = [["kind": "custom", "baseURL": "https://gateway.exemplo/v1", "format": "grpc", "headers": ["X-Chave": "1"],
                              "models": models]]
        try put(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), at: stateURL)

        let read = Store(directory: root).readState()
        let loaded = try #require(read.value)
        #expect(loaded.bots.map(\.name) == ["Atlas"])
        #expect(loaded.bots[0].orb.temperament == .equilibrado)
        let account = try #require(loaded.providers.first)
        #expect(account.baseURL == "https://gateway.exemplo/v1" && account.headers == ["X-Chave": "1"])
        #expect(account.format == .chat)
        #expect(account.models.map(\.id) == ["m1"]) // the model nobody here can call is left out, not the provider
        #expect(read.notice?.copy != nil) // what was replaced is kept in a copy of the file
    }

    @Test func aCleanFileProducesNoNoticeAndNoCopy() throws {
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let read = store.readState()
        #expect(read.value != nil && read.notice == nil)
        #expect(siblings(of: stateURL, withPrefix: "state.json.corrupt").isEmpty)
    }

    // MARK: Pruning

    private func longConversation() -> (Conversation, outputs: [String]) {
        let outputs = (1...3).map { n in "\(n)-início " + String(repeating: "x", count: 20_000) + " fim-\(n)" }
        var conversation = Conversation()
        for (index, output) in outputs.enumerated() {
            let part = storeTurn(index + 1, output: output)
            conversation.items += part.items
            conversation.messages += part.messages
        }
        return (conversation, outputs)
    }

    private func toolOutputs(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { if case .tool(let call) = $0.kind { call.output } else { nil } }
    }

    @Test func oldToolOutputsKeepOnlyAHeadAndATail() {
        let (conversation, outputs) = longConversation()
        let pruned = conversation.pruningOldToolOutputs()

        let stored = toolOutputs(pruned)
        #expect(stored[0].count <= 4_000 && stored[0].hasPrefix("1-início") && stored[0].hasSuffix("fim-1"))
        #expect(stored[0].contains("omitidos"))
        // The last two user turns are recent: intact.
        #expect(Array(stored[1...]) == Array(outputs[1...]))
        let toolMessages = pruned.messages.filter { $0.role == .tool }.map(\.content)
        #expect(toolMessages[0] == stored[0])
        #expect(Array(toolMessages[1...]) == Array(outputs[1...]))
        // Only outputs change.
        #expect(pruned.items.count == conversation.items.count && pruned.messages.count == conversation.messages.count)
        // The in-memory conversation is untouched, and pruning twice changes nothing more.
        #expect(toolOutputs(conversation) == outputs)
        #expect(pruned.pruningOldToolOutputs().messages == pruned.messages)
    }

    @Test func shortConversationsAreNotPruned() {
        var conversation = Conversation()
        let part = storeTurn(1, output: String(repeating: "y", count: 50_000))
        conversation.items = part.items
        conversation.messages = part.messages
        #expect(conversation.pruningOldToolOutputs().messages == conversation.messages)
        #expect(toolOutputs(conversation.pruningOldToolOutputs()) == toolOutputs(conversation))
    }

    @Test func savingWritesThePrunedConversationButMemoryKeepsTheFullOne() throws {
        let (conversation, outputs) = longConversation()
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation, for: id)
        store.flush()
        let loaded = try #require(store.loadConversation(id))
        #expect(toolOutputs(loaded)[0].count <= 4_000)
        #expect(Array(toolOutputs(loaded)[1...]) == Array(outputs[1...]))
        #expect(toolOutputs(conversation) == outputs)
        #expect(try Data(contentsOf: conversationURL(id)).count < 100_000)
    }

    // MARK: Model: lazy loading and quitting

    @MainActor private func twoOrbs() throws -> (bots: [Bot], first: UUID, second: UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let store = Store(directory: root)
        store.save(state)
        for (index, bot) in state.bots.enumerated() {
            // A reply, not a request: a conversation that ends in an unanswered request opens as interrupted.
            store.save(Conversation(items: [TranscriptItem(.bot(text: "conversa \(index)", isStreaming: false))],
                                    messages: [ChatMessage(role: .assistant, content: "conversa \(index)")]), for: bot.id)
        }
        store.flush()
        return (state.bots, state.bots[0].id, state.bots[1].id)
    }

    @Test @MainActor func onlyTheSelectedConversationLoadsAtLaunchTheRestLoadOnDemandOrInTheBackground() async throws {
        let orbs = try twoOrbs()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        #expect(model.transcript(orbs.first).count == 1)
        #expect(model.transcript(orbs.second).isEmpty) // not read yet

        // A refused send to the unloaded Orb keeps its history: it never starts from an empty conversation.
        #expect(model.send("oi", to: orbs.second) == false)
        #expect(model.transcript(orbs.second).count == 2)

        // Selecting loads too; and the background pass doesn't replace what is already there.
        model.selection = .bot(orbs.second)
        await model.loadRemainingConversations()
        #expect(model.transcript(orbs.second).count == 2)
    }

    @Test @MainActor func theBackgroundPassLoadsTheOtherConversations() async throws {
        let orbs = try twoOrbs()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        await model.loadRemainingConversations()
        #expect(model.transcript(orbs.second).count == 1)
    }

    @Test @MainActor func quittingWritesOnlyTheConversationsThatChanged() async throws {
        let orbs = try twoOrbs()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        await model.loadRemainingConversations()
        // Same content in a form the encoder wouldn't produce: any rewrite shows.
        let sentinel = try String(contentsOf: conversationURL(orbs.second), encoding: .utf8) + "\n"
        try put(sentinel, at: conversationURL(orbs.second))

        #expect(model.send("oi", to: orbs.first) == false) // refused (no model), but the transcript changed
        model.saveNow()

        #expect(Store(directory: root).loadConversation(orbs.first)?.items.count == 2)
        #expect(try String(contentsOf: conversationURL(orbs.second), encoding: .utf8) == sentinel)
    }

    @Test @MainActor func aConversationThatLostItemsIsRewrittenOnceAndNamesTheOrb() async throws {
        let orbs = try twoOrbs()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: conversationURL(orbs.second))) as? [String: Any])
        json["items"] = (json["items"] as? [Any] ?? []) + [["id": UUID().uuidString, "kind": ["hologram": [:]], "date": 0]]
        try put(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), at: conversationURL(orbs.second))

        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        await model.loadRemainingConversations()
        #expect(model.dataNotices.count == 1)
        #expect(model.dataNotices.first?.message.hasPrefix("Conversa de Luna: ") == true)
        model.saveNow()
        #expect(siblings(of: conversationURL(orbs.second), withPrefix: "\(orbs.second.uuidString).json.corrupt-").count == 1)

        // The next launch finds a clean file: no new copy, no new notice.
        let next = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        await next.loadRemainingConversations()
        #expect(next.dataNotices.isEmpty)
        #expect(siblings(of: conversationURL(orbs.second), withPrefix: "\(orbs.second.uuidString).json.corrupt-").count == 1)
        #expect(next.transcript(orbs.second).count == 1)
    }

    // MARK: Model: drafts and attachments

    @MainActor private func modelWithAProvider() -> (AppModel, Bot) {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        // A gateway without an address is "usable" but has no client: the turn fails before any network call.
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        return (model, model.bots[0])
    }

    @Test @MainActor func aRoutineDoesNotWipeWhatYouAreTyping() async {
        let (model, bot) = modelWithAProvider()
        let routine = Routine(name: "Resumo", botID: bot.id, prompt: "resuma o dia", schedule: .daily(hour: 9, minute: 0))
        model.routines = [routine]
        model.drafts[bot.id] = "rascunho em andamento"

        model.runRoutine(routine.id)
        await model.routineStarted()
        // It ran. (Not `isWorking`: with no address the turn fails at once, and on a slow machine it is already over here.)
        #expect(model.routines.first?.lastRun != nil)
        #expect(model.drafts[bot.id] == "rascunho em andamento")
        model.stop(bot.id)
    }

    @Test @MainActor func quickAskAndSuggestionsKeepTheDraftButTheComposerClearsIt() {
        let (model, bot) = modelWithAProvider()
        model.drafts[bot.id] = "rascunho"
        #expect(model.send("pergunta rápida", to: bot.id))
        #expect(model.drafts[bot.id] == "rascunho")
        model.stop(bot.id)

        #expect(model.send("rascunho", to: bot.id, fromUser: true))
        #expect(model.drafts[bot.id] == "")
        model.stop(bot.id)
    }

    @Test @MainActor func aRefusedSendReportsItSoTheComposerKeepsAttachmentsAndDraft() {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false) // no provider set up
        let bot = model.bots[0]
        model.drafts[bot.id] = "texto"
        let sent = model.send("texto", attachments: [URL(fileURLWithPath: "/tmp/a.txt")], to: bot.id, fromUser: true)
        #expect(sent == false)
        #expect(model.drafts[bot.id] == "texto")
        #expect(model.send("   ", to: bot.id, fromUser: true) == false)
    }

    // MARK: Routines

    @Test func aReEnabledRoutineIsNotDueRightAway() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var routine = Routine(name: "r", botID: UUID(), prompt: "p", schedule: .everyHours(1), isEnabled: false,
                              createdAt: now.addingTimeInterval(-5 * 86_400), lastRun: now.addingTimeInterval(-4 * 86_400))
        #expect(routine.nextRun <= now) // would fire on the next 30 s check

        routine.setEnabled(true, now: now)
        #expect(routine.isEnabled)
        #expect(routine.nextRun > now)
        #expect(routine.nextRun == now.addingTimeInterval(3600))

        routine.setEnabled(true, now: now.addingTimeInterval(600)) // already on: lastRun stays
        #expect(routine.lastRun == now)
        routine.setEnabled(false, now: now.addingTimeInterval(700))
        #expect(!routine.isEnabled && routine.lastRun == now)
    }
}

extension Store {
    func loadState() -> AppState? { readState().value }
    func loadConversation(_ botID: UUID) -> Conversation? { readConversation(botID).value }
}
