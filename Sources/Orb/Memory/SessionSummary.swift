import Foundation

/// Turns a stretch of a conversation into a session page without an LLM (ai-memory's rule-based session
/// summary): what you asked, what the Orb did, the files and links involved, its last answer and what was left
/// open. Secrets are scrubbed before anything is clipped or written, and each entry is one line.
enum SessionSummary {
    /// Idle time after which a conversation stretch is saved as a session (a new message later starts another).
    /// `ORB_MEMORY_IDLE=<seconds>` shortens it for end-to-end checks.
    static let idleGap: TimeInterval = ProcessInfo.processInfo.environment["ORB_MEMORY_IDLE"].flatMap(Double.init) ?? 30 * 60

    /// The session page for `items` (nil when you didn't say anything in it). Linear in the number of items.
    static func page(from items: [TranscriptItem], now: Date = .now) -> MemoryPage? {
        func line(_ text: String, _ limit: Int) -> String { MemoryText.clip(MemoryText.flatten(MemorySanitizer.scrub(text)), limit) }
        let requests = items.compactMap { item -> (Date, String)? in
            guard case .user(let text, let attachments) = item.kind else { return nil }
            let files = attachments.isEmpty ? "" : " (anexos: \(attachments.joined(separator: ", ")))"
            return (item.date, text + files)
        }
        guard let first = requests.first else { return nil }

        var actions: [String] = [], references: [String] = [], open: [String] = []
        var seenActions = Set<String>(), seenReferences = Set<String>()
        var lastAnswer = "", answeredLast = false
        for item in items {
            switch item.kind {
            case .user:
                answeredLast = false
            case .bot(let text, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastAnswer = text
                    answeredLast = true
                }
            case .tool(let call):
                // Saving to and searching the memory itself isn't worth remembering.
                guard call.kind != .memory else { continue }
                let action = line(call.title + (call.detail.isEmpty ? "" : ": " + call.detail), 160) + (call.state == .failed ? " (falhou)" : "")
                if seenActions.insert(action).inserted { actions.append(action) }
                if call.state == .failed { open.append("Não deu certo: " + line(call.title + " " + call.detail, 140)) }
                for token in MemoryText.keepTokens(MemorySanitizer.scrub(call.detail)) where seenReferences.insert(token).inserted {
                    references.append(token)
                }
            case .approval(let request):
                if request.decision == .deny { open.append("Você negou: " + line(request.title + " " + request.command, 140)) }
            case .notice:
                break
            }
        }
        if !answeredLast, let last = requests.last { open.append("Ficou sem resposta: " + line(last.1, 200)) }

        let calendar = Calendar(identifier: .gregorian)
        let spansDays = !calendar.isDate(first.0, inSameDayAs: requests.last?.0 ?? first.0)
        let time = DateFormatter()
        time.locale = Locale(identifier: "pt_BR")
        time.dateFormat = spansDays ? "dd/MM HH:mm" : "HH:mm"
        var body = "## Pedidos\n" + requests.suffix(12).map { "- \(time.string(from: $0.0)) — \(line($0.1, 280))" }
            .joined(separator: "\n")
        if !actions.isEmpty { body += "\n\n## O que foi feito\n" + actions.suffix(15).map { "- \($0)" }.joined(separator: "\n") }
        if !references.isEmpty { body += "\n\n## Arquivos e links\n" + references.prefix(15).map { "- \($0)" }.joined(separator: "\n") }
        if !lastAnswer.isEmpty {
            // Headings inside the answer would read as sections of this page.
            let answer = lastAnswer.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : $0 }
                .joined(separator: "\n")
            body += "\n\n## Última resposta\n" + MemoryText.clip(MemorySanitizer.scrub(answer), 700)
        }
        if !open.isEmpty { body += "\n\n## Pendências\n" + open.suffix(8).map { "- \($0)" }.joined(separator: "\n") }

        let start = first.0, end = items.last?.date ?? now
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = calendar
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        return MemoryPage(path: "sessoes/\(stamp.string(from: start))-\(String(UUID().uuidString.prefix(6)).lowercased()).md",
                          kind: .sessao, title: line(first.1, 70), body: body, created: start, updated: end, origin: .automatico)
    }

    /// The bullet lines under `## <title>` in a session page.
    static func section(_ title: String, in body: String) -> [String] {
        var lines: [String] = [], inside = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inside = line == "## \(title)"; continue }
            if inside, line.hasPrefix("- ") { lines.append(String(line.dropFirst(2))) }
        }
        return lines
    }

    /// The text under `## <title>` (up to the next heading), or nil.
    static func paragraph(_ title: String, in body: String) -> String? {
        var lines: [String] = [], inside = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line == "## \(title)"
                continue
            }
            if inside { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
