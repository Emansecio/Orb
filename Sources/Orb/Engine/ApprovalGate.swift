import Foundation

/// What the user answered on an approval card.
struct ApprovalAnswer: Sendable, Equatable {
    var decision: ApprovalDecision
    /// For "Sempre…" and "Só nesta tarefa": the rule chosen from the card's suggestions.
    var rule: PermissionRule?

    static let deny = ApprovalAnswer(decision: .deny)
    static let once = ApprovalAnswer(decision: .once)
}

/// The open approval cards of every Orb, shared by both engines: a turn opens one, shows it and waits; the UI
/// (or a change of permission mode) answers it. Waiting is safe against cancellation, and an answer that
/// arrives before the engine starts waiting is kept.
actor ApprovalGate {
    private struct Entry {
        var botID: UUID
        /// Still needs the user's eyes whatever the mode (destructive, or changes the Orb's instructions).
        var alwaysAsks: Bool
        var answer: ApprovalAnswer?
        var continuation: CheckedContinuation<ApprovalAnswer, Never>?
    }

    private var entries: [UUID: Entry] = [:]

    /// Registers a card before it is shown, so an answer can never get ahead of the wait.
    func open(_ approvalID: UUID, botID: UUID, alwaysAsks: Bool = false) {
        entries[approvalID] = Entry(botID: botID, alwaysAsks: alwaysAsks)
    }

    /// Suspends until the card is answered. A cancelled task (the user pressed Parar) leaves as a denial.
    func wait(for approvalID: UUID) async -> ApprovalAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalAnswer, Never>) in
                guard var entry = entries[approvalID] else { return continuation.resume(returning: .deny) }
                if let answer = entry.answer {
                    entries[approvalID] = nil
                    continuation.resume(returning: answer)
                } else {
                    entry.continuation = continuation
                    entries[approvalID] = entry
                }
            }
        } onCancel: {
            Task { await self.resolve(approvalID: approvalID, answer: .deny) }
        }
    }

    /// Answers a card. Unknown or already answered cards are ignored.
    func resolve(approvalID: UUID, answer: ApprovalAnswer) {
        guard var entry = entries[approvalID], entry.answer == nil else { return }
        if let continuation = entry.continuation {
            entries[approvalID] = nil
            continuation.resume(returning: answer)
        } else {
            entry.answer = answer
            entries[approvalID] = entry
        }
    }

    func resolve(approvalID: UUID, decision: ApprovalDecision) {
        resolve(approvalID: approvalID, answer: ApprovalAnswer(decision: decision))
    }

    /// Denies the Orb's open cards (the user stopped its turn).
    func cancelApprovals(for botID: UUID) {
        for id in openIDs(for: botID) { resolve(approvalID: id, answer: .deny) }
    }

    /// The permission mode changed while cards were open: "Sem pedir permissão" allows all of them, "Automático"
    /// the ones it would not have asked about, "Só leitura" denies all of them. Returns what was answered, so the
    /// transcript can show it.
    @discardableResult
    func applyModeChange(to mode: PermissionMode, for botID: UUID) -> [(approvalID: UUID, decision: ApprovalDecision)] {
        var answered: [(UUID, ApprovalDecision)] = []
        for id in openIDs(for: botID) {
            guard let entry = entries[id] else { continue }
            switch mode {
            case .bypass: answered.append((id, .once))
            case .auto where !entry.alwaysAsks: answered.append((id, .once))
            case .readOnly: answered.append((id, .deny))
            case .ask, .auto: break
            }
        }
        for (id, decision) in answered { resolve(approvalID: id, answer: ApprovalAnswer(decision: decision)) }
        return answered.map { (approvalID: $0.0, decision: $0.1) }
    }

    /// Cards of the Orb that nobody has answered yet.
    func openIDs(for botID: UUID) -> [UUID] {
        entries.filter { $0.value.botID == botID && $0.value.answer == nil }.map(\.key)
    }
}
