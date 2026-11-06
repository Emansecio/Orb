import Foundation

/// Seats the flat feature layers (eyes, mouths, brows, visemes, accessories rendered by Blender, kept in
/// `art/orbgen/flat/`) on the lit body: each gets a soft contact shadow cast away from the key light, limited to the
/// head, so it reads as part of the 3D object instead of a sticker. The original pixels stay on top, untouched.
enum Decals {
    struct Look {
        /// Shadow offset (pixels at 640) and blur (sigma, pixels), and its opacity.
        var offset: (x: Int, y: Int)
        var blur: Double
        var opacity: Double
    }

    static let looks: [String: Look] = [
        "eyes": Look(offset: (3, 5), blur: 3.5, opacity: 0.34),
        "brows": Look(offset: (2, 4), blur: 2.5, opacity: 0.26),
        "mouth": Look(offset: (2, 4), blur: 3, opacity: 0.28),
        "visemes": Look(offset: (2, 4), blur: 3, opacity: 0.28),
        "accessories": Look(offset: (5, 9), blur: 6, opacity: 0.32),
    ]

    /// Layers the app tints by multiplying (the headphones) keep no shadow: the multiply would turn
    /// a translucent dark shadow into a translucent tinted glow. They are copied as they are.
    static func run(flat: URL, resources: URL, only: Set<String>) throws {
        let fm = FileManager.default
        let tinted = try tintedAccessories(resources)
        let categories = Set(looks.keys).union(["cheeks"])
        for category in categories.sorted() where only.isEmpty || only.contains(category) {
            let folder = flat.appendingPathComponent(category)
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files.sorted() where file.hasSuffix(".png") {
                let source = try Canvas.read(folder.appendingPathComponent(file))
                let id = String(file.dropLast(4))
                let skip = category == "accessories" && tinted.contains(id)
                let out = looks[category].flatMap { skip ? nil : seat(source, look: $0) } ?? source
                try out.writePNG(to: resources.appendingPathComponent("\(category)/\(file)"))
            }
            print("traços", category, files.filter { $0.hasSuffix(".png") }.count)
        }
    }

    private static func tintedAccessories(_ resources: URL) throws -> Set<String> {
        let url = resources.appendingPathComponent("options.json")
        guard let data = try? Data(contentsOf: url),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArtError.read(url.path) }
        return Set(json["tintedAccessories"] as? [String] ?? [])
    }

    static func seat(_ source: Canvas, look: Look) -> Canvas {
        let side = source.side
        var alpha = [Double](repeating: 0, count: side * side)
        for i in 0..<(side * side) { alpha[i] = source.pixels[i].w }
        let blurred = gaussian(alpha, side: side, sigma: look.blur)
        let out = Canvas(side: side)
        let shadowColor = V3(0.02, 0.008, 0.035)
        for y in 0..<side {
            for x in 0..<side {
                let sx = x - look.offset.x, sy = y - look.offset.y
                let cast = sx >= 0 && sy >= 0 && sx < side && sy < side ? blurred[sy * side + sx] : 0
                // Only where the head is (the background must stay clean).
                let q = Frame.point(Double(x) + 0.5, Double(y) + 0.5)
                let inside = 1 - smoothstep(0.985, 1.0, length(V2(q.x / Head.radii.x, q.y / Head.radii.y)))
                let shadow = min(1, cast * 1.15) * look.opacity * inside
                let top = source.pixels[y * side + x]
                let under = Pixel(shadowColor.x * shadow, shadowColor.y * shadow, shadowColor.z * shadow, shadow)
                out.pixels[y * side + x] = top + under * (1 - top.w)
            }
        }
        return out
    }

    /// Separable Gaussian blur of a single channel.
    static func gaussian(_ input: [Double], side: Int, sigma: Double) -> [Double] {
        let radius = Int((sigma * 3).rounded(.up))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var temp = [Double](repeating: 0, count: input.count)
        var output = [Double](repeating: 0, count: input.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let xx = min(side - 1, max(0, x + k))
                    sum += input[y * side + xx] * kernel[k + radius]
                }
                temp[y * side + x] = sum
            }
        }
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let yy = min(side - 1, max(0, y + k))
                    sum += temp[yy * side + x] * kernel[k + radius]
                }
                output[y * side + x] = sum
            }
        }
        return output
    }
}
