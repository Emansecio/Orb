import AppKit
import CoreText
import Foundation
import Testing
@testable import Orb

/// The text of attached files goes with the message: PDF, Word, spreadsheets and text files are read by the app, so an
/// Orb reads them with its file tools or without.
final class AttachmentTextTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbAttachmentText-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { removeTestFolder(root) }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func text(_ extracted: AttachmentText.Extracted) -> String? {
        if case .text(let text, _) = extracted { text } else { nil }
    }

    @Test func textFilesAreReadAsTheyAre() throws {
        for name in ["notas.txt", "leia.md", "dados.csv", "config.json"] {
            let url = try write(name, Data("primeira linha — com acento\nsegunda".utf8))
            #expect(text(AttachmentText.extract(url)) == "primeira linha — com acento\nsegunda", "\(name)")
        }
        // Latin-1, as old exports often are.
        let latin = try write("antigo.csv", "nome;cidade\nJoão;Itabira".data(using: .isoLatin1)!)
        #expect(text(AttachmentText.extract(latin))?.contains("João;Itabira") == true)
    }

    @Test func aWordDocumentIsConvertedToText() throws {
        let document = NSAttributedString(string: "Relatório trimestral\nReceita subiu 12%")
        let data = try document.data(from: NSRange(location: 0, length: document.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = try write("relatorio.docx", data)
        let extracted = AttachmentText.extract(url)
        #expect(text(extracted)?.contains("Receita subiu 12%") == true)
        guard case .text(_, let kind) = extracted else { return }
        #expect(kind.contains(".docx"))
    }

    @Test func aPDFIsReadPageByPage() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in ["Contrato de locação", "Cláusula segunda"] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = try write("contrato.pdf", data as Data)
        let read = try #require(text(AttachmentText.extract(url)))
        #expect(read.contains("Contrato de locação") && read.contains("Cláusula segunda"))
        #expect(read.contains("--- Página 2 ---"))
    }

    @Test func anOldExcelFileSavedAsAWebPageIsReadAsATable() throws {
        let page = "<html><body><table><tr><td>Nome</td><td>Matrícula</td></tr><tr><td>Ana</td><td>1128938200</td></tr></table></body></html>"
        let url = try write("lista.xls", page.data(using: .isoLatin1)!)
        let read = try #require(text(AttachmentText.extract(url)))
        #expect(read.contains("Ana\t1128938200"))
    }

    @Test func binariesAndPicturesAreLeftToTheTools() throws {
        let zip = try write("fotos.zip", Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0xFF, 0x00, 0x01]))
        #expect(AttachmentText.extract(zip) == .unread)
        let picture = try write("foto.png", try Pictures.data(width: 8, height: 8))
        #expect(AttachmentText.extract(picture) == .unread)
        // A broken document says why.
        let broken = try write("quebrado.pdf", Data("não é pdf".utf8))
        guard case .failed(let reason) = AttachmentText.extract(broken) else { Issue.record("a broken PDF must fail"); return }
        #expect(reason.contains("PDF"))
    }

    @Test func aLongFileIsCutWhereReadFileCanContinue() throws {
        let line = String(repeating: "x", count: 99)
        let lines = Array(repeating: line, count: AttachmentText.perFile / 50) // twice what fits
        let url = try write("log.txt", Data(lines.joined(separator: "\n").utf8))
        let extracted = AttachmentText.extract(url)
        let block = AttachmentText.block(for: [url], texts: [url: extracted])
        #expect(block.contains("kind=\"texto, cut\""))
        let kept = AttachmentText.perFile / 100 // whole lines of 100 characters with their breaks
        #expect(block.contains("[... cut here; read the rest with read_file, offset=\(kept + 1)]")
                || block.contains("[... cut here; read the rest with read_file, offset=\(kept)]"))
        #expect(block.count < AttachmentText.perFile + 1_000)
    }

    @Test func theFilesShareTheRoomOfTheMessage() {
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/b.txt"), c = URL(fileURLWithPath: "/tmp/c.zip")
        let long = String(repeating: "y", count: 3_000)
        let block = AttachmentText.block(for: [a, b, c], texts: [a: .text(long, kind: "texto"), b: .text(long, kind: "texto"), c: .unread],
                                         room: 4_000)
        #expect(block.hasPrefix("\n\nAttached files ("))
        #expect(block.contains("- /tmp/a.txt\n- /tmp/b.txt\n- /tmp/c.zip"))
        #expect(block.contains("<attached_file path=\"/tmp/a.txt\" kind=\"texto\">\n" + long + "\n</attached_file>"))
        // The second gets what is left (1,000 characters), cut; the zip is left to the tools.
        #expect(block.contains("<attached_file path=\"/tmp/b.txt\" kind=\"texto, cut\">\n" + String(repeating: "y", count: 1_000) + "\n[... cut here"))
        #expect(block.contains("<attached_file path=\"/tmp/c.zip\">\n(not read here: read it with your tools)\n</attached_file>"))
        // A file not read yet is left to the tools too, and nothing at all for no files.
        #expect(AttachmentText.block(for: [a], texts: [:]).contains("(not read here"))
        #expect(AttachmentText.block(for: [], texts: [:]).isEmpty)
        // A small model keeps room for its conversation.
        #expect(AttachmentText.room(historyCharacters: 9_000) == 4_000)
        #expect(AttachmentText.room(historyCharacters: 1_000_000) == AttachmentText.total)
    }

    @Test @MainActor func theCacheReadsOnceAndAgainWhenTheFileChanges() async throws {
        let url = try write("notas.md", Data("# Primeira".utf8))
        let cache = AttachmentTextCache()
        cache.prepare(url)
        let first = await cache.texts([url])
        #expect(first[url].flatMap(text) == "# Primeira")
        #expect(cache.cached([url])[url].flatMap(text) == "# Primeira")
        try Data("# Segunda versão".utf8).write(to: url)
        #expect(cache.cached([url])[url] == nil) // another size: not the text that was read
        #expect(await cache.texts([url])[url].flatMap(text) == "# Segunda versão")
    }
}
