import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Orb

/// Tables on a picture: the layout test, the markdown and the limits are checked with made-up boxes and cells; one test draws a table
/// in memory and reads it with Vision (nothing on screen, no app).
struct TableRecognizerTests {
    /// `rows` x `columns` boxes in fractions of the picture, columns starting at 0.1, 0.4 and 0.7.
    private func gridBoxes(rows: Int, columns: Int, jitter: CGFloat = 0) -> [CGRect] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGRect(x: 0.1 + CGFloat(column) * 0.3 + (row.isMultiple(of: 2) ? jitter : 0), y: 0.9 - CGFloat(row) * 0.1, width: 0.2, height: 0.04)
            }
        }
    }

    @Test func aGridOfBoxesLooksLikeATable() {
        #expect(TableRecognizer.looksTabular(gridBoxes(rows: 4, columns: 3)))
        #expect(TableRecognizer.looksTabular(gridBoxes(rows: 3, columns: 2, jitter: 0.01)), "edges within 2% still line up")
    }

    @Test func linesOfTextAreNotATable() {
        let paragraph = (0..<10).map { CGRect(x: 0.1, y: 0.9 - CGFloat($0) * 0.05, width: 0.8, height: 0.03) }
        #expect(!TableRecognizer.looksTabular(paragraph))
        #expect(!TableRecognizer.looksTabular([]))
        #expect(!TableRecognizer.looksTabular(gridBoxes(rows: 2, columns: 3)), "two rows are not enough")
        #expect(!TableRecognizer.looksTabular(gridBoxes(rows: 5, columns: 1)), "one column is a list")
    }

    @Test func scatteredBoxesInRowsAreNotATableEither() {
        // Boxes that share rows but never a left edge: a sidebar next to loose text.
        let scattered = (0..<5).flatMap { (row: Int) -> [CGRect] in
            [CGRect(x: 0.02 + CGFloat(row) * 0.05, y: 0.9 - CGFloat(row) * 0.1, width: 0.1, height: 0.04),
             CGRect(x: 0.5 + CGFloat(row) * 0.07, y: 0.9 - CGFloat(row) * 0.1, width: 0.1, height: 0.04)]
        }
        #expect(!TableRecognizer.looksTabular(scattered))
    }

    @Test func cellsBecomeAGridAtTheirFirstRowAndColumn() {
        let grid = TableRecognizer.grid([.init(row: 0, column: 0, text: "Nome"), .init(row: 0, column: 2, text: "Total"),
                                         .init(row: 1, column: 0, text: "Ana"), .init(row: 1, column: 1, text: "10"), .init(row: 1, column: 2, text: "R$ 5")])
        #expect(grid == [["Nome", "", "Total"], ["Ana", "10", "R$ 5"]])
        #expect(TableRecognizer.grid([]).isEmpty)
    }

    @Test func theMarkdownHasAHeaderSeparatorAndSafeCells() {
        let text = TableRecognizer.markdown([["Item", "Nota"], ["a | b", "linha 1\nlinha 2"], ["x", ""]])
        #expect(text == "| Item | Nota |\n| --- | --- |\n| a \\| b | linha 1 linha 2 |\n| x |  |")
        #expect(TableRecognizer.markdown([["só uma linha", "b"]]).isEmpty)
        #expect(TableRecognizer.markdown([["a"], ["b"], ["c"]]).isEmpty, "one column is a list")
    }

    @Test func aBigTableIsCutAndSaysHowMuchIsMissing() {
        let rows = (0..<80).map { row in (0..<15).map { "r\(row)c\($0)" } }
        let text = TableRecognizer.markdown(rows)
        #expect(text.contains("r59c11") && !text.contains("r60c0") && !text.contains("c12"))
        #expect(text.hasSuffix("[... faltam 20 linhas e 3 colunas ...]"))
    }

    @Test func theReportNumbersTablesAndHasALimit() {
        let report = TableRecognizer.report([[["a", "b"], ["1", "2"]], [["só"]], [["x", "y", "z"], ["1", "2", "3"], ["4", "5", "6"]]])
        #expect(report.contains("Tabela 1 (2 linhas × 2 colunas):") && report.contains("Tabela 3 (3 linhas × 3 colunas):"))
        #expect(!report.contains("Tabela 2"), "a single cell is not a table")
        #expect(TableRecognizer.report([]).isEmpty)
        let huge = TableRecognizer.report([(0..<60).map { row in (0..<12).map { _ in String(repeating: "x", count: 40) + "\(row)" } }])
        #expect(huge.count < TableRecognizer.maxCharacters + 100 && huge.contains("tabelas cortadas"))
    }

    @Test func theBudgetIsWhatTheTextLeftMinusOneSecond() {
        let budget = TableRecognizer.budget(deadline: 20, since: ContinuousClock.now)
        #expect(budget > 18.5 && budget <= 19)
        let late = ContinuousClock.now - .seconds(30)
        #expect(TableRecognizer.budget(deadline: 20, since: late) < 0)
    }

    private func blankImage() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func noTablesWithoutATableLayoutOrWithoutTime() async throws {
        let image = blankImage()
        let paragraph = (0..<10).map { CGRect(x: 0.1, y: 0.9 - CGFloat($0) * 0.05, width: 0.8, height: 0.03) }
        #expect(try await TableRecognizer.tables(in: image, boxes: paragraph, budget: 20) == nil)
        #expect(try await TableRecognizer.tables(in: image, boxes: gridBoxes(rows: 4, columns: 3), budget: 1) == nil, "no time left for the tables")
    }

    @Test func aCancelledReadStopsInsteadOfFallingBackToPlainText() async {
        let image = blankImage()
        let boxes = gridBoxes(rows: 4, columns: 3)
        let task = Task { try await TableRecognizer.tables(in: image, boxes: boxes, budget: 20) }
        task.cancel()
        do {
            _ = try await task.value
            // On a Mac older than macOS 26 the answer is nil before any request: no cancellation to see.
            if #available(macOS 26.0, *) { Issue.record("a cancelled read should throw") }
        } catch { #expect(error is CancellationError) }
    }

    // MARK: Vision, for real

    /// A 3-column table drawn in memory: grid lines and text. Vision sees only this picture.
    private func tableImage(at url: URL) throws {
        let width = 1_200, height = 520
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(3)
        let columns: [CGFloat] = [60, 460, 760, 1_140], rows: [CGFloat] = [460, 370, 280, 190, 100, 20]
        for x in columns { context.move(to: CGPoint(x: x, y: rows.last!)); context.addLine(to: CGPoint(x: x, y: rows.first!)) }
        for y in rows { context.move(to: CGPoint(x: columns.first!, y: y)); context.addLine(to: CGPoint(x: columns.last!, y: y)) }
        context.strokePath()
        let cells = [["Produto", "Quantidade", "Preco"], ["Caneta", "12", "3,50"], ["Caderno", "7", "18,90"], ["Mochila", "2", "120,00"], ["Lapis", "30", "1,25"]]
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() {
                let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
                context.textPosition = CGPoint(x: columns[column] + 20, y: rows[row + 1] + 28)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aDrawnTableComesBackWithItsRowsAndColumns() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orb-table-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try tableImage(at: file)
        let text = try await TextRecognizer.recognizeWithTables(imageAt: file)
        #expect(text.contains("Caderno") && text.contains("Mochila"), "the plain text is always there")
        if #available(macOS 26.0, *) {
            #expect(text.hasPrefix("Tabela 1 (5 linhas × 3 colunas):\n| Produto | Quantidade | Preco |\n| --- | --- | --- |\n| Caneta | 12 | 3,50 |"))
            #expect(text.contains("| Mochila | 2 | 120,00 |") && text.contains("Texto corrido:"))
        } else {
            #expect(!text.contains("Tabela 1"))
        }
    }
}
