import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Quick contact sheet straight from the layer files (body + face + hair, tinted like the app), for iterating on
/// the art without launching the app. The app's own sheets (`Orb --render-orbs out.png cabelos`) are the reference.
enum Preview {
    static func sheet(resources: URL, to url: URL, hairs only: [String] = [], tile: Int = 200,
                      columns: [(String, UInt32?)] = defaultColumns) throws {
        let palettes = try Palette.load(from: resources)
        let hairs = only.isEmpty ? ["nenhum"] + HairStyle.all.map(\.id) : only
        let rows = (hairs.count + 2) / 3
        let perRow = columns.count == 1 ? min(3, hairs.count) : columns.count
        let width = tile * perRow, height = tile * (columns.count == 1 ? rows : hairs.count)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtError.write(url.path) }
        context.setFillColor(red: 0.027, green: 0.027, blue: 0.027, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (row, hair) in hairs.enumerated() {
            for (column, item) in columns.enumerated() {
                guard let palette = palettes.first(where: { $0.id == item.0 }) else { continue }
                let variant = palette.isLight ? "-dark" : ""
                let canvas = try Canvas.read(resources.appendingPathComponent("body/\(palette.id).png"))
                for layer in ["eyes/pilulas\(variant)", "mouth/sorriso\(variant)"] {
                    canvas.composite(try Canvas.read(resources.appendingPathComponent("\(layer).png")))
                }
                if hair != "nenhum" {
                    let tint = linear(item.1 ?? defaultHair(palette))
                    canvas.composite(try Canvas.read(resources.appendingPathComponent("hair/\(hair).png")), tint: tint)
                    let shine = resources.appendingPathComponent("hair/\(hair)-brilho.png")
                    if FileManager.default.fileExists(atPath: shine.path) { canvas.composite(try Canvas.read(shine)) }
                }
                guard let image = canvas.cgImage() else { continue }
                // One palette: hairs flow left to right in rows of three.
                let (x, y) = columns.count == 1 ? (row % 3, row / 3) : (column, row)
                // The layer frame holds everything (hats, tails), so draw it whole, cropping only the empty bottom.
                let rect = CGRect(x: x * tile - tile / 8, y: height - (y + 1) * tile - tile / 3, width: tile * 5 / 4, height: tile * 5 / 4)
                context.draw(image, in: rect)
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ArtError.write(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static let defaultColumns: [(String, UInt32?)] = [
        ("indigo", nil), ("rosa", nil), ("menta", nil), ("sol", nil), ("perola", nil), ("noite", nil),
        ("pessego", 0x5A3B22), ("ceu", 0xE8B95A), ("lavanda", 0x1C1A2B),
    ]

    /// Mirrors `OrbConfig.defaultHair` in the app.
    static func defaultHair(_ palette: Palette) -> UInt32 {
        Manifest.hairColors[palette.id] ?? 0x333333
    }
}

extension Canvas {
    func cgImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let p = pixels[i]
            let a = clamp(p.w)
            guard a > 0 else { continue }
            bytes[i * 4] = UInt8((srgb(p.x / a) * a * 255).rounded())
            bytes[i * 4 + 1] = UInt8((srgb(p.y / a) * a * 255).rounded())
            bytes[i * 4 + 2] = UInt8((srgb(p.z / a) * a * 255).rounded())
            bytes[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
