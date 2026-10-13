import Foundation

/// A part of a reply quoted in a message of yours: "Citar" on a selection puts it at the start of the draft as a Markdown
/// quote ("> …"), so it travels as part of the message's text through everything a message goes through (the queue of a
/// running task, a merge, a give-back to the composer, an edit, the saved conversation) and the model reads it as what it
/// is. Your bubble shows it apart, above what you wrote, and a click on it goes back to the reply it came from, found by
/// its words.
enum MessageQuote {
    /// A quote longer than this is cut (with "…"): it points at a passage, it does not copy the reply.
    static let limit = 600
    /// The words a quote is looked for by in the replies: its start, as it reads.
    static let probeLength = 60

    /// `text` as a quote block: each line after "> ", blank lines dropped, cut to `limit`.
    static func block(_ text: String) -> String {
        var quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if quoted.count > limit { quoted = String(quoted.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return quoted.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    /// The draft with `text` quoted at its start, a blank line before what was written. A draft that already starts with a
    /// quote gets the new passage at the end of it: one message quotes one block.
    static func draft(quoting text: String, before draft: String) -> String {
        let quote = block(text)
        guard !quote.isEmpty else { return draft }
        let current = split(draft)
        guard let earlier = current.quote else {
            return quote + "\n\n" + draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return block(earlier) + "\n" + quote + "\n\n" + current.body
    }

    /// A message's leading quote (its "> " lines, without the marks) and what follows it; no quote when it does not start
    /// with one.
    static func split(_ message: String) -> (quote: String?, body: String) {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.prefix { $0.hasPrefix(">") }
        guard !quoted.isEmpty else { return (nil, message) }
        let quote = quoted.map { line in
            line.dropFirst().drop { $0 == " " }
        }.joined(separator: "\n")
        let body = lines.dropFirst(quoted.count).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (nil, message) : (text, body)
    }

    /// What a quote is looked for by: its first words as they read (no list marker, spaces as one), at most `probeLength`.
    static func probe(_ quote: String) -> String {
        let firstLine = quote.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let unmarked = firstLine.replacing(/^\s*(?:[•◦☐☑]|\d+\.)\s+/, with: "")
        return String(squeezed(unmarked).prefix(probeLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The reply a quote in the message at `index` came from: the nearest one before it whose words hold the quote's start.
    static func source(of quote: String, before index: Int, in items: [TranscriptItem]) -> UUID? {
        let probe = probe(quote).lowercased()
        guard !probe.isEmpty else { return nil }
        for item in items[..<min(index, items.count)].reversed() {
            let text: String
            switch item.kind {
            case .bot(let reply, _), .greeting(let reply): text = reply
            default: continue
            }
            if squeezed(MarkdownBlocks.plainText(of: text)).lowercased().contains(probe) { return item.id }
        }
        return nil
    }

    /// Every run of spaces and line breaks as one space.
    private static func squeezed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
