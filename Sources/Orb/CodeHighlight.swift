import Foundation
import SwiftUI

// The colors of the code in a reply, from one pass over its UTF-8 bytes: a small reader per kind of language, no parser
// and no dependency. It only changes colors, never the font, so a block that gets its colors keeps every line where it was.

/// A piece of code that has a color, by its UTF-8 offsets.
struct CodeSpan: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case keyword, string, comment, number, type, added, removed }

    var start: Int
    var end: Int
    var kind: Kind
}

enum CodeHighlight {
    /// Larger code stays plain: nobody reads that much in a reply, and it would cost more than it shows.
    static let maxBytes = 48 * 1024

    /// Whether `language` (what the fence says) has colors.
    static func colors(_ language: String) -> Bool { reader(for: language) != nil }

    /// The pieces of `code` with a color, in order and without overlaps; empty for a language without colors.
    static func spans(_ code: String, language: String) -> [CodeSpan] {
        guard let reader = reader(for: language) else { return [] }
        return spans(Array(code.utf8), reader)
    }

    private static func spans(_ bytes: [UInt8], _ reader: Reader) -> [CodeSpan] {
        switch reader {
        case .grammar(let grammar): return scan(bytes, grammar)
        case .markup: return markupSpans(bytes)
        case .diff: return diffSpans(bytes)
        case .markdown: return markdownSpans(bytes)
        }
    }

    /// `code` with its colors, or nil when it stays plain (no colors for this language, too long, nothing to color).
    static func attributed(_ code: String, language: String) -> AttributedString? {
        guard code.utf8.count <= maxBytes, let reader = reader(for: language) else { return nil }
        let bytes = Array(code.utf8)
        let found = spans(bytes, reader)
        guard !found.isEmpty else { return nil }
        func text(_ start: Int, _ end: Int) -> AttributedString {
            AttributedString(String(decoding: bytes[start..<end], as: UTF8.self))
        }
        var result = AttributedString()
        var cursor = 0
        for span in found {
            if span.start > cursor { result.append(text(cursor, span.start)) }
            var piece = text(span.start, span.end)
            piece.foregroundColor = span.kind.color
            result.append(piece)
            cursor = span.end
        }
        if cursor < bytes.count { result.append(text(cursor, bytes.count)) }
        return result
    }

    // MARK: Languages

    private enum Reader { case grammar(Grammar), markup, diff, markdown }

    private static func reader(for language: String) -> Reader? {
        switch language.lowercased() {
        case "swift": .grammar(Grammar.swift)
        case "python", "py", "python3": .grammar(Grammar.python)
        case "javascript", "js", "jsx", "mjs", "typescript", "ts", "tsx": .grammar(Grammar.javascript)
        case "bash", "sh", "shell", "zsh", "console": .grammar(Grammar.shell)
        case "json", "jsonc": .grammar(Grammar.json)
        case "sql": .grammar(Grammar.sql)
        case "css", "scss": .grammar(Grammar.css)
        case "yaml", "yml": .grammar(Grammar.yaml)
        case "html", "htm", "xml", "svg", "xhtml": .markup
        case "diff", "patch": .diff
        case "markdown", "md": .markdown
        default: nil
        }
    }

    /// What one pass needs to know about a language.
    private struct Grammar: Sendable {
        var keywords: Set<String> = []
        var lineComments: [[UInt8]] = []
        var blockComment: (open: [UInt8], close: [UInt8])?
        var quotes: [UInt8] = []
        /// `"""` and `'''` open a string that goes on over lines.
        var tripleQuotes = false
        /// A quote that may go on over lines. Any other ends with its line, so a stray quote colors one line at most.
        var multilineQuotes: Set<UInt8> = []
        /// `f'…'`, `rb'…'`: a letter or two right before a quote open a string (Python).
        var stringPrefixes = false
        /// A word that starts with a capital is a type.
        var capitalizedTypes = false
        /// `@decorator`, drawn as a keyword.
        var attributeMark: UInt8?
        /// `$NAME`, drawn as a type.
        var variableMark: UInt8?
        /// A comment needs a space or the start of a line before it: `${#a}` and `url#part` are not comments.
        var commentsAfterSpace = false
        var ignoresCase = false
        /// `name:` and `"name":` are keys, drawn as keywords.
        var colonKeys = false

        static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

        static let swift = Grammar(
            keywords: words("""
            actor any as associatedtype async await break case catch class continue convenience default defer deinit \
            didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in \
            indirect init inout internal is lazy let mutating nil nonisolated nonmutating open operator optional override \
            precedencegroup private protocol public repeat required rethrows return self Self set some static struct \
            subscript super switch throw throws true try typealias unowned var weak where while willSet
            """),
            lineComments: [Array("//".utf8)], blockComment: (Array("/*".utf8), Array("*/".utf8)), quotes: [q2],
            tripleQuotes: true, capitalizedTypes: true, attributeMark: at)

        static let python = Grammar(
            keywords: words("""
            and as assert async await break case class continue def del elif else except False finally for from global \
            if import in is lambda match None nonlocal not or pass raise return self True try while with yield
            """),
            lineComments: [[hash]], quotes: [q2, q1], tripleQuotes: true, stringPrefixes: true, capitalizedTypes: true, attributeMark: at)

        static let javascript = Grammar(
            keywords: words("""
            abstract any as async await boolean break case catch class const continue debugger declare default delete \
            do else enum export extends false finally for from function get if implements import in instanceof \
            interface keyof let namespace new null number of private protected public readonly return set static \
            string super switch this throw true try type typeof undefined var void while yield
            """),
            lineComments: [Array("//".utf8)], blockComment: (Array("/*".utf8), Array("*/".utf8)),
            quotes: [q2, q1, backtick], multilineQuotes: [backtick], capitalizedTypes: true, attributeMark: at)

        static let shell = Grammar(
            keywords: words("""
            alias break case cd continue do done elif else esac eval exec exit export fi for function if in local read \
            readonly return select set shift source then time trap unset until while
            """),
            lineComments: [[hash]], quotes: [q2, q1], multilineQuotes: [q2, q1], variableMark: dollar, commentsAfterSpace: true)

        static let json = Grammar(keywords: words("true false null"), lineComments: [Array("//".utf8)], quotes: [q2], colonKeys: true)

        static let sql = Grammar(
            keywords: words("""
            add all alter and as asc begin between by case check commit constraint create default delete desc distinct \
            drop else end exists foreign from full group having if in index inner insert into is join key left like \
            limit not null offset on or order outer primary references returning right rollback select set table then \
            transaction union unique update using values view when where with
            """),
            lineComments: [Array("--".utf8)], blockComment: (Array("/*".utf8), Array("*/".utf8)), quotes: [q1, q2], ignoresCase: true)

        static let css = Grammar(blockComment: (Array("/*".utf8), Array("*/".utf8)), quotes: [q2, q1], attributeMark: at)

        static let yaml = Grammar(keywords: words("true false null yes no"), lineComments: [[hash]], quotes: [q2, q1],
                                  commentsAfterSpace: true, colonKeys: true)
    }

    private static let (q1, q2, backtick): (UInt8, UInt8, UInt8) = (0x27, 0x22, 0x60)
    private static let (hash, at, dollar, backslash, newline, colon): (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0x23, 0x40, 0x24, 0x5C, 0x0A, 0x3A)

    // MARK: Reading

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }

    /// A letter of a word: `_` and anything past ASCII count, so an accented name is one word.
    private static func isWordStart(_ byte: UInt8) -> Bool {
        isUpper(byte) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80
    }

    private static func isWord(_ byte: UInt8) -> Bool { isWordStart(byte) || isDigit(byte) }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8], at index: Int) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in prefix.indices where bytes[index + offset] != prefix[offset] { return false }
        return true
    }

    /// Where the line that holds `index` ends (its line break, or the end of the text).
    private static func lineEnd(_ bytes: [UInt8], from index: Int) -> Int {
        var end = index
        while end < bytes.count, bytes[end] != newline { end += 1 }
        return end
    }

    /// Just past the first `close` from `index`, or the end of the text.
    private static func past(_ close: [UInt8], in bytes: [UInt8], from index: Int) -> Int {
        var index = index
        while index < bytes.count {
            if hasPrefix(bytes, close, at: index) { return index + close.count }
            index += 1
        }
        return bytes.count
    }

    private static func scan(_ bytes: [UInt8], _ grammar: Grammar) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        var index = 0
        scanning: while index < bytes.count {
            let byte = bytes[index]
            let before = index > 0 ? bytes[index - 1] : newline

            for mark in grammar.lineComments where hasPrefix(bytes, mark, at: index) {
                if grammar.commentsAfterSpace, before != 0x20, before != 0x09, before != newline { continue }
                let end = lineEnd(bytes, from: index)
                spans.append(CodeSpan(start: index, end: end, kind: .comment))
                index = end
                continue scanning
            }
            if let block = grammar.blockComment, hasPrefix(bytes, block.open, at: index) {
                let end = past(block.close, in: bytes, from: index + block.open.count)
                spans.append(CodeSpan(start: index, end: end, kind: .comment))
                index = end
                continue
            }
            // An apostrophe after a word is part of it ("don't" in a command), not a string.
            if grammar.quotes.contains(byte), byte != q1 || !isWord(before) || (grammar.stringPrefixes && hasStringPrefix(bytes, before: index)) {
                let end = stringEnd(bytes, from: index, grammar)
                var next = end
                while next < bytes.count, bytes[next] == 0x20 { next += 1 }
                let isKey = grammar.colonKeys && next < bytes.count && bytes[next] == colon
                spans.append(CodeSpan(start: index, end: end, kind: isKey ? .keyword : .string))
                index = end
                continue
            }
            if byte == grammar.attributeMark || byte == grammar.variableMark, index + 1 < bytes.count, isWordStart(bytes[index + 1]) {
                var end = index + 1
                while end < bytes.count, isWord(bytes[end]) { end += 1 }
                spans.append(CodeSpan(start: index, end: end, kind: byte == grammar.attributeMark ? .keyword : .type))
                index = end
                continue
            }
            if isDigit(byte), !isWord(before) {
                var end = index + 1
                while end < bytes.count, isWord(bytes[end]) || (bytes[end] == 0x2E && end + 1 < bytes.count && isDigit(bytes[end + 1])) {
                    end += 1
                }
                spans.append(CodeSpan(start: index, end: end, kind: .number))
                index = end
                continue
            }
            if isWordStart(byte) {
                var end = index + 1
                while end < bytes.count, isWord(bytes[end]) { end += 1 }
                let word = String(decoding: bytes[index..<end], as: UTF8.self)
                // After a dot it is a member (`obj.type`, `re.match`), whatever its name.
                if (before != 0x2E && grammar.keywords.contains(grammar.ignoresCase ? word.lowercased() : word))
                    || (grammar.colonKeys && end < bytes.count && bytes[end] == colon && isValueSeparator(bytes, end + 1)) {
                    spans.append(CodeSpan(start: index, end: end, kind: .keyword))
                } else if grammar.capitalizedTypes, isUpper(byte) {
                    spans.append(CodeSpan(start: index, end: end, kind: .type))
                }
                index = end
                continue
            }
            index += 1
        }
        return spans
    }

    /// Whether the word that ends at `index` is a string prefix: one or two of Python's letters.
    private static func hasStringPrefix(_ bytes: [UInt8], before index: Int) -> Bool {
        let letters = Array("rRbBfFuU".utf8)
        var start = index
        while start > 0, isWord(bytes[start - 1]) { start -= 1 }
        return (1...2).contains(index - start) && bytes[start..<index].allSatisfy(letters.contains)
    }

    /// After a YAML key: a space or the end of the line, which `12:30` and `http://` do not have.
    private static func isValueSeparator(_ bytes: [UInt8], _ index: Int) -> Bool {
        index >= bytes.count || bytes[index] == 0x20 || bytes[index] == newline
    }

    /// Just past the string that opens at `start`.
    private static func stringEnd(_ bytes: [UInt8], from start: Int, _ grammar: Grammar) -> Int {
        let quote = bytes[start]
        if grammar.tripleQuotes, quote != backtick {
            let triple = [quote, quote, quote]
            if hasPrefix(bytes, triple, at: start) { return past(triple, in: bytes, from: start + 3) }
        }
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == backslash { index += 2; continue }
            if byte == quote { return index + 1 }
            if byte == newline, !grammar.multilineQuotes.contains(quote) { return index }
            index += 1
        }
        return bytes.count
    }

    /// Tags as keywords, attribute names as types, their values as strings, comments. Text between tags stays plain.
    private static func markupSpans(_ bytes: [UInt8]) -> [CodeSpan] {
        let (open, close): (UInt8, UInt8) = (0x3C, 0x3E)
        var spans: [CodeSpan] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == open else { index += 1; continue }
            if hasPrefix(bytes, Array("<!--".utf8), at: index) {
                let end = past(Array("-->".utf8), in: bytes, from: index + 4)
                spans.append(CodeSpan(start: index, end: end, kind: .comment))
                index = end
                continue
            }
            // "a < b" and "x <5" are text: a tag starts with a name or `/`, `!`, `?`.
            guard index + 1 < bytes.count, isWordStart(bytes[index + 1]) || [0x2F, 0x21, 0x3F].contains(bytes[index + 1]) else { index += 1; continue }
            var end = index + 1
            while end < bytes.count, isWord(bytes[end]) || [0x2F, 0x21, 0x3F, 0x2D, colon].contains(bytes[end]) { end += 1 }
            spans.append(CodeSpan(start: index, end: end, kind: .keyword))
            index = end
            while index < bytes.count, bytes[index] != close {
                let byte = bytes[index]
                if byte == q2 || byte == q1 {
                    let closing = past([byte], in: bytes, from: index + 1)
                    spans.append(CodeSpan(start: index, end: closing, kind: .string))
                    index = closing
                } else if isWordStart(byte) {
                    var name = index + 1
                    while name < bytes.count, isWord(bytes[name]) || bytes[name] == 0x2D || bytes[name] == colon { name += 1 }
                    spans.append(CodeSpan(start: index, end: name, kind: .type))
                    index = name
                } else {
                    index += 1
                }
            }
        }
        return spans
    }

    /// A span per line that `kind` names.
    private static func lineSpans(_ bytes: [UInt8], kind: (ArraySlice<UInt8>) -> CodeSpan.Kind?) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        var start = 0
        while start < bytes.count {
            let end = lineEnd(bytes, from: start)
            if end > start, let found = kind(bytes[start..<end]) { spans.append(CodeSpan(start: start, end: end, kind: found)) }
            start = end + 1
        }
        return spans
    }

    /// A file's `---` and `+++` are headers only outside a hunk: inside one, `--- x` is a removed line that held `-- x`.
    private static func diffSpans(_ bytes: [UInt8]) -> [CodeSpan] {
        var inHunk = false
        return lineSpans(bytes) { line in
            if line.starts(with: Array("@@".utf8)) {
                inHunk = true
                return .keyword
            }
            if line.starts(with: Array("diff ".utf8)) { inHunk = false }
            if !inHunk, line.starts(with: Array("+++".utf8)) || line.starts(with: Array("---".utf8)) { return .keyword }
            switch line.first {
            case 0x2B: return .added
            case 0x2D: return .removed
            default: return nil
            }
        }
    }

    /// Headings, quotes and fences by line, `code` inside the others.
    private static func markdownSpans(_ bytes: [UInt8]) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        var start = 0
        while start < bytes.count {
            let end = lineEnd(bytes, from: start)
            if bytes[start] == hash {
                spans.append(CodeSpan(start: start, end: end, kind: .keyword))
            } else if bytes[start] == 0x3E || hasPrefix(bytes, [backtick, backtick, backtick], at: start) {
                spans.append(CodeSpan(start: start, end: end, kind: .comment))
            } else {
                var index = start
                while index < end {
                    guard bytes[index] == backtick, let close = bytes[(index + 1)..<end].firstIndex(of: backtick) else { index += 1; continue }
                    spans.append(CodeSpan(start: index, end: close + 1, kind: .string))
                    index = close + 1
                }
            }
            start = end + 1
        }
        return spans
    }
}

extension CodeSpan.Kind {
    var color: Color {
        switch self {
        case .keyword: Palette.codeKeyword
        case .string: Palette.codeString
        case .comment: Palette.faint
        case .number: Palette.codeNumber
        case .type: Palette.codeType
        case .added: Palette.codeAdded
        case .removed: Palette.codeRemoved
        }
    }
}

/// The change an `edit_file` shows (`EditFileTool.summary`): its path, sometimes a line on its scope, then the lines of
/// `EditFileTool.diff`. The "- " and "+ " stay, so the colors are never the only way to tell the two apart.
enum EditDiff {
    static func colored(_ detail: String) -> AttributedString {
        var result = AttributedString()
        var isFirst = true
        for line in detail.split(separator: "\n", omittingEmptySubsequences: false) {
            if !isFirst { result.append(AttributedString("\n")) }
            var piece = AttributedString(String(line))
            // The first line is the path, whatever it starts with.
            if !isFirst {
                if line.hasPrefix("+ ") { piece.foregroundColor = CodeSpan.Kind.added.color }
                if line.hasPrefix("- ") { piece.foregroundColor = CodeSpan.Kind.removed.color }
            }
            result.append(piece)
            isFirst = false
        }
        return result
    }
}
