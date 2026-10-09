import Foundation

/// Reads Excel workbooks (.xlsx, .xlsm) and PowerPoint decks (.pptx) as text. Both are zip files of XML, opened with the
/// system's `unzip`; nothing is written to disk.
enum OfficeReader {
    static let extensions: Set<String> = ["xlsx", "xlsm", "pptx"]
    /// Most rows of one sheet that are shown; a spreadsheet of a million rows is for `run_command`.
    static let maxRows = 20_000
    /// Largest XML part that is read (a big sheet is tens of megabytes of XML).
    static let maxPartBytes = 120_000_000

    static func isOffice(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func text(at url: URL) throws -> String {
        let isDeck = url.pathExtension.lowercased() == "pptx"
        guard let names = entries(of: url) else {
            throw ToolError("Não consegui abrir \(url.lastPathComponent): o arquivo está corrompido ou não é um \(isDeck ? "PowerPoint" : "Excel") válido.")
        }
        return isDeck ? try deck(url, names: names) : try workbook(url, names: names)
    }

    // MARK: Workbook

    private static func workbook(_ url: URL, names: [String]) throws -> String {
        let strings = part(url, "xl/sharedStrings.xml").map { SharedStringsParser.parse($0) } ?? []
        let sheets = sheetList(url, names: names)
        if sheets.isEmpty { throw ToolError("A planilha \(url.lastPathComponent) não tem abas legíveis.") }
        var blocks: [String] = []
        for (index, sheet) in sheets.enumerated() {
            guard let data = part(url, sheet.path) else { continue }
            let rows = SheetParser.parse(data, strings: strings, maxRows: maxRows + 1)
            var lines = rows.rows.prefix(maxRows).map { row in "\(row.number): " + row.cells.joined(separator: "\t") }
            if rows.rows.count > maxRows { lines.append("[... a aba tem mais linhas; leia o resto com run_command ...]") }
            if rows.cutColumns { lines.append("[... colunas além da \(SheetParser.maxColumns)ª foram omitidas; leia o resto com run_command ...]") }
            blocks.append("## Aba \(index + 1): \(sheet.name) (\(rows.rows.count > maxRows ? "mais de \(maxRows)" : String(rows.rows.count)) linhas com dados)\n"
                          + (lines.isEmpty ? "(vazia)" : lines.joined(separator: "\n")))
        }
        return blocks.isEmpty ? "(planilha vazia)" : blocks.joined(separator: "\n\n")
    }

    /// The sheets in workbook order with the file each one lives in.
    private static func sheetList(_ url: URL, names: [String]) -> [(name: String, path: String)] {
        let listed = part(url, "xl/workbook.xml").map { WorkbookParser.parse($0) } ?? []
        let relationships = part(url, "xl/_rels/workbook.xml.rels").map { RelationshipsParser.parse($0) } ?? [:]
        var sheets: [(String, String)] = []
        for item in listed {
            guard let target = relationships[item.relationship] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            if names.contains(path) { sheets.append((item.name, path)) }
        }
        if !sheets.isEmpty { return sheets }
        // Without a readable index, the sheets in numeric order.
        return numbered(names, prefix: "xl/worksheets/sheet").enumerated().map { ("Planilha\($0.offset + 1)", $0.element) }
    }

    // MARK: Deck

    private static func deck(_ url: URL, names: [String]) throws -> String {
        let slides = numbered(names, prefix: "ppt/slides/slide")
        guard !slides.isEmpty else { throw ToolError("A apresentação \(url.lastPathComponent) não tem slides legíveis.") }
        var blocks: [String] = []
        for (index, path) in slides.enumerated() {
            guard let data = part(url, path) else { continue }
            var block = "## Slide \(index + 1)\n" + (DrawingTextParser.parse(data).joined(separator: "\n"))
            // Speaker notes sit in a part with the same number.
            let number = path.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
            if let notes = part(url, "ppt/notesSlides/notesSlide\(number).xml") {
                let text = DrawingTextParser.parse(notes).filter { Int($0) == nil }.joined(separator: "\n")
                if !text.isEmpty { block += "\n[Notas do apresentador]\n" + text }
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Zip

    /// `<prefix>N.xml` entries in numeric order of N.
    private static func numbered(_ names: [String], prefix: String) -> [String] {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".xml"),
                  let number = Int(name.dropFirst(prefix.count).dropLast(".xml".count)) else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The names inside the zip, nil when it cannot be read as one.
    private static func entries(of url: URL) -> [String]? {
        guard let data = run(["-Z1", url.path], limit: 8_000_000) else { return nil }
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return names.isEmpty ? nil : names
    }

    private static func part(_ url: URL, _ name: String) -> Data? { run(["-p", url.path, name], limit: maxPartBytes) }

    /// `unzip` with its output read up to `limit` bytes; nil when it fails or has more than that.
    private static func run(_ arguments: [String], limit: Int) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                process.terminate()
                return nil
            }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: - XML parsers

/// Collects the text of every `<si>` (a shared string), leaving out phonetic hints.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false
    private var phonetic = 0

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "si": inItem = true; current = ""
        case "t": inText = inItem && phonetic == 0
        case "rPh": phonetic += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "t": inText = false
        case "rPh": phonetic -= 1
        case "si": strings.append(current); inItem = false
        default: break
        }
    }
}

/// `<sheet name= r:id=>` in order.
private final class WorkbookParser: NSObject, XMLParserDelegate {
    private var sheets: [(name: String, relationship: String)] = []

    static func parse(_ data: Data) -> [(name: String, relationship: String)] {
        let delegate = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.sheets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "sheet", let sheetName = attributes["name"], let id = attributes["r:id"] ?? attributes["id"] else { return }
        sheets.append((sheetName, id))
    }
}

/// `Id → Target` of a relationships file.
private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        targets[id] = target
    }
}

/// The rows of one worksheet as text, columns kept in place (an empty cell is an empty string).
final class SheetParser: NSObject, XMLParserDelegate {
    struct Row { var number: Int; var cells: [String] }

    /// Columns kept per row: the cells beyond are dropped, so a stray far-right value cannot make a row of millions.
    static let maxColumns = 1_024

    private let strings: [String]
    private let maxRows: Int
    private(set) var rows: [Row] = []
    /// Whether a cell beyond `maxColumns` was dropped.
    private(set) var cutColumns = false
    private var cells: [Int: String] = [:]
    private var rowNumber = 0
    private var column = 0
    private var type = ""
    private var value = ""
    private var inValue = false
    private var inline = ""
    private var inInline = false
    private var inText = false

    init(strings: [String], maxRows: Int) {
        self.strings = strings
        self.maxRows = maxRows
    }

    static func parse(_ data: Data, strings: [String], maxRows: Int) -> SheetParser {
        let delegate = SheetParser(strings: strings, maxRows: maxRows)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    /// "AB12" → 27 (zero-based); nil for a reference past Excel's last column (XFD), which is not a real one.
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
            if index > 16_384 { return nil }
        }
        return max(index - 1, 0)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "row":
            cells = [:]
            rowNumber = attributes["r"].flatMap { Int($0) } ?? (rows.last.map { $0.number + 1 } ?? 1)
        case "c":
            column = attributes["r"].flatMap(Self.columnIndex) ?? ((cells.keys.max() ?? -1) + 1)
            type = attributes["t"] ?? ""
            value = ""
            inline = ""
        case "v": inValue = true
        case "is": inInline = true
        case "t": inText = inInline
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { value += string } else if inText { inline += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inValue = false
        case "t": inText = false
        case "is": inInline = false
        case "c":
            var text: String
            switch type {
            case "s": text = Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
            case "inlineStr": text = inline
            case "b": text = value == "1" ? "VERDADEIRO" : "FALSO"
            default: text = value
            }
            text = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            if !text.isEmpty {
                if column < Self.maxColumns { cells[column] = text } else { cutColumns = true }
            }
        case "row":
            if let last = cells.keys.max() {
                rows.append(Row(number: rowNumber, cells: (0...last).map { cells[$0] ?? "" }))
                if rows.count >= maxRows { parser.abortParsing() }
            }
        default: break
        }
    }
}

/// The text of a slide: one entry per paragraph (`<a:p>`) with its runs (`<a:t>`) joined.
private final class DrawingTextParser: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = DrawingTextParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.paragraphs
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "a:t" { inText = true } else if name == "a:p" { current = "" } else if name == "a:br" { current += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "a:t" {
            inText = false
        } else if name == "a:p" {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(text) }
            current = ""
        }
    }
}
