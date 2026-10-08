import Foundation

/// A body color from `options.json`: rim (frosted edge), core, deep (top) and glow (bottom), sRGB hex.
struct Palette: Sendable {
    let id: String
    let rim: UInt32, core: UInt32, deep: UInt32, glow: UInt32

    /// Light bodies (white-ish) use dark faces: `OrbCatalog.lightPalettes` in the app.
    static let light: Set<String> = ["perola", "algodao"]
    var isLight: Bool { Self.light.contains(id) }

    static func load(from resources: URL) throws -> [Palette] {
        let url = resources.appendingPathComponent("options.json")
        guard let data = try? Data(contentsOf: url),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = json["color"] as? [[String: Any]] else { throw ArtError.read(url.path) }
        return colors.compactMap { entry in
            let hexes = (entry["hex"] as? [String] ?? []).compactMap { UInt32($0.dropFirst(), radix: 16) }
            guard let id = entry["id"] as? String, hexes.count >= 4 else { return nil }
            return Palette(id: id, rim: hexes[0], core: hexes[1], deep: hexes[2], glow: hexes[3])
        }
    }
}
