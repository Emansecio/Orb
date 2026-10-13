import Testing
import Foundation
import CoreGraphics
@testable import Orb

/// The pieces that keep orbs cheap: the shared frame clock, the visibility check, the frame-rate cap for big
/// orbs and the background decoding of bitmaps.
@MainActor
struct OrbPerformanceTests {
    // MARK: Frame clock

    /// (`#expect` cannot call a mutating method.)
    private func due(_ clock: inout OrbFrameClock, _ time: Double, _ rate: Float) -> Bool {
        clock.isDue(at: time, rate: rate)
    }

    /// Frames an orb of `rate` fps gets from a clock ticking at `tickRate` for `seconds`.
    private func frames(rate: Float, tickRate: Double, seconds: Double) -> Int {
        var clock = OrbFrameClock()
        var count = 0
        for tick in 1...Int(tickRate * seconds) {
            if clock.isDue(at: Double(tick) / tickRate, rate: rate) { count += 1 }
        }
        return count
    }

    /// (The first tick always steps, hence one frame more than rate × seconds.)
    @Test func clockGivesEachOrbItsOwnRate() {
        #expect(frames(rate: 60, tickRate: 60, seconds: 2) == 120)
        #expect(frames(rate: 30, tickRate: 60, seconds: 2) == 61)
        #expect(frames(rate: 20, tickRate: 60, seconds: 2) == 41)
        #expect(frames(rate: 10, tickRate: 60, seconds: 2) == 21)
        // A clock exactly as fast as the orb wants.
        #expect(frames(rate: 10, tickRate: 10, seconds: 2) == 20)
    }

    @Test func clockNeverRunsFasterThanItsTicks() {
        #expect(frames(rate: 60, tickRate: 30, seconds: 2) == 60)
    }

    @Test func clockDoesNotBurstAfterAGap() {
        var clock = OrbFrameClock()
        #expect(due(&clock, 1, 10))
        // The orb was paused for a minute: one frame now, then back to the normal pace.
        #expect(due(&clock, 61, 10))
        #expect(!due(&clock, 61.016, 10))
        #expect(due(&clock, 61.05, 10))
        #expect(!due(&clock, 61.1, 10))
        #expect(due(&clock, 61.15, 10))
    }

    @Test func clockSpeedsUpWhenTheRateRises() {
        var clock = OrbFrameClock()
        #expect(due(&clock, 1, 10))
        #expect(!due(&clock, 1.033, 10))
        clock.rateChanged(to: 30)
        #expect(due(&clock, 1.034, 30))
    }

    @Test func clockIsDueAtOnceAfterAReset() {
        var clock = OrbFrameClock()
        #expect(due(&clock, 5, 10))
        clock.reset()
        #expect(due(&clock, 5.001, 10))
    }

    // MARK: Visibility

    @Test func orbsOutsideTheViewportDoNotAnimate() {
        let viewport = CGRect(x: 0, y: 100, width: 240, height: 300)
        #expect(OrbVisibility.isVisible(orb: CGRect(x: 10, y: 120, width: 30, height: 30), in: viewport, margin: 30))
        // Partly in: still visible.
        #expect(OrbVisibility.isVisible(orb: CGRect(x: 10, y: 390, width: 30, height: 30), in: viewport, margin: 30))
        // Its hat or glow reaches in, though the frame does not.
        #expect(OrbVisibility.isVisible(orb: CGRect(x: 10, y: 410, width: 30, height: 30), in: viewport, margin: 30))
        #expect(!OrbVisibility.isVisible(orb: CGRect(x: 10, y: 600, width: 30, height: 30), in: viewport, margin: 30))
        #expect(OrbVisibility.isVisible(orb: CGRect(x: 10, y: 80, width: 30, height: 30), in: viewport, margin: 30))
        #expect(!OrbVisibility.isVisible(orb: CGRect(x: 10, y: -200, width: 30, height: 30), in: viewport, margin: 30))
    }

    @Test func aScrollViewNotLaidOutYetCountsAsVisible() {
        #expect(OrbVisibility.isVisible(orb: CGRect(x: 0, y: 900, width: 30, height: 30), in: .zero, margin: 30))
    }

    // MARK: Frame rate

    @Test func bigOrbsOnlyReachSixtyWhileLively() {
        #expect(OrbFrameRate.cap(forSize: 96, lively: false) == 30)
        #expect(OrbFrameRate.cap(forSize: 96, lively: true) == 60)
        #expect(OrbFrameRate.cap(forSize: 132, lively: false) == 30)
        #expect(OrbFrameRate.cap(forSize: 30, lively: true) == 30)
        #expect(OrbFrameRate.cap(forSize: 79, lively: true) == 30)
    }

    // MARK: Bitmaps

    @Test func bitmapsLoadInTheBackgroundAndThenAreCached() async {
        // A size no other test uses, so the cache starts cold.
        let layers = [OrbLayer(kind: .eyes, path: "eyes/pontos", tint: nil), OrbLayer(kind: .hair, path: "hair/topete", tint: 0x336699)]
        #expect(OrbImages.cached("eyes/pontos", pixels: 143, tint: nil) == nil)
        #expect(!OrbImages.isCached(layers, pixels: 143))
        await OrbImages.load(layers, pixels: 143)
        #expect(OrbImages.isCached(layers, pixels: 143))
        #expect(OrbImages.cached("hair/topete", pixels: 143, tint: 0x336699)?.width == 143)
    }

    @Test func loadingHandsOverTheBitmapsInOrder() async {
        // The caller keeps them: the cache may drop a bitmap before the rebuild that needs it.
        let ghost = OrbLayer(kind: .eyes, path: "eyes/does-not-exist", tint: nil)
        let hair = OrbLayer(kind: .hair, path: "hair/topete", tint: 0x336699)
        let images = await OrbImages.load([hair, ghost], pixels: 159)
        #expect(images.count == 2)
        #expect(images.first??.width == 159)
        #expect(images.last! == nil)
    }

    @Test func aTintDarkensSoftEdgesAsMuchAsTheRest() throws {
        // A multiply that saw white where the hair is see-through left its edges lighter than the hair.
        let tint: UInt32 = 0x804020
        let plain = try #require(OrbImages.cgImage("hair/topete", pixels: 157, tint: nil))
        let tinted = try #require(OrbImages.cgImage("hair/topete", pixels: 157, tint: tint))
        let (a, b) = (rgba(plain), rgba(tinted))
        let factors = [Int(tint >> 16 & 0xFF), Int(tint >> 8 & 0xFF), Int(tint & 0xFF)]
        var softEdges = 0, wrong = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if a[i + 3] > 0 && a[i + 3] < 255 { softEdges += 1 }
            if b[i + 3] != a[i + 3] { wrong += 1 }
            for c in 0..<3 where abs(Int(b[i + c]) - Int(a[i + c]) * factors[c] / 255) > 1 { wrong += 1 }
        }
        #expect(softEdges > 0)
        #expect(wrong == 0)
    }

    /// The image's premultiplied RGBA bytes.
    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test func glassesMoveWithTheEyes() {
        let glasses = OrbLayer(kind: .accessory, path: "accessories/oculos-redondos", tint: nil)
        let hat = OrbLayer(kind: .accessory, path: "accessories/cartola", tint: nil)
        #expect(glasses.depth == OrbLayer(kind: .eyes, path: "eyes/pontos", tint: nil).depth)
        #expect(!glasses.isLoose)
        #expect(hat.depth < glasses.depth)
        #expect(hat.isLoose)
    }

    @Test func loadingCompletesOnTheMainActor() async {
        await withCheckedContinuation { continuation in
            OrbImages.load([OrbLayer(kind: .eyes, path: "eyes/pontos", tint: nil)], pixels: 147) { _ in
                #expect(Thread.isMainThread)
                continuation.resume()
            }
        }
    }

    @Test func loadingCompletesForMissingFilesToo() async {
        let ghost = OrbLayer(kind: .eyes, path: "eyes/does-not-exist", tint: nil)
        await OrbImages.load([ghost], pixels: 151)
        #expect(OrbImages.cached(ghost.path, pixels: 151, tint: nil) == nil)
    }

    @Test func loadingWhatIsCachedCompletesAtOnce() async {
        let layer = OrbLayer(kind: .eyes, path: "eyes/pontos", tint: nil)
        await OrbImages.load([layer], pixels: 155)
        await OrbImages.load([layer], pixels: 155)
        #expect(OrbImages.isCached([layer], pixels: 155))
    }

    @Test func retintingReusesTheDecodedBitmap() {
        // The color picker passes through many tints of one layer: each is a bitmap of its own, all the right size.
        let colors: [UInt32] = [0xFF0000, 0x00FF00, 0x0000FF]
        let images = colors.map { OrbImages.cgImage("hair/topete", pixels: 159, tint: $0) }
        #expect(images.allSatisfy { $0?.width == 159 && $0?.height == 159 })
        #expect(OrbImages.cached("hair/topete", pixels: 159, tint: 0x00FF00) != nil)
        func pixel(_ image: CGImage?) -> [UInt8] {
            guard let image, let data = image.dataProvider?.data as Data? else { return [] }
            return Array(data)
        }
        #expect(pixel(images[0]) != pixel(images[1]))
    }
}
