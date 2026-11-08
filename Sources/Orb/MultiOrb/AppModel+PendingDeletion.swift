import Foundation

// A deletion an Orb asked for in a turn nobody watches (a routine's run, the pulse, another Orb's request): a card there would
// hold the Orb for a day, so its chat gets a line with Apagar and Manter instead, and the turn goes on. Only that click
// deletes (`answerDeletion`), checked again by id, never by name: what the Orb asked about is what goes, or nothing.

/// What an Orb asked to delete.
enum DeletionAsk: Equatable, Sendable {
    case orb(OrbRef)
    case group(id: UUID, name: String)
    /// Taking `orb` out of the group, which ends it (it would be left with one Orb).
    case removeMember(OrbRef, groupID: UUID, groupName: String)

    /// The same ask from the same Orb is written once while it waits.
    var key: String {
        switch self {
        case .orb(let orb): "orb:\(orb.id.uuidString)"
        case .group(let id, _): "group:\(id.uuidString)"
        case .removeMember(let orb, let id, _): "remove:\(orb.id.uuidString):\(id.uuidString)"
        }
    }

    /// The line of the chat: `subject` the Orb, `groupID` and `detail` the group; both for taking a member out.
    func event(by requester: OrbRef, text: String) -> OrbEvent {
        switch self {
        case .orb(let orb): OrbEvent(kind: .deletionAsked, actor: requester, subject: orb, note: text)
        case .group(let id, let name): OrbEvent(kind: .deletionAsked, actor: requester, detail: name, groupID: id, note: text)
        case .removeMember(let orb, let id, let name):
            OrbEvent(kind: .deletionAsked, actor: requester, subject: orb, detail: name, groupID: id, note: text)
        }
    }

    /// The ask a line stands for (`deletionAsked` or `deletionAnswered`).
    init?(event: OrbEvent) {
        switch (event.subject, event.groupID) {
        case (let orb?, let group?): self = .removeMember(orb, groupID: group, groupName: event.detail ?? "")
        case (let orb?, nil): self = .orb(orb)
        case (nil, let group?): self = .group(id: group, name: event.detail ?? "")
        case (nil, nil): return nil
        }
    }
}

extension AppModel {
    /// Writes the ask in the requester's chat and says to the model what happened (in English: it goes back as the tool's text).
    func askDeletionLater(_ ask: DeletionAsk, by botID: UUID, text: String) -> String {
        guard let requester = bot(botID) else { return "This Orb no longer exists." }
        let key = botID.uuidString + "|" + ask.key
        guard !askedDeletions.contains(key) else {
            return "The user was already asked in your chat; nothing was deleted yet. Do not ask again: go on with the rest."
        }
        guard appendToChat(.event(ask.event(by: OrbRef(requester), text: text)), of: botID) != nil else {
            return "The user could not be asked now: say in your reply what you would delete and why."
        }
        askedDeletions.insert(key)
        return "Asked the user in your chat (a line with Apagar and Manter); nothing was deleted. Do not ask again: go on with the rest."
    }

    /// The line still waits for the person, and what it asks about is still there to delete.
    func canAnswerDeletion(_ event: OrbEvent) -> Bool {
        guard event.kind == .deletionAsked, event.outcome == nil, let ask = DeletionAsk(event: event) else { return false }
        return stillApplies(ask)
    }

    /// By id, and under the name the line shows: after a rename the person would be saying yes to a name that is not there.
    private func stillApplies(_ ask: DeletionAsk) -> Bool {
        func same(_ a: String?, _ b: String) -> Bool { a.map { DelegationRules.fold($0) == DelegationRules.fold(b) } ?? false }
        switch ask {
        case .orb(let orb): return same(bot(orb.id)?.name, orb.name)
        case .group(let id, let name): return same(group(id)?.name, name)
        case .removeMember(let orb, let id, let name):
            guard let group = group(id), group.memberIDs.contains(orb.id) else { return false }
            return same(group.name, name) && same(bot(orb.id)?.name, orb.name)
        }
    }

    /// The person's click on the line `item` of `botID`'s chat on show: Apagar (`accept`) or Manter. The line keeps how it
    /// ended, and a second line tells the Orb in its next turn (`SinceLastTurn`), so it does not ask again.
    func answerDeletion(_ shown: OrbEvent, item: UUID, of botID: UUID, accept: Bool) {
        // The line as the chat has it now, not as the view drew it: a second click before the redraw finds it answered.
        let owner = self.session(botID), chat = owner.chatID
        // The chat on show is the session's conversation, or parked aside while a turn works elsewhere (`changeChat`).
        let onShow = chat == owner.conversationChat ? owner.conversation : owner.parkedChat
        guard case .event(let event)? = onShow?.items.first(where: { $0.id == item })?.kind, event == shown,
              event.kind == .deletionAsked, event.outcome == nil, let ask = DeletionAsk(event: event), !isResetting else { return }
        var outcome: OrbEvent.Outcome = accept ? .finished : .failed
        if accept {
            if !stillApplies(ask) {
                outcome = .attention
            } else {
                switch ask {
                case .orb(let orb):
                    // The same check as the card's: an Orb at work is not deleted under its feet.
                    guard liveBot(orb.id)?.isWorking != true, sessions[orb.id]?.turnTask == nil else {
                        appendToChat(.notice("\(orb.name) está trabalhando agora: apague quando terminar."), of: botID,
                                     in: chat)
                        return
                    }
                    deleteBot(orb.id)
                case .group(let id, _):
                    deleteGroup(id)
                case .removeMember(let orb, let id, _):
                    if !removeMember(orb.id, from: id) { outcome = .attention }
                }
            }
        }
        let ended = outcome
        owner.changeChat(chat) { conversation in
            guard let index = conversation.items.firstIndex(where: { $0.id == item }),
                  case .event(var line) = conversation.items[index].kind else { return }
            line.outcome = ended
            conversation.items[index].kind = .event(line)
        }
        var answered = event
        answered.kind = .deletionAnswered
        answered.outcome = outcome
        appendToChat(.event(answered), of: botID, in: chat)
        if let actor = event.actor { askedDeletions.remove(actor.id.uuidString + "|" + ask.key) }
    }
}
