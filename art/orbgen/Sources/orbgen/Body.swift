import Foundation

/// One lighting rig for every layer, matching the Blender renders of the other layers: a big soft key light
/// from the top left and front, a weaker cool fill from the right, and a rim/bounce light from below.
enum Light {
    static let key = normalize(V3(-0.55, 0.68, 0.6))
    static let fill = normalize(V3(0.85, -0.05, 0.5))
    static let rim = normalize(V3(0.35, -0.75, -0.2))
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

/// The satin body: soft-touch vinyl, not glossy gel. The palette's vertical gradient, pulled most of the way to the
/// core color (the base takes the body's color, not the light glow), lit by a broad diffuse key with a defined core
/// shadow, a thin frosted rim, a faint bounce at the lower edge and one wide, low sheen. No window reflection, no
/// hot spot and no light scattered out through the base: that is what made the old gel look like candy.
struct BodyShader: Sendable {
    let rim: V3, core: V3, deep: V3, glow: V3
    let light: Bool

    init(_ palette: Palette) {
        rim = linear(palette.rim)
        core = linear(palette.core)
        deep = linear(palette.deep)
        // The base stays the body's color: only a fifth of the palette's bright glow is left in the ramp.
        glow = mix(linear(palette.glow), linear(palette.core), 0.8)
        light = palette.isLight
    }

    /// The palette's vertical ramp, `h` 0 (bottom) ... 1 (top), at 40 %: the rest is the core color.
    func ramp(_ h: Double) -> V3 {
        let stops: [(Double, V3)] = [(0, glow), (0.12, mix(glow, core, 0.4)), (0.36, core), (0.7, deep), (1, deep)]
        for i in 1..<stops.count where h <= stops[i].0 {
            let (h0, c0) = stops[i - 1], (h1, c1) = stops[i]
            return mix(core, mix(c0, c1, smoothstep(h0, h1, h)), 0.4)
        }
        return mix(core, deep, 0.4)
    }

    func shade(_ u: Double, _ v: Double) -> Pixel {
        let q = Frame.point(u, v)
        guard let p = Head.front(q.x, q.y) else { return .zero }
        let n = Head.normal(p)
        let facing = n.z
        let edge = 1 - facing
        let h = clamp((p.y / Head.radii.y + 1) / 2)

        var color = ramp(h)

        // Diffuse key light, wrapped but with more range than the gel had: the volume comes from here.
        let key = dot(n, Light.key)
        let wrapped = clamp((key + 0.5) / 1.5)
        color *= 0.7 + 0.46 * wrapped

        // Core shadow: a soft band where the light turns away, faded out toward the bottom.
        let bottom = smoothstep(-0.15, -0.95, p.y)
        let band = exp(-pow((key + 0.12) / 0.32, 2))
        color *= 1 - (light ? 0.09 : 0.16) * band * (1 - bottom)

        // A thin frosted rim, a little stronger on the lit side (not along the base).
        let radius = (1 - facing * facing).squareRoot()
        let frost = pow(smoothstep(0.64, 1, radius), 1.6)
        let side = 0.72 + 0.28 * clamp(dot(n, Light.key) + 0.3)
        color = mix(color, mix(rim, V3(repeating: 1), 0.05), clamp(0.22 * frost * side))

        // A faint bounce from below along the lower right edge.
        let bounce = clamp(dot(n, Light.rim)) * pow(edge, 3)
        color += mix(glow, rim, 0.5) * 0.04 * bounce

        // Satin: one broad, low sheen toward the key light instead of a reflection.
        let r = reflect(-Light.view, n)
        color += V3(repeating: smoothstep(0.15, 0.9, dot(r, Light.key)) * 0.09)

        // A tenth less saturated than the palette.
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        color = mix(color, V3(repeating: luma), 0.1)

        // Soft shoulder instead of clipping, so bright areas go white without hue shifts.
        color = V3(shoulder(color.x), shoulder(color.y), shoulder(color.z))
        return Pixel(color.x, color.y, color.z, 1)
    }

    private func shoulder(_ x: Double) -> Double {
        x < 0.82 ? x : 0.82 + 0.18 * (1 - exp(-(x - 0.82) / 0.18))
    }
}
