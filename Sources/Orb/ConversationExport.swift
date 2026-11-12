import AppKit
import UniformTypeIdentifiers

/// A conversation as a Markdown file the person keeps: what they asked, what the Orb answered and, in one line each, what
/// it did. Made from the lines of the chat (not from the model's history), so it reads as the chat does and holds nothing
/// the chat does not show: no system prompt, no tool output, no memory.
enum ConversationExport {
    /// The file's text. `orb` and `person` head each turn; a conversation with nothing said gives nil.
    static func markdown(_ items: [TranscriptItem], orb: String, person: String, now: Date = .now) -> String? {
        var blocks: [String] = []
        var actions: [String] = []
        func flushActions() {
            guard !actions.isEmpty else { return }
            blocks.append(actions.map { "- " + $0 }.joined(separator: "\n"))
            actions = []
        }
        func say(_ who: String, _ text: String, at date: Date) {
            flushActions()
            blocks.append("**\(who)** · \(date.formatted(date: .abbreviated, time: .shortened))\n\n\(text)")
        }
        for item in items {
            switch item.kind {
            case .user(let text, let attachments):
                let files = attachments.map { "- Anexo: " + ($0 as NSString).lastPathComponent }
                say(person, ([text] + files).filter { !$0.isEmpty }.joined(separator: "\n"), at: item.date)
            case .bot(let text, _), .greeting(let text):
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { say(orb, words, at: item.date) }
            case .tool(let call):
                // One line per action: its title and what it acted on (the first line of a command or a path), never its output.
                let detail = call.detail.split(whereSeparator: \.isNewline).first.map { " `\(Conversation.clipped(String($0), to: 160))`" } ?? ""
                actions.append(call.title + detail + (call.state == .failed ? " (falhou)" : ""))
            case .browserView(let view):
                actions.append(LiveScreenText.closingLine(view))
            case .notice(let text):
                flushActions()
                blocks.append("> " + text.replacingOccurrences(of: "\n", with: "\n> "))
            case .approval, .event, .orbMessage, .groupPause:
                continue
            }
        }
        flushActions()
        guard blocks.contains(where: { $0.hasPrefix("**") }) else { return nil }
        let heading = "# Conversa com \(orb)\n\nExportada em \(now.formatted(date: .long, time: .shortened))."
        return ([heading] + blocks).joined(separator: "\n\n") + "\n"
    }

    /// "Conversa com Atlas 2026-11-12.md": safe in any folder.
    static func fileName(orb: String, now: Date = .now) -> String {
        let name = orb.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "Conversa com \(name.isEmpty ? "Orb" : name) \(now.formatted(.iso8601.year().month().day())).md"
    }
}

extension AppModel {
    /// Whether the Orb's conversation on show has anything to export.
    func canExportConversation(_ botID: UUID) -> Bool {
        transcript(botID).contains { if case .bot(let text, false) = $0.kind { !text.isEmpty } else { false } }
    }

    /// Asks where to keep the conversation on show and writes it there as Markdown.
    func exportConversation(_ botID: UUID) {
        guard let bot = bot(botID),
              let text = ConversationExport.markdown(transcript(botID), orb: bot.name, person: profile.callName ?? "Você") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ConversationExport.fileName(orb: bot.name)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            append(.notice("Não consegui salvar a conversa: \(error.localizedDescription)"), to: botID)
        }
    }
}
