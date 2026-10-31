import Foundation

extension AppModel {
    /// The composer's microphone: opens it for `botID`, or closes it (the words stay in the field).
    func toggleDictation(_ botID: UUID) {
        if dictation.isActive(for: botID) {
            Task { await dictation.finish() }
            return
        }
        composerLane(botID).error = nil
        let vocabulary = dictationVocabulary(botID)
        var review: (@MainActor (String) async -> String?)?
        if reviewsDictation {
            review = { [weak self] text in await self?.reviewDictation(text, of: botID, vocabulary: vocabulary) }
        }
        dictation.start(for: botID, vocabulary: vocabulary, draft: drafts[botID, default: ""],
                        write: { [weak self] id, text in self?.setDraft(text, for: id) },
                        fail: { [weak self] id, message in self?.composerLane(id).error = message },
                        review: review)
    }

    /// Ajustes → Geral: the dictated text is read over by the Orb's model when the microphone closes.
    var reviewsDictation: Bool { preferences.object(forKey: DictationReview.settingKey) as? Bool ?? true }

    /// The dictated text read over by the Orb's model (`DictationReview`): a smaller one of the same maker when there is
    /// one (Haiku for Claude Code), with the chat's last messages and the names it may hear. nil keeps the text as it was.
    func reviewDictation(_ text: String, of botID: UUID, vocabulary: [String]) async -> String? {
        guard !isResetting, let bot = bot(botID), let ref = modelRef(for: bot), let account = account(ref.provider),
              account.isEnabled, isUsable(account) else { return nil }
        let model = Self.dictationReviewer(in: account, orb: ref.model)
        guard let client = clientOverride?() ?? account.client(for: account.models.first { $0.id == model },
                                                               credentials: Self.credentials(for: ref.provider),
                                                               conversationID: botID.uuidString + "-ditado") else { return nil }
        let context = session(botID).conversation?.messages ?? []
        let result = await DictationReview.revise(text, context: Array(context.suffix(40)), vocabulary: vocabulary, client: client, model: model)
        if let usage = result.usage, !isResetting, self.bot(botID) != nil {
            // On the Uso page, apart from the chat: a call the app made for itself, billed whether or not its text was kept.
            recordAuxiliaryUsage(usage, botID: botID, model: ModelRef(provider: ref.provider, model: model).text)
        }
        return result.text
    }

    /// Which model reads the dictation over: the cheap one of the Orb's maker (`ChunkSummarizer.model`), Haiku on Claude
    /// Code (whose list has it under that name), else the Orb's own.
    static func dictationReviewer(in account: ProviderAccount, orb: String) -> String {
        if account.kind == .claudeCode {
            return account.models.first { $0.id.lowercased().contains("haiku") }?.id ?? orb
        }
        return ChunkSummarizer.model(in: account, orb: orb)?.id ?? orb
    }

    /// Words the recognizer should expect: the Orbs' names and this Orb's skills, routines and groups.
    private func dictationVocabulary(_ botID: UUID) -> [String] {
        var words = ["Orb"] + bots.map(\.name) + skills(for: botID).map(\.name)
        words += routines.filter { $0.botID == botID }.map(\.name)
        words += groups(containing: botID).map(\.name)
        words = words.filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: words).array.compactMap { $0 as? String }.prefix(100))
    }
}
