import Foundation

/// Inter-turn stagnation and external-blocker detector for autonomous Teams (extending `LoopWatch`).
/// Forces strategy pivots on repeated error signatures, escalates to the Team leader if stuck, and pauses ONLY the
/// blocked front (`waitingUser`) when a physical external blocker cannot be resolved by agents.
struct TeamStagnationDetector: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case none
        /// Inject a root-cause directive forcing the member to abandon the repeating tactic.
        case pivotStrategy(directive: String)
        /// Escalate the stage to the orchestrator to split, reassign, or change approach.
        case escalateToLeader(stageID: UUID, reason: String)
        /// External physical blocker (login, 2FA, CAPTCHA, missing credential, payment) that requires the user.
        case pauseFrontForUser(stageID: UUID, prompt: String)
    }

    struct StageTracker: Sendable, Equatable {
        var lastSignature = ""
        var sameFailureCount = 0
        var reviewRejectCount = 0
        var pivotedOnce = false
    }

    static let pivotThreshold = 2
    static let escalateAfterPivotThreshold = 3
    static let maxReviewRejectsBeforeEscalate = 3

    private(set) var stages: [UUID: StageTracker] = [:]

    /// Evaluates a failure or gate rejection on `stageID` and decides the autonomous recovery action.
    mutating func recordFailure(stageID: UUID, rawError: String) -> Action {
        if let blockerPrompt = TeamExternalBlocker.detect(in: rawError) {
            return .pauseFrontForUser(stageID: stageID, prompt: blockerPrompt)
        }
        let signature = Self.normalizedSignature(rawError)
        var tracker = stages[stageID] ?? StageTracker()
        if signature == tracker.lastSignature, !signature.isEmpty {
            tracker.sameFailureCount += 1
        } else {
            tracker.lastSignature = signature
            tracker.sameFailureCount = 1
            tracker.pivotedOnce = false
        }
        stages[stageID] = tracker

        if tracker.sameFailureCount >= Self.escalateAfterPivotThreshold && tracker.pivotedOnce {
            return .escalateToLeader(
                stageID: stageID,
                reason: "A etapa repetiu a mesma falha \(tracker.sameFailureCount) vezes mesmo após troca de tática (\(signature.prefix(120)))."
            )
        }
        if tracker.sameFailureCount >= Self.pivotThreshold && !tracker.pivotedOnce {
            tracker.pivotedOnce = true
            stages[stageID] = tracker
            return .pivotStrategy(
                directive: "Você repetiu a mesma falha (\(tracker.sameFailureCount)x): pare de tentar o mesmo comando/tática. "
                    + "Diagnostique a causa raiz no código/ambiente e execute uma estratégia alternativa."
            )
        }
        return .none
    }

    /// Tracks consecutive independent review rejections (`CHANGES:`) on a stage.
    mutating func recordReviewChanges(stageID: UUID, feedback: String) -> Action {
        var tracker = stages[stageID] ?? StageTracker()
        tracker.reviewRejectCount += 1
        stages[stageID] = tracker
        if tracker.reviewRejectCount >= Self.maxReviewRejectsBeforeEscalate {
            return .escalateToLeader(
                stageID: stageID,
                reason: "Etapa recusada \(tracker.reviewRejectCount) vezes na revisão (\(feedback.prefix(120))). Redivida ou reatribua."
            )
        }
        return .none
    }

    mutating func clearStage(_ stageID: UUID) {
        stages.removeValue(forKey: stageID)
    }

    static func normalizedSignature(_ raw: String) -> String {
        LoopWatch.steady(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Detects genuine physical/external blockers that autonomous agents cannot resolve on their own.
enum TeamExternalBlocker {
    private static let patterns: [(token: String, prompt: String)] = [
        ("captcha", "O serviço exigiu verificação humana (CAPTCHA) para continuar."),
        ("2fa", "É necessário concluir autenticação em duas etapas (2FA) manualmente."),
        ("two-factor", "É necessário concluir autenticação em duas etapas (2FA) manualmente."),
        ("missing api key", "Falta uma chave de API/credencial externa para esta frente avançar."),
        ("no api key", "Falta uma chave de API/credencial externa para esta frente avançar."),
        ("payment required", "A ação exige confirmação de pagamento pelo usuário."),
        ("login required", "A conta externa pede login manual antes de continuar."),
    ]

    static func detect(in text: String) -> String? {
        let lower = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        for entry in patterns where lower.contains(entry.token) {
            return entry.prompt
        }
        return nil
    }
}
