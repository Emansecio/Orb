import Foundation

/// The person's judgement of a reply or an action of the Orb: good or bad, and, for a bad one, why. Kept on the line it
/// is about; the Orb is told with the next message of that chat (`SinceLastTurn`), and a bad one about work with tools
/// may start a review of the skill behind it at once (`AppModel.react`).
struct Reaction: Codable, Sendable, Equatable {
    var isGood: Bool
    /// What was wrong, in the person's words or one of `quickReasons`.
    var reason: String?
    /// When it was given: what makes it news to the Orb, since the line it sits on is older.
    var date = Date.now

    static let reasonLimit = 300
    /// What a bad reply is most often: one click instead of a sentence.
    static let quickReasons = ["Não era isso que pedi", "Está errado", "Longo demais", "Faltou conferir o resultado"]

    /// What the Orb is told about the reaction on `items[index]`: which reply or action, how it was judged and why. nil
    /// for a line that takes no reaction.
    static func report(on index: Int, in items: [TranscriptItem]) -> String? {
        guard items.indices.contains(index), let reaction = items[index].reaction else { return nil }
        let subject: String
        switch items[index].kind {
        case .bot(let text, _): subject = "Your reply \"\(Conversation.clipped(MemoryText.flatten(text), to: 240))\""
        case .tool(let call):
            subject = "Your action \"\(Conversation.clipped(MemoryText.flatten([call.title, call.detail].filter { !$0.isEmpty }.joined(separator: ": ")), to: 200))\""
        default: return nil
        }
        var lines = [subject + (reaction.isGood ? ": the user marked it as GOOD." : ": the user marked it as BAD.")]
        if let reason = reaction.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append("Why, in the user's words: " + Conversation.clipped(MemoryText.flatten(reason), to: reasonLimit))
        }
        return lines.joined(separator: "\n")
    }

    /// What goes with the report when the turn used skills: a bad result of a skill is the skill's to fix.
    static func skillsLine(_ slugs: [String]) -> String {
        slugs.isEmpty ? "" : "\nSkills used in that turn: " + slugs.map { "/" + $0 }.joined(separator: ", ") + "."
    }

    /// What may be a skill in the turn `index` is in (from your message before it to your next one): what you ran with
    /// /name and what the Orb read. The caller keeps the ones that are skills of the Orb (/name is also how an app
    /// command and a path begin).
    static func commandsUsed(inTurnOf index: Int, _ items: [TranscriptItem]) -> [String] {
        func isUser(_ item: TranscriptItem) -> Bool { if case .user = item.kind { true } else { false } }
        let start = items[...index].lastIndex(where: isUser) ?? items.startIndex
        let end = items[(index + 1)...].firstIndex(where: isUser) ?? items.endIndex
        var found: [String] = []
        for item in items[start..<end] {
            var slug: Substring?
            switch item.kind {
            case .user(let text, _) where text.hasPrefix("/"): slug = text.dropFirst().prefix { !$0.isWhitespace }
            case .tool(let call) where call.title == RecallTool.skillTitle && call.detail.hasPrefix("/"):
                slug = call.detail.dropFirst().prefix { $0 != "#" && !$0.isWhitespace }
            default: break
            }
            if let slug, !slug.isEmpty, !found.contains(String(slug)) { found.append(String(slug)) }
        }
        return found
    }
}
