import Foundation

/// Lifecycle state of an autonomous Team (`Time`).
enum TeamStatus: String, CaseIterable, Codable, Sendable {
    case preparing
    case running
    case waitingUser
    case paused
    case completed
    case failed

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .paused) }

    var label: String {
        switch self {
        case .preparing: "Preparando"
        case .running: "Executando"
        case .waitingUser: "Aguardando você"
        case .paused: "Pausado"
        case .completed: "Concluído"
        case .failed: "Interrompido"
        }
    }

    var isWorking: Bool { self == .preparing || self == .running }
}

/// Live activity state of a Team member (`Integrante`).
enum TeamMemberState: String, CaseIterable, Codable, Sendable {
    case idle
    case working
    case reviewing
    case blocked
    case done

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .idle) }

    var label: String {
        switch self {
        case .idle: "Aguardando"
        case .working: "Trabalhando"
        case .reviewing: "Revisando"
        case .blocked: "Bloqueado"
        case .done: "Concluído"
        }
    }

    var orbActivity: OrbActivity {
        switch self {
        case .working: .typing
        case .reviewing: .reading
        case .blocked: .waiting
        case .idle, .done: .idle
        }
    }
}

/// A verifiable acceptance criterion attached to a Team's Mission (`done_when`).
struct MissionCriterion: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var description: String
    var verification = ""
    var isVerified = false
    var lastEvidence = ""
    var verifiedAtCommit = ""
}

extension MissionCriterion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        description = try c.value(.description, default: "")
        verification = try c.value(.verification, default: "")
        isVerified = try c.value(.isVerified, default: false)
        lastEvidence = try c.value(.lastEvidence, default: "")
        verifiedAtCommit = try c.value(.verifiedAtCommit, default: "")
    }
}

/// One stage inside a Team's Mission plan, assigned to an owner and an independent reviewer.
struct MissionStage: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var title: String
    var ownerMemberID: UUID?
    var reviewerMemberID: UUID?
    var dependsOn: [UUID] = []
    var isDone = false
    var blockerNote = ""
}

extension MissionStage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        title = try c.value(.title, default: "")
        ownerMemberID = try c.decodeIfPresent(UUID.self, forKey: .ownerMemberID)
        reviewerMemberID = try c.decodeIfPresent(UUID.self, forKey: .reviewerMemberID)
        dependsOn = try c.lossyArray(.dependsOn)
        isDone = try c.value(.isDone, default: false)
        blockerNote = try c.value(.blockerNote, default: "")
    }
}

/// Structured Mission guiding continuous execution and progress tracking.
struct TeamMission: Codable, Sendable, Equatable {
    var objective = ""
    var criteria: [MissionCriterion] = []
    var stages: [MissionStage] = []

    struct Progress: Sendable, Equatable {
        var stagesDone: Int
        var totalStages: Int
        var criteriaVerified: Int
        var totalCriteria: Int

        var fraction: Double {
            if totalStages > 0 { return Double(stagesDone) / Double(totalStages) }
            if totalCriteria > 0 { return Double(criteriaVerified) / Double(totalCriteria) }
            return 0
        }

        /// Short progress indicator for sidebar and header ("2 de 5 etapas").
        var stageSummary: String? {
            guard totalStages > 0 else { return nil }
            return "\(stagesDone) de \(totalStages) \(totalStages == 1 ? "etapa" : "etapas")"
        }
    }

    var progress: Progress {
        Progress(stagesDone: stages.filter(\.isDone).count,
                 totalStages: stages.count,
                 criteriaVerified: criteria.filter(\.isVerified).count,
                 totalCriteria: criteria.count)
    }
}

extension TeamMission {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objective = try c.value(.objective, default: "")
        criteria = try c.lossyArray(.criteria)
        stages = try c.lossyArray(.stages)
    }
}

/// An agent created exclusively to belong to one `OrbTeam` (`Integrante`).
/// Invisible in the personal `Orbs` list and deleted when the Team is deleted.
struct TeamMember: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var role = ""
    var systemGoal = ""
    var orb = OrbConfig()
    /// Model id (`"provider/model"`); empty uses the app default.
    var model = ""
    var effort = ""
    var capabilities: Set<Capability> = [.terminal, .browser, .computerUse]
    var state = TeamMemberState.idle
}

extension TeamMember {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.value(.name, default: "")
        role = try c.value(.role, default: "")
        systemGoal = try c.value(.systemGoal, default: "")
        orb = try c.value(.orb, default: OrbConfig())
        model = try c.value(.model, default: "")
        effort = try c.value(.effort, default: "")
        let decodedCaps = try? c.decodeIfPresent(Set<Capability>.self, forKey: .capabilities)
        capabilities = decodedCaps ?? [.terminal, .browser, .computerUse]
        state = try c.value(.state, default: .idle)
    }
}

/// An autonomous Team generated from an idea (`Time`), shown in its own sidebar wing.
struct OrbTeam: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var idea = ""
    var scouterModel = ""
    /// Repository or working folder shared by the team (empty uses `times/<teamID>/espaco/`).
    var projectFolder = ""
    var permissionMode = PermissionMode.bypass
    var orchestratorID: UUID
    var members: [TeamMember]
    var mission = TeamMission()
    var status = TeamStatus.paused
    var createdAt = Date.now
    var updatedAt = Date.now
    var unread = 0

    static let recommendedLimits = 2...8
    static let maxMembers = 12

    var orchestrator: TeamMember? { member(id: orchestratorID) ?? members.first }

    func member(id memberID: UUID) -> TeamMember? {
        members.first { $0.id == memberID }
    }

    /// Ensures the Team keeps unique valid members within `[2, maxMembers]` and a valid orchestrator.
    func normalized() -> OrbTeam? {
        var seen: Set<UUID> = []
        var copy = self
        copy.members = members.filter { seen.insert($0.id).inserted }
        if copy.members.count > Self.maxMembers {
            copy.members = Array(copy.members.prefix(Self.maxMembers))
        }
        guard copy.members.count >= Self.recommendedLimits.lowerBound else { return nil }
        if !copy.members.contains(where: { $0.id == copy.orchestratorID }) {
            copy.orchestratorID = copy.members[0].id
        }
        if copy.unread < 0 { copy.unread = 0 }
        return copy
    }

    /// Member names are scoped to this Team only so different Teams can reuse role names like "Revisor".
    func isMemberNameTaken(_ candidate: String, excluding memberID: UUID? = nil) -> Bool {
        let target = Self.foldedName(candidate)
        guard !target.isEmpty else { return false }
        return members.contains { $0.id != memberID && Self.foldedName($0.name) == target }
    }

    func uniqueMemberName(basedOn base: String, excluding memberID: UUID? = nil) -> String {
        let trimmed = Self.clippedName(base)
        let root = trimmed.isEmpty ? "Integrante" : trimmed
        guard isMemberNameTaken(root, excluding: memberID) else { return root }
        var index = 2
        while isMemberNameTaken("\(root) \(index)", excluding: memberID) { index += 1 }
        return "\(root) \(index)"
    }

    /// Converts a member into a standalone personal `Bot`, resolving collisions against existing `Orbs`.
    func promotedBot(for memberID: UUID, existingBotNames: [String]) -> Bot? {
        guard let member = member(id: memberID) else { return nil }
        let taken = Set(existingBotNames.map(Self.foldedName))
        let clipped = Self.clippedName(member.name)
        let base = clipped.isEmpty ? "Integrante" : clipped
        var candidate = base
        var index = 2
        while taken.contains(Self.foldedName(candidate)) {
            candidate = Self.clippedName("\(base) \(index)")
            index += 1
        }
        var bot = Bot(name: candidate, role: member.role, orb: member.orb)
        bot.model = member.model
        bot.effort = member.effort
        bot.capabilities = member.capabilities
        bot.permissionMode = permissionMode
        bot.workingDirectory = projectFolder
        return bot
    }

    private static let memberNameLimit = 60

    private static func clippedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(memberNameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func foldedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension OrbTeam {
    /// Tolerant decoding so Teams saved across app versions always open cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        name = try c.value(.name, default: "")
        idea = try c.value(.idea, default: "")
        scouterModel = try c.value(.scouterModel, default: "")
        projectFolder = try c.value(.projectFolder, default: "")
        permissionMode = try c.value(.permissionMode, default: .bypass)
        members = try c.lossyArray(.members)
        orchestratorID = try c.decodeIfPresent(UUID.self, forKey: .orchestratorID) ?? members.first?.id ?? UUID()
        mission = try c.value(.mission, default: TeamMission())
        status = try c.value(.status, default: .paused)
        createdAt = try c.value(.createdAt, default: Date.now)
        updatedAt = try c.value(.updatedAt, default: Date.now)
        unread = try c.value(.unread, default: 0)
    }
}
