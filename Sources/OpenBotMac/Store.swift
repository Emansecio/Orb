import Foundation
import Security

/// Everything the app keeps between launches, except conversations (one file per bot) and API keys (Keychain).
struct AppState: Codable, Sendable {
    var bots: [Bot]
    var routines: [Routine] = []
    var skills: [Skill] = Skill.starters
    var connectors: [MCPServerConfig] = []
    var provider = ProviderConfig()
    /// Last model list fetched from the provider.
    var models: [String] = []

    static let initial = AppState(bots: [
        Bot(name: "Atlas", role: "Assistente do seu Mac",
            orb: OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso", accessories: ["oculos-redondos"]))
    ])
}

/// JSON files in ~/Library/Application Support/OpenBot (override with `OPENBOT_DATA_DIR`).
/// Encoding and disk I/O run in order on one background queue, off the main thread.
struct Store: Sendable {
    let directory: URL

    private static let queue = DispatchQueue(label: "app.openbot.store", qos: .utility)

    static let standard = Store(directory: ProcessInfo.processInfo.environment["OPENBOT_DATA_DIR"]
        .map { URL(fileURLWithPath: $0) }
        ?? URL.applicationSupportDirectory.appendingPathComponent("OpenBot"))

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
            NSLog("OpenBot: não foi possível salvar \(url.lastPathComponent): \(error)")
        }
    }
}

/// API keys in the login Keychain, one item per provider.
enum Keychain {
    private static let service = "app.openbot.mac"

    static func key(for preset: ProviderPreset) -> String? {
        var query = baseQuery(preset)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setKey(_ key: String, for preset: ProviderPreset) {
        SecItemDelete(baseQuery(preset) as CFDictionary)
        guard !key.isEmpty else { return }
        var item = baseQuery(preset)
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func baseQuery(_ preset: ProviderPreset) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: preset.rawValue]
    }
}

extension Skill {
    static let starters: [Skill] = [
        Skill(slug: "resumir", name: "Resumir", summary: "Resume um texto, arquivo ou página em tópicos",
              instructions: "Summarize the material the user points to (text, file path or URL — read it with your tools first). Answer with a one-line takeaway followed by at most 7 short bullet points. Keep names, numbers and dates exact."),
        Skill(slug: "organizar", name: "Organizar pasta", summary: "Propõe e aplica uma organização para uma pasta",
              instructions: "Organize the folder the user names (default ~/Downloads). First list it and propose a structure (by type and month) with counts, without moving anything. Only after the user agrees, move files with run_command using `mv -n` so nothing is overwritten, then report what moved."),
        Skill(slug: "revisar", name: "Revisar texto", summary: "Corrige e melhora um texto mantendo a voz do autor",
              instructions: "Proofread the user's text: fix grammar, spelling and clarity while keeping their voice and language. Return the revised text first, then a short list of the most important changes."),
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
        provider = try c.value(.provider, default: ProviderConfig())
        models = try c.value(.models, default: [])
    }
}
