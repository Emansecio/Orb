import AppKit
import Foundation

/// File paths in a finished reply become links once the file is known to exist: the text is scanned without touching the disk
/// (`candidates`), the disk is asked off the main thread (`check`), and the links arrive afterwards as a change of color only, so
/// no line moves. A click shows the file in Quick Look; it never runs anything.
@MainActor
enum PathLinks {
    /// The most paths looked for in one text: a listing pasted in a reply is not worth a question to the disk per line.
    nonisolated static let perText = 40
    /// Answers kept. Past it they start over: a lost answer only costs another `fileExists`.
    private static let known = 4_000
    private static var exists: [String: Bool] = [:]

    /// Paths in `text` that nobody asked the disk about yet.
    static func unknown(in text: NSAttributedString) -> [String] {
        Array(Set(found(in: text).map(\.path).filter { exists[$0] == nil }))
    }

    /// Turns what is known to exist into links, in place: on a text on show, a selection stays.
    static func link(_ text: NSMutableAttributedString) {
        text.beginEditing()
        defer { text.endEditing() }
        for (path, range) in found(in: text) where exists[path] == true {
            text.addAttribute(.link, value: URL(fileURLWithPath: path), range: range)
        }
    }

    /// Asks the disk, away from the main thread. Whether any of them exists: only then is the text worth setting again.
    static func check(_ paths: [String]) async -> Bool {
        let existing = await Task.detached(priority: .utility) {
            Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
        }.value
        if exists.count + paths.count > known { exists = [:] }
        for path in paths { exists[path] = existing.contains(path) }
        return !existing.isEmpty
    }

    /// The addresses a reply may open with a click. A reply can be shaped by a page the Orb read, so any other scheme (an app's
    /// own, `shortcuts:`, `ssh:`, `smb:`) would be an action on the Mac, not a link.
    nonisolated static func opensOutside(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased())
    }

    /// Quick Look for a click on a link. The file may have gone since the reply was written.
    static func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        QuickLookPreview.show([url.path], at: 0)
    }

    private static func found(in text: NSAttributedString) -> [(path: String, range: NSRange)] {
        guard text.string.utf16.contains(0x2F) else { return [] } // no "/": the usual reply
        var result: [(String, NSRange)] = []
        let whole = NSRange(location: 0, length: text.length)
        let string = text.string as NSString
        text.enumerateAttributes(in: whole) { attributes, range, stop in
            guard attributes[.link] == nil else { return }
            let part = string.substring(with: range)
            let isCode = attributes[ProseText.inlineCodeKey] != nil
            for match in Self.candidates(in: part, isCode: isCode) {
                let span = NSRange(match.range, in: part)
                result.append((match.path, NSRange(location: range.location + span.location, length: span.length)))
                if result.count >= perText { stop.pointee = true; return }
            }
        }
        return result
    }

    /// What in `text` reads as an absolute path. Written as code, the whole text is the path, spaces and all; among words a
    /// path ends at the first space and loses the punctuation after it. Two folders at least, starting at `/` or `~/` after a
    /// space or an opening mark, so "e/ou", "1/2", "src/app" and a web address stay words.
    nonisolated static func candidates(in text: String, isCode: Bool) -> [(path: String, range: Range<String.Index>)] {
        if isCode {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let path = normalized(trimmed), let range = text.range(of: trimmed) else { return [] }
            return [(path, range)]
        }
        var result: [(String, Range<String.Index>)] = []
        var index = text.startIndex
        while let slash = text[index...].firstIndex(where: { $0 == "/" || $0 == "~" }) {
            var end = slash
            while end < text.endIndex, !text[end].isWhitespace, !closes.contains(text[end]) { end = text.index(after: end) }
            defer { index = max(end, text.index(after: slash)) }
            if slash > text.startIndex, !opens.contains(text[text.index(before: slash)]) { continue }
            var stop = end
            while stop > slash, trailing.contains(text[text.index(before: stop)]) { stop = text.index(before: stop) }
            if let path = normalized(String(text[slash..<stop])) { result.append((path, slash..<stop)) }
        }
        return result
    }

    private nonisolated static let opens: Set<Character> = [" ", "\t", "\n", "\u{2028}", "(", "[", "{", "\"", "'", "“", "‘", "«", "="]
    private nonisolated static let closes: Set<Character> = ["\"", "“", "”", "«", "»", "`", "<", ">", "|"]
    private nonisolated static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "’", "*", "_"]

    /// The absolute path, or nil when it is not one of ours: `~/` expanded, at least two names, no line break.
    private nonisolated static func normalized(_ text: String) -> String? {
        guard text.hasPrefix("/") || text.hasPrefix("~/"), !text.hasPrefix("//"), !text.contains("\n"), !text.contains("\u{2028}") else { return nil }
        let path = NSString(string: text).expandingTildeInPath
        let names = path.split(separator: "/")
        guard names.count >= 2, !names.contains("..") else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
