import CoreGraphics

/// Gradient map for the body shapes: their images are greyscale plush renders and the palette gives them color. Each
/// pixel's luminance picks a color from a 256-entry table built from the palette's [rim, core, deep, glow] hexes.
enum OrbRecolor {
    /// One stop of the gradient: at `luminance` the color is `deep`, `core` and `rim` blended by these weights in linear
    /// light (they add up to less than 1 to darken). Tuned by eye against the renders; change the numbers here only.
    struct Stop {
        let luminance: Double
        var deep = 0.0, core = 0.0, rim = 0.0
    }

    /// The renders' fur sits between about 0.39 (2nd percentile) and 0.82 (98th), with the middle at 0.54: the
    /// middle sits between deep and core and only the lit side reaches core and a little rim, matching the circle's
    /// bodies (darker than a plain luminance match: the circle's fur is mostly in shade).
    static let stops: [Stop] = [
        Stop(luminance: 0, deep: 0.3),
        Stop(luminance: 0.38, deep: 0.8),
        Stop(luminance: 0.54, deep: 0.45, core: 0.55),
        Stop(luminance: 0.72, core: 1),
        Stop(luminance: 0.9, core: 0.7, rim: 0.3),
        Stop(luminance: 1, core: 0.4, rim: 0.6)
    ]

    /// 256 sRGB colors (r, g, b), one per 8-bit luminance.
    static func lut(for palette: OrbPalette, stops: [Stop] = stops) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let linear = { (hex: UInt32) -> [Double] in
            [16, 8, 0].map { shift in
                let c = Double((hex >> UInt32(shift)) & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
        }
        let rim = linear(palette.hexes[0]), core = linear(palette.hexes[1]), deep = linear(palette.hexes[2])
        let encode = { (c: Double) -> UInt8 in
            let v = min(1, max(0, c))
            return UInt8((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
        }
        return (0..<256).map { index in
            let l = Double(index) / 255
            let upper = stops.firstIndex { $0.luminance >= l } ?? stops.count - 1
            let high = stops[upper], low = stops[max(0, upper - 1)]
            let span = high.luminance - low.luminance
            let t = span > 0 ? min(1, max(0, (l - low.luminance) / span)) : 1
            let mix = { (a: Double, b: Double) in a + (b - a) * t }
            let (wd, wc, wr) = (mix(low.deep, high.deep), mix(low.core, high.core), mix(low.rim, high.rim))
            return (encode(deep[0] * wd + core[0] * wc + rim[0] * wr),
                    encode(deep[1] * wd + core[1] * wc + rim[1] * wr),
                    encode(deep[2] * wd + core[2] * wc + rim[2] * wr))
        }
    }

    /// `image` (premultiplied RGBA, as `OrbImages` decodes) with every pixel's luminance mapped through the palette's
    /// table; alpha is kept. Colors are unpremultiplied before the lookup and premultiplied again after.
    static func apply(to image: CGImage, palette: OrbPalette) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let lut = lut(for: palette)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            var p = pixels + y * context.bytesPerRow
            for _ in 0..<width {
                let a = Int(p[3])
                if a == 0 {
                    p[0] = 0; p[1] = 0; p[2] = 0
                } else {
                    // Straight-alpha channels, then the luminance in 0...255 (integer Rec. 709 weights).
                    let r = min(255, Int(p[0]) * 255 / a), g = min(255, Int(p[1]) * 255 / a), b = min(255, Int(p[2]) * 255 / a)
                    let color = lut[(r * 54 + g * 183 + b * 19) >> 8]
                    p[0] = UInt8((Int(color.r) * a + 127) / 255)
                    p[1] = UInt8((Int(color.g) * a + 127) / 255)
                    p[2] = UInt8((Int(color.b) * a + 127) / 255)
                }
                p += 4
            }
        }
        return context.makeImage()
    }
}
