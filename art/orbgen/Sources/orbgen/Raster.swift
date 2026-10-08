import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Linear RGB, premultiplied by alpha.
typealias Pixel = SIMD4<Double>

/// Layer framing shared with the app (`OrbGeometry`): 640 px images, orb centered, x radius 168.5 px
/// (the orb's height, `size` in the app, is 1/1.96 of the image side).
enum Frame {
    static let side = 640
    static let center = 320.0
    static let scale = 168.5

    /// Model-space point (x right, y up) at continuous pixel coordinates (y down).
    @inline(__always) static func point(_ u: Double, _ v: Double) -> V2 {
        V2((u - center) / scale, (center - v) / scale)
    }
}

/// Pixel buffer written from many threads at once (each pixel by one thread only), hence raw storage.
final class Canvas: @unchecked Sendable {
    let side: Int
    let pixels: UnsafeMutableBufferPointer<Pixel>

    init(side: Int = Frame.side) {
        self.side = side
        pixels = .allocate(capacity: side * side)
        pixels.initialize(repeating: .zero)
    }

    deinit { pixels.deallocate() }

    subscript(x: Int, y: Int) -> Pixel {
        get { pixels[y * side + x] }
        set { pixels[y * side + x] = newValue }
    }

    /// Renders every pixel in parallel. `shade` gets continuous pixel coordinates and returns a premultiplied
    /// linear color. Pixels whose neighborhood differs (edges, thin details) get `samples`² stratified samples.
    static func render(side: Int = Frame.side, samples: Int = 4, threshold: Double = 0.02,
                       _ shade: @Sendable (Double, Double) -> Pixel) -> Canvas {
        let canvas = Canvas(side: side)
        let coarse = Canvas(side: side)
        DispatchQueue.concurrentPerform(iterations: side) { y in
            for x in 0..<side { coarse.pixels[y * side + x] = shade(Double(x) + 0.5, Double(y) + 0.5) }
        }
        DispatchQueue.concurrentPerform(iterations: side) { y in
            for x in 0..<side {
                let center = coarse.pixels[y * side + x]
                var edge = false
                for dy in -1...1 where !edge {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                        let d = simd_abs(coarse.pixels[ny * side + nx] - center)
                        if simd_reduce_max(d) > threshold { edge = true; break }
                    }
                }
                guard edge else { canvas.pixels[y * side + x] = center; continue }
                var sum = Pixel.zero
                let n = samples
                for sy in 0..<n {
                    for sx in 0..<n {
                        // Rotated stratified offsets: better edges than a plain grid at the same count.
                        let ox = (Double(sx) + 0.5 + 0.25 * (Double(sy % 2) - 0.5)) / Double(n)
                        let oy = (Double(sy) + 0.5 + 0.25 * (Double(sx % 2) - 0.5)) / Double(n)
                        sum += shade(Double(x) + ox, Double(y) + oy)
                    }
                }
                canvas.pixels[y * side + x] = sum / Double(n * n)
            }
        }
        return canvas
    }

    /// Writes an sRGB PNG with straight alpha; fully transparent pixels get zero color (smaller files).
    func writePNG(to url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let p = pixels[i]
            let a = clamp(p.w)
            let alpha = UInt8((a * 255).rounded())
            guard alpha > 0 else { continue }
            let color = V3(p.x, p.y, p.z) / a
            bytes[i * 4] = UInt8((srgb(color.x) * 255).rounded())
            bytes[i * 4 + 1] = UInt8((srgb(color.y) * 255).rounded())
            bytes[i * 4 + 2] = UInt8((srgb(color.z) * 255).rounded())
            bytes[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ArtError.write(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtError.write(url.path) }
    }

    /// Reads a PNG as premultiplied linear pixels (for previews and for post-processing existing layers).
    static func read(_ url: URL) throws -> Canvas {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ArtError.read(url.path) }
        let side = image.width
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ArtError.read(url.path) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let canvas = Canvas(side: side)
        let table = (0...255).map { v -> Double in
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        for i in 0..<(side * side) {
            let a = Double(bytes[i * 4 + 3]) / 255
            guard a > 0 else { continue }
            let un = { (v: UInt8) in table[min(255, Int((Double(v) / a).rounded()))] }
            canvas.pixels[i] = Pixel(un(bytes[i * 4]) * a, un(bytes[i * 4 + 1]) * a, un(bytes[i * 4 + 2]) * a, a)
        }
        return canvas
    }

    /// `other` over `self`.
    func composite(_ other: Canvas, tint: V3? = nil) {
        for i in 0..<pixels.count {
            var top = other.pixels[i]
            if let tint { top = Pixel(top.x * tint.x, top.y * tint.y, top.z * tint.z, top.w) }
            pixels[i] = top + pixels[i] * (1 - top.w)
        }
    }
}

enum ArtError: Error, CustomStringConvertible {
    case read(String), write(String), usage(String)

    var description: String {
        switch self {
        case .read(let path): "não consegui ler \(path)"
        case .write(let path): "não consegui gravar \(path)"
        case .usage(let text): text
        }
    }
}
