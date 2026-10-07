import Foundation
import Testing
@testable import OpenBotMac

struct OrbTests {
    // MARK: Spring

    @Test func criticallyDampedSpringSettlesWithoutOvershoot() {
        var spring = Spring()
        var peak = 0.0
        for _ in 0..<120 {
            spring.step(toward: 1, dt: 1.0 / 60, response: 0.3)
            peak = max(peak, spring.value)
        }
        #expect(peak <= 1.0001)
        #expect(spring.isSettled(at: 1))
    }

    @Test func underdampedSpringOvershootsThenSettles() {
        var spring = Spring()
        var peak = 0.0
        for _ in 0..<240 {
            spring.step(toward: 1, dt: 1.0 / 60, response: 0.3, damping: 0.3)
            peak = max(peak, spring.value)
        }
        #expect(peak > 1.2)
        #expect(spring.isSettled(at: 1, tolerance: 0.01))
    }

    @Test func springIsStableAndFrameRateIndependent() {
        var fast = Spring(), slow = Spring()
        for _ in 0..<60 { fast.step(toward: 1, dt: 1.0 / 60, response: 0.07) }
        for _ in 0..<10 { slow.step(toward: 1, dt: 0.1, response: 0.07) }
        #expect(abs(fast.value - 1) < 0.001)
        #expect(abs(slow.value - fast.value) < 0.001)
    }

    // MARK: Blinks

    @Test func blinkClosesQuicklyAndOpensSlowly() {
        #expect(Blinker.closure(0) == 0)
        #expect(Blinker.closure(Blinker.close) == 1)
        #expect(Blinker.closure(Blinker.duration) == 0)
        #expect(Blinker.open > Blinker.close)
        // Monotonic while opening
        var last = 1.0
        for step in 0...20 {
            let value = Blinker.closure(Blinker.close + Blinker.hold + Blinker.open * Double(step) / 20)
            #expect(value <= last + 1e-9)
            last = value
        }
    }

    @Test func blinkIntervalsAreIrregularWithOccasionalDoubles() {
        var rng = SeededRandom(seed: 42)
        var blinker = Blinker(firstAt: 1)
        var starts: [Double] = []
        var wasClosed = false
        for frame in 0..<(600 * 60) {
            let time = Double(frame) / 60
            let closed = blinker.amount(at: time, using: &rng) > 0.5
            if closed && !wasClosed { starts.append(time) }
            wasClosed = closed
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        let doubles = gaps.filter { $0 < 0.5 }.count
        let regular = gaps.filter { $0 >= 0.5 }
        #expect(starts.count > 80 && starts.count < 300)
        #expect(doubles > 0 && doubles < gaps.count / 4)
        #expect(regular.allSatisfy { $0 > 1.9 && $0 < 7.5 })
        #expect((regular.max() ?? 0) - (regular.min() ?? 0) > 2)
    }

    // MARK: Saccades

    @Test func saccadesHoldFixationsNearTheCenter() {
        var rng = SeededRandom(seed: 7)
        var saccades = Saccades(firstAt: 0)
        var jumps: [Double] = []
        for frame in 0..<(120 * 30) {
            let time = Double(frame) / 30
            if saccades.update(at: time, using: &rng) {
                jumps.append(time)
                #expect(hypot(saccades.fixation.x, saccades.fixation.y) <= 0.75)
            }
        }
        let holds = zip(jumps.dropFirst(), jumps).map { $0 - $1 }
        #expect(holds.allSatisfy { $0 >= 0.45 && $0 <= 2.85 })
        #expect(jumps.count > 40)
    }

    // MARK: Frame pacing

    @Test func frameRateFollowsOnScreenSpeed() {
        #expect(OrbFrameRate.rate(forSpeed: 0, cap: 60) == 10)
        #expect(OrbFrameRate.rate(forSpeed: 10, cap: 60) == 15)
        #expect(OrbFrameRate.rate(forSpeed: 1000, cap: 30) == 30)
        #expect(OrbFrameRate.rate(forSpeed: 1000, cap: 60) == 60)
    }

    @Test func vibratingActivitiesKeepAFrameRateFloor() {
        // Typing shakes at ~6 Hz: below 30 fps it would alias into a slow wobble.
        #expect(OrbActivity.typing.minFrameRate >= 30)
        #expect(OrbActivity.error.minFrameRate >= 30)
        #expect(OrbActivity.idle.minFrameRate == OrbFrameRate.steps[0])
    }

    @Test func poseDistanceIsInDevicePixels() {
        var moved = OrbPose()
        #expect(moved.pixelDistance(to: OrbPose(), size: 100, scale: 2) == 0)
        moved.lift = 0.01
        #expect(abs(moved.pixelDistance(to: OrbPose(), size: 100, scale: 2) - 2) < 1e-9)
        var dimmed = OrbPose()
        dimmed.glow = 0.9
        #expect(dimmed.pixelDistance(to: OrbPose(), size: 100, scale: 2) > 0.25)
    }

    // MARK: Activities

    @Test func activityMotionHasNoJumps() {
        for activity in OrbActivity.allCases {
            var last = activity.motion(at: 0)
            for step in 1...10_000 {
                let motion = activity.motion(at: Double(step) / 1000)
                #expect(abs(motion.lift - last.lift) < 0.002, "\(activity) lift")
                #expect(abs(motion.squash - last.squash) < 0.005, "\(activity) squash")
                #expect(abs(motion.tilt - last.tilt) < 0.05, "\(activity) tilt")
                last = motion
            }
        }
    }

    @Test func bounceBlendsSquashIntoStretch() {
        #expect(abs(OrbActivity.bounce(0, squash: 0.06, stretch: 0.02) - 0.06) < 1e-9)
        #expect(abs(OrbActivity.bounce(0.3, squash: 0.06, stretch: 0.02) + 0.02) < 1e-9)
        #expect(abs(OrbActivity.bounce(1, squash: 0.06, stretch: 0.02) + 0.02) < 1e-9)
    }

    @Test func bodyMotionMixesLinearly() {
        let a = OrbActivity.sleepy.motion(at: 0), b = OrbActivity.idle.motion(at: 0)
        #expect(OrbBodyMotion.mix(a, b, 0) == a)
        #expect(OrbBodyMotion.mix(a, b, 1) == b)
        #expect(abs(OrbBodyMotion.mix(a, b, 0.5).tilt - (a.tilt + b.tilt) / 2) < 1e-9)
    }

    // MARK: Images

    @Test func layerBitmapsUseTheSmallestCoveringBucket() {
        #expect(OrbImages.bucket(for: 118) == 128)
        #expect(OrbImages.bucket(for: 376) == 384)
        #expect(OrbImages.bucket(for: 2000) == 640)
        let image = OrbImages.cgImage("hair/topete", pixels: 118, tint: 0xFF0000)
        #expect(image?.width == 128 && image?.height == 128)
    }

    @Test func looseLayersExcludeEyewear() {
        #expect(OrbLayer(kind: .hair, path: "hair/topete", tint: nil).isLoose)
        #expect(OrbLayer(kind: .accessory, path: "accessories/cartola", tint: nil).isLoose)
        #expect(!OrbLayer(kind: .accessory, path: "accessories/oculos-redondos", tint: nil).isLoose)
        #expect(!OrbLayer(kind: .eyes, path: "eyes/pilulas", tint: nil).isLoose)
    }
}

// Test-only helpers.

extension Spring {
    func isSettled(at target: Double, tolerance: Double = 0.001) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 10
    }
}

/// Seeded generator (SplitMix64) so blink/saccade schedules are reproducible.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
