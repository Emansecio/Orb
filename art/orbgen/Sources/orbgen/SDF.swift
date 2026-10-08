import Foundation

// Signed distance primitives (after Inigo Quilez). Distances are in model units (orb x radius = 1).

@inline(__always) func sdSphere(_ p: V3, _ c: V3, _ r: Double) -> Double { length(p - c) - r }

/// Approximate ellipsoid distance (bound, good near the surface).
@inline(__always) func sdEllipsoid(_ p: V3, _ c: V3, _ r: V3) -> Double {
    let q = p - c
    let k0 = length(q / r), k1 = length(q / (r * r))
    return k0 * (k0 - 1) / max(k1, 1e-9)
}

/// Cone with rounded ends between `a` (radius `ra`) and `b` (radius `rb`).
@inline(__always) func sdRoundCone(_ p: V3, _ a: V3, _ b: V3, _ ra: Double, _ rb: Double) -> Double {
    let ba = b - a
    let l2 = dot(ba, ba)
    let rr = ra - rb
    let a2 = l2 - rr * rr
    let il2 = 1 / l2
    let pa = p - a
    let y = dot(pa, ba)
    let z = y - l2
    let xv = pa * l2 - ba * y
    let x2 = dot(xv, xv)
    let y2 = y * y * l2
    let z2 = z * z * l2
    let k = (rr >= 0 ? 1.0 : -1.0) * rr * rr * x2
    if (z >= 0 ? 1.0 : -1.0) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - rb }
    if (y >= 0 ? 1.0 : -1.0) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - ra }
    return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - ra
}

@inline(__always) func sdCapsule(_ p: V3, _ a: V3, _ b: V3, _ r: Double) -> Double {
    let pa = p - a, ba = b - a
    let h = clamp(dot(pa, ba) / dot(ba, ba))
    return length(pa - ba * h) - r
}

/// Torus around `axis` through `c`.
@inline(__always) func sdTorus(_ p: V3, _ c: V3, axis: V3, _ major: Double, _ minor: Double) -> Double {
    let q = p - c
    let h = dot(q, axis)
    let radial = length(q - axis * h)
    return (V2(radial - major, h).squaredLength()).squareRoot() - minor
}

extension V2 {
    @inline(__always) func squaredLength() -> Double { x * x + y * y }
}

/// Orthonormal frame around a direction (for curls and swirls facing outward).
struct Basis: Sendable {
    let u: V3, v: V3, w: V3

    init(_ direction: V3) {
        w = normalize(direction)
        let up = abs(w.y) < 0.95 ? V3(0, 1, 0) : V3(1, 0, 0)
        u = normalize(cross(up, w))
        v = cross(w, u)
    }

    @inline(__always) func local(_ p: V3) -> V3 { V3(dot(p, u), dot(p, v), dot(p, w)) }
}

/// A lock of hair: a tube along a cubic Bézier curve, tapering from `r0` to `r1`, made of round-cone segments.
struct Lock: Sendable {
    let points: [V3]
    let radii: [Double]
    let lower: V3, upper: V3

    init(_ p0: V3, _ p1: V3, _ p2: V3, _ p3: V3, r0: Double, r1: Double, segments: Int = 10,
         profile: (Double) -> Double = { $0 }) {
        var points: [V3] = [], radii: [Double] = []
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let s = 1 - t
            points.append(s * s * s * p0 + 3 * s * s * t * p1 + 3 * s * t * t * p2 + t * t * t * p3)
            radii.append(mix(r0, r1, profile(t)))
        }
        self.points = points
        self.radii = radii
        let pad = max(r0, r1)
        lower = points.reduce(V3(repeating: .infinity)) { simd_min($0, $1) } - V3(repeating: pad)
        upper = points.reduce(V3(repeating: -.infinity)) { simd_max($0, $1) } + V3(repeating: pad)
    }

    /// Distance, or a cheap lower bound when far from the lock's bounding box.
    @inline(__always) func distance(_ p: V3) -> Double {
        let outside = simd_max(simd_max(lower - p, p - upper), .zero)
        let away = length(outside)
        if away > 0.15 { return away }
        var d = Double.infinity
        for i in 0..<(points.count - 1) {
            d = min(d, sdRoundCone(p, points[i], points[i + 1], radii[i], radii[i + 1]))
        }
        return d
    }
}

import simd
