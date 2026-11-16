import Foundation

/// Programmatic perfectionism gates enforced in the Team engine (`ADR 0003`):
/// 1) Post-edit verification (`CompletionWatch`), 2) Independent reviewer != author,
/// 3) Explicit `ReviewVerdict`, and 4) Final integrated audit across all stages and criteria.
enum TeamQualityGates {
    enum StageRejection: Sendable, Equatable {
        case needsFreshCheck(String)
        case sameAuthorReviewer
        case reviewNotApproved(String)
        case missingReviewVerdict
    }

    enum StageGateResult: Sendable, Equatable {
        case approved
        case rejected(StageRejection)
    }

    enum FinalAuditRejection: Sendable, Equatable {
        case unfinishedStages([String])
        case unverifiedCriteria([String])
        case auditNotApproved(String)
        case sameAuthorFinalAuditor
    }

    enum FinalAuditResult: Sendable, Equatable {
        case passed
        case blocked(FinalAuditRejection)
    }

    /// Validates that an execution turn genuinely ran verification after its last edit, has an independent reviewer,
    /// and received an explicit `APPROVED` verdict.
    static func evaluateStage(ownerID: UUID, reviewerID: UUID?, builderReply: String,
                              completionWatch: CompletionWatch, reviewerReply: String,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> StageGateResult {
        if let reminder = completionWatch.reminder(for: builderReply, fileExists: fileExists) {
            return .rejected(.needsFreshCheck(reminder))
        }
        guard let reviewerID, reviewerID != ownerID else {
            return .rejected(.sameAuthorReviewer)
        }
        guard let verdict = ReviewVerdict.read(reviewerReply) else {
            return .rejected(.missingReviewVerdict)
        }
        switch verdict {
        case .approved:
            return .approved
        case .changes:
            return .rejected(.reviewNotApproved(reviewerReply))
        }
    }

    /// Final Mission completion gate: requires every stage done, every criterion verified with evidence,
    /// and an independent final auditor verdict (`APPROVED`) from someone other than the last stage owner.
    static func evaluateFinalAudit(team: OrbTeam, lastStageOwnerID: UUID?, auditorID: UUID?,
                                   auditorReply: String) -> FinalAuditResult {
        let openStages = team.mission.stages.filter { !$0.isDone }.map(\.title)
        if !openStages.isEmpty {
            return .blocked(.unfinishedStages(openStages))
        }
        let unverified = team.mission.criteria.filter {
            !$0.isVerified || $0.lastEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.description)
        if !unverified.isEmpty {
            return .blocked(.unverifiedCriteria(unverified))
        }
        if let lastStageOwnerID, let auditorID, lastStageOwnerID == auditorID, team.members.count > 1 {
            return .blocked(.sameAuthorFinalAuditor)
        }
        guard let verdict = ReviewVerdict.read(auditorReply), verdict == .approved else {
            return .blocked(.auditNotApproved(auditorReply))
        }
        return .passed
    }
}
