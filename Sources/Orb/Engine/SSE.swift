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
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            // Most SSE streams are LF-only: checking for CR once per chunk avoids O(lines * chunk) memchr scans.
            let hasCR = memchr(base, 0x0D, count) != nil
            var i = 0
            while i < count {
                if afterCR {
                    afterCR = false
                    if bytes[i] == 0x0A { i += 1; continue }
                }
                let rem = count - i
                let lf = memchr(base + i, 0x0A, rem).map { base.distance(to: $0) }
                let cr: Int? = if hasCR {
                    memchr(base + i, 0x0D, lf.map { $0 - i } ?? rem).map { base.distance(to: $0) }
                } else {
                    nil
                }
                let nextBreak = cr ?? lf
                guard let brk = nextBreak else {
                    line.append(contentsOf: UnsafeBufferPointer(start: bytes + i, count: rem))
                    return
                }
                let event: SSEEvent?
                if line.isEmpty {
                    // Contiguous line inside chunk: parse directly without copying into `self.line`.
                    event = processLine(UnsafeBufferPointer(start: bytes + i, count: brk - i))
                } else {
                    if brk > i {
                        line.append(contentsOf: UnsafeBufferPointer(start: bytes + i, count: brk - i))
                    }
                    event = endLine()
                }
                if bytes[brk] == 0x0D { afterCR = true }
                i = brk + 1
                if let event, try onEvent(event) {
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
        return line.withUnsafeBufferPointer { processLine($0) }
    }

    private mutating func processLine(_ bytes: UnsafeBufferPointer<UInt8>) -> SSEEvent? {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            eventBytes = 0
            return dispatch()
        }
        let count = bytes.count
        eventBytes += count + 1
        if bytes[0] == 0x3A { return nil } // ':' comment
        // Fast byte-level matching for "data:" and "event:" avoids allocating an intermediate full-line String.
        if count >= 4, bytes[0] == 0x64, bytes[1] == 0x61, bytes[2] == 0x74, bytes[3] == 0x61 { // "data"
            if count == 4 {
                pending.append("")
                return nil
            }
            if bytes[4] == 0x3A { // "data:"
                let start = (count > 5 && bytes[5] == 0x20) ? 6 : 5
                let value = start < count ? String(decoding: UnsafeBufferPointer(start: base + start, count: count - start), as: UTF8.self) : ""
                pending.append(value)
                return nil
            }
        } else if count >= 5, bytes[0] == 0x65, bytes[1] == 0x76, bytes[2] == 0x65, bytes[3] == 0x6E, bytes[4] == 0x74 { // "event"
            if count == 5 {
                name = ""
                return nil
            }
            if bytes[5] == 0x3A { // "event:"
                let start = (count > 6 && bytes[6] == 0x20) ? 7 : 6
                name = start < count ? String(decoding: UnsafeBufferPointer(start: base + start, count: count - start), as: UTF8.self) : ""
                return nil
            }
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { pending.removeAll(keepingCapacity: true); name = nil }
        guard !pending.isEmpty else { return nil }
        let raw = pending.count == 1 ? pending[0] : pending.joined(separator: "\n")
        // Fast path: JSON payloads almost always start with '{' or '[' and end with '}' or ']'.
        let needsTrim: Bool = if let first = raw.utf8.first, let last = raw.utf8.last {
            first <= 0x20 || first >= 0x80 || last <= 0x20 || last >= 0x80
        } else {
            true
        }
        let data = needsTrim ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        return data.isEmpty ? nil : SSEEvent(name: name, data: data)
    }
}
