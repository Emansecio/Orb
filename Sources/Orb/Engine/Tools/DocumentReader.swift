import AppKit
import ImageIO
import PDFKit
import Vision

/// Turns files that are not plain text (PDF, word-processor documents, images) into text the model can read.
enum DocumentReader {
    /// What one `read_file` call may return, so a huge file never floods the conversation. Kept under
    /// `ToolOutputCap.limit`, so the page arrives whole with its note on where to continue, instead of cut in the middle.
    static let maxCharacters = ToolOutputBudget.pageCharacters

    /// Formats `NSAttributedString` can read without WebKit. HTML is left out on purpose: it is read as source,
    /// which is what editing it needs (and the HTML importer must run on the main thread).
    private static let documentTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "rtfd": .rtfd, "odt": .openDocument,
    ]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp"]

    static func isDocument(_ url: URL) -> Bool { documentTypes[url.pathExtension.lowercased()] != nil }
    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    // MARK: PDF

    /// Parses "3", "2-5", "4-" (to the end) and "-3" (from the start) into a range clamped to the document.
    static func pageRange(_ text: String, pageCount: Int) throws -> ClosedRange<Int> {
        let invalid = ToolError("Intervalo de páginas inválido: \"\(text)\". Use \"3\", \"2-5\" ou \"4-\" (o PDF tem \(pageCount) páginas).")
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let first: Int
        let last: Int
        switch parts.count {
        case 1:
            guard let page = Int(parts[0]) else { throw invalid }
            (first, last) = (page, page)
        default:
            guard parts[0].isEmpty || Int(parts[0]) != nil, parts[1].isEmpty || Int(parts[1]) != nil,
                  !(parts[0].isEmpty && parts[1].isEmpty) else { throw invalid }
            (first, last) = (Int(parts[0]) ?? 1, Int(parts[1]) ?? pageCount)
        }
        guard first >= 1, first <= pageCount, last >= first else { throw invalid }
        return first...min(last, pageCount)
    }

    /// Text of the requested pages, each under a "--- Página N ---" marker, cut at `maxCharacters` with a hint
    /// for the next range.
    static func pdfText(_ data: Data, pages: String?) throws -> String {
        guard let document = PDFDocument(data: data) else { throw ToolError("Não consegui abrir o PDF (corrompido ou protegido).") }
        if document.isLocked { throw ToolError("O PDF está protegido por senha.") }
        let count = document.pageCount
        guard count > 0 else { return "(PDF sem páginas)" }
        let range = try pages.map { try pageRange($0, pageCount: count) } ?? 1...count

        var output = "PDF com \(count) página\(count == 1 ? "" : "s"); mostrando \(range.lowerBound == range.upperBound ? "a página \(range.lowerBound)" : "as páginas \(range.lowerBound)-\(range.upperBound)")."
        var wroteText = false
        for number in range {
            let text = (document.page(at: number - 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let block = "\n\n--- Página \(number) ---\n" + text
            if output.count + block.count > maxCharacters {
                if !wroteText {
                    output += block.truncated(to: maxCharacters - output.count)
                }
                let next = wroteText ? number : number + 1
                if next <= count { output += "\n[... texto cortado; use pages=\"\(next)-\" para continuar ...]" }
                return output
            }
            output += block
            wroteText = wroteText || !text.isEmpty
        }
        if !wroteText {
            output += "\n(Nenhum texto extraível: o PDF parece ser digitalizado. Converta a página em imagem, por exemplo com run_command e `qlmanage -t` ou `sips`, e leia a imagem para obter o texto por OCR.)"
        }
        return output
    }

    /// Every page's text with page markers, uncut (web_fetch pages through it by character offset itself).
    static func allPDFText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else { throw ToolError("Não consegui abrir o PDF (corrompido ou protegido).") }
        if document.isLocked { throw ToolError("O PDF está protegido por senha.") }
        return (0..<document.pageCount).map { index in
            "--- Página \(index + 1) ---\n" + (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
    }

    // MARK: Word-processor documents

    static func documentText(at url: URL) throws -> String {
        guard let type = documentTypes[url.pathExtension.lowercased()] else { throw ToolError("Formato de documento não suportado.") }
        do {
            let document = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            return document.string
        } catch {
            throw ToolError("Não consegui ler o documento \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Images

    /// Pixel size plus the text Vision recognises (Portuguese and English).
    static func describeImage(at url: URL, size: Int) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("Não consegui abrir a imagem \(url.lastPathComponent).")
        }
        let bytes = AttachmentKind.fileSize(Int64(size))
        var output = "Imagem \(url.pathExtension.uppercased()): \(image.width)×\(image.height) px (\(bytes))."

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let languages = ["pt-BR", "en-US"].filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        // Vision now and then refuses a request while others run (CRImageReaderError under load): try twice more, briefly.
        var failure: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25 * Double(attempt)) }
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                failure = nil
                break
            } catch {
                failure = error
            }
        }
        if let failure { return output + "\nNão foi possível fazer OCR: \(failure.localizedDescription)" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return output + "\nNenhum texto reconhecido na imagem (OCR)." }
        output += "\nTexto reconhecido (OCR):\n" + lines.joined(separator: "\n")
        return output.truncated(to: maxCharacters)
    }
}
