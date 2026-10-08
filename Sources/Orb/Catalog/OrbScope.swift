import Foundation

/// Connectors and skills can be offered to every Orb (the default, what they always did) or only to chosen ones
/// ("Usar com"). `orbIDs == nil` means every Orb, including Orbs created later.
protocol OrbScoped {
    var orbIDs: Set<UUID>? { get set }
}

extension OrbScoped {
    func isAvailable(to botID: UUID) -> Bool { orbIDs?.contains(botID) ?? true }
    var isForAllOrbs: Bool { orbIDs == nil }
}

extension MCPServerConfig: OrbScoped {}
extension Skill: OrbScoped {}

/// How a scope reads in the UI ("Todos os Orbs", "Só Atlas", "Atlas, Lia e mais 2").
enum OrbScopeText {
    /// `names` are the Orbs in scope that still exist, in sidebar order.
    static func summary(orbIDs: Set<UUID>?, bots: [Bot]) -> String {
        guard let orbIDs else { return "Todos os Orbs" }
        let names = bots.filter { orbIDs.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "Nenhum Orb"
        case 1: return "Só \(names[0])"
        default: return "Só " + list(names, limit: 2)
        }
    }

    /// The warning under "Usar com" when choosing an Orb would also give it connectors it does not have yet.
    static func extraAccess(_ items: [(bot: Bot, connectors: [String])]) -> String? {
        guard !items.isEmpty else { return nil }
        var seen = Set<String>(), names: [String] = []
        for name in items.flatMap(\.connectors) where seen.insert(name).inserted { names.append(name) }
        let orbs = list(items.map(\.bot.name), limit: 3)
        let who = items.count == 1 ? "o Orb" : "os Orbs"
        return "“Conectores” está desligado em \(orbs). Ao ligar, \(who) também passa\(items.count == 1 ? "" : "m") a usar \(list(names, limit: 3)), que já \(names.count == 1 ? "está instalado" : "estão instalados")."
    }

    /// "Atlas", "Atlas e Lia", "Atlas, Lia e mais 2".
    static func list(_ names: [String], limit: Int = 2) -> String {
        guard names.count > limit else {
            return names.count > 1 ? names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1] : names.first ?? ""
        }
        let rest = names.count - limit
        return names.prefix(limit).joined(separator: ", ") + " e mais \(rest)"
    }
}

extension AppModel {
    // MARK: Which connectors and skills an Orb gets

    /// Enabled skills the Orb may use (all of them unless a skill is limited to other Orbs).
    func skills(for botID: UUID) -> [Skill] {
        skills.filter { $0.isEnabled && $0.isAvailable(to: botID) }
    }

    /// Enabled connectors the Orb may use. Whether it gets them at all is its "Conectores" switch (`Capability.connectors`).
    func connectors(for botID: UUID) -> [MCPServerConfig] {
        connectors.filter { $0.isEnabled && $0.isAvailable(to: botID) }
    }

    /// The connectors a Claude Code turn of this Orb is given: none while its "Conectores" switch is off.
    func connectorServers(for bot: Bot) -> [MCPServerConfig] {
        bot.capabilities.contains(.connectors) ? connectors(for: bot.id) : []
    }

    /// What the Orb panel shows under "Conectores": the names of the connectors this Orb actually gets (empty while its
    /// switch is off).
    func connectorNames(for botID: UUID) -> [String] {
        guard bots.first(where: { $0.id == botID })?.capabilities.contains(.connectors) == true else { return [] }
        return connectors(for: botID).map(\.name)
    }

    /// The Orbs that get a connector now: in its scope and with their "Conectores" switch on.
    func orbsUsing(_ connector: MCPServerConfig) -> [Bot] {
        guard connector.isEnabled else { return [] }
        return bots.filter { $0.capabilities.contains(.connectors) && connector.isAvailable(to: $0.id) }
    }

    // MARK: Changing scopes

    /// The Orb a new connector starts with: the one the user was last on, if it still exists. nil means every Orb.
    func defaultScopeForNewConnector() -> Set<UUID>? {
        lastSelectedBotID.flatMap { id in bots.contains { $0.id == id } ? [id] : nil }
    }

    /// Orbs with "Conectores" off that would get connectors other than `id` when it is turned on for them (as choosing
    /// the Orb in "Usar com" does), with the names of those other connectors.
    func extraConnectorAccess(ifEnabledFor botIDs: some Collection<UUID>, besides id: UUID) -> [(bot: Bot, connectors: [String])] {
        bots.filter { botIDs.contains($0.id) && !$0.capabilities.contains(.connectors) }.compactMap { bot in
            let others = connectors(for: bot.id).filter { $0.id != id }.map(\.name)
            return others.isEmpty ? nil : (bot, others)
        }
    }

    func setConnector(_ id: UUID, enabled: Bool, for botID: UUID) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].orbIDs = Self.toggled(connectors[index].orbIDs, botID: botID, on: enabled, allBots: bots.map(\.id))
        if enabled { allowConnectors(for: [botID]) }
    }

    func setSkill(_ id: UUID, enabled: Bool, for botID: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].orbIDs = Self.toggled(skills[index].orbIDs, botID: botID, on: enabled, allBots: bots.map(\.id))
    }

    /// Turns "Conectores" on for the Orbs that were just given a connector, so choosing an Orb in "Usar com" is enough.
    func allowConnectors(for botIDs: some Collection<UUID>) {
        for id in botIDs {
            if let index = bots.firstIndex(where: { $0.id == id }), !bots[index].capabilities.contains(.connectors) {
                bots[index].capabilities.insert(.connectors)
            }
        }
    }

    /// The new scope after switching one Orb: from "all Orbs" it becomes everyone else (minus this one) or just it.
    nonisolated static func toggled(_ scope: Set<UUID>?, botID: UUID, on: Bool, allBots: [UUID]) -> Set<UUID>? {
        var ids = scope ?? Set(allBots)
        if on { ids.insert(botID) } else { ids.remove(botID) }
        return ids.isSuperset(of: allBots) && scope == nil ? nil : ids
    }

    // MARK: Using a skill

    /// The Orb a "Usar" button talks to: the last Orb the user was on, when it still exists and may use the skill.
    func preferredBot(for skill: Skill) -> Bot? {
        guard let id = lastSelectedBotID, skill.isAvailable(to: id) else { return nil }
        return bots.first { $0.id == id }
    }

    /// Opens the Orb's chat with `/slug ` at the start of the composer (what was typed stays after it).
    func useSkill(_ skill: Skill, with botID: UUID) {
        drafts[botID] = Self.draft(inserting: skill.slug, into: drafts[botID] ?? "")
        selection = .bot(botID)
    }

    /// "/slug rest": a skill only counts at the start of the message, so another one already there is replaced.
    nonisolated static func draft(inserting slug: String, into draft: String) -> String {
        var rest = draft.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("/") {
            rest = rest.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        }
        return "/\(slug) " + rest
    }
}
