import Foundation

/// One Server-Sent Events event: the `event:` name (if any) and its `data:` lines joined by newlines, without the
/// whitespace around them (computed once, when the event is dispatched).
struct SSEEvent: Equatable, Sendable {
    var name: String?
    var data: String

    /// The `[DONE]` sentinel chat-completions providers end a stream with.
    var isDone: Bool { data == "[DONE]" }
}

/// Reads Server-Sent Events from bytes, one at a time or in chunks of any size (a line, or a UTF-8 character, may
/// be split anywhere). Lines end in `\n`, `\r\n` or `\r`; `:` lines are comments; an event is the `data:` lines
/// before a blank line (joined by `\n`) with the last `event:` name. Events without data are dropped, and the
/// event a stream ends in the middle of is delivered by `finish()`.
struct SSEDecoder {
    private var line: [UInt8] = []
    private var pending: [String] = []
    private var name: String?
    private var afterCR = false

    /// Feeds one byte; the event it completes, if any.
    mutating func feed(_ byte: UInt8) -> SSEEvent? {
        if afterCR {
            afterCR = false
            if byte == 0x0A { return nil } // the LF of a CRLF
        }
        switch byte {
        case 0x0A: return endLine()
        case 0x0D: afterCR = true; return endLine()
        default: line.append(byte); return nil
        }
    }

    /// Feeds a chunk; the events it completes.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        bytes.compactMap { feed($0) }
    }

    /// The stream ended: the last line and event, if they were not closed.
    mutating func finish() -> SSEEvent? {
        let last = line.isEmpty ? nil : endLine()
        return last ?? dispatch()
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line[0] == UInt8(ascii: ":") { return nil }
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring, value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            let rest = text[text.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            (field, value) = (text[...], "")
        }
        switch field {
        case "data": pending.append(String(value))
        case "event": name = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { pending.removeAll(); name = nil }
        let data = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return data.isEmpty ? nil : SSEEvent(name: name, data: data)
    }
}
