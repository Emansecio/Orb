import Foundation
import os
import Testing
@testable import Orb

/// Excel and PowerPoint files read as text, built here as zips of XML so no binary fixture lives in the repository.
final class OfficeReaderTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    /// Zips the given parts (path → XML) into `name`.
    @discardableResult
    private func zip(_ name: String, _ parts: [String: String]) throws -> URL {
        let folder = workspace.url("build-\(UUID().uuidString)")
        for (path, xml) in parts {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: file, atomically: true, encoding: .utf8)
        }
        let output = workspace.url(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", "-r", output.path, "."]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: folder)
        return output
    }

    private let sharedStrings = """
    <?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">\
    <si><t>Nome</t></si><si><t>Valor</t></si><si><r><t>João </t></r><r><t>Silva</t><rPh><t>ignorado</t></rPh></r></si><si><t xml:space="preserve">Total</t></si></sst>
    """

    private func workbook(sheets: [(name: String, rel: String)]) -> String {
        "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
            + sheets.enumerated().map { "<sheet name=\"\($0.element.name.replacingOccurrences(of: "&", with: "&amp;"))\" sheetId=\"\($0.offset + 1)\" r:id=\"\($0.element.rel)\"/>" }.joined()
            + "</sheets></workbook>"
    }

    private let relationships = """
    <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="x" Target="worksheets/sheet2.xml"/><Relationship Id="rId2" Type="x" Target="/xl/worksheets/sheet1.xml"/>\
    <Relationship Id="rId3" Type="x" Target="sharedStrings.xml"/></Relationships>
    """

    private let sheet1 = """
    <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
    <row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>1234.5</v></c></row>\
    <row r="4"><c r="A4" t="s"><v>3</v></c><c r="B4"><f>SUM(B2:B3)</f><v>99</v></c><c r="D4" t="b"><v>1</v></c></row>\
    </sheetData></worksheet>
    """

    private let sheet2 = """
    <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" t="inlineStr"><is><t>só texto</t></is></c><c r="B1" t="str"><v>fórmula</v></c></row></sheetData></worksheet>
    """

    @Test func readExcelSheetsInWorkbookOrderWithSharedStringsAndGaps() async throws {
        try zip("dados.xlsx", [
            "xl/workbook.xml": workbook(sheets: [("Vendas", "rId2"), ("Resumo & Notas", "rId1")]),
            "xl/_rels/workbook.xml.rels": relationships,
            "xl/sharedStrings.xml": sharedStrings,
            "xl/worksheets/sheet1.xml": sheet1,
            "xl/worksheets/sheet2.xml": sheet2,
            "[Content_Types].xml": "<Types/>",
        ])
        let output = try await workspace.run(ReadFileTool(), ["path": .string("dados.xlsx")])
        #expect(output.contains("convertido em texto"))
        let lines = output.split(separator: "\n").map(String.init)
        let aba1 = try #require(lines.firstIndex { $0.contains("## Aba 1: Vendas") })
        // Row numbers are the sheet's own; columns stay in place with an empty cell where there is none.
        #expect(lines[aba1 + 1].hasSuffix("1: Nome\tValor"))
        #expect(lines[aba1 + 2].hasSuffix("2: João Silva\t\t1234.5"), Comment(rawValue: lines[aba1 + 2]))
        #expect(lines[aba1 + 3].hasSuffix("4: Total\t99\t\tVERDADEIRO"))
        #expect(!output.contains("ignorado"))
        let aba2 = try #require(lines.firstIndex { $0.contains("## Aba 2: Resumo & Notas") })
        #expect(lines[aba2 + 1].hasSuffix("1: só texto\tfórmula"))
    }

    @Test func readExcelWithoutAWorkbookIndexFallsBackToNumberedSheets() async throws {
        try zip("sem-indice.xlsx", ["xl/sharedStrings.xml": sharedStrings, "xl/worksheets/sheet1.xml": sheet1, "xl/worksheets/sheet10.xml": sheet2,
                                    "xl/worksheets/sheet2.xml": sheet2])
        let output = try await workspace.run(ReadFileTool(), ["path": .string("sem-indice.xlsx")])
        let headers = output.split(separator: "\n").filter { $0.contains("## Aba") }.map(String.init)
        #expect(headers.count == 3)
        #expect(headers.first?.contains("## Aba 1: Planilha1") == true)
    }

    @Test func readPowerPointSlidesWithNotes() async throws {
        func slide(_ paragraphs: [String]) -> String {
            "<?xml version=\"1.0\"?><p:sld xmlns:p=\"p\" xmlns:a=\"a\"><p:cSld><p:spTree><p:sp><p:txBody>"
                + paragraphs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined() + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        try zip("apresentacao.pptx", [
            "ppt/slides/slide1.xml": slide(["Título do deck", "Subtítulo"]),
            "ppt/slides/slide2.xml": "<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>Meta: </a:t></a:r><a:r><a:t>dobrar</a:t></a:r></a:p><a:p><a:r><a:t>Segundo ponto</a:t></a:r></a:p></p:sld>",
            "ppt/slides/slide10.xml": slide(["Fim"]),
            "ppt/notesSlides/notesSlide2.xml": slide(["Falar devagar", "2"]),
        ])
        let output = try await workspace.run(ReadFileTool(), ["path": .string("apresentacao.pptx")])
        let lines = output.split(separator: "\n").map(String.init)
        let first = try #require(lines.firstIndex { $0.hasSuffix("## Slide 1") })
        #expect(lines[first + 1].hasSuffix("Título do deck") && lines[first + 2].hasSuffix("Subtítulo"))
        let second = try #require(lines.firstIndex { $0.hasSuffix("## Slide 2") })
        #expect(lines[second + 1].hasSuffix("Meta: dobrar") && lines[second + 2].hasSuffix("Segundo ponto"))
        #expect(lines[second + 3].hasSuffix("[Notas do apresentador]") && lines[second + 4].hasSuffix("Falar devagar"))
        #expect(!lines.contains { $0.hasSuffix("\t2") }, "the note's slide number is not text")
        // Numeric order: slide10 comes last, not second.
        let third = try #require(lines.firstIndex { $0.hasSuffix("## Slide 3") })
        #expect(lines[third + 1].hasSuffix("Fim"))
    }

    @Test func aFileThatIsNotAZipSaysSo() async throws {
        try workspace.write("falso.xlsx", "isto não é um zip")
        do {
            _ = try await workspace.run(ReadFileTool(), ["path": .string("falso.xlsx")])
            Issue.record("expected an error")
        } catch {
            #expect((error as? ToolError)?.message.contains("corrompido ou não é um Excel válido") == true)
        }
    }

    @Test func readFilePagesAnExcelFileByLines() async throws {
        let rows = (1...3_000).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c><c r=\"B\($0)\" t=\"inlineStr\"><is><t>linha \($0) com algum texto para ocupar espaço</t></is></c></row>" }
        try zip("grande.xlsx", ["xl/worksheets/sheet1.xml": "<worksheet><sheetData>\(rows.joined())</sheetData></worksheet>"])
        let first = try await workspace.run(ReadFileTool(), ["path": .string("grande.xlsx")])
        #expect(first.contains("continue com offset="))
        let page = try await workspace.run(ReadFileTool(), ["path": .string("grande.xlsx"), "offset": .number(2_900), "limit": .number(3)])
        #expect(page.contains("2898: 2898") || page.contains(": 28"))
    }

    @Test func otherBinaryFormatsGetSpecificAdvice() async throws {
        for (name, needle) in [("a.pages", "iWork"), ("b.numbers", "iWork"), ("c.key", "iWork"), ("d.xls", "formato antigo"), ("e.ppt", "formato antigo"),
                               ("f.zip", "compactado")] {
            try workspace.write(name, Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02]))
            do {
                _ = try await workspace.run(ReadFileTool(), ["path": .string(name)])
                Issue.record("expected an error for \(name)")
            } catch {
                #expect((error as? ToolError)?.message.contains(needle) == true, Comment(rawValue: "\(name): \(error)"))
            }
        }
    }
}

final class DocumentTextCacheTests {
    private func key(_ path: String, modified: TimeInterval = 0, size: Int = 1) -> DocumentTextCache.Key {
        // A file at a path that exists, so the key can be built; fields are then set as the test needs.
        var key = DocumentTextCache.Key(URL(fileURLWithPath: "/"), size: size)!
        key.path = path
        key.modified = Date(timeIntervalSince1970: modified)
        return key
    }

    @Test func aDocumentIsConvertedOnceWhileItStaysTheSame() throws {
        let cache = DocumentTextCache()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func load() throws -> String { calls.withLock { $0 += 1 }; return "texto \(calls.withLock { $0 })" }
        #expect(try cache.text(for: key("/a.xlsx"), load: load) == "texto 1")
        #expect(try cache.text(for: key("/a.xlsx"), load: load) == "texto 1")
        #expect(calls.withLock { $0 } == 1)
        // Edited (date) or replaced (size): converted again.
        #expect(try cache.text(for: key("/a.xlsx", modified: 5), load: load) == "texto 2")
        #expect(try cache.text(for: key("/a.xlsx", modified: 5, size: 9), load: load) == "texto 3")
        // Without a key nothing is cached; a failing conversion caches nothing either.
        _ = try cache.text(for: nil, load: load)
        _ = try cache.text(for: nil, load: load)
        #expect(calls.withLock { $0 } == 5)
        #expect(throws: ToolError.self) { try cache.text(for: self.key("/b.xlsx")) { throw ToolError("quebrado") } }
        #expect(try cache.text(for: key("/b.xlsx")) { "b" } == "b")
    }

    @Test func theOldestDocumentsLeaveWhenThereAreTooManyOrTooMuchText() throws {
        let cache = DocumentTextCache()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func load() throws -> String { calls.withLock { $0 += 1 }; return "x" }
        for index in 0...DocumentTextCache.capacity { _ = try cache.text(for: key("/\(index).xlsx"), load: load) }
        #expect(calls.withLock { $0 } == DocumentTextCache.capacity + 1)
        _ = try cache.text(for: key("/1.xlsx"), load: load)   // still there
        #expect(calls.withLock { $0 } == DocumentTextCache.capacity + 1)
        _ = try cache.text(for: key("/0.xlsx"), load: load)   // the first one left
        #expect(calls.withLock { $0 } == DocumentTextCache.capacity + 2)

        // Text beyond the budget is not kept.
        let huge = String(repeating: "a", count: DocumentTextCache.characterBudget + 1)
        let before = calls.withLock { $0 }
        _ = try cache.text(for: key("/huge.xlsx")) { calls.withLock { $0 += 1 }; return huge }
        _ = try cache.text(for: key("/huge.xlsx")) { calls.withLock { $0 += 1 }; return huge }
        #expect(calls.withLock { $0 } == before + 2)
    }

    private func rows(_ cellsXML: String) -> [SheetParser.Row] {
        let xml = "<worksheet><sheetData><row r=\"1\">\(cellsXML)</row></sheetData></worksheet>"
        return SheetParser.parse(Data(xml.utf8), strings: [], maxRows: 10).rows
    }

    private func cell(_ reference: String, _ text: String = "x") -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }

    @Test func aFarOrAbsurdColumnReferenceNeitherCrashesNorBuildsAHugeRow() {
        for reference in ["ZZZZZZZZZZZZZZZ1", "AAAAAAAAAAAAAA1", "ZZZZZZZ1", "XFE1", "XFD1"] {
            let width = rows(cell("A1", "a") + cell(reference)).first?.cells.count ?? 0
            #expect(width >= 1 && width <= SheetParser.maxColumns, Comment(rawValue: "\(reference): \(width)"))
        }
    }

    @Test func aCellBeyondTheColumnLimitIsReportedAsCut() {
        func parsed(_ cells: String) -> SheetParser {
            let xml = "<worksheet><sheetData><row r=\"1\">\(cells)</row></sheetData></worksheet>"
            return SheetParser.parse(Data(xml.utf8), strings: [], maxRows: 10)
        }
        #expect(parsed(cell("A1", "a") + cell("XFD1")).cutColumns)
        #expect(parsed(cell("A1", "a") + cell("ZZZZZZZ1")).cutColumns == false)   // not a real reference: placed next to the last cell
        #expect(parsed(cell("A1", "a") + cell("D1")).cutColumns == false)
    }

    @Test func smallGapsBetweenColumnsStayFilled() {
        #expect(rows(cell("B1", "b") + cell("D1", "d")).first?.cells == ["", "b", "", "d"])
    }

    /// The tool pages over one conversion, and a document that changed is read again.
    @Test func readFilePagesAndNoticesWhenTheFileChanges() async throws {
        let workspace = try ToolWorkspace()
        try workspace.write("nota.rtf", #"{\rtf1\ansi Primeira versao}"#)
        let first = try await workspace.run(ReadFileTool(), ["path": .string("nota.rtf")])
        #expect(first.contains("Primeira versao"))
        let paged = try await workspace.run(ReadFileTool(), ["path": .string("nota.rtf"), "offset": .number(1)])
        #expect(paged.contains("Primeira versao"))
        try workspace.write("nota.rtf", #"{\rtf1\ansi Segunda versao, bem maior}"#)
        let changed = try await workspace.run(ReadFileTool(), ["path": .string("nota.rtf")])
        #expect(changed.contains("Segunda versao") && !changed.contains("Primeira"))
    }
}
