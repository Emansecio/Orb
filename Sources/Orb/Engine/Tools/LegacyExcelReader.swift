import Foundation

/// Reads old Excel files (`.xls`) as text, in the same format `OfficeReader` gives an `.xlsx`: a `## Aba N: name` block per
/// sheet with `<row>: cell<TAB>cell` lines. The extension is only a hint, because three very different things carry it:
///  - a real binary workbook (OLE2 / Compound File with BIFF8 or BIFF5 records), parsed here byte by byte;
///  - HTML that a web system saved as `.xls` (the most common export), whose `<table>`s become sheets;
///  - SpreadsheetML 2003, Excel's XML flavour.
/// Numbers are written the way `SheetParser` writes them (integers without ".0"). Dates are NOT converted: like in an
/// `.xlsx`, they stay the serial number the file stores (telling a date from a number takes the cell's number format).
/// Pure Foundation: nothing is written to disk and no process is started.
enum LegacyExcelReader {
    static func isLegacyExcel(_ url: URL) -> Bool { url.pathExtension.lowercased() == "xls" }

    static func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // An .xlsx saved under the old extension is common; the zip reader handles it.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try OfficeReader.text(at: url) }
        return try text(data, name: url.lastPathComponent)
    }

    static func text(_ data: Data, name: String) throws -> String {
        guard !data.isEmpty else { throw ToolError("A planilha \(name) está vazia (0 bytes).") }
        let sheets: [Sheet]
        if data.starts(with: CompoundFile.signature) {
            sheets = try BinaryWorkbook.sheets(CompoundFile(Array(data), name: name), name: name)
        } else if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            throw ToolError("\(name) é um arquivo .xlsx com extensão .xls; renomeie para .xlsx para ler.")
        } else {
            switch textKind(data) {
            case .html:
                sheets = try HTMLTables.sheets(decodeText(data), name: name)
            case .spreadsheetML:
                sheets = try SpreadsheetML.sheets(data, name: name)
            case nil:
                throw ToolError("\(name) não parece uma planilha Excel legível (nem .xls binário, nem HTML, nem XML do Excel 2003). "
                    + "Se for texto simples, olhe o começo com run_command (head).")
            }
        }
        let blocks = sheets.enumerated().map { OfficeReader.sheetBlock(number: $0.offset + 1, name: $0.element.name, rows: $0.element.rows,
                                                                       cutColumns: $0.element.cutColumns) }
        return blocks.isEmpty ? "(planilha vazia)" : blocks.joined(separator: "\n\n")
    }

    // MARK: Shared pieces

    /// One sheet ready to print: at most `OfficeReader.maxRows + 1` rows, so the renderer can tell there are more.
    struct Sheet {
        var name: String
        var rows: [SheetParser.Row]
        var cutColumns = false
    }

    /// Cells collected in any order (a binary sheet is not strictly sorted), turned into rows by `rows()`.
    struct SparseSheet {
        private var cells: [Int: [(column: Int, text: String)]] = [:]
        private(set) var cutColumns = false

        mutating func set(row: Int, column: Int, _ raw: String) {
            let text = LegacyExcelReader.clean(raw)
            guard !text.isEmpty else { return }
            guard column < SheetParser.maxColumns else { cutColumns = true; return }
            cells[row, default: []].append((column, text))
        }

        func rows() -> [SheetParser.Row] {
            cells.keys.sorted().prefix(OfficeReader.maxRows + 1).map { row in
                let entries = cells[row] ?? []
                var line = [String](repeating: "", count: (entries.map(\.column).max() ?? 0) + 1)
                for entry in entries { line[entry.column] = entry.text }
                return SheetParser.Row(number: row + 1, cells: line)
            }
        }
    }

    /// A cell's text on one line, like `SheetParser` leaves it.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// 12 → "12", 12.5 → "12.5" (shortest text that reads back as the same number).
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "#NUM!" }
        if value == value.rounded(), abs(value) < 9e15 { return String(Int64(value)) }
        return "\(value)"
    }

    enum TextKind { case html, spreadsheetML }

    /// What a file that is not a binary workbook is, by its first kilobytes; nil when it is neither.
    private static func textKind(_ data: Data) -> TextKind? {
        let head: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            head = String(decodeText(Data(data.prefix(16_000))).prefix(8_000)).lowercased()
        } else {
            // Latin-1 view: tags are ASCII in every encoding that matters here.
            head = String(data.prefix(8_000).map { Character(Unicode.Scalar($0)) }).lowercased()
        }
        if head.contains("urn:schemas-microsoft-com:office:spreadsheet"), head.contains("<workbook") { return .spreadsheetML }
        let markers = ["<html", "<!doctype", "<table", "<head", "<body", "<meta", "<tr"]
        return markers.contains { head.contains($0) } ? .html : nil
    }

    /// HTML bytes as text: a byte-order mark decides; else the page's own `charset` unless it is UTF-8/ASCII, where UTF-8 is
    /// tried first (a page that says ascii and carries accents is nearly always UTF-8) and Windows-1252 catches the rest.
    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        let head = String(body.prefix(2_048).map { Character(Unicode.Scalar($0)) }).lowercased()
        if let declared = declaredCharset(head), !["utf-8", "utf8", "us-ascii", "ascii"].contains(declared),
           let encoding = stringEncoding(ianaName: declared), let text = String(data: body, encoding: encoding) {
            return text
        }
        if let text = String(data: body, encoding: .utf8) { return text }
        return String(data: body, encoding: .windowsCP1252) ?? String(data: body, encoding: .isoLatin1) ?? ""
    }

    private static func declaredCharset(_ head: String) -> String? {
        guard let range = head.range(of: "charset") else { return nil }
        var rest = head[range.upperBound...].drop { $0 == " " }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\"" || $0 == "'" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func stringEncoding(ianaName: String) -> String.Encoding? {
        // Latin-1 pages are really Windows-1252 in practice (curly quotes and the like).
        if ["iso-8859-1", "latin1", "iso8859-1", "windows-1252", "cp1252"].contains(ianaName) { return .windowsCP1252 }
        let cf = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// 8-bit text of a BIFF5 file (or any other) in its code page: 1252 is the usual one, 1200 is UTF-16.
    static func decode8(_ bytes: ArraySlice<UInt8>, codepage: Int) -> String {
        let data = Data(bytes)
        switch codepage {
        case 1200: return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16LittleEndian) ?? ""
        case 65001: return String(data: data, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        case 1252: break
        default:
            let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(max(codepage, 0)))
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return text }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - Little-endian reads that never trap

private extension Array where Element == UInt8 {
    func le16(_ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}

// MARK: - Compound File Binary (OLE2)

/// The container of a binary workbook: sectors chained by a FAT, a directory of named streams, and a "mini stream" that
/// holds the streams under 4096 bytes. Handles 512- and 4096-byte sectors and a DIFAT that spills out of the header.
private struct CompoundFile {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let firstSpecial: UInt32 = 0xFFFF_FFFA   // from here on: DIFSECT, FATSECT, ENDOFCHAIN, FREESECT

    struct Entry {
        var name: String
        var type: Int   // 1 storage, 2 stream, 5 root
        var start: UInt32
        var size: Int
    }

    private let bytes: [UInt8]
    private let shift: Int
    private let miniShift: Int
    private let cutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: [UInt8]
    private let entries: [Entry]

    init(_ bytes: [UInt8], name: String) throws {
        let corrupt = ToolError("Não consegui abrir \(name): o arquivo .xls está corrompido ou truncado.")
        guard bytes.count >= 512 else { throw corrupt }
        self.bytes = bytes
        let shift = bytes.le16(0x1E)
        guard shift == 9 || shift == 12 else { throw corrupt }
        self.shift = shift
        miniShift = max(bytes.le16(0x20), 1)
        cutoff = Int(bytes.le32(0x38))
        let sectorSize = 1 << shift
        func offset(of sector: UInt32) -> Int { (Int(sector) + 1) << shift }

        // The FAT's own sectors: 109 in the header, the rest in a chain of DIFAT sectors.
        var fatSectors: [UInt32] = (0..<109).map { bytes.le32(0x4C + 4 * $0) }.filter { $0 < Self.firstSpecial }
        var next = bytes.le32(0x44)
        var hops = 0
        while next < Self.firstSpecial, hops < Int(bytes.le32(0x48)), hops < 100_000 {
            let start = offset(of: next)
            guard start + sectorSize <= bytes.count else { break }
            fatSectors += (0..<(sectorSize / 4 - 1)).map { bytes.le32(start + 4 * $0) }.filter { $0 < Self.firstSpecial }
            next = bytes.le32(start + sectorSize - 4)
            hops += 1
        }
        var fat: [UInt32] = []
        for sector in fatSectors {
            let start = offset(of: sector)
            guard start < bytes.count else { continue }
            fat += stride(from: start, to: min(start + sectorSize, bytes.count) - 3, by: 4).map { bytes.le32($0) }
        }
        guard !fat.isEmpty else { throw corrupt }
        self.fat = fat

        let directory = Self.chain(bytes, shift: shift, fat: fat, start: bytes.le32(0x30), limit: nil)
        var entries: [Entry] = []
        for base in stride(from: 0, to: directory.count - 127, by: 128) {
            let nameLength = max(min(directory.le16(base + 64) / 2 - 1, 31), 0)
            let units = (0..<nameLength).map { UInt16(directory.le16(base + 2 * $0)) }
            var size = Int(directory.le32(base + 120))
            if shift == 12 { size |= Int(directory.le32(base + 124)) << 32 }
            entries.append(Entry(name: String(decoding: units, as: UTF16.self), type: Int(directory[base + 66]),
                                 start: directory.le32(base + 116), size: size))
        }
        guard let root = entries.first, root.type == 5 else { throw corrupt }
        self.entries = entries
        miniStream = Self.chain(bytes, shift: shift, fat: fat, start: root.start, limit: root.size)
        let miniFatBytes = Self.chain(bytes, shift: shift, fat: fat, start: bytes.le32(0x3C), limit: nil)
        miniFat = stride(from: 0, to: miniFatBytes.count - 3, by: 4).map { miniFatBytes.le32($0) }
    }

    func hasStream(_ name: String) -> Bool { entry(name) != nil }

    private func entry(_ name: String) -> Entry? {
        entries.first { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The content of the stream called `name`, nil when there is none.
    func stream(_ name: String) -> [UInt8]? {
        guard let entry = entry(name) else { return nil }
        if entry.size < cutoff { return miniChain(start: entry.start, size: entry.size) }
        return Self.chain(bytes, shift: shift, fat: fat, start: entry.start, limit: entry.size)
    }

    /// The sectors from `start` along the FAT, joined; stops at `limit` bytes, at the end of the chain or of a damaged file.
    private static func chain(_ bytes: [UInt8], shift: Int, fat: [UInt32], start: UInt32, limit: Int?) -> [UInt8] {
        var output: [UInt8] = []
        var sector = start
        var steps = 0
        let size = 1 << shift
        while sector < firstSpecial, steps <= fat.count {
            let begin = (Int(sector) + 1) << shift
            guard begin < bytes.count else { break }
            output += bytes[begin..<min(begin + size, bytes.count)]
            if let limit, output.count >= limit { return Array(output.prefix(limit)) }
            sector = Int(sector) < fat.count ? fat[Int(sector)] : 0xFFFF_FFFE
            steps += 1
        }
        return limit.map { Array(output.prefix($0)) } ?? output
    }

    private func miniChain(start: UInt32, size: Int) -> [UInt8] {
        var output: [UInt8] = []
        var sector = start
        var steps = 0
        let sectorSize = 1 << miniShift
        while sector < Self.firstSpecial, steps <= miniFat.count, output.count < size {
            let begin = Int(sector) << miniShift
            guard begin < miniStream.count else { break }
            output += miniStream[begin..<min(begin + sectorSize, miniStream.count)]
            sector = Int(sector) < miniFat.count ? miniFat[Int(sector)] : 0xFFFF_FFFE
            steps += 1
        }
        return Array(output.prefix(size))
    }
}

// MARK: - BIFF records

/// The BIFF8 (Excel 97-2003) and BIFF5 (Excel 5/95) workbook stream: the sheet list and shared strings from the globals
/// substream, then each worksheet's cell records.
private enum BinaryWorkbook {
    static func sheets(_ file: CompoundFile, name: String) throws -> [LegacyExcelReader.Sheet] {
        guard let stream = file.stream("Workbook") ?? file.stream("Book") else {
            if file.hasStream("EncryptedPackage") || file.hasStream("EncryptionInfo") {
                throw ToolError("A planilha \(name) está protegida por senha.")
            }
            throw ToolError("\(name) é um arquivo do Office, mas não é uma planilha Excel (não tem o fluxo Workbook).")
        }
        let globals = try Globals.parse(stream, name: name)
        var result: [LegacyExcelReader.Sheet] = []
        for sheet in globals.sheets where sheet.type == 0 {   // 0 worksheet; charts, macro sheets and VBA modules carry no cells
            let parsed = parseSheet(stream, from: sheet.offset, globals: globals)
            result.append(LegacyExcelReader.Sheet(name: LegacyExcelReader.clean(sheet.name), rows: parsed.rows(), cutColumns: parsed.cutColumns))
        }
        return result
    }

    // Record ids.
    private static let bof = 0x0809, eof = 0x000A, continueID = 0x003C

    struct Globals {
        var sheets: [(name: String, offset: Int, type: Int)] = []
        var strings: [String] = []
        var codepage = 1252
        var biff8 = true

        static func parse(_ stream: [UInt8], name: String) throws -> Globals {
            var globals = Globals()
            var position = 0
            var depth = 0
            while let record = BinaryWorkbook.record(stream, at: position) {
                position = record.payload.upperBound
                let payload = record.payload
                if depth == 0, record.id != BinaryWorkbook.bof {
                    throw ToolError("\(name) não tem o formato de planilha do Excel 97-2003 ou 5/95 (BIFF2-4 não é lido).")
                }
                switch record.id {
                case BinaryWorkbook.bof:
                    if depth == 0 { globals.biff8 = stream.le16(payload.lowerBound) >= 0x0600 }
                    depth += 1
                case BinaryWorkbook.eof:
                    return globals
                case 0x002F:
                    throw ToolError("A planilha \(name) está protegida por senha.")
                case 0x0042:
                    globals.codepage = stream.le16(payload.lowerBound)
                case 0x0085 where payload.count >= 8:
                    let type = Int(stream[payload.lowerBound + 5])
                    let offset = Int(stream.le32(payload.lowerBound))
                    var sheetName: String
                    if globals.biff8 {
                        var reader = ChunkReader(stream, [(payload.lowerBound + 6)..<payload.upperBound])
                        sheetName = reader.string(lengthBytes: 1) ?? ""
                    } else {
                        let length = Int(stream[payload.lowerBound + 6])
                        let end = min(payload.lowerBound + 7 + length, payload.upperBound)
                        sheetName = LegacyExcelReader.decode8(stream[(payload.lowerBound + 7)..<end], codepage: globals.codepage)
                    }
                    globals.sheets.append((sheetName, offset, type))
                case 0x00FC where payload.count >= 8:
                    var chunks = [(payload.lowerBound + 8)..<payload.upperBound]
                    chunks += BinaryWorkbook.continuations(stream, after: &position)
                    var reader = ChunkReader(stream, chunks)
                    let unique = Int(stream.le32(payload.lowerBound + 4))
                    while globals.strings.count < unique, let string = reader.string(lengthBytes: 2) { globals.strings.append(string) }
                default:
                    break
                }
            }
            return globals
        }
    }

    /// The record that starts at `offset`; a record cut short by the end of the stream keeps the bytes that are there.
    static func record(_ stream: [UInt8], at offset: Int) -> (id: Int, payload: Range<Int>)? {
        guard offset >= 0, offset + 4 <= stream.count else { return nil }
        let start = offset + 4
        return (stream.le16(offset), start..<min(start + stream.le16(offset + 2), stream.count))
    }

    /// The payloads of the CONTINUE records that follow, moving `position` past them.
    static func continuations(_ stream: [UInt8], after position: inout Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        while let record = record(stream, at: position), record.id == continueID {
            ranges.append(record.payload)
            position = record.payload.upperBound
        }
        return ranges
    }

    private static func parseSheet(_ stream: [UInt8], from offset: Int, globals: Globals) -> LegacyExcelReader.SparseSheet {
        var sheet = LegacyExcelReader.SparseSheet()
        var position = offset
        var depth = 0
        /// Cell of a formula whose result is text, which arrives in the STRING record that follows.
        var pendingString: (row: Int, column: Int)?
        while let record = record(stream, at: position) {
            position = record.payload.upperBound
            let p = record.payload.lowerBound
            let length = record.payload.count
            if record.id == bof { depth += 1; continue }
            if record.id == eof {
                depth -= 1
                if depth <= 0 { break }
                continue
            }
            // Substreams nested in the sheet (embedded charts) have cells of their own; those are not the sheet's.
            guard depth == 1 else { continue }
            let row = stream.le16(p), column = stream.le16(p + 2)
            switch record.id {
            case 0x00FD where length >= 10:   // LABELSST
                pendingString = nil
                let index = Int(stream.le32(p + 6))
                if globals.strings.indices.contains(index) { sheet.set(row: row, column: column, globals.strings[index]) }
            case 0x0204 where length >= 8:    // LABEL
                pendingString = nil
                sheet.set(row: row, column: column, labelText(stream, from: p + 6, to: record.payload.upperBound, globals: globals))
            case 0x0203 where length >= 14:   // NUMBER
                pendingString = nil
                sheet.set(row: row, column: column, LegacyExcelReader.number(Double(bitPattern: stream.le64(p + 6))))
            case 0x027E where length >= 10:   // RK
                pendingString = nil
                sheet.set(row: row, column: column, LegacyExcelReader.number(rk(stream.le32(p + 6))))
            case 0x00BD where length >= 6:    // MULRK: a run of (xf, rk) pairs, then the last column
                pendingString = nil
                let count = (length - 6) / 6
                for index in 0..<count {
                    sheet.set(row: row, column: column + index, LegacyExcelReader.number(rk(stream.le32(p + 4 + 6 * index + 2))))
                }
            case 0x0205 where length >= 8:    // BOOLERR
                pendingString = nil
                let value = Int(stream[p + 6])
                sheet.set(row: row, column: column, stream[p + 7] == 0 ? (value == 0 ? "FALSO" : "VERDADEIRO") : errorText(value))
            case 0x0006 where length >= 14:   // FORMULA: the result Excel cached
                pendingString = nil
                if stream.le16(p + 12) == 0xFFFF {
                    let value = Int(stream[p + 8])
                    switch stream[p + 6] {
                    case 0: pendingString = (row, column)
                    case 1: sheet.set(row: row, column: column, value == 0 ? "FALSO" : "VERDADEIRO")
                    case 2: sheet.set(row: row, column: column, errorText(value))
                    default: break   // 3: the empty string
                    }
                } else {
                    sheet.set(row: row, column: column, LegacyExcelReader.number(Double(bitPattern: stream.le64(p + 6))))
                }
            case 0x0207:                      // STRING: the text result of the formula before it
                guard let cell = pendingString else { continue }
                pendingString = nil
                var chunks = [record.payload]
                chunks += continuations(stream, after: &position)
                var reader = ChunkReader(stream, chunks)
                let value: String?
                if globals.biff8 {
                    value = reader.string(lengthBytes: 2)
                } else {
                    let first = min(p + 2, record.payload.upperBound)
                    let last = min(p + 2 + stream.le16(p), record.payload.upperBound)
                    value = LegacyExcelReader.decode8(stream[first..<last], codepage: globals.codepage)
                }
                sheet.set(row: cell.row, column: cell.column, value ?? "")
            default:
                break
            }
        }
        return sheet
    }

    /// The text of a LABEL record: `from` is where its string starts (the 2-byte length), `end` the end of the record.
    private static func labelText(_ stream: [UInt8], from: Int, to end: Int, globals: Globals) -> String {
        if globals.biff8 {
            var reader = ChunkReader(stream, [from..<end])
            return reader.string(lengthBytes: 2) ?? ""
        }
        let count = stream.le16(from)
        return LegacyExcelReader.decode8(stream[min(from + 2, end)..<min(from + 2 + count, end)], codepage: globals.codepage)
    }

    /// An RK number: 30 bits that are either an integer or the top of a double, optionally divided by 100.
    private static func rk(_ value: UInt32) -> Double {
        var number: Double
        if value & 2 != 0 {
            number = Double(Int32(bitPattern: value) >> 2)
        } else {
            number = Double(bitPattern: UInt64(value & 0xFFFF_FFFC) << 32)
        }
        if value & 1 != 0 { number /= 100 }
        return number
    }

    private static func errorText(_ code: Int) -> String {
        switch code {
        case 0x00: "#NULL!"
        case 0x07: "#DIV/0!"
        case 0x0F: "#VALUE!"
        case 0x17: "#REF!"
        case 0x1D: "#NAME?"
        case 0x24: "#NUM!"
        case 0x2A: "#N/A"
        default: "#ERRO"
        }
    }
}

/// Reads BIFF8 strings (XLUnicodeString) from a record and its CONTINUE records, which can cut the characters anywhere:
/// each continuation then starts with a fresh flags byte that may switch between 8-bit and UTF-16 characters.
private struct ChunkReader {
    private let bytes: [UInt8]
    private let chunks: [Range<Int>]
    private var chunk = 0
    private var offset: Int

    init(_ bytes: [UInt8], _ chunks: [Range<Int>]) {
        self.bytes = bytes
        self.chunks = chunks
        offset = chunks.first?.lowerBound ?? 0
    }

    /// Moves past exhausted chunks; false at the end of the data.
    private mutating func ready() -> Bool {
        while chunk < chunks.count, offset >= chunks[chunk].upperBound {
            chunk += 1
            if chunk < chunks.count { offset = chunks[chunk].lowerBound }
        }
        return chunk < chunks.count
    }

    private mutating func u8() -> Int? {
        guard ready() else { return nil }
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    private mutating func u16() -> Int? {
        guard let low = u8(), let high = u8() else { return nil }
        return low | high << 8
    }

    private mutating func u32() -> Int? {
        guard let low = u16(), let high = u16() else { return nil }
        return low | high << 16
    }

    private mutating func skip(_ count: Int) {
        var left = count
        while left > 0, ready() {
            let step = min(left, chunks[chunk].upperBound - offset)
            offset += step
            left -= step
        }
    }

    /// `count` characters. Whenever the current chunk runs out mid-string, the next one opens with the flags byte again.
    private mutating func characters(_ count: Int, wide initial: Bool) -> String? {
        var wide = initial
        var units: [UInt16] = []
        var remaining = count
        while remaining > 0 {
            guard chunk < chunks.count else { return nil }
            if offset >= chunks[chunk].upperBound {
                chunk += 1
                guard chunk < chunks.count else { return nil }
                offset = chunks[chunk].lowerBound
                guard offset < chunks[chunk].upperBound else { continue }
                wide = bytes[offset] & 1 != 0
                offset += 1
                continue
            }
            let available = (chunks[chunk].upperBound - offset) / (wide ? 2 : 1)
            let take = min(remaining, available)
            if take == 0 { offset = chunks[chunk].upperBound; continue }   // a stray odd byte
            for _ in 0..<take {
                if wide {
                    units.append(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                    offset += 2
                } else {
                    units.append(UInt16(bytes[offset]))   // 8-bit characters are the first 256 of Unicode
                    offset += 1
                }
            }
            remaining -= take
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A string with a 1- or 2-byte length; skips the rich-text runs and the phonetic data behind it.
    mutating func string(lengthBytes: Int) -> String? {
        guard let count = lengthBytes == 1 ? u8() : u16(), let flags = u8() else { return nil }
        let runs = flags & 8 != 0 ? (u16() ?? 0) : 0
        let phonetic = flags & 4 != 0 ? (u32() ?? 0) : 0
        guard let text = characters(count, wide: flags & 1 != 0) else { return nil }
        skip(runs * 4)
        skip(phonetic)
        return text
    }
}

// MARK: - HTML saved as .xls

/// The `<table>`s of an HTML page, each one a sheet. A small tokenizer, not a browser: scripts, styles and comments are
/// skipped (an Excel page keeps whole tables inside its JavaScript strings), nested tables become sheets of their own and
/// `rowspan` is ignored.
private enum HTMLTables {
    static func sheets(_ html: String, name: String) throws -> [LegacyExcelReader.Sheet] {
        var builder = Builder()
        builder.run(Array(html.utf8))
        let kept = builder.tables.sorted { $0.key < $1.key }.compactMap { entry -> (rows: [SheetParser.Row], cut: Bool)? in
            var cut = false
            var result: [SheetParser.Row] = []
            for (index, cells) in entry.value.enumerated() {
                var cells = cells
                while cells.last?.isEmpty == true { cells.removeLast() }
                guard !cells.isEmpty else { continue }
                if cells.count > SheetParser.maxColumns { cells = Array(cells.prefix(SheetParser.maxColumns)); cut = true }
                result.append(SheetParser.Row(number: index + 1, cells: cells))
                if result.count > OfficeReader.maxRows { break }
            }
            return result.isEmpty ? nil : (result, cut)
        }
        if kept.isEmpty, builder.tables.isEmpty {
            let lower = html.lowercased()
            if lower.contains("<frameset") || lower.contains("excel workbook frameset") {
                throw ToolError("\(name) é só a página-moldura de uma planilha que o Excel exportou como HTML: os dados ficam em arquivos numa "
                    + "pasta ao lado (algo como …_arquivos/sheet001.htm), que não veio junto. Peça a pasta inteira ou um .xlsx.")
            }
            throw ToolError("\(name) é uma página HTML sem nenhuma tabela; não há células para ler.")
        }
        return kept.enumerated().map { LegacyExcelReader.Sheet(name: "Tabela \($0.offset + 1)", rows: $0.element.rows, cutColumns: $0.element.cut) }
    }

    private struct Builder {
        struct Context {
            var index: Int
            var rows: [[String]] = []
            var row: [String]?
            var cell: String?
            var span = 1
        }

        private var stack: [Context] = []
        private var nextIndex = 0
        /// Finished tables by the order in which they opened.
        private(set) var tables: [Int: [[String]]] = [:]

        mutating func run(_ bytes: [UInt8]) {
            var text: [UInt8] = []
            var i = 0
            let n = bytes.count
            func flush() {
                guard !text.isEmpty else { return }
                add(HTMLTables.decodeEntities(String(decoding: text, as: UTF8.self)))
                text.removeAll(keepingCapacity: true)
            }
            while i < n {
                guard bytes[i] == UInt8(ascii: "<") else {
                    text.append(bytes[i])
                    i += 1
                    continue
                }
                if matches(bytes, i, "<!--") {
                    i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? n
                    continue
                }
                let next = i + 1 < n ? bytes[i + 1] : 0
                if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                    i = find(bytes, ">", from: i + 2).map { $0 + 1 } ?? n
                    continue
                }
                let closing = next == UInt8(ascii: "/")
                let nameStart = closing ? i + 2 : i + 1
                var j = nameStart
                while j < n, isLetterOrDigit(bytes[j]) { j += 1 }
                guard j > nameStart else {   // a lone "<" in the text
                    text.append(bytes[i])
                    i += 1
                    continue
                }
                let tag = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
                var end = j
                var quote: UInt8 = 0
                while end < n {
                    let byte = bytes[end]
                    if quote != 0 { if byte == quote { quote = 0 } } else if byte == 0x22 || byte == 0x27 { quote = byte } else if byte == UInt8(ascii: ">") { break }
                    end += 1
                }
                let attributes = String(decoding: bytes[j..<min(end, n)], as: UTF8.self).lowercased()
                i = min(end + 1, n)
                if !closing, tag == "script" || tag == "style" {
                    i = find(bytes, "</\(tag)", from: i, caseInsensitive: true).flatMap { find(bytes, ">", from: $0) }.map { $0 + 1 } ?? n
                    continue
                }
                flush()
                tagEvent(tag, closing: closing, attributes: attributes)
            }
            flush()
            while !stack.isEmpty { endTable() }
        }

        private mutating func tagEvent(_ tag: String, closing: Bool, attributes: String) {
            switch (tag, closing) {
            case ("table", false):
                stack.append(Context(index: nextIndex))
                nextIndex += 1
            case ("table", true): endTable()
            case ("tr", false): if !stack.isEmpty { closeRow(); stack[stack.count - 1].row = [] }
            case ("tr", true): closeRow()
            case ("td", false), ("th", false):
                guard !stack.isEmpty else { return }
                closeCell()
                let top = stack.count - 1
                if stack[top].row == nil { stack[top].row = [] }
                stack[top].cell = ""
                stack[top].span = min(max(Self.colspan(attributes), 1), SheetParser.maxColumns)
            case ("td", true), ("th", true): closeCell()
            case ("br", _), ("p", _), ("div", _), ("li", _): add(" ")
            default: break
            }
        }

        private mutating func add(_ text: String) {
            guard let top = stack.last, top.cell != nil else { return }
            stack[stack.count - 1].cell?.append(text)
        }

        private mutating func closeCell() {
            guard let top = stack.last, let cell = top.cell else { return }
            stack[stack.count - 1].row?.append(Self.collapse(cell))
            stack[stack.count - 1].row?.append(contentsOf: [String](repeating: "", count: top.span - 1))
            stack[stack.count - 1].cell = nil
            stack[stack.count - 1].span = 1
        }

        private mutating func closeRow() {
            guard !stack.isEmpty else { return }
            closeCell()
            let top = stack.count - 1
            if let row = stack[top].row { stack[top].rows.append(row) }
            stack[top].row = nil
        }

        private mutating func endTable() {
            guard !stack.isEmpty else { return }
            closeRow()
            let finished = stack.removeLast()
            tables[finished.index] = finished.rows
        }

        private static func colspan(_ attributes: String) -> Int {
            guard let range = attributes.range(of: "colspan") else { return 1 }
            let rest = attributes[range.upperBound...].drop { $0 == " " }
            guard rest.first == "=" else { return 1 }
            return Int(rest.dropFirst().drop { $0 == " " || $0 == "\"" || $0 == "'" }.prefix { $0.isNumber }) ?? 1
        }

        /// Runs of whitespace (the non-breaking space too) become one space; the ends are trimmed.
        static func collapse(_ text: String) -> String {
            var output = ""
            var pendingSpace = false
            for scalar in text.unicodeScalars {
                if scalar.properties.isWhitespace || scalar.value == 0x200B {
                    pendingSpace = !output.isEmpty
                } else {
                    if pendingSpace { output.append(" "); pendingSpace = false }
                    output.unicodeScalars.append(scalar)
                }
            }
            return output
        }

        private func isLetterOrDigit(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }

        private func matches(_ bytes: [UInt8], _ index: Int, _ pattern: String) -> Bool {
            let needle = Array(pattern.utf8)
            return index + needle.count <= bytes.count && bytes[index..<(index + needle.count)].elementsEqual(needle)
        }

        /// The index of the first `pattern` at or after `from`.
        private func find(_ bytes: [UInt8], _ pattern: String, from: Int, caseInsensitive: Bool = false) -> Int? {
            let needle = Array(pattern.utf8).map { caseInsensitive ? lower($0) : $0 }
            guard !needle.isEmpty, from >= 0, bytes.count >= needle.count else { return nil }
            var i = from
            while i + needle.count <= bytes.count {
                if (caseInsensitive ? lower(bytes[i]) : bytes[i]) == needle[0] {
                    var k = 1
                    while k < needle.count, (caseInsensitive ? lower(bytes[i + k]) : bytes[i + k]) == needle[k] { k += 1 }
                    if k == needle.count { return i }
                }
                i += 1
            }
            return nil
        }

        private func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte }
    }

    private static let namedEntities: [String: String] = {
        var table = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—",
                     "hellip": "…", "euro": "€", "laquo": "«", "raquo": "»", "ordm": "º", "ordf": "ª", "deg": "°", "copy": "©", "reg": "®",
                     "sect": "§", "middot": "·", "bull": "•", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]
        // Letters with accents, lower and upper case (&Aacute; is the upper-case form of &aacute;).
        let accented = ["agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "egrave": "è", "eacute": "é",
                        "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ograve": "ò",
                        "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "ugrave": "ù", "uacute": "ú", "ucirc": "û",
                        "uuml": "ü", "ccedil": "ç", "ntilde": "ñ"]
        for (name, letter) in accented {
            table[name] = letter
            table[name.prefix(1).uppercased() + name.dropFirst()] = letter.uppercased()
        }
        return table
    }()

    /// `&amp;`, `&nbsp;`, `&aacute;`, `&#233;`, `&#xE9;` and the like; anything unknown stays as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            output += rest[..<ampersand]
            let tail = rest[rest.index(after: ampersand)...]
            guard let semicolon = tail.prefix(12).firstIndex(of: ";"), let decoded = entity(String(tail[..<semicolon])) else {
                output.append("&")
                rest = tail
                continue
            }
            output += decoded
            rest = tail[tail.index(after: semicolon)...]
        }
        return output + rest
    }

    private static func entity(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return namedEntities[body] }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) } else { value = UInt32(digits) }
        guard let code = value else { return nil }
        // Browsers read 128-159 as Windows-1252 (curly quotes, the euro sign), not as control characters.
        if (0x80...0x9F).contains(code), let text = String(data: Data([UInt8(code)]), encoding: .windowsCP1252) { return text }
        return Unicode.Scalar(code).map { String(Character($0)) }
    }
}

// MARK: - SpreadsheetML 2003

/// Excel 2003's XML workbook: `Worksheet ss:Name` → `Row ss:Index?` → `Cell ss:Index?` → `Data`.
private final class SpreadsheetML: NSObject, XMLParserDelegate {
    private var sheets: [LegacyExcelReader.Sheet] = []
    private var sheetName = ""
    private var rows: [SheetParser.Row] = []
    private var cutColumns = false
    private var inSheet = false
    private var cells: [Int: String] = [:]
    private var rowNumber = 0
    private var column = 0
    private var mergeAcross = 0
    private var type = ""
    private var value = ""
    private var dataDepth = 0
    private var commentDepth = 0
    private var stopped = false

    static func sheets(_ data: Data, name: String) throws -> [LegacyExcelReader.Sheet] {
        let delegate = SpreadsheetML()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if !parser.parse(), !delegate.stopped, delegate.sheets.isEmpty {
            throw ToolError("Não consegui ler \(name): o XML do Excel 2003 está malformado.")
        }
        return delegate.sheets
    }

    /// The element or attribute name without its namespace prefix (`ss:Name` → `Name`).
    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let attributes = Dictionary(attributes.map { (local($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        switch local(name) {
        case "Worksheet":
            inSheet = true
            sheetName = attributes["Name"] ?? "Planilha\(sheets.count + 1)"
            rows = []
            cutColumns = false
            rowNumber = 0
        case "Row" where inSheet:
            cells = [:]
            rowNumber = attributes["Index"].flatMap { Int($0) } ?? rowNumber + 1
            column = 0
        case "Cell" where inSheet:
            if let index = attributes["Index"].flatMap({ Int($0) }) { column = max(index - 1, 0) }
            mergeAcross = attributes["MergeAcross"].flatMap { Int($0) } ?? 0
            value = ""
            type = ""
        case "Data" where inSheet:
            if dataDepth == 0 && commentDepth == 0 { type = attributes["Type"] ?? "String"; value = "" }
            dataDepth += 1
        case "Comment" where inSheet: commentDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if dataDepth > 0, commentDepth == 0 { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch local(name) {
        case "Data" where inSheet: dataDepth = max(dataDepth - 1, 0)
        case "Comment" where inSheet: commentDepth = max(commentDepth - 1, 0)
        case "Cell" where inSheet:
            var text = type == "Boolean" ? (value == "1" ? "VERDADEIRO" : "FALSO") : value
            text = LegacyExcelReader.clean(text)
            if !text.isEmpty {
                if column < SheetParser.maxColumns { cells[column] = text } else { cutColumns = true }
            }
            column += 1 + mergeAcross
            mergeAcross = 0
            value = ""
            type = ""
        case "Row" where inSheet:
            if let last = cells.keys.max() {
                rows.append(SheetParser.Row(number: rowNumber, cells: (0...last).map { cells[$0] ?? "" }))
                if rows.count > OfficeReader.maxRows {
                    // Enough to tell the sheet has more than is shown: keep it and stop reading.
                    sheets.append(LegacyExcelReader.Sheet(name: sheetName, rows: rows, cutColumns: cutColumns))
                    inSheet = false
                    stopped = true
                    parser.abortParsing()
                }
            }
        case "Worksheet":
            sheets.append(LegacyExcelReader.Sheet(name: sheetName, rows: rows, cutColumns: cutColumns))
            inSheet = false
        default: break
        }
    }
}
