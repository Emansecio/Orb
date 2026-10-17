import CoreGraphics
import Foundation
import Vision

// Tables (and forms laid out in a grid) on a picture. The plain OCR (`VNRecognizeTextRequest`) stays the default and the
// fallback: it gives lines, not rows and columns. When its boxes look like a table, and the Mac has macOS 26's
// `RecognizeDocumentsRequest`, that request gives the table back with its rows and columns, as a markdown table.

enum TableRecognizer {
    static let maxRows = 60
    static let maxColumns = 12
    static let maxCharacters = 4_000

    // MARK: Is it a table?

    /// Whether text boxes (fractions of the picture, any vertical direction) are laid out as a table: at least 3 rows with 2 or
    /// more boxes each, and at least 2 left edges that 3 of those rows share. Cheap, and wrong sometimes: a wrong yes costs one more
    /// Vision request, a wrong no leaves the plain text, which is what the model had before.
    static func looksTabular(_ boxes: [CGRect]) -> Bool {
        guard boxes.count >= 6 else { return false }
        // Rows: boxes whose centres are within half a line of each other.
        var rows: [[CGRect]] = []
        for box in boxes.sorted(by: { $0.midY > $1.midY }) {
            if let last = rows.last, let reference = last.first, abs(reference.midY - box.midY) <= min(reference.height, box.height) / 2 {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        let wide = rows.filter { $0.count >= 2 }
        guard wide.count >= 3 else { return false }
        // Columns: left edges that fall together (2% of the width) in 3 or more rows.
        var columns: [(edge: CGFloat, rows: Set<Int>)] = []
        for (index, row) in wide.enumerated() {
            for box in row {
                if let match = columns.firstIndex(where: { abs($0.edge - box.minX) <= 0.02 }) {
                    columns[match].rows.insert(index)
                } else {
                    columns.append((box.minX, [index]))
                }
            }
        }
        return columns.filter { $0.rows.count >= 3 }.count >= 2
    }

    // MARK: The table as text

    /// A cell at its first row and column; a merged cell fills only that one (the rest stay empty).
    struct Cell: Sendable, Equatable {
        var row: Int
        var column: Int
        var text: String
    }

    static func grid(_ cells: [Cell]) -> [[String]] {
        guard let rows = cells.map(\.row).max(), let columns = cells.map(\.column).max() else { return [] }
        var grid = [[String]](repeating: [String](repeating: "", count: columns + 1), count: rows + 1)
        for cell in cells where cell.row >= 0 && cell.column >= 0 { grid[cell.row][cell.column] = cell.text }
        return grid
    }

    /// `| a | b |` rows with a separator under the first row (which usually is the header). Cut at `maxRows` rows and `maxColumns`
    /// columns, and the note says so. Empty when there are fewer than 2 rows or 2 columns: that is a list, not a table.
    static func markdown(_ grid: [[String]]) -> String {
        guard grid.count >= 2, let width = grid.map(\.count).max(), width >= 2 else { return "" }
        let columns = min(width, maxColumns)
        func line(_ row: [String]) -> String {
            let cells = (0..<columns).map { index in
                index < row.count ? clean(row[index]) : ""
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        var lines = [line(grid[0]), "|" + String(repeating: " --- |", count: columns)]
        lines += grid.dropFirst().prefix(maxRows - 1).map(line)
        var text = lines.joined(separator: "\n")
        var cut: [String] = []
        if grid.count > maxRows { cut.append("\(grid.count - maxRows) linhas") }
        if width > maxColumns { cut.append("\(width - maxColumns) colunas") }
        if !cut.isEmpty { text += "\n[... faltam " + cut.joined(separator: " e ") + " ...]" }
        return text
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
    }

    /// Several tables, each with its size; empty when none.
    static func report(_ tables: [[[String]]]) -> String {
        let shown = tables.map(markdown).enumerated().filter { !$0.element.isEmpty }
        guard !shown.isEmpty else { return "" }
        let text = shown.map { index, table in
            let grid = tables[index]
            return "Tabela \(index + 1) (\(grid.count) linhas × \(grid.map(\.count).max() ?? 0) colunas):\n" + table
        }.joined(separator: "\n\n")
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "\n[... tabelas cortadas em \(maxCharacters) caracteres ...]" : text
    }

    // MARK: Vision

    /// The tables on the picture as markdown, or nil: it does not look like a table (`boxes`), the Mac is older than macOS 26,
    /// Vision found none or failed, or there are fewer than 2 seconds of `budget` left. It never throws for the request's own
    /// failure (the plain text still stands); a cancellation does throw.
    static func tables(in image: CGImage, boxes: [CGRect], budget: TimeInterval) async throws -> String? {
        guard looksTabular(boxes), budget >= 2, #available(macOS 26.0, *) else { return nil }
        try Task.checkCancellation()
        do {
            let found = try await withDeadline(budget, "a leitura de tabelas") { try await recognizeTables(in: image) }
            try Task.checkCancellation()
            let text = report(found)
            return text.isEmpty ? nil : text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func recognizeTables(in image: CGImage) async throws -> [[[String]]] {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image)
        return observations.flatMap { $0.document.tables }.map { table in
            grid(table.rows.flatMap { $0 }.map {
                Cell(row: $0.rowRange.lowerBound, column: $0.columnRange.lowerBound, text: $0.content.text.transcript)
            })
        }
    }

    /// Seconds of an OCR deadline still free for the tables after `elapsed`, keeping one for the answer.
    static func budget(deadline: TimeInterval, since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: .now)
        return deadline - Double(elapsed.components.seconds) - Double(elapsed.components.attoseconds) / 1e18 - 1
    }
}
