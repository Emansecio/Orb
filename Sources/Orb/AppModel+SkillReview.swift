import Foundation

// The Orb's skills as the Orb itself sees them, and the skills it proposes: it learns a procedure by doing a task,
// proposes it as a skill, and you read it in the editor and save it, or not. Nothing is saved without you.

/// A proposal on its way to the editor: the skill it would be (new, or an existing one with the proposed text).
struct SkillDraft: Identifiable {
    var id: String { slug }
    var skill: Skill
    /// The command of the proposal (the one in the file; the editor may rename the skill).
    var slug: String
    var botID: UUID
    var orbName: String
    /// It replaces the instructions of a skill that exists.
    var isUpdate: Bool
}

extension AppModel {
    // MARK: What the Orb's tools can load

    /// Gives the Orb's tools (`recall "/name"`) the skills this Orb may use.
    func publishSkills(for botID: UUID) {
        let digests = skills(for: botID).map(SkillDigest.init)
        let bank = memory.bank(for: botID)
        Task { await bank.publishSkills(digests) }
    }

    // MARK: The review

    /// Ajustes → Orbs: the Orbs review their work and propose skills (on unless turned off).
    var proposesSkills: Bool { preferences.object(forKey: SkillReview.settingKey) as? Bool ?? true }

    /// Starts the review of the conversation when the turn that just ended took enough steps with tools: in the
    /// background, without a word in the chat, with the system prompt, tools and history of the turn (so the provider's
    /// cache is still warm).
    /// Not in an Orb that only reads and not while anything else
    /// has the Orb; a message from the user stops it (`send`).
    func reviewSkillsIfDue(_ session: BotSession) {
        guard proposesSkills, session.stepsSinceSkill >= SkillReview.threshold, session.skillReview == nil,
              session.turnTask == nil, !isResetting, var request = session.reviewBase,
              let current = bot(session.id), current.permissionMode != .readOnly,
              let messages = session.conversation?.messages, session.reviewFrom <= messages.count else { return }
        session.stepsSinceSkill = 0
        // The history the turn sent (its summary and condensed stretch, not the raw messages) and what the turn added
        // to it: the prefix of the turn's last model call, which is what the provider has in its cache.
        request.history += messages[session.reviewFrom...]
        request.prompt = SkillReview.prompt
        request.maxSteps = SkillReview.maxSteps
        request.onlyTools = SkillReview.tools
        request.context.skillReview = true
        // The prompt asks for no task: the turn's own request stays the start of the task in progress, so what the
        // turn's last call sent whole is sent whole again (and the provider's cache holds).
        request.promptOnlySteers = true
        let botID = session.id
        let reviewFrom = session.reviewFrom
        let usedModel = session.turnModel ?? modelRef(for: current)?.text
        session.skillReview = Task {
            // No room for another proposal: the review could only end in a refusal, and it would be paid for first.
            // (The count starts over, so the next try is after `SkillReview.threshold` more steps.)
            guard await memory.bank(for: botID).proposals().count < MemoryBank.maximumProposals else {
                if !Task.isCancelled { session.skillReview = nil }
                return
            }
            // The gate: one short call on the cheap model decides whether the full review (the whole history again, and
            // almost always "Nothing to save.") is worth paying for. Without a cheap model, or without a clear answer,
            // the review runs as it always did.
            if let ref = modelRef(for: current), await askSkillGate(botID: botID, ref: ref, messages: messages[reviewFrom...]) == false {
                if !Task.isCancelled { session.skillReview = nil }
                return
            }
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            session.skillReview = nil
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
        let orb = bot(botID)?.name ?? "O Orb"
        if var current = skills(for: botID).first(where: { $0.slug == slug && $0.isImprovable }) {
            current.summary = proposal.summary
            current.instructions = proposal.instructions
            return SkillDraft(skill: current, slug: slug, botID: botID, orbName: orb, isUpdate: true)
        }
        var command = slug, suffix = 2
        while skills.contains(where: { $0.slug == command }) {
            command = "\(slug)-\(suffix)"
            suffix += 1
        }
        let skill = Skill(slug: command, name: proposal.name, summary: proposal.summary, instructions: proposal.instructions,
                          source: Skill.learnedSource, orbIDs: [botID], learnedBy: botID)
        return SkillDraft(skill: skill, slug: slug, botID: botID, orbName: orb, isUpdate: false)
    }

    /// The gate's verdict on the turn: true or false, nil when there is none (no cheap model, a failure, an unreadable
    /// answer) and the review should run. Cancelled, it also gives nil: the caller leaves on `Task.isCancelled`.
    private func askSkillGate(botID: UUID, ref: ModelRef, messages: ArraySlice<ChatMessage>) async -> Bool? {
        guard let account = account(ref.provider), account.isEnabled, isUsable(account),
              let model = Self.skillGate(in: account, orb: ref.model),
              let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == model },
                                                               credentials: Self.credentials(for: ref.provider),
                                                               conversationID: botID.uuidString + "-porteiro") else { return nil }
        let transcript = ChunkSummarizer.transcript(of: messages, characters: SkillReview.gateCharacters)
        let prompt = SkillReview.gatePrompt(transcript: transcript, skillNames: skills(for: botID).map { "/" + $0.slug })
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

    /// You decided: the proposal goes away. Saved, it is also said (VoiceOver) and the Orb is pleased.
    func finishSkillDraft(_ draft: SkillDraft, saved skill: Skill? = nil) {
        let bank = memory.bank(for: draft.botID)
        Task { await bank.discardProposal(draft.slug) }
        guard let skill else { return }
        announceForAccessibility("Skill /\(skill.slug) salva")
        sessions[draft.botID]?.celebrate(.light)
    }
}
