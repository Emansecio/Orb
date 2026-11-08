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
        switch isKept(key) && stillApplies(ask) ? .kept : standingAnswer(ask, key: key, of: botID) {
        case .waiting:
            return "The user was already asked in your chat; nothing was deleted yet. Do not ask again: go on with the rest."
        case .kept:
            return "The user already chose to keep it (Manter): nothing was deleted. Do not ask again unless the user asks."
        case nil:
            break
        }
        guard let line = appendToChat(.event(ask.event(by: OrbRef(requester), text: text)), of: botID) else {
            return "The user could not be asked now: say in your reply what you would delete and why."
        }
        askedDeletions[key] = (line.chat, line.item, false)
        return "Asked the user in your chat (a line with Apagar and Manter); nothing was deleted. Do not ask again: go on with the rest."
    }

    /// Where an ask stands with the person: a line still waits for the click, or they chose Manter.
    enum StandingAnswer { case waiting, kept }

    /// The Manter answers, by "Orb id|ask key", kept across launches: the line may be in a conversation not read after a
    /// relaunch, and the runs that ask would ask again. Each lasts `keptFor`; a reset clears them with the preferences.
    static let keptDeletionsKey = "keptDeletions"
    static let keptFor: TimeInterval = 30 * 86_400

    private var keptDeletions: [String: Date] {
        get { preferences.dictionary(forKey: Self.keptDeletionsKey) as? [String: Date] ?? [:] }
        set { preferences.set(newValue.isEmpty ? nil : newValue, forKey: Self.keptDeletionsKey) }
    }

    private func isKept(_ key: String, now: Date = .now) -> Bool {
        keptDeletions[key].map { now.timeIntervalSince($0) < Self.keptFor } ?? false
    }

    /// The same ask waits for the person on a line they can still answer, or they answered Manter: the runs that ask (a
    /// routine's, the pulse's) are never handed the chat's lines, so without this every run would ask again. The line is
    /// looked at where it is in memory: one gone with its conversation, or no longer valid (a rename, the target gone), does
    /// not count; after a relaunch (nothing remembered) the chat on show is read. A line in a conversation not in memory is trusted.
    private func standingAnswer(_ ask: DeletionAsk, key: String, of botID: UUID) -> StandingAnswer? {
        if let line = askedDeletions[key] {
            guard isChat(line.chat, of: botID), stillApplies(ask) else { askedDeletions[key] = nil; return nil }
            guard let chat = loadedChat(line.chat, of: botID) else { return line.kept ? .kept : .waiting }
            if case .event(let event)? = chat.items.first(where: { $0.id == line.item })?.kind, let standing = standing(event) {
                return standing
            }
            askedDeletions[key] = nil
            return nil
        }
        let chat = latestChat(of: botID)
        // The newest line about this ask decides: a later ask after a Manter is the one that counts.
        guard let last = loadedChat(chat, of: botID)?.items.last(where: { item in
            guard case .event(let event) = item.kind, event.actor?.id == botID,
                  event.kind == .deletionAsked || event.kind == .deletionAnswered else { return false }
            return DeletionAsk(event: event)?.key == ask.key
        }), case .event(let event) = last.kind, let standing = standing(event) else { return nil }
        askedDeletions[key] = (chat, last.id, standing == .kept)
        return standing
    }

    /// What a line of the chat says of its ask: still waiting (and answerable), or kept by the person.
    private func standing(_ event: OrbEvent) -> StandingAnswer? {
        if event.kind == .deletionAnswered, event.outcome == .failed {
            return DeletionAsk(event: event).map(stillApplies) == true ? .kept : nil
        }
        return canAnswerDeletion(event) ? .waiting : nil
    }

    /// The conversation `chat` of the Orb if it is in memory: the one the turn machinery has, or the one on show parked aside.
    private func loadedChat(_ chat: UUID, of botID: UUID) -> Conversation? {
        guard let session = sessions[botID] else { return nil }
        if chat == session.conversationChat, !session.isUnloaded { return session.conversation }
        if chat == session.chatID { return session.parkedChat }
        return nil
    }

    /// The Orb was deleted: what it asked, and what was asked about it, is not waited on any more.
    func forgetAskedDeletions(of botID: UUID) {
        let id = botID.uuidString
        askedDeletions = askedDeletions.filter { !$0.key.contains(id) }
        let kept = keptDeletions
        if kept.keys.contains(where: { $0.contains(id) }) { keptDeletions = kept.filter { !$0.key.contains(id) } }
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
            // The line says the group ends: with a third member come since, taking the Orb out would be another thing.
            guard let group = group(id), group.memberIDs.contains(orb.id),
                  group.memberIDs.count <= OrbGroup.memberLimits.lowerBound else { return false }
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
                        let busy = "\(orb.name) está trabalhando agora: apague quando terminar."
                        // Said once, however many times Apagar is clicked meanwhile.
                        if onShow?.items.last?.kind != .notice(busy) { appendToChat(.notice(busy), of: botID, in: chat) }
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
        let line = appendToChat(.event(answered), of: botID, in: chat)
        // Manter is remembered, so the Orb's next unattended run is told no instead of asking again.
        if let actor = event.actor {
            let key = actor.id.uuidString + "|" + ask.key
            askedDeletions[key] = outcome == .failed ? line.map { ($0.chat, $0.item, true) } : nil
            let now = Date.now
            var kept = keptDeletions.filter { now.timeIntervalSince($0.value) < Self.keptFor } // the old ones go as a new one comes
            kept[key] = outcome == .failed ? now : nil
            keptDeletions = kept
        }
    }
}
