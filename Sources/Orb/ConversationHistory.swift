import Foundation

// Archived conversations and routine runs: the value types and the text around them. Where they are kept is
// `Store` (conversation archive); how the app uses them is `AppModel`.

/// One line of the list of an Orb's earlier conversations (also what `index.json` of the archive holds).
struct ConversationSummary: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    /// The first thing the user said, flattened and shortened.
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// What the user and the Orb said (tool rows and notices do not count).
    var messageCount: Int

    static let titleLimit = 60

    init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    init(of conversation: Conversation, id: UUID = UUID()) {
        self.id = id
        title = conversation.archiveTitle
        createdAt = conversation.items.first?.date ?? .now
        updatedAt = conversation.items.last?.date ?? createdAt
        messageCount = conversation.items.reduce(0) { count, item in
            switch item.kind {
            case .user, .bot: count + 1
            default: count
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.value(.title, default: "Conversa")
        createdAt = try c.value(.createdAt, default: Date.now)
        updatedAt = try c.value(.updatedAt, default: createdAt)
        messageCount = try c.value(.messageCount, default: 0)
    }
}

/// The archive's `index.json`. It is a cache of the folder: whatever it gets wrong is corrected from the files.
struct ConversationIndex: Codable, Sendable {
    var entries: [ConversationSummary] = []

    init(entries: [ConversationSummary] = []) { self.entries = entries }

    init(from decoder: Decoder) throws {
        entries = try decoder.container(keyedBy: CodingKeys.self).lossyArray(.entries)
    }
}

extension Conversation {
    /// Whether the user ever said something here (a conversation of notices alone is not worth keeping).
    var hasUserMessages: Bool {
        items.contains { if case .user = $0.kind { true } else { false } }
    }

    /// The first user message on one line, shortened to `ConversationSummary.titleLimit`.
    var archiveTitle: String {
        for item in items {
            guard case .user(let text, let attachments) = item.kind else { continue }
            let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { return Self.clipped(line, to: ConversationSummary.titleLimit) }
            if let first = attachments.first { return Self.clipped(first, to: ConversationSummary.titleLimit) }
        }
        return "Conversa sem título"
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Notice that opens each run in a routine's conversation.
    static let routineRunMarker = "Execução de "

    /// The routine's conversation as a new run finds it. The transcript keeps the last runs (older ones are cut at a
    /// run boundary), but the model starts from nothing: every run is a fresh task, and its context must not grow
    /// with each hourly run.
    func startingRoutineRun(at date: Date, keepingRuns: Int = Routine.keptRuns - 1) -> Conversation {
        var copy = self
        copy.messages = []
        copy.summary = nil
        copy.summaryCoveredCount = nil
        copy.ledger = nil
        copy.compactions = nil
        copy.condensedCount = nil
        copy.taskPaused = nil
        copy.workspaceHash = nil
        copy.gatewaySessionID = nil
        copy.workspaceSeen = nil
        copy.memorySavedCount = nil

        let starts = copy.items.indices.filter { index in
            if case .notice(let text) = copy.items[index].kind { text.hasPrefix(Self.routineRunMarker) } else { false }
        }
        if starts.count > keepingRuns, let cut = starts.suffix(keepingRuns).first {
            copy.items.removeSubrange(0..<cut)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "pt_BR")
        format.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        copy.items.append(TranscriptItem(.notice(Self.routineRunMarker + format.string(from: date))))
        return copy
    }
}

// MARK: - Routine runs

enum RoutinePrompt {
    /// What the model gets for a routine run: nobody is there, so it must not ask or wait. English, like the rest of
    /// the prompts. `previous` is the last run's report, so a routine like "tell me what changed" has something to
    /// compare against without carrying the whole last conversation.
    static func unattended(_ prompt: String, routine name: String, previous: RoutineRun? = nil) -> String {
        var text = """
        [Automatic run] This is the scheduled routine “\(name)”, started by the app, not a message from the user. \
        The user is not here: do not ask questions, do not wait for answers or confirmations, and do not offer choices. \
        Make reasonable assumptions and do the work with your tools. If something blocks you, say so in your report \
        instead of asking. Finish with a short report (a few lines, plain text): what you did and what you found. Its \
        first line is shown to the user as a notification, so make it a complete summary on its own.
        """
        if let report = previous?.report, !report.isEmpty, let date = previous?.date {
            text += "\n\nReport of the previous run (\(RoutineReport.stamp(date))), in case you need to compare:\n"
                + Conversation.clipped(report, to: RoutineRun.promptReportLimit)
        }
        return text + "\n\nTask:\n" + prompt
    }
}

extension RoutineRun {
    /// How much of a report is kept in `Routine.runs` (the full text stays in the routine's conversation).
    static let reportLimit = 1_500
    /// How much of the previous report the next run is shown.
    static let promptReportLimit = 1_200
    static let summaryLimit = 160

    /// The first meaningful line of a report, without Markdown decoration, shortened.
    static func firstLine(of report: String?) -> String? {
        guard let report else { return nil }
        for line in report.split(whereSeparator: \.isNewline) {
            let cleaned = plain(line)
            if !cleaned.isEmpty { return Conversation.clipped(cleaned, to: summaryLimit) }
        }
        return nil
    }

    /// The start of a reply for a banner: its lines without Markdown decoration, on one line, shortened to `limit`.
    static func preview(of reply: String, limit: Int = 180) -> String {
        let text = reply.split(whereSeparator: \.isNewline).map { plain($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        return Conversation.clipped(text, to: limit)
    }

    private static func plain(_ line: Substring) -> String {
        line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "#*>-_` \t"))
    }
}

enum RoutineReport {
    /// `yyyy-MM-dd HHmm`: the report's file name, and how a run is dated in prompts.
    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmm"
        return format.string(from: date)
    }

    /// Saves the report as `Rotinas/<routine>/<yyyy-MM-dd HHmm>.md` inside the Orb's folder and returns that path
    /// relative to it, or nil when it could not be written. A second run in the same minute gets a number.
    static func write(_ report: String, routine: String, orb: String, date: Date, in folder: URL) -> String? {
        let files = FileManager.default
        let directoryName = safeName(routine)
        let directory = folder.appendingPathComponent("Rotinas", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "pt_BR")
        format.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        let body = "# \(routine)\n\n_\(orb) · \(format.string(from: date))_\n\n\(report.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            var name = stamp(date), attempt = 1
            while files.fileExists(atPath: directory.appendingPathComponent(name + ".md").path) {
                attempt += 1
                name = "\(stamp(date)) (\(attempt))"
            }
            try Data(body.utf8).write(to: directory.appendingPathComponent(name + ".md"), options: .atomic)
            return "Rotinas/\(directoryName)/\(name).md"
        } catch {
            NSLog("Orb: não foi possível salvar o relatório da rotina “\(routine)”: \(error)")
            return nil
        }
    }

    /// A routine's name as a folder name: no separators, no leading dots, not empty.
    static func safeName(_ name: String) -> String {
        let cleaned = String(name.map { "/\\:\u{0}".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Rotina" : String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}
