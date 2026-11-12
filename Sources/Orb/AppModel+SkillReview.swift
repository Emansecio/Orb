import Foundation

// The Orb's skills as the Orb itself sees them, and the skills it proposes: it learns a procedure by doing a task,
// proposes it as a skill, and you read it in the editor and save it, or not. Nothing is saved without you.

/// A proposal on its way to the editor: the skill it would be (new, or an existing one with the proposed text).
struct SkillDraft: Identifiable {
    /// Per Orb: two Orbs may propose the same command, and the Skills page lists them together.
    var id: String { "\(botID.uuidString)/\(slug)" }
    var skill: Skill
    /// The command of the proposal (the one in the file; the editor may rename the skill).
    var slug: String
    var botID: UUID
    var orbName: String
    /// It replaces the instructions of a skill that exists.
    var isUpdate: Bool
    /// When the proposal file was written, as the editor read it: a deciding click only throws away that version.
    var modified: Date?
}

extension AppModel {
    // MARK: What the Orb's tools can load

    /// Gives the Orb's tools (`recall "/name"`) the skills this Orb may use.
    func publishSkills(for botID: UUID) {
        let digests = skills(for: botID).map(SkillDigest.init)
        let bank = memory.bank(for: botID)
        Task { await bank.publishSkills(digests) }
    }

    /// Skills changed (edited, switched off, deleted, or only counted a use): refresh the copy of the Orbs whose bank is
    /// open now, so a `recall "/slug"` in a turn already running does not read the old text. A bank not open has no turn
    /// reading it, and the next turn publishes anyway: opening fifty banks at every use would cost for nothing.
    func republishSkills() {
        for bot in bots {
            guard let bank = memory.openBank(for: bot.id) else { continue }
            let digests = skills(for: bot.id).map(SkillDigest.init)
            Task { await bank.publishSkills(digests) }
        }
    }

    // MARK: The review

    /// Ajustes → Orbs: the Orbs review their work and propose skills (on unless turned off).
    var proposesSkills: Bool { preferences.object(forKey: SkillReview.settingKey) as? Bool ?? true }

    /// Starts the review of the conversation when the turn that just ended took enough steps with tools: in the
    /// background, without a word in the chat, with the system prompt, tools and history of the turn (so the provider's
    /// cache is still warm). Fewer steps are enough when the stretch shows a sign (`SkillReview.hasSign`), and then only
    /// a yes from the gate runs the review.
    /// Not in an Orb that only reads and not while anything else
    /// has the Orb; a message from the user stops it (`send`), and the stretch waits for the end of the next turn.
    /// `messages` are those of the conversation the turn worked on: when it ended in another one than the one on show,
    /// `session.conversation` is already the other (`endWorkElsewhere`), and `reviewFrom` counts the turn's.
    /// `rated`: the person has just judged the turn's work (`react`), which asks now whatever the count: the gate decides.
    func reviewSkillsIfDue(_ session: BotSession, messages: [ChatMessage]?, rated: String? = nil) {
        let steps = session.stepsSinceSkill
        guard proposesSkills, rated != nil || steps >= SkillReview.earlyThreshold, session.skillReview == nil,
              session.turnTask == nil, !isResetting, var request = session.reviewBase,
              let current = bot(session.id), current.permissionMode != .readOnly,
              let messages, session.reviewFrom <= messages.count else { return }
        // The stretch the count spans: from the turn of its first step, in this conversation's messages (a count that
        // began in another conversation, or before a compaction, starts at the latest turn at worst).
        let since = steps > 0 ? min(session.reviewSince, session.reviewFrom) : session.reviewFrom
        let early = rated != nil || steps < SkillReview.threshold
        // Before the count is due only the gate decides, so without a cheap model to ask there is nothing to start.
        let hasGate = modelRef(for: current).flatMap { ref in account(ref.provider).flatMap { Self.skillGate(in: $0, orb: ref.model) } } != nil
        // A rating is about work: a reply with no action behind it has no procedure to keep (it reaches the Orb with the next message).
        let worked = messages[since...].contains { $0.role == .assistant && !$0.toolCalls.isEmpty }
        guard !early || (hasGate && (rated != nil ? worked : SkillReview.hasSign(messages[since...]))) else { return }
        let feedback = SkillReview.feedback(in: messages[since...]) + (rated.map { [$0] } ?? [])
        session.stepsSinceSkill = 0
        let isRetry = session.reviewStopped
        session.reviewStopped = false
        // The history the turn sent (its summary and condensed stretch, not the raw messages) and what the turn added
        // to it: the prefix of the turn's last model call, which is what the provider has in its cache.
        request.history += messages[session.reviewFrom...]
        request.maxSteps = SkillReview.maxSteps
        request.onlyTools = SkillReview.tools
        request.context.skillReview = true
        request.client = request.client.withoutIdleProcess // never the conversation's idle Claude Code process
        // The prompt asks for no task: the turn's own request stays the start of the task in progress, so what the
        // turn's last call sent whole is sent whole again (and the provider's cache holds).
        request.promptOnlySteers = true
        let botID = session.id
        let usedModel = session.turnModel ?? modelRef(for: current)?.text
        session.skillReview = Task { [request] in
            var request = request
            let bank = memory.bank(for: botID)
            let waiting = await bank.proposals()
            // The stretch is still unreviewed: its steps count again, and the end of a later turn reads the whole of it.
            @MainActor func putBack() {
                session.stepsSinceSkill += steps
                session.reviewSince = min(since, session.reviewSince)
            }
            // Stopped before it ended (the user wrote): the end of the next turn tries once more, and only once.
            @MainActor func stopped() {
                guard !isRetry else { return }
                putBack()
                session.reviewStopped = true
            }
            // No room for another proposal: the review could only end in a refusal, and it would be paid for first.
            // (The count starts over, so the next try is after `SkillReview.threshold` more steps.)
            guard waiting.count < MemoryBank.maximumProposals else {
                if !Task.isCancelled { session.skillReview = nil }
                return
            }
            let declined = await bank.declinedProposals()
            // The gate: one short call on the cheap model decides whether the full review (the whole history again, and
            // almost always "Nothing to save.") is worth paying for. Without a cheap model, or without a clear answer,
            // the review runs as it always did, unless the count was not due yet: then only a yes runs it.
            var verdict: Bool?
            if let ref = modelRef(for: current) {
                verdict = await askSkillGate(botID: botID, ref: ref, messages: messages[since...], declined: declined,
                                             feedback: feedback, early: early)
            }
            guard !Task.isCancelled else { return stopped() }
            if verdict == false || (early && verdict == nil) {
                // The gate gave no answer, or a rating asked before the count was due: the count goes on as it was.
                if verdict == nil || rated != nil { putBack() }
                session.skillReview = nil
                return
            }
            request.prompt = SkillReview.prompt(declined: declined, rated: rated)
            // Nothing of it reaches the chat or the history, but what it costs is real: each call goes to the usage
            // history as the app's own (`auxiliary`), so the Uso page shows it apart from the chat's.
            // A call stopped midway (the user wrote) is billed for the input the provider already reported, as in a turn.
            var unfinished: TokenUsage?
            for await event in engine.run(request) {
                guard let usedModel else { continue }
                switch event {
                case .pendingUsage(let used): unfinished = used
                case .requestUsage(let used):
                    unfinished = nil
                    recordUsage(UsageTotals(used), botID: botID, model: usedModel, source: .auxiliary)
                default: break
                }
            }
            if let unfinished, let usedModel { recordUsage(UsageTotals(unfinished), botID: botID, model: usedModel, source: .auxiliary) }
            usageLog.flush()
            guard !Task.isCancelled else {
                // Stopped after it had already proposed: there is nothing left to try again for.
                if await bank.proposals() == waiting { stopped() }
                return
            }
            session.skillReview = nil
            // "Propor skills" was switched off while the review ran: its result is not announced.
            guard proposesSkills else { return }
            await collectSkillProposals(botID)
        }
    }

    /// Tells the chat about a proposal that waits for you: one at a time, each once (`announcedProposals`).
    func collectSkillProposals(_ botID: UUID) async {
        guard sessions[botID] != nil else { return }
        let waiting = await memory.bank(for: botID).proposals()
        // Not while a routine has the Orb: its conversation is on screen then, and the notice would land in it.
        guard let session = sessions[botID], session.routineID == nil,
              let next = waiting.first(where: { session.announcedProposals[$0.slug] != $0.modified }) else { return }
        session.announcedProposals[next.slug] = next.modified
        let isUpdate = skills(for: botID).contains { $0.slug == next.slug && $0.isImprovable }
        append(.notice(isUpdate ? "\(NoticeAction.proposalUpdatePrefix) /\(next.slug)"
                       : "\(NoticeAction.proposalPrefix) /\(next.slug) — \(next.name)"), to: botID)
    }

    // MARK: Deciding

    func hasSkillProposal(_ slug: String, of botID: UUID) async -> Bool {
        await memory.bank(for: botID).proposal(slug) != nil
    }

    /// The proposal as the editor shows it: nil when it is gone.
    func skillDraft(_ slug: String, from botID: UUID) async -> SkillDraft? {
        guard let proposal = await memory.bank(for: botID).proposal(slug) else { return nil }
        return skillDraft(proposal, from: botID)
    }

    /// Every proposal of every Orb that waits for you (the Skills page lists them; newest first within each Orb). The
    /// folders are read inside each Orb's memory actor, not on the main thread.
    func pendingSkillDrafts() async -> [SkillDraft] {
        var drafts: [SkillDraft] = []
        for id in bots.map(\.id) {
            drafts += await memory.bank(for: id).proposals().map { skillDraft($0, from: id) }
        }
        return drafts
    }

    /// A skill was renamed: the proposal waiting under the old command moves to the new one, or `skillDraft` would make
    /// a new skill with the old command next to the renamed one.
    func carryProposals(from old: String, to new: String, orbs: Set<UUID>) {
        guard old != new else { return }
        for id in orbs where bot(id) != nil {
            let bank = memory.bank(for: id)
            Task { await bank.renameProposal(from: old, to: new) }
        }
    }

    private func skillDraft(_ proposal: SkillProposal, from botID: UUID) -> SkillDraft {
        let slug = proposal.slug
        let orb = bot(botID)?.name ?? "O Orb"
        // Switched-off skills count too: the Orb never saw it listed, so it may propose the same command again, and a
        // "slug-2" next to the disabled one would not be the improvement it meant.
        if var current = skills.first(where: { $0.slug == slug && $0.isImprovable && $0.isAvailable(to: botID) }) {
            current.summary = proposal.summary
            current.instructions = proposal.instructions
            return SkillDraft(skill: current, slug: slug, botID: botID, orbName: orb, isUpdate: true, modified: proposal.modified)
        }
        let command = uniqueSlug(slug)
        let skill = Skill(slug: command, name: proposal.name, summary: proposal.summary, instructions: proposal.instructions,
                          source: Skill.learnedSource, orbIDs: [botID], learnedBy: botID)
        return SkillDraft(skill: skill, slug: slug, botID: botID, orbName: orb, isUpdate: false, modified: proposal.modified)
    }

    /// The gate's verdict on the turn: true or false, nil when there is none (no cheap model, a failure, an unreadable
    /// answer) and the review should run. Cancelled, it also gives nil: the caller leaves on `Task.isCancelled`.
    private func askSkillGate(botID: UUID, ref: ModelRef, messages: ArraySlice<ChatMessage>, declined: [SkillDigest],
                              feedback: [String], early: Bool) async -> Bool? {
        guard let account = account(ref.provider), account.isEnabled, isUsable(account),
              let model = Self.skillGate(in: account, orb: ref.model),
              let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == model },
                                                               credentials: Self.credentials(for: ref.provider),
                                                               conversationID: botID.uuidString + "-porteiro") else { return nil }
        let transcript = ChunkSummarizer.transcript(of: messages, characters: SkillReview.gateCharacters)
        let prompt = SkillReview.gatePrompt(transcript: transcript, skillNames: skills(for: botID).map { "/" + $0.slug },
                                            declined: declined, feedback: feedback, early: early)
        let verdict = await SkillReview.askGate(prompt, client: client, model: model)
        if let usage = verdict.usage, !isResetting, bot(botID) != nil {
            recordAuxiliaryUsage(usage, botID: botID, model: ModelRef(provider: ref.provider, model: model).text)
        }
        return Task.isCancelled ? nil : verdict.yes
    }

    /// Which model decides: Haiku on Claude Code (whose list has it under that name), else the cheap one of the Orb's
    /// maker (`ChunkSummarizer.model`). nil when there is none: the gate does not run and the review does.
    static func skillGate(in account: ProviderAccount, orb: String) -> String? {
        if account.kind == .claudeCode { return account.models.first { $0.id.lowercased().contains("haiku") }?.id }
        return ChunkSummarizer.model(in: account, orb: orb)?.id
    }

    /// You decided: the proposal goes away. Saved, it is also said (VoiceOver) and the Orb is pleased; turned down, the
    /// Orb's memory keeps it so the review does not bring the same one back.
    func finishSkillDraft(_ draft: SkillDraft, saved skill: Skill? = nil) {
        let bank = memory.bank(for: draft.botID)
        Task {
            // The review may have rewritten the proposal while the sheet was open: that newer version was never read, so
            // it stays for the next look instead of going with the one decided.
            if let modified = draft.modified, let current = await bank.proposal(draft.slug), current.modified != modified {
                append(.notice("A proposta /\(draft.slug) mudou enquanto você a revisava. A versão nova continua esperando sua decisão."),
                       to: draft.botID)
            } else if skill == nil {
                await bank.declineProposal(draft.slug)
            } else {
                await bank.discardProposal(draft.slug)
            }
        }
        guard let skill else { return }
        announceForAccessibility("Skill /\(skill.slug) salva")
        sessions[draft.botID]?.celebrate(.light)
    }
}
