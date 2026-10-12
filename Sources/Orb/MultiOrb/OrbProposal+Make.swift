import Foundation

/// What `orb_propose` needs to know about the Orb that proposes and the Orbs there already are, captured when the turn starts
/// (the engine never reads the app's state), and how the engine asks the app to create the Orb once the person accepts.
struct OrbCreationSupport: Sendable {
    /// The Orb that proposes it, as it is now (the engine refreshes its permission mode before the tool runs).
    var creator: Bot
    /// The names the Orbs have now, for the card's "another folder name" warning.
    var existingNames: [String]
    /// How many Orbs this creator already made, and how many Orbs have been made by Orbs in all (`OrbProposal.perCreatorLimit`).
    var createdByCreator = 0
    var createdTotal = 0
    /// Creates the Orb for the card `approvalID` (the person said "Criar"). It reads the proposal as the card holds it, which
    /// is what "Editar antes" changed, and answers with what the model is told.
    var create: OrbCreationHandler

    init(creator: Bot, existingNames: [String] = [], createdByCreator: Int = 0, createdTotal: Int = 0,
         create: @escaping OrbCreationHandler = { _, _ in .failed("Não foi possível criar o Orb agora.") }) {
        self.creator = creator
        self.existingNames = existingNames
        self.createdByCreator = createdByCreator
        self.createdTotal = createdTotal
        self.create = create
    }
}

typealias OrbCreationHandler = @Sendable (_ approvalID: UUID, _ proposal: OrbProposal) async -> ProposalOutcome

extension OrbProposal {
    /// At most this many Orbs per creator, and this many made by Orbs in all (the tool refuses past them).
    static let perCreatorLimit = 5
    static let totalLimit = 12
    static let roleLimit = 120
    /// The same limit `AppModel.clippedName` holds the Orb's name to.
    static let nameLimit = 60

    /// A name as the Orb will have it: secrets and control characters out, one line, within the limit.
    static func clippedName(_ name: String) -> String {
        String(MemoryText.flatten(MemorySanitizer.scrub(name)).prefix(nameLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The modes a card may offer, least to most permissive. "Sem pedir permissão" is never one of them.
    static let modeOrder: [PermissionMode] = [.readOnly, .ask, .auto]

    /// The most permissive mode the new Orb may have, from the creator's own: never "Sem pedir permissão".
    static func ceiling(forCreatorMode mode: PermissionMode) -> PermissionMode {
        switch mode {
        case .readOnly: .readOnly
        case .ask: .ask
        case .auto, .bypass: .auto
        }
    }

    /// The more cautious of two modes ("Sem pedir permissão" is the least cautious).
    static func lesser(_ a: PermissionMode, _ b: PermissionMode) -> PermissionMode {
        func rank(_ mode: PermissionMode) -> Int { mode == .bypass ? 3 : modeOrder.firstIndex(of: mode) ?? 0 }
        return rank(b) < rank(a) ? b : a
    }

    /// The modes up to the ceiling, for the card's picker.
    var allowedModes: [PermissionMode] {
        let top = Self.modeOrder.firstIndex(of: modeCeiling) ?? Self.modeOrder.count - 1
        return Array(Self.modeOrder[...top])
    }

    /// Why the tool refuses to propose, or nil when it may. The limits count Orbs that exist, so a declined card costs nothing.
    static func refusal(creatorMode: PermissionMode, createdByCreator: Int, createdTotal: Int) -> String? {
        if creatorMode == .readOnly {
            return "You are in read-only mode, so you cannot create Orbs. Tell the user to change your mode if they want one."
        }
        if createdByCreator >= perCreatorLimit {
            return "You already created \(perCreatorLimit) Orbs, which is the most one Orb may create. Use the ones that exist (orbs list)."
        }
        if createdTotal >= totalLimit {
            return "Orbs have already created \(totalLimit) Orbs, which is the most allowed. Use the ones that exist (orbs list)."
        }
        return nil
    }

    /// The proposal for `creator` and the arguments of `orb_propose` (the rules of docs/historico/MULTI-ORBS.md 4.2). Pure: whatever the
    /// model sent, the result never has more than the creator, no connectors, and a look that exists.
    /// `existingNames`: the Orbs there are now, to warn that the folder gets another name.
    static func make(from creator: Bot, args: JSONValue, existingNames: [String] = []) -> OrbProposal {
        let name = Self.clippedName(args["name"]?.string ?? "")
        let requested = Set((args["capabilities"]?.array ?? []).compactMap { $0.string.flatMap(Capability.init(rawValue:)) })
            .subtracting([.connectors])
        let inheritable = creator.capabilities.subtracting([.connectors])
        let ceiling = ceiling(forCreatorMode: creator.permissionMode)
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let taken = existingNames.contains { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) == folded }
        let reason = args["reason"]?.string.map { MemoryText.flatten(MemorySanitizer.scrub($0)) }.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
        return OrbProposal(
            creator: OrbRef(creator),
            name: name.isEmpty ? "Novo Orb" : name,
            role: String(MemoryText.flatten(MemorySanitizer.scrub(args["role"]?.string ?? "")).prefix(roleLimit)),
            instructions: cleanInstructions(args["instructions"]?.string ?? ""),
            // Nothing asked for is everything the creator may hand down; what is asked for is never more than that.
            capabilities: requested.isEmpty ? inheritable : requested.intersection(inheritable),
            mode: lesser(.ask, ceiling),
            modeCeiling: ceiling,
            orb: look(from: args["look"]),
            model: creator.model,
            reason: reason,
            creatorCapabilities: inheritable,
            nameTaken: taken)
    }

    /// The instructions without secrets, control characters or `#` headings that could pass for a section of the Orb's identity;
    /// lines stay lines, a run of blank lines becomes one, and the whole stays within `OrbProposeTool.instructionsLimit`.
    static func cleanInstructions(_ text: String) -> String {
        var lines: [String] = []
        for line in MemorySanitizer.scrub(text).components(separatedBy: .newlines) {
            let flat = MemoryText.flatten(line)
            if flat.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(flat)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(OrbProposeTool.instructionsLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A random look with whatever the model asked for that the catalog knows laid over it (an unknown id is left out).
    static func look(from value: JSONValue?, catalog: OrbCatalog = .shared) -> OrbConfig {
        var config = OrbConfig.random()
        guard let value, case .object = value else { return config }
        let singles: [(String, OrbCategory)] = [("color", .color), ("eyes", .eyes), ("mouth", .mouth), ("brows", .brows),
                                                ("cheeks", .cheeks), ("mustache", .mustache), ("hair", .hair)]
        for (key, category) in singles {
            guard let id = value[key]?.string, catalog.ids(category).contains(id) else { continue }
            config.set(category, id)
        }
        if let items = value["accessories"]?.array {
            let known = catalog.ids(.accessories)
            var seen: [String] = []
            for id in items.compactMap(\.string) where known.contains(id) && !seen.contains(id) { seen.append(id) }
            config.accessories = Array(seen.prefix(2))
        }
        return config
    }

    /// The proposal as it may be created: everything held to the rules again, since the card's fields are free text and the
    /// proposal came through a conversation file. The creator's side of it (`creatorCapabilities`, the ceiling, the model) is kept.
    func clamped() -> OrbProposal {
        var copy = self
        let clipped = Self.clippedName(name)
        copy.name = clipped.isEmpty ? "Novo Orb" : clipped
        copy.role = String(MemoryText.flatten(MemorySanitizer.scrub(role)).prefix(Self.roleLimit))
        copy.instructions = Self.cleanInstructions(instructions)
        copy.capabilities = capabilities.intersection(creatorCapabilities).subtracting([.connectors])
        let allowed = allowedModes
        copy.mode = allowed.contains(mode) ? mode : Self.lesser(.ask, modeCeiling)
        return copy
    }

    /// What "Editar antes" changed, in a few words for the model ("nome Lia, sem navegador, modo Automático"); empty when nothing.
    func changes(from original: OrbProposal) -> String {
        var parts: [String] = []
        if name != original.name { parts.append("nome \(name)") }
        if role != original.role { parts.append("papel “\(role)”") }
        if instructions != original.instructions { parts.append("instruções editadas") }
        for capability in Capability.allCases where original.capabilities.contains(capability) != capabilities.contains(capability) {
            parts.append((capabilities.contains(capability) ? "com " : "sem ") + capability.label)
        }
        if mode != original.mode { parts.append("modo \(mode.label)") }
        if orb != original.orb { parts.append("outra aparência") }
        return parts.joined(separator: ", ")
    }
}
