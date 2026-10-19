import AppKit
import SwiftUI

/// The app icon, drawn by the app itself (`Orb --render-icon out.png [pixels]`, used by scripts/bundle.sh): the brand
/// Orb on a graphite tile, circled by a tilted ring, on the standard macOS icon grid. The tile is ours on purpose: since
/// macOS 26 the system puts any icon that is not this rounded square in a grey one. Pure CoreGraphics, flat colors,
/// drawn straight at the final size (nothing is scaled down afterwards).
///
/// The only gradient is along the ring: its front half (over the Orb) is white and its back half (behind it) a dimmer
/// white, and at both ends one turns into the other gradually instead of at a seam. The ring gets heavier as the icon
/// gets smaller, so it still shows in the Dock; at 16 px it would be a scratch across the face, and the Orb is drawn
/// alone, bigger, with bigger eyes. The face is the brand's pill eyes, no smile.
@MainActor
enum AppIcon {
    /// The macOS icon grid on a 1024 canvas: a tile of 824 with a 100 px margin, and continuous corners.
    static let canvas: CGFloat = 1024
    static let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4
    static let center = CGPoint(x: 512, y: 512)
    /// The Orb inside its ring, and alone (16 px), where it takes more of the tile.
    static let diameter: CGFloat = 500
    static let smallDiameter: CGFloat = 600
    static let smallCenter = CGPoint(x: 512, y: 516)
    /// At this size or below, the Orb is drawn without its ring.
    static let smallVariantLimit = 16

    /// The ring: an ellipse around the Orb's center, tilted up to the right.
    enum Ring {
        static let radii = CGSize(width: 350, height: 98)
        static let tilt: CGFloat = -22 * .pi / 180
        /// Opacity of the back half.
        static let backAlpha: CGFloat = 0.4
        /// Half the height (of the untilted ellipse) of the band around its long axis where front turns into back.
        static let band: CGFloat = 98 * 0.55

        /// Line width on the 1024 canvas for an icon `pixels` wide: about 1 px or more on screen at every size.
        static func width(pixels: Int) -> CGFloat {
            switch pixels {
            case 256...: 16
            case 128...: 22
            case 64...: 30
            default: 38
            }
        }
    }

    enum Colors {
        static let tile: UInt32 = 0x121216
        static let orb: UInt32 = 0x4A3AF0
        static let face: UInt32 = 0xFFFFFF
        static let ring: UInt32 = 0xFFFFFF
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

        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: tile).cgPath
        let d = small ? smallDiameter : diameter
        let center = small ? smallCenter : center
        let orb = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let ringWidth = Ring.width(pixels: pixels)

        drawShadows(ctx, tile: squircle, scale: k)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        ctx.setFillColor(color(Colors.tile))
        ctx.fill(tile)
        if !small { drawRing(ctx, space: space, around: center, width: ringWidth, front: false) }
        ctx.setFillColor(color(Colors.orb))
        ctx.fillEllipse(in: orb)
        drawEyes(ctx, orb: orb, scale: small ? (pixels <= 16 ? 1.25 : 1.1) : 1)
        if !small { drawRing(ctx, space: space, around: center, width: ringWidth, front: true) }
        ctx.restoreGState()
        // No hairline along the edge: macOS 26+ draws its own light rim on every icon, and a line of ours under it
        // made that rim brighter than on the other icons in the Dock.
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
            ctx.setFillColor(color(Colors.tile))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// One half of the ring: the back one (drawn before the Orb) or the front one (after it). In the ring's own frame
    /// (centered, untilted) the back is the half above the long axis; the stroke fades from the front's white to the
    /// back's alpha across `Ring.band`, the same ramp for both halves, so they meet at the ends without a seam.
    private static func drawRing(_ ctx: CGContext, space: CGColorSpace, around center: CGPoint, width: CGFloat, front: Bool) {
        let rx = Ring.radii.width, ry = Ring.radii.height
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: Ring.tilt)
        let reach = rx + width
        ctx.clip(to: CGRect(x: -reach, y: front ? 0 : -reach, width: reach * 2, height: reach))
        ctx.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let fade = CGGradient(colorsSpace: space, colors: [color(Colors.ring), color(Colors.ring, Ring.backAlpha)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: Ring.band), end: CGPoint(x: 0, y: -Ring.band),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// The pill eyes, a little above the Orb's middle; `scale` makes them bigger for the small sizes.
    private static func drawEyes(_ ctx: CGContext, orb: CGRect, scale: CGFloat) {
        let d = orb.width
        let width = d * 0.075 * scale, height = d * 0.165 * scale
        let eyeY = orb.midY - d * 0.07
        ctx.setFillColor(color(Colors.face))
        for side in [-1.0, 1.0] as [CGFloat] {
            let rect = CGRect(x: orb.midX + side * d * 0.155 - width / 2, y: eyeY - height / 2, width: width, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            ctx.fillPath()
        }
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}
