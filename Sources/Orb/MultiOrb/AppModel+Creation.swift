import SwiftUI

/// Orb creates Orb (`orb_propose`): what the app knows for the proposal, the creation once the person says "Criar", and the
/// edits of "Editar antes" (docs/historico/MULTI-ORBS.md 4).
extension AppModel {
    /// What `orb_propose` needs for `bot`: who it is, the Orbs there are, and how to create the one the person accepts.
    func orbCreationSupport(for bot: Bot) -> OrbCreationSupport {
        let creatorID = bot.id
        return OrbCreationSupport(
            creator: bot, existingNames: bots.map(\.name),
            createdByCreator: bots.filter { $0.createdBy == creatorID }.count,
            createdTotal: bots.filter { $0.createdBy != nil }.count,
            create: { [weak self] approvalID, proposal in
                guard let self else { return .failed("O app está fechando.") }
                return await self.createProposedOrb(proposal, approvalID: approvalID, by: creatorID)
            })
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

    /// An Orb already has this name (accents and case aside): the new Orb's folder then gets another name.
    func isOrbNameTaken(_ name: String) -> Bool {
        let fold = { (text: String) in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let wanted = fold(OrbProposal.clippedName(name))
        return bots.contains { fold($0.name) == wanted }
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
        let own = bots.filter { $0.createdBy == creatorID }.count, total = bots.filter { $0.createdBy != nil }.count
        if let limit = OrbProposal.refusal(creatorMode: .ask, createdByCreator: own, createdTotal: total) {
            markNotCreated(approvalID, of: creatorID, reason: "Limite de Orbs criados por Orbs")
            return .failed(limit)
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
        append(.event(OrbEvent(kind: .orbCreated, actor: OrbRef(creator), subject: OrbRef(bot))), to: creatorID)
        announceForAccessibility("\(creator.name) criou \(PortugueseArticle.article(for: bot.name)) \(bot.name)")
        landLater(bot.id)

        let folder = bot.workingDirectory.isEmpty ? "~" : OrbFolder.display(bot.workingURL)
        let changes = final.changes(from: proposal)
        return changes.isEmpty ? .created(name: bot.name, folder: folder)
            : .createdEdited(name: bot.name, folder: folder, summary: changes)
    }

    /// The card said "Criar" but the Orb could not be made: its record says so instead of "Criado".
    private func markNotCreated(_ approvalID: UUID, of botID: UUID, reason: String) {
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
