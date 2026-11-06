import CoreGraphics

/// How much of its box an Orb's look takes: the body fills the box ([0, 1] × [0, 1], in fractions of its size), and
/// some hair and accessories reach past it (an afro, headphones). `fit` shrinks such an Orb just enough for the whole
/// look to sit inside the box, so a small avatar (a sidebar row, the panel's header) does not cover what is next to it.
enum OrbFootprint {
    /// What each hair and accessory image covers at rest, in fractions of the Orb's size (pixels with alpha over
    /// 0.08 in the 1.96× layer image; `OrbFootprintTests` measures the images again and compares).
    static let reach: [String: CGRect] = [
        "hair/antena": rect(0.457, -0.256, 0.668, 0.010),
        "hair/black-power": rect(-0.238, -0.336, 1.238, 0.809),
        "hair/cachos": rect(-0.131, -0.168, 1.140, 0.528),
        "hair/chiquinhas": rect(-0.266, -0.036, 1.266, 0.714),
        "hair/coque": rect(-0.018, -0.318, 1.018, 0.420),
        "hair/espetado": rect(-0.039, -0.266, 1.088, 0.479),
        "hair/franja": rect(-0.097, -0.085, 1.097, 0.662),
        "hair/moicano": rect(0.365, -0.348, 0.638, 0.178),
        "hair/ondulado": rect(-0.158, -0.073, 1.161, 0.926),
        "hair/rabo-de-cavalo": rect(-0.018, -0.100, 1.260, 0.751),
        "hair/topete": rect(-0.011, -0.241, 1.011, 0.396),
        "hair/tufinho": rect(0.301, -0.220, 0.702, 0.022),
        "accessories/fones": rect(-0.082, -0.125, 1.082, 0.598),
        "accessories/monoculo": rect(0.580, 0.332, 0.849, 0.794),
        "accessories/oculos-quadrados": rect(0.185, 0.341, 0.819, 0.531),
        "accessories/oculos-redondos": rect(0.194, 0.335, 0.806, 0.540),
        "accessories/oculos-sol": rect(0.194, 0.335, 0.806, 0.540),
    ]

    /// How far past its box a look may reach before it is shrunk (a few percent on each side reads as the Orb, not
    /// as an overlap).
    static let allowance: CGFloat = 1.06

    private static func rect(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The part of the box the whole look covers (the body's box and every hair or accessory layer it draws).
    static func extent(of config: OrbConfig) -> CGRect {
        config.layers().reduce(CGRect(x: 0, y: 0, width: 1, height: 1)) { union, layer in
            reach[layer.path].map { union.union($0) } ?? union
        }
    }

    /// The scale (at most 1) and where the scaled Orb's center goes, relative to the box's center (fractions of the
    /// box): the look centered in the box when it had to shrink, the Orb untouched when it fits.
    static func fit(_ config: OrbConfig) -> (scale: CGFloat, offset: CGSize) {
        let extent = extent(of: config)
        let scale = min(1, allowance / max(extent.width, extent.height))
        guard scale < 1 else { return (1, .zero) }
        // The scaled look's center lands on the box's center; the Orb's own center follows.
        let offset = CGSize(width: scale * (0.5 - extent.midX), height: scale * (0.5 - extent.midY))
        return (scale, offset)
    }
}
