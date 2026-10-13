import Foundation

// Routine runs and the conversations an older version set aside: the value types and the text around them. Where they
// are kept is `Store`; how the app uses them is `AppModel`.

extension Conversation {
    /// Whether the user ever said something here (a conversation of notices alone is not worth keeping).
    var hasUserMessages: Bool {
        items.contains { if case .user = $0.kind { true } else { false } }
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
        copy.items.append(TranscriptItem(.notice(Self.routineRunMarker + RoutineFormats.runDate.string(from: date))))
        return copy
    }
}

// MARK: - Routine runs

enum RoutinePrompt {
    /// What the model gets for a routine run: nobody is there, so it must not ask or wait. English, like the rest of
    /// the prompts. `previous` is the last run's report, so a routine like "tell me what changed" has something to
    /// compare against without carrying the whole last conversation. A routine with a `goal` is also told where the
    /// goal stood and how to end its report (`goalSection`).
    static func unattended(_ prompt: String, routine name: String, previous: RoutineRun? = nil, goal: RoutineGoal? = nil) -> String {
        var text = """
        [Automatic run] This is the scheduled routine “\(name)”, started by the app, not a message from the user. \
        The user is not here: do not ask questions, do not wait for answers or confirmations, and do not offer choices. \
        Make reasonable assumptions and do the whole task with your tools, every step it asks for, in this run: there is no \
        later turn to finish it in. What it does not ask for, above all what deletes, sends or cannot be undone, goes in \
        your report as a suggestion. If something blocks you, try another way, and only then say so in your report instead \
        of asking. Finish with a short report (a few lines, plain text): what you did and what you found. Its \
        first line is shown to the user as a notification, so make it a complete summary on its own.
        """
        if let report = previous?.report, !report.isEmpty, let date = previous?.date {
            text += "\n\nReport of the previous run (\(RoutineReport.stamp(date))), in case you need to compare:\n"
                + Conversation.clipped(report, to: RoutineRun.promptReportLimit)
        }
        if let goal { text += "\n\n" + goalSection(goal) }
        return text + "\n\nTask:\n" + prompt
    }

    /// The goal, its last check, and the one line the report must end with. A readable line rather than hidden JSON:
    /// small models get it right, and it reads fine in the report (`GoalCheck.parse` reads it back).
    static func goalSection(_ goal: RoutineGoal) -> String {
        let last = goal.check.map { check in
            "Last check\(goal.updatedAt.map { " (\(RoutineReport.stamp($0)))" } ?? ""): \(check.label)"
                + (check.note.isEmpty ? "." : " · \(check.note)")
        } ?? "No check yet: this is the first."
        return """
        Goal of this routine (what success looks like, in the user's words): \(MemoryText.flatten(goal.target))
        \(last)
        On this run, check with your tools where the goal stands. Take the next small step toward it only if it is safe \
        and can be undone; otherwise just report. End your report with exactly one line in this shape, in Portuguese:
        Progresso: <0-100>% · <em dia | atenção | concluída> · <nota curta>
        Use "atenção" when the goal is stuck, at risk or needs the user, and "concluída" only once it is met.
        """
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

/// Shared formatters (thread-safe to format with on macOS 14+); never mutated after creation.
private enum RoutineFormats {
    static let runDate = make("pt_BR", "dd/MM/yyyy 'às' HH:mm")
    static let stamp = make("en_US_POSIX", "yyyy-MM-dd HHmm")

    private static func make(_ locale: String, _ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }
}

enum RoutineReport {
    /// `yyyy-MM-dd HHmm`: the report's file name, and how a run is dated in prompts.
    static func stamp(_ date: Date) -> String {
        RoutineFormats.stamp.string(from: date)
    }

    /// Saves the report as `Rotinas/<routine>/<yyyy-MM-dd HHmm>.md` inside the Orb's folder and returns that path
    /// relative to it, or nil when it could not be written. A second run in the same minute gets a number.
    static func write(_ report: String, routine: String, orb: String, date: Date, in folder: URL) -> String? {
        let files = FileManager.default
        let directoryName = safeName(routine)
        let directory = folder.appendingPathComponent("Rotinas", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let body = "# \(routine)\n\n_\(orb) · \(RoutineFormats.runDate.string(from: date))_\n\n\(report.trimmingCharacters(in: .whitespacesAndNewlines))\n"
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

// MARK: - One conversation per Orb

extension Conversation {
    /// The Orb's one conversation with the ones the old "Nova conversa" set aside put back before it, oldest first (an
    /// Orb has a single conversation now). With no user message in `current` (only the greeting it got after the last
    /// set-aside, or nothing) the newest set-aside one carries on instead. One already in it (an item of it is there:
    /// the merge ran before and its files were not yet gone) is not added twice.
    static func merging(_ archived: [Conversation], into current: Conversation?) -> Conversation {
        var older = archived.filter { !$0.items.isEmpty }
            .sorted { ($0.items.first?.date ?? .distantPast) < ($1.items.first?.date ?? .distantPast) }
        var base: Conversation
        if let current, current.hasUserMessages || older.isEmpty {
            base = current
        } else if let newest = older.popLast() {
            base = newest.closingInterruptedTurn()
        } else {
            return Conversation()
        }
        let present = Set(base.items.map(\.id))
        older.removeAll { $0.items.contains { present.contains($0.id) } }
        guard !older.isEmpty else { return base }

        var items: [TranscriptItem] = [], messages: [ChatMessage] = []
        for conversation in older {
            items += conversation.closingInterruptedTurn().items
            messages += conversation.messages.answeringDanglingToolCalls()
        }
        let shift = messages.count
        var merged = base
        merged.items = items + base.items
        merged.messages = messages + base.messages
        // What was set aside had been saved to memory when it was.
        merged.memorySavedCount = items.count + (base.memorySavedCount ?? 0)
        merged.summaryCoveredCount = base.summaryCoveredCount.map { $0 + shift }
        merged.condensedCount = base.condensedCount.map { $0 + shift }
        merged.chunkSummaries = base.chunkSummaries?.map { ChunkSummary(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
        return merged
    }
}
