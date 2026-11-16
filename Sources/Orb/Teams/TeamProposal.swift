import Foundation

/// Fields inside a live `TeamProposal` so the UI can highlight whatever the Olheiro just updated.
enum TeamProposalField: Hashable, Sendable {
    case teamName
    case objective
    case analysisSummary
    case criteria
    case stages
    case members
}

/// Editable member inside an in-progress Team proposal before it becomes an `OrbTeam`.
struct TeamMemberDraft: Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var role = ""
    var systemGoal = ""
    var orb = OrbConfig()
    /// `"provider/model"`; empty uses the app default.
    var model = ""
    var effort = ""
    var capabilities: Set<Capability> = [.terminal, .browser, .computerUse]
    var isOrchestrator = false

    static let orbPresets: [OrbConfig] = [
        OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso", temperament: .equilibrado),
        OrbConfig(color: "menta", eyes: "felizes", mouth: "sorrisao", cheeks: "sardas", temperament: .animado),
        OrbConfig(color: "sol", eyes: "pontos", mouth: "sorriso", temperament: .curioso),
        OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush", temperament: .calmo),
        OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", temperament: .equilibrado),
        OrbConfig(color: "perola", eyes: "ovais", mouth: "sorriso", cheeks: "blush", temperament: .calmo),
        OrbConfig(color: "noite", eyes: "pilulas", brows: "arqueadas", temperament: .curioso),
    ]

    static func preset(at index: Int) -> OrbConfig {
        orbPresets[abs(index) % orbPresets.count]
    }

    static func orbConfig(forColor color: String?, fallbackIndex: Int) -> OrbConfig {
        let validColors = Set(orbPresets.map(\.color))
        let base = preset(at: fallbackIndex)
        guard let color = color?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              validColors.contains(color) else { return base }
        return orbPresets.first { $0.color == color } ?? OrbConfig(color: color, eyes: base.eyes, mouth: base.mouth)
    }

    /// Rotates to the next expressive Orb preset so the user can customize looks with one click.
    func nextPreset() -> OrbConfig {
        if let idx = Self.orbPresets.firstIndex(where: { $0.color == orb.color }) {
            return Self.preset(at: idx + 1)
        }
        return Self.preset(at: 0)
    }
}

/// Live editable blueprint produced and refined in conversation with the Olheiro.
struct TeamProposal: Sendable, Equatable {
    var teamName = ""
    var objective = ""
    var analysisSummary = ""
    var scoutNote = ""
    var criteria: [String] = []
    var stages: [String] = []
    var members: [TeamMemberDraft] = []
    var ready = false

    var hasContent: Bool {
        !teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !members.isEmpty
    }

    /// True when the proposal can materialize into a valid `OrbTeam` with 2–12 uniquely named members.
    var canCreate: Bool {
        guard (OrbTeam.recommendedLimits.lowerBound...OrbTeam.maxMembers).contains(members.count) else { return false }
        let cleanNames = members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleanNames.allSatisfy({ !$0.isEmpty }) else { return false }
        let folded = Set(cleanNames.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        })
        return folded.count == members.count
    }

    /// Duplicate names inside the draft, for inline validation cues.
    var hasDuplicateNames: Bool {
        let cleanNames = members.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }.filter { !$0.isEmpty }
        return Set(cleanNames).count != cleanNames.count
    }

    /// Applies partial or full structured updates returned by `team_proposal` and returns changed fields.
    @discardableResult
    mutating func apply(_ arguments: JSONValue) -> Set<TeamProposalField> {
        var changed: Set<TeamProposalField> = []

        if let rawName = arguments["name"]?.string ?? arguments["team_name"]?.string {
            let clean = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean != teamName {
                teamName = clean
                changed.insert(.teamName)
            }
        }
        if let rawObj = arguments["objective"]?.string {
            let clean = rawObj.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean != objective {
                objective = clean
                changed.insert(.objective)
            }
        }
        if let rawSummary = arguments["analysis_summary"]?.string {
            let clean = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean != analysisSummary {
                analysisSummary = clean
                changed.insert(.analysisSummary)
            }
        }
        if let rawNote = arguments["scout_note"]?.string {
            scoutNote = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let list = arguments["criteria"]?.array {
            let parsed = list.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !parsed.isEmpty, parsed != criteria {
                criteria = Array(parsed.prefix(8))
                changed.insert(.criteria)
            }
        }
        if let list = arguments["stages"]?.array {
            let parsed = list.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !parsed.isEmpty, parsed != stages {
                stages = Array(parsed.prefix(12))
                changed.insert(.stages)
            }
        }
        if let rawMembers = arguments["members"]?.array {
            var parsed: [TeamMemberDraft] = []
            for (index, item) in rawMembers.prefix(OrbTeam.maxMembers).enumerated() {
                guard let name = item["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                let role = item["role"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let goal = item["instructions"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? item["system_goal"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                let model = item["model"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let effort = item["effort"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let color = item["color"]?.string
                let isLead = item["is_orchestrator"]?.bool ?? item["orchestrator"]?.bool ?? (index == 0)
                let caps: Set<Capability> = {
                    guard let arr = item["capabilities"]?.array else { return [.terminal, .browser, .computerUse] }
                    let values = Set(arr.compactMap(\.string).compactMap(Capability.init(rawValue:)))
                    return values.isEmpty ? [.terminal] : values
                }()
                let existingID = members.first(where: {
                    $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        == name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                })?.id ?? UUID()
                parsed.append(TeamMemberDraft(
                    id: existingID,
                    name: name,
                    role: role,
                    systemGoal: goal,
                    orb: TeamMemberDraft.orbConfig(forColor: color, fallbackIndex: index),
                    model: model,
                    effort: effort,
                    capabilities: caps,
                    isOrchestrator: isLead
                ))
            }
            if !parsed.isEmpty {
                // Guarantee exactly one orchestrator in the draft.
                if let leadIndex = parsed.firstIndex(where: \.isOrchestrator) {
                    for i in parsed.indices { parsed[i].isOrchestrator = (i == leadIndex) }
                } else {
                    parsed[0].isOrchestrator = true
                }
                if parsed != members {
                    members = parsed
                    changed.insert(.members)
                }
            }
        }
        if let flag = arguments["ready"]?.bool {
            ready = flag
        } else if canCreate {
            ready = true
        }
        return changed
    }

    func modelSummary(_ changed: Set<TeamProposalField>) -> String {
        let updated = changed.map { "\($0)" }.sorted().joined(separator: ", ")
        return "Proposal updated (\(members.count) members, \(criteria.count) criteria, ready=\(ready); changed: \(updated.isEmpty ? "none" : updated))."
    }

    /// Converts the refined blueprint into an `OrbTeam` ready to persist and start.
    func buildTeam(idea: String, scouterModel: String, projectFolder: String, permissionMode: PermissionMode) -> OrbTeam? {
        guard canCreate else { return nil }
        let leadID = members.first(where: \.isOrchestrator)?.id ?? members[0].id
        let builtMembers = members.map { draft in
            TeamMember(
                id: draft.id,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                role: draft.role.trimmingCharacters(in: .whitespacesAndNewlines),
                systemGoal: draft.systemGoal.trimmingCharacters(in: .whitespacesAndNewlines),
                orb: draft.orb,
                model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
                effort: draft.effort.trimmingCharacters(in: .whitespacesAndNewlines),
                capabilities: draft.capabilities,
                state: .idle
            )
        }
        let nonLeadID = builtMembers.first(where: { $0.id != leadID })?.id
        let builtStages = stages.enumerated().map { index, title in
            let owner = builtMembers[index % builtMembers.count].id
            let reviewer = builtMembers.first(where: { $0.id != owner })?.id ?? nonLeadID
            return MissionStage(title: title, ownerMemberID: owner, reviewerMemberID: reviewer)
        }
        let builtCriteria = criteria.map { MissionCriterion(description: $0) }
        let cleanName = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanName.isEmpty ? "Time novo" : cleanName
        let resolvedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        return OrbTeam(
            name: resolvedName,
            idea: idea.trimmingCharacters(in: .whitespacesAndNewlines),
            scouterModel: scouterModel,
            projectFolder: projectFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            permissionMode: permissionMode,
            orchestratorID: leadID,
            members: builtMembers,
            mission: TeamMission(objective: resolvedObjective.isEmpty ? idea : resolvedObjective,
                                 criteria: builtCriteria,
                                 stages: builtStages),
            status: .paused
        ).normalized()
    }
}
