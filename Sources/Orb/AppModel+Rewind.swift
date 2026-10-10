import Foundation

// "Refazer" and "Editar": going back in the chat (see `Rewind.swift` for where the cut goes and what it forgets). Both
// end the same way: the conversation is cut, and the message is sent again as the next one, so the model sees a
// conversation that never had the discarded steps. "Refazer" sends the last request as it was; "Editar" puts a message
// of yours in the composer, and what is sent from there replaces it.

/// What is sent after the cut.
private struct RewindRequest {
    var text: String
    var files: [URL]
    var pictures: [ImageAttachment]
    /// The request counted a skill's use already (sending it again must not count it twice).
    var repeatsSkillUse: Bool
}

extension AppModel {
    // MARK: Whether

    /// Why nothing can be rewound in this Orb's chat right now, or nil. Not while it works, waits for a permission,
    /// loads, changes chat, or a routine holds it.
    func rewindRefusal(_ botID: UUID, ignoringFade: Bool = false) -> RewindRefusal? {
        guard let session = sessions[botID], bot(botID) != nil else { return .missing }
        if session.routineID != nil || session.parkedChat != nil { return .routine }
        if session.turnTask != nil || live(botID).isWorking || session.isLoading || session.isUnloaded
            || changingChat.contains(botID) || isResetting || (!ignoringFade && !live(botID).dropping.isEmpty) { return .busy }
        if !pendingApprovals(of: botID).isEmpty { return .approvalPending }
        return nil
    }

    /// Why the message `itemID` cannot be edited now, or nil.
    func editRefusal(itemID: UUID, of botID: UUID, ignoringFade: Bool = false) -> RewindRefusal? {
        if let refusal = rewindRefusal(botID, ignoringFade: ignoringFade) { return refusal }
        if (sessions[botID]?.lane?.pendingPictures ?? 0) > 0 { return .preparingPictures }
        guard let conversation = sessions[botID]?.conversation,
              let index = conversation.items.firstIndex(where: { $0.id == itemID }),
              case .user = conversation.items[index].kind else { return .missing }
        if conversation.items[index].duringTask == true { return .steered }
        switch conversation.rewindPoint(atItem: index, skills: skills(for: botID)) {
        case .failure(let refusal): return refusal
        case .success(let cut): return conversation.isSummarized(cut) ? .summarized : nil
        }
    }

    /// Why the last reply cannot be redone now, or nil.
    func regenerateRefusal(_ botID: UUID, ignoringFade: Bool = false) -> RewindRefusal? {
        if let refusal = rewindRefusal(botID, ignoringFade: ignoringFade) { return refusal }
        guard let conversation = sessions[botID]?.conversation, conversation.lastTurnRequestItem() != nil else { return .noReply }
        guard let start = conversation.lastTurnStart(skills: skills(for: botID)) else { return .unmatched }
        if start.hasSteeredMessages { return .steeredTurn }
        return conversation.isSummarized(start.cut) ? .summarized : nil
    }

    /// Whether editing `itemID` would drop actions that may have changed things on the Mac (worth a confirmation).
    func editDropsChanges(itemID: UUID, of botID: UUID) -> Bool {
        guard let conversation = sessions[botID]?.conversation,
              let index = conversation.items.firstIndex(where: { $0.id == itemID }) else { return false }
        return conversation.dropsChanges(from: index + 1)
    }

    /// The same for "Refazer": the steps of the last turn.
    func regenerateDropsChanges(_ botID: UUID) -> Bool {
        guard let conversation = sessions[botID]?.conversation,
              let start = conversation.lastTurnStart(skills: skills(for: botID)) else { return false }
        return conversation.dropsChanges(from: start.cut.itemIndex + 1)
    }

    /// Whether editing `itemID` drops something already saved to the memory (the confirmation says it stays).
    func editSavedToMemory(itemID: UUID, of botID: UUID) -> Bool {
        guard let conversation = sessions[botID]?.conversation,
              let index = conversation.items.firstIndex(where: { $0.id == itemID }) else { return false }
        return conversation.dropsSavedMemory(from: index)
    }

    /// The same for "Refazer": from the request on (the request itself stays and runs again).
    func regenerateSavedToMemory(_ botID: UUID) -> Bool {
        guard let conversation = sessions[botID]?.conversation,
              let start = conversation.lastTurnStart(skills: skills(for: botID)) else { return false }
        return conversation.dropsSavedMemory(from: start.cut.itemIndex + 1)
    }

    // MARK: Refazer

    /// "Refazer": the last reply and everything the turn added after your request leave the conversation, and the
    /// request runs again. `animated`: the rows that go fade out first (the cut happens when they have).
    @discardableResult
    func regenerateLastReply(_ botID: UUID, animated: Bool = false) -> Bool {
        guard regenerateRefusal(botID) == nil, let conversation = sessions[botID]?.conversation,
              let start = conversation.lastTurnStart(skills: skills(for: botID)),
              let request = rewindRequest(of: start.cut.itemIndex, in: conversation, botID: botID, keepingMissingFiles: true,
                                          repeatsSkillUse: true),
              hasUsableModel(botID) else { return false }
        let id = conversation.items[start.cut.itemIndex].id
        let tail = Set(conversation.items[(start.cut.itemIndex + 1)...].map(\.id))
        return rewind(botID, itemID: id, tail: tail, request: request, animated: animated, stillWanted: { true }, finished: { _ in })
    }

    // MARK: Editar

    /// Whether the composer holds a message being edited.
    func isEditing(_ botID: UUID) -> Bool { sessions[botID]?.lane?.editing != nil }

    /// "Editar": the message goes into the composer (its text and its attachments that are still there), and what the
    /// composer held waits until the edit ends. False when it cannot be edited.
    @discardableResult
    func beginEditing(itemID: UUID, of botID: UUID) -> Bool {
        let lane = composerLane(botID)
        if lane.editing?.itemID == itemID {
            request(.focusComposer, of: botID)
            return true
        }
        guard editRefusal(itemID: itemID, of: botID) == nil, let conversation = sessions[botID]?.conversation,
              let index = conversation.items.firstIndex(where: { $0.id == itemID }),
              let request = rewindRequest(of: index, in: conversation, botID: botID, keepingMissingFiles: false,
                                          repeatsSkillUse: false) else { return false }
        cancelEditing(botID) // another message was being edited: its stash goes back first
        let stash = ComposerDraft(text: drafts[botID] ?? "", files: lane.files.map(\.url.path), pictures: lane.pictures)
        lane.editing = MessageEdit(itemID: itemID, stash: stash, originalPictures: Set(request.pictures.map(\.path)))
        lane.files = request.files.map { AttachedFile(url: $0) }
        lane.pictures = request.pictures
        lane.error = nil
        setDraft(request.text, for: botID)
        self.request(.focusComposer, of: botID)
        return true
    }

    /// The edit is given up (Esc, the banner's button, another chat opening): the composer gets back what it held.
    func cancelEditing(_ botID: UUID) {
        guard let lane = sessions[botID]?.lane, let edit = lane.editing else { return }
        lane.editing = nil
        restore(edit.stash, in: lane, of: botID)
    }

    /// What is in the composer is sent in place of the message being edited: the message and everything after it leave
    /// the conversation and the turn runs from there. False (and the composer keeps its text) when nothing was sent.
    @discardableResult
    func submitEdit(_ text: String, to botID: UUID, animated: Bool = false) -> Bool {
        let lane = composerLane(botID)
        guard let edit = lane.editing else { return false }
        switch editRefusal(itemID: edit.itemID, of: botID) {
        case nil: break
        case .missing?: // the conversation changed under the edit
            cancelEditing(botID)
            return false
        default: return false
        }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lane.pendingPictures == 0, !typed.isEmpty || lane.hasAttachments, hasUsableModel(botID),
              let conversation = sessions[botID]?.conversation,
              let index = conversation.items.firstIndex(where: { $0.id == edit.itemID }) else { return false }
        let request = RewindRequest(text: typed, files: lane.files.map(\.url), pictures: lane.pictures, repeatsSkillUse: false)
        let tail = Set(conversation.items[(index + 1)...].map(\.id))
        return rewind(botID, itemID: edit.itemID, tail: tail, request: request, animated: animated,
                      stillWanted: { [weak self] in self?.sessions[botID]?.lane?.editing?.itemID == edit.itemID },
                      finished: { [weak self] sent in
                          guard sent, let self, let lane = self.sessions[botID]?.lane else { return }
                          lane.editing = nil
                          self.restore(edit.stash, in: lane, of: botID)
                      })
    }

    // MARK: The cut

    /// Cuts the chat before the message `itemID`, sends `request` and keeps that message's row (so an edited bubble
    /// changes where it is, and the rows after it fade away). Everything is put back when nothing could be sent.
    private func rewind(_ botID: UUID, itemID: UUID, tail: Set<UUID>, request: RewindRequest, animated: Bool,
                        stillWanted: @escaping @MainActor () -> Bool, finished: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard animated, !tail.isEmpty else {
            let sent = performRewind(botID, itemID: itemID, request: request)
            finished(sent)
            return sent
        }
        live(botID).setDropping(tail)
        Task { [weak self] in
            try? await Task.sleep(for: Motion.exitDuration)
            guard let self else { return }
            // Things may have changed in the 0.16 s (a routine came, the edit was given up): then nothing is cut.
            var sent = false
            if stillWanted(), self.rewindRefusal(botID, ignoringFade: true) == nil {
                sent = self.performRewind(botID, itemID: itemID, request: request)
            }
            self.live(botID).setDropping([])
            finished(sent)
        }
        return true
    }

    private func performRewind(_ botID: UUID, itemID: UUID, request: RewindRequest) -> Bool {
        guard let session = sessions[botID], let before = session.conversation,
              let index = before.items.firstIndex(where: { $0.id == itemID }),
              let cut = before.rewindCut(atItem: index, skills: skills(for: botID)), !before.isSummarized(cut) else { return false }
        let row = before.items[index]
        session.cancelChunkNote() // a note on a stretch of the conversation that is going
        session.chunkAttempts = [:]
        editConversation(botID) { $0.rewind(to: cut) }
        // The new message takes the row of the old one (no bubble leaves and another arrives), and the model's copy of it
        // is tied to that row.
        guard send(request.text, attachments: request.files, images: request.pictures, to: botID, bubble: row.id, endsEdit: false) else {
            session.conversation = before // nothing was sent (no usable model): the chat is as it was
            scheduleConversationSave(botID, delay: 0.3)
            return false
        }
        if request.repeatsSkillUse, let skill = SystemPrompt.expandSkill(in: request.text, skills: skills(for: botID))?.skill,
           let at = skills.firstIndex(where: { $0.id == skill.id }), skills[at].uses > 0 {
            skills[at].uses -= 1 // the first run counted it
        }
        live(botID).scrolled() // the click is yours: the chat follows the new answer
        return true
    }

    /// The text, files and pictures of your message at `index`, as they would be sent again.
    private func rewindRequest(of index: Int, in conversation: Conversation, botID: UUID, keepingMissingFiles: Bool,
                               repeatsSkillUse: Bool) -> RewindRequest? {
        guard case .user(let text, let attachments) = conversation.items[index].kind else { return nil }
        // The model's copy of the message knows which attachments were pictures (the transcript keeps only paths).
        let message = conversation.requestMessageIndices(skills: skills(for: botID))[index].map { conversation.messages[$0] }
        let isThere: (String) -> Bool = { keepingMissingFiles || FileManager.default.fileExists(atPath: $0) }
        var pictures = (message?.images ?? []).filter { isThere($0.path) }
        var pictured = Set((message?.images ?? []).map(\.path))
        if message == nil {
            // A request that never reached the model has no copy to say which of its attachments were pictures: the ones in
            // the store of pictures are (files are never kept there).
            for path in attachments {
                guard let picture = images.attachment(forStoredPath: path) else { continue }
                pictured.insert(path)
                if isThere(path) { pictures.append(picture) }
            }
        }
        // A name with no folder is an attachment from before paths were kept: there is nothing to attach again.
        let files = attachments.filter { !pictured.contains($0) && $0.hasPrefix("/") && isThere($0) }
        return RewindRequest(text: text, files: files.map { URL(fileURLWithPath: $0) }, pictures: pictures, repeatsSkillUse: repeatsSkillUse)
    }

    private func restore(_ draft: ComposerDraft, in lane: ComposerLane, of botID: UUID) {
        setDraft(draft.text, for: botID)
        lane.files = draft.files.filter { FileManager.default.fileExists(atPath: $0) }.map { AttachedFile(url: URL(fileURLWithPath: $0)) }
        lane.pictures = draft.pictures.filter { FileManager.default.fileExists(atPath: $0.path) }
        lane.error = nil
    }
}
