import Foundation

/// The model's note on a long stretch saved to the memory as a session page (see `SessionSummary`), when you turn it on in
/// Ajustes: the page is written by rules first, and the note joins it under `## Resumo` once it arrives, so a quit or a
/// failed call never costs the page. Only a stretch with `minimumRequests` of yours, and never one that used a connector
/// (what came from mail or messages never reaches the memory, see `SessionSummary`).
enum SessionNote {
    static let settingKey = "summarizeSessions"
    /// Requests of yours a stretch must have for a note: a short exchange says what it needs in its rules alone.
    static let minimumRequests = 6

    /// What is sent about `items` (the same kind of text a stretch note sends, `ChunkSummarizer.transcript`), or nil when
    /// the stretch gets no note.
    static func input(from items: [TranscriptItem]) -> String? {
        var lines: [String] = [], requests = 0
        for item in items {
            switch item.kind {
            case .user(let text, _):
                requests += 1
                lines.append("User: " + ContextText.preview(text, limit: 3_000))
            case .bot(let text, _):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("Assistant: " + ContextText.preview(text, limit: 3_000)) }
            case .tool(let call):
                if call.kind == .connector { return nil }
                guard call.kind != .memory else { continue }
                let detail = call.detail.isEmpty ? "" : ": " + ContextText.preview(call.detail, limit: 200)
                lines.append("Assistant used " + call.title + detail + (call.state == .failed ? " (failed)" : ""))
            case .approval(let request):
                if request.decision == .deny { lines.append("User denied: " + request.title) }
            case .notice, .greeting, .event, .orbMessage, .groupPause:
                break
            }
        }
        guard requests >= minimumRequests else { return nil }
        return ContextText.preview(lines.joined(separator: "\n"),
                                   limit: Int(Double(ChunkSummarizer.inputTokens) * ContextBudget.charactersPerToken))
    }
}
