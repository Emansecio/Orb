import Foundation

/// A part of the draft, for highlighting what the last call changed.
enum DraftField: String, CaseIterable, Sendable {
    case name, role, instructions, look, capabilities, mode
}

/// An Orb being made in the "Criar conversando" assistant: what the assistant has filled in so far (`orb_draft`), shown
/// live next to the chat. In memory only. `apply(_:)` (the merge of one `orb_draft` call) lives in `OrbDraft+Apply.swift`.
struct OrbDraft: Equatable, Sendable {
    /// What one `orb_draft` call did: the parts it changed and the values it refused (each as a line for the model).
    struct Report: Equatable, Sendable {
        var changed: Set<DraftField> = []
        var rejected: [String] = []
    }

    var name = ""
    var role = ""
    var instructions = ""
    var orb = OrbConfig()
    var capabilities: Set<Capability> = []
    var mode = PermissionMode.ask
    /// The assistant says it has enough: the final card appears.
    var ready = false
    /// Incremented by each call, so the preview animates what changed.
    var revision = 0
    /// What the last call changed.
    var changed: Set<DraftField> = []

    /// "Criar" needs a name.
    var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
