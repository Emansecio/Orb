import Foundation
import Security
import Darwin.malloc

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
    /// How much conversation the Orbs remember word for word before folding the start into a summary.
    var contextMemory = ContextMemoryLevel.balanced
    /// Context windows models turned out to have (a request was refused for its size), by "provider/model".
    var learnedContexts: [String: LearnedContext] = [:]
    /// Who the user is, for every Orb (Ajustes → Geral → Você).
    var profile = UserProfile()

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
/// disagrees) and `routine-<routineID>.json` for the conversation of each routine.
///
/// A file that can't be read is never overwritten: it is set aside as `<name>.corrupt-<yyyyMMdd-HHmmss>` (or,
/// if that fails, left alone and blocked from writes for the rest of the session).
struct Store: Sendable {
    let directory: URL
    /// Called (on the store's queue) when a write fails; the app turns it into a message for the user.
    var onSaveFailure: (@Sendable (StoreNotice) -> Void)?

    init(directory: URL, onSaveFailure: (@Sendable (StoreNotice) -> Void)? = nil) {
        self.directory = directory
        self.onSaveFailure = onSaveFailure
    }

    /// Every write, in order. One queue per data folder (the app has one; tests have one each, so a test that holds
    /// the writer cannot stall the others).
    private var queue: DispatchQueue { WriterQueues.queue(for: directory) }
    /// Reads of conversations and the state: concurrent, and at the priority of something the user is waiting for.
    private static let readQueue = DispatchQueue(label: "app.orb.store.read", qos: .userInitiated, attributes: .concurrent)
    private static let gate = FileGate()
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

    private func conversationURL(_ botID: UUID) -> URL {
        directory.appendingPathComponent("conversations/\(botID.uuidString).json")
    }

    private func metaURL(_ botID: UUID) -> URL {
        directory.appendingPathComponent("conversations/\(botID.uuidString).meta.json")
    }

    // MARK: Reading

    func readState() -> StoreRead<AppState> {
        Self.gate.reading(stateURL) { read(AppState.self, from: stateURL, ifUnreadable: "o Orb começou do zero") }
    }

    /// Reads (and decodes) on the calling thread. The main thread uses this only when it cannot wait for
    /// `readConversationAsync`.
    func readConversation(_ botID: UUID) -> StoreRead<Conversation> {
        loadConversation(botID)
    }

    /// Like `readConversation`, on a thread of the store's own: the caller is not blocked, and nothing is waited for
    /// but the writes still queued for this very file.
    func readConversationAsync(_ botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: loadConversation(botID)) }
        }
    }

    private func loadConversation(_ botID: UUID) -> StoreRead<Conversation> {
        let url = conversationURL(botID)
        let result = Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: "a conversa começou vazia")
        }
        // The decode of a long conversation leaves megabytes of freed memory the process would keep: give it back.
        if let size = result.fingerprint?.size, size > 1 << 20 { malloc_zone_pressure_relief(nil, 0) }
        // A conversation read without a valid note about it gets one, so the next launch can tell what is unsaved
        // in it without reading it again.
        if let conversation = result.value, let fingerprint = result.fingerprint, result.notice == nil,
           readMeta(botID)?.file != fingerprint {
            recordMeta(ConversationMeta(of: conversation, file: fingerprint), for: botID, ifFileStill: fingerprint)
        }
        return result
    }

    /// What is known about the conversation without reading it: nil when no valid note exists, `.empty` when there is
    /// no conversation file.
    func readMeta(_ botID: UUID) -> ConversationMeta? {
        let url = conversationURL(botID)
        return Self.gate.reading([url, metaURL(botID)]) {
            guard let current = FileFingerprint(of: url) else { return ConversationMeta.empty }
            guard let data = try? Data(contentsOf: metaURL(botID)),
                  let meta = try? JSONDecoder().decode(ConversationMeta.self, from: data), meta.file == current else { return nil }
            return meta
        }
    }

    func readMetaAsync(_ botID: UUID) async -> ConversationMeta? {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readMeta(botID)) }
        }
    }

    /// Writes a note about a conversation just read, unless the file changed since (a save in between wrote a
    /// better note).
    private func recordMeta(_ meta: ConversationMeta, for botID: UUID, ifFileStill fingerprint: FileFingerprint) {
        let conversation = conversationURL(botID), note = metaURL(botID)
        enqueue(touching: [note]) {
            guard FileFingerprint(of: conversation) == fingerprint else { return }
            write(meta, to: note)
        }
    }

    // MARK: Writing

    /// Queues `work` on the writer, registering the files it touches first so that reads of them wait. Once the
    /// folder is sealed (`sealWrites`) the work is dropped.
    private func enqueue(touching urls: [URL], _ work: @escaping @Sendable () -> Void) {
        Self.gate.willWrite(urls)
        let directory = directory
        queue.async {
            if !WriteSeals.isSealed(directory) { work() }
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
    func save(_ conversation: Conversation, for botID: UUID) {
        let url = conversationURL(botID), note = metaURL(botID)
        enqueue(touching: [url, note]) {
            // A save that wrote nothing (nothing changed) leaves the note as it is.
            guard writeConversation(conversation, to: url, cached: true) == .wrote else { return }
            write(ConversationMeta(of: conversation, file: FileFingerprint(of: url)), to: note)
        }
    }

    /// Lets go of what is kept for saving this Orb's conversation faster (it was unloaded).
    func releaseCache(for botID: UUID) {
        let url = conversationURL(botID)
        queue.async { encoders.remove(url) }
    }

    func deleteConversation(_ botID: UUID) {
        let url = conversationURL(botID), note = metaURL(botID)
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

    private func routineConversationURL(_ botID: UUID, _ routineID: UUID) -> URL {
        archiveFolder(botID).appendingPathComponent("routine-\(routineID.uuidString).json")
    }

    private func archiveIndexURL(_ botID: UUID) -> URL { archiveFolder(botID).appendingPathComponent("index.json") }

    /// Puts the conversation in the archive and returns its entry at once; the files follow on the store's queue.
    /// The conversation file goes first: a crash before the index is written leaves a file the next listing finds.
    @discardableResult
    func archive(_ conversation: Conversation, for botID: UUID) -> ConversationSummary {
        let summary = ConversationSummary(of: conversation)
        let file = archivedURL(botID, summary.id)
        enqueue(touching: [file, archiveIndexURL(botID)]) {
            var entries = reconciledArchive(botID).entries
            writeConversation(conversation, to: file, cached: false)
            entries.append(summary)
            write(ConversationIndex(entries: entries), to: archiveIndexURL(botID))
        }
        return summary
    }

    /// The archived conversations of an Orb, newest first. A file that can't be read is left out of the list.
    func readArchive(_ botID: UUID) -> [ConversationSummary] {
        queue.sync { listArchive(botID) }
    }

    func readArchiveAsync(_ botID: UUID) async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: listArchive(botID)) }
        }
    }

    func readArchived(_ id: UUID, for botID: UUID) -> StoreRead<Conversation> {
        let url = archivedURL(botID, id)
        return Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: "ela saiu da lista de conversas")
        }
    }

    /// Like `readArchived`, on a thread of the store's own: reopening a long conversation does not freeze the window.
    func readArchivedAsync(_ id: UUID, for botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readArchived(id, for: botID)) }
        }
    }

    /// Deletes an archived conversation. With `unlessUsedBy` (the file names of the pictures the app holds in memory
    /// for this Orb: its open conversation, unsent attachments, queued messages) the pictures only this conversation
    /// pointed to go with it; one that another conversation of the same Orb (the current one, another archived one,
    /// a routine's) or `unlessUsedBy` still refers to stays. nil leaves the pictures alone (reopening a conversation
    /// moves it, it is not deleted).
    func deleteArchived(_ id: UUID, for botID: UUID, removingPicturesUnlessUsedBy inUse: Set<String>? = nil) {
        let file = archivedURL(botID, id)
        enqueue(touching: [file, archiveIndexURL(botID)]) {
            Self.gate.waitForReaders(of: file)
            let pictures = inUse == nil ? [] : Self.pictureNames(inFileAt: file)
            try? FileManager.default.removeItem(at: file)
            let (entries, changed) = reconciledArchive(botID)
            if changed { write(ConversationIndex(entries: entries), to: archiveIndexURL(botID)) }
            if let inUse { removePictures(pictures, of: botID, unlessUsedBy: inUse) }
        }
    }

    /// The names (`<uuid>.jpg|png`, see `ImageStore`) of the pictures a conversation file points to. It reads the
    /// file's text, not the conversation: it works on a file that no longer decodes, and any mention counts.
    static func pictureNames(inFileAt url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let matches = pictureNamePattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    private static let pictureNamePattern = try! NSRegularExpression(
        pattern: #"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.(?:jpg|png)"#)

    private static func jsonFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
    }

    /// The `<name>.json.corrupt-<date>` copies of files that stopped decoding: they are kept for the user to recover
    /// and may still name a picture, so a picture they name is not deleted. In the Orb's own `conversations/` folder
    /// (`botID` given) only the copies of this Orb's files count.
    private static func setAsideCopies(in folder: URL, of botID: UUID? = nil) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                guard name.contains(".json.corrupt-") else { return false }
                return botID.map { name.hasPrefix($0.uuidString) } ?? true
            }
    }

    /// Deletes the Orb's pictures named in `names`, except those the Orb's current conversation, the rest of its archive
    /// (routines' conversations included) or `inUse` still point to. Runs on the store's queue.
    private func removePictures(_ names: Set<String>, of botID: UUID, unlessUsedBy inUse: Set<String>) {
        var doomed = names.subtracting(inUse)
        guard !doomed.isEmpty else { return }
        let others = ([conversationURL(botID)] + Self.jsonFiles(in: archiveFolder(botID)))
            + Self.setAsideCopies(in: archiveFolder(botID)) + Self.setAsideCopies(in: conversationURL(botID).deletingLastPathComponent(), of: botID)
        for other in others where !doomed.isEmpty {
            Self.gate.waitForReaders(of: other)
            doomed.subtract(Self.pictureNames(inFileAt: other))
        }
        let folder = ImageStore(dataFolder: directory).folder(for: botID)
        for name in doomed { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    /// Everything archived for the Orb, its routines' conversations included (the Orb is being deleted).
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

    func saveRoutineConversation(_ conversation: Conversation, routine routineID: UUID, for botID: UUID) {
        let url = routineConversationURL(botID, routineID)
        enqueue(touching: [url]) { writeConversation(conversation, to: url, cached: true) }
    }

    func readRoutineConversation(routine routineID: UUID, for botID: UUID) -> StoreRead<Conversation> {
        let url = routineConversationURL(botID, routineID)
        return Self.gate.reading(url) {
            read(Conversation.self, from: url, ifUnreadable: "o histórico da rotina começou vazio")
        }
    }

    func readRoutineConversationAsync(routine routineID: UUID, for botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.readQueue.async { continuation.resume(returning: readRoutineConversation(routine: routineID, for: botID)) }
        }
    }

    func deleteRoutineConversation(routine routineID: UUID, for botID: UUID) {
        let url = routineConversationURL(botID, routineID)
        enqueue(touching: [url]) {
            Self.gate.waitForReaders(of: url)
            try? FileManager.default.removeItem(at: url)
            encoders.remove(url)
        }
    }

    private func listArchive(_ botID: UUID) -> [ConversationSummary] {
        let (entries, changed) = reconciledArchive(botID)
        if changed { write(ConversationIndex(entries: entries), to: archiveIndexURL(botID)) }
        return entries.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    /// The index corrected by the folder: entries whose file is gone are dropped, and files the index does not know
    /// (it was lost, or the app quit before writing it) are added. A file that can't be decoded is skipped and left
    /// where it is. `changed` says the index file needs rewriting. Runs on `queue`.
    private func reconciledArchive(_ botID: UUID) -> (entries: [ConversationSummary], changed: Bool) {
        let folder = archiveFolder(botID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return ([], false) }
        let files = Set(names.compactMap { name -> UUID? in
            name.hasSuffix(".json") ? UUID(uuidString: String(name.dropLast(".json".count))) : nil
        })
        let indexed = (try? Data(contentsOf: archiveIndexURL(botID)))
            .flatMap { try? JSONDecoder().decode(ConversationIndex.self, from: $0) }?.entries
        var entries: [ConversationSummary] = []
        var seen: Set<UUID> = []
        for entry in indexed ?? [] where files.contains(entry.id) && seen.insert(entry.id).inserted { entries.append(entry) }
        var changed = indexed == nil ? !files.isEmpty : entries.count != indexed?.count
        for id in files.subtracting(seen).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let data = try? Data(contentsOf: archivedURL(botID, id)),
                  let conversation = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }
            entries.append(ConversationSummary(of: conversation, id: id))
            changed = true
        }
        return (entries, changed)
    }

    /// Waits for pending writes.
    func flush() { queue.sync {} }

    private func read<T: Decodable & Sendable>(_ type: T.Type, from url: URL, ifUnreadable outcome: String) -> StoreRead<T> {
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
            guard let copy = keepAside(url, moving: false) else { return StoreRead(value: value, fingerprint: fingerprint) }
            let lost = skipped == 1 ? "1 item não pôde ser lido" : "\(skipped) itens não puderam ser lidos"
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
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

    private func write<T: Encodable>(_ value: T, to url: URL) {
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

    static func seal(_ directory: URL) { lock.withLock { _ = sealed.insert(directory.standardizedFileURL.path) } }
    static func isSealed(_ directory: URL) -> Bool { lock.withLock { sealed.contains(directory.standardizedFileURL.path) } }
}

/// The serial writer queue of each data folder.
enum WriterQueues {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func queue(for directory: URL) -> DispatchQueue {
        lock.withLock {
            let key = directory.standardizedFileURL.path
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
            let key = directory.standardizedFileURL.path
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

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

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
        SecItemDelete(Self.baseQuery(account, service: service) as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = Self.baseQuery(account, service: service)
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
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
    static let service = "app.orb.mac"
    /// Where OpenBot kept its items; each one is copied here the first time it is read, once per account.
    static let legacyService = "app.openbot.mac"

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
        contextMemory = try c.value(.contextMemory, default: .balanced)
        learnedContexts = (try? c.decodeIfPresent([String: LearnedContext].self, forKey: .learnedContexts)) ?? [:]
        do { profile = try c.value(.profile, default: UserProfile()) } catch { DecodeLoss.record() }
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
