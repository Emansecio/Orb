import Foundation
import Observation

// Talking to an Orb while it works: what you send during a turn is queued, shown in the chat as waiting, and handed
// to the model at the next step boundary (Orb's own engine) or sent right after the turn (Claude Code, whose
// process takes one prompt per turn). Also the composer state that must outlive the composer view (attachments),
// which is rebuilt every time you switch Orb.

/// A file waiting to be sent with the next message. The size is read when it is attached, not when it is drawn.
struct AttachedFile: Identifiable, Equatable, Sendable {
    var url: URL
    var size: Int?
    /// The icon for its type.
    var symbol: String
    var id: URL { url }

    init(url: URL) {
        self.url = url
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        symbol = AttachmentKind.symbol(for: url)
    }

    var name: String { url.lastPathComponent }
}

/// What one Orb's composer holds that is not text: files and pictures to send, an attachment error, and the
/// messages queued during a turn. One observable object per Orb (like `BotLive`), so a change in one Orb's composer
/// re-renders nothing of another.
@MainActor
@Observable
final class ComposerLane {
    var files: [AttachedFile] = []
    /// Pictures already decoded, shrunk and saved (see `ImageStore`); they go with the message as images.
    var pictures: [ImageAttachment] = []
    var error: String?
    /// Messages sent during a turn that are not in the transcript yet, oldest first. This list is what the chat
    /// shows as "na fila"; `queue` is the copy the engine drains.
    private(set) var queued: [SteeredMessage] = []
    @ObservationIgnored let queue = SteeringQueue()

    var hasAttachments: Bool { !files.isEmpty || !pictures.isEmpty }

    func enqueue(_ message: SteeredMessage) {
        queued.append(message)
        queue.push(message)
    }

    /// The engine handed this message to the model (the transcript shows it now). nil when it is not queued.
    func delivered(_ id: UUID) -> SteeredMessage? {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return queued.remove(at: index)
    }

    /// The user took a message back. nil when it was already delivered (too late to change its mind).
    func withdraw(_ id: UUID) -> SteeredMessage? {
        guard queue.remove(id) != nil else { return nil }
        return delivered(id)
    }

    /// Everything that never reached the transcript, for sending again or giving back to the draft.
    func takeAll() -> [SteeredMessage] {
        _ = queue.drain()
        defer { queued = [] }
        return queued
    }
}

extension SteeredMessage {
    /// Several queued messages as one: their texts in order, one blank line apart, with all their attachments.
    static func merged(_ messages: [SteeredMessage]) -> SteeredMessage? {
        guard let first = messages.first else { return nil }
        guard messages.count > 1 else { return first }
        var files: [URL] = []
        for url in messages.flatMap(\.files) where !files.contains(url) { files.append(url) }
        return SteeredMessage(text: messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                              files: files, pictures: messages.flatMap(\.pictures),
                              prompt: messages.map(\.prompt).joined(separator: "\n\n"))
    }
}

extension AppModel {
    /// The composer state of one Orb, made when first asked for.
    func composerLane(_ botID: UUID) -> ComposerLane {
        if let lane = composerLanes[botID] { return lane }
        let lane = ComposerLane()
        composerLanes[botID] = lane
        return lane
    }

    /// Whether a message sent now is queued behind the running turn instead of starting one: the Orb is working on
    /// your chat (a routine's run has a conversation of its own, which a message cannot join).
    func canSteer(_ botID: UUID) -> Bool { turns[botID] != nil && routineTurns[botID] == nil }

    /// Whether a queued message reaches the model before the turn ends (Orb's own engine) and not only after it
    /// (Claude Code takes one prompt per process).
    func steersMidTurn(_ botID: UUID) -> Bool { canSteer(botID) && !claudeTurns.contains(botID) }

    /// The composer's send: starts a turn when the Orb is free, queues the message when it is working. Returns false
    /// when nothing was sent, so the composer keeps what you wrote.
    @discardableResult
    func submit(_ text: String, to botID: UUID) -> Bool {
        let lane = composerLane(botID)
        if !canSteer(botID) {
            let sent = send(text, attachments: lane.files.map(\.url), images: lane.pictures, to: botID, fromUser: true)
            if sent {
                lane.files.removeAll()
                lane.pictures.removeAll()
                lane.error = nil
            }
            return sent
        }
        return queueMessage(text, to: botID)
    }

    /// Queues a message for the running turn. The draft and the attachments leave the composer; the message shows in
    /// the chat as waiting until it is delivered.
    @discardableResult
    func queueMessage(_ text: String, to botID: UUID) -> Bool {
        let lane = composerLane(botID)
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteer(botID), !typed.isEmpty || !lane.pictures.isEmpty else { return false }
        let files = lane.files.map(\.url), pictures = lane.pictures
        // The skill's use is counted when the message is delivered (here or by `send`, which expands it again), not
        // now: a queued message may be delivered by either path and must count once.
        var prompt = SystemPrompt.expandSkill(in: typed, skills: skills(for: botID))?.prompt ?? typed
        if !files.isEmpty {
            prompt += "\n\nAttached files (read them with your tools):\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
        }
        if !pictures.isEmpty { prompt += Self.pictureNote(pictures, forClaudeCode: false, modelSees: nil) }
        // Asking to remember something mid-turn: the model is told to save it (the turn's grants were fixed when it
        // began, so saving may still ask for approval). Sent after the turn, `send` handles it as a message of its own.
        if steersMidTurn(botID), MemoryIntent.detect(typed) != nil {
            prompt += "\n\n(The user is asking you to remember something. Save it now with the remember tool, picking the "
                + "right tipo; if it refers to something said earlier, save that. Then confirm in one short sentence.)"
        }
        lane.enqueue(SteeredMessage(text: typed, files: files, pictures: pictures, prompt: prompt))
        live(botID).poked() // scrolls the chat down to the "na fila" bubble, which changes no transcript revision
        setDraft("", for: botID)
        lane.files.removeAll()
        lane.pictures.removeAll()
        lane.error = nil
        return true
    }

    /// Takes a queued message back into the composer (its text before what is typed now, its attachments with the
    /// current ones). Does nothing when it was delivered meanwhile.
    func unqueue(_ id: UUID, botID: UUID) {
        guard let message = composerLane(botID).withdraw(id) else { return }
        giveBack([message], to: botID)
    }

    /// "Parar e enviar": ends the turn now and sends what was queued (with the draft, when there is one) as the
    /// next message.
    func stopAndSend(_ botID: UUID, draft: String = "") {
        guard canSteer(botID) else {
            submit(draft, to: botID)
            return
        }
        let lane = composerLane(botID)
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lane.hasAttachments { queueMessage(draft, to: botID) }
        let waiting = lane.takeAll()
        stop(botID)
        guard let message = SteeredMessage.merged(waiting) else { return }
        if !send(message.text, attachments: message.files, images: message.pictures, to: botID) { giveBack(waiting, to: botID) }
    }

    /// A queued message reached the model: the chat shows it as sent, at the point where the model got it.
    func deliverSteered(_ id: UUID, to botID: UUID) {
        guard let message = composerLane(botID).delivered(id) else { return }
        countSkillUse(in: message.text)
        closeStreaming(botID)
        append(.user(text: message.text, attachments: message.attachmentPaths), to: botID)
        live(botID).poked()
    }

    /// Counts one use of the skill a message starts with (`/slug`), if it does.
    private func countSkillUse(in text: String) {
        guard let skill = SystemPrompt.expandSkill(in: text, skills: enabledSkills)?.skill,
              let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].uses += 1
    }

    /// The turn ended. What was queued and never reached the model is sent now as one message after a good ending;
    /// after a failure or a stop it goes back to the composer instead, so a broken turn is not followed by another
    /// one the user did not choose.
    func settleSteering(_ botID: UUID, succeeded: Bool) {
        guard let lane = composerLanes[botID], !lane.queued.isEmpty else { return }
        let waiting = lane.takeAll()
        guard succeeded, let message = SteeredMessage.merged(waiting),
              send(message.text, attachments: message.files, images: message.pictures, to: botID) else {
            giveBack(waiting, to: botID)
            return
        }
    }

    /// Puts messages back in the composer: their texts first, then what is already typed.
    private func giveBack(_ messages: [SteeredMessage], to botID: UUID) {
        guard let message = SteeredMessage.merged(messages) else { return }
        let lane = composerLane(botID)
        let current = drafts[botID, default: ""]
        setDraft(current.isEmpty ? message.text : message.text + "\n\n" + current, for: botID)
        for url in message.files where !lane.files.contains(where: { $0.url == url }) { lane.files.append(AttachedFile(url: url)) }
        lane.pictures += message.pictures
    }
}
