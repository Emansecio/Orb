import Foundation
import simd

/// Model space: orb of x radius 1 centered at the origin, x right, y up, z toward the viewer (orthographic camera).
typealias V3 = SIMD3<Double>
typealias V2 = SIMD2<Double>

@inline(__always) func dot(_ a: V3, _ b: V3) -> Double { simd_dot(a, b) }
@inline(__always) func length(_ a: V3) -> Double { simd_length(a) }
@inline(__always) func length(_ a: V2) -> Double { simd_length(a) }
@inline(__always) func normalize(_ a: V3) -> V3 { simd_normalize(a) }
@inline(__always) func cross(_ a: V3, _ b: V3) -> V3 { simd_cross(a, b) }
@inline(__always) func reflect(_ i: V3, _ n: V3) -> V3 { i - 2 * dot(n, i) * n }

@inline(__always) func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
@inline(__always) func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * t }
@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}

/// Polynomial smooth minimum (blends two distance fields with a fillet of size `k`).
@inline(__always) func smin(_ a: Double, _ b: Double, _ k: Double) -> Double {
    guard k > 0 else { return min(a, b) }
    let h = clamp(0.5 + 0.5 * (b - a) / k)
    return mix(b, a, h) - k * h * (1 - h)
}

@inline(__always) func smax(_ a: Double, _ b: Double, _ k: Double) -> Double { -smin(-a, -b, k) }

/// sRGB hex → linear RGB.
func linear(_ hex: UInt32) -> V3 {
    func channel(_ c: UInt32) -> Double {
        let v = Double(c & 0xFF) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return V3(channel(hex >> 16), channel(hex >> 8), channel(hex))
}

func srgb(_ v: Double) -> Double {
    let c = clamp(v)
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
}

func luminance(_ c: V3) -> Double { dot(c, V3(0.2126, 0.7152, 0.0722)) }

// MARK: - Noise (deterministic, for hair texture)

@inline(__always) private func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ z &* 83_492_791))
    h = (h ^ (h >> 33)) &* 0xFF51AFD7ED558CCD
    h = (h ^ (h >> 33)) &* 0xC4CEB9FE1A85EC53
    h ^= h >> 33
    return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
}

/// Smooth value noise in 0...1.
func noise(_ p: V3) -> Double {
    let i = V3(floor(p.x), floor(p.y), floor(p.z))
    let f = p - i
    let u = f * f * (V3(repeating: 3) - 2 * f)
    let x = Int(i.x), y = Int(i.y), z = Int(i.z)
    func corner(_ dx: Int, _ dy: Int, _ dz: Int) -> Double { hash(x + dx, y + dy, z + dz) }
    let x00 = mix(corner(0, 0, 0), corner(1, 0, 0), u.x), x10 = mix(corner(0, 1, 0), corner(1, 1, 0), u.x)
    let x01 = mix(corner(0, 0, 1), corner(1, 0, 1), u.x), x11 = mix(corner(0, 1, 1), corner(1, 1, 1), u.x)
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z)
}

/// Deterministic pseudo-random sequence (for placing curls and strands).
struct Seeded {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
}
