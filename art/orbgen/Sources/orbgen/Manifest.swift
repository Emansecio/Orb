import Foundation

/// Keeps `options.json` in step with the art made here: the hair styles (ids and labels, in the editor's order) and
/// each palette's default hair color. Everything else in the file (written by `art/orbs.py manifest`) is kept
/// as is, in the same layout (`json.dump(indent=2, ensure_ascii=False)`), so diffs stay small.
enum Manifest {
    /// Default hair color per palette: a deeper shade of the body that still reads on the app's dark background.
    static let hairColors: [String: UInt32] = [
        "indigo": 0x2B1F9E, "ceu": 0x1A4FA8, "oceano": 0x0B4870, "menta": 0x0E4F5C, "lima": 0x6B4A1E,
        "sol": 0xA45A12, "pessego": 0xB4482C, "coral": 0x7A2A18, "cereja": 0x4E0A24, "rosa": 0x5E1046,
        "lavanda": 0x5E3BC0, "ametista": 0x4A0F80, "aurora": 0x5A2BC0, "algodao": 0x6E9FE0, "chocolate": 0x3A2216,
        "noite": 0x3B45B8, "grafite": 0x3A4560, "perola": 0x6F6490,
    ]

    static let hats = ["bone", "cartola", "chapeu-festa", "coroa", "gorro"]

    static func update(resources: URL) throws {
        let url = resources.appendingPathComponent("options.json")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArtError.read(url.path) }
        json["hair"] = HairStyle.manifest.map { ["id": $0.id, "label": $0.label] }
        // Accessories worn on top of the head: with one of them, styles that have a `-chapeu` layer use it.
        json["hats"] = hats
        if let colors = json["color"] as? [[String: Any]] {
            json["color"] = colors.map { entry in
                var entry = entry
                if let id = entry["id"] as? String, let hair = hairColors[id] { entry["hair"] = String(format: "#%06X", hair) }
                return entry
            }
        }
        // Top-level keys in the order the file already has.
        let order = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  \""), let end = line.dropFirst(3).firstIndex(of: "\"") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<end])
        }
        let keys = order.filter { json[$0] != nil } + json.keys.filter { !order.contains($0) }.sorted()
        var out = "{\n"
        for (i, key) in keys.enumerated() {
            out += "  \(quote(key)): \(emit(json[key]!, indent: 2))\(i < keys.count - 1 ? "," : "")\n"
        }
        out += "}"
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let entryOrder = ["id", "label", "hex", "hair"]

    private static func emit(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent + 2), close = String(repeating: " ", count: indent)
        switch value {
        case let string as String:
            return quote(string)
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { pad + emit($0, indent: indent + 2) }.joined(separator: ",\n") + "\n\(close)]"
        case let object as [String: Any]:
            let keys = entryOrder.filter { object[$0] != nil } + object.keys.filter { !entryOrder.contains($0) }.sorted()
            return "{\n" + keys.map { "\(pad)\(quote($0)): \(emit(object[$0]!, indent: indent + 2))" }.joined(separator: ",\n") + "\n\(close)}"
        case let number as NSNumber:
            return number.stringValue
        default:
            return "null"
        }
    }

    private static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
