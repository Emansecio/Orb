import SwiftUI

/// Orb creates Orb (`orb_propose`): what the app knows for the proposal, the creation once the person says "Criar", and the
/// edits of "Editar antes" (docs/historico/MULTI-ORBS.md 4).
extension AppModel {
    /// What `orb_propose` needs for `bot`: who it is, the Orbs there are, and how to create the one the person accepts.
    func orbCreationSupport(for bot: Bot) -> OrbCreationSupport {
        let creatorID = bot.id
        return OrbCreationSupport(
            creator: bot, existingNames: bots.map(\.name),
            withoutCard: orbsCreateWithoutAsking,
            roles: Dictionary(bots.map { ($0.name, $0.role) }, uniquingKeysWith: { first, _ in first }),
            create: { [weak self] approvalID, proposal in
                guard let self else { return .failed("O app está fechando.") }
                return await self.createProposedOrb(proposal, approvalID: approvalID, by: creatorID)
            })
    }

    /// The creator's "Desfazer": whether the Orb it made can still be taken back without losing anything: it exists, an Orb made
    /// it, its own chat is empty and it is not working.
    func canUndoCreation(of botID: UUID) -> Bool {
        guard let created = bot(botID), created.createdBy != nil, liveBot(botID)?.isWorking != true else { return false }
        // Its greeting is not talk: `messages` holds only what went to or came from the model.
        return sessions[botID]?.conversation?.messages.isEmpty ?? true
    }

    /// Deletes the Orb the creator's line offers to undo (the click is the person's, so no card). Its memory goes too: it never
    /// had a conversation to remember.
    func undoCreation(of botID: UUID) {
        sessions[botID]?.ensureLoaded() // the line may be shown before the conversation is read: check what is really there
        guard canUndoCreation(of: botID) else { return }
        deleteBot(botID)
    }

    /// The proposal as the card of `approvalID` holds it now (what "Editar antes" changed), nil when the card is gone.
    func heldProposal(_ approvalID: UUID, of botID: UUID) -> OrbProposal? {
        ensureLoaded(botID)
        for item in (sessions[botID]?.conversation?.items ?? []).reversed() {
            if case .approval(let request) = item.kind, request.id == approvalID { return request.proposal }
        }
        return nil
    }

    /// "Editar antes" is done: the card keeps what the person typed, so "Criar" creates that. Only an open card changes.
    func updateProposal(_ proposal: OrbProposal, approvalID: UUID, botID: UUID) {
        var proposal = proposal
        proposal.nameTaken = isOrbNameTaken(proposal.name)
        session(botID).mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID, request.decision == nil {
                    request.proposal = proposal
                    items[index].kind = .approval(request)
                }
            }
        }
    }

    /// An Orb already has this name (accents, case and spacing aside, as delegation tells names apart): creating or renaming
    /// to it is refused.
    /// `excluding`: the Orb being renamed, which may keep its own name (or change its case).
    func isOrbNameTaken(_ name: String, excluding: UUID? = nil) -> Bool {
        let wanted = DelegationRules.fold(OrbProposal.clippedName(name))
        // A group is reached by name from the chat (`orbs ask`): an Orb with that name would shadow it.
        return bots.contains { $0.id != excluding && DelegationRules.fold($0.name) == wanted }
            || groups.contains { DelegationRules.fold($0.name) == wanted }
    }

    /// `name`, or "name 2", "name 3"… when it is taken: for Orbs nobody named by hand (Atlas, a draft), which must not fail.
    func uniqueOrbName(_ name: String) -> String {
        var candidate = name
        var number = 2
        while isOrbNameTaken(candidate) {
            let suffix = " \(number)"
            candidate = String(name.prefix(AppModel.nameLimit - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            number += 1
        }
        return candidate
    }

    /// Creates the Orb the person accepted, as the card holds it, and answers for the model. The Orb gets its own folder and no
    /// connectors, never more than the creator can hand down, and a note of where it came from; the creator's chat gets the line
    /// "Atlas criou o Pesquisador". The selection stays on the creator's chat (the person is reading it); the new row arrives
    /// in the sidebar by itself and its Orb gives its little hop.
    /// `proposal`: what the engine proposed, to tell what the person changed.
    @discardableResult
    func createProposedOrb(_ proposal: OrbProposal, approvalID: UUID, by creatorID: UUID) -> ProposalOutcome {
        guard let creator = bot(creatorID) else { return .failed("The Orb that proposed it no longer exists.") }
        var final = (heldProposal(approvalID, of: creatorID) ?? proposal).clamped()
        // Held to the creator as it is now, not as it was when the card opened.
        final.capabilities.formIntersection(creator.capabilities)
        final.modeCeiling = OrbProposal.lesser(final.modeCeiling, OrbProposal.ceiling(forCreatorMode: creator.permissionMode))
        if !final.allowedModes.contains(final.mode) { final.mode = final.allowedModes.last ?? .ask }

        // The card waits for another name; this is for a decision that arrives anyway (a shortcut, an edit that raced).
        if isOrbNameTaken(final.name) {
            markNotCreated(approvalID, of: creatorID, reason: "Já existe um Orb com esse nome")
            return .failed("An Orb named \"\(final.name)\" already exists. Propose another name.")
        }
        let previous = selection
        let bot = createBot(name: final.name, role: final.role, orb: final.orb, model: final.model, mode: final.mode,
                            identity: final.instructions, interview: false, folder: .own, base: proposedOrbFolderBase)
        selection = previous
        update(bot.id) {
            $0.capabilities = final.capabilities
            $0.createdBy = creator.id
            $0.createdByName = creator.name
            $0.createdAt = .now
        }
        // A routine's run, a request or a group's turn works on a conversation of its own: the line belongs in the creator's chat.
        let line = TranscriptItem.Kind.event(OrbEvent(kind: .orbCreated, actor: OrbRef(creator), subject: OrbRef(bot)))
        if isOwnChat(creatorID) { append(line, to: creatorID) } else { appendToChat(line, of: creatorID) }
        announceForAccessibility("\(creator.name) criou \(PortugueseArticle.article(for: bot.name)) \(bot.name)")
        landLater(bot.id)

        let folder = bot.workingDirectory.isEmpty ? "~" : OrbFolder.display(bot.workingURL)
        let changes = final.changes(from: proposal)
        return changes.isEmpty ? .created(name: bot.name, folder: folder)
            : .createdEdited(name: bot.name, folder: folder, summary: changes)
    }

    /// The card said "Criar" (or "Liberar") but nothing came of it: its record says so instead of "Criado".
    func markNotCreated(_ approvalID: UUID, of botID: UUID, reason: String) {
        session(botID).mutateItems { items in
            for index in items.indices {
                if case .approval(var request) = items[index].kind, request.id == approvalID {
                    request.decision = .deny
                    request.note = reason
                    items[index].kind = .approval(request)
                }
            }
        }
    }

    /// The new Orb's sidebar avatar gives its birth hop once its row is on screen (a beat after the row arrives).
    private func landLater(_ botID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.liveBot(botID)?.landed()
        }
    }
}
