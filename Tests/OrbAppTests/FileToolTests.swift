import AppKit
import Foundation
import Testing
@testable import Orb

/// read_file, write_file, edit_file, list_directory and search_files.
final class FileToolTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await workspace.run(tool, arguments)
    }

    // MARK: read_file: encodings and lines

    @Test func readSurvivesHugeNumbers() async throws {
        try workspace.write("short.txt", "a\nb\n")
        for value in [JSONValue.number(1e19), .number(Double(Int.max)), .string("1e19"), .string("99999999999999999999")] {
            let past = try await run(ReadFileTool(), ["path": .string("short.txt"), "offset": value])
            #expect(past.contains("além do fim"))
            let all = try await run(ReadFileTool(), ["path": .string("short.txt"), "limit": value])
            #expect(all.contains("2\tb"))
        }
        #expect(JSONValue.object(["n": .number(-1e30)]).integer("n", default: 5, in: 0...10) == 0)
        #expect(JSONValue.object(["n": .string("1e400")]).integer("n", default: 5, in: 0...Int.max) == 5)
    }

    @Test func readDecodesWindows1252AndLatin1() async throws {
        try workspace.write("latin.txt", try #require("Olá, coração – “ok”\n".data(using: .windowsCP1252)))
        let text = try await run(ReadFileTool(), ["path": .string("latin.txt")])
        #expect(text.contains("Olá, coração – “ok”"))
        #expect(text.contains("Windows-1252"))

        // 0x81 is undefined in Windows-1252; the file must still read instead of being refused.
        try workspace.write("odd.txt", Data([0x61, 0x81, 0xE9, 0x0A]))
        #expect(try await run(ReadFileTool(), ["path": .string("odd.txt")]).contains("é"))
    }

    @Test func readDecodesUTF16AndKeepsUTF8WithBOMQuiet() async throws {
        let sample = "linha um\nlinha dois: ação\n"
        try workspace.write("le.txt", Data([0xFF, 0xFE]) + (try #require(sample.data(using: .utf16LittleEndian))))
        try workspace.write("be.txt", Data([0xFE, 0xFF]) + (try #require(sample.data(using: .utf16BigEndian))))
        try workspace.write("nobom.txt", try #require(sample.data(using: .utf16LittleEndian)))
        for name in ["le.txt", "be.txt", "nobom.txt"] {
            let text = try await run(ReadFileTool(), ["path": .string(name)])
            #expect(text.contains("     2\tlinha dois: ação"), "\(name)")
            #expect(text.contains("UTF-16"), "\(name)")
        }

        try workspace.write("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("ola\n".utf8))
        #expect(try await run(ReadFileTool(), ["path": .string("bom.txt")]).hasSuffix("1\tola"))
    }

    /// A log cut in the middle of a character: one stray byte must not turn every accent of the file into two.
    @Test func utf8WithAStrayByteStaysUTF8() async throws {
        let bytes = Data("coração e Ásia\n".utf8) + Data([0xC3])
        let file = try #require(TextFile.decode(bytes))
        #expect(file.encoding == .utf8)
        #expect(file.invalidUTF8Bytes == 1)
        #expect(file.text.contains("coração") && file.text.contains("Ásia"))
        // Text in Windows-1252 has no valid multi-byte sequences, so it is still told apart.
        let latinBytes = try #require("ação\n".data(using: .windowsCP1252))
        let latin = try #require(TextFile.decode(latinBytes))
        #expect(latin.encoding == .windowsCP1252 && latin.invalidUTF8Bytes == 0)

        try workspace.write("cortado.log", bytes)
        let read = try await run(ReadFileTool(), ["path": .string("cortado.log")])
        #expect(read.contains("coração") && read.contains("1 bytes inválidos") && !read.contains("Windows-1252"))
    }

    /// The stray byte is not near the edit: the rest of the file must come back byte for byte, the stray byte included.
    @Test func editChangesOnlyTheStretchOfAUTF8FileWithInvalidBytes() async throws {
        let before = Data("// ação, função, coração\nlet x = 1\n// fim ".utf8) + Data([0xC3, 0x0A]) + Data("Ásia e ação\n".utf8)
        try workspace.write("sujo.txt", before)
        _ = try await run(EditFileTool(), ["path": .string("sujo.txt"), "old_text": .string("let x = 1"), "new_text": .string("let x = 2 // atenção")])
        let after = Data("// ação, função, coração\nlet x = 2 // atenção\n// fim ".utf8) + Data([0xC3, 0x0A]) + Data("Ásia e ação\n".utf8)
        #expect(try workspace.read("sujo.txt") == after)
        // Every occurrence, on both sides of the stray byte.
        _ = try await run(EditFileTool(), ["path": .string("sujo.txt"), "old_text": .string("ação"), "new_text": .string("acao"), "replace_all": .bool(true)])
        let all = Data("// acao, função, coracao\nlet x = 2 // atenção\n// fim ".utf8) + Data([0xC3, 0x0A]) + Data("Ásia e acao\n".utf8)
        #expect(try workspace.read("sujo.txt") == all)
    }

    @Test func editRefusesAStretchThatIncludesAnInvalidByteAndLeavesTheFileUntouched() async throws {
        let bytes = Data("coração\nfim ".utf8) + Data([0xC3, 0x0A]) + Data("Ásia e ação\n".utf8)
        try workspace.write("sujo.txt", bytes)
        let message = await workspace.failure(EditFileTool(), ["path": .string("sujo.txt"), "old_text": .string("fim \u{FFFD}"), "new_text": .string("atenção")])
        #expect(message.contains("bytes inválidos"))
        #expect(try workspace.read("sujo.txt") == bytes)
        // Text that borrows the private-use characters standing in for the bytes cannot smuggle bytes in.
        let smuggled = await workspace.failure(EditFileTool(), ["path": .string("sujo.txt"), "old_text": .string("fim"), "new_text": .string("\u{F7C3}")])
        #expect(smuggled.contains("bytes inválidos"))
        #expect(try workspace.read("sujo.txt") == bytes)
    }

    /// A pipe has no size and a read waits for a writer that may never come; a device like /dev/zero never ends.
    @Test func filesThatAreNotOrdinaryAreRefusedBeforeBeingOpened() async throws {
        let pipe = workspace.url("log.fifo")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        try workspace.link("alias.fifo", to: pipe.path)
        for tool in [ReadFileTool(), EditFileTool()] as [any AgentTool] {
            for name in ["log.fifo", "alias.fifo"] {
                let message = await workspace.outcome(of: tool, ["path": .string(name), "old_text": .string("a"), "new_text": .string("b")])
                #expect(message?.contains("não é um arquivo comum") == true, Comment(rawValue: "\(tool.spec.name) \(name): \(message ?? "no answer")"))
            }
        }
        let device = await workspace.outcome(of: ReadFileTool(), ["path": .string("/dev/zero")])
        #expect(device?.contains("não é um arquivo comum") == true, Comment(rawValue: device ?? "no answer"))
        // Ordinary files, and links to them, still read.
        try workspace.write("normal.txt", "oi\n")
        try workspace.link("normal.link", to: workspace.url("normal.txt").path)
        for name in ["normal.txt", "normal.link"] {
            #expect(try await run(ReadFileTool(), ["path": .string(name)]).contains("oi"))
        }
    }

    @Test func decodingPicksTheRightEncoding() throws {
        #expect(TextFile.decode(Data("café".utf8))?.encoding == .utf8)
        #expect(TextFile.decode(try #require("café".data(using: .isoLatin1)))?.encoding == .windowsCP1252)
        #expect(TextFile.decode(Data([0x50, 0x4B, 0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(TextFile.decode(Data("a\r\nb\r\nc\n".utf8))?.lineEnding == .crlf)
        #expect(TextFile.decode(Data("a\nb\r\nc\n".utf8))?.lineEnding == .lf)
    }

    @Test func readSplitsLinesOnNewlineOnly() async throws {
        // U+2028, U+0085 and a form feed are not line breaks in source files; \r\n is one break.
        try workspace.write("odd.txt", "a\u{2028}b\nc\u{85}d\u{0C}e\r\nlast\r\n")
        let text = try await run(ReadFileTool(), ["path": .string("odd.txt")])
        #expect(text.contains("     1\ta\u{2028}b\n     2\tc\u{85}d\u{0C}e\n     3\tlast"))
        #expect(!text.contains("\r"))
        #expect(text.contains("linhas CRLF"))
    }

    @Test func readClipsLongLinesAndCapsOneCall() async throws {
        try workspace.write("long.txt", String(repeating: "x", count: 5_000) + "\nshort\n")
        let clipped = try await run(ReadFileTool(), ["path": .string("long.txt")])
        #expect(clipped.contains("caracteres nesta linha"))
        #expect(clipped.count < 2_300)
        #expect(clipped.contains("     2\tshort"))

        let line = String(repeating: "y", count: 1_000)
        try workspace.write("big.txt", (1...300).map { _ in line }.joined(separator: "\n") + "\n")
        let page = try await run(ReadFileTool(), ["path": .string("big.txt")])
        // A page stays under the cap that would cut its middle (see ToolOutputBudget).
        #expect(page.count < ToolOutputCap.limit)
        #expect(page.count < ToolOutputBudget.pageCharacters + 200)
        let next = try #require(page.range(of: #"offset=(\d+)"#, options: .regularExpression)).lowerBound
        let offset = Int(page[next...].dropFirst(7).prefix { $0.isNumber }) ?? 0
        #expect(offset > 1 && offset < 301)
        let rest = try await run(ReadFileTool(), ["path": .string("big.txt"), "offset": .number(Double(offset))])
        #expect(rest.hasPrefix(String(repeating: " ", count: 6 - String(offset).count) + "\(offset)\t"))
        #expect(page.hasSuffix("[linhas 1–\(offset - 1) de 300; continue com offset=\(offset)]"))
    }

    @Test func readReportsOffsetsPastTheEnd() async throws {
        try workspace.write("short.txt", "one\ntwo\n")
        #expect(try await run(ReadFileTool(), ["path": .string("short.txt"), "offset": .number(9)]).contains("só 2 linhas"))
        try workspace.write("empty.txt", "")
        #expect(try await run(ReadFileTool(), ["path": .string("empty.txt")]) == "(arquivo vazio)")
    }

    @Test func readAcceptsStringArguments() async throws {
        try workspace.write("n.txt", "1\n2\n3\n4\n")
        let page = try await run(ReadFileTool(), ["path": .string("n.txt"), "offset": .string("2"), "limit": .string("2")])
        #expect(page.hasPrefix("     2\t2\n     3\t3\n"))
        #expect(page.contains("offset=4"))
    }

    @Test func readFollowsSymlinks() async throws {
        try workspace.write("real.txt", "hello\n")
        try workspace.link("alias.txt", to: "real.txt")
        #expect(try await run(ReadFileTool(), ["path": .string("alias.txt")]) == "     1\thello")
    }

    // MARK: read_file: PDF, documents, images

    @Test func readPDFTextWithPageRanges() async throws {
        try workspace.write("doc.pdf", try Fixtures.pdf(pages: ["Primeira pagina", "Segunda pagina", "Terceira pagina"]))
        let all = try await run(ReadFileTool(), ["path": .string("doc.pdf")])
        #expect(all.contains("PDF com 3 páginas"))
        #expect(all.contains("--- Página 1 ---\nPrimeira pagina"))
        #expect(all.contains("Terceira pagina"))

        let middle = try await run(ReadFileTool(), ["path": .string("doc.pdf"), "pages": .string("2")])
        #expect(middle.contains("Segunda pagina"))
        #expect(!middle.contains("Primeira") && !middle.contains("Terceira"))

        let tail = try await run(ReadFileTool(), ["path": .string("doc.pdf"), "pages": .string("2-")])
        #expect(tail.contains("Segunda") && tail.contains("Terceira") && !tail.contains("Primeira"))

        #expect(await workspace.failure(ReadFileTool(), ["path": .string("doc.pdf"), "pages": .string("9")]).contains("Intervalo de páginas inválido"))
        #expect(await workspace.failure(ReadFileTool(), ["path": .string("doc.pdf"), "pages": .string("a-b")]).contains("inválido"))
    }

    @Test func pageRangesParse() throws {
        #expect(try DocumentReader.pageRange("3", pageCount: 5) == 3...3)
        #expect(try DocumentReader.pageRange("2-4", pageCount: 5) == 2...4)
        #expect(try DocumentReader.pageRange("4-", pageCount: 5) == 4...5)
        #expect(try DocumentReader.pageRange("-2", pageCount: 5) == 1...2)
        #expect(try DocumentReader.pageRange("3-99", pageCount: 5) == 3...5)
        for bad in ["0", "6", "5-2", "-", "x"] {
            #expect(throws: ToolError.self) { try DocumentReader.pageRange(bad, pageCount: 5) }
        }
    }

    @Test func pdfWithoutTextSaysSo() async throws {
        try workspace.write("blank.pdf", try Fixtures.pdf(pages: [""]))
        #expect(try await run(ReadFileTool(), ["path": .string("blank.pdf")]).contains("Nenhum texto extraível"))
        try workspace.write("broken.pdf", "not a pdf")
        #expect(await workspace.failure(ReadFileTool(), ["path": .string("broken.pdf")]).contains("PDF"))
    }

    @Test func readWordProcessorDocuments() async throws {
        let attributed = NSAttributedString(string: "Relatório mensal\nTotal: 42\n")
        for (name, type) in [("nota.rtf", NSAttributedString.DocumentType.rtf), ("nota.docx", .officeOpenXML)] {
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type])
            try workspace.write(name, data)
            let text = try await run(ReadFileTool(), ["path": .string(name)])
            #expect(text.contains("Relatório mensal"), "\(name)")
            #expect(text.contains("Total: 42"), "\(name)")
            #expect(text.contains("convertido em texto"), "\(name)")
        }
    }

    @Test func readAnRTFDPackageAsADocumentNotAFolder() async throws {
        let attributed = NSAttributedString(string: "Relatório mensal\nTotal: 42\n")
        let package = try #require(try attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length),
                                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
        try package.write(to: workspace.url("nota.rtfd"), options: .atomic, originalContentsURL: nil)
        #expect(workspace.url("nota.rtfd").isExistingDirectory)
        let text = try await run(ReadFileTool(), ["path": .string("nota.rtfd")])
        #expect(text.contains("Relatório mensal") && text.contains("convertido em texto"))
        // A plain folder is still a folder.
        try FileManager.default.createDirectory(at: workspace.url("pasta"), withIntermediateDirectories: true)
        #expect(await workspace.failure(ReadFileTool(), ["path": .string("pasta")]).contains("é uma pasta"))
    }

    @Test func readImageStopsWaitingWhenTheTurnIsCancelled() async throws {
        try workspace.write("sign.png", try Fixtures.png(text: "HELLO WORLD"))
        let context = workspace.context
        let task = Task { () -> String in
            // Parar is pressed before the reading ends: the call must come back with the cancellation, not wait for Vision.
            while !Task.isCancelled { await Task.yield() }
            return try await ReadFileTool().run(.object(["path": .string("sign.png")]), context: context)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func htmlIsReadAsSource() async throws {
        try workspace.write("page.html", "<h1>Oi</h1>\n")
        #expect(try await run(ReadFileTool(), ["path": .string("page.html")]).hasSuffix("1\t<h1>Oi</h1>"))
    }

    @Test func readImageGivesSizeAndOCRText() async throws {
        try workspace.write("sign.png", try Fixtures.png(text: "HELLO WORLD"))
        let text = try await run(ReadFileTool(), ["path": .string("sign.png")])
        #expect(text.contains("900×240 px"))
        #expect(text.contains("OCR"))
        #expect(text.localizedCaseInsensitiveContains("hello"))

        try workspace.write("blank.png", try Fixtures.png(text: ""))
        #expect(try await run(ReadFileTool(), ["path": .string("blank.png")]).contains("Nenhum texto reconhecido"))
        try workspace.write("fake.png", "not an image")
        #expect(await workspace.failure(ReadFileTool(), ["path": .string("fake.png")]).contains("imagem"))
    }

    @Test func otherBinariesAreRefusedClearly() async throws {
        try workspace.write("blob.bin", Data([0x50, 0x4B, 0x00, 0x01]))
        let message = await workspace.failure(ReadFileTool(), ["path": .string("blob.bin")])
        #expect(message.contains("binário"))
        #expect(message.contains("run_command"))
    }

    // MARK: write_file

    @Test func writeGoesThroughSymlinksToTheTarget() async throws {
        try workspace.write("dotfiles/zshrc", "old\n")
        try workspace.link(".zshrc", to: "dotfiles/zshrc")

        let result = try await run(WriteFileTool(), ["path": .string(".zshrc"), "content": .string("new\n")])
        #expect(result.contains("link simbólico"))
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.url(".zshrc").path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try workspace.readText("dotfiles/zshrc") == "new\n")

        // A dangling link creates its target, folders included.
        try workspace.link("later.txt", to: "made/by/link.txt")
        _ = try await run(WriteFileTool(), ["path": .string("later.txt"), "content": .string("hi")])
        #expect(try workspace.readText("made/by/link.txt") == "hi")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: workspace.url("later.txt").path) == "made/by/link.txt")

        // A symlinked folder works too.
        try workspace.link("shortcut", to: "dotfiles")
        _ = try await run(WriteFileTool(), ["path": .string("shortcut/extra.txt"), "content": .string("x")])
        #expect(try workspace.readText("dotfiles/extra.txt") == "x")
    }

    @Test func writeKeepsPermissions() async throws {
        let script = try workspace.write("run.sh", "#!/bin/sh\necho 1\n")
        try script.makeExecutable()
        _ = try await run(WriteFileTool(), ["path": .string("run.sh"), "content": .string("#!/bin/sh\necho 2\n")])
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test func writeSummaryTellsNewFromReplacement() throws {
        let tool = WriteFileTool()
        let existing = try workspace.write("old.txt", String(repeating: "a", count: 2_048))
        let replaced = tool.summary(.object(["path": .string(existing.path), "content": .string("new")]))
        #expect(replaced.detail.contains("Substitui ("))
        #expect(replaced.detail.contains("KB"))
        let appended = tool.summary(.object(["path": .string(existing.path), "content": .string("x"), "append": .string("true")]))
        #expect(appended.detail.contains("Acrescenta ao final"))
        let fresh = tool.summary(.object(["path": .string(workspace.url("none.txt").path), "content": .string("x")]))
        #expect(fresh.detail.contains("Novo arquivo"))
        // Through a link the target is what counts.
        try workspace.link("link.txt", to: "old.txt")
        #expect(tool.summary(.object(["path": .string(workspace.url("link.txt").path), "content": .string("x")])).detail.contains("Substitui"))
        #expect(replaced.detail.hasSuffix("\n\nnew"))
    }

    @Test func writeSummaryResolvesRelativePathsWithTheContext() throws {
        let tool = WriteFileTool()
        try workspace.write("here.txt", "abc")
        #expect(tool.summary(.object(["path": .string("here.txt"), "content": .string("x")]), context: workspace.context).detail.contains("Substitui ("))
        #expect(tool.summary(.object(["path": .string("nope.txt"), "content": .string("x")]), context: workspace.context).detail.contains("Novo arquivo"))
        // Without a context a relative path says nothing about the file.
        let blind = tool.summary(.object(["path": .string("here.txt"), "content": .string("x")]))
        #expect(!blind.detail.contains("Substitui") && !blind.detail.contains("Novo arquivo"))
    }

    @Test func appendAcceptsTheStringTrue() async throws {
        try workspace.write("log.txt", "a\n")
        _ = try await run(WriteFileTool(), ["path": .string("log.txt"), "content": .string("b\n"), "append": .string("true")])
        #expect(try workspace.readText("log.txt") == "a\nb\n")
        _ = try await run(WriteFileTool(), ["path": .string("log.txt"), "content": .string("c\n"), "append": .string("false")])
        #expect(try workspace.readText("log.txt") == "c\n")
    }

    @Test func appendMatchesTheFilesEncodingAndLineEndings() async throws {
        let utf16 = Data([0xFF, 0xFE]) + (try #require("um\n".data(using: .utf16LittleEndian)))
        try workspace.write("u16.txt", utf16)
        _ = try await run(WriteFileTool(), ["path": .string("u16.txt"), "content": .string("dois: ação\n"), "append": .bool(true)])
        let bytes = try workspace.read("u16.txt")
        #expect(bytes.prefix(2) == Data([0xFF, 0xFE]))
        #expect(String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) == "um\ndois: ação\n")

        try workspace.write("win.txt", "a\r\nb\r\n")
        _ = try await run(WriteFileTool(), ["path": .string("win.txt"), "content": .string("c\nd\n"), "append": .bool(true)])
        #expect(try workspace.readText("win.txt") == "a\r\nb\r\nc\r\nd\r\n")

        try workspace.write("latin.txt", try #require("não\n".data(using: .windowsCP1252)))
        _ = try await run(WriteFileTool(), ["path": .string("latin.txt"), "content": .string("é\n"), "append": .bool(true)])
        #expect(String(data: try workspace.read("latin.txt"), encoding: .windowsCP1252) == "não\né\n")
    }

    @Test func writeRefusesFolders() async throws {
        try FileManager.default.createDirectory(at: workspace.url("dir"), withIntermediateDirectories: true)
        #expect(await workspace.failure(WriteFileTool(), ["path": .string("dir"), "content": .string("x")]).contains("pasta"))
    }

    // MARK: edit_file

    @Test func editReplacesExactlyOnce() async throws {
        try workspace.write("code.swift", "let a = 1\nlet b = 2\n")
        let result = try await run(EditFileTool(), ["path": .string("code.swift"), "old_text": .string("let b = 2"), "new_text": .string("let b = 3")])
        #expect(result.contains("1 trecho substituído (linha 2)"))
        #expect(try workspace.readText("code.swift") == "let a = 1\nlet b = 3\n")

        // Deleting with an empty replacement.
        _ = try await run(EditFileTool(), ["path": .string("code.swift"), "old_text": .string("let a = 1\n"), "new_text": .string("")])
        #expect(try workspace.readText("code.swift") == "let b = 3\n")
    }

    @Test func editWithNoMatchExplainsWhatToDo() async throws {
        try workspace.write("a.txt", "alpha\nbeta\n")
        let missing = await workspace.failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("gamma"), "new_text": .string("x")])
        #expect(missing.contains("não foi encontrado"))
        #expect(missing.contains("read_file"))
        #expect(!missing.contains("números de linha"))

        let numbered = await workspace.failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("     1\talpha"), "new_text": .string("x")])
        #expect(numbered.contains("números de linha"))
        #expect(try workspace.readText("a.txt") == "alpha\nbeta\n")
    }

    @Test func editWithSeveralMatchesNeedsContextOrReplaceAll() async throws {
        try workspace.write("dup.txt", "x = 1\ny = 2\nx = 1\n")
        let ambiguous = await workspace.failure(EditFileTool(), ["path": .string("dup.txt"), "old_text": .string("x = 1"), "new_text": .string("x = 9")])
        #expect(ambiguous.contains("2 vezes"))
        #expect(ambiguous.contains("linhas 1, 3"))
        #expect(ambiguous.contains("mais linhas"))
        #expect(ambiguous.contains("replace_all"))
        #expect(try workspace.readText("dup.txt") == "x = 1\ny = 2\nx = 1\n")

        let result = try await run(EditFileTool(), ["path": .string("dup.txt"), "old_text": .string("x = 1"), "new_text": .string("x = 9"), "replace_all": .string("true")])
        #expect(result.contains("2 trechos substituídos"))
        #expect(try workspace.readText("dup.txt") == "x = 9\ny = 2\nx = 9\n")
    }

    @Test func editPreservesCRLF() async throws {
        try workspace.write("win.txt", "one\r\ntwo\r\nthree\r\n")
        // Multi-line text given with plain newlines still matches, and the replacement gets CRLF too.
        _ = try await run(EditFileTool(), ["path": .string("win.txt"), "old_text": .string("one\ntwo"), "new_text": .string("1\n1.5\n2")])
        #expect(try workspace.read("win.txt") == Data("1\r\n1.5\r\n2\r\nthree\r\n".utf8))

        // A single-line match with a multi-line replacement is converted as well.
        _ = try await run(EditFileTool(), ["path": .string("win.txt"), "old_text": .string("three"), "new_text": .string("a\nb")])
        #expect(try workspace.read("win.txt") == Data("1\r\n1.5\r\n2\r\na\r\nb\r\n".utf8))

        // LF files stay LF even when the model sends CRLF.
        try workspace.write("unix.txt", "p\nq\n")
        _ = try await run(EditFileTool(), ["path": .string("unix.txt"), "old_text": .string("p\r\nq"), "new_text": .string("r\r\ns")])
        #expect(try workspace.readText("unix.txt") == "r\ns\n")
    }

    @Test func editPreservesEncodings() async throws {
        let utf16 = Data([0xFF, 0xFE]) + (try #require("olá mundo\n".data(using: .utf16LittleEndian)))
        try workspace.write("u16.txt", utf16)
        _ = try await run(EditFileTool(), ["path": .string("u16.txt"), "old_text": .string("mundo"), "new_text": .string("você")])
        let bytes = try workspace.read("u16.txt")
        #expect(bytes.prefix(2) == Data([0xFF, 0xFE]))
        #expect(String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) == "olá você\n")

        try workspace.write("latin.txt", try #require("café\n".data(using: .windowsCP1252)))
        _ = try await run(EditFileTool(), ["path": .string("latin.txt"), "old_text": .string("café"), "new_text": .string("pão")])
        #expect(try workspace.read("latin.txt") == (try #require("pão\n".data(using: .windowsCP1252))))
        // Characters Windows-1252 cannot hold are refused instead of being replaced by "?".
        #expect(await workspace.failure(EditFileTool(), ["path": .string("latin.txt"), "old_text": .string("pão"), "new_text": .string("日本")]).contains("Windows-1252"))
        #expect(try workspace.read("latin.txt") == (try #require("pão\n".data(using: .windowsCP1252))))

        try workspace.write("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("abc\n".utf8))
        _ = try await run(EditFileTool(), ["path": .string("bom.txt"), "old_text": .string("b"), "new_text": .string("B")])
        #expect(try workspace.read("bom.txt") == Data([0xEF, 0xBB, 0xBF]) + Data("aBc\n".utf8))
    }

    @Test func editWritesThroughSymlinksAndKeepsPermissions() async throws {
        let real = try workspace.write("dotfiles/profile", "export A=1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: real.path)
        try workspace.link(".profile", to: "dotfiles/profile")
        let result = try await run(EditFileTool(), ["path": .string(".profile"), "old_text": .string("A=1"), "new_text": .string("A=2")])
        #expect(result.contains("link simbólico"))
        #expect(try FileManager.default.attributesOfItem(atPath: workspace.url(".profile").path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try workspace.readText("dotfiles/profile") == "export A=2\n")
        #expect(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func editMatchesCanonicallyEquivalentText() async throws {
        // File has "é" decomposed (e + U+0301); the model sends it composed.
        try workspace.write("nfd.txt", "cafe\u{301}\n")
        _ = try await run(EditFileTool(), ["path": .string("nfd.txt"), "old_text": .string("caf\u{E9}"), "new_text": .string("tea")])
        #expect(try workspace.readText("nfd.txt") == "tea\n")
    }

    @Test func editRefusesBadInput() async throws {
        try workspace.write("a.txt", "a\n")
        #expect(await workspace.failure(EditFileTool(), ["path": .string("nope.txt"), "old_text": .string("a"), "new_text": .string("b")]).contains("write_file"))
        #expect(await workspace.failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string(""), "new_text": .string("b")]).contains("old_text"))
        #expect(await workspace.failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("a"), "new_text": .string("a")]).contains("idênticos"))
        #expect(await workspace.failure(EditFileTool(), ["path": .string("a.txt"), "old_text": .string("a")]).contains("new_text"))
        try workspace.write("blob.bin", Data([1, 0, 2]))
        #expect(await workspace.failure(EditFileTool(), ["path": .string("blob.bin"), "old_text": .string("a"), "new_text": .string("b")]).contains("binário"))
    }

    @Test func editApprovalCardShowsAShortDiff() {
        let tool = EditFileTool()
        let arguments: JSONValue = .object(["path": .string("src/a.swift"), "old_text": .string("let a = 1\nlet b = 2"), "new_text": .string("let a = 10")])
        let summary = tool.summary(arguments)
        #expect(summary.title == "Editando arquivo")
        #expect(summary.detail == "src/a.swift\n- let a = 1\n- let b = 2\n+ let a = 10")
        #expect(tool.risk(arguments) == .sensitive)
        #expect(tool.capability == .terminal)

        let long = String((1...20).map { "line \($0)\n" }.joined())
        let big = tool.summary(.object(["path": .string("x"), "old_text": .string(long), "new_text": .string("y"), "replace_all": .bool(true)]))
        #expect(big.detail.contains("(+13 linhas)"))
        #expect(big.detail.contains("Todas as ocorrências"))
    }

    // MARK: list_directory

    @Test func listTreatsSymlinkedFoldersAsFolders() async throws {
        try workspace.write("real/inner.txt", "x")
        try workspace.link("alias", to: "real")
        try workspace.link("file-alias.txt", to: "real/inner.txt")
        let listing = try await run(ListDirectoryTool(), [:])
        #expect(listing.contains("\nalias/"))
        #expect(listing.contains("\nreal/"))
        #expect(listing.contains("\nfile-alias.txt  ("))
        // The folder shown through the link can be listed.
        #expect(try await run(ListDirectoryTool(), ["path": .string("alias")]).contains("inner.txt"))
    }

    @Test func aDeepListStopsCountingAtTheCap() async throws {
        let folder = workspace.url("many")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 0..<(ListDirectoryTool.countCap + 100) {
            FileManager.default.createFile(atPath: folder.appending(path: "f\(number).txt").path, contents: nil)
        }
        let listing = try await run(ListDirectoryTool(), ["depth": .number(2)])
        #expect(listing.contains("mais de 5.000 itens"), Comment(rawValue: String(listing.suffix(200))))
    }

    @Test func listReportsAnUnreadableFolderInsteadOfCallingItEmpty() async throws {
        let locked = workspace.url("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try workspace.write("locked/inner.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // Running as root (some CI) reads anything; the assertions only make sense when the folder is really locked.
        guard (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil else { return }

        let message = await workspace.failure(ListDirectoryTool(), ["path": .string("locked")])
        #expect(message.contains("Não consegui ler"))

        // An unreadable subfolder is skipped and mentioned, the rest is still listed.
        try workspace.write("open.txt", "y")
        let listing = try await run(ListDirectoryTool(), ["depth": .number(2)])
        #expect(listing.contains("open.txt"))
        #expect(listing.contains("locked/"))
        #expect(listing.contains("1 subpasta sem permissão"))
    }

    @Test func listShowsModificationDates() async throws {
        let file = try workspace.write("dated.txt", "x")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
        let line = try await run(ListDirectoryTool(), [:]).split(separator: "\n").first { $0.hasPrefix("dated.txt") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        #expect(line?.contains(formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))) == true)
    }

    @Test func listFiltersByPatternAndRecursesToDepth() async throws {
        try workspace.write("a.md", "")
        try workspace.write("b.txt", "")
        try workspace.write("docs/c.md", "")
        try workspace.write("docs/deep/d.md", "")
        try workspace.write("docs/deep/deeper/e.md", "")
        try workspace.write("node_modules/pkg/f.md", "")

        let flat = try await run(ListDirectoryTool(), ["pattern": .string("*.md")])
        #expect(flat.contains("a.md") && !flat.contains("b.txt") && !flat.contains("c.md"))

        let two = try await run(ListDirectoryTool(), ["pattern": .string("*.md"), "depth": .string("2")])
        #expect(two.contains("\ndocs/c.md") && !two.contains("d.md"))

        let all = try await run(ListDirectoryTool(), ["pattern": .string("*.md"), "depth": .number(99)])
        #expect(all.contains("docs/deep/d.md"))
        #expect(!all.contains("e.md"), "depth is capped at 3")
        #expect(!all.contains("f.md"), "node_modules is not entered")

        let none = try await run(ListDirectoryTool(), ["pattern": .string("*.zzz")])
        #expect(none.contains("Nenhuma entrada"))
    }

    // MARK: search_files

    @Test func emptySpotlightResultMentionsBlindSpotsAndGrep() async throws {
        let query = "orbnosuchfile\(UUID().uuidString.prefix(8)).xyz"
        let result = try await run(SearchFilesTool(), ["query": .string(query), "directory": .string(workspace.directory.path)])
        #expect(result.contains("Spotlight"))
        #expect(result.contains("grep"))
    }

    // MARK: String arguments

    @Test func stringTypedArgumentsAreAccepted() {
        let arguments: JSONValue = .object([
            "n": .string("120"), "padded": .string(" 7 "), "float": .string("3.9"), "bad": .string("abc"), "real": .number(5),
            "yes": .string("true"), "YES": .string("Sim"), "no": .string("false"), "one": .string("1"), "bool": .bool(true),
            "junk": .string("maybe"),
        ])
        #expect(arguments.integer("n", default: 1, in: 1...600) == 120)
        #expect(arguments.integer("n", default: 1, in: 1...100) == 100)
        #expect(arguments.integer("padded", default: 1, in: 1...600) == 7)
        #expect(arguments.integer("float", default: 1, in: 1...600) == 3)
        #expect(arguments.integer("bad", default: 42, in: 1...600) == 42)
        #expect(arguments.integer("real", default: 1, in: 1...600) == 5)
        #expect(arguments.integer("missing", default: 9, in: 1...600) == 9)
        #expect(arguments.flag("yes") && arguments.flag("YES") && arguments.flag("one") && arguments.flag("bool"))
        #expect(!arguments.flag("no") && !arguments.flag("missing"))
        #expect(arguments.flag("junk", default: true) && !arguments.flag("junk"))
    }

    @Test func runCommandAcceptsStringTimeout() async throws {
        let start = ContinuousClock.now
        let output = try await run(RunCommandTool(), ["command": .string("sleep 30"), "timeout_seconds": .string("1")])
        #expect(output.contains("tempo esgotado após 1 s"))
        #expect(ContinuousClock.now - start < .seconds(20)) // ended by the timeout, not by the thirty seconds of the command
    }
}
