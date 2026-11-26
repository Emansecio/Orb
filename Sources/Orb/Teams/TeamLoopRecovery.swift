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
    private static let captcha = "O serviço exigiu verificação humana (CAPTCHA) para continuar."
    private static let twoFactor = "É necessário concluir autenticação em duas etapas (2FA) manualmente."
    private static let apiKey = "Falta uma chave de API/credencial externa para esta frente avançar."
    private static let payment = "A ação exige confirmação de pagamento pelo usuário."
    private static let login = "A conta externa pede login manual antes de continuar."

    /// Tokens are matched on word boundaries (accents and case folded), so "2fa" inside a commit hash is not a blocker.
    private static let patterns: [(token: String, prompt: String)] = [
        ("captcha", captcha),
        ("recaptcha", captcha),
        ("2fa", twoFactor),
        ("two-factor", twoFactor),
        ("autenticacao em duas etapas", twoFactor),
        ("verificacao em duas etapas", twoFactor),
        ("missing api key", apiKey),
        ("no api key", apiKey),
        ("falta a chave de api", apiKey),
        ("chave de api ausente", apiKey),
        ("sem chave de api", apiKey),
        ("payment required", payment),
        ("pagamento necessario", payment),
        ("login required", login),
        ("login necessario", login),
        ("exige login", login),
    ]

    static func detect(in text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        for entry in patterns where containsWord(entry.token, in: folded) {
            return entry.prompt
        }
        return nil
    }

    private static func containsWord(_ token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
