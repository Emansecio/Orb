import Foundation

extension AppModel {
    /// The composer's microphone: opens it for `botID`, or closes it (the words stay in the field).
    func toggleDictation(_ botID: UUID) {
        if dictation.isActive(for: botID) {
            Task { await dictation.finish() }
            return
        }
        composerLane(botID).error = nil
        dictation.start(for: botID, vocabulary: dictationVocabulary(botID), draft: drafts[botID, default: ""],
                        write: { [weak self] id, text in self?.setDraft(text, for: id) },
                        fail: { [weak self] id, message in self?.composerLane(id).error = message })
    }

    /// Words the recognizer should expect: the Orbs' names and this Orb's skills.
    private func dictationVocabulary(_ botID: UUID) -> [String] {
        var words = ["Orb"] + bots.map(\.name) + skills(for: botID).map(\.name)
        words = words.filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: words).array.compactMap { $0 as? String }.prefix(100))
    }
}
