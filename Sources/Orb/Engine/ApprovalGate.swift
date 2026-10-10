import Foundation

/// What the user answered on an approval card.
struct ApprovalAnswer: Sendable, Equatable {
    var decision: ApprovalDecision
    /// For "Sempre…" and "Só nesta tarefa": the rule chosen from the card's suggestions.
    var rule: PermissionRule?
    /// For a denial: what the user wants the Orb to do instead (cleaned by `ApprovalNote.clean`).
    var note: String?

    init(decision: ApprovalDecision, rule: PermissionRule? = nil, note: String? = nil) {
        self.decision = decision
        self.rule = rule
        self.note = ApprovalNote.clean(note)
    }

    static let deny = ApprovalAnswer(decision: .deny)
    static let once = ApprovalAnswer(decision: .once)
}

/// The user's words on a denial, and how each engine tells the model.
enum ApprovalNote {
    static let maxLength = 500

    /// Trimmed and capped; nil when nothing is left.
    static func clean(_ note: String?) -> String? {
        guard let text = note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maxLength))
    }

    static func append(_ note: String?, to denial: String) -> String {
        guard let note = clean(note) else { return denial }
        return denial + " The user said: " + note
    }
}

extension PermissionVerdict.AskReason {
    /// A destructive action: it never joins a grouped card and its notification asks for the Mac to be unlocked.
    var isDangerous: Bool { if case .dangerous = self { true } else { false } }
}

extension PermissionPolicy {
    /// `userDenial`, with what the user said to do instead.
    static func userDenial(note: String?) -> String { ApprovalNote.append(note, to: userDenial) }
}

extension ClaudeCodePolicy {
    static func userDenial(note: String?) -> String { ApprovalNote.append(note, to: userDenial) }
}

extension ApprovalGate {
    /// The card `browse_show` opens once the window is up: `show` puts it in the conversation (and says the Orb is waiting),
    /// and this waits for "Pronto" (true) or "Cancelar" and Parar (false). A change of permission mode never answers it.
    func handoff(page: String, botName: String, botID: UUID, show: (ApprovalRequest) -> Void) async -> Bool {
        let card = ApprovalRequest.handoff(botName: botName, page: page)
        open(card.id, botID: botID, alwaysAsks: true, isHandoff: true)
        show(card)
        return await wait(for: card.id).decision != .deny
    }
}

// MARK: MultiOrb (WP3)
extension ApprovalGate {
    /// The creation card of `orb_propose`: `show` puts it in the conversation, and this waits for "Criar" (`.once`) or "Não criar" and
    /// Parar (`.deny`). Like a hand-off it asks whatever the permission mode is, and a change of mode never answers it.
    /// Returns the card (the app finds the possibly edited proposal by its id) and the answer.
    func propose(_ proposal: OrbProposal, botName: String, botID: UUID,
                 show: (ApprovalRequest) -> Void) async -> (card: ApprovalRequest, answer: ApprovalAnswer) {
        let card = ApprovalRequest(toolName: OrbProposeTool.name, title: "\(botName) quer criar um Orb", command: proposal.name,
                                   reason: proposal.reason ?? "", proposal: proposal)
        open(card.id, botID: botID, alwaysAsks: true, isHandoff: true)
        show(card)
        return (card, await wait(for: card.id))
    }

    /// The whole of `orb_propose` once the engine has the proposal: the card, the wait, and, on "Criar", the creation. A refusal
    /// (or Parar) is the model's "o usuário não quis criar esse Orb"; the app says what it made, or why it could not.
    func proposeAndCreate(_ proposal: OrbProposal, creation: OrbCreationSupport, botName: String, botID: UUID,
                          show: (ApprovalRequest) -> Void) async -> ProposalOutcome {
        let (card, answer) = await propose(proposal, botName: botName, botID: botID, show: show)
        guard answer.decision != .deny, !Task.isCancelled else { return .declined }
        return await creation.create(card.id, proposal)
    }
}
// MARK: end MultiOrb (WP3)

/// The open approval cards of every Orb, shared by both engines: a turn opens one, shows it and waits; the UI
/// (or a change of permission mode) answers it. Waiting is safe against cancellation, and an answer that
/// arrives before the engine starts waiting is kept.
actor ApprovalGate {
    private struct Entry {
        var botID: UUID
        /// Still needs the user's eyes whatever the mode (destructive, or changes the Orb's instructions).
        var alwaysAsks: Bool
        /// The Orb waits for the person to finish something in the browser (not a permission): no mode answers it.
        var isHandoff = false
        var answer: ApprovalAnswer?
        var continuation: CheckedContinuation<ApprovalAnswer, Never>?
    }

    private var entries: [UUID: Entry] = [:]

    /// Registers a card before it is shown, so an answer can never get ahead of the wait.
    func open(_ approvalID: UUID, botID: UUID, alwaysAsks: Bool = false, isHandoff: Bool = false) {
        entries[approvalID] = Entry(botID: botID, alwaysAsks: alwaysAsks, isHandoff: isHandoff)
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

    /// Whether a task is suspended in `wait(for:)` on this card right now.
    func isWaiting(for approvalID: UUID) -> Bool { entries[approvalID]?.continuation != nil }

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

    /// Denies the Orb's open cards (the user stopped its turn), hand-offs included.
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
            // A hand-off is not a permission: only the person answers it (or Parar, which cancels it).
            guard let entry = entries[id], !entry.isHandoff else { continue }
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
