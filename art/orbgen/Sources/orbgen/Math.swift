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
