import Foundation

/// What a ```chart fence asks for, read from its JSON:
/// `{"type":"bar","title":"…","labels":["Jan","Fev"],"series":[{"name":"2026","values":[3,5]}]}`, or `"values":[3,5]` for one
/// series. Read once, with the block; whatever is not a chart this app can draw is nil, and the fence stays code.
struct ChartSpec: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable { case bar, line, area, pie }

    struct Series: Equatable, Sendable {
        var name: String
        /// One per label; nil leaves a gap.
        var values: [Double?]
    }

    static let maxLabels = 200
    static let maxSeries = 8
    static let maxSlices = 12

    var kind: Kind
    var title: String?
    var labels: [String]
    var series: [Series]

    static func parse(_ source: String) -> ChartSpec? {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = (root["type"] as? String).flatMap({ Kind(rawValue: $0.lowercased()) }),
              let labels = (root["labels"] as? [Any])?.map(label(_:)), !labels.isEmpty, labels.count <= maxLabels,
              Set(labels).count == labels.count, // the chart axes join repeated names
              let series = series(in: root, count: labels.count), !series.isEmpty, series.count <= maxSeries
        else { return nil }
        if kind == .pie {
            guard series.count == 1, labels.count <= maxSlices, series[0].values.allSatisfy({ ($0 ?? 0) >= 0 }),
                  series[0].values.contains(where: { ($0 ?? 0) > 0 }) else { return nil }
        }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChartSpec(kind: kind, title: title?.isEmpty == false ? String(title!.prefix(120)) : nil, labels: labels, series: series)
    }

    private static func label(_ value: Any) -> String {
        if let text = value as? String { return String(text.prefix(40)) }
        return (value as? NSNumber)?.stringValue ?? ""
    }

    private static func series(in root: [String: Any], count: Int) -> [Series]? {
        let rows: [[String: Any]]
        if let many = root["series"] as? [[String: Any]] {
            rows = many
        } else if root["values"] != nil {
            rows = [root]
        } else {
            return nil
        }
        var result: [Series] = []
        for row in rows {
            guard let values = (row["values"] as? [Any])?.map(number(_:)), values.count == count,
                  !values.contains(where: { $0 == .invalid }) else { return nil }
            result.append(Series(name: String((row["name"] as? String ?? "").prefix(40)), values: values.map(\.value)))
        }
        // Each name is a color of the chart: two equal ones would be drawn as one. Models often leave them out.
        if result.count > 1 {
            for index in result.indices where result[index].name.isEmpty { result[index].name = "Série \(index + 1)" }
        }
        let names = result.map(\.name)
        return Set(names).count == names.count ? result : nil
    }

    private enum Number: Equatable {
        case value(Double?)
        case invalid

        var value: Double? {
            if case .value(let number) = self { number } else { nil }
        }
    }

    private static func number(_ value: Any) -> Number {
        if value is NSNull { return .value(nil) }
        // `true` is an NSNumber too.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return .invalid }
        return .value(number.doubleValue)
    }

    /// What VoiceOver reads: each series with its values.
    var speech: String {
        let name = title.map { "Gráfico: \($0)" } ?? "Gráfico"
        let rows = series.map { line in
            let values = zip(labels, line.values).compactMap { label, value in value.map { "\(label), \($0.formatted())" } }
            return (line.name.isEmpty ? "" : line.name + ": ") + values.joined(separator: "; ")
        }
        return ([name] + rows).joined(separator: ". ")
    }
}
