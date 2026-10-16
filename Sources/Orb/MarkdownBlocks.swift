import Foundation

// Block-level Markdown for the replies of an Orb: paragraphs, headings, lists, quotes, code, tables, rules, and pictures
// on this Mac.
//
// Light and dependency-free on purpose. The text is first cut into the same pieces the streaming path uses (blank
// lines outside a code fence, see `ReplyParagraphs`) and each piece is read into blocks, so a reply that is done
// is exactly the pieces it had while it streamed: nothing moves when the last flush arrives. Inline syntax (bold,
// italics, code, links) stays with `AttributedString`; only the structure is read here.

/// One block of a reply. Holds the Markdown source of its inline text (not a parsed `AttributedString`), so it is
/// cheap to compare and the views decide how to draw it.
enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([MarkdownListItem])
    case quote(String)
    case code(language: String?, code: String, isClosed: Bool)
    case table(MarkdownTable)
    case rule
    /// `![what it shows](/path/picture.png)` on a line of its own: a picture on this Mac that the reply shows (a capture,
    /// a chart the Orb drew). `path` is absolute. Never a web address (see `MarkdownBlocks.image`).
    case image(alt: String, path: String)
}

struct MarkdownListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    var depth: Int
    var marker: Marker
    var text: String
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    var header: [String]
    var rows: [[String]]
    var alignments: [Alignment]
}

enum MarkdownBlocks {
    /// The blocks of a whole reply, piece by piece as the streaming path cuts it.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let pieces = ReplyParagraphs(text)
        var blocks: [MarkdownBlock] = []
        for piece in pieces.closed { blocks += parsePiece(piece) }
        if !pieces.tail.isEmpty { blocks += parsePiece(pieces.tail) }
        return blocks
    }

    /// The blocks of one piece (the text between two blank lines, or a code block with blank lines inside).
    static func parsePiece(_ piece: String) -> [MarkdownBlock] {
        let lines = piece.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { index += 1; continue }

            if let fence = fenceOpening(line) {
                var code: [Substring] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if isFenceClosing(lines[index], minimum: fence.ticks) { closed = true; index += 1; break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n"), isClosed: closed))
                continue
            }
            if let heading = heading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if let image = image(line) {
                blocks.append(.image(alt: image.alt, path: image.path))
                index += 1
                continue
            }
            if isRule(line) {
                blocks.append(.rule)
                index += 1
                continue
            }
            if isQuote(line) {
                var quoted: [String] = []
                while index < lines.count, isQuote(lines[index]) {
                    quoted.append(quoteContent(lines[index]))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, let table = table(startingAt: index, in: lines) {
                blocks.append(.table(table.table))
                index = table.next
                continue
            }
            if listMarker(line) != nil {
                let list = list(startingAt: index, in: lines)
                blocks.append(.list(list.items))
                index = list.next
                continue
            }
            // A paragraph: lines up to a blank one or the start of another block. Line breaks are kept.
            var paragraph: [String] = [String(line)]
            index += 1
            while index < lines.count, !isBlank(lines[index]), !startsBlock(lines[index], at: index, in: lines) {
                paragraph.append(String(lines[index]))
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: Plain text

    /// What "Copiar" puts on the pasteboard: the reply without Markdown marks (lists keep their bullets and
    /// numbers, code its text, a table its cells separated by tabs).
    static func plainText(of text: String) -> String {
        parse(text).map(plainText(of:)).joined(separator: "\n\n")
    }

    static func plainText(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let source), .quote(let source):
            return inlinePlain(source)
        case .heading(_, let text):
            return inlinePlain(text)
        case .list(let items):
            return items.map { item in
                let prefix: String = switch item.marker {
                case .bullet: "• "
                case .number(let number): "\(number). "
                case .task(let done): done ? "[x] " : "[ ] "
                }
                return String(repeating: "  ", count: item.depth) + prefix + inlinePlain(item.text)
            }.joined(separator: "\n")
        case .code(_, let code, _):
            return code
        case .table(let table):
            return ([table.header] + table.rows).map { $0.map(inlinePlain).joined(separator: "\t") }.joined(separator: "\n")
        case .rule:
            return "—"
        case .image(let alt, let path):
            return alt.isEmpty ? path : "\(alt): \(path)"
        }
    }

    /// Inline Markdown as plain text (nothing to interpret: the source itself).
    static func inlinePlain(_ source: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return source }
        return String(parsed.characters)
    }

    // MARK: Line reading

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Leading spaces of a line (a tab counts as four).
    private static func indent(of line: Substring) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    private static func fenceOpening(_ line: Substring) -> (ticks: Int, language: String?)? {
        guard indent(of: line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        let ticks = trimmed.prefix { $0 == "`" }.count
        guard ticks >= 3 else { return nil }
        let info = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
        guard !info.contains("`") else { return nil } // ```inline``` on one line is not a fence
        let language = info.split(separator: " ").first.map(String.init)
        return (ticks, language)
    }

    private static func isFenceClosing(_ line: Substring, minimum: Int) -> Bool {
        guard indent(of: line) <= 3 else { return false }
        let trimmed = line.drop { $0 == " " }
        let ticks = trimmed.prefix { $0 == "`" }.count
        return ticks >= minimum && trimmed.dropFirst(ticks).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func heading(_ line: Substring) -> (level: Int, text: String)? {
        guard indent(of: line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing run of hashes after a space ("## Título ##"); "C#" keeps its own.
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == "#" { end = text.index(before: end) }
        if end < text.endIndex, end > text.startIndex, text[text.index(before: end)] == " " {
            while end > text.startIndex, text[text.index(before: end)] == " " { end = text.index(before: end) }
            text.removeSubrange(end...)
        }
        return (hashes, text)
    }

    private static func isRule(_ line: Substring) -> Bool {
        guard indent(of: line) <= 3 else { return false }
        guard let first = line.first(where: { $0 != " " && $0 != "\t" }), "-*_".contains(first) else { return false }
        var count = 0
        for character in line where character != " " && character != "\t" {
            guard character == first else { return false }
            count += 1
        }
        return count >= 3
    }

    private static func isQuote(_ line: Substring) -> Bool {
        indent(of: line) <= 3 && line.drop { $0 == " " }.first == ">"
    }

    private static func quoteContent(_ line: Substring) -> String {
        var rest = line.drop { $0 == " " }.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A picture alone on its line, `![what it shows](address)`, whose address is a picture file on this Mac: an absolute
    /// path, `~/…`, a `file://` URL, or any of them in `<…>` (a path with spaces). Anything else stays text: a web address
    /// (the app never fetches what a reply points at, so a reply cannot send anything out), a picture in the middle of a
    /// sentence, a file that is not a picture. Whether the file is there is the view's business: the parser reads no disk.
    static func image(_ line: Substring) -> (alt: String, path: String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("!["), text.hasSuffix(")"), let middle = text.range(of: "](") else { return nil }
        let alt = text[text.index(text.startIndex, offsetBy: 2)..<middle.lowerBound]
        guard !alt.contains("]") else { return nil }
        var address = text[middle.upperBound..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("<"), address.hasSuffix(">") {
            address = String(address.dropFirst().dropLast())
        } else if address.contains(" ") {
            return nil
        }
        let path: String
        if address.hasPrefix("file://") {
            guard let url = URL(string: address), url.isFileURL, !url.path.isEmpty else { return nil }
            path = url.path
        } else if address.hasPrefix("~/") {
            path = NSString(string: address).expandingTildeInPath
        } else if address.hasPrefix("/"), !address.hasPrefix("//") { // "//host/…" is a web address in Markdown
            path = address
        } else {
            return nil
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard ImageProcessing.isImageFile(file) else { return nil }
        return (alt.trimmingCharacters(in: .whitespaces), file.path)
    }

    /// The start of a list item: its indentation, mark and text.
    private static func listMarker(_ line: Substring) -> (indent: Int, marker: MarkdownListItem.Marker, text: String)? {
        let width = indent(of: line)
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        if "-*+•".contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            var text = rest.drop { $0 == " " || $0 == "\t" }
            // "[ ] tarefa" / "[x] tarefa"
            if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                let done = !text.hasPrefix("[ ] ")
                text = text.dropFirst(4)
                return (width, .task(done: done), String(text))
            }
            return (width, .bullet, String(text))
        }
        if first.isASCII, first.isNumber {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, let number = Int(digits) else { return nil }
            let rest = body.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return (width, .number(number), String(after.drop { $0 == " " || $0 == "\t" }))
        }
        return nil
    }

    /// Whether a line begins a block of its own (so it ends the paragraph above it).
    private static func startsBlock(_ line: Substring, at index: Int, in lines: [Substring]) -> Bool {
        if fenceOpening(line) != nil || heading(line) != nil || isRule(line) || isQuote(line) || listMarker(line) != nil
            || image(line) != nil { return true }
        return index + 1 < lines.count && table(startingAt: index, in: lines) != nil
    }

    /// Items of a list from `start`, nesting by indentation. A line that continues an item (indented, not a new
    /// item) joins its text on a new line.
    private static func list(startingAt start: Int, in lines: [Substring]) -> (items: [MarkdownListItem], next: Int) {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { break }
            if let item = listMarker(line), !isRule(line) {
                while let last = indents.last, item.indent < last { indents.removeLast() }
                if indents.last.map({ item.indent > $0 }) ?? true { indents.append(item.indent) }
                items.append(MarkdownListItem(depth: min(indents.count - 1, 3), marker: item.marker, text: item.text))
            } else if !items.isEmpty, indent(of: line) >= 2, !startsBlock(line, at: index, in: lines) {
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
            index += 1
        }
        return (items, max(index, start + 1))
    }

    private static func table(startingAt start: Int, in lines: [Substring]) -> (table: MarkdownTable, next: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let separator = cells(of: lines[start + 1])
        guard !separator.isEmpty, separator.allSatisfy(isSeparatorCell) else { return nil }
        let header = cells(of: lines[start])
        guard header.count == separator.count else { return nil }
        let alignments = separator.map { cell -> MarkdownTable.Alignment in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, !isBlank(lines[index]), lines[index].contains("|") {
            var row = cells(of: lines[index])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        return (MarkdownTable(header: header, rows: rows, alignments: alignments), index)
    }

    private static func cells(of line: Substring) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\" + String(character))
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return core.count >= 1 && core.allSatisfy { $0 == "-" } && cell.contains("-")
    }
}
