import Foundation
import Observation

// Talking to an Orb while it works: what you send during a turn waits, shown in the chat with where it is going.
// Two modes (`SteeringDelivery`): ↩ steers (Orb's own engine hands it to the model at the next step boundary) and ⇥ queues
// it for after the task (it goes as the next request when the turn ends well). Also the composer state that must outlive the composer view (attachments),
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

/// What an Orb's composer holds that was not sent, as it is kept between launches (`rascunhos.json`): the text, and the
/// paths of the files and pictures attached to it.
struct ComposerDraft: Codable, Equatable, Sendable {
    var text = ""
    var files: [String] = []
    var pictures: [ImageAttachment] = []

    var isEmpty: Bool { files.isEmpty && pictures.isEmpty && text.allSatisfy(\.isWhitespace) }

    /// Takes back text, files and pictures that were refused or never sent: the text goes before what is already
    /// there, and a file already attached is not added twice.
    mutating func putBack(text back: String, separator: String, files backFiles: [String] = [], pictures backPictures: [ImageAttachment] = []) {
        if !back.isEmpty { text = text.isEmpty ? back : back + separator + text }
        for path in backFiles where !files.contains(path) { files.append(path) }
        pictures += backPictures
    }
}

/// A message of the chat being edited in the composer: what the composer held before (put back when the edit ends, one
/// way or the other) and the pictures the message came with (their files belong to the conversation, so taking one
/// out of the strip must not delete it).
struct MessageEdit: Equatable, Sendable {
    var itemID: UUID
    var stash: ComposerDraft
    var originalPictures: Set<String>
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

    /// Attaches the files and pictures of a saved draft that are still on disk.
    func attachExisting(files paths: [String], pictures saved: [ImageAttachment]) {
        files = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { AttachedFile(url: URL(fileURLWithPath: $0)) }
        pictures = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Pictures pasted or dropped that are still being shrunk and saved off the main thread. Sending waits for 0.
    var pendingPictures = 0
    /// The pictures being prepared, in the order they were attached: one that is ready waits for the ones attached
    /// before it, so a small picture never jumps ahead of a big one ("compare a primeira com a segunda").
    @ObservationIgnored private var arriving: [(id: UUID, picture: ImageAttachment?, done: Bool)] = []
    /// The message of the chat that the composer is editing, if it is (see `AppModel+Rewind`).
    var editing: MessageEdit?
    /// Messages sent during a turn that are not in the transcript yet, oldest first. This list is what the chat
    /// shows as "na fila"; `queue` is the copy the engine drains.
    private(set) var queued: [SteeredMessage] = []
    @ObservationIgnored let queue = SteeringQueue()

    var hasAttachments: Bool { !files.isEmpty || !pictures.isEmpty }

    /// Holds a place for a picture about to be prepared.
    func reservePicture() -> UUID {
        let id = UUID()
        arriving.append((id, nil, false))
        pendingPictures += 1
        return id
    }

    /// The picture of `id` is ready (nil: it failed): it and the ones after it that are ready join in order.
    func pictureArrived(_ id: UUID, _ picture: ImageAttachment?) {
        if let index = arriving.firstIndex(where: { $0.id == id }) { arriving[index] = (id, picture, true) }
        while let first = arriving.first, first.done {
            arriving.removeFirst()
            if let picture = first.picture { pictures.append(picture) }
        }
        pendingPictures -= 1
    }

    /// The chip's text while pictures are prepared.
    nonisolated static func preparingText(_ count: Int) -> String { count == 1 ? "Preparando imagem…" : "Preparando \(count) imagens…" }

    func enqueue(_ message: SteeredMessage) {
        queued.append(message)
        queue.push(message)
    }

    /// The engine handed this message to the model (the transcript shows it now). nil when it is not queued.
    func delivered(_ id: UUID) -> SteeredMessage? {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return queued.remove(at: index)
    }

    /// Changes where a waiting message goes. False when it already left (delivered, or taken back): too late.
    func setDelivery(_ id: UUID, to delivery: SteeringDelivery) -> Bool {
        guard queue.setDelivery(id, to: delivery), let index = queued.firstIndex(where: { $0.id == id }) else { return false }
        queued[index].delivery = delivery
        return true
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
    /// The unsent drafts of the Orbs that exist: the text of the composer and its attachments. A message still queued
    /// for a running turn is in neither until the turn ends (`settleSteering` gives it back).
    func composerDrafts() -> [UUID: ComposerDraft] {
        var result: [UUID: ComposerDraft] = [:]
        for bot in bots {
            let lane = sessions[bot.id]?.lane
            // An edit under way is not a draft: what the composer held before it is what is kept.
            if let stash = lane?.editing?.stash {
                if !stash.isEmpty { result[bot.id] = stash }
                continue
            }
            let draft = ComposerDraft(text: drafts[bot.id] ?? "", files: lane?.files.map(\.url.path) ?? [], pictures: lane?.pictures ?? [])
            if !draft.isEmpty { result[bot.id] = draft }
        }
        // A group's composer has only text, kept under the group's id.
        for group in groups {
            let draft = ComposerDraft(text: drafts[group.id] ?? "")
            if !draft.isEmpty { result[group.id] = draft }
        }
        return result
    }

    /// Takes back what the last launch left in the composers, without the files and pictures that are gone.
    func restoreDrafts() {
        let saved = store.readDrafts()
        savedDrafts = saved
        for bot in bots {
            guard let draft = saved[bot.id] else { continue }
            if !draft.text.isEmpty { drafts[bot.id] = draft.text }
            let lane = composerLane(bot.id)
            lane.attachExisting(files: draft.files, pictures: draft.pictures)
        }
        for group in groups {
            if let text = saved[group.id]?.text, !text.isEmpty { drafts[group.id] = text }
        }
    }

    /// Writes the drafts when they differ from what is on disk (quit, and the scheduler's rounds).
    func saveDraftsIfChanged() {
        let current = composerDrafts()
        guard current != savedDrafts else { return }
        savedDrafts = current
        store.saveDrafts(current)
    }

    /// The composer state of one Orb, made when first asked for (it lives in the Orb's session).
    func composerLane(_ botID: UUID) -> ComposerLane { session(botID).composerLane() }

    /// Whether a message sent now is queued behind the running turn instead of starting one: the Orb is working on
    /// your chat (a routine's run has a conversation of its own, which a message cannot join).
    func canSteer(_ botID: UUID) -> Bool {
        guard let session = sessions[botID] else { return false }
        return session.turnTask != nil && session.routineID == nil
    }

    /// The name of the routine whose run holds this Orb, if one does.
    func runningRoutineName(_ botID: UUID) -> String? {
        sessions[botID]?.routineID.flatMap { id in routines.first { $0.id == id }?.name }
    }

    /// The composer's send: starts a turn when the Orb is free, queues the message when it is working. Returns false
    /// when nothing was sent, so the composer keeps what you wrote.
    @discardableResult
    func submit(_ text: String, to botID: UUID, delivery: SteeringDelivery = .steer) -> Bool {
        let lane = composerLane(botID)
        guard lane.pendingPictures == 0 else { return false } // a picture still on its way would miss this message
        if lane.editing != nil { return submitEdit(text, to: botID) } // the composer holds a message being edited
        if !canSteer(botID) {
            let sent = send(text, attachments: lane.files.map(\.url), images: lane.pictures, to: botID, fromUser: true)
            if sent {
                lane.files.removeAll()
                lane.pictures.removeAll()
                lane.error = nil
            }
            return sent
        }
        // The Orb waits on a question of its own (`ask_user`): what is written answers it, instead of waiting behind it. Not a
        // command, nor a message with files or longer than an answer keeps: those stay messages.
        if delivery == .steer, lane.files.isEmpty, lane.pictures.isEmpty, CompactionCommand.parse(text) == nil,
           text.count <= OrbQuestion.answerLimit, let reply = OrbQuestion.clean(text), let question = openQuestion(of: botID) {
            decide(.once, reply: reply, approvalID: question, botID: botID)
            setDraft("", for: botID)
            return true
        }
        // "/compactar" is a command of the composer, not a message: queued, it would reach the model as one. It waits in
        // the composer for the end of the turn, as `send` runs it (which it does only without attachments).
        if lane.files.isEmpty, lane.pictures.isEmpty, CompactionCommand.parse(text) != nil {
            append(.notice(Self.compactionBusyMessage), to: botID)
            return false
        }
        return queueMessage(text, to: botID, delivery: delivery)
    }

    /// Queues a message for the running turn: into the task (`.steer`) or after it. The draft and the attachments leave
    /// the composer; the message shows in the chat as waiting until it is delivered.
    @discardableResult
    func queueMessage(_ text: String, to botID: UUID, delivery: SteeringDelivery = .steer) -> Bool {
        let lane = composerLane(botID)
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteer(botID), !typed.isEmpty || !lane.pictures.isEmpty || !lane.files.isEmpty else { return false }
        enqueue(typed, files: lane.files.map(\.url), pictures: lane.pictures, delivery: delivery, to: botID)
        // Attachments alone (nothing typed) must not take a draft with real text along; a blank one is cleared.
        if !typed.isEmpty || (drafts[botID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setDraft("", for: botID) }
        lane.files.removeAll()
        lane.pictures.removeAll()
        lane.error = nil
        return true
    }

    /// Queues a message that does not come from the composer (the menu bar panel): the composer's draft and
    /// attachments are not part of it and stay where they are.
    @discardableResult
    func queueOutsideComposer(_ text: String, to botID: UUID) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteer(botID), !typed.isEmpty else { return false }
        enqueue(typed, files: [], pictures: [], delivery: .steer, to: botID)
        return true
    }

    private func enqueue(_ typed: String, files: [URL], pictures: [ImageAttachment], delivery: SteeringDelivery, to botID: UUID) {
        let lane = composerLane(botID)
        // The skill's use is counted when the message is delivered (here or by `send`, which expands it again), not
        // now: a queued message may be delivered by either path and must count once.
        var prompt = SystemPrompt.expandSkill(in: typed, skills: skills(for: botID))?.prompt
            ?? (typed.isEmpty && pictures.isEmpty ? Self.attachmentsOnlyPrompt : typed)
        if !pictures.isEmpty { prompt += Self.pictureNote(pictures, modelSees: nil) }
        // Asking to remember something mid-turn: the model is told to save it (the turn's grants were fixed when it
        // began, so saving may still ask for approval). Sent after the turn, `send` handles it as a message of its own.
        if MemoryIntent.detect(typed) != nil {
            prompt += MemoryIntent.instruction(tool: "remember")
        }
        // The files' text as far as it is read already (it is, unless they were attached a moment ago): the rest is left to the tools.
        let room = AttachmentText.room(historyCharacters: bot(botID).flatMap(contextBudget(for:))?.characters ?? ContextBudget.fallback.characters)
        prompt += AttachmentText.block(for: files, texts: attachmentTexts.cached(files), room: room)
        lane.enqueue(SteeredMessage(text: typed, files: files, pictures: pictures, prompt: prompt, delivery: delivery))
        live(botID).scrolled() // scrolls the chat down to the "na fila" bubble, which changes no transcript revision
    }

    /// Moves a waiting message between "into the task" and "after the task". Does nothing when it was delivered meanwhile.
    func switchDelivery(_ id: UUID, botID: UUID) {
        let lane = composerLane(botID)
        guard canSteer(botID), let current = lane.queued.first(where: { $0.id == id })?.delivery else { return }
        _ = lane.setDelivery(id, to: current.other)
    }

    /// Takes a queued message back into the composer (its text before what is typed now, its attachments with the
    /// current ones). Does nothing when it was delivered meanwhile.
    func unqueue(_ id: UUID, botID: UUID) {
        guard let message = composerLane(botID).withdraw(id) else { return }
        giveBack([message], to: botID)
    }

    /// The messages of yours that reached the running task and that the Orb has not acted on yet: "Parar e enviar" still
    /// takes them out of it and sends them as a request of their own (their bubble offers it, and ⌘↩).
    func unansweredSteered(of botID: UUID) -> [UUID] {
        guard isWorking(botID), canSteer(botID) else { return [] }
        return TranscriptItem.unansweredSteered(in: transcript(botID))
    }

    /// Your "Parar" (the composer's button, ⌘.). What you said that the Orb never acted on comes back to the composer,
    /// before what was still queued (which the end of the turn gives back too, `settleSteering`): it would otherwise stay
    /// in a stopped task that will never answer it, and you would have to write it again.
    func stopTurn(_ botID: UUID) {
        let hadTurn = session(botID).turnTask != nil
        let unanswered = canSteer(botID) ? session(botID).unansweredSteered() : []
        // Like "Parar e enviar": a routine waiting for this Orb starts only once the chat is settled (it would take the
        // conversation the message is withdrawn from).
        stop(botID, startsQueuedRoutines: false)
        if !unanswered.isEmpty {
            session(botID).withdrawSteered(unanswered.map(\.id))
            giveBack(unanswered, to: botID)
        }
        if hadTurn { startNextQueuedWork(for: botID) } // what the stop would have started (an Orb that only waited started nothing)
    }

    /// "Parar e enviar": ends the turn now and sends what was queued (with the draft, when there is one) as the
    /// next message. Without a `draft` (the queue bubble's button) the composer is left alone: what is typed and
    /// attached there stays, and only the queue is sent.
    func stopAndSend(_ botID: UUID, draft: String? = nil) {
        guard canSteer(botID) else {
            submit(draft ?? "", to: botID)
            return
        }
        let lane = composerLane(botID)
        // While a message is being edited the field holds the edit, which is not a message to queue: the edit is given up
        // (the composer gets back what it held; the send below would end it anyway) and only the queue is sent. The key is
        // disabled then (`ComposerAction.stopAndSendEnabled`); this keeps the menu and the queue bubble's button safe too.
        let wasEditing = lane.editing != nil
        cancelEditing(botID)
        if let draft, !wasEditing {
            let isCommand = lane.files.isEmpty && lane.pictures.isEmpty && CompactionCommand.parse(draft) != nil // stays in the composer
            if !isCommand, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lane.hasAttachments { queueMessage(draft, to: botID) }
        }
        var waiting = lane.takeAll()
        // A message that reached the task a moment before the click, and that the Orb has not answered yet, is what the
        // click was about: it leaves the stopped task and goes as the new request (taken before the stop closes the turn).
        let unanswered = session(botID).turnTask != nil ? session(botID).unansweredSteered() : []
        // A routine waiting for this Orb must not take it between the stop and the send: the message goes first, and
        // the routine starts when that turn ends (or now, when nothing was sent).
        stop(botID, startsQueuedRoutines: false)
        if !unanswered.isEmpty {
            session(botID).withdrawSteered(unanswered.map(\.id))
            waiting = unanswered + waiting
        }
        if let message = SteeredMessage.merged(waiting),
           send(message.text, attachments: message.files, images: message.pictures, to: botID) {
            live(botID).scrolled() // you asked for this send
            return
        }
        giveBack(waiting, to: botID)
        startNextQueuedWork(for: botID)
    }

    /// A queued message reached the model: the chat shows it as sent, at the point where the model got it. The bubble has
    /// the id the message had in the queue, which is the link the model's copy of it carries (`ChatMessage.itemID`).
    func deliverSteered(_ id: UUID, to botID: UUID) {
        guard let message = composerLane(botID).delivered(id) else { return }
        countSkillUse(in: message.text)
        closeStreaming(botID)
        // Marked "durante a tarefa": it reached the model in the middle of its work, not as a request of its own.
        append(.user(text: message.text, attachments: message.attachmentPaths), to: botID, duringTask: true, id: id) // follows the end only if the chat was there
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
        guard let lane = sessions[botID]?.lane, !lane.queued.isEmpty else { return }
        let waiting = lane.takeAll()
        guard succeeded, let message = SteeredMessage.merged(waiting),
              send(message.text, attachments: message.files, images: message.pictures, to: botID) else {
            giveBack(waiting, to: botID)
            return
        }
    }

    /// Puts messages back in the composer: their texts first, then what is already typed. While a message is being edited
    /// they go to what the composer held before the edit, which is what comes back when it ends.
    private func giveBack(_ messages: [SteeredMessage], to botID: UUID) {
        guard let message = SteeredMessage.merged(messages) else { return }
        let lane = composerLane(botID)
        if lane.editing != nil {
            lane.editing?.stash.putBack(text: message.text, separator: "\n\n", files: message.files.map(\.path), pictures: message.pictures)
            return
        }
        let current = drafts[botID, default: ""]
        setDraft(current.isEmpty ? message.text : message.text + "\n\n" + current, for: botID)
        for url in message.files where !lane.files.contains(where: { $0.url == url }) { lane.files.append(AttachedFile(url: url)) }
        lane.pictures += message.pictures
    }
}
