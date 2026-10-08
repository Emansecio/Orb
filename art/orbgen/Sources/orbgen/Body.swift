import Foundation

/// One lighting rig for every layer, matching the Blender renders of the other layers: a big soft key light
/// from the top left and front, a weaker cool fill from the right, and a rim/bounce light from below.
enum Light {
    static let key = normalize(V3(-0.55, 0.68, 0.6))
    static let fill = normalize(V3(0.85, -0.05, 0.5))
    static let rim = normalize(V3(0.35, -0.75, -0.2))
    /// Where the glossy reflection of the key comes from: steeper than the key itself, so the highlight sits on
    /// the upper-left shoulder of the orb, clear of the eyes and brows.
    static let gloss = normalize(V3(-0.64, 0.74, -0.18))
    static let view = V3(0, 0, 1)
}

/// The head: an ellipsoid (the Blender orb was scaled 1 × 0.97 high × 0.98 deep).
enum Head {
    static let radii = V3(1, 0.97, 0.98)

    /// Front surface point at (x, y), if inside the silhouette.
    @inline(__always) static func front(_ x: Double, _ y: Double) -> V3? {
        let q = 1 - (x / radii.x) * (x / radii.x) - (y / radii.y) * (y / radii.y)
        guard q > 0 else { return nil }
        return V3(x, y, radii.z * q.squareRoot())
    }

    @inline(__always) static func normal(_ p: V3) -> V3 {
        normalize(p / (radii * radii))
    }

    /// Approximate signed distance (good near the surface, which is where it is used).
    @inline(__always) static func distance(_ p: V3) -> Double {
        let k0 = length(p / radii), k1 = length(p / (radii * radii))
        return k0 * (k0 - 1) / max(k1, 1e-9)
    }
}

/// The gel body: the palette's vertical gradient (glow at the bottom, deep at the top) lit like a soft 3D
/// object: wrapped diffuse from the key light, a core shadow, light scattered out at the bottom, a frosted
/// fresnel rim, a soft window reflection with a small hot spot, and a thin bounce rim along the bottom.
struct BodyShader: Sendable {
    let rim: V3, core: V3, deep: V3, glow: V3
    let light: Bool

    init(_ palette: Palette) {
        rim = linear(palette.rim)
        core = linear(palette.core)
        deep = linear(palette.deep)
        glow = linear(palette.glow)
        light = palette.isLight
    }

    /// The palette's vertical ramp, `h` 0 (bottom) ... 1 (top).
    func ramp(_ h: Double) -> V3 {
        let stops: [(Double, V3)] = [(0, glow), (0.12, mix(glow, core, 0.4)), (0.36, core), (0.7, deep), (1, deep)]
        for i in 1..<stops.count where h <= stops[i].0 {
            let (h0, c0) = stops[i - 1], (h1, c1) = stops[i]
            return mix(c0, c1, smoothstep(h0, h1, h))
        }
        return deep
    }

    func shade(_ u: Double, _ v: Double) -> Pixel {
        let q = Frame.point(u, v)
        guard let p = Head.front(q.x, q.y) else { return .zero }
        let n = Head.normal(p)
        let facing = n.z
        let edge = 1 - facing
        let h = clamp((p.y / Head.radii.y + 1) / 2)

        var color = ramp(h)

        // Diffuse key light, wrapped so the shadow side stays soft (gel lets light through).
        let key = dot(n, Light.key)
        let wrapped = clamp((key + 0.5) / 1.5)
        color *= 0.84 + 0.34 * wrapped

        // Core shadow: a soft band where the light turns away, faded out where the bottom glows.
        let bottom = smoothstep(-0.15, -0.95, p.y)
        let band = exp(-pow((key + 0.12) / 0.32, 2))
        color *= 1 - (light ? 0.05 : 0.09) * band * (1 - bottom)

        // Light scattered through the gel leaving at the bottom: a brighter glow toward the lower edge.
        color = mix(color, glow * 1.15, 0.55 * bottom * smoothstep(0.1, 0.75, edge))

        // Frosted fresnel rim (the Orb's signature edge), stronger on the lit side and at the bottom.
        // Soft like the original Blender gel's "Facing" ramp, a little narrower so the saturated core (the neon
        // glow) reaches further out: ~10 % of the rim color three quarters of the way out, ~55 % at the silhouette.
        let radius = (1 - facing * facing).squareRoot()
        let frost = pow(smoothstep(0.64, 1, radius), 1.6)
        let side = 0.72 + 0.28 * max(clamp(dot(n, Light.key) + 0.3), bottom)
        color = mix(color, mix(rim, V3(repeating: 1), 0.15), clamp(0.66 * frost * side))

        // Bounce light from below: a thin bright rim along the lower right.
        let bounce = clamp(dot(n, Light.rim)) * pow(edge, 3)
        color += mix(glow, rim, 0.5) * 0.45 * bounce

        // Glossy coat: a soft window reflection of the key light and a small hot spot inside it.
        let r = reflect(-Light.view, n)
        let alignment = dot(r, Light.gloss)
        let window = smoothstep(0.84, 0.97, alignment) * (light ? 0.32 : 0.4)
        let hotspot = pow(clamp(alignment), 300) * 0.75
        let sheen = smoothstep(0.5, 0.9, dot(r, Light.key)) * 0.05
        color += V3(repeating: window + hotspot + sheen)

        // Soft shoulder instead of clipping, so bright highlights go white without hue shifts.
        color = V3(shoulder(color.x), shoulder(color.y), shoulder(color.z))
        return Pixel(color.x, color.y, color.z, 1)
    }

    private func shoulder(_ x: Double) -> Double {
        x < 0.82 ? x : 0.82 + 0.18 * (1 - exp(-(x - 0.82) / 0.18))
    }
}
