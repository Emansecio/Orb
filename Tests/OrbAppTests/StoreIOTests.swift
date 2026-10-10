import Foundation
import Testing
@testable import Orb

extension Store {
    /// Holds the writer until `release` is signalled, as a long write would.
    func stallWriter(until release: DispatchSemaphore) {
        WriterQueues.queue(for: directory).async { release.wait() }
    }
}

/// How the Store reads and writes: saves that redo only what changed (and still write the document every version of
/// the app reads), reads that do not queue behind unrelated writes, files cut short by a crash, and the notes that
/// let the app know what is unsaved in a conversation without reading it.
@Suite final class StoreIOTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbStoreIO-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "conversations").path)
        removeTestFolder(root)
    }

    private func conversationURL(_ id: UUID) -> URL { root.appending(path: "conversations/\(id.uuidString).json") }
    private func metaURL(_ id: UUID) -> URL { root.appending(path: "conversations/\(id.uuidString).meta.json") }

    /// A small deterministic generator, so a failure can be replayed.
    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func turn(_ n: Int, output: String) -> (items: [TranscriptItem], messages: [ChatMessage]) {
        let call = ToolCall(kind: .file, title: "Lendo", detail: "f\(n)", state: .done, output: output)
        return ([TranscriptItem(.user(text: "pergunta \(n)", attachments: [])), TranscriptItem(.tool(call)),
                 TranscriptItem(.bot(text: "resposta \(n)", isStreaming: false))],
                [.user("pergunta \(n)"),
                 ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c\(n)", name: "read_file", arguments: "{}")]),
                 .tool("c\(n)", output), ChatMessage(role: .assistant, content: "resposta \(n)")])
    }

    private func conversation(turns: Int, outputSize: Int = 9_000) -> Conversation {
        var conversation = Conversation()
        for n in 1...max(1, turns) {
            let part = turn(n, output: "\(n)-início " + String(repeating: "á", count: outputSize) + " fim-\(n)")
            conversation.items += part.items
            conversation.messages += part.messages
        }
        return conversation
    }

    /// The document the old, whole-conversation save wrote.
    private func reference(_ conversation: Conversation) throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation.pruningOldToolOutputs()))
    }

    private func same(_ a: Conversation, _ b: Conversation) -> Bool {
        a.items == b.items && a.messages == b.messages && a.claudeSessionID == b.claudeSessionID
            && a.claudeSeenCount == b.claudeSeenCount && a.memorySavedCount == b.memorySavedCount
            && a.summary == b.summary && a.summaryCoveredCount == b.summaryCoveredCount && a.workspaceHash == b.workspaceHash
            && a.claudeWorkspaceHash == b.claudeWorkspaceHash && a.claudeStandingHash == b.claudeStandingHash
            && a.claudeMemoryPinned == b.claudeMemoryPinned && a.claudeSessionFolder == b.claudeSessionFolder
    }

    // MARK: The incremental encoder writes the same document

    @Test func incrementalEncodingDecodesToWhatTheWholeEncodeWrites() throws {
        var random = Random(state: 42)
        var live = conversation(turns: 3)
        let encoder = ConversationEncoder()
        for step in 0..<150 {
            switch random.next(9) {
            case 0, 1: // a new turn
                let part = turn(100 + step, output: String(repeating: "ç", count: 200 + random.next(9_000)))
                live.items += part.items
                live.messages += part.messages
            case 2: // the last item grows, as a streaming reply does
                if let last = live.items.indices.last, case .bot(let text, _) = live.items[last].kind {
                    live.items[last].kind = .bot(text: text + " mais texto", isStreaming: random.next(2) == 0)
                }
            case 3: // a tool call finishes: an item far from the end changes
                let tools = live.items.indices.filter { live.items[$0].hasToolOutput }
                if !tools.isEmpty, case .tool(var call) = live.items[tools[random.next(tools.count)]].kind {
                    let index = tools[random.next(tools.count)]
                    call = { if case .tool(let current) = live.items[index].kind { current } else { call } }()
                    call.output = String(repeating: "x", count: random.next(8_000))
                    live.items[index].kind = .tool(call)
                }
            case 4:
                live.memorySavedCount = random.next(live.items.count + 1)
            case 5:
                live.claudeSessionID = random.next(2) == 0 ? nil : "sessao-\(step)"
                live.summary = random.next(2) == 0 ? nil : "resumo \"com aspas\" e \\ barras"
            case 6: // an old item disappears (never done by the app, but the cache must not care)
                if live.items.count > 4 { live.items.remove(at: random.next(live.items.count)) }
            case 7:
                if live.messages.count > 4 { live.messages.remove(at: random.next(live.messages.count)) }
            default: // nothing changes
                break
            }
            let output = try #require(try encoder.encode(live))
            let data = encoder.data(for: output)
            let decoded = try JSONDecoder().decode(Conversation.self, from: data)
            #expect(same(decoded, try reference(live)), "step \(step)")
            encoder.commit(output, fingerprint: nil)
        }
    }

    @Test func fieldsThatLookLikeTheListsInsideTextDoNotConfuseTheSplit() throws {
        var live = conversation(turns: 2, outputSize: 50)
        live.summary = #"o texto tem "items":[] e "messages":[] dentro"#
        live.items.append(TranscriptItem(.notice(#"{"items":[],"messages":[]}"#)))
        let encoder = ConversationEncoder()
        let output = try #require(try encoder.encode(live))
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoder.data(for: output))
        #expect(same(decoded, try reference(live)))
    }

    @Test func onlyWhatChangedIsEncodedAgain() throws {
        var live = conversation(turns: 40, outputSize: 2_000)
        let encoder = ConversationEncoder()
        var output = try #require(try encoder.encode(live))
        encoder.commit(output, fingerprint: nil)
        #expect(!output.isUnchanged)

        output = try #require(try encoder.encode(live)) // the same conversation again
        #expect(output.isUnchanged)

        live.items.append(TranscriptItem(.notice("nova")))
        output = try #require(try encoder.encode(live))
        #expect(!output.isUnchanged)
        encoder.commit(output, fingerprint: nil)
        #expect(try encoder.encode(live)?.isUnchanged == true)
    }

    @Test func anItemWhoseOutputTurnsOldIsPrunedOnTheNextSave() throws {
        var live = conversation(turns: 2, outputSize: 20_000)
        let encoder = ConversationEncoder()
        var output = try #require(try encoder.encode(live))
        func toolOutputs(_ data: Data) throws -> [String] {
            try JSONDecoder().decode(Conversation.self, from: data).items.compactMap {
                if case .tool(let call) = $0.kind { call.output } else { nil }
            }
        }
        var outputs = try toolOutputs(encoder.data(for: output))
        #expect(outputs.map(\.count).allSatisfy { $0 > 10_000 }, "two user turns: nothing is old yet")
        encoder.commit(output, fingerprint: nil)

        let part = turn(3, output: "novo")
        live.items += part.items
        live.messages += part.messages
        output = try #require(try encoder.encode(live))
        outputs = try toolOutputs(encoder.data(for: output))
        #expect(outputs[0].count <= 4_000 && outputs[0].contains("omitidos"))
        #expect(outputs[1].count > 10_000)
    }

    @Test func theCacheIsBoundedByFilesAndBytes() {
        let cache = EncoderCache()
        let urls = (0..<10).map { root.appending(path: "c\($0).json") }
        for url in urls {
            _ = cache.encoder(for: url)
            cache.trim(keeping: url)
        }
        // The oldest were let go: asking again gives a new, empty encoder.
        #expect(cache.encoder(for: urls[0]).byteCount == 0)
    }

    // MARK: Saving to disk

    @Test func savingWritesTheSameFileFormatAsBefore() throws {
        let id = UUID()
        let live = conversation(turns: 4)
        let store = Store(directory: root)
        store.save(live, for: id)
        store.flush()
        let onDisk = try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: conversationURL(id)))
        #expect(same(onDisk, try reference(live)))
        // And it is plain JSON an older build (which uses JSONDecoder on the same types) reads.
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: conversationURL(id))) as? [String: Any])
        #expect((object["items"] as? [Any])?.count == live.items.count)
        #expect((object["messages"] as? [Any])?.count == live.messages.count)
    }

    @Test func aSaveThatChangesNothingWritesNothing() throws {
        let id = UUID()
        var live = conversation(turns: 3)
        let store = Store(directory: root)
        store.save(live, for: id)
        store.flush()
        let first = try #require(FileFingerprint(of: conversationURL(id)))

        Thread.sleep(forTimeInterval: 0.02) // a rewrite would show in the modification time
        store.save(live, for: id)
        store.flush()
        #expect(FileFingerprint(of: conversationURL(id)) == first)

        live.items.append(TranscriptItem(.notice("mudou")))
        store.save(live, for: id)
        store.flush()
        #expect(FileFingerprint(of: conversationURL(id)) != first)
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: conversationURL(id))).items.count == live.items.count)
    }

    @Test func aFileChangedBehindOurBackIsWrittenAgainEvenIfTheConversationDidNotChange() throws {
        let id = UUID()
        let live = conversation(turns: 3)
        let store = Store(directory: root)
        store.save(live, for: id)
        store.flush()
        try Data("alguém mexeu".utf8).write(to: conversationURL(id)) // another program, a restore, an older build

        store.save(live, for: id)
        store.flush()
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: conversationURL(id))).items.count == live.items.count)
    }

    @Test func aFailedWriteIsNeverMistakenForAFinishedOne() throws {
        let id = UUID()
        var live = conversation(turns: 2)
        let failures = Collected()
        let store = Store(directory: root) { failures.add($0.message) }
        store.save(live, for: id)
        store.flush()

        let folder = root.appending(path: "conversations")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) // no new files
        live.items.append(TranscriptItem(.notice("não chegou ao disco")))
        store.save(live, for: id)
        store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard failures.messages.count == 1 else { return } // running as root: the write could not fail

        // The same conversation, saved again: it must reach the disk this time.
        store.save(live, for: id)
        store.flush()
        let onDisk = try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: conversationURL(id)))
        #expect(onDisk.items.count == live.items.count)
    }

    // MARK: Crashes

    @Test func aFileCutShortAtAnyPointIsKeptAndNeverLoadedHalf() throws {
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation(turns: 3), for: id)
        store.flush()
        let whole = try Data(contentsOf: conversationURL(id))
        var cuts = Set((1..<20).map { whole.count * $0 / 20 })
        cuts.formUnion([1, whole.count - 1, whole.count / 2 + 7])
        for cut in cuts.sorted() {
            try whole.prefix(cut).write(to: conversationURL(id))
            let read = Store(directory: root).readConversation(id)
            #expect(read.value == nil, "cut at \(cut)")
            let copy = try #require(read.notice?.copy, "cut at \(cut)")
            #expect(try Data(contentsOf: copy) == whole.prefix(cut))
            #expect(!FileManager.default.fileExists(atPath: conversationURL(id).path)) // never overwritten with a blank one
        }
    }

    @Test func aWriteInterruptedBeforeTheRenameLeavesTheLastGoodFile() throws {
        let id = UUID()
        let store = Store(directory: root)
        let before = conversation(turns: 3)
        store.save(before, for: id)
        store.flush()
        // What a crash during the atomic replacement leaves: the half-written temporary copy beside the real file.
        let whole = try Data(contentsOf: conversationURL(id))
        try whole.prefix(whole.count / 3).write(to: root.appending(path: "conversations/\(id.uuidString).json.sb-1a2b3c4d-XYZ"))

        let read = Store(directory: root).readConversation(id)
        #expect(read.notice == nil)
        #expect(read.value.map { same($0, (try? reference(before)) ?? Conversation()) } == true)
    }

    @Test func aCrashBetweenTheConversationAndItsNoteLeavesANoteThatIsIgnored() throws {
        let id = UUID()
        let store = Store(directory: root)
        var live = conversation(turns: 2)
        live.memorySavedCount = live.items.count
        store.save(live, for: id)
        store.flush()
        #expect(store.readMeta(id)?.hasUnsavedStretch == false)

        // The conversation is replaced (and grows) but the app dies before the note is written: simulated by
        // replacing the file without the Store.
        live.items.append(TranscriptItem(.user(text: "mais uma", attachments: [])))
        try JSONEncoder().encode(live).write(to: conversationURL(id), options: .atomic)
        #expect(store.readMeta(id) == nil, "a stale note must not claim there is nothing to save")
    }

    // MARK: Reading while writing

    @Test func aReadDoesNotWaitBehindWritesToOtherFiles() async throws {
        let (a, b) = (UUID(), UUID())
        let store = Store(directory: root)
        store.save(conversation(turns: 2), for: a)
        store.save(conversation(turns: 3), for: b)
        store.flush()

        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)          // a long write is in progress...
        store.save(conversation(turns: 5), for: a) // ...with another save of a queued behind it
        defer { release.signal() }

        let read = await store.readConversationAsync(b) // b has nothing queued: it must not wait
        #expect(read.value?.items.count == 9)
    }

    @Test func aReadOfAFileWaitsForTheSaveQueuedForThatFile() async throws {
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation(turns: 2), for: id)
        store.flush()

        let release = DispatchSemaphore(value: 0)
        store.stallWriter(until: release)
        store.save(conversation(turns: 5), for: id)
        let reading = Task { await store.readConversationAsync(id) }
        try await Task.sleep(for: .milliseconds(150))
        release.signal() // the save goes through; the read must see it, not the older file
        let read = await reading.value
        #expect(read.value?.items.count == 15)
    }

    @Test func readsDuringASeriesOfSavesAlwaysSeeAWholeFile() async throws {
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation(turns: 1), for: id)
        store.flush()
        let sizes = Collected()
        let versions = (2...25).map { conversation(turns: $0, outputSize: 3_000) }
        let writer = Task.detached {
            for version in versions {
                store.save(version, for: id)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        for _ in 0..<60 {
            let read = await store.readConversationAsync(id)
            guard let value = read.value, read.notice == nil else {
                Issue.record("a read saw a missing or damaged file: \(String(describing: read.notice?.message))")
                break
            }
            sizes.add("\(value.items.count)")
        }
        await writer.value
        store.flush()
        #expect(store.readConversation(id).value?.items.count == 75)
        #expect(sizes.messages.allSatisfy { (Int($0) ?? 0) % 3 == 0 }, "every read was a whole conversation")
    }

    // MARK: Notes about a conversation

    @Test func theNoteTellsWhatIsUnsavedWithoutReadingTheConversation() throws {
        let id = UUID()
        let store = Store(directory: root)
        #expect(store.readMeta(id) == .empty, "no file: nothing to save")

        var live = conversation(turns: 3)
        live.memorySavedCount = 4
        store.save(live, for: id)
        store.flush()
        let meta = try #require(store.readMeta(id))
        #expect(meta.itemCount == 9 && meta.memorySavedCount == 4 && meta.hasUnsavedStretch)
        #expect(meta.lastItemDate == live.items.last?.date)

        live.memorySavedCount = live.items.count
        store.save(live, for: id)
        store.flush()
        #expect(store.readMeta(id)?.hasUnsavedStretch == false)
    }

    @Test func aConversationFromBeforeNotesExistGetsOneWhenItIsRead() throws {
        let id = UUID()
        var live = conversation(turns: 2)
        live.memorySavedCount = 2
        try FileManager.default.createDirectory(at: conversationURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(live).write(to: conversationURL(id)) // written by a version without notes
        let store = Store(directory: root)
        #expect(store.readMeta(id) == nil)

        _ = store.readConversation(id)
        store.flush()
        let meta = try #require(store.readMeta(id))
        #expect(meta.itemCount == 6 && meta.memorySavedCount == 2)
        #expect(FileManager.default.fileExists(atPath: metaURL(id).path))
    }

    @Test func aGarbledNoteIsJustIgnored() throws {
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation(turns: 2), for: id)
        store.flush()
        try Data("{ não é json".utf8).write(to: metaURL(id))
        #expect(store.readMeta(id) == nil)
        // and the conversation itself is unaffected
        #expect(store.readConversation(id).value?.items.count == 6)
    }

    @Test func deletingAConversationDeletesItsNote() throws {
        let id = UUID()
        let store = Store(directory: root)
        store.save(conversation(turns: 2), for: id)
        store.flush()
        store.deleteConversation(id)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: conversationURL(id).path))
        #expect(!FileManager.default.fileExists(atPath: metaURL(id).path))
        #expect(store.readMeta(id) == .empty)
    }
}

/// Messages collected from several threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ message: String) { lock.withLock { items.append(message) } }
    var messages: [String] { lock.withLock { items } }
}
