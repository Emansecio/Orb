import Foundation
import Security

/// Everything the app keeps between launches, except conversations (see `Store`) and API keys (Keychain).
struct AppState: Codable, Sendable {
    var bots: [Bot]
    var routines: [Routine] = []
    var skills: [Skill] = Skill.starters
    var connectors: [MCPServerConfig] = []
    var providers: [ProviderAccount] = []
    /// "provider/model" for bots without a model of their own.
    var defaultModel = ""
    /// Messages each Orb has not seen yet (by Orb id; Orbs with none are left out). Older files kept the count
    /// inside each Orb, and still load (see `init(from:)`).
    var unread: [String: Int] = [:]
    /// The latest reply of each Orb, shortened to a line, for the second line of its sidebar row (by Orb id; Orbs with
    /// none are left out). Older files have none.
    var replies: [String: ReplyPreview] = [:]
    /// How much conversation the Orbs remember word for word before folding the start into a summary.
    var contextMemory = ContextMemoryLevel.balanced
    /// Context windows models turned out to have (a request was refused for its size), by "provider/model".
    var learnedContexts: [String: LearnedContext] = [:]
    /// Who the user is, for every Orb (Ajustes → Geral → Você).
    var profile = UserProfile()
    /// Prices the user corrected on the Uso page, by "provider/model" (US$ per million tokens).
    var priceCorrections: [String: ModelPrice] = [:]
    /// The groups of Orbs (see `OrbGroup`); their threads are in `conversations/_grupos/`.
    var groups: [OrbGroup] = []
    /// The sidebar's categories of Orbs (see `SidebarCategory`); older files have none.
    var categories: [SidebarCategory] = []
    /// The conversations of each Orb that has more than one (by Orb id; see `OrbChats`). Older files have none.
    var chats: [String: OrbChats] = [:]

    /// What the app starts with when there is no data yet (a new install, after "Redefinir o Orb"): no Orb, so the
    /// window opens on the welcome, where Atlas is one click away.
    static let firstUse = AppState(bots: [])

    /// A state with Atlas ready, for tests and the developer modes' sample data.
    static let initial = AppState(bots: [
        Bot(name: "Atlas", role: "Assistente do seu Mac",
            orb: OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso", accessories: ["oculos-redondos"]))
    ])
}

/// Something about the data files the user should know: a file that couldn't be read (and where its copy is) or
/// a write that failed. Shown once by the app, in Portuguese.
struct StoreNotice: Sendable, Equatable {
    var message: String
    /// The untouched copy of the file that was set aside, when there is one.
    var copy: URL?
    /// The data file the notice is about, so the app can name what it holds (an Orb's conversation) instead of its
    /// file name. `message` always names the file too, as `“name”`, which is what the app replaces.
    var file: URL?
}

/// What reading a file produced: the value (nil when the file is missing or unreadable) and anything worth telling.
struct StoreRead<Value: Sendable>: Sendable {
    var value: Value?
    var notice: StoreNotice?
    /// How the file looked just before it was read: what a note made from `value` is valid for.
    var fingerprint: FileFingerprint?
}

/// JSON files in ~/Library/Application Support/Orb (override with `ORB_DATA_DIR`).
/// Encoding and disk writes run in order on one background queue, off the main thread. Reads do not use that queue:
/// they run on the caller's thread or on a concurrent queue of their own, so a conversation being opened never waits
/// behind another one being saved (`FileGate` keeps a read from overtaking a write to the same file).
///
/// Conversations: an Orb's current one is `conversations/<botID>.json`, with `conversations/<botID>.meta.json` beside
/// it (see `ConversationMeta`). Its earlier ones are archived in the folder beside it, `conversations/<botID>/`:
/// `<conversationID>.json` each, `index.json` listing them (a cache that is corrected from the files whenever it
/// disagrees), `routine-<routineID>.json` for the conversation of each routine, `pedido-<requestID>.json` for the one of
/// each request another Orb made (the last `DelegationLimits.keptPedidos`) and `grupo-<groupID>.json` for the one of the Orb
/// in each group.
///
/// A file that can't be read is never overwritten: it is set aside as `<name>.corrupt-<yyyyMMdd-HHmmss>` (or,
/// if that fails, left alone and blocked from writes for the rest of the session).
struct Store: Sendable {
    let directory: URL
    /// Called (on the store's queue) when a write fails; the app turns it into a message for the user.
    var onSaveFailure: (@Sendable (StoreNotice) -> Void)?
    /// Called (on the store's queue) with something worth telling that is not a failed write: a usage file that was
    /// read with items left out, or set aside. Nothing was lost by saving, so it must not count as a save failure.
    var onNotice: (@Sendable (StoreNotice) -> Void)?

    /// Every write, in order. One queue per data folder (the app has one; tests have one each, so a test that holds
    /// the writer cannot stall the others).
    private var queue: DispatchQueue { WriterQueues.queue(for: directory) }
    /// Reads of conversations and the state: concurrent, and at the priority of something the user is waiting for.
    static let readQueue = DispatchQueue(label: "app.orb.store.read", qos: .userInitiated, attributes: .concurrent)
    static let gate = FileGate()
    /// The encoders of the conversation files saved most recently (the ones being streamed into), so a save redoes
    /// only what changed. One cache per data folder; touched only on `queue`.
    private var encoders: EncoderCache { EncoderCache.shared(for: directory) }

    /// The user's folder, or, in a developer mode (`--snapshot`, `--render-*`) without `ORB_DATA_DIR`, a fresh temporary
    /// one (see `DevRun.dataFolder`). OpenBot's data is only ever copied into the user's own folder.
    static let standard: Store = {
        let location = DevRun.currentDataFolder
        if location.allowsLegacyMigration, LegacyMigration.shouldRun {
            LegacyMigration.run(into: location.url, from: URL.applicationSupportDirectory.appendingPathComponent(LegacyMigration.oldFolder))
        }
        return Store(directory: location.url)
    }()

    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// The Orb's first conversation (`chat` nil or the Orb's own id) is `conversations/<botID>.json`; the others it opened
    /// later (`OrbChats`) are in its archive folder, `conversa-<id>.json`.
    private func conversationURL(_ botID: UUID, _ chat: UUID? = nil) -> URL {
        guard let chat, chat != botID else { return directory.appendingPathComponent("conversations/\(botID.uuidString).json") }
        return archiveFolder(botID).appendingPathComponent("\(Self.conversaPrefix)-\(chat.uuidString).json")
    }

    /// The prefixes of the conversations an Orb keeps in its archive folder besides the earlier chats (a routine's run, a
    /// request from another Orb, a turn in a group, a conversation of its own made with "Nova conversa"): not the earlier
    /// chats `mergeArchive` folds back, so no index of the archive lists them.
    static var sideConversationPrefixes: [String] { [routinePrefix, pedidoPrefix, grupoPrefix, conversaPrefix].map { $0 + "-" } }

    /// Whether `file` is where a chat of this Orb is saved (its first one, or one made later), or the conversation of one
    /// of its side runs (a routine's, a request's, a group's).
    func isConversationFile(_ file: URL, of botID: UUID) -> Bool {
        file == conversationURL(botID)
            || (file.deletingLastPathComponent() == archiveFolder(botID) && Self.isSideConversationName(file.lastPathComponent))
    }

    static let routinePrefix = "routine", pedidoPrefix = "pedido", grupoPrefix = "grupo", conversaPrefix = "conversa"

    /// `routine-…`, `pedido-…`, `grupo-…` and `conversa-…`: the conversations that are not "earlier conversations" of the Orb.
    static func isSideConversationName(_ name: String) -> Bool {
        sideConversationPrefixes.contains { name.hasPrefix($0) }
    }

    private func metaURL(_ botID: UUID, _ chat: UUID? = nil) -> URL {
        conversationURL(botID, chat).deletingPathExtension().appendingPathExtension("meta.json")
    }

    // MARK: Reading

    func readState() -> StoreRead<AppState> {
        Self.gate.reading(stateURL) { read(AppState.self, from: stateURL, ifUnreadable: "o Orb começou do zero") }
    }

    /// Reads (and decodes) on the calling thread. The main thread uses this only when it cannot wait for
    /// `readConversationAsync`.
    func readConversation(_ botID: UUID, chat: UUID? = nil) -> StoreRead<Conversation> {
        loadConversation(botID, chat)
    }

    /// Like `readConversation`, on a thread of the store's own: the caller is not blocked, and nothing is waited for
    /// but the writes still queued for this very file.
    func readConversationAsync(_ botID: UUID, chat: UUID? = nil) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: loadConversation(botID, chat)) }
        }
    }

    private func loadConversation(_ botID: UUID, _ chat: UUID?) -> StoreRead<Conversation> {
        let url = conversationURL(botID, chat)
        let result = Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: "a conversa começou vazia")
        }
        // The decode of a long conversation leaves megabytes of freed memory the process would keep: give it back.
        if let size = result.fingerprint?.size, size > 1 << 20 { MemoryRelief.now() }
        // A conversation read without a valid note about it gets one, so the next launch can tell what is unsaved
        // in it without reading it again.
        if let conversation = result.value, let fingerprint = result.fingerprint, result.notice == nil,
           readMeta(botID, chat: chat)?.file != fingerprint {
            recordMeta(ConversationMeta(of: conversation, file: fingerprint), for: botID, chat, ifFileStill: fingerprint)
        }
        return result
    }

    /// What is known about the conversation without reading it: nil when no valid note exists, `.empty` when there is
    /// no conversation file.
    func readMeta(_ botID: UUID, chat: UUID? = nil) -> ConversationMeta? {
        let url = conversationURL(botID, chat), note = metaURL(botID, chat)
        return Self.gate.reading([url, note]) {
            guard let current = FileFingerprint(of: url) else { return ConversationMeta.empty }
            guard let data = try? Data(contentsOf: note),
                  let meta = try? JSONDecoder().decode(ConversationMeta.self, from: data), meta.file == current else { return nil }
            return meta
        }
    }

    func readMetaAsync(_ botID: UUID, chat: UUID? = nil) async -> ConversationMeta? {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readMeta(botID, chat: chat)) }
        }
    }

    /// Writes a note about a conversation just read, unless the file changed since (a save in between wrote a
    /// better note).
    private func recordMeta(_ meta: ConversationMeta, for botID: UUID, _ chat: UUID?, ifFileStill fingerprint: FileFingerprint) {
        let conversation = conversationURL(botID, chat), note = metaURL(botID, chat)
        enqueue(touching: [note]) {
            guard FileFingerprint(of: conversation) == fingerprint else { return }
            write(meta, to: note)
        }
    }

    // MARK: Writing

    /// Queues `work` on the writer, registering the files it touches first so that reads of them wait. Once the
    /// folder is sealed (`sealWrites`) the work is dropped, and `dropped` (if any) runs in its place, so that whoever
    /// waits for the work is not left waiting.
    func enqueue(touching urls: [URL], dropped: (@Sendable () -> Void)? = nil, _ work: @escaping @Sendable () -> Void) {
        Self.gate.willWrite(urls)
        let directory = directory
        queue.async {
            if WriteSeals.isSealed(directory) { dropped?() } else { work() }
            Self.gate.didWrite(urls)
        }
    }

    /// Ends every write to this folder from now on, the ones already queued included: the app is about to wipe it
    /// (`ResetExecutor`) and nothing may write the old state back afterwards. It does not wait: `flush()` afterwards
    /// waits for the write that was running. Not undone: the process is over soon after.
    func sealWrites() { WriteSeals.seal(directory) }

    func save(_ state: AppState) {
        enqueue(touching: [stateURL]) { write(state, to: stateURL) }
    }

    // MARK: Composer drafts

    /// What each Orb's composer holds that was not sent (`ComposerDraft`), so quitting does not lose it.
    static let draftsFileName = "rascunhos.json"
    private var draftsURL: URL { directory.appendingPathComponent(Self.draftsFileName) }

    /// Empty when there is none or it cannot be read: a draft is a convenience, and the next save writes the file again.
    func readDrafts() -> [UUID: ComposerDraft] {
        let url = draftsURL
        return Self.gate.reading(url) {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode([String: ComposerDraft].self, from: data) else { return [:] }
            return Dictionary(raw.compactMap { key, draft in UUID(uuidString: key).map { ($0, draft) } }) { first, _ in first }
        }
    }

    /// Writes the drafts; none at all removes the file.
    func saveDrafts(_ drafts: [UUID: ComposerDraft]) {
        let url = draftsURL
        enqueue(touching: [url]) {
            if drafts.isEmpty { try? FileManager.default.removeItem(at: url) } else {
                write(Dictionary(uniqueKeysWithValues: drafts.map { ($0.key.uuidString, $0.value) }), to: url)
            }
        }
    }

    // MARK: Connector catalogs

    private func connectorCatalogURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("conectores/\(id.uuidString).json")
    }

    /// nil when there is none or it cannot be read: it is a cache, the next start of the connector writes it again.
    func readConnectorCatalog(_ id: UUID) -> ConnectorCatalog? {
        let url = connectorCatalogURL(id)
        return Self.gate.reading(url) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ConnectorCatalog.self, from: $0) }
        }
    }

    func saveConnectorCatalog(_ catalog: ConnectorCatalog, for id: UUID) {
        let url = connectorCatalogURL(id)
        enqueue(touching: [url]) { write(catalog, to: url) }
    }

    func deleteConnectorCatalog(_ id: UUID) {
        let url = connectorCatalogURL(id)
        enqueue(touching: [url]) { try? FileManager.default.removeItem(at: url) }
    }

    /// Old tool outputs are stored shortened (`Conversation.pruningOldToolOutputs`); the caller's copy is untouched.
    /// The file is the same document either way; what is cheaper is that only items that changed since the last
    /// save of this file are encoded again, and a save that changes nothing writes nothing.
    /// `then` (on the store's queue) says whether the file is as written: false when the write failed.
    func save(_ conversation: Conversation, for botID: UUID, chat: UUID? = nil, then done: (@Sendable (Bool) -> Void)? = nil) {
        let url = conversationURL(botID, chat), note = metaURL(botID, chat)
        enqueue(touching: [url, note], dropped: { done?(false) }) {
            let result = writeConversation(conversation, to: url, cached: true)
            // A save that wrote nothing (nothing changed) leaves the note as it is.
            if result == .wrote { write(ConversationMeta(of: conversation, file: FileFingerprint(of: url)), to: note) }
            done?(result != .failed)
        }
    }

    /// Writes the conversation and says whether it is on disk (see `save`). For a caller that must not let go of
    /// another copy before this one is safe.
    func saveAndWait(_ conversation: Conversation, for botID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            save(conversation, for: botID) { continuation.resume(returning: $0) }
        }
    }

    /// Changes a conversation that is not in memory, in its file: read after the writes queued for it, changed and
    /// written back, with its note (what lands in one of an Orb's conversations that is not on show,
    /// `BotSession.changeChat`). A file that can't be read is set aside as a read does, and told (`onNotice`); the change
    /// then starts an empty one.
    func amend(_ botID: UUID, chat: UUID, _ change: @escaping @Sendable (inout Conversation) -> Void) {
        let url = conversationURL(botID, chat), note = metaURL(botID, chat)
        enqueue(touching: [url, note]) {
            // This write is queued, so no read of the file starts; one already under way ends first.
            Self.gate.waitForReaders(of: url)
            let found = read(Conversation.self, from: url, ifUnreadable: "a conversa recomeçou com o que chegou nela")
            if let notice = found.notice { onNotice?(notice) }
            if let size = found.fingerprint?.size, size > 1 << 20 { MemoryRelief.now() }
            var conversation = found.value ?? Conversation()
            change(&conversation)
            if writeConversation(conversation, to: url, cached: true) == .wrote {
                write(ConversationMeta(of: conversation, file: FileFingerprint(of: url)), to: note)
            }
        }
    }

    /// Lets go of what is kept for saving this Orb's conversation faster (it was unloaded).
    func releaseCache(for botID: UUID, chat: UUID? = nil) {
        let url = conversationURL(botID, chat)
        queue.async { encoders.remove(url) }
    }

    func deleteConversation(_ botID: UUID, chat: UUID? = nil) {
        let url = conversationURL(botID, chat), note = metaURL(botID, chat)
        enqueue(touching: [url, note]) {
            Self.gate.waitForReaders(of: url)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: note)
            encoders.remove(url)
        }
    }

    // MARK: Archive

    private func archiveFolder(_ botID: UUID) -> URL {
        directory.appendingPathComponent("conversations/\(botID.uuidString)", isDirectory: true)
    }

    private func archivedURL(_ botID: UUID, _ id: UUID) -> URL {
        archiveFolder(botID).appendingPathComponent("\(id.uuidString).json")
    }

    private func archiveIndexURL(_ botID: UUID) -> URL { archiveFolder(botID).appendingPathComponent("index.json") }

    // MARK: Side conversations (requests from other Orbs, turns in groups)

    private func sideConversationURL(_ botID: UUID, _ prefix: String, _ id: UUID) -> URL {
        archiveFolder(botID).appendingPathComponent("\(prefix)-\(id.uuidString).json")
    }

    /// `then` (on the store's queue) says whether the file is as written.
    func saveSideConversation(_ conversation: Conversation, prefix: String, id: UUID, for botID: UUID,
                              then done: (@Sendable (Bool) -> Void)? = nil) {
        let url = sideConversationURL(botID, prefix, id)
        enqueue(touching: [url], dropped: { done?(false) }) {
            let result = writeConversation(conversation, to: url, cached: true)
            done?(result != .failed)
        }
    }

    func readSideConversation(prefix: String, id: UUID, for botID: UUID,
                              ifUnreadable outcome: String = "a conversa começou vazia") -> StoreRead<Conversation> {
        let url = sideConversationURL(botID, prefix, id)
        return Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: outcome)
        }
    }

    func readSideConversationAsync(prefix: String, id: UUID, for botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readSideConversation(prefix: prefix, id: id, for: botID)) }
        }
    }

    func deleteSideConversation(prefix: String, id: UUID, for botID: UUID) {
        let url = sideConversationURL(botID, prefix, id)
        enqueue(touching: [url]) {
            Self.gate.waitForReaders(of: url)
            try? FileManager.default.removeItem(at: url)
            encoders.remove(url)
        }
    }

    /// The Orb keeps the conversations of its last `count` requests from other Orbs; older ones go (by the date they were written).
    func prunePedidos(for botID: UUID, keeping count: Int) {
        let folder = archiveFolder(botID)
        enqueue(touching: []) {
            let manager = FileManager.default
            let files = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(Self.pedidoPrefix + "-") && $0.pathExtension == "json" }
            guard files.count > count else { return }
            let dated = files.map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)
            }
            for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(count) {
                Self.gate.waitForReaders(of: url)
                try? manager.removeItem(at: url)
                encoders.remove(url)
            }
        }
    }

    /// Puts the conversations the old "Nova conversa" set aside (`<uuid>.json` in the Orb's folder of conversations)
    /// back into its one conversation (see `Conversation.merging`), once: their files go after the merged conversation
    /// is written. Reads of the conversation wait for it. A conversation file that can't be read is left alone, and so
    /// is a set-aside one that can't; the routines' and requests' files in the same folder are never touched.
    func mergeArchive(of botID: UUID) {
        let url = conversationURL(botID), note = metaURL(botID), index = archiveIndexURL(botID)
        enqueue(touching: [url, note, index]) {
            let manager = FileManager.default
            func setAside() -> [URL] {
                ((try? manager.contentsOfDirectory(atPath: archiveFolder(botID).path)) ?? []).compactMap { name in
                    guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(".json".count))) else { return nil }
                    return archivedURL(botID, id)
                }
            }
            let files = setAside()
            guard !files.isEmpty else {
                try? manager.removeItem(at: index) // the list of the set-aside ones, which is no longer read
                return
            }
            var current: Conversation?
            if manager.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url),
                      let read = try? JSONDecoder().decode(Conversation.self, from: data) else { return }
                current = read
            }
            let archived = files.compactMap { file -> (URL, Conversation)? in
                guard let data = try? Data(contentsOf: file),
                      let conversation = try? JSONDecoder().decode(Conversation.self, from: data) else { return nil }
                return (file, conversation)
            }
            guard !archived.isEmpty else { return }
            let merged = Conversation.merging(archived.map(\.1), into: current)
            guard writeConversation(merged, to: url, cached: true) != .failed else { return }
            write(ConversationMeta(of: merged, file: FileFingerprint(of: url)), to: note)
            for (file, _) in archived {
                Self.gate.waitForReaders(of: file)
                try? manager.removeItem(at: file)
            }
            if setAside().isEmpty { try? manager.removeItem(at: index) }
        }
    }

    /// The Orb's folder of conversations: its routines' and its requests' (the Orb is being deleted).
    func deleteArchive(_ botID: UUID) {
        let folder = archiveFolder(botID)
        enqueue(touching: []) {
            // Reads of those files run outside this queue: one under way finishes before the folder goes.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                Self.gate.waitForReaders(of: folder.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// `then` (on the store's queue) says whether the file is as written: false when the write failed or was dropped.
    func saveRoutineConversation(_ conversation: Conversation, routine routineID: UUID, for botID: UUID,
                                 then done: (@Sendable (Bool) -> Void)? = nil) {
        saveSideConversation(conversation, prefix: Self.routinePrefix, id: routineID, for: botID, then: done)
    }

    func readRoutineConversation(routine routineID: UUID, for botID: UUID) -> StoreRead<Conversation> {
        readSideConversation(prefix: Self.routinePrefix, id: routineID, for: botID,
                             ifUnreadable: "o histórico da rotina começou vazio")
    }

    func readRoutineConversationAsync(routine routineID: UUID, for botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readRoutineConversation(routine: routineID, for: botID)) }
        }
    }

    // MARK: Groups

    /// A group's thread: `conversations/_grupos/<groupID>.json` (only its items are used).
    private func groupConversationURL(_ groupID: UUID) -> URL {
        directory.appendingPathComponent("conversations/\(GroupFiles.threadFolder)/\(groupID.uuidString).json")
    }

    /// `then` (on the store's queue) says whether the file is as written: false when the write failed or was dropped.
    func saveGroupConversation(_ conversation: Conversation, group groupID: UUID, then done: (@Sendable (Bool) -> Void)? = nil) {
        let url = groupConversationURL(groupID)
        enqueue(touching: [url], dropped: { done?(false) }) {
            let result = writeConversation(conversation, to: url, cached: true)
            done?(result != .failed)
        }
    }

    /// A file that cannot be read is set aside and never written over (see `read`).
    func readGroupConversation(group groupID: UUID) -> StoreRead<Conversation> {
        let url = groupConversationURL(groupID)
        return Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: "a conversa do grupo começou vazia")
        }
    }

    func deleteGroupConversation(group groupID: UUID) {
        let url = groupConversationURL(groupID)
        enqueue(touching: [url]) {
            Self.gate.waitForReaders(of: url)
            try? FileManager.default.removeItem(at: url)
            encoders.remove(url)
        }
    }

    // A member's conversation in a group is `conversations/<botID>/grupo-<groupID>.json`: the one side-conversation API
    // (`saveSideConversation(prefix:)`, with `grupoPrefix`), under the group's names.
    func deleteGroupSideConversation(group groupID: UUID, for botID: UUID) {
        deleteSideConversation(prefix: Self.grupoPrefix, id: groupID, for: botID)
    }

    func deleteRoutineConversation(routine routineID: UUID, for botID: UUID) {
        deleteSideConversation(prefix: Self.routinePrefix, id: routineID, for: botID)
    }

    /// Waits for pending writes.
    func flush() { queue.sync {} }

    func read<T: Decodable & Sendable>(_ type: T.Type, from url: URL, ifUnreadable outcome: String) -> StoreRead<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreRead() }
        let name = url.lastPathComponent
        // Taken before the bytes are: a note made from what is read can only be older than the file, never newer.
        let fingerprint = FileFingerprint(of: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // It exists but can't be read right now: treating that as "empty" would overwrite it on the next save.
            Self.gate.block(url)
            return StoreRead(notice: StoreNotice(message: "Não foi possível ler “\(name)” (\(error.localizedDescription)). "
                + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo.", file: url))
        }
        do {
            let (value, skipped) = try DecodeLoss.measure { try JSONDecoder().decode(type, from: data) }
            guard skipped > 0 else { return StoreRead(value: value, fingerprint: fingerprint) }
            // Whatever was skipped disappears from the file on the next save: keep the original beside it.
            let lost = skipped == 1 ? "1 item não pôde ser lido" : "\(skipped) itens não puderam ser lidos"
            guard let copy = keepAside(url, moving: false) else {
                // As for a file that does not decode at all: without the copy, the next save would lose them for good.
                Self.gate.block(url)
                return StoreRead(value: value, notice: StoreNotice(
                    message: "Ao ler “\(name)”, \(lost) e \(skipped == 1 ? "ficou" : "ficaram") de fora, e não foi possível guardar uma cópia do arquivo. "
                        + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo.", file: url),
                    fingerprint: fingerprint)
            }
            return StoreRead(value: value, notice: StoreNotice(
                message: "Ao ler “\(name)”, \(lost) (talvez de uma versão mais nova do Orb) "
                    + "e \(skipped == 1 ? "ficou" : "ficaram") de fora. O arquivo original foi guardado como “\(copy.lastPathComponent)”.",
                copy: copy, file: url),
                fingerprint: fingerprint)
        } catch {
            guard let copy = keepAside(url, moving: true) else {
                Self.gate.block(url)
                return StoreRead(notice: StoreNotice(message: "Não foi possível ler “\(name)” nem guardar uma cópia do arquivo. "
                    + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo.", file: url))
            }
            return StoreRead(notice: StoreNotice(
                message: "Não foi possível ler “\(name)”. O arquivo foi guardado, sem mudanças, como “\(copy.lastPathComponent)” "
                    + "na mesma pasta (\(copy.deletingLastPathComponent().path)), e \(outcome).", copy: copy, file: url))
        }
    }

    /// Moves (or copies) `url` to `<name>.corrupt-<yyyyMMdd-HHmmss>`; a name already taken never blocks it.
    /// A copy never duplicates one already kept with the same content (the same file read twice, or again on a
    /// later launch because it still couldn't be rewritten).
    private func keepAside(_ url: URL, moving: Bool) -> URL? {
        if !moving, let existing = identicalCopy(of: url) { return existing }
        let formatter = DateFormatter.make(locale: "en_US_POSIX", format: "yyyyMMdd-HHmmss")
        let base = "\(url.lastPathComponent).corrupt-\(formatter.string(from: .now))"
        let manager = FileManager.default
        for attempt in 0..<100 {
            let target = url.deletingLastPathComponent().appendingPathComponent(attempt == 0 ? base : "\(base)-\(attempt)")
            guard !manager.fileExists(atPath: target.path) else { continue }
            do {
                if moving { try manager.moveItem(at: url, to: target) } else { try manager.copyItem(at: url, to: target) }
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    private func identicalCopy(of url: URL) -> URL? {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).corrupt-"
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path),
              let original = try? Data(contentsOf: url) else { return nil }
        for name in names.sorted() where name.hasPrefix(prefix) {
            let candidate = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: candidate)) == original { return candidate }
        }
        return nil
    }

    func write<T: Encodable>(_ value: T, to url: URL) {
        writeFile(to: url) { try JSONEncoder().encode(value) }
    }

    /// A conversation file: pruned and encoded as `ConversationEncoder` does. With `cached`, what the last save of
    /// this file encoded is reused, and a save that would leave the file exactly as it is writes nothing.
    @discardableResult
    private func writeConversation(_ conversation: Conversation, to url: URL, cached: Bool) -> WriteResult {
        guard cached else {
            return writeFile(to: url) { try JSONEncoder().encode(conversation.pruningOldToolOutputs()) }
        }
        let encoder = encoders.encoder(for: url)
        var output: ConversationEncoder.Output?
        let result = writeFile(to: url) {
            output = try encoder.encode(conversation)
            guard let output else { return try JSONEncoder().encode(conversation.pruningOldToolOutputs()) }
            // Nothing changed and the file is as we left it: nothing to write.
            if output.isUnchanged, encoder.fileIsAsWeLeftIt(url) { return nil }
            return encoder.data(for: output)
        }
        switch result {
        case .wrote:
            if let output { encoder.commit(output, fingerprint: FileFingerprint(of: url)) } else { encoder.invalidateCommit() }
        case .skipped:
            break
        case .failed:
            encoder.invalidateCommit() // the next save must write, whatever it finds unchanged
        }
        encoders.trim(keeping: url)
        return result
    }

    private enum WriteResult { case wrote, skipped, failed }

    /// Writes what `content` produces atomically (`nil`: nothing to write). Refuses a file that could not be read
    /// when the app opened, and reports a failure instead of throwing.
    @discardableResult
    private func writeFile(to url: URL, _ content: () throws -> Data?) -> WriteResult {
        let name = url.lastPathComponent
        guard !WriteSeals.isSealed(directory) else { return .skipped }
        guard !Self.gate.isBlocked(url) else {
            onSaveFailure?(StoreNotice(message: "Ao abrir o app, não foi possível ler “\(name)”, e por isso nada é gravado por cima: "
                + "o que você mudou desde então não está sendo salvo. Feche e abra o Orb de novo.", file: url))
            return .failed
        }
        Self.gate.waitForReaders(of: url)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try content() else { return .skipped }
            try data.write(to: url, options: .atomic)
            return .wrote
        } catch {
            NSLog("Orb: não foi possível salvar \(name): \(error)")
            // The note beside a conversation and a connector's catalog are made again (from it, from the next start of
            // the server): not worth alarming anyone.
            if !name.hasSuffix(".meta.json"), url.deletingLastPathComponent().lastPathComponent != "conectores" {
                onSaveFailure?(StoreNotice(message: "Não foi possível salvar “\(name)”: \(error.localizedDescription). "
                    + "As últimas mudanças podem não estar no disco.", file: url))
            }
            return .failed
        }
    }
}

/// The data folders that must not be written to any more (see `Store.sealWrites`).
enum WriteSeals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sealed: Set<String> = []

    static func seal(_ directory: URL) { lock.withLock { _ = sealed.insert(FileKey.of(directory)) } }
    static func isSealed(_ directory: URL) -> Bool { lock.withLock { sealed.contains(FileKey.of(directory)) } }
}

/// The serial writer queue of each data folder.
enum WriterQueues {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func queue(for directory: URL) -> DispatchQueue {
        lock.withLock {
            let key = FileKey.of(directory)
            if let existing = queues[key] { return existing }
            let made = DispatchQueue(label: "app.orb.store", qos: .utility)
            queues[key] = made
            return made
        }
    }
}

/// The conversation encoders kept between saves: the few files being written lately, within a budget of bytes.
final class EncoderCache: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caches: [String: EncoderCache] = [:]

    static func shared(for directory: URL) -> EncoderCache {
        lock.withLock {
            let key = FileKey.of(directory)
            if let existing = caches[key] { return existing }
            let made = EncoderCache()
            caches[key] = made
            return made
        }
    }

    private var encoders: [String: ConversationEncoder] = [:]
    /// Most recently used last.
    private var order: [String] = []
    static let maxFiles = 4
    static let maxBytes = 48 << 20

    private static func key(_ url: URL) -> String { FileKey.of(url) }

    func encoder(for url: URL) -> ConversationEncoder {
        let key = Self.key(url)
        order.removeAll { $0 == key }
        order.append(key)
        if let existing = encoders[key] { return existing }
        let made = ConversationEncoder()
        encoders[key] = made
        return made
    }

    func remove(_ url: URL) {
        let key = Self.key(url)
        encoders[key] = nil
        order.removeAll { $0 == key }
    }

    /// Drops the encoders used longest ago while there are too many or they hold too much (never the one in use).
    func trim(keeping url: URL) {
        let keep = Self.key(url)
        while order.count > 1, order.count > Self.maxFiles || encoders.values.reduce(0, { $0 + $1.byteCount }) > Self.maxBytes {
            guard let oldest = order.first(where: { $0 != keep }) else { return }
            encoders[oldest] = nil
            order.removeAll { $0 == oldest }
        }
    }
}

/// The Keychain operations `Keychain` needs, so the fallback to OpenBot's items runs in tests on a dictionary.
protocol KeychainItems {
    func read(_ account: String, service: String) -> String?
    /// Replaces the item with `value` (an empty value only deletes it) and says whether it is stored.
    func replace(_ value: String, account: String, service: String) -> Bool
}

/// The login Keychain itself.
struct SystemKeychainItems: KeychainItems {
    func read(_ account: String, service: String) -> String? {
        var query = Self.baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func replace(_ value: String, account: String, service: String) -> Bool {
        let query = Self.baseQuery(account, service: service)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return true
        }
        let data = Data(value.utf8)
        return Self.store(
            update: { SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) },
            add: {
                var item = query
                item[kSecValueData as String] = data
                return SecItemAdd(item as CFDictionary, nil)
            })
    }

    /// Updates the item in place and only adds it when there is none, so a failed write never costs the key that was there
    /// (deleting first would lose, say, the ChatGPT refresh token and force a new login). The statuses come from closures so
    /// the order of the steps runs in tests without touching the real Keychain.
    static func store(update: () -> OSStatus, add: () -> OSStatus) -> Bool {
        switch update() {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            let added = add()
            // Another writer created it between the two calls: the value goes in as an update.
            if added == errSecDuplicateItem { return update() == errSecSuccess }
            return added == errSecSuccess
        default:
            return false
        }
    }

    private static func baseQuery(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// The accounts whose OpenBot item has been dealt with: copied over, or removed or replaced in Orb on purpose. The
/// OpenBot item stays in the Keychain as a backup, so without this a key the user removed would come back from it.
/// Kept in the preferences (not in the Keychain, where reading it could ask for a password).
struct LegacyKeychainLedger {
    static let key = "keychainAccountsFromOpenBot"
    private static let lock = NSLock()
    let preferences: any PreferenceStore

    /// For the bundled app on a normal launch; nil elsewhere (tests, developer modes), where OpenBot's items are not looked at.
    static var current: LegacyKeychainLedger? {
        LegacyMigration.shouldRun ? LegacyKeychainLedger(preferences: UserDefaults.standard) : nil
    }

    func handled(_ account: String) -> Bool {
        (preferences.object(forKey: Self.key) as? [String])?.contains(account) ?? false
    }

    func record(_ account: String) {
        Self.lock.withLock {
            var accounts = preferences.object(forKey: Self.key) as? [String] ?? []
            guard !accounts.contains(account) else { return }
            accounts.append(account)
            preferences.set(accounts, forKey: Self.key)
        }
    }
}

/// Secrets in the login Keychain (API keys per provider, sign-in tokens), one item per account name.
enum Keychain {
    static let service = LegacyMigration.identifier
    /// Where OpenBot kept its items; each one is copied here the first time it is read, once per account.
    static let legacyService = LegacyMigration.oldIdentifier

    /// The item, or, for the app's own service, OpenBot's item of the same name (copied over on the way, so
    /// macOS asks at most once per key and only when it's needed).
    static func get(_ account: String, service: String = Keychain.service) -> String? {
        guard DevRun.allowsKeychain(arguments: CommandLine.arguments) else { return nil }
        return lookup(account, service: service, items: SystemKeychainItems(), ledger: .current)
    }

    /// OpenBot's item is consulted for an account only until Orb has dealt with it: once it was copied, or once
    /// the user removed or replaced the key in Orb (`write`), the item OpenBot left as a backup stays untouched and
    /// is not looked at again.
    static func lookup(_ account: String, service: String, items: any KeychainItems, ledger: LegacyKeychainLedger?) -> String? {
        if let value = items.read(account, service: service) { return value }
        guard service == Keychain.service, let ledger, !ledger.handled(account),
              let legacy = items.read(account, service: legacyService) else { return nil }
        if items.replace(legacy, account: account, service: service) { ledger.record(account) }
        return legacy
    }

    /// Stores `value`; an empty value deletes the item.
    static func set(_ value: String, account: String, service: String = Keychain.service) {
        _ = store(value, account: account, service: service)
    }

    /// Like `set`, and says whether the item is stored: a caller that is about to remove the only other copy of a
    /// secret (the data file) must know the Keychain has it.
    static func store(_ value: String, account: String, service: String = Keychain.service) -> Bool {
        guard DevRun.allowsKeychain(arguments: CommandLine.arguments) else { return false }
        return write(value, account: account, service: service, items: SystemKeychainItems(), ledger: .current)
    }

    /// A write to the app's own service settles the account: OpenBot's item no longer stands in for it.
    static func write(_ value: String, account: String, service: String, items: any KeychainItems,
                      ledger: LegacyKeychainLedger?) -> Bool {
        let stored = items.replace(value, account: account, service: service)
        if service == Keychain.service { ledger?.record(account) }
        return stored
    }
}

extension Skill {
    static let starters: [Skill] = [
        Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto, arquivo ou página em tópicos",
              instructions: "Resuma o material que o usuário indicar (texto, caminho de arquivo ou URL; leia com suas ferramentas antes). Responda com uma conclusão de uma linha seguida de no máximo 7 tópicos curtos. Mantenha nomes, números e datas exatos.", source: builtInSource),
        Skill(slug: "organizar", name: "Organizar pasta", summary: "Propõe e aplica uma organização para uma pasta",
              instructions: "Organize a pasta que o usuário indicar (padrão ~/Downloads). Primeiro liste o conteúdo e proponha uma estrutura (por tipo e mês) com as contagens, sem mover nada. Só depois que o usuário concordar, mova os arquivos com run_command usando `mv -n`, para nada ser sobrescrito, e conte o que foi movido.", source: builtInSource),
        Skill(slug: "revisar", name: "Revisar texto", summary: "Corrige e melhora um texto mantendo a voz do autor",
              instructions: "Revise o texto do usuário: corrija gramática, ortografia e clareza, mantendo a voz e o idioma dele. Devolva primeiro o texto revisado, depois uma lista curta das mudanças mais importantes.", source: builtInSource),
    ]
}

// MARK: - Tolerant decoding

// Fields added in later versions must not make older files unreadable: missing keys fall back to defaults.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// Counts the elements `lossyArray` dropped during a decode, so the Store can keep a copy of a file that lost
/// something. Decoding is synchronous, so the count lives in the thread's own dictionary.
enum DecodeLoss {
    private static let key = "app.orb.decodeLoss"

    static func measure<T>(_ body: () throws -> T) rethrows -> (value: T, skipped: Int) {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[key]
        dictionary[key] = 0
        defer { dictionary[key] = outer }
        let value = try body()
        return (value, dictionary[key] as? Int ?? 0)
    }

    static func record() {
        let dictionary = Thread.current.threadDictionary
        if let count = dictionary[key] as? Int { dictionary[key] = count + 1 }
    }
}

/// One element of a list that may fail to decode without taking the list down.
private struct Lossy<Element: Decodable>: Decodable {
    let element: Element?

    init(from decoder: Decoder) throws {
        element = try? Element(from: decoder)
        if element == nil { DecodeLoss.record() }
    }
}

extension KeyedDecodingContainer {
    /// A list where an element that can't be read (a case from a newer version, a missing field) is skipped
    /// instead of failing the whole file.
    func lossyArray<T: Decodable>(_ key: Key, default fallback: [T] = []) throws -> [T] {
        try decodeIfPresent([Lossy<T>].self, forKey: key)?.compactMap(\.element) ?? fallback
    }

    /// The same list with nil where an element can't be read, so indexes into the stored list can be moved past it.
    func lossyOptionals<T: Decodable>(_ key: Key) throws -> [T?] {
        try decodeIfPresent([Lossy<T>].self, forKey: key)?.map(\.element) ?? []
    }
}

extension Decoder {
    /// A string-backed enum that maps unknown values to `fallback` instead of failing.
    func rawValue<E: RawRepresentable>(_ type: E.Type, fallback: E) throws -> E where E.RawValue == String {
        if let known = E(rawValue: try singleValueContainer().decode(String.self)) { return known }
        DecodeLoss.record() // the fallback replaces the original on the next save: keep a copy of the file
        return fallback
    }
}

extension AppState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bots = try c.lossyArray(.bots)
        routines = try c.lossyArray(.routines)
        skills = try c.lossyArray(.skills, default: Skill.starters)
        connectors = try c.lossyArray(.connectors)
        providers = try c.lossyArray(.providers)
        defaultModel = try c.value(.defaultModel, default: "")
        // A bad count never loses the file, nor the good counts beside it.
        struct Count: Decodable {
            var value: Int?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Int.self) }
        }
        unread = ((try? c.decodeIfPresent([String: Count].self, forKey: .unread)) ?? nil)?.compactMapValues(\.value) ?? [:]
        // Before the count lived apart from the Orbs it was saved inside each one.
        struct Counted: Decodable {
            var id: UUID
            var unread: Int
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
            }
            enum CodingKeys: CodingKey { case id, unread }
        }
        // The same Orbs again: the ones it can't read were already counted as lost by `bots` above.
        let counted = try DecodeLoss.measure { try c.lossyArray(.bots) as [Counted] }.value
        for orb in counted where orb.unread > 0 && unread[orb.id.uuidString] == nil {
            unread[orb.id.uuidString] = orb.unread
        }
        // A preview is only a convenience: one that can't be read is dropped, never the file.
        replies = ((try? c.decodeIfPresent([String: ReplyPreview].self, forKey: .replies)) ?? nil) ?? [:]
        contextMemory = try c.value(.contextMemory, default: .balanced)
        learnedContexts = (try? c.decodeIfPresent([String: LearnedContext].self, forKey: .learnedContexts)) ?? [:]
        do { profile = try c.value(.profile, default: UserProfile()) } catch { DecodeLoss.record() }
        // One damaged correction is dropped alone; the others stay.
        struct Price: Decodable {
            var value: ModelPrice?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(ModelPrice.self) }
        }
        priceCorrections = ((try? c.decodeIfPresent([String: Price].self, forKey: .priceCorrections)) ?? nil)?.compactMapValues(\.value) ?? [:]
        groups = try c.lossyArray(.groups)
        categories = try c.lossyArray(.categories)
        // An Orb's list that can't be read is dropped alone (its conversations' files stay); the others stay.
        struct Chats: Decodable {
            var value: OrbChats?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(OrbChats.self) }
        }
        chats = ((try? c.decodeIfPresent([String: Chats].self, forKey: .chats)) ?? nil)?.compactMapValues(\.value) ?? [:]
        try migrateSingleProvider(from: decoder)
    }

    /// Before multi-provider support the app had one OpenAI-compatible `provider`, a `models` list and
    /// bare model ids on bots. Turn that into an account and "provider/model" references.
    private mutating func migrateSingleProvider(from decoder: Decoder) throws {
        struct Legacy: Decodable { var preset: String; var baseURL: String; var defaultModel: String }
        enum Keys: CodingKey { case provider, models }
        let c = try decoder.container(keyedBy: Keys.self)
        guard providers.isEmpty, let legacy = try? c.decodeIfPresent(Legacy.self, forKey: .provider),
              let kind = ProviderKind(rawValue: legacy.preset) else { return }
        var account = ProviderAccount(kind: kind)
        account.baseURL = legacy.baseURL
        account.models = (try? c.decodeIfPresent([String].self, forKey: .models))?.map {
            ProviderModel(id: $0, name: $0, format: .chat)
        } ?? []
        providers = [account]
        if !legacy.defaultModel.isEmpty { defaultModel = ModelRef(provider: kind, model: legacy.defaultModel).text }
        for index in bots.indices where !bots[index].model.isEmpty && ModelRef(bots[index].model) == nil {
            bots[index].model = ModelRef(provider: kind, model: bots[index].model).text
        }
    }
}
