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

    /// One line of the final audit about a numbered criterion: `2. PASS — swift test: 48 passed` or `3. FAIL: falta o teste`.
    struct CriterionVerdict: Sendable, Equatable {
        var passed: Bool
        var evidence: String
    }

    /// One tool execution observed by the engine during a Team turn, used for mechanical evidence provenance.
    struct ObservedTool: Sendable, Equatable {
        var tool: String
        var input: String
        var output: String
        var isError: Bool
    }

    /// Mechanical provenance check (fail-closed): verifies that the evidence cited for a `PASS` line actually matches
    /// a non-error tool call observed in the same turn. Rejects empty evidence, turns that ran no successful tools,
    /// fabricated numbers not present in the tool output, and hallucinated claims whose tokens never appeared.
    static func hasProvenance(evidence: String, in observed: [ObservedTool]) -> Bool {
        let haystacks = foldedHaystacks(from: observed)
        return matchesProvenance(evidence: evidence, in: haystacks)
    }

    /// Batch provenance check for all `PASS` verdicts in a final audit, folding observed tool outputs once (O(N)).
    static func verifiedCriteriaNumbers(for verdicts: [Int: CriterionVerdict], in observed: [ObservedTool]) -> Set<Int> {
        let haystacks = foldedHaystacks(from: observed)
        guard !haystacks.isEmpty else { return [] }
        var verified: Set<Int> = []
        for (number, verdict) in verdicts where verdict.passed {
            if matchesProvenance(evidence: verdict.evidence, in: haystacks) {
                verified.insert(number)
            }
        }
        return verified
    }

    private static func foldedHaystacks(from observed: [ObservedTool]) -> [String] {
        observed.compactMap { entry in
            guard !entry.isError else { return nil }
            return fold(entry.tool + " " + entry.input + "\n" + entry.output)
        }
    }

    private static func matchesProvenance(evidence: String, in haystacks: [String]) -> Bool {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !haystacks.isEmpty else { return false }

        let foldedEvidence = fold(trimmed)
        let tokens = substantiveTokens(from: foldedEvidence)
        guard !tokens.isEmpty else { return false }
        let numericTokens = tokens.filter { $0.allSatisfy(\.isNumber) }

        for haystack in haystacks {
            // Every numeric figure cited in the evidence (e.g. test counts, exit codes) must appear standalone in the same tool output.
            if !numericTokens.isEmpty, !numericTokens.allSatisfy({ containsStandaloneNumber($0, in: haystack) }) {
                continue
            }
            if foldedEvidence.count >= 10, haystack.contains(foldedEvidence) {
                return true
            }
            var matched = 0
            for token in tokens {
                let found = token.allSatisfy(\.isNumber)
                    ? containsStandaloneNumber(token, in: haystack)
                    : haystack.contains(token)
                if found {
                    matched += 1
                    if matched >= min(2, tokens.count) { return true }
                }
            }
        }
        return false
    }

    private static func containsStandaloneNumber(_ number: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: number, range: search) {
            let beforeIsDigit = range.lowerBound > text.startIndex && text[text.index(before: range.lowerBound)].isNumber
            let afterIsDigit = range.upperBound < text.endIndex && text[range.upperBound].isNumber
            if !beforeIsDigit && !afterIsDigit { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Extracts distinct substantive tokens (numbers, identifiers, file names, commands) from folded evidence.
    private static func substantiveTokens(from folded: String) -> [String] {
        let stopWords: Set<String> = [
            "para", "como", "mais", "tudo", "certo", "passou", "passaram", "aprovado",
            "verificado", "ok", "com", "sem", "dos", "das", "que", "uma", "este", "esta",
            "with", "from", "that", "this", "have", "were", "been", "passed", "verified", "approved",
        ]
        var seen: Set<String> = []
        var result: [String] = []
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-")).inverted
        for raw in folded.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "._/-"))
            guard !token.isEmpty else { continue }
            let isNumber = token.allSatisfy(\.isNumber)
            let isSubstantive = isNumber || token.count >= 4 || token.contains(".") || token.contains("/")
            guard isSubstantive, !stopWords.contains(token), seen.insert(token).inserted else { continue }
            result.append(token)
            if result.count >= 16 { break }
        }
        return result
    }

    /// Reads the per-criterion lines of a final audit, keyed by the 1-based number of the criterion. A criterion with no line
    /// gets no verdict: an overall `APPROVED` alone never verifies it.
    static func criterionVerdicts(in reply: String, count: Int) -> [Int: CriterionVerdict] {
        guard count > 0, let regex = criterionLine else { return [:] }
        var result: [Int: CriterionVerdict] = [:]
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
                .replacingOccurrences(of: "**", with: "")
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line), let number = Int(line[numberRange]),
                  (1...count).contains(number),
                  let markRange = Range(match.range(at: 2), in: line) else { continue }
            let mark = line[markRange].uppercased()
            let evidence = Range(match.range(at: 3), in: line).map { String(line[$0]) }?
                .trimmingCharacters(in: CharacterSet(charactersIn: " :—–-")) ?? ""
            result[number] = CriterionVerdict(passed: mark == "PASS", evidence: evidence)
        }
        return result
    }

    private static let criterionLine = try? NSRegularExpression(
        pattern: #"^\[?(\d{1,2})[\].):]?\s*\[?(PASS|FAIL)\b\]?(.*)$"#, options: [.caseInsensitive]
    )
}
