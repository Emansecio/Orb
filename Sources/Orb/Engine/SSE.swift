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
    /// Bytes accumulated since the last blank line (completed lines + current line), for ceiling checks.
    private var eventBytes = 0
    var bufferedBytes: Int { eventBytes + line.count }

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
        var events: [SSEEvent] = []
        if let data = bytes as? Data {
            _ = feed(data) { events.append($0); return false }
            return events
        }
        return bytes.compactMap { feed($0) }
    }

    /// Scans a contiguous `Data` chunk with `memchr` instead of iterating byte by byte. Stops early if `onEvent` returns true.
    mutating func feed(_ chunk: Data, onEvent: (SSEEvent) throws -> Bool) rethrows -> Bool {
        var stopped = false
        try chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var i = 0
            while i < count {
                if afterCR {
                    afterCR = false
                    if raw[i] == 0x0A { i += 1; continue }
                }
                let rem = count - i
                let lf = memchr(base + i, 0x0A, rem).map { base.distance(to: $0) }
                let cr = memchr(base + i, 0x0D, rem).map { base.distance(to: $0) }
                let nextBreak: Int?
                if let lf, let cr { nextBreak = min(lf, cr) } else { nextBreak = lf ?? cr }
                guard let brk = nextBreak else {
                    line.append(contentsOf: UnsafeBufferPointer(start: (base + i).assumingMemoryBound(to: UInt8.self), count: rem))
                    return
                }
                if brk > i {
                    line.append(contentsOf: UnsafeBufferPointer(start: (base + i).assumingMemoryBound(to: UInt8.self), count: brk - i))
                }
                if raw[brk] == 0x0D { afterCR = true }
                i = brk + 1
                if let event = endLine(), try onEvent(event) {
                    stopped = true
                    return
                }
            }
        }
        return stopped
    }

    /// The stream ended: the last line and event, if they were not closed.
    mutating func finish() -> SSEEvent? {
        let last = line.isEmpty ? nil : endLine()
        return last ?? dispatch()
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { eventBytes = 0; return dispatch() }
        eventBytes += line.count + 1
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
        defer { pending.removeAll(keepingCapacity: true); name = nil }
        let raw = pending.count == 1 ? pending[0] : pending.joined(separator: "\n")
        let data = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return data.isEmpty ? nil : SSEEvent(name: name, data: data)
    }
}
