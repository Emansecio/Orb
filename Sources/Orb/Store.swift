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
}

/// JSON files in ~/Library/Application Support/Orb (override with `ORB_DATA_DIR`).
/// Encoding and disk I/O run in order on one background queue, off the main thread.
///
/// Conversations: an Orb's current one is `conversations/<botID>.json`. Its earlier ones are archived in the folder
/// beside it, `conversations/<botID>/`: `<conversationID>.json` each, `index.json` listing them (a cache that is
/// corrected from the files whenever it disagrees) and `routine-<routineID>.json` for the conversation of each routine.
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

    private static let queue = DispatchQueue(label: "app.orb.store", qos: .utility)
    /// Files that couldn't be read nor set aside: writes to them are refused. Touched only on `queue`.
    nonisolated(unsafe) private static var blocked: Set<URL> = []

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

    func readState() -> StoreRead<AppState> {
        Self.queue.sync { read(AppState.self, from: stateURL, ifUnreadable: "O Orb começou do zero") }
    }

    func readConversation(_ botID: UUID) -> StoreRead<Conversation> {
        Self.queue.sync { read(Conversation.self, from: conversationURL(botID), ifUnreadable: "a conversa começou vazia") }
    }

    /// Like `readConversation`, without blocking the caller's thread while the store works through earlier writes.
    func readConversationAsync(_ botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: read(Conversation.self, from: conversationURL(botID),
                                                     ifUnreadable: "a conversa começou vazia"))
            }
        }
    }

    func save(_ state: AppState) { Self.queue.async { write(state, to: stateURL) } }

    /// Old tool outputs are stored shortened (`Conversation.pruningOldToolOutputs`); the caller's copy is untouched.
    func save(_ conversation: Conversation, for botID: UUID) {
        Self.queue.async { write(conversation.pruningOldToolOutputs(), to: conversationURL(botID)) }
    }

    func deleteConversation(_ botID: UUID) {
        let url = conversationURL(botID)
        Self.queue.async { try? FileManager.default.removeItem(at: url) }
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
        Self.queue.async {
            var entries = reconciledArchive(botID).entries
            write(conversation.pruningOldToolOutputs(), to: archivedURL(botID, summary.id))
            entries.append(summary)
            write(ConversationIndex(entries: entries), to: archiveIndexURL(botID))
        }
        return summary
    }

    /// The archived conversations of an Orb, newest first. A file that can't be read is left out of the list.
    func readArchive(_ botID: UUID) -> [ConversationSummary] {
        Self.queue.sync { listArchive(botID) }
    }

    func readArchiveAsync(_ botID: UUID) async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: listArchive(botID)) }
        }
    }

    func readArchived(_ id: UUID, for botID: UUID) -> StoreRead<Conversation> {
        Self.queue.sync {
            read(Conversation.self, from: archivedURL(botID, id), ifUnreadable: "ela saiu da lista de conversas")
        }
    }

    func deleteArchived(_ id: UUID, for botID: UUID) {
        Self.queue.async {
            try? FileManager.default.removeItem(at: archivedURL(botID, id))
            let (entries, changed) = reconciledArchive(botID)
            if changed { write(ConversationIndex(entries: entries), to: archiveIndexURL(botID)) }
        }
    }

    /// Everything archived for the Orb, its routines' conversations included (the Orb is being deleted).
    func deleteArchive(_ botID: UUID) {
        let folder = archiveFolder(botID)
        Self.queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    func saveRoutineConversation(_ conversation: Conversation, routine routineID: UUID, for botID: UUID) {
        Self.queue.async { write(conversation.pruningOldToolOutputs(), to: routineConversationURL(botID, routineID)) }
    }

    func readRoutineConversation(routine routineID: UUID, for botID: UUID) -> StoreRead<Conversation> {
        Self.queue.sync {
            read(Conversation.self, from: routineConversationURL(botID, routineID),
                 ifUnreadable: "o histórico da rotina começou vazio")
        }
    }

    func readRoutineConversationAsync(routine routineID: UUID, for botID: UUID) async -> StoreRead<Conversation> {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: read(Conversation.self, from: routineConversationURL(botID, routineID),
                                                     ifUnreadable: "o histórico da rotina começou vazio"))
            }
        }
    }

    func deleteRoutineConversation(routine routineID: UUID, for botID: UUID) {
        let url = routineConversationURL(botID, routineID)
        Self.queue.async { try? FileManager.default.removeItem(at: url) }
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
    func flush() { Self.queue.sync {} }

    private func read<T: Decodable & Sendable>(_ type: T.Type, from url: URL, ifUnreadable outcome: String) -> StoreRead<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreRead() }
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // It exists but can't be read right now: treating that as "empty" would overwrite it on the next save.
            Self.blocked.insert(url.standardizedFileURL)
            return StoreRead(notice: StoreNotice(message: "Não foi possível ler “\(name)” (\(error.localizedDescription)). "
                + "Para não perder nada, o Orb não vai gravar nesse arquivo até você abrir o app de novo."))
        }
        do {
            let (value, skipped) = try DecodeLoss.measure { try JSONDecoder().decode(type, from: data) }
            guard skipped > 0 else { return StoreRead(value: value) }
            // Whatever was skipped disappears from the file on the next save: keep the original beside it.
            guard let copy = keepAside(url, moving: false) else { return StoreRead(value: value) }
            return StoreRead(value: value, notice: StoreNotice(
                message: "\(skipped) item(ns) de “\(name)” não puderam ser lidos (talvez de uma versão mais nova do Orb) "
                    + "e ficaram de fora. O arquivo original foi guardado como “\(copy.lastPathComponent)”.", copy: copy))
        } catch {
            guard let copy = keepAside(url, moving: true) else {
                Self.blocked.insert(url.standardizedFileURL)
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
        let name = url.lastPathComponent
        guard !Self.blocked.contains(url.standardizedFileURL) else {
            onSaveFailure?(StoreNotice(message: "“\(name)” não pôde ser lido ao abrir o app e não foi sobrescrito: "
                + "o que você mudou desde então não está sendo salvo. Feche e abra o Orb de novo."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Orb: não foi possível salvar \(name): \(error)")
            onSaveFailure?(StoreNotice(message: "Não foi possível salvar “\(name)”: \(error.localizedDescription). "
                + "As últimas mudanças podem não estar no disco."))
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

extension Conversation {
    /// What is written to disk: tool outputs older than the second-to-last user message keep only a head and a
    /// tail (the model sees no more than that of old outputs anyway). `self` is not changed.
    func pruningOldToolOutputs(limit: Int = 4_000) -> Conversation {
        var copy = self
        let itemCutoff = Self.secondToLastUser(items.map { if case .user = $0.kind { true } else { false } })
        for index in copy.items.indices where index < itemCutoff {
            guard case .tool(var call) = copy.items[index].kind, let output = call.output else { continue }
            let short = Self.preview(output, limit: limit)
            guard short != output else { continue }
            call.output = short
            copy.items[index].kind = .tool(call)
        }
        let messageCutoff = Self.secondToLastUser(messages.map { $0.role == .user })
        for index in copy.messages.indices where index < messageCutoff && copy.messages[index].role == .tool {
            copy.messages[index].content = Self.preview(copy.messages[index].content, limit: limit)
        }
        return copy
    }

    /// Index of the second-to-last `true` (0 when there are fewer than two: nothing is old yet).
    private static func secondToLastUser(_ isUser: [Bool]) -> Int {
        isUser.indices.reversed().lazy.filter { isUser[$0] }.dropFirst().first ?? 0
    }

    /// `text` as is when it fits in `limit`, otherwise its head and tail around a marker (about `limit` in all).
    static func preview(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit, text.count > limit else { return text }
        let keep = max(0, (limit - 100) / 2)
        let omitted = text.count - 2 * keep
        return String(text.prefix(keep)) + "\n[… \(omitted) caracteres omitidos de uma saída antiga …]\n" + String(text.suffix(keep))
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
