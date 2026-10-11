import Foundation
import Testing
@testable import Orb

// MARK: - Fixture builders (no binary file lives in the repository)

private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
private func le64(_ value: Double) -> [UInt8] { (0..<8).map { UInt8((value.bitPattern >> (8 * UInt64($0))) & 0xFF) } }

/// One BIFF record: id, length, payload.
private func record(_ id: Int, _ payload: [UInt8] = []) -> [UInt8] { le16(id) + le16(payload.count) + payload }

/// Characters of a BIFF8 string as 8-bit (compressed) or UTF-16LE, with the flags byte first.
private func characters(_ text: String, wide: Bool) -> [UInt8] {
    wide ? [1] + text.utf16.flatMap { le16(Int($0)) } : [0] + text.unicodeScalars.map { UInt8($0.value) }
}

/// A BIFF8 string: length (1 or 2 bytes), flags, characters.
private func xlString(_ text: String, lengthBytes: Int = 2, wide: Bool = false) -> [UInt8] {
    let count = wide ? text.utf16.count : text.unicodeScalars.count
    return (lengthBytes == 1 ? [UInt8(count)] : le16(count)) + characters(text, wide: wide)
}

private func address(_ row: Int, _ column: Int) -> [UInt8] { le16(row) + le16(column) + le16(0x0F) }

private func labelSST(_ row: Int, _ column: Int, _ index: Int) -> [UInt8] { record(0x00FD, address(row, column) + le32(UInt32(index))) }
private func number(_ row: Int, _ column: Int, _ value: Double) -> [UInt8] { record(0x0203, address(row, column) + le64(value)) }
private func rkRecord(_ row: Int, _ column: Int, _ raw: UInt32) -> [UInt8] { record(0x027E, address(row, column) + le32(raw)) }
private func rkInt(_ value: Int32, times100: Bool = false) -> UInt32 { (UInt32(bitPattern: value) << 2) | 2 | (times100 ? 1 : 0) }
private func mulrk(_ row: Int, _ firstColumn: Int, _ raws: [UInt32]) -> [UInt8] {
    record(0x00BD, le16(row) + le16(firstColumn) + raws.flatMap { le16(0x0F) + le32($0) } + le16(firstColumn + raws.count - 1))
}
private func label(_ row: Int, _ column: Int, _ text: String) -> [UInt8] { record(0x0204, address(row, column) + xlString(text)) }
private func boolErr(_ row: Int, _ column: Int, _ value: Int, error: Bool) -> [UInt8] {
    record(0x0205, address(row, column) + [UInt8(value), error ? 1 : 0])
}
/// A formula cell whose cached result is `result` (8 bytes); the formula itself is empty.
private func formula(_ row: Int, _ column: Int, result: [UInt8]) -> [UInt8] {
    record(0x0006, address(row, column) + result + le16(0) + le32(0) + le16(0))
}
private func formulaNumber(_ row: Int, _ column: Int, _ value: Double) -> [UInt8] { formula(row, column, result: le64(value)) }
/// The cached result that is not a number: 0 text (a STRING record follows), 1 boolean, 2 error, 3 empty text.
private func formulaSpecial(_ row: Int, _ column: Int, type: UInt8, value: UInt8 = 0) -> [UInt8] {
    formula(row, column, result: [type, 0, value, 0, 0, 0, 0xFF, 0xFF])
}

private func bof(_ type: Int, version: Int = 0x0600) -> [UInt8] {
    record(0x0809, le16(version) + le16(type) + le16(0x0DBB) + le16(0x07CC) + le32(0) + le32(6))
}
private let eof = record(0x000A)

private func boundSheet(offset: Int, type: UInt8 = 0, name: String) -> [UInt8] {
    record(0x0085, le32(UInt32(offset)) + [0, type] + xlString(name, lengthBytes: 1, wide: name.unicodeScalars.contains { $0.value > 255 }))
}

/// The shared strings, cut across CONTINUE records on purpose:
/// 0 "Nome", 1 "Valor", 2 "Olá, 日本" (8-bit in the SST record, UTF-16 in the CONTINUE), 3 "日本語 ok!" (UTF-16, then 8-bit),
/// 4 "Rch" (rich text: runs and phonetic data, which cross the next CONTINUE), 5 "Fim".
private func sharedStrings() -> [UInt8] {
    var sst = le32(6) + le32(6)
    sst += xlString("Nome") + xlString("Valor")
    sst += le16(7) + [0] + "Olá, ".unicodeScalars.map { UInt8($0.value) }                         // 5 of 7 characters, 8-bit
    var continue1 = [UInt8(1)] + "日本".utf16.flatMap { le16(Int($0)) }                           // the rest, now UTF-16
    continue1 += le16(7) + [1] + "日本語".utf16.flatMap { le16(Int($0)) }                          // next string: 3 of 7, UTF-16
    var continue2 = [UInt8(0)] + " ok!".unicodeScalars.map { UInt8($0.value) }                    // the rest, now 8-bit
    continue2 += le16(3) + [0x0C] + le16(2) + le32(6) + "Rch".unicodeScalars.map { UInt8($0.value) }   // rich + phonetic header
    let continue3: [UInt8] = [UInt8](repeating: 0xAA, count: 8) + [UInt8](repeating: 0xBB, count: 6) + xlString("Fim")
    return record(0x00FC, sst) + record(0x003C, continue1) + record(0x003C, continue2) + record(0x003C, continue3)
}

private enum WorkbookFixture {
    /// Sheets "Vendas" (text, numbers, formulas), a chart sheet and "Resumo". `extraRows` more rows in "Resumo";
    /// `padding` zero bytes before its substream (the stream grows without a single new record).
    static func stream(extraRows: Int = 0, padding: Int = 0) -> [UInt8] {
        var vendas = bof(0x10) + record(0x0200, [UInt8](repeating: 0, count: 14))
        vendas += labelSST(0, 0, 0) + labelSST(0, 1, 1)
        vendas += labelSST(1, 0, 2) + number(1, 2, 1234.5)
        vendas += rkRecord(2, 0, rkInt(42)) + rkRecord(2, 1, rkInt(1234, times100: true)) + rkRecord(2, 3, 0x3FE0_0000)
        vendas += mulrk(3, 0, [rkInt(1), rkInt(2), rkInt(3), rkInt(-5)])
        vendas += formulaNumber(4, 0, 99) + formulaSpecial(4, 1, type: 0) + record(0x04BC, [1, 2, 3]) + record(0x0207, xlString("calculado ç"))
        vendas += formulaSpecial(4, 2, type: 1, value: 1) + formulaSpecial(4, 3, type: 2, value: 0x07) + formulaSpecial(4, 4, type: 3)
        vendas += boolErr(4, 5, 0, error: false) + boolErr(4, 6, 0x2A, error: true)
        vendas += record(0x0201, address(5, 0)) + label(6, 0, "rótulo")
        vendas += eof

        let chart = bof(0x20) + record(0x1001, [1, 2, 3]) + eof

        var resumo = bof(0x10) + labelSST(0, 0, 3) + labelSST(0, 1, 4) + labelSST(0, 2, 5)
        resumo += bof(0x20) + number(0, 9, 777) + eof      // an embedded chart: its cells are not the sheet's
        resumo += number(1, 0, 0)
        for row in 0..<extraRows { resumo += number(2 + row, 0, Double(2 + row)) }
        resumo += eof

        func globals(_ offsets: [Int]) -> [UInt8] {
            bof(0x05) + record(0x0042, le16(1200)) + record(0x00E1, [0xB0, 0x04])
                + boundSheet(offset: offsets[0], name: "Vendas") + boundSheet(offset: offsets[1], type: 2, name: "Gráfico")
                + boundSheet(offset: offsets[2], name: "Resumo") + sharedStrings() + eof
        }
        let start = globals([0, 0, 0]).count
        let offsets = [start, start + vendas.count, start + vendas.count + chart.count + padding]
        return globals(offsets) + vendas + chart + [UInt8](repeating: 0, count: padding) + resumo
    }

    static let expectedVendas = """
    ## Aba 1: Vendas (6 linhas com dados)
    1: Nome\tValor
    2: Olá, 日本\t\t1234.5
    3: 42\t12.34\t\t0.5
    4: 1\t2\t3\t-5
    5: 99\tcalculado ç\tVERDADEIRO\t#DIV/0!\t\tFALSO\t#N/A
    7: rótulo
    """
}

/// A Compound File Binary container holding `streams`: streams of 4096 bytes or more in regular sectors, the rest in the
/// mini stream; `fragmented` interleaves the sectors of the streams so no chain is contiguous.
private enum CompoundFixture {
    static let end: UInt32 = 0xFFFF_FFFE
    static let free: UInt32 = 0xFFFF_FFFF

    static func build(_ streams: [(name: String, data: [UInt8])], shift: Int = 9, fragmented: Bool = false) -> [UInt8] {
        let size = 1 << shift
        let perFat = size / 4
        let big = streams.indices.filter { streams[$0].data.count >= 4096 }
        let small = streams.indices.filter { streams[$0].data.count < 4096 }

        /// Slot numbers for each stream, contiguous or taken in turns.
        func layout(_ counts: [Int]) -> [[Int]] {
            guard fragmented else {
                var next = 0
                return counts.map { count in defer { next += count }; return Array(next..<(next + count)) }
            }
            var slots = counts.map { _ in [Int]() }
            var next = 0
            for round in 0..<(counts.max() ?? 0) {
                for (index, count) in counts.enumerated() where round < count { slots[index].append(next); next += 1 }
            }
            return slots
        }

        // Mini stream and its FAT.
        let miniSlots = layout(small.map { (streams[$0].data.count + 63) / 64 })
        let miniCount = miniSlots.reduce(0) { $0 + $1.count }
        var mini = [UInt8](repeating: 0, count: miniCount * 64)
        var miniFat = [UInt32](repeating: free, count: (miniCount + perFat - 1) / perFat * perFat)
        for (k, index) in small.enumerated() {
            for (j, slot) in miniSlots[k].enumerated() {
                let chunk = streams[index].data.dropFirst(j * 64).prefix(64)
                mini.replaceSubrange((slot * 64)..<(slot * 64 + chunk.count), with: chunk)
                miniFat[slot] = j + 1 < miniSlots[k].count ? UInt32(miniSlots[k][j + 1]) : end
            }
        }

        // Regular sectors: big streams, mini stream, mini FAT, directory; then FAT and DIFAT sectors.
        let bigSlots = layout(big.map { (streams[$0].data.count + size - 1) / size })
        let bigTotal = bigSlots.reduce(0) { $0 + $1.count }
        let miniStreamSectors = (mini.count + size - 1) / size
        let miniFatSectors = miniCount == 0 ? 0 : miniFat.count * 4 / size
        let directorySectors = ((1 + streams.count) * 128 + size - 1) / size
        let plain = bigTotal + miniStreamSectors + miniFatSectors + directorySectors
        var fatSectors = 1
        var difatSectors = 0
        while true {
            difatSectors = fatSectors > 109 ? (fatSectors - 109 + perFat - 2) / (perFat - 1) : 0
            if plain + fatSectors + difatSectors <= fatSectors * perFat { break }
            fatSectors += 1
        }
        let total = plain + fatSectors + difatSectors
        var fat = [UInt32](repeating: free, count: fatSectors * perFat)
        var sectors = [[UInt8]](repeating: [UInt8](repeating: 0, count: size), count: total)

        func chain(_ ids: [Int]) {
            for (position, id) in ids.enumerated() { fat[id] = position + 1 < ids.count ? UInt32(ids[position + 1]) : end }
        }
        var starts: [Int: UInt32] = [:]
        for (k, index) in big.enumerated() {
            let ids = bigSlots[k]
            chain(ids)
            starts[index] = ids.first.map { UInt32($0) } ?? end
            for (j, id) in ids.enumerated() { sectors[id].replaceSubrange(0..<streams[index].data.dropFirst(j * size).prefix(size).count,
                                                                          with: streams[index].data.dropFirst(j * size).prefix(size)) }
        }
        for (k, index) in small.enumerated() { starts[index] = miniSlots[k].first.map { UInt32($0) } ?? end }

        let miniStreamStart = bigTotal
        let miniFatStart = miniStreamStart + miniStreamSectors
        let directoryStart = miniFatStart + miniFatSectors
        chain(Array(miniStreamStart..<(miniStreamStart + miniStreamSectors)))
        chain(Array(miniFatStart..<(miniFatStart + miniFatSectors)))
        chain(Array(directoryStart..<(directoryStart + directorySectors)))
        for id in 0..<miniStreamSectors { sectors[miniStreamStart + id].replaceSubrange(0..<mini.dropFirst(id * size).prefix(size).count, with: mini.dropFirst(id * size).prefix(size)) }
        let miniFatBytes = miniFat.flatMap(le32)
        for id in 0..<miniFatSectors { sectors[miniFatStart + id] = Array(miniFatBytes[(id * size)..<((id + 1) * size)]) }

        // Directory.
        func entry(_ name: String, type: UInt8, left: UInt32 = free, right: UInt32 = free, child: UInt32 = free, start: UInt32, size: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 128)
            let units = Array(name.utf16.prefix(31))
            for (i, unit) in units.enumerated() { bytes.replaceSubrange((2 * i)..<(2 * i + 2), with: le16(Int(unit))) }
            bytes.replaceSubrange(64..<66, with: le16((units.count + 1) * 2))
            bytes[66] = type
            bytes[67] = 1
            bytes.replaceSubrange(68..<72, with: le32(left))
            bytes.replaceSubrange(72..<76, with: le32(right))
            bytes.replaceSubrange(76..<80, with: le32(child))
            bytes.replaceSubrange(116..<120, with: le32(start))
            bytes.replaceSubrange(120..<124, with: le32(UInt32(size)))
            return bytes
        }
        var directory = entry("Root Entry", type: 5, child: streams.isEmpty ? free : 1,
                              start: miniStreamSectors == 0 ? end : UInt32(miniStreamStart), size: mini.count)
        for (index, stream) in streams.enumerated() {
            directory += entry(stream.name, type: 2, right: index + 1 < streams.count ? UInt32(index + 2) : free,
                               start: starts[index] ?? end, size: stream.data.count)
        }
        directory += [UInt8](repeating: 0, count: directorySectors * size - directory.count)
        for id in 0..<directorySectors { sectors[directoryStart + id] = Array(directory[(id * size)..<((id + 1) * size)]) }

        // FAT and DIFAT.
        let fatStart = plain
        let difatStart = plain + fatSectors
        for id in 0..<fatSectors { fat[fatStart + id] = 0xFFFF_FFFD }
        for id in 0..<difatSectors { fat[difatStart + id] = 0xFFFF_FFFC }
        let fatBytes = fat.flatMap(le32)
        for id in 0..<fatSectors { sectors[fatStart + id] = Array(fatBytes[(id * size)..<((id + 1) * size)]) }
        let fatIDs = (0..<fatSectors).map { UInt32(fatStart + $0) }
        for id in 0..<difatSectors {
            var entries = [UInt32](repeating: free, count: perFat)
            for slot in 0..<(perFat - 1) where 109 + id * (perFat - 1) + slot < fatIDs.count { entries[slot] = fatIDs[109 + id * (perFat - 1) + slot] }
            entries[perFat - 1] = id + 1 < difatSectors ? UInt32(difatStart + id + 1) : end
            sectors[difatStart + id] = entries.flatMap(le32)
        }

        // Header.
        var header = [UInt8](repeating: 0, count: size)
        header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.replaceSubrange(0x18..<0x1A, with: le16(0x003E))
        header.replaceSubrange(0x1A..<0x1C, with: le16(shift == 9 ? 3 : 4))
        header.replaceSubrange(0x1C..<0x1E, with: le16(0xFFFE))
        header.replaceSubrange(0x1E..<0x20, with: le16(shift))
        header.replaceSubrange(0x20..<0x22, with: le16(6))
        header.replaceSubrange(0x28..<0x2C, with: le32(shift == 9 ? 0 : UInt32(directorySectors)))
        header.replaceSubrange(0x2C..<0x30, with: le32(UInt32(fatSectors)))
        header.replaceSubrange(0x30..<0x34, with: le32(UInt32(directoryStart)))
        header.replaceSubrange(0x38..<0x3C, with: le32(4096))
        header.replaceSubrange(0x3C..<0x40, with: le32(miniFatSectors == 0 ? end : UInt32(miniFatStart)))
        header.replaceSubrange(0x40..<0x44, with: le32(UInt32(miniFatSectors)))
        header.replaceSubrange(0x44..<0x48, with: le32(difatSectors == 0 ? end : UInt32(difatStart)))
        header.replaceSubrange(0x48..<0x4C, with: le32(UInt32(difatSectors)))
        for slot in 0..<109 { header.replaceSubrange((0x4C + 4 * slot)..<(0x50 + 4 * slot), with: le32(slot < fatIDs.count ? fatIDs[slot] : free)) }
        return header + sectors.flatMap { $0 }
    }

    /// A workbook in a container, with a neighbour stream like the ones Excel writes.
    static func workbook(_ stream: [UInt8], name: String = "Workbook", shift: Int = 9, fragmented: Bool = false) -> Data {
        Data(build([("\u{5}SummaryInformation", [UInt8](repeating: 7, count: 300)), (name, stream)]
                   + (fragmented ? [("Outro", [UInt8](repeating: 9, count: 5_000)), ("Pequeno", [UInt8](repeating: 3, count: 700))] : []),
                   shift: shift, fragmented: fragmented))
    }
}

// MARK: - Tests

final class LegacyExcelReaderTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func read(_ data: Data, name: String = "teste.xls") throws -> String { try LegacyExcelReader.text(data, name: name) }

    private func failure(_ data: Data, name: String = "teste.xls") -> String? {
        do { _ = try read(data, name: name); return nil } catch { return (error as? ToolError)?.message }
    }

    @Test func theExtensionDecidesWhatIsOfferedToTheReader() {
        #expect(LegacyExcelReader.isLegacyExcel(URL(fileURLWithPath: "/a/b.xls")))
        #expect(LegacyExcelReader.isLegacyExcel(URL(fileURLWithPath: "/a/B.XLS")))
        #expect(!LegacyExcelReader.isLegacyExcel(URL(fileURLWithPath: "/a/b.xlsx")))
    }

    // MARK: Binary workbook

    private static let expectedResumo = "## Aba 2: Resumo (2 linhas com dados)\n1: 日本語 ok!\tRch\tFim\n2: 0"

    @Test func aBinaryWorkbookInTheMiniStreamReadsTextNumbersFormulasAndSkipsTheChartSheet() throws {
        let stream = WorkbookFixture.stream()
        #expect(stream.count < 4096, "the small variant must live in the mini stream")
        let output = try read(CompoundFixture.workbook(stream))
        #expect(output == WorkbookFixture.expectedVendas + "\n\n" + Self.expectedResumo, Comment(rawValue: output))
    }

    @Test func aBinaryWorkbookInRegularSectorsReadsTheSame() throws {
        let stream = WorkbookFixture.stream(extraRows: 400)
        #expect(stream.count > 4096)
        let output = try read(CompoundFixture.workbook(stream))
        #expect(output.hasPrefix(WorkbookFixture.expectedVendas))
        #expect(output.contains("## Aba 2: Resumo (402 linhas com dados)"))
        #expect(output.contains("\n2: 0\n3: 2\n") && output.hasSuffix("\n402: 401"), Comment(rawValue: String(output.suffix(80))))
    }

    @Test func sectorsOfFourKilobytesAndFragmentedChainsReadTheSame() throws {
        let stream = WorkbookFixture.stream(extraRows: 400)
        let plain = try read(CompoundFixture.workbook(stream))
        for (shift, fragmented) in [(12, false), (12, true), (9, true)] {
            let output = try read(CompoundFixture.workbook(stream, shift: shift, fragmented: fragmented))
            #expect(output == plain, Comment(rawValue: "shift \(shift) fragmented \(fragmented)"))
        }
        // The mini stream too: small streams taking their mini sectors in turns.
        let small = try read(CompoundFixture.workbook(WorkbookFixture.stream(), fragmented: true))
        #expect(small == WorkbookFixture.expectedVendas + "\n\n" + Self.expectedResumo)
    }

    @Test func aFatThatSpillsIntoExtraDifatSectorsIsFollowed() throws {
        // More than 109 FAT sectors (about 7 MB of 512-byte sectors): the rest are listed in DIFAT sectors. The last
        // sheet lives past the padding, in sectors only reachable through those.
        let stream = WorkbookFixture.stream(extraRows: 3, padding: 7_500_000)
        let file = CompoundFixture.workbook(stream)
        #expect(Int(file[0x48]) >= 1, "the fixture must use a DIFAT sector")
        let output = try read(file)
        #expect(output.hasPrefix(WorkbookFixture.expectedVendas))
        #expect(output.contains("## Aba 2: Resumo (5 linhas com dados)") && output.hasSuffix("5: 4"), Comment(rawValue: String(output.suffix(60))))
    }

    @Test func anExcel5FileKeepsItsTextInTheCodePage() throws {
        // BIFF5: 8-bit strings in the file's code page (here 1252: 0xE9 is é), sheet names with a 1-byte length.
        let cell = record(0x0204, address(0, 0) + le16(4) + [0x63, 0x61, 0x66, 0xE9])      // "café"
            + record(0x0203, address(0, 1) + le64(2.25))
        let sheet = bof(0x10, version: 0x0500) + cell + eof
        func globals(_ offset: Int) -> [UInt8] {
            bof(0x05, version: 0x0500) + record(0x0042, le16(1252))
                + record(0x0085, le32(UInt32(offset)) + [0, 0, 4] + Array("Aba5".utf8)) + eof
        }
        let output = try read(CompoundFixture.workbook(globals(globals(0).count) + sheet, name: "Book"))
        #expect(output == "## Aba 1: Aba5 (1 linhas com dados)\n1: café\t2.25")
    }

    @Test func aSheetWithManyRowsAndColumnsIsCutLikeAnXlsx() throws {
        var sheet = bof(0x10)
        for row in 0..<(OfficeReader.maxRows + 2) { sheet += number(row, 0, Double(row)) }
        sheet += number(0, SheetParser.maxColumns + 5, 1) + eof
        let globalsLength = (bof(0x05) + boundSheet(offset: 0, name: "Grande") + eof).count
        let stream = bof(0x05) + boundSheet(offset: globalsLength, name: "Grande") + eof + sheet
        let output = try read(CompoundFixture.workbook(stream))
        #expect(output.hasPrefix("## Aba 1: Grande (mais de \(OfficeReader.maxRows) linhas com dados)\n1: 0\n2: 1\n"))
        #expect(output.contains("\(OfficeReader.maxRows): \(OfficeReader.maxRows - 1)\n[... a aba tem mais linhas"))
        #expect(!output.contains("\(OfficeReader.maxRows + 1): "))
        #expect(output.hasSuffix("[... colunas além da \(SheetParser.maxColumns)ª foram omitidas; leia o resto com run_command ...]"))
    }

    @Test func aWorkbookWithoutCellsIsEmpty() throws {
        let stream = bof(0x05) + eof
        #expect(try read(CompoundFixture.workbook(stream)) == "(planilha vazia)")
        let withSheet = bof(0x05) + boundSheet(offset: 0, name: "Vazia") + eof
        let sheet = bof(0x10) + record(0x0201, address(0, 0)) + eof
        let full = bof(0x05) + boundSheet(offset: withSheet.count, name: "Vazia") + eof + sheet
        #expect(try read(CompoundFixture.workbook(full)) == "## Aba 1: Vazia (0 linhas com dados)\n(vazia)")
    }

    // MARK: Errors

    @Test func aPasswordProtectedWorkbookSaysSo() {
        let encrypted = bof(0x05) + record(0x002F, [1, 0, 1, 0, 1, 0]) + eof
        #expect(failure(CompoundFixture.workbook(encrypted), name: "folha.xls") == "A planilha folha.xls está protegida por senha.")
        // An encrypted .xlsx is a container with an EncryptedPackage stream.
        let package = Data(CompoundFixture.build([("EncryptionInfo", [1, 2, 3]), ("EncryptedPackage", [4, 5, 6])]))
        #expect(failure(package, name: "cofre.xls") == "A planilha cofre.xls está protegida por senha.")
    }

    @Test func filesThatAreNotReadableWorkbooksExplainWhy() {
        #expect(failure(Data()) == "A planilha teste.xls está vazia (0 bytes).")
        let word = Data(CompoundFixture.build([("WordDocument", [1, 2, 3])]))
        #expect(failure(word)?.contains("não é uma planilha Excel") == true)
        let truncated = Data(CompoundFixture.workbook(WorkbookFixture.stream(extraRows: 400)).prefix(300))
        #expect(failure(truncated)?.contains("corrompido ou truncado") == true)
        #expect(failure(Data(CompoundFixture.workbook(WorkbookFixture.stream()).prefix(2_000)))?.isEmpty == false)
        #expect(failure(Data((0..<300).map { UInt8($0 % 251) }))?.contains("não parece uma planilha Excel legível") == true)
        #expect(failure(Data("a,b\n1,2\n".utf8))?.contains("não parece uma planilha Excel legível") == true)
        #expect(failure(Data("<html><body>nada</body></html>".utf8))?.contains("sem nenhuma tabela") == true)
        // A stream that is not BIFF at all (an old BIFF4 file starts with a different BOF).
        let old = Data(CompoundFixture.workbook(record(0x0409, [0, 4, 0x10, 0]) + eof))
        #expect(failure(old)?.contains("BIFF2-4") == true)
    }

    @Test func damagedContainersNeverCrash() {
        let good = CompoundFixture.workbook(WorkbookFixture.stream(extraRows: 400))
        // Flip bytes all over the file; whatever comes out, it must come out (text or an error), not trap or hang.
        for seed in 0..<40 {
            var bytes = [UInt8](good)
            for step in 0..<12 { bytes[(seed * 7919 + step * 104_729) % bytes.count] = UInt8(truncatingIfNeeded: seed * 31 + step * 17) }
            _ = try? read(Data(bytes))
        }
        for cut in stride(from: 0, to: good.count, by: 997) { _ = try? read(good.prefix(cut)) }
    }

    // MARK: HTML saved as .xls

    private func html(_ text: String, encoding: String.Encoding = .utf8) -> Data { text.data(using: encoding)! }

    @Test func htmlTablesBecomeSheetsWithColspanEntitiesAndLatin1() throws {
        let page = """
        <html><head><meta http-equiv=Content-Type content="text/html; charset=windows-1252"><style>td { color: red }</style>
        <script>var s = "<table><tr><td>NAO</td></tr></table>";</script></head><body>
        <!-- <table><tr><td>comentário</td></tr></table> -->
        <table border=1>
        <tr><th colspan=2>Relatório &amp; Totais</th><th>Ano</th></tr>
        <tr><td>Jo&atilde;o&nbsp;Silva</td><td>  A &lt; B
         &quot;ok&quot; &#39;x&#39; &#233; &#xE9; &#150; &desconhecido;</td><td>2024</td></tr>
        <tr><td></td><td></td></tr>
        <tr><td>só<br>duas linhas</td><td COLSPAN="3">x</td><td>y</td></tr>
        </table>
        <table><tr><td>Segunda</td></tr></table>
        <table><tr><td> </td></tr></table>
        </body></html>
        """
        let output = try read(html(page, encoding: .windowsCP1252), name: "web.xls")
        #expect(output == """
        ## Aba 1: Tabela 1 (3 linhas com dados)
        1: Relatório & Totais\t\tAno
        2: João Silva\tA < B "ok" 'x' é é – &desconhecido;\t2024
        4: só duas linhas\tx\t\t\ty

        ## Aba 2: Tabela 2 (1 linhas com dados)
        1: Segunda
        """, Comment(rawValue: output))
    }

    @Test func utf8HtmlWithAWrongCharsetAndNestedLayoutTablesIsRead() throws {
        let page = "\u{FEFF}<!DOCTYPE html><HTML><HEAD><META charset=us-ascii></HEAD><BODY><TABLE><TR><TD>"
            + "<TABLE><THEAD><TR><TH>Nome</TH><TH>Cidade</TH></TR></THEAD><TBODY><TR><TD>José</TD><TD>São João</TD></TR><TR><TD>Ana<TD>Itabira</TBODY></TABLE>"
            + "</TD></TR></TABLE></BODY></HTML>"
        let output = try read(html(page))
        #expect(output == "## Aba 1: Tabela 1 (3 linhas com dados)\n1: Nome\tCidade\n2: José\tSão João\n3: Ana\tItabira", Comment(rawValue: output))
    }

    @Test func utf16HtmlIsRead() throws {
        let data = Data([0xFF, 0xFE]) + "<table><tr><td>Olá</td><td>日本</td></tr></table>".data(using: .utf16LittleEndian)!
        #expect(try read(data) == "## Aba 1: Tabela 1 (1 linhas com dados)\n1: Olá\t日本")
    }

    @Test func aFrameSetPageSaysWhereTheDataIs() {
        let page = "<html><head><meta name=\"Excel Workbook Frameset\"><script>var t = \"<table><tr><td>x</td></tr></table>\";</script></head>"
            + "<frameset rows=\"*,39\"><frame src=\"dados_arquivos/sheet001.htm\"></frameset></html>"
        let message = failure(html(page), name: "moldura.xls")
        #expect(message?.contains("página-moldura") == true && message?.contains("sheet001.htm") == true, Comment(rawValue: message ?? "nil"))
    }

    // MARK: SpreadsheetML 2003

    @Test func spreadsheetMLHonoursIndexMergeAndSkipsComments() throws {
        let xml = """
        <?xml version="1.0"?>
        <?mso-application progid="Excel.Sheet"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
         <Worksheet ss:Name="Dados &amp; Mais"><Table>
          <Row><Cell><Data ss:Type="String">Nome</Data></Cell><Cell ss:Index="3"><Data ss:Type="Number">12.5</Data></Cell></Row>
          <Row ss:Index="4"><Cell><Data ss:Type="String">Linha<B>Rica</B> um</Data><Comment><ss:Data>ignorado</ss:Data></Comment></Cell>
           <Cell ss:MergeAcross="1"><Data ss:Type="Boolean">1</Data></Cell><Cell><Data ss:Type="String">depois
        da mescla</Data></Cell></Row>
         </Table></Worksheet>
         <Worksheet ss:Name="Vazia"><Table/></Worksheet>
        </Workbook>
        """
        let output = try read(html(xml))
        #expect(output == """
        ## Aba 1: Dados & Mais (2 linhas com dados)
        1: Nome\t\t12.5
        4: LinhaRica um\tVERDADEIRO\t\tdepois da mescla

        ## Aba 2: Vazia (0 linhas com dados)
        (vazia)
        """, Comment(rawValue: output))
    }

    // MARK: read_file

    @Test func readFileReadsAnXlsAndPagesIt() async throws {
        try workspace.write("dados.xls", CompoundFixture.workbook(WorkbookFixture.stream(extraRows: 400)))
        let output = try await workspace.run(ReadFileTool(), ["path": .string("dados.xls")])
        #expect(output.hasPrefix("(documento .xls convertido em texto)"))
        #expect(output.contains("## Aba 1: Vendas") && output.contains("5: 99\tcalculado ç"))
        let page = try await workspace.run(ReadFileTool(), ["path": .string("dados.xls"), "offset": .number(9), "limit": .number(2)])
        #expect(page.contains("## Aba 2: Resumo") && page.contains("1: 日本語"), Comment(rawValue: page))

        try workspace.write("web.XLS", html("<table><tr><td>a</td><td>b</td></tr></table>"))
        #expect(try await workspace.run(ReadFileTool(), ["path": .string("web.XLS")]).contains("1: a\tb"))
    }

    @Test func readFileExplainsAnXlsThatCannotBeRead() async throws {
        try workspace.write("quebrado.xls", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]))
        do {
            _ = try await workspace.run(ReadFileTool(), ["path": .string("quebrado.xls")])
            Issue.record("expected an error")
        } catch {
            #expect((error as? ToolError)?.message.contains("corrompido ou truncado") == true)
        }
        // The old PowerPoint format still has no reader.
        try workspace.write("velho.ppt", Data([0xD0, 0xCF, 0x11, 0xE0, 0, 1, 2]))
        do {
            _ = try await workspace.run(ReadFileTool(), ["path": .string("velho.ppt")])
            Issue.record("expected an error")
        } catch {
            #expect((error as? ToolError)?.message.contains("formato antigo do PowerPoint") == true)
        }
    }

    @Test func anXlsxSavedWithTheXlsExtensionIsReadAsAnXlsx() async throws {
        let folder = workspace.url("zip-\(UUID().uuidString)")
        let sheet = folder.appending(path: "xl/worksheets/sheet1.xml")
        try FileManager.default.createDirectory(at: sheet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>zip dentro</t></is></c></row></sheetData></worksheet>"
            .write(to: sheet, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", "-r", workspace.url("enganado.xls").path, "."]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        let output = try await workspace.run(ReadFileTool(), ["path": .string("enganado.xls")])
        #expect(output.contains("1: zip dentro"), Comment(rawValue: output))
        // From bytes alone there is no file to unzip: the message says what to do.
        let bytes = try workspace.read("enganado.xls")
        #expect(failure(bytes)?.contains("renomeie para .xlsx") == true)
    }
}
