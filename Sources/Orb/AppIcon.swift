import AppKit
import SwiftUI
import simd

/// The app icon, drawn by the app itself (`Orb --render-icon out.png [pixels]`, used by scripts/bundle.sh): the brand
/// Orb, as big as the tile allows, on pearl glass, on the standard macOS icon grid. The tile is ours on purpose: since
/// macOS 26 the system puts any icon that is not this rounded square in a grey one. Pure CoreGraphics, drawn straight at
/// the final size (nothing is scaled down afterwards), and the gel body comes from `GelShader`, a port of the shader
/// that made the art in Resources/Orbs/body, so it is as sharp as the Orbs in the app at any size.
///
/// The face is the brand's default one (pill eyes and a smile, no glasses): the icon stands for the product, not for
/// Atlas, and glasses turn into noise below 64 px. Up to 64 px a simpler variant is drawn: bigger Orb and face, no
/// floor light.
@MainActor
enum AppIcon {
    /// The macOS icon grid on a 1024 canvas: a tile of 824 with a 100 px margin, and continuous corners.
    static let canvas: CGFloat = 1024
    static let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4
    /// The Orb fills the tile but for a margin that keeps its frosted rim off the corners, and room for its light below.
    static let diameter: CGFloat = 690
    static let center = CGPoint(x: 512, y: 494)
    /// Up to 64 px: a bigger Orb, centered.
    static let smallDiameter: CGFloat = 760
    /// At this size or below, the small variant is drawn.
    static let smallVariantLimit = 64

    enum Colors {
        /// The pearl glass, top to bottom (locations 0, 0.55, 1): white into a faint lavender, light enough to read as
        /// white, tinted enough that the tile holds on a white window.
        static let pearl: [UInt32] = [0xFFFFFF, 0xF4F2FF, 0xE6E3FA]
        static let pearlStops: [CGFloat] = [0, 0.55, 1]
        /// The Orb's light tinting the glass around it (opacity at the center of the ramp).
        static let aura: UInt32 = 0x6E5CFF
        static let auraAlpha: CGFloat = 0.20
        /// The light that leaves through the bottom of the gel and pools on the glass (the palette's glow).
        static let floorAlpha: CGFloat = 0.55
        static let contact: UInt32 = 0x2A1E8C
        static let contactAlpha: CGFloat = 0.38
        /// Inks of the face (the palette's deep, darkened) and the eye's inner gradient.
        static let faceShadow: UInt32 = 0x1A0E80
        static let eyeBottom: UInt32 = 0xE6E2FF
    }

    /// Writes the icon as a PNG, `pixels` wide and high.
    static func render(to url: URL, pixels: Int = 1024) {
        let image = image(pixels: pixels)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The icon in an sRGB, 8-bit, premultiplied bitmap of `pixels` × `pixels`; transparent outside the tile and its shadow.
    static func image(pixels: Int) -> CGImage {
        let pixels = max(pixels, 1)
        let small = pixels <= smallVariantLimit
        let k = CGFloat(pixels) / canvas
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: k, y: k)
        // The design is in 1024 units with y down.
        ctx.translateBy(x: 0, y: canvas)
        ctx.scaleBy(x: 1, y: -1)

        let hexes = OrbCatalog.shared.palette("indigo").hexes
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: tile).cgPath
        let d = small ? smallDiameter : diameter
        let center = small ? CGPoint(x: 512, y: 512) : center

        drawShadows(ctx, tile: squircle, scale: k)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        drawBackground(ctx, space: space, center: center, diameter: d, glow: hexes[3], withFloor: !small)
        ctx.restoreGState()

        let orb = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        drawBody(ctx, hexes: hexes, in: orb, scale: k)
        drawFace(ctx, space: space, orb: orb, small: small, pixels: pixels, scale: k)
        drawEdge(ctx, space: space, tile: squircle)
        return ctx.makeImage()!
    }

    // MARK: Layers

    /// The standard macOS drop shadow, in two passes, filled with the tile's own color.
    private static func drawShadows(_ ctx: CGContext, tile: CGPath, scale k: CGFloat) {
        for (dy, blur, alpha) in [(12.0, 28.0, 0.24), (2.0, 4.0, 0.14)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            // Core Graphics shadows live in device space, unaffected by the transform: scale them by hand, and note that
            // the bitmap's y goes up, so a shadow that falls (y down in the design) has a negative offset.
            ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: color(0x000000, alpha))
            ctx.addPath(tile)
            ctx.setFillColor(color(Colors.pearl[2]))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Pearl gradient, the Orb's light around it, the glow and contact under it (clipped to the tile by the caller).
    private static func drawBackground(_ ctx: CGContext, space: CGColorSpace, center: CGPoint, diameter d: CGFloat, glow: UInt32,
                                       withFloor: Bool) {
        let pearl = CGGradient(colorsSpace: space, colors: Colors.pearl.map { color($0) } as CFArray, locations: Colors.pearlStops)!
        ctx.drawLinearGradient(pearl, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])

        let aura = CGGradient(colorsSpace: space,
                              colors: [color(Colors.aura, Colors.auraAlpha), color(Colors.aura, Colors.auraAlpha * 0.3), color(Colors.aura, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
        ctx.drawRadialGradient(aura, startCenter: center, startRadius: d * 0.3, endCenter: center, endRadius: d * 0.85, options: [])

        guard withFloor else { return }
        // The pool of cool light under the Orb, what comes out of the bottom of the gel, and the contact shadow in it.
        let pools: [(dy: CGFloat, rx: CGFloat, ry: CGFloat, hex: UInt32, alpha: CGFloat)] = [
            (0.52, 0.5, 0.09, glow, Colors.floorAlpha),
            (0.49, 0.3, 0.045, Colors.contact, Colors.contactAlpha),
        ]
        for pool in pools {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y + d * pool.dy)
            ctx.scaleBy(x: 1, y: pool.ry / pool.rx)
            let ramp = CGGradient(colorsSpace: space,
                                  colors: [color(pool.hex, pool.alpha), color(pool.hex, pool.alpha * 0.35), color(pool.hex, 0)] as CFArray,
                                  locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(ramp, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: d * pool.rx, options: [])
            ctx.restoreGState()
        }
    }

    /// The gel, rendered at the exact pixel size it lands on.
    private static func drawBody(_ ctx: CGContext, hexes: [UInt32], in rect: CGRect, scale k: CGFloat) {
        let side = max(Int((rect.width * k).rounded()), 8)
        let body = GelShader(hexes: hexes, light: OrbCatalog.shared.palette("indigo").isLight).image(diameter: side)
        ctx.saveGState()
        // The context is y-down: flip the image back around the rect.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(body, in: rect)
        ctx.restoreGState()
    }

    /// Pill eyes and a smile, in the proportions measured from eyes/pilulas.png and mouth/sorriso.png.
    private static func drawFace(_ ctx: CGContext, space: CGColorSpace, orb: CGRect, small: Bool, pixels: Int, scale k: CGFloat) {
        let d = orb.width
        let eyeScale: CGFloat = small ? 1.3 : 1
        let width = d * 0.081 * eyeScale, height = d * 0.15 * eyeScale
        let eyeY = orb.minY + d * 0.42
        let spread = d * 0.151 * (small ? 1.12 : 1)
        let eyes = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(Colors.eyeBottom)] as CFArray, locations: [0.4, 1])!
        for side in [-1.0, 1.0] as [CGFloat] {
            let rect = CGRect(x: orb.midX + side * spread - width / 2, y: eyeY - height / 2, width: width, height: height)
            let pill = CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.008 * k), blur: d * 0.012 * k, color: color(Colors.faceShadow, 0.45))
            ctx.addPath(pill)
            ctx.setFillColor(color(0xFFFFFF))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(pill)
            ctx.clip()
            ctx.drawLinearGradient(eyes, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            ctx.restoreGState()
        }

        // No smile at 16 px: it would be a smudge.
        guard !(small && pixels <= 16) else { return }
        let mouth = d * 0.15 * (small ? 1.15 : 1)
        let y = orb.minY + d * 0.585
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: orb.midX - mouth / 2, y: y - mouth * 0.12))
        smile.addQuadCurve(to: CGPoint(x: orb.midX + mouth / 2, y: y - mouth * 0.12), control: CGPoint(x: orb.midX, y: y + mouth * 0.42))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.006 * k), blur: d * 0.01 * k, color: color(Colors.faceShadow, 0.4))
        ctx.addPath(smile)
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setLineWidth(d * (small ? 0.045 : 0.032))
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The glass edge of the tile, on top of everything, inside the tile: bright at the top, fading toward the bottom.
    private static func drawEdge(_ ctx: CGContext, space: CGColorSpace, tile squircle: CGPath) {
        ctx.saveGState()
        // Clipped to the tile first, then to the stroke: only the inner half of the line is drawn.
        ctx.addPath(squircle)
        ctx.clip()
        ctx.addPath(squircle)
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let edge = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0.25)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
        ctx.restoreGState()
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

/// The gel body of the Orb, shaded per pixel on the CPU. Keep it equal to `BodyShader` in art/orbgen/Sources/orbgen/Body.swift
/// (same lights, same head, same maths): the icon's Orb must look like the Orbs in the app. `AppIconTests` compares it to the
/// art in Resources/Orbs/body.
struct GelShader: Sendable {
    typealias V3 = SIMD3<Double>

    let rim: V3, core: V3, deep: V3, glow: V3
    /// The light palettes (Pérola, Algodão-doce...) get a softer core shadow and window, as in `BodyShader`.
    let light: Bool

    /// - Parameters:
    ///   - hexes: the palette's rim, core, deep and glow colors.
    ///   - light: whether the palette is one of the light ones.
    init(hexes: [UInt32], light: Bool = false) {
        self.light = light
        rim = Self.linear(hexes[0])
        core = Self.linear(hexes[1])
        deep = Self.linear(hexes[2])
        glow = Self.linear(hexes[3])
    }

    private enum Light {
        static let key = normalize(V3(-0.55, 0.68, 0.6))
        static let rim = normalize(V3(0.35, -0.75, -0.2))
        static let gloss = normalize(V3(-0.64, 0.74, -0.18))
        static let view = V3(0, 0, 1)
    }

    /// The head: an ellipsoid (1 wide, 0.97 high, 0.98 deep).
    private static let radii = V3(1, 0.97, 0.98)

    /// The palette's vertical ramp, `h` 0 (bottom) ... 1 (top).
    func ramp(_ h: Double) -> V3 {
        let stops: [(Double, V3)] = [(0, glow), (0.12, Self.mix(glow, core, 0.4)), (0.36, core), (0.7, deep), (1, deep)]
        for i in 1..<stops.count where h <= stops[i].0 {
            let (h0, c0) = stops[i - 1], (h1, c1) = stops[i]
            return Self.mix(c0, c1, Self.smoothstep(h0, h1, h))
        }
        return deep
    }

    /// Whether model-space (x right, y up, the x radius is 1) is inside the silhouette.
    func contains(_ x: Double, _ y: Double) -> Bool {
        1 - (x / Self.radii.x) * (x / Self.radii.x) - (y / Self.radii.y) * (y / Self.radii.y) > 0
    }

    /// Linear color at model-space (x, y), nil outside the silhouette.
    func shade(_ x: Double, _ y: Double) -> V3? {
        let q = 1 - (x / Self.radii.x) * (x / Self.radii.x) - (y / Self.radii.y) * (y / Self.radii.y)
        guard q > 0 else { return nil }
        let p = V3(x, y, Self.radii.z * q.squareRoot())
        let n = normalize(p / (Self.radii * Self.radii))
        let facing = n.z
        let edge = 1 - facing
        let h = Self.clamp((p.y / Self.radii.y + 1) / 2)

        var color = ramp(h)

        // Diffuse key light, wrapped so the shadow side stays soft.
        let key = dot(n, Light.key)
        color *= 0.84 + 0.34 * Self.clamp((key + 0.5) / 1.5)

        // Core shadow, faded out where the bottom glows.
        let bottom = Self.smoothstep(-0.15, -0.95, p.y)
        let band = exp(-pow((key + 0.12) / 0.32, 2))
        color *= 1 - (light ? 0.05 : 0.09) * band * (1 - bottom)

        // Light scattered out of the bottom.
        color = Self.mix(color, glow * 1.15, 0.55 * bottom * Self.smoothstep(0.1, 0.75, edge))

        // Frosted rim.
        let radius = (1 - facing * facing).squareRoot()
        let frost = pow(Self.smoothstep(0.64, 1, radius), 1.6)
        let side = 0.72 + 0.28 * max(Self.clamp(dot(n, Light.key) + 0.3), bottom)
        color = Self.mix(color, Self.mix(rim, V3(repeating: 1), 0.15), Self.clamp(0.66 * frost * side))

        // Bounce from below.
        let bounce = Self.clamp(dot(n, Light.rim)) * pow(edge, 3)
        color += Self.mix(glow, rim, 0.5) * 0.45 * bounce

        // Glossy coat: window reflection, hot spot and a faint sheen.
        let r = -Light.view - n * (2 * dot(n, -Light.view))
        let alignment = dot(r, Light.gloss)
        let reflection = Self.smoothstep(0.84, 0.97, alignment) * (light ? 0.32 : 0.4)
        let hotspot = pow(Self.clamp(alignment), 300) * 0.75
        let sheen = Self.smoothstep(0.5, 0.9, dot(r, Light.key)) * 0.05
        color += V3(repeating: reflection + hotspot + sheen)

        return V3(shoulder(color.x), shoulder(color.y), shoulder(color.z))
    }

    /// Premultiplied sRGB bytes (RGBA, y down) of a `side` × `side` frame in which the orb's x radius is `scale` pixels,
    /// centered at (`center`, `center`). Supersamples `samples`² only where the silhouette cuts a pixel.
    func pixels(side: Int, center: Double, scale: Double, samples: Int = 3) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let total = Double(samples * samples)
        for py in 0..<side {
            for px in 0..<side {
                let x0 = Double(px), y0 = Double(py)
                func model(_ u: Double, _ v: Double) -> (Double, Double) { ((u - center) / scale, (center - v) / scale) }
                let corners = [model(x0, y0), model(x0 + 1, y0), model(x0, y0 + 1), model(x0 + 1, y0 + 1)].map { contains($0.0, $0.1) }
                let inside = corners.filter { $0 }.count
                var sum = V3.zero
                var covered = 0.0
                if inside == 4 {
                    // The ellipse is convex: a pixel with all four corners inside is inside, and one sample is enough.
                    let m = model(x0 + 0.5, y0 + 0.5)
                    guard let c = shade(m.0, m.1) else { continue }
                    sum = c * total
                    covered = total
                } else {
                    for sy in 0..<samples {
                        for sx in 0..<samples {
                            let m = model(x0 + (Double(sx) + 0.5) / Double(samples), y0 + (Double(sy) + 0.5) / Double(samples))
                            if let c = shade(m.0, m.1) { sum += c; covered += 1 }
                        }
                    }
                }
                guard covered > 0 else { continue }
                let alpha = covered / total
                let color = sum / covered
                let i = (py * side + px) * 4
                data[i] = UInt8((Self.srgb(color.x) * alpha * 255).rounded())
                data[i + 1] = UInt8((Self.srgb(color.y) * alpha * 255).rounded())
                data[i + 2] = UInt8((Self.srgb(color.z) * alpha * 255).rounded())
                data[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        return data
    }

    /// The orb filling a square image, `diameter` pixels wide.
    func image(diameter: Int) -> CGImage {
        var data = pixels(side: diameter, center: Double(diameter) / 2, scale: Double(diameter) / 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return data.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: diameter * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    // MARK: Maths

    private func shoulder(_ x: Double) -> Double {
        x < 0.82 ? x : 0.82 + 0.18 * (1 - exp(-(x - 0.82) / 0.18))
    }

    private static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
    private static func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * t }
    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    static func linear(_ hex: UInt32) -> V3 {
        func channel(_ c: UInt32) -> Double {
            let v = Double(c & 0xFF) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return V3(channel(hex >> 16), channel(hex >> 8), channel(hex))
    }

    static func srgb(_ v: Double) -> Double {
        let c = clamp(v)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
