import Foundation
import Security

/// Everything the app keeps between launches, except conversations (one file per bot) and API keys (Keychain).
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

/// JSON files in ~/Library/Application Support/Orb (override with `ORB_DATA_DIR`).
/// Encoding and disk I/O run in order on one background queue, off the main thread.
struct Store: Sendable {
    let directory: URL

    private static let queue = DispatchQueue(label: "app.orb.store", qos: .utility)

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

    func loadState() -> AppState? { Self.queue.sync { read(AppState.self, from: stateURL) } }
    func save(_ state: AppState) { Self.queue.async { write(state, to: stateURL) } }

    func loadConversation(_ botID: UUID) -> Conversation? { Self.queue.sync { read(Conversation.self, from: conversationURL(botID)) } }
    func save(_ conversation: Conversation, for botID: UUID) { Self.queue.async { write(conversation, to: conversationURL(botID)) } }
    func deleteConversation(_ botID: UUID) {
        let url = conversationURL(botID)
        Self.queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for pending writes.
    func flush() { Self.queue.sync {} }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Orb: não foi possível salvar \(url.lastPathComponent): \(error)")
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

extension AppState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bots = try c.value(.bots, default: [])
        routines = try c.value(.routines, default: [])
        skills = try c.value(.skills, default: Skill.starters)
        connectors = try c.value(.connectors, default: [])
        providers = try c.value(.providers, default: [])
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
