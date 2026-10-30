import Foundation
import Testing
@testable import Orb

/// Benchmark for the streaming path of long code blocks and tables (not a regression test): what a flush costs when it
/// recuts or remeasures the whole block against what it costs keeping the closed parts (`StreamCut`, `FloorMeasure`).
struct StreamingBenchTests {
    private func codeLines(_ range: Range<Int>) -> String {
        range.map { "    let value\($0) = compute(index: \($0), factor: \($0 * 2))" }.joined(separator: "\n") + "\n"
    }

    private func tableRows(_ range: Range<Int>) -> [[String]] {
        range.map { ["Linha \($0)", "Resultado \($0 * 7)", "https://example.com/caminho/\($0)", "nota"] }
    }

    private func table(rows: [[String]]) -> MarkdownTable {
        MarkdownTable(header: ["Item", "Valor", "Link", "Nota"], rows: rows, alignments: [.leading, .trailing, .leading, .leading])
    }

    /// What `codeText`/`TableBlockView.body` did on every flush before the cut and the measure were kept.
    @Test func measureFlushCostOfLongCodeAndTables() {
        let clock = ContinuousClock()

        var code = ""
        var closed: [String] = []
        var comparisons = 0
        let codeTime = clock.measure {
            for line in stride(from: 1, through: 2_000, by: 20) {
                code += codeLines(line..<line + 20)
                guard let pieces = CodeBlockView.pieces(of: code) else { continue }
                // Each closed piece is an Equatable CodeLines: comparing it costs a full string compare per piece.
                let previous = closed
                for (index, piece) in pieces.closed.enumerated() where index < previous.count {
                    comparisons += (piece == previous[index] ? 1 : 0)
                }
                closed = pieces.closed
            }
        }

        var rows: [[String]] = []
        var floorSum: CGFloat = 0
        let tableTime = clock.measure {
            for row in stride(from: 1, through: 400, by: 5) {
                rows += tableRows(row..<row + 5)
                floorSum += TableBlockView.columnFloors(of: table(rows: rows)).reduce(0, +)
                _ = TableBlockView.pieces(of: rows)
            }
        }

        print("CODE-BENCH flushes=100 closedPieces=\(closed.count) comparisons=\(comparisons) time=\(codeTime)")
        print("TABLE-BENCH flushes=80 floorSum=\(floorSum) time=\(tableTime)")
    }

    /// The same flushes through the kept cut/measure: a flush re-splits only what grew and folds only the new rows.
    @MainActor @Test func measureFlushCostWithTheKeptCutAndMeasure() {
        let clock = ContinuousClock()

        var code = ""
        let cut = CodeBlockView.StreamCut()
        var closed: [String] = []
        var comparisons = 0
        let codeTime = clock.measure {
            for line in stride(from: 1, through: 2_000, by: 20) {
                code += codeLines(line..<line + 20)
                guard let pieces = cut.pieces(of: code) else { continue }
                // The closed pieces are the same strings, so these compares hit the same-storage fast path.
                let previous = closed
                for (index, piece) in pieces.closed.enumerated() where index < previous.count {
                    comparisons += (piece == previous[index] ? 1 : 0)
                }
                closed = pieces.closed
            }
        }

        var rows: [[String]] = []
        let measure = TableBlockView.FloorMeasure()
        var floorSum: CGFloat = 0
        let tableTime = clock.measure {
            for row in stride(from: 1, through: 400, by: 5) {
                rows += tableRows(row..<row + 5)
                floorSum += measure.floors(of: table(rows: rows)).reduce(0, +)
                _ = TableBlockView.pieces(of: rows)
            }
        }

        print("CODE-BENCH-KEPT flushes=100 closedPieces=\(closed.count) comparisons=\(comparisons) time=\(codeTime)")
        print("TABLE-BENCH-KEPT flushes=80 floorSum=\(floorSum) time=\(tableTime)")
    }
}
