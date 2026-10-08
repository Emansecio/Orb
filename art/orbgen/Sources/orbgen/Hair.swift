import Foundation
import simd

// The hair styles. Every style sits on the head: a cap that wraps the skull above a hairline (so nothing floats),
// plus bangs, curls, tails or spikes blended into it. Coordinates: orb x radius 1, y up, z toward the viewer; the
// brows sit at y ≈ 0.38 and the eyes at y ≈ 0.17, so bangs stop around y = 0.45.

// MARK: - Helpers

/// Far-away distance to start unions from (infinity would turn `smin` into NaN).
let far = 1e9

/// Point on the head at azimuth `theta` (0 = front center, + toward image right) and height `y`, pushed out along
/// the surface normal by `lift`.
func scalp(_ theta: Double, _ y: Double, lift: Double = 0) -> V3 {
    let r = Head.radii
    let ny = clamp(y / r.y, -1, 1)
    let ring = (1 - ny * ny).squareRoot()
    let p = V3(r.x * ring * sin(theta), y, r.z * ring * cos(theta))
    return p + Head.normal(p) * lift
}

/// Point on the front of the head at image position (x, y), pushed out by `lift`.
func face(_ x: Double, _ y: Double, lift: Double = 0) -> V3 {
    let p = Head.front(x, y) ?? V3(x, y, 0)
    return p + Head.normal(p) * lift
}

/// Height of a hairline around the head: `front` at the center of the forehead, `temple` around ±50°, `side`
/// at the sides and `back` at the nape.
struct Hairline: Sendable {
    var front: Double, temple: Double, side: Double, back: Double

    @inline(__always) func height(_ theta: Double) -> Double {
        let a = abs(theta)
        if a < 0.9 { return mix(front, temple, smoothstep(0, 0.9, a)) }
        if a < 1.6 { return mix(temple, side, smoothstep(0.9, 1.6, a)) }
        return mix(side, back, smoothstep(1.6, .pi, a))
    }
}

/// Hair wrapping the skull above the hairline height `h`. Hair grows from the scalp, so it is only `edge` thick at
/// the hairline and reaches `thickness` a little above it; `crown` adds volume on top.
@inline(__always) func cap(_ p: V3, hairline h: Double, thickness: Double, edge: Double, crown: Double = 0,
                           soft: Double = 0.03) -> Double {
    let above = p.y - h
    let t = edge + (thickness - edge) * smoothstep(0, 0.25, above) + crown * smoothstep(0.2, 0.95, p.y)
    return smax(Head.distance(p) - t, -above, soft)
}

@inline(__always) func cap(_ p: V3, line: Hairline, thickness: Double, edge: Double, crown: Double = 0,
                           soft: Double = 0.03) -> Double {
    cap(p, hairline: line.height(atan2(p.x, p.z)), thickness: thickness, edge: edge, crown: crown, soft: soft)
}

/// Grooves between bundles of strands running along `flow` (`count` bundles around), faded near where the
/// strands start so they don't pinch into a star.
@inline(__always) func clumps(_ p: V3, flow: Flow, count: Double, depth: Double) -> Double {
    let across = flow.across(p)
    // Warped so the bundles have uneven widths, and grooves of uneven depth (a regular pattern reads as knitting).
    let u = across * count + 1.3 * noise(V3(across * 4, 0.2, 0.4)) + 0.25 * sin(p.y * 7 + across * 9)
    let f = u - floor(u)
    let edge = min(f, 1 - f)
    let strength = 0.45 + 0.55 * noise(V3(floor(u) * 1.7, 0.6, 0.9))
    var fade = 1.0
    if case .radial(let center) = flow { fade = smoothstep(0.08, 0.35, length(p - center)) }
    return fade * depth * strength * ((1 - smoothstep(0, 0.22, edge)) + 0.3 * (1 - sin(.pi * f)))
}

private func union(_ locks: [Lock], _ p: V3, k: Double) -> Double {
    var d = far
    for lock in locks { d = smin(d, lock.distance(p), k) }
    return d
}

/// Hair tie around `axis`: a soft, slightly gathered torus.
private func tie(at center: V3, axis: V3, major: Double, minor: Double) -> @Sendable (V3) -> Double {
    let basis = Basis(axis)
    return { p in
        let q = basis.local(p - center)
        let phi = atan2(q.y, q.x)
        let radial = length(V2(q.x, q.y))
        let puff = minor * (1 + 0.07 * sin(phi * 9))
        return length(V2(radial - major, q.z * 1.15)) - puff
    }
}

/// Soft pink for hair ties (untinted; works with every hair and body color).
private let ribbon = linear(0xFF7AA2)

/// Radius profile for tails: swells after the tie, then tapers to a soft point.
private func swell(_ t: Double) -> Double {
    t < 0.3 ? -0.35 * sin(t / 0.3 * .pi / 2) : -0.35 + 1.35 * pow((t - 0.3) / 0.7, 1.4)
}

// MARK: - Styles

extension HairStyle {
    static let all: [HairStyle] = [
        franja, ondulado, cachos, blackPower, coque, rabo, chiquinhas, topete, espetado, moicano, tufinho, antena,
    ]

    /// Labels in the editor's order (written to options.json with "nenhum" first).
    static var manifest: [(id: String, label: String)] { [("nenhum", "Nenhum")] + all.map { ($0.id, $0.label) } }

    // A bob with blunt, chunky bangs that frames the face.
    static let franja: HairStyle = {
        let line = Hairline(front: 0.47, temple: 0.42, side: -0.3, back: -0.38)
        let flow = Flow.radial(V3(0, 1.0, -0.12))
        return HairStyle(id: "franja", label: "Franja", hair: { p in
            let theta = atan2(p.x, p.z)
            // Notches between the chunks of the bangs, a little irregular.
            let notch = pow(max(0, cos(theta * 12.5 + 0.2)), 5) * (0.05 + 0.03 * noise(V3(theta * 4, 1, 2)))
            let front = 1 - smoothstep(0.7, 0.95, abs(theta))
            let h = line.height(theta) + notch * front
            // The bob flares out toward its ends.
            let flare = 0.075 * smoothstep(0.45, -0.3, p.y) * smoothstep(0.75, 1.25, abs(theta))
            var d = cap(p, hairline: h, thickness: 0.1 + flare, edge: 0.065 + flare * 0.8, crown: 0.06, soft: 0.035)
            d += clumps(p, flow: flow, count: 22, depth: 0.008)
            return d
        }, lower: V3(-1.3, -0.5, -1.3), upper: V3(1.3, 1.2, 1.2), flow: flow, gloss: 0.36, relax: 0.85)
    }()

    // Long waves falling past the face, with a side part and a swept fringe.
    static let ondulado: HairStyle = {
        let line = Hairline(front: 0.64, temple: 0.48, side: 0.1, back: -0.2)
        let flow = Flow.radial(V3(-0.32, 0.92, 0.25))
        let sweep = Lock(face(-0.3, 0.88, lift: 0.05), face(0.0, 0.8, lift: 0.11), face(0.42, 0.64, lift: 0.1),
                         face(0.76, 0.44, lift: 0.04), r0: 0.15, r1: 0.06, segments: 14)
        let short = Lock(face(-0.34, 0.86, lift: 0.04), face(-0.52, 0.78, lift: 0.08), face(-0.7, 0.62, lift: 0.07),
                         face(-0.8, 0.48, lift: 0.03), r0: 0.12, r1: 0.06)
        // Locks framing the face: they come forward over its edges, so the long hair reads as hair, not a hood.
        let framing = [-1.0, 1.0].map { side in
            Lock(scalp(0.95 * side, 0.5, lift: 0.08), scalp(1.12 * side, 0.12, lift: 0.1), scalp(1.05 * side, -0.25, lift: 0.1),
                 scalp(1.18 * side, -0.62, lift: 0.12), r0: 0.12, r1: 0.06, segments: 14)
        }
        return HairStyle(id: "ondulado", label: "Ondulado", hair: { p in
            var d = cap(p, line: line, thickness: 0.085, edge: 0.03, crown: 0.05)
            // The long part: a curtain behind and beside the head, waving toward its ends.
            let flare = 0.16 * smoothstep(0.35, -0.75, p.y)
            let wave = 0.06 * sin(p.y * 9 + 1.2 + 0.6 * sign(p.x)) * smoothstep(0.35, -0.2, p.y)
            var curtain = (length(V2(p.x, (p.z + 0.28) / 0.88)) - (1.06 + flare + wave)) * 0.85
            curtain = smax(curtain, p.y - 0.55, 0.15)
            curtain = smax(curtain, -0.82 - p.y, 0.1)
            curtain = smax(curtain, -max(-p.z + 0.02, abs(p.x) - 0.88), 0.1)
            d = smin(d, curtain, 0.1)
            d = smin(d, smin(sweep.distance(p), short.distance(p), 0.04), 0.05)
            for lock in framing { d = smin(d, lock.distance(p), 0.06) }
            // Side part.
            d += 0.028 * exp(-pow((p.x + 0.33) / 0.03, 2)) * smoothstep(0.6, 0.85, p.y) * smoothstep(-0.2, 0.3, p.z)
            return d + clumps(p, flow: flow, count: 24, depth: 0.01)
        }, lower: V3(-1.45, -1.0, -1.4), upper: V3(1.4, 1.2, 1.2), flow: flow, gloss: 0.4, relax: 0.8)
    }()

    // Big, springy curls all over the top, framing the face at the temples.
    static let cachos: HairStyle = {
        let line = Hairline(front: 0.6, temple: 0.46, side: 0.05, back: -0.25)
        var curls: [(center: V3, radius: Double, basis: Basis, phase: Double)] = []
        var random = Seeded(11)
        let rows: [(y: Double, thetas: [Double], radius: Double)] = [
            (0.99, [0], 0.23),
            (0.86, [-1.05, -0.35, 0.35, 1.05, 1.9, 2.6, -1.9, -2.6, .pi], 0.23),
            (0.68, [-0.5, 0.5, -1.2, 1.2, -1.9, 1.9, -2.6, 2.6, .pi], 0.235),
            (0.42, [-1.0, 1.0, -1.55, 1.55, -2.1, 2.1, -2.7, 2.7], 0.22),
            (0.15, [-1.35, 1.35, -1.85, 1.85, -2.4, 2.4], 0.2),
        ]
        for row in rows {
            for theta in row.thetas {
                let t = theta + random.range(-0.08, 0.08)
                let y = row.y + random.range(-0.025, 0.025)
                let center = scalp(t, y, lift: 0.1)
                curls.append((center, row.radius * random.range(0.92, 1.06), Basis(Head.normal(center)), random.range(0, 6.28)))
            }
        }
        let items = curls
        return HairStyle(id: "cachos", label: "Cachinhos", hair: { p in
            var d = cap(p, line: line, thickness: 0.09, edge: 0.03)
            for curl in items {
                let offset = p - curl.center
                // Skip only curls too far to change the blend (skipping nearer ones would overstate the distance).
                if length(offset) - curl.radius * 1.15 > d + 0.06 { continue }
                let q = curl.basis.local(offset)
                let rho = length(V2(q.x, q.y))
                let phi = atan2(q.y, q.x)
                // One soft spiral groove on the outward face makes each bump read as a curl.
                // Lobes slightly flattened along the head and twisted, so they read as springy curls, not balls.
                let flat = length(V3(q.x, q.y, q.z * 1.12))
                d = smin(d, flat - curl.radius + 0.006 * sin(phi * 2 + curl.phase), 0.06)
            }
            return d
        }, lower: V3(-1.35, -0.2, -1.35), upper: V3(1.35, 1.38, 1.3), flow: .none, gloss: 0.2, relax: 0.8)
    }()

    // A big, soft afro framing the face.
    static let blackPower: HairStyle = {
        let hairline: @Sendable (Double) -> Double = { x in 0.6 - 0.3 * x * x }
        return HairStyle(id: "black-power", label: "Black power", hair: { p in
            var d = sdEllipsoid(p, V3(0, 0.4, -0.24), V3(1.42, 1.18, 1.22))
            // The face shows through an oval a little narrower than the head, so the hair comes forward over its
            // edges (no light gap between hair and face, no hood).
            let oval = length(V2(p.x / 0.86, (p.y + 0.12) / 0.8)) - 1
            let faceRegion = max(max(0.06 - p.z, p.y - hairline(p.x)), oval * 0.8)
            d = smax(d, -faceRegion, 0.12)
            // Soft lumps with a finer, gentler coil (not felt).
            let lumps = noise(p * 3.2) * 0.065 + noise(p * 9 + V3(3, 1, 7)) * 0.014 + noise(p * 20 + V3(7, 5, 1)) * 0.005
            return d + lumps - 0.05
        }, lower: V3(-1.6, -0.9, -1.6), upper: V3(1.6, 1.72, 1.15), flow: .none, gloss: 0.1, relax: 0.6)
    }()

    // Hair pulled up into a twisted bun with a scrunchie.
    static let coque: HairStyle = {
        let line = Hairline(front: 0.66, temple: 0.52, side: 0.15, back: -0.2)
        let bun = V3(0, 1.3, -0.08)
        let flow = Flow.radial(bun)
        let scrunchie = tie(at: V3(0, 1.08, -0.07), axis: V3(0, 1, 0.1), major: 0.2, minor: 0.07)
        return HairStyle(id: "coque", label: "Coque", hair: { p in
            var d = cap(p, line: line, thickness: 0.065, edge: 0.014, crown: 0.03) + clumps(p, flow: flow, count: 20, depth: 0.007)
            let q = p - bun
            let twist = 0.5 + 0.5 * sin(atan2(q.x, q.z) * 2 + q.y * 14)
            let knot = sdEllipsoid(p, bun, V3(0.33, 0.28, 0.32)) + 0.016 * twist
            d = smin(d, smin(knot, sdCapsule(p, V3(0, 1.0, -0.06), V3(0, 1.18, -0.08), 0.15), 0.05), 0.07)
            return d
        }, accents: [Accent(distance: scrunchie, color: ribbon)],
        lower: V3(-1.15, 0, -1.15), upper: V3(1.15, 1.66, 1.15), flow: flow, gloss: 0.34, relax: 0.85,
        underHat: { pulledBack(id: "coque", line: line) })
    }()

    /// Hair pulled back under a hat: just the smooth cap, strands running to the nape.
    private static func pulledBack(id: String, line: Hairline) -> HairStyle {
        let flow = Flow.radial(V3(0, 0.75, -0.75))
        return HairStyle(id: id, label: "", hair: { p in
            cap(p, line: line, thickness: 0.065, edge: 0.014, crown: 0.02) + clumps(p, flow: flow, count: 20, depth: 0.007)
        }, lower: V3(-1.15, 0, -1.15), upper: V3(1.15, 1.2, 1.15), flow: flow, gloss: 0.34, relax: 0.85)
    }

    // A high ponytail swinging out to one side.
    static let rabo: HairStyle = {
        let line = Hairline(front: 0.66, temple: 0.52, side: 0.15, back: -0.2)
        let root = scalp(0.82, 0.84, lift: 0.07)
        let out = normalize(V3(0.8, 0.5, -0.05))
        let flow = Flow.radial(root)
        let tail = [
            Lock(root, root + V3(0.34, 0.34, 0), V3(1.5, 0.52, -0.05), V3(1.38, -0.42, 0), r0: 0.14, r1: 0.03, segments: 18, profile: swell),
            Lock(root, root + V3(0.3, 0.38, 0.06), V3(1.42, 0.6, 0.04), V3(1.44, -0.32, 0.04), r0: 0.11, r1: 0.025, segments: 16, profile: swell),
            Lock(root, root + V3(0.38, 0.26, -0.1), V3(1.58, 0.36, -0.12), V3(1.32, -0.46, -0.04), r0: 0.11, r1: 0.022, segments: 16, profile: swell),
        ]
        let band = tie(at: root + out * 0.05, axis: out, major: 0.12, minor: 0.06)
        return HairStyle(id: "rabo-de-cavalo", label: "Rabo de cavalo", hair: { p in
            let d = cap(p, line: line, thickness: 0.065, edge: 0.014) + clumps(p, flow: flow, count: 20, depth: 0.007)
            return smin(d, union(tail, p, k: 0.05), 0.07)
        }, accents: [Accent(distance: band, color: ribbon)],
        lower: V3(-1.15, -0.7, -1.15), upper: V3(1.85, 1.4, 1.15), flow: flow, gloss: 0.38, relax: 0.85)
    }()

    // Two puffy pigtails with ties and a center part.
    static let chiquinhas: HairStyle = {
        let line = Hairline(front: 0.64, temple: 0.48, side: 0.25, back: -0.1)
        let flow = Flow.radial(V3(0, 1.02, 0.2))
        var locks: [Lock] = []
        var ties: [@Sendable (V3) -> Double] = []
        for s in [-1.0, 1.0] {
            let root = scalp(1.2 * s, 0.68, lift: 0.07)
            let out = normalize(V3(s, 0.25, -0.1))
            locks.append(Lock(root, root + V3(0.32 * s, 0.06, 0), V3(1.46 * s, 0.14, -0.02), V3(1.36 * s, -0.36, 0.02),
                              r0: 0.17, r1: 0.05, segments: 16, profile: swell))
            locks.append(Lock(root, root + V3(0.3 * s, 0.12, 0.06), V3(1.38 * s, 0.22, 0.06), V3(1.44 * s, -0.26, 0.04),
                              r0: 0.12, r1: 0.04, segments: 14, profile: swell))
            ties.append(tie(at: root + out * 0.1, axis: out, major: 0.15, minor: 0.065))
        }
        let all = locks
        return HairStyle(id: "chiquinhas", label: "Maria-chiquinha", hair: { p in
            var d = cap(p, line: line, thickness: 0.07, edge: 0.016) + clumps(p, flow: flow, count: 20, depth: 0.007)
            d += 0.03 * exp(-pow(p.x / 0.03, 2)) * smoothstep(0.5, 0.75, p.y) * smoothstep(-0.4, 0.2, p.z)
            return smin(d, union(all, p, k: 0.05), 0.07)
        }, accents: ties.map { Accent(distance: $0, color: ribbon) },
        lower: V3(-1.8, -0.55, -1.15), upper: V3(1.8, 1.25, 1.15), flow: flow, gloss: 0.38, relax: 0.85)
    }()

    // Short sides and a big quiff leaning to one side, its front curling over like a wave.
    static let topete: HairStyle = {
        let line = Hairline(front: 0.66, temple: 0.55, side: 0.2, back: -0.2)
        let swoosh = Lock(V3(-0.42, 1.12, 0.62), V3(-0.1, 1.42, 0.78), V3(0.48, 1.4, 0.72), V3(0.56, 1.06, 0.72),
                          r0: 0.15, r1: 0.05, segments: 16)
        let flow = Flow.radial(V3(-0.1, 0.62, 0.9))
        let lean = -0.2, c = cos(lean), s = sin(lean)
        return HairStyle(id: "topete", label: "Topete", hair: { p in
            var d = cap(p, line: line, thickness: 0.06, edge: 0.014)
            let q = p - V3(0.1, 1.06, 0.4)
            let tilted = V3(c * q.x - s * q.y, s * q.x + c * q.y, q.z)
            let mass = sdEllipsoid(tilted, .zero, V3(0.6, 0.34, 0.5))
            let back = sdEllipsoid(p, V3(0.0, 0.98, -0.1), V3(0.62, 0.26, 0.55))
            d = smin(d, smin(smin(mass, back, 0.15), swoosh.distance(p), 0.08), 0.1)
            return d + clumps(p, flow: flow, count: 14, depth: 0.008)
        }, lower: V3(-1.15, 0, -1.15), upper: V3(1.15, 1.62, 1.2), flow: flow, gloss: 0.42, relax: 0.85,
        underHat: { pulledBack(id: "topete", line: line) })
    }()

    // Anime-style spikes all around, with a few pointing down over the forehead.
    static let espetado: HairStyle = {
        let line = Hairline(front: 0.62, temple: 0.46, side: 0.05, back: -0.25)
        var spikes: [(V3, V3, Double)] = []
        let crown: [(Double, Double, Double, Double)] = [   // theta, y, length, sweep (toward image right)
            (0.1, 0.96, 0.5, 0.25), (0.75, 0.86, 0.46, 0.4), (-0.6, 0.88, 0.42, 0.15), (1.35, 0.68, 0.42, 0.45),
            (-1.3, 0.7, 0.38, 0.1), (1.9, 0.5, 0.36, 0.45), (-1.9, 0.55, 0.34, 0.2), (2.6, 0.72, 0.38, 0.3),
            (-2.6, 0.72, 0.36, 0.2), (.pi, 0.85, 0.4, 0.3),
        ]
        for (theta, y, length, sweep) in crown {
            let base = scalp(theta, y, lift: 0.02)
            let tip = base + normalize(Head.normal(base) + V3(sweep, 0.3, 0)) * length
            spikes.append((base, tip, 0.18))
        }
        for (x, tipX, tipY) in [(-0.42, -0.58, 0.44), (-0.05, 0.02, 0.4), (0.36, 0.52, 0.45)] {
            spikes.append((face(x * 0.7, 0.9, lift: 0.07), face(tipX, tipY, lift: 0.07), 0.15))
        }
        let all = spikes
        return HairStyle(id: "espetado", label: "Espetado", hair: { p in
            var d = cap(p, line: line, thickness: 0.075, edge: 0.03, crown: 0.03)
            for (base, tip, radius) in all { d = smin(d, sdRoundCone(p, base, tip, radius, 0.012), 0.05) }
            return d
        }, lower: V3(-1.5, -0.2, -1.5), upper: V3(1.5, 1.6, 1.3), flow: .radial(V3(0, 1, 0)), gloss: 0.36)
    }()

    // A strip of hair from the forehead to the nape, standing up in a crest of spikes that fan out a little.
    static let moicano: HairStyle = {
        var spikes: [(V3, V3, Double)] = []
        let crest: [(elevation: Double, length: Double, lean: Double)] = [
            (0.55, 0.42, 0.0), (0.22, 0.6, -0.55), (0.12, 0.62, 0.55), (-0.2, 0.68, -0.15), (-0.45, 0.6, 0.4),
            (-0.75, 0.5, -0.4), (-1.05, 0.4, 0.2),
        ]
        for spike in crest {
            // Along the top meridian: elevation 0 = straight up, + toward the front.
            let base = V3(0, 0.97 * cos(spike.elevation), 0.98 * sin(spike.elevation))
            let tip = base + normalize(Head.normal(base) * 0.6 + V3(spike.lean, 0.75, -0.15)) * spike.length
            spikes.append((base, tip, 0.19))
        }
        let all = spikes
        let line = Hairline(front: 0.6, temple: 0.6, side: 0.6, back: -0.3)
        return HairStyle(id: "moicano", label: "Moicano", hair: { p in
            // A rounded ridge along the top (a head squeezed sideways), not a slab with flat walls.
            var d = smax((Head.distance(V3(p.x * 3, p.y, p.z)) - 0.1) / 3, line.height(atan2(p.x, p.z)) - p.y, 0.12)
            for (base, tip, radius) in all { d = smin(d, sdRoundCone(p, base, tip, radius, 0.03), 0.08) }
            return d
        }, lower: V3(-0.75, 0.3, -1.4), upper: V3(0.75, 1.8, 1.2), flow: .sagittal, gloss: 0.34, relax: 0.8,
        underHat: {
            // Only the strip shows under a hat; the crest is flattened by it.
            HairStyle(id: "moicano", label: "", hair: { p in
                smax((Head.distance(V3(p.x * 3, p.y, p.z)) - 0.1) / 3, line.height(atan2(p.x, p.z)) - p.y, 0.12)
            }, lower: V3(-0.5, 0.3, -1.3), upper: V3(0.5, 1.2, 1.2), flow: .sagittal, gloss: 0.34, relax: 0.8)
        })
    }()

    // A single cartoon curl on top, with a little strand beside it.
    static let tufinho: HairStyle = {
        let locks = [
            Lock(scalp(0, 0.95, lift: -0.02), V3(-0.12, 1.32, 0.14), V3(0.44, 1.5, 0.14), V3(0.34, 1.16, 0.14),
                 r0: 0.09, r1: 0.03, segments: 18),
            Lock(scalp(-0.12, 0.95, lift: -0.02), V3(-0.14, 1.14, 0.1), V3(-0.26, 1.22, 0.1), V3(-0.36, 1.2, 0.1),
                 r0: 0.055, r1: 0.022, segments: 10),
        ]
        return HairStyle(id: "tufinho", label: "Tufinho", hair: { p in
            union(locks, p, k: 0.05)
        }, lower: V3(-0.5, 0.75, -0.3), upper: V3(0.6, 1.62, 0.4), flow: .none, gloss: 0.3)
    }()

    // A springy antenna with a glowing bulb.
    static let antena: HairStyle = {
        let stalk = Lock(scalp(0, 0.96, lift: -0.02), V3(0.0, 1.22, 0.04), V3(0.14, 1.4, 0.04), V3(0.3, 1.44, 0.04),
                         r0: 0.04, r1: 0.024, segments: 14)
        let bulb = V3(0.37, 1.45, 0.04)
        return HairStyle(id: "antena", label: "Antena", hair: { p in
            smin(stalk.distance(p), sdSphere(p, V3(0, 0.96, 0.02), 0.08), 0.04)
        }, accents: [Accent(distance: { sdSphere($0, bulb, 0.095) }, color: linear(0x9FF0FF), glow: 0.55)],
        lower: V3(-0.25, 0.8, -0.3), upper: V3(0.55, 1.62, 0.35), flow: .none, gloss: 0.3)
    }()
}
