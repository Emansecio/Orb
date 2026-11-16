import Foundation

/// Four-block live shared board (`Quadro vivo`) synchronized into each Team turn preface:
/// 1) Mission & criteria, 2) Stages & owners, 3) Active contracts/decisions, 4) Verification log.
enum TeamBoard {
    static let briefLimit = 2_800
    static let blockShare = 650
    static let maxContractEntries = 10
    static let maxVerificationEntries = 12

    static let missionPath = "preferencias/missao.md"
    static let stagesPath = "fatos/etapas.md"
    static let contractsPath = "preferencias/contratos-ativos.md"
    static let verificationsPath = "fatos/log-verificacoes.md"

    /// Writes Block 1 (Mission & criteria) and Block 2 (Stages & owners) from `team` to `bank`.
    static func syncMission(_ team: OrbTeam, to bank: MemoryBank) async {
        await bank.prepare(now: .now)
        await writePage(path: missionPath, kind: .preferencia, title: "Missão e critérios",
                        body: formatMissionBlock(team.mission), origin: .automatico, to: bank)
        await writePage(path: stagesPath, kind: .fato, title: "Mapa de etapas",
                        body: formatStagesBlock(team), origin: .automatico, to: bank)
    }

    /// Appends or updates Block 3 (Active contracts and architectural decisions) so parallel members see newly merged interfaces.
    static func recordContract(title: String, summary: String, author: String, to bank: MemoryBank) async {
        await bank.prepare(now: .now)
        let cleanTitle = MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(title)), 70)
        let cleanSummary = MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(summary)), 220)
        let cleanAuthor = MemoryText.clip(MemoryText.flatten(author), 40)
        guard !cleanTitle.isEmpty, !cleanSummary.isEmpty else { return }

        let line = "- **\(cleanTitle)** (\(cleanAuthor)): \(cleanSummary)"
        var lines = await existingLines(at: contractsPath, in: bank)
            .filter { !$0.hasPrefix("- **\(cleanTitle)** (") }
        lines.append(line)
        if lines.count > maxContractEntries { lines.removeFirst(lines.count - maxContractEntries) }

        await writePage(path: contractsPath, kind: .preferencia, title: "Contratos e decisões ativas",
                        body: lines.joined(separator: "\n"), origin: .orb, to: bank)
    }

    /// Records a check/test verification entry into Block 4 (`Log de verificações`).
    static func recordVerification(stageTitle: String, command: String, passed: Bool,
                                   commit: String = "", summary: String = "", to bank: MemoryBank) async {
        await bank.prepare(now: .now)
        let mark = passed ? "PASSOU" : "FALHOU"
        let cleanStage = MemoryText.clip(MemoryText.flatten(stageTitle), 60)
        let cleanCommand = MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(command)), 90)
        let commitPart = commit.isEmpty ? "" : " @ \(MemoryText.clip(MemoryText.flatten(commit), 16))"
        let detailPart = summary.isEmpty ? "" : " — \(MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(summary)), 120))"
        let entry = "- [\(mark)] \(cleanStage)\(commitPart): `\(cleanCommand)`\(detailPart)"

        var lines = await existingLines(at: verificationsPath, in: bank)
        lines.append(entry)
        if lines.count > maxVerificationEntries { lines.removeFirst(lines.count - maxVerificationEntries) }

        await writePage(path: verificationsPath, kind: .fato, title: "Log de verificações e evidências",
                        body: lines.joined(separator: "\n"), origin: .automatico, to: bank)
    }

    private static func writePage(path: String, kind: MemoryKind, title: String, body: String,
                                  origin: MemoryOrigin, to bank: MemoryBank) async {
        let now = Date.now
        let created = (await bank.read(path))?.created ?? now
        await bank.write(MemoryPage(path: path, kind: kind, title: title, body: body,
                                    created: created, updated: now, origin: origin))
    }

    /// Builds the sanitized 4-block preface injected into active Team turns.
    static func brief(bank: MemoryBank, team: OrbTeam, message: String) async -> String {
        await bank.prepare(now: .now)
        var sections: [String] = []

        let missionText = formatMissionBlock(team.mission)
        if !missionText.isEmpty {
            sections.append("### 1. Missão e critérios\n" + MemoryText.clip(missionText, blockShare))
        }

        let stagesText = formatStagesBlock(team)
        if !stagesText.isEmpty {
            sections.append("### 2. Mapa de etapas\n" + MemoryText.clip(stagesText, blockShare))
        }

        let contractLines = await existingLines(at: contractsPath, in: bank)
        let otherPrefs = (await bank.items(.preferencia, limit: 6))
            .filter { $0.path != missionPath && $0.path != contractsPath }
            .map { "- " + MemoryText.clip(MemoryBank.untrusted($0.body), 140) }
        let contractsCombined = contractLines.map { MemoryBank.untrusted($0) } + otherPrefs
        if !contractsCombined.isEmpty {
            sections.append("### 3. Contratos e decisões ativas\n"
                + MemoryText.clip(contractsCombined.joined(separator: "\n"), blockShare))
        }

        let verifications = (await existingLines(at: verificationsPath, in: bank)).map { MemoryBank.untrusted($0) }
        if !verifications.isEmpty {
            sections.append("### 4. Log de verificações\n"
                + MemoryText.clip(verifications.joined(separator: "\n"), blockShare))
        }

        let excluded: Set<String> = [missionPath, stagesPath, contractsPath, verificationsPath]
        let related = await bank.related(to: message, limit: MemoryBank.relatedLimit, excluding: excluded)
        if !related.isEmpty {
            sections.append("### Notas relacionadas\n" + related.map(MemoryBank.relatedLine).joined(separator: "\n"))
        }

        return GroupThread.fenced(MemoryText.clip(sections.joined(separator: "\n\n"), briefLimit))
    }

    private static func existingLines(at path: String, in bank: MemoryBank) async -> [String] {
        guard let page = await bank.read(path) else { return [] }
        return page.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func formatMissionBlock(_ mission: TeamMission) -> String {
        var lines: [String] = []
        let obj = MemoryText.flatten(MemorySanitizer.scrub(mission.objective))
        if !obj.isEmpty { lines.append("Objetivo: \(MemoryText.clip(obj, 320))") }
        if !mission.criteria.isEmpty {
            lines.append("Critérios:")
            for criterion in mission.criteria {
                let mark = criterion.isVerified ? "x" : " "
                let desc = MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(criterion.description)), 140)
                let evidence = criterion.lastEvidence.isEmpty ? "" : " (\(MemoryText.clip(MemoryText.flatten(criterion.lastEvidence), 60)))"
                lines.append("- [\(mark)] \(desc)\(evidence)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatStagesBlock(_ team: OrbTeam) -> String {
        guard !team.mission.stages.isEmpty else { return "" }
        return team.mission.stages.map { stage in
            let mark = stage.isDone ? "x" : " "
            let owner = stage.ownerMemberID.flatMap { team.member(id: $0)?.name } ?? "—"
            let reviewer = stage.reviewerMemberID.flatMap { team.member(id: $0)?.name } ?? "—"
            let blocker = stage.blockerNote.isEmpty ? "" : " [bloqueio: \(MemoryText.clip(MemoryText.flatten(stage.blockerNote), 80))]"
            return "- [\(mark)] \(MemoryText.clip(MemoryText.flatten(stage.title), 100)) · execução: \(owner) · revisão: \(reviewer)\(blocker)"
        }.joined(separator: "\n")
    }
}
