import Foundation

/// An untinted part of a hair style (hair ties, the antenna's bulb): fixed color, optionally glowing.
struct Accent: Sendable {
    let distance: @Sendable (V3) -> Double
    let color: V3
    var glow = 0.0
}

/// Which way the strands run, for the strand texture and the anisotropic highlight.
enum Flow: Sendable {
    /// Strands radiate from a point on the head (crown, part, hair tie).
    case radial(V3)
    /// Strands run front to back (quiffs).
    case sagittal
    /// No strands (afro, antenna).
    case none

    /// Strand direction at `p` on a surface with normal `n`.
    @inline(__always) func tangent(_ p: V3, _ n: V3) -> V3? {
        switch self {
        case .radial(let center):
            let d = p - center
            let t = d - n * dot(d, n)
            return length(t) > 1e-6 ? normalize(t) : nil
        case .sagittal:
            return normalize(cross(n, V3(1, 0, 0)))
        case .none:
            return nil
        }
    }

    /// A coordinate across the strands (constant along each strand), in turns.
    @inline(__always) func across(_ p: V3) -> Double {
        switch self {
        case .radial(let center):
            let axis = normalize(center)
            let basis = Basis(axis)
            let q = basis.local(p)
            return atan2(q.y, q.x) / (2 * .pi)
        case .sagittal:
            return p.x * 0.5
        case .none:
            return 0
        }
    }

    /// Fine strand texture in 0...1 (shading only).
    @inline(__always) func strands(_ p: V3) -> Double {
        if case .none = self { return 0.5 }
        let u = across(p)
        return 0.6 * noise(V3(u * 70, 0.31, 0.77)) + 0.4 * noise(V3(u * 190, 0.53, 0.11))
    }
}

/// A hair style as distance fields: the hair itself (rendered white, tinted by the app) and its accents.
struct HairStyle: Sendable {
    let id: String
    let label: String
    let hair: @Sendable (V3) -> Double
    var accents: [Accent] = []
    /// Box that contains everything (rays outside it are skipped).
    let lower: V3, upper: V3
    var flow = Flow.radial(V3(0, 1, -0.05))
    /// Strength of the highlight band (glossy straight hair ~0.4, matte coils ~0.1).
    var gloss = 0.32
    /// Step scale for fields that aren't exact distances (displacement, noise).
    var relax = 0.9
    /// The style squeezed under a hat (no bun or crest poking through it), rendered as `<id>-chapeu`.
    var underHat: (@Sendable () -> HairStyle)?
}

/// Ray-marches a hair style over the head (orthographic, looking down -z) into two layers:
/// - `base`: the hair in white-to-gray shading (key light, soft shadows, ambient occlusion, strand texture),
///   multiplied by the hair color in the app;
/// - `shine`: drawn over it untinted: the highlight band along the strands and a rim light on the hair, its
///   accents, and the shadow and occlusion the hair casts on the head (where hair meets the body).
/// The head is a holdout: hair behind it is cut, so the layers fit over any body.
struct HairRenderer: Sendable {
    let style: HairStyle

    private static let hitEpsilon = 0.0006
    /// How much of the strand highlight is kept (1 was the glossy gel look).
    static let satin = 0.35

    func render() -> (base: Canvas, shine: Canvas) {
        let base = Canvas.render { u, v in shade(u, v).base }
        let shine = Canvas.render { u, v in shade(u, v).shine }
        return (base, shine)
    }

    // MARK: Fields

    @inline(__always) private func accents(_ p: V3) -> (Double, Int) {
        var best = Double.infinity, index = -1
        for (i, accent) in style.accents.enumerated() {
            let d = accent.distance(p)
            if d < best { best = d; index = i }
        }
        return (best, index)
    }

    /// Everything that blocks light: hair, accents and the head.
    @inline(__always) private func occluders(_ p: V3) -> Double {
        min(style.hair(p), accents(p).0, Head.distance(p))
    }

    /// What the hair throws on the head: hair and accents only.
    @inline(__always) private func casters(_ p: V3) -> Double {
        min(style.hair(p), accents(p).0)
    }

    // MARK: Marching

    private func march(x: Double, y: Double, stop: Double, _ field: (V3) -> Double) -> V3? {
        guard x >= style.lower.x, x <= style.upper.x, y >= style.lower.y, y <= style.upper.y else { return nil }
        var z = style.upper.z + 0.01
        let floor = max(stop, style.lower.z - 0.01)
        var steps = 0
        while z > floor, steps < 500 {
            let p = V3(x, y, z)
            let d = field(p)
            if d < Self.hitEpsilon { return p }
            z -= max(d * style.relax, Self.hitEpsilon * 0.8)
            steps += 1
        }
        return nil
    }

    private func normal(_ p: V3, _ field: (V3) -> Double) -> V3 {
        let e = 0.0015
        let a = V3(1, -1, -1), b = V3(-1, -1, 1), c = V3(-1, 1, -1), d = V3(1, 1, 1)
        let n = a * field(p + a * e) + b * field(p + b * e) + c * field(p + c * e) + d * field(p + d * e)
        return normalize(n)
    }

    private func softShadow(_ origin: V3, _ direction: V3, k: Double, _ field: (V3) -> Double) -> Double {
        var result = 1.0, t = 0.015
        for _ in 0..<64 {
            let h = field(origin + direction * t)
            result = min(result, k * h / t)
            t += clamp(h, 0.008, 0.12)
            if result < 0.002 || t > 2.5 { break }
        }
        return clamp(result)
    }

    private func occlusion(_ p: V3, _ n: V3, _ field: (V3) -> Double) -> Double {
        var occ = 0.0, weight = 1.0
        for i in 0..<6 {
            let h = 0.012 + 0.045 * Double(i)
            occ += (h - field(p + n * h)) * weight
            weight *= 0.72
        }
        return clamp(1 - 2.2 * occ)
    }

    // MARK: Shading

    private func shade(_ u: Double, _ v: Double) -> (base: Pixel, shine: Pixel) {
        let q = Frame.point(u, v)
        let head = Head.front(q.x, q.y)
        let stop = head?.z ?? -3

        // Base: the hair alone (accents are drawn over it in the shine layer).
        var base = Pixel.zero
        if let p = march(x: q.x, y: q.y, stop: stop, style.hair) {
            let n = normal(p, style.hair)
            let lit = clamp((dot(n, Light.key) + 0.35) / 1.35)
            let shadow = lit > 0 ? softShadow(p + n * 0.004, Light.key, k: 9, occluders) : 0
            let ao = occlusion(p, n, occluders)
            let ambient = (0.6 + 0.4 * n.y) * ao
            let fill = clamp(dot(n, Light.fill)) * 0.2 * ao
            var g = 0.3 * ambient + 0.76 * lit * mix(0.3, 1, shadow) * mix(0.55, 1, ao) + fill
            g *= 0.86 + 0.14 * style.flow.strands(p)
            g = g < 0.85 ? g : 0.85 + 0.15 * (1 - exp(-(g - 0.85) / 0.15))
            base = Pixel(g, g, g, 1)
        }

        // Shine: highlights on the hair, accents, and the hair's shadow on the head.
        var shine = Pixel.zero
        if let p = march(x: q.x, y: q.y, stop: stop, { min(style.hair($0), accents($0).0) }) {
            let (accentDistance, index) = accents(p)
            if index >= 0, accentDistance <= style.hair(p) {
                shine = shadeAccent(style.accents[index], at: p)
            } else {
                shine = highlight(at: p)
            }
        } else if let head {
            let n = Head.normal(head)
            let shadow = softShadow(head + n * 0.004, Light.key, k: 8, casters)
            let ao = occlusion(head, n, casters)
            // Contact: the head darkens right where hair sits on it.
            let contact = 1 - smoothstep(0, 0.1, casters(head))
            let a = clamp((1 - shadow) * 0.5 + (1 - ao) * 0.5 + contact * 0.45) * 0.7
            // A deep violet-black reads better than pure black on saturated bodies.
            shine = Pixel(0.012 * a, 0.006 * a, 0.022 * a, a)
        }
        return (base, shine)
    }

    /// Kajiya–Kay style highlight band across the strands, broken up by the strand texture, plus a soft rim.
    private func highlight(at p: V3) -> Pixel {
        let n = normal(p, style.hair)
        let shadow = softShadow(p + n * 0.004, Light.key, k: 9, occluders)
        let h = normalize(Light.key + Light.view)
        var spec: Double
        if let t = style.flow.tangent(p, n) {
            let shifted = normalize(t - n * 0.12)
            let th = dot(shifted, h)
            let band = pow(max(0, 1 - th * th), 40)
            let broad = pow(max(0, 1 - th * th), 6)
            spec = (band * 0.75 + broad * 0.12) * style.gloss * (0.45 + 0.55 * style.flow.strands(p))
        } else {
            spec = pow(clamp(dot(n, h)), 14) * style.gloss
        }
        spec *= mix(0.15, 1, shadow) * clamp(dot(n, Light.key) + 0.4)
        let rim = pow(1 - clamp(n.z), 3) * clamp(dot(n, Light.rim) + 0.5) * 0.16
        // A third of the old shine, to sit on the satin body: a sheen on the strands, not wet-look hair.
        let a = clamp(spec + rim) * Self.satin
        return Pixel(a, a, a, a)
    }

    private func shadeAccent(_ accent: Accent, at p: V3) -> Pixel {
        let n = normal(p, accent.distance)
        let lit = clamp((dot(n, Light.key) + 0.3) / 1.3)
        let shadow = softShadow(p + n * 0.004, Light.key, k: 10, occluders)
        let ao = occlusion(p, n, occluders)
        let h = normalize(Light.key + Light.view)
        let spec = pow(clamp(dot(n, h)), 48) * 0.45 * shadow
        var color = accent.color * (0.32 * (0.6 + 0.4 * n.y) * ao + 0.8 * lit * mix(0.3, 1, shadow))
        color += accent.color * accent.glow
        color += V3(repeating: spec)
        return Pixel(min(color.x, 1), min(color.y, 1), min(color.z, 1), 1)
    }
}
