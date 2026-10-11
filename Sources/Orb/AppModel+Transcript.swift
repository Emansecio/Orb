import AppKit

// What the transcript offers to do about a notice ("Tentar de novo", "Continuar", "Abrir Ajustes"), and what those
// actions do to the conversation. A notice stays plain text in the saved conversation: the action is read from its
// words, so conversations written before this still get their buttons and nothing new has to be stored.

/// An action offered under a notice of the transcript.
enum NoticeAction: Equatable, Sendable {
    /// The turn failed: try it again.
    case retry
    /// The turn paused or its reply was cut: say "continua".
    case continueTurn
    /// The problem is the model, its key or its login: open Ajustes.
    case openSettings
    /// The conversation is too long for the model: summarize its start and send the last message again.
    case compact
    /// The app kept something in memory by itself: look at it in the Memória tab.
    case openMemory
    /// The Orb proposed a skill (or a better version of one): read it and decide.
    case reviewSkill

    var title: String {
        switch self {
        case .retry: "Tentar de novo"
        case .continueTurn: "Continuar"
        case .openSettings: "Abrir Ajustes"
        case .compact: "Compactar e tentar de novo"
        case .openMemory: "Ver na memória"
        case .reviewSkill: "Revisar"
        }
    }

    /// The hover text of the button.
    var help: String {
        switch self {
        case .retry: "Refaz o pedido que não deu certo"
        case .continueTurn: "Envia “\(Self.continueMessage)” para o Orb seguir de onde parou"
        case .openSettings: "Abre os Ajustes para ver o modelo, a chave ou o login"
        case .compact: "Resume o começo da conversa e envia a última mensagem de novo"
        case .openMemory: "Abre a aba Memória, no painel do Orb"
        case .reviewSkill: "Abre a skill proposta para você ler e decidir"
        }
    }

    var symbol: String {
        switch self {
        case .retry: "arrow.clockwise"
        case .continueTurn: "play.fill"
        case .openSettings: "gearshape"
        case .compact: "arrow.triangle.merge"
        case .openMemory: "brain"
        case .reviewSkill: "wand.and.stars"
        }
    }

    /// What the message sent by "Continuar" says.
    static let continueMessage = "continua"

    static let failurePrefix = "Não deu certo: "
    /// How the notice for a fact the app kept by itself (not the model) starts.
    static let keptMemoryPrefix = "Guardado na memória:"
    /// How the notices for a skill the Orb proposed start: a new one ("Skill proposta: /publicar-site — Publicar site") and
    /// a better version of one that exists ("Melhoria proposta para /publicar-site").
    static let proposalPrefix = "Skill proposta:"
    static let proposalUpdatePrefix = "Melhoria proposta para"

    /// The command a proposal notice is about.
    static func proposedSlug(in notice: String) -> String? {
        guard notice.hasPrefix(proposalPrefix) || notice.hasPrefix(proposalUpdatePrefix),
              let start = notice.firstIndex(of: "/") else { return nil }
        let slug = notice[notice.index(after: start)...].prefix { !$0.isWhitespace }
        return slug.isEmpty ? nil : String(slug)
    }

    /// The actions that fit a notice, most useful first; none for the notices that only inform.
    static func actions(for notice: String) -> [NoticeAction] {
        if notice.hasPrefix("Conecte um modelo") { return [.openSettings] }
        if notice.hasPrefix("Pausei depois de") || notice.hasPrefix("A resposta passou do limite") { return [.continueTurn] }
        // Wrongly detected, it is one click to the page to forget.
        if notice.hasPrefix(keptMemoryPrefix) { return [.openMemory] }
        if proposedSlug(in: notice) != nil { return [.reviewSkill] }
        guard notice.hasPrefix(failurePrefix) else { return [] }
        // Only the app's own sentence decides: what follows "Detalhe do provedor:" (or "Detalhe do Claude Code:") is free text.
        let reason = ourSentence(of: notice.dropFirst(failurePrefix.count).lowercased())
        if reason.contains("grande demais") { return [.compact] }
        // Out of balance: trying again is right once the balance is topped up; Ajustes only if another model is wanted.
        if reason.contains("sem saldo") || reason.contains("pede pagamento") { return [.retry, .openSettings] }
        return isSettingsProblem(reason) ? [.openSettings, .retry] : [.retry]
    }

    /// `actions(for:)` without "Compactar e tentar de novo" when the conversation has nothing older to summarize, and
    /// without "Revisar" once the proposal is gone (saved, discarded or deleted).
    static func actions(for notice: String, canCompact: Bool, hasProposal: Bool = true) -> [NoticeAction] {
        actions(for: notice).filter { ($0 != .compact || canCompact) && ($0 != .reviewSkill || hasProposal) }
    }

    /// The part of a failure the app wrote, before the provider's own words.
    static func ourSentence(of reason: String) -> String {
        ["detalhe do provedor:", "detalhe do claude code:"].reduce(reason) { $0.components(separatedBy: $1).first ?? $0 }
    }

    /// A failure that Ajustes can fix: no model, a bad key or login, Claude Code missing or not signed in. A usage
    /// limit (429), a missing balance or a server error (5xx) is not one. (`reason` is lowercased and is only the
    /// app's own sentence, see `ourSentence`.)
    static func isSettingsProblem(_ reason: String) -> Bool {
        if ["ajustes", "chave", "nenhum modelo", "claude code não"].contains(where: { reason.contains($0) }) { return true }
        // A model the provider refused while the key is fine is not a key problem.
        return (reason.contains("(401)") || reason.contains("(403)")) && !reason.contains("recusou este modelo")
    }

    /// A failure notice split into its heading and the detail.
    static func failureDetail(of notice: String) -> String? {
        notice.hasPrefix(failurePrefix) ? String(notice.dropFirst(failurePrefix.count)) : nil
    }
}

/// What "Tentar de novo" does with the end of a conversation.
enum RetryPlan: Equatable, Sendable {
    /// The turn failed before doing anything: take the failed message back and send it again. Pictures are the ones
    /// in `attachments` too (as paths); the message in the model's history says which were pictures.
    case resend(text: String, attachments: [String], itemRange: Range<Int>)
    /// The turn had already answered or run tools: do not repeat it, ask the Orb to go on.
    case continueTurn
    case none

    static func plan(for items: [TranscriptItem]) -> RetryPlan {
        guard let lastUser = items.lastIndex(where: { if case .user = $0.kind { true } else { false } }),
              case .user(let text, let attachments) = items[lastUser].kind else { return .none }
        let after = items[(lastUser + 1)...]
        for item in after {
            switch item.kind {
            case .notice, .greeting, .event, .orbMessage, .groupPause: continue
            case .user: return .none
            case .bot, .tool, .approval: return .continueTurn
            }
        }
        return .resend(text: text, attachments: attachments, itemRange: lastUser..<items.count)
    }

    /// Whether `message` is the one `typed` produced: its words, without the preface and the lists the app adds, are
    /// exactly the typed ones (searching for them inside the message would find "2" in the preface's date). A skill's
    /// "/slug request" is stored expanded into the skill's instructions, so it does not hold what was typed.
    static func isMessage(_ message: ChatMessage, from typed: String, skills: [Skill]) -> Bool {
        guard message.role == .user else { return false }
        let words = TurnPreface.requestWords(message.content)
        if words == typed { return true }
        guard let expanded = SystemPrompt.expandSkill(in: typed, skills: skills)?.prompt else { return false }
        return words == expanded
    }
}

extension AppModel {
    /// One of the quick replies under a new Orb's greeting. The message goes as the person's own (`fromUser`: with no
    /// model connected it pulses the connect card instead of leaving a notice, and the replies stay).
    func answerGreeting(_ reply: OrbGreeting.Reply, for botID: UUID) {
        switch reply {
        case .tell:
            setDraft(OrbGreeting.draft, for: botID)
            request(.focusComposer, of: botID)
        case .interview: send(EmptyChatContent.interviewRequest, to: botID, fromUser: true)
        case .abilities: send(OrbGreeting.Reply.abilities.title, to: botID, fromUser: true)
        }
    }

    /// "Continuar": says "continua" to the Orb, which goes on from where it paused or was cut.
    @discardableResult
    func continueTurn(_ botID: UUID) -> Bool {
        // Not `fromUser`: that would also clear the draft you may be typing. The click is yours, so the chat follows.
        guard send(NoticeAction.continueMessage, to: botID) else { return false }
        live(botID).scrolled()
        return true
    }

    /// "Tentar de novo": a turn that failed before doing anything is taken back and its message sent again (the
    /// conversation shows it once). One that had begun to answer or run tools asks the Orb to go on instead, so
    /// nothing runs twice.
    @discardableResult
    func retryLastTurn(_ botID: UUID) -> Bool {
        guard !isWorking(botID), sessions[botID]?.turnTask == nil, bot(botID) != nil else { return false }
        guard let items = loadedConversation(botID)?.items else { return false }
        switch RetryPlan.plan(for: items) {
        case .none:
            return false
        case .continueTurn:
            return continueTurn(botID)
        case .resend(let text, let attachments, let range):
            // What the model's history holds of the failed message (its picture attachments), taken back with it.
            let removedItems = Array(items[range])
            var removedMessage: ChatMessage?
            let skillsForRetry = skills(for: botID)
            let failedBubble = items[range.lowerBound].id
            editConversation(botID) { conversation in
                // The failed attempt's own message, if it got that far: by its link, or (an older conversation) by its words.
                if let last = conversation.messages.last, last.role == .user,
                   last.itemID.map({ $0 == failedBubble }) ?? RetryPlan.isMessage(last, from: text, skills: skillsForRetry) {
                    removedMessage = last
                    conversation.messages.removeLast()
                }
                conversation.items.removeSubrange(range)
            }
            let pictures = removedMessage?.images ?? []
            let pictured = Set(pictures.map(\.path))
            let files = attachments.filter { !pictured.contains($0) }.map { URL(fileURLWithPath: $0) }
            if send(text, attachments: files, images: pictures, to: botID) {
                // The failed attempt already counted the skill's use; sending again counted it a second time.
                if let skill = SystemPrompt.expandSkill(in: text, skills: skillsForRetry)?.skill,
                   let index = skills.firstIndex(where: { $0.id == skill.id }), skills[index].uses > 0 {
                    skills[index].uses -= 1
                }
                live(botID).scrolled() // the click is yours: the chat follows the new answer
                return true
            }
            // Nothing was sent (no usable model): the message goes back where it was.
            editConversation(botID) { conversation in
                conversation.items.insert(contentsOf: removedItems, at: min(range.lowerBound, conversation.items.count))
                if let removedMessage { conversation.messages.append(removedMessage) }
            }
            return false
        }
    }

    /// "Compactar e tentar de novo": the provider refused the conversation as too big, so its start becomes a summary
    /// and the last message is sent again. False when there was nothing to summarize (the message is not resent).
    /// The notice about the compaction stays in the transcript, above the message sent again.
    @discardableResult
    func compactAndRetry(_ botID: UUID) -> Bool {
        let before = loadedConversation(botID)?.items.count ?? 0
        guard compactFromMeter(botID, focus: nil).didCompact else { return false }
        // What the compaction added to the transcript (the retry takes back everything after the failed message).
        let notices = loadedConversation(botID).map { Array($0.items.dropFirst(before)) } ?? []
        guard retryLastTurn(botID) else { return false }
        editConversation(botID) { conversation in
            guard let resent = conversation.items.lastIndex(where: { if case .user = $0.kind { true } else { false } }) else { return }
            conversation.items.insert(contentsOf: notices, at: resent)
        }
        return true
    }

    /// "Ver na memória": the panel opens on the Orb's Memória tab.
    func showMemory(of botID: UUID) {
        setInspector(true)
        request(.showTab(.memory), of: botID)
    }

    /// Tells VoiceOver something that just happened in the window (an Orb asking for permission).
    func announceForAccessibility(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// Tells VoiceOver what the Orb has started doing ("Lia: Rodando swift build"), politely: at low priority, only to
    /// someone who has VoiceOver on, in the window they are looking at, for the Orb they are talking to, and
    /// (`WorkAnnouncer`) for phrases that name something, not more often than every 8 s. The wait for an answer has
    /// its own, urgent announcement (`announceApproval`).
    func announceWork(_ line: WorkLine, of botID: UUID) {
        guard NSWorkspace.shared.isVoiceOverEnabled, NSApp?.isActive == true, selectedBot?.id == botID,
              let name = bot(botID)?.name, workAnnouncer.shouldAnnounce(line, at: .now) else { return }
        announceForAccessibility("\(name): \(line.text)", priority: .low)
    }
}
