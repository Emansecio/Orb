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

    static let standard: Store = {
        if let custom = ProcessInfo.processInfo.environment["ORB_DATA_DIR"] { return Store(directory: URL(fileURLWithPath: custom)) }
        // Rendering the icon or the Orb sheet (scripts/bundle.sh) only needs sample data: never the user's.
        if CommandLine.arguments.contains(where: { $0 == "--render-icon" || $0 == "--render-orbs" }) {
            return Store(directory: FileManager.default.temporaryDirectory.appending(path: "orb-render-\(UUID().uuidString)"))
        }
        let support = URL.applicationSupportDirectory
        let directory = support.appendingPathComponent("Orb")
        if LegacyMigration.shouldRun {
            LegacyMigration.run(into: directory, from: support.appendingPathComponent(LegacyMigration.oldFolder))
        }
        return Store(directory: directory)
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
        Self.gate.reading(stateURL) { read(AppState.self, from: stateURL, ifUnreadable: "O Orb começou do zero") }
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

    /// Queues `work` on the writer, registering the files it touches first so that reads of them wait.
    private func enqueue(touching urls: [URL], _ work: @escaping @Sendable () -> Void) {
        Self.gate.willWrite(urls)
        queue.async {
            work()
            Self.gate.didWrite(urls)
        }
    }

    func save(_ state: AppState) {
        enqueue(touching: [stateURL]) { write(state, to: stateURL) }
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

    func deleteArchived(_ id: UUID, for botID: UUID) {
        let file = archivedURL(botID, id)
        enqueue(touching: [file, archiveIndexURL(botID)]) {
            Self.gate.waitForReaders(of: file)
            try? FileManager.default.removeItem(at: file)
            let (entries, changed) = reconciledArchive(botID)
            if changed { write(ConversationIndex(entries: entries), to: archiveIndexURL(botID)) }
        }
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
                + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo."))
        }
        do {
            let (value, skipped) = try DecodeLoss.measure { try JSONDecoder().decode(type, from: data) }
            guard skipped > 0 else { return StoreRead(value: value, fingerprint: fingerprint) }
            // Whatever was skipped disappears from the file on the next save: keep the original beside it.
            guard let copy = keepAside(url, moving: false) else { return StoreRead(value: value, fingerprint: fingerprint) }
            return StoreRead(value: value, notice: StoreNotice(
                message: "\(skipped) item(ns) de “\(name)” não puderam ser lidos (talvez de uma versão mais nova do Orb) "
                    + "e ficaram de fora. O arquivo original foi guardado como “\(copy.lastPathComponent)”.", copy: copy),
                fingerprint: fingerprint)
        } catch {
            guard let copy = keepAside(url, moving: true) else {
                Self.gate.block(url)
                return StoreRead(notice: StoreNotice(message: "Não foi possível ler “\(name)” nem guardar uma cópia dele. "
                    + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo."))
            }
            return StoreRead(notice: StoreNotice(
                message: "Não foi possível ler “\(name)”. Ele foi guardado, sem mudanças, como “\(copy.lastPathComponent)” "
                    + "na mesma pasta (\(copy.deletingLastPathComponent().path)), e \(outcome).", copy: copy))
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
        guard !Self.gate.isBlocked(url) else {
            onSaveFailure?(StoreNotice(message: "“\(name)” não pôde ser lido ao abrir o app e não foi sobrescrito: "
                + "o que você mudou desde então não está sendo salvo. Feche e abra o Orb de novo."))
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
            onSaveFailure?(StoreNotice(message: "Não foi possível salvar “\(name)”: \(error.localizedDescription). "
                + "As últimas mudanças podem não estar no disco."))
            return .failed
        }
    }
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

/// Secrets in the login Keychain (API keys per provider, sign-in tokens), one item per account name.
enum Keychain {
    static let service = "app.orb.mac"
    /// Where OpenBot kept its items; each one moves here the first time it is read.
    static let legacyService = "app.openbot.mac"

    /// The item, or, for the app's own service, OpenBot's item of the same name (copied over on the way, so
    /// macOS asks at most once per key and only when it's needed).
    static func get(_ account: String, service: String = Keychain.service) -> String? {
        if let value = read(account, service: service) { return value }
        guard service == Keychain.service, LegacyMigration.shouldRun,
              let legacy = read(account, service: legacyService) else { return nil }
        set(legacy, account: account)
        return legacy
    }

    private static func read(_ account: String, service: String) -> String? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`; an empty value deletes the item.
    static func set(_ value: String, account: String, service: String = Keychain.service) {
        SecItemDelete(baseQuery(account, service: service) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = baseQuery(account, service: service)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }


    private static func baseQuery(_ account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

extension Skill {
    static let starters: [Skill] = [
        Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto, arquivo ou página em tópicos",
              instructions: "Summarize the material the user points to (text, file path or URL — read it with your tools first). Answer with a one-line takeaway followed by at most 7 short bullet points. Keep names, numbers and dates exact.", source: builtInSource),
        Skill(slug: "organizar", name: "Organizar pasta", summary: "Propõe e aplica uma organização para uma pasta",
              instructions: "Organize the folder the user names (default ~/Downloads). First list it and propose a structure (by type and month) with counts, without moving anything. Only after the user agrees, move files with run_command using `mv -n` so nothing is overwritten, then report what moved.", source: builtInSource),
        Skill(slug: "revisar", name: "Revisar texto", summary: "Corrige e melhora um texto mantendo a voz do autor",
              instructions: "Proofread the user's text: fix grammar, spelling and clarity while keeping their voice and language. Return the revised text first, then a short list of the most important changes.", source: builtInSource),
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

    fileprivate static func record() {
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
        for orb in try c.lossyArray(.bots) as [Counted] where orb.unread > 0 && unread[orb.id.uuidString] == nil {
            unread[orb.id.uuidString] = orb.unread
        }
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
