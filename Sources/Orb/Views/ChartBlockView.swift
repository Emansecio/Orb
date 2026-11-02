import Charts
import SwiftUI

/// A ```chart fence as a chart (`ChartSpec`), in the frame of a code block: the same fill and the same buttons, and its source
/// a click away.
struct ChartBlockView: View, Equatable {
    let spec: ChartSpec
    let source: String
    @State private var showsSource = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source }

    var body: some View {
        RichBlockFrame(title: spec.title ?? "gráfico", source: source, language: "json", block: .chart(spec, source: source), showsSource: $showsSource) {
            ChartCanvas(spec: spec)
                .frame(height: 220)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }
}

/// The chart itself.
struct ChartCanvas: View {
    let spec: ChartSpec

    /// In order, so a series keeps its color between charts of a reply.
    nonisolated static let colors: [Color] = [Palette.codeType, Palette.codeKeyword, Palette.codeNumber, Palette.codeString,
                                              Palette.codeRemoved, Palette.accentText, Palette.secondary, Palette.warn]

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        spec.series.enumerated().flatMap { row, series in
            zip(spec.labels, series.values).enumerated().compactMap { column, pair in
                pair.1.map { Point(id: row * ChartSpec.maxLabels + column, label: pair.0, series: series.name, value: $0) }
            }
        }
    }

    private var domain: [String] { spec.kind == .pie ? spec.labels : spec.series.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            chart
                .chartForegroundStyleScale(domain: domain, range: Self.colors.cycled(to: domain.count))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Palette.line)
                        AxisValueLabel().foregroundStyle(Palette.faint)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Palette.line)
                        AxisValueLabel().foregroundStyle(Palette.faint)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spec.speech)
            if domain.count > 1 { legend }
        }
    }

    @ViewBuilder private var chart: some View {
        switch spec.kind {
        case .bar:
            Chart(points) { point in
                BarMark(x: .value("Rótulo", point.label), y: .value("Valor", point.value))
                    .position(by: .value("Série", point.series))
                    .foregroundStyle(by: .value("Série", point.series))
            }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("Rótulo", point.label), y: .value("Valor", point.value), series: .value("Série", point.series))
                    .foregroundStyle(by: .value("Série", point.series))
                PointMark(x: .value("Rótulo", point.label), y: .value("Valor", point.value))
                    .foregroundStyle(by: .value("Série", point.series))
                    .symbolSize(18)
            }
            .chartXScale(domain: spec.labels)
        case .area:
            Chart(points) { point in
                AreaMark(x: .value("Rótulo", point.label), y: .value("Valor", point.value), series: .value("Série", point.series),
                         stacking: .unstacked)
                    .foregroundStyle(by: .value("Série", point.series))
                    .opacity(0.5)
                // A value with no neighbor has no area to fill.
                PointMark(x: .value("Rótulo", point.label), y: .value("Valor", point.value))
                    .foregroundStyle(by: .value("Série", point.series))
                    .symbolSize(12)
            }
            .chartXScale(domain: spec.labels)
        case .pie:
            Chart(points) { point in
                SectorMark(angle: .value("Valor", point.value), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(by: .value("Fatia", point.label))
            }
        }
    }

    /// Their names beside a dot, never the color alone.
    private var legend: some View {
        let colors = Self.colors.cycled(to: domain.count)
        return WrappingLayout(spacing: Spacing.m) {
            ForEach(Array(domain.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 5) {
                    Circle().fill(colors[index]).frame(width: 8, height: 8)
                    Text(name.isEmpty ? "Série \(index + 1)" : name)
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private extension [Color] {
    /// Past the last color they come back lighter, so no two slices read as one.
    func cycled(to count: Int) -> [Color] { (0..<count).map { $0 < self.count ? self[$0] : self[$0 % self.count].opacity(0.55) } }
}
