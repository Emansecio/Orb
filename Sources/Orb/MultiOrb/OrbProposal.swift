import Foundation

/// A new Orb an Orb proposes (`orb_propose`) or the assistant has drafted, as the creation card shows it. Nothing exists
/// until the person accepts. `OrbProposal.make(from:args:)` (the inheritance rules) lives in `OrbProposal+Make.swift`.
struct OrbProposal: Codable, Equatable, Sendable {
    /// The Orb that proposes it.
    var creator: OrbRef
    var name: String
    /// One line.
    var role: String = ""
    /// How it should work; up to 1,500 characters here (the Orb's identity keeps up to 12,000).
    var instructions: String = ""
    /// Never more than the creator has, never `.connectors`.
    var capabilities: Set<Capability> = []
    /// Up to `modeCeiling`.
    var mode: PermissionMode = .ask
    /// The most permissive mode the card lets the person pick (the creator's own, never "Sem pedir permissão").
    var modeCeiling: PermissionMode = .auto
    var orb: OrbConfig = OrbConfig()
    /// The creator's model; empty is the app's default. Read only on the card.
    var model: String = ""
    /// Why, in one sentence.
    var reason: String?
    /// What the creator has among the switches the card can offer.
    var creatorCapabilities: Set<Capability> = []
    /// An Orb already has this name: the card warns that the folder gets another name.
    var nameTaken: Bool = false
}

extension OrbProposal {
    /// Tolerant decoding: a proposal saved in a conversation opens in any version that knows the type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creator = try c.decode(OrbRef.self, forKey: .creator)
        name = try c.value(.name, default: "")
        role = try c.value(.role, default: "")
        instructions = try c.value(.instructions, default: "")
        capabilities = Set(try c.lossyArray(.capabilities, default: [Capability]()))
        mode = try c.value(.mode, default: PermissionMode.ask)
        modeCeiling = try c.value(.modeCeiling, default: PermissionMode.auto)
        orb = try c.value(.orb, default: OrbConfig())
        model = try c.value(.model, default: "")
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        creatorCapabilities = Set(try c.lossyArray(.creatorCapabilities, default: [Capability]()))
        nameTaken = try c.value(.nameTaken, default: false)
    }
}

/// How the person answered a creation card, for the model that proposed the Orb.
enum ProposalOutcome: Equatable, Sendable {
    case created(name: String, folder: String)
    /// Created after "Editar antes"; `summary` says what changed.
    case createdEdited(name: String, folder: String, summary: String)
    case declined
    /// It could not be created (the creator is in read-only mode, a limit was reached).
    case failed(String)

    /// What the tool returns to the model.
    var modelText: String {
        switch self {
        case .created(let name, let folder):
            "O usuário criou o Orb \(name) (pasta \(folder)). Você pode pedir trabalho a ele com orbs."
        case .createdEdited(let name, let folder, let summary):
            "O usuário criou o Orb \(name) com ajustes: \(summary). Pasta \(folder). Você pode pedir trabalho a ele com orbs."
        case .declined:
            "O usuário não quis criar esse Orb. Não proponha de novo."
        case .failed(let reason):
            reason
        }
    }
}
