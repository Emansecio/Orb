import Compression
import Foundation

/// Reads Excel workbooks (.xlsx, .xlsm) and PowerPoint decks (.pptx) as text. Both are zip files of XML, opened in-process
/// with `Compression` (zero `/usr/bin/unzip` forks; falls back to `unzip` only for uncommon compression methods).
enum OfficeReader {
    static let extensions: Set<String> = ["xlsx", "xlsm", "pptx"]
    /// Most rows of one sheet that are shown; a spreadsheet of a million rows is for `run_command`.
    static let maxRows = 20_000
    /// Largest XML part that is read (a big sheet is tens of megabytes of XML).
    static let maxPartBytes = 120_000_000

    static func isOffice(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func text(at url: URL) throws -> String {
        let isDeck = url.pathExtension.lowercased() == "pptx"
        let source = ZipSource(url: url)
        guard let names = source.entries(), !names.isEmpty else {
            throw ToolError("Não consegui abrir \(url.lastPathComponent): o arquivo está corrompido ou não é um \(isDeck ? "PowerPoint" : "Excel") válido.")
        }
        return isDeck ? try deck(source, url: url, names: names) : try workbook(source, url: url, names: names)
    }

    // MARK: Workbook

    private static func workbook(_ source: ZipSource, url: URL, names: [String]) throws -> String {
        let nameSet = Set(names)
        let strings = nameSet.contains("xl/sharedStrings.xml")
            ? source.part("xl/sharedStrings.xml").map { SharedStringsParser.parse($0) } ?? [] : []
        let sheets = sheetList(source, names: names, nameSet: nameSet)
        if sheets.isEmpty { throw ToolError("A planilha \(url.lastPathComponent) não tem abas legíveis.") }
        var blocks: [String] = []
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation() // ⌘. reaches a big workbook between its sheets
            guard let data = source.part(sheet.path) else { continue }
            let rows = SheetParser.parse(data, strings: strings, maxRows: maxRows + 1)
            blocks.append(sheetBlock(number: index + 1, name: sheet.name, rows: rows.rows, cutColumns: rows.cutColumns))
        }
        return blocks.isEmpty ? "(planilha vazia)" : blocks.joined(separator: "\n\n")
    }

    /// One sheet as text. `rows` holds at most `maxRows + 1` rows (the extra one only tells there are more); the
    /// legacy `.xls` reader prints its sheets through here too, so both formats read the same.
    static func sheetBlock(number: Int, name: String, rows: [SheetParser.Row], cutColumns: Bool) -> String {
        var lines = rows.prefix(maxRows).map { row in "\(row.number): " + row.cells.joined(separator: "\t") }
        if rows.count > maxRows { lines.append("[... a aba tem mais linhas; leia o resto com run_command ...]") }
        if cutColumns { lines.append("[... colunas além da \(SheetParser.maxColumns)ª foram omitidas; leia o resto com run_command ...]") }
        return "## Aba \(number): \(name) (\(rows.count > maxRows ? "mais de \(maxRows)" : String(rows.count)) linhas com dados)\n"
            + (lines.isEmpty ? "(vazia)" : lines.joined(separator: "\n"))
    }

    /// The sheets in workbook order with the file each one lives in.
    private static func sheetList(_ source: ZipSource, names: [String], nameSet: Set<String>) -> [(name: String, path: String)] {
        let listed = nameSet.contains("xl/workbook.xml") ? source.part("xl/workbook.xml").map { WorkbookParser.parse($0) } ?? [] : []
        let relationships = nameSet.contains("xl/_rels/workbook.xml.rels")
            ? source.part("xl/_rels/workbook.xml.rels").map { RelationshipsParser.parse($0) } ?? [:] : [:]
        var sheets: [(String, String)] = []
        for item in listed {
            guard let target = relationships[item.relationship] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            if nameSet.contains(path) { sheets.append((item.name, path)) }
        }
        if !sheets.isEmpty { return sheets }
        // Without a readable index, the sheets in numeric order.
        return numbered(names, prefix: "xl/worksheets/sheet").enumerated().map { ("Planilha\($0.offset + 1)", $0.element) }
    }

    // MARK: Deck

    private static func deck(_ source: ZipSource, url: URL, names: [String]) throws -> String {
        let nameSet = Set(names)
        let slides = numbered(names, prefix: "ppt/slides/slide")
        guard !slides.isEmpty else { throw ToolError("A apresentação \(url.lastPathComponent) não tem slides legíveis.") }
        var blocks: [String] = []
        for (index, path) in slides.enumerated() {
            try Task.checkCancellation()
            guard let data = source.part(path) else { continue }
            var block = "## Slide \(index + 1)\n" + (DrawingTextParser.parse(data).joined(separator: "\n"))
            if let notesPath = notesPart(source, slidePath: path, nameSet: nameSet), nameSet.contains(notesPath),
               let notes = source.part(notesPath) {
                let text = DrawingTextParser.parse(notes).filter { Int($0) == nil }.joined(separator: "\n")
                if !text.isEmpty { block += "\n[Notas do apresentador]\n" + text }
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// The part with a slide's speaker notes: the one its relationships file points to (PowerPoint numbers the notes parts in
    /// sequence among the slides that have notes, so slide 3 may own `notesSlide1.xml`). Without a relationships file, the part
    /// with the slide's own number.
    private static func notesPart(_ source: ZipSource, slidePath: String, nameSet: Set<String>) -> String? {
        let file = slidePath.dropFirst("ppt/slides/".count)
        let relsPath = "ppt/slides/_rels/\(file).rels"
        guard nameSet.contains(relsPath), let data = source.part(relsPath) else {
            let number = slidePath.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
            return "ppt/notesSlides/notesSlide\(number).xml"
        }
        guard let target = RelationshipsParser.targets(ofType: "/notesSlide", in: data).first else { return nil }
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = ["ppt", "slides"]
        for component in target.split(separator: "/") {
            if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
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

    /// In-process ZIP reader over mmap + `Compression` (stored & raw deflate, including ZIP64); falls back to `/usr/bin/unzip`
    /// only when an archive uses an uncommon compression method or layout.
    private struct ZipSource {
        let url: URL
        let archive: NativeZip?

        init(url: URL) {
            self.url = url
            self.archive = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(NativeZip.init)
        }

        func entries() -> [String]? {
            if let archive { return archive.names }
            guard let data = OfficeReader.run(["-Z1", url.path], limit: 8_000_000) else { return nil }
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            return names.isEmpty ? nil : names
        }

        func part(_ name: String) -> Data? {
            if let archive {
                switch archive.extract(name, limit: OfficeReader.maxPartBytes) {
                case .data(let data): return data
                case .tooLarge, .missing: return nil
                case .unsupported: break
                }
            }
            return OfficeReader.run(["-p", url.path, name], limit: OfficeReader.maxPartBytes)
        }
    }

    private struct NativeZip {
        struct Entry { let method: UInt16; let compressedSize: Int; let localOffset: Int }
        enum Extraction { case data(Data), missing, tooLarge, unsupported }

        let data: Data
        let names: [String]
        let entries: [String: Entry]

        init?(_ data: Data) {
            guard data.count >= 22 else { return nil }
            let minOffset = max(0, data.count - 65_557)
            var eocdOffset: Int?
            for offset in stride(from: data.count - 22, through: minOffset, by: -1) {
                if Self.u32(data, offset) == 0x0605_4b50 { eocdOffset = offset; break }
            }
            guard let eocd = eocdOffset else { return nil }
            var cdSize = Int(Self.u32(data, eocd + 12))
            var cdOffset = Int(Self.u32(data, eocd + 16))
            if cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
                // ZIP64 End of Central Directory Locator sits 20 bytes before EOCD.
                guard eocd >= 20, Self.u32(data, eocd - 20) == 0x0706_4b50 else { return nil }
                let z64 = Int(Self.u64(data, eocd - 12))
                guard z64 >= 0, z64 + 56 <= data.count, Self.u32(data, z64) == 0x0606_4b50 else { return nil }
                cdSize = Int(Self.u64(data, z64 + 40))
                cdOffset = Int(Self.u64(data, z64 + 48))
            }
            guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else { return nil }
            var names: [String] = []
            var entries: [String: Entry] = [:]
            var cursor = cdOffset
            let end = cdOffset + cdSize
            while cursor + 46 <= end {
                guard Self.u32(data, cursor) == 0x0201_4b50 else { return nil }
                let method = Self.u16(data, cursor + 10)
                var compSize = Int(Self.u32(data, cursor + 20))
                var uncompSize = Int(Self.u32(data, cursor + 24))
                let nameLen = Int(Self.u16(data, cursor + 28))
                let extraLen = Int(Self.u16(data, cursor + 30))
                let commentLen = Int(Self.u16(data, cursor + 32))
                var localOffset = Int(Self.u32(data, cursor + 42))
                let headerEnd = cursor + 46 + nameLen + extraLen + commentLen
                guard headerEnd <= end else { return nil }
                let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLen)], as: UTF8.self)
                if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                    var ex = cursor + 46 + nameLen
                    let exEnd = ex + extraLen
                    while ex + 4 <= exEnd {
                        let tag = Self.u16(data, ex), len = Int(Self.u16(data, ex + 2))
                        var p = ex + 4
                        if tag == 0x0001, p + len <= exEnd {
                            if uncompSize == 0xFFFF_FFFF, p + 8 <= ex + 4 + len { uncompSize = Int(Self.u64(data, p)); p += 8 }
                            if compSize == 0xFFFF_FFFF, p + 8 <= ex + 4 + len { compSize = Int(Self.u64(data, p)); p += 8 }
                            if localOffset == 0xFFFF_FFFF, p + 8 <= ex + 4 + len { localOffset = Int(Self.u64(data, p)) }
                            break
                        }
                        ex += 4 + len
                    }
                }
                names.append(name)
                entries[name] = Entry(method: method, compressedSize: compSize, localOffset: localOffset)
                cursor = headerEnd
            }
            guard !names.isEmpty else { return nil }
            self.data = data
            self.names = names
            self.entries = entries
        }

        func extract(_ name: String, limit: Int) -> Extraction {
            guard let entry = entries[name] else { return .missing }
            let o = entry.localOffset
            guard o >= 0, o + 30 <= data.count, Self.u32(data, o) == 0x0403_4b50 else { return .unsupported }
            let start = o + 30 + Int(Self.u16(data, o + 26)) + Int(Self.u16(data, o + 28))
            let end = start + entry.compressedSize
            guard start >= 0, end <= data.count else { return .unsupported }
            if entry.method == 0 {
                return entry.compressedSize > limit ? .tooLarge : .data(Data(data[start..<end]))
            }
            guard entry.method == 8 else { return .unsupported }
            return inflate(data[start..<end], limit: limit)
        }

        private func inflate(_ slice: Data, limit: Int) -> Extraction {
            var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                return .unsupported
            }
            defer { compression_stream_destroy(&stream) }
            let chunkSize = 65_536
            var out = Data()
            var scratch = [UInt8](repeating: 0, count: chunkSize)
            return slice.withUnsafeBytes { raw -> Extraction in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return .data(Data()) }
                stream.src_ptr = base
                stream.src_size = raw.count
                while true {
                    let produced: (status: compression_status, count: Int) = scratch.withUnsafeMutableBufferPointer { dst in
                        stream.dst_ptr = dst.baseAddress!
                        stream.dst_size = dst.count
                        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        return (status, dst.count - stream.dst_size)
                    }
                    if produced.count > 0 {
                        if out.count + produced.count > limit { return .tooLarge }
                        out.append(contentsOf: scratch[0..<produced.count])
                    }
                    if produced.status == COMPRESSION_STATUS_END { return .data(out) }
                    if produced.status != COMPRESSION_STATUS_OK { return .unsupported }
                    if produced.count == 0 && stream.src_size == 0 { return .data(out) }
                }
            }
        }

        private static func u16(_ d: Data, _ i: Int) -> UInt16 {
            UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
        }
        private static func u32(_ d: Data, _ i: Int) -> UInt32 {
            UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
        }
        private static func u64(_ d: Data, _ i: Int) -> UInt64 {
            UInt64(u32(d, i)) | (UInt64(u32(d, i + 4)) << 32)
        }
    }

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
    /// Type and Target of each relationship, in file order.
    private var typed: [(type: String, target: String)] = []

    static func parse(_ data: Data) -> [String: String] { run(data).targets }

    /// The targets whose relationship type ends with `suffix` (".../relationships/notesSlide").
    static func targets(ofType suffix: String, in data: Data) -> [String] {
        run(data).typed.filter { $0.type.hasSuffix(suffix) }.map(\.target)
    }

    private static func run(_ data: Data) -> RelationshipsParser {
        let delegate = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "Relationship", let target = attributes["Target"] else { return }
        if let id = attributes["Id"] { targets[id] = target }
        if let type = attributes["Type"] { typed.append((type, target)) }
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
            // Out-of-range numbers would overflow the `+ 1` below; fall back to the sequential number instead.
            rowNumber = attributes["r"].flatMap { Int($0) }.flatMap { (1...1_048_576).contains($0) ? $0 : nil } ?? (rows.last.map { $0.number + 1 } ?? 1)
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
