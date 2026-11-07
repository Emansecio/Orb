import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Quick contact sheet straight from the layer files (every body with eyes and a smile), for iterating on the art
/// without launching the app. The app's own sheets (`Orb --render-orbs out.png cores`) are the reference.
enum Preview {
    static func sheet(resources: URL, to url: URL, tile: Int = 200, columns: Int = 6) throws {
        let palettes = try Palette.load(from: resources)
        let rows = (palettes.count + columns - 1) / columns
        let width = tile * columns, height = tile * rows
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtError.write(url.path) }
        context.setFillColor(red: 0.027, green: 0.027, blue: 0.027, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, palette) in palettes.enumerated() {
            let variant = palette.isLight ? "-dark" : ""
            let canvas = try Canvas.read(resources.appendingPathComponent("body/\(palette.id).png"))
            for layer in ["eyes/pilulas\(variant)", "mouth/sorriso\(variant)"] {
                canvas.composite(try Canvas.read(resources.appendingPathComponent("\(layer).png")))
            }
            guard let image = canvas.cgImage() else { continue }
            let (x, y) = (index % columns, index / columns)
            // The layer frame is larger than the orb, so draw it whole, cropping only the empty bottom.
            let rect = CGRect(x: x * tile - tile / 8, y: height - (y + 1) * tile - tile / 3, width: tile * 5 / 4, height: tile * 5 / 4)
            context.draw(image, in: rect)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ArtError.write(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
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
