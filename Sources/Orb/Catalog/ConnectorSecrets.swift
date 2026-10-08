import Foundation

/// Where secrets live: the login Keychain in the app, a dictionary in tests.
protocol SecretVault: Sendable {
    func get(_ account: String) -> String?
    /// True when the value is stored (an empty value deletes the item).
    func set(_ value: String, account: String) -> Bool
    func remove(_ account: String)
}

struct KeychainVault: SecretVault {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String, account: String) -> Bool { Keychain.store(value, account: account) }
    func remove(_ account: String) { Keychain.set("", account: account) }
}

final class MemoryVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// Tests: refuse writes, as a locked Keychain would.
    var rejectsWrites = false

    func get(_ account: String) -> String? { lock.withLock { items[account] } }

    func set(_ value: String, account: String) -> Bool {
        lock.withLock {
            guard !rejectsWrites else { return false }
            items[account] = value.isEmpty ? nil : value
            return true
        }
    }

    func remove(_ account: String) { lock.withLock { items[account] = nil } }
    var accounts: Set<String> { lock.withLock { Set(items.keys) } }
}

/// Keeps the secrets of connectors (tokens in environment variables and headers) in the Keychain, like the keys of
/// providers: in the data file (`state.json`) each one is replaced by `marker`; in memory, and in what the connector
/// is started with, the real value is there.
///
/// Safe by construction: a value leaves the data file only after the Keychain confirmed it stored it, and nothing
/// is deleted from the Keychain because it could not be read (a locked Keychain must not wipe a token).
/// Values are never logged.
@MainActor
final class ConnectorSecrets {
    static let marker = "@keychain"

    private let vault: any SecretVault
    /// What this app knows the vault holds, by account: lets a save skip unchanged secrets and find stale ones.
    private var known: [String: String] = [:]
    /// Accounts the data file referred to but the vault could not give: left alone until the user types a new value.
    private var unresolved: Set<String> = []

    init(vault: any SecretVault) { self.vault = vault }

    nonisolated static func account(id: UUID, name: String) -> String { "mcp.\(id.uuidString).\(name)" }

    /// Names that hold secrets: authentication headers and anything called token, key, secret, password…
    nonisolated static func looksSecret(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["token", "secret", "password", "passwd", "key", "auth", "credential", "cookie"].contains { lowered.contains($0) }
    }

    /// The names of `config`'s variables or headers that are secrets.
    nonisolated static func secretNames(of config: MCPServerConfig) -> Set<String> {
        let all = Set(config.environment.keys).union(config.headers.keys)
        return all.filter { config.secretKeys.contains($0) || looksSecret($0) }
    }

    // MARK: Reading

    /// `configs` as read from the data file with real values in place of markers. A marker whose item is gone becomes
    /// an empty value (the editor then asks for it again).
    func resolve(_ configs: [MCPServerConfig]) -> [MCPServerConfig] {
        configs.map { config in
            var config = config
            config.environment = resolved(config.environment, of: config)
            config.headers = resolved(config.headers, of: config)
            return config
        }
    }

    private func resolved(_ values: [String: String], of config: MCPServerConfig) -> [String: String] {
        var result = values
        for (name, value) in values where value == Self.marker {
            let account = Self.account(id: config.id, name: name)
            if let stored = vault.get(account) {
                known[account] = stored
                unresolved.remove(account)
                result[name] = stored
            } else {
                unresolved.insert(account)
                result[name] = ""
            }
        }
        return result
    }

    // MARK: Writing

    /// True when saving would still move a secret out of the data file (older files kept them in plain text).
    func hasUnprotectedSecrets(_ configs: [MCPServerConfig]) -> Bool {
        configs.contains { config in
            Self.secretNames(of: config).contains { name in
                let value = config.environment[name] ?? config.headers[name] ?? ""
                return !value.isEmpty && value != Self.marker && known[Self.account(id: config.id, name: name)] != value
            }
        }
    }

    /// `configs` as they go into the data file: secrets moved to the Keychain and replaced by `marker`. A secret the
    /// Keychain refused stays as it was (nothing is lost; the next save tries again). Items of removed connectors
    /// or cleared values are deleted.
    func redact(_ configs: [MCPServerConfig]) -> [MCPServerConfig] {
        var live: Set<String> = []
        let result = configs.map { config -> MCPServerConfig in
            var config = config
            let names = Self.secretNames(of: config)
            config.environment = redacted(config.environment, names: names, id: config.id, live: &live)
            config.headers = redacted(config.headers, names: names, id: config.id, live: &live)
            return config
        }
        for account in known.keys where !live.contains(account) {
            vault.remove(account)
            known[account] = nil
        }
        return result
    }

    private func redacted(_ values: [String: String], names: Set<String>, id: UUID, live: inout Set<String>) -> [String: String] {
        var result = values
        for name in names {
            guard let value = values[name] else { continue }
            let account = Self.account(id: id, name: name)
            if value.isEmpty {
                // Nothing typed: a reference the Keychain could not resolve is kept for the next launch.
                if unresolved.contains(account) { result[name] = Self.marker }
                continue
            }
            guard value != Self.marker else { live.insert(account); continue }
            if known[account] == value {
                live.insert(account)
                result[name] = Self.marker
            } else if vault.set(value, account: account) {
                known[account] = value
                unresolved.remove(account)
                live.insert(account)
                result[name] = Self.marker
            }
        }
        return result
    }
}
