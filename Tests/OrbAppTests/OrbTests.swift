import Foundation
import Testing
@testable import Orb

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

    @Test func layerBitmapsMatchTheDrawnPixelSize() {
        #expect(OrbImages.bitmapSide(for: 118) == 118)
        #expect(OrbImages.bitmapSide(for: 517.4) == 517)
        #expect(OrbImages.bitmapSide(for: 2000) == OrbImages.sourceSide)
        let image = OrbImages.cgImage("hair/topete", pixels: 118, tint: 0xFF0000)
        #expect(image?.width == 118 && image?.height == 118)
    }

    @Test func layerImagesSitOnThePixelGrid() {
        // Every size the app uses, at 1x and 2x: whole pixels, centered on the orb at a whole-pixel offset.
        for size: CGFloat in [18, 26, 28, 30, 40, 60, 92, 96, 132] {
            for scale: CGFloat in [1, 2] {
                let side = OrbGeometry.imageSide(for: size, scale: scale)
                let pixels = side * scale, margin = (side - size) / 2 * scale
                #expect(pixels == pixels.rounded(), "\(size)@\(scale)x")
                #expect(margin == margin.rounded(), "\(size)@\(scale)x")
                #expect(abs(side / size - OrbGeometry.imageScale) < 0.06, "\(size)@\(scale)x")
            }
        }
    }

    // MARK: Pausing and shadow

    @Test func poseMixBlendsEverythingAndSwitchesTheMouthHalfway() {
        var talking = OrbPose()
        talking.lift = 0.1
        talking.look = CGPoint(x: 0.6, y: -0.4)
        talking.blink = 1
        talking.viseme = .open
        #expect(OrbPose.mix(talking, .rest, 0) == talking)
        #expect(OrbPose.mix(talking, .rest, 1) == .rest)
        let half = OrbPose.mix(talking, .rest, 0.5)
        #expect(abs(half.lift - 0.05) < 1e-9 && abs(half.look.x - 0.3) < 1e-9 && abs(half.blink - 0.5) < 1e-9)
        #expect(OrbPose.mix(talking, .rest, 0.4).viseme == .open)
        #expect(OrbPose.mix(talking, .rest, 0.6).viseme == nil)
    }

    @Test func groundShadowIsUnchangedAtRestAndFadesInTheAir() {
        let rest = OrbShadow.ground(for: .rest)
        #expect(abs(rest.width - 1.05) < 1e-9 && abs(rest.height - 0.2) < 1e-9 && abs(rest.opacity - 1) < 1e-9)
        var hop = OrbPose()
        hop.lift = 0.12
        let air = OrbShadow.ground(for: hop)
        #expect(air.width < rest.width && air.height < rest.height && air.opacity < 0.7)
        var landing = OrbPose()
        landing.squash = 0.07
        #expect(OrbShadow.ground(for: landing).width > rest.width)
        var dim = OrbPose()
        dim.glow = 0.55
        #expect(abs(OrbShadow.ground(for: dim).opacity - 0.55) < 1e-9)
    }

    @Test func wideGlancesAreFlaggedAndRare() {
        var rng = SeededRandom(seed: 7)
        var saccades = Saccades(firstAt: 0)
        var glances = 0, total = 0
        var time = 0.0
        while total < 2000 {
            if saccades.update(at: time, using: &rng) {
                total += 1
                if saccades.isGlance {
                    glances += 1
                    #expect(hypot(saccades.fixation.x, saccades.fixation.y) > 0.25)
                }
            }
            time += 0.05
        }
        #expect(glances > 200 && glances < 450) // ~15 %
    }

    // MARK: Config

    @Test func configsSavedBeforeTemperamentsStillLoad() throws {
        let json = #"{"color":"rosa","eyes":"ovais","mouth":"sorriso","accessories":["laco"],"accentColor":16732043}"#
        let config = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
        #expect(config.color == "rosa" && config.eyes == "ovais" && config.accessories == ["laco"])
        #expect(config.accentColor == 0xFF4F8B && config.hairColor == nil)
        #expect(config.brows == "nenhuma" && config.temperament == .equilibrado)

        var shy = config
        shy.temperament = .timido
        #expect(try JSONDecoder().decode(OrbConfig.self, from: JSONEncoder().encode(shy)) == shy)
        // (Saved before the designed automatic colors, so it keeps the original ones: see OrbDesignTests.)
        var empty = OrbConfig()
        empty.autoColors = .original
        #expect(try JSONDecoder().decode(OrbConfig.self, from: Data("{}".utf8)) == empty)
    }

    @Test func temperamentIsEditedLikeACategory() {
        var config = OrbConfig()
        config.set(.temperament, "curioso")
        #expect(config.temperament == .curioso && config.value(for: .temperament) == "curioso")
        config.set(.temperament, "???")
        #expect(config.temperament == .curioso)
        #expect(OrbCatalog.shared.options(.temperament).map(\.label) == ["Calmo", "Equilibrado", "Animado", "Tímido", "Curioso"])
    }

    // MARK: Temperaments

    @Test func balancedTemperamentKeepsTheOriginalMotion() {
        let traits = OrbTemperament.equilibrado.traits
        #expect(traits == OrbTemperament.Traits())
        #expect(traits.flourishes.isEmpty && !traits.avertsGaze && traits.lean == 0)
        for activity in OrbActivity.allCases {
            #expect(activity.motion(at: 1.7, traits: traits) == activity.motion(at: 1.7))
        }
    }

    @Test func temperamentsDifferInTheIntendedDirection() {
        let calm = OrbTemperament.calmo.traits, lively = OrbTemperament.animado.traits
        let shy = OrbTemperament.timido.traits, curious = OrbTemperament.curioso.traits
        let balanced = OrbTemperament.equilibrado.traits
        #expect(calm.blinkGap.lowerBound > balanced.blinkGap.lowerBound && lively.blinkGap.upperBound < balanced.blinkGap.upperBound)
        #expect(calm.saccadeHold > 1 && calm.saccadeReach < 1 && lively.saccadeHold < 1 && lively.saccadeReach > 1)
        #expect(calm.springResponse > 1 && lively.springResponse < 1)
        #expect(calm.jump < 1 && shy.jump < 1 && lively.jump > 1)
        #expect(calm.bob < 1 && calm.pace < 1 && lively.bob > 1 && lively.pace > 1)
        #expect(shy.avertsGaze && shy.lean < 0)
        #expect(curious.pointerReach > 1 && curious.pointerInterest > 1 && curious.lean > 0)
        #expect(Set(lively.flourishes) == [.hop, .wiggle] && lively.flourishGap == 8...20)
        #expect(curious.flourishes == [.lookAround])
        #expect(lively.syllableRate > balanced.syllableRate && calm.syllableRate < balanced.syllableRate)
        // Hops scale with the temperament.
        let hop = { (traits: OrbTemperament.Traits) in OrbActivity.happy.motion(at: .pi / 8, traits: traits).lift }
        #expect(hop(lively) > hop(balanced) && hop(balanced) > hop(calm))
    }

    @Test func activityMotionHasNoJumpsInAnyTemperament() {
        for temperament in OrbTemperament.allCases {
            let traits = temperament.traits
            for activity in OrbActivity.allCases {
                // The view advances body time at `pace`, so per-step changes scale with it.
                let step = traits.pace / 1000
                var last = activity.motion(at: 0, traits: traits)
                for index in 1...5_000 {
                    let motion = activity.motion(at: Double(index) * step, traits: traits)
                    #expect(abs(motion.lift - last.lift) < 0.003, "\(temperament) \(activity) lift")
                    #expect(abs(motion.squash - last.squash) < 0.006, "\(temperament) \(activity) squash")
                    #expect(abs(motion.tilt - last.tilt) < 0.07, "\(temperament) \(activity) tilt")
                    last = motion
                }
            }
        }
    }

    @Test func calmBlinksAreSlowerThanLivelyOnes() {
        func gaps(_ temperament: OrbTemperament) -> [Double] {
            var rng = SeededRandom(seed: 3)
            var blinker = Blinker(firstAt: 0)
            blinker.gap = temperament.traits.blinkGap
            blinker.doubleChance = temperament.traits.doubleBlink
            var starts: [Double] = []
            var wasClosed = false
            for frame in 0..<(300 * 60) {
                let time = Double(frame) / 60
                let closed = blinker.amount(at: time, using: &rng) > 0.5
                if closed && !wasClosed { starts.append(time) }
                wasClosed = closed
            }
            return zip(starts.dropFirst(), starts).map { $0 - $1 }.filter { $0 >= 0.5 }
        }
        let calm = gaps(.calmo), lively = gaps(.animado)
        #expect(calm.allSatisfy { $0 > 3.4 && $0 < 9.1 })
        #expect(lively.allSatisfy { $0 > 1.3 && $0 < 4.6 })
        #expect(lively.count > calm.count * 2)
    }

    @Test func saccadeReachAndHoldScale() {
        var rng = SeededRandom(seed: 11)
        var calm = Saccades(firstAt: 0)
        calm.reach = 0.6
        calm.hold = 1.8
        var jumps: [Double] = []
        for frame in 0..<(120 * 30) {
            let time = Double(frame) / 30
            if calm.update(at: time, using: &rng) {
                jumps.append(time)
                #expect(hypot(calm.fixation.x, calm.fixation.y) <= 0.75 * 0.6 + 1e-9)
            }
        }
        let holds = zip(jumps.dropFirst(), jumps).map { $0 - $1 }
        #expect(holds.allSatisfy { $0 >= 0.5 * 1.8 - 0.05 })
        #expect(jumps.count < 60)
    }

    @Test func shyOrbsLookAwayFromACloseAndPeekBack() {
        let pointer = CGPoint(x: 0.5, y: 0.2)
        #expect(OrbTemperament.shyGaze(pointer: pointer, closeness: 0, peeking: false) == pointer)
        let averted = OrbTemperament.shyGaze(pointer: pointer, closeness: 1, peeking: false)
        #expect(averted.x < 0 && averted.y < 0)
        #expect(OrbTemperament.shyGaze(pointer: CGPoint(x: -0.5, y: 0), closeness: 1, peeking: false).x > 0)
        #expect(OrbTemperament.shyGaze(pointer: pointer, closeness: 1, peeking: true) == pointer)
        // Continuous as the pointer crosses in front of the orb.
        let left = OrbTemperament.shyGaze(pointer: CGPoint(x: -0.01, y: 0), closeness: 1, peeking: false)
        let right = OrbTemperament.shyGaze(pointer: CGPoint(x: 0.01, y: 0), closeness: 1, peeking: false)
        #expect(abs(left.x - right.x) < 0.05)
    }

    @Test func glancesAreLongLooksAwayWithBriefPeeks() {
        var rng = SeededRandom(seed: 5)
        var glances = Glances(firstAt: 0)
        var flips: [(time: Double, peeking: Bool)] = []
        for frame in 0..<(60 * 60) {
            let time = Double(frame) / 60
            if glances.update(at: time, using: &rng) { flips.append((time, glances.isPeeking)) }
        }
        for (a, b) in zip(flips, flips.dropFirst()) {
            let length = b.time - a.time
            #expect(a.peeking ? (0.34...0.77).contains(length) : (1.59...3.82).contains(length))
        }
        #expect(flips.count > 20)
    }

    // MARK: Flourishes

    @Test func flourishesStartAndEndAtRest() {
        for flourish in OrbFlourish.allCases {
            #expect(flourish.offset(at: 0) == OrbFlourish.Offset())
            #expect(flourish.offset(at: flourish.duration) == OrbFlourish.Offset())
            let nearStart = flourish.offset(at: 0.002), nearEnd = flourish.offset(at: flourish.duration - 0.002)
            for offset in [nearStart, nearEnd] {
                #expect(abs(offset.lift) < 0.005 && abs(offset.squash) < 0.01 && abs(offset.tilt) < 0.6, "\(flourish)")
                #expect(offset.lookWeight < 0.05 && offset.squint < 0.05, "\(flourish)")
            }
        }
        #expect(OrbFlourish.hop.offset(at: 0.3).lift > 0.08)
        #expect(OrbFlourish.lookAround.offset(at: 0.3 * OrbFlourish.lookAround.duration).look.x < -0.5)
    }

    @Test func spontaneousFlourishesFollowTheTemperament() {
        var rng = SeededRandom(seed: 9)
        let lively = OrbTemperament.animado.traits
        var flourishes = Flourishes(firstAt: 5)
        var starts: [Double] = []
        for frame in 0..<(300 * 30) {
            let time = Double(frame) / 30
            if let kind = flourishes.update(at: time, kinds: lively.flourishes, gap: lively.flourishGap, allowed: true, using: &rng) {
                #expect(lively.flourishes.contains(kind))
                starts.append(time)
            }
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 7.95 && $0 <= 20.05 })
        #expect(starts.count >= 14 && starts.count <= 38)

        // None while busy or for temperaments without them; a requested one always plays.
        var calm = Flourishes(firstAt: 0)
        for frame in 0..<(60 * 30) {
            #expect(calm.update(at: Double(frame) / 30, kinds: [.sigh], gap: 1...2, allowed: false, using: &rng) == nil)
            #expect(calm.update(at: Double(frame) / 30, kinds: [], gap: 1...2, allowed: true, using: &rng) == nil)
        }
        calm.play(.sigh, at: 100)
        #expect(calm.current == .sigh)
        _ = calm.update(at: 100 + OrbFlourish.sigh.duration, kinds: [], gap: 1...2, allowed: true, using: &rng)
        #expect(calm.current == nil)
    }

    // MARK: Speaking

    @Test func speakingKeepsTheBotsFaceAndHasNoBubble() {
        #expect(OrbActivity.speaking.eyes == nil && OrbActivity.speaking.brows == nil && OrbActivity.speaking.bubble == nil)
        #expect(OrbActivity.speaking.mouth(base: "sorriso") == nil)
        #expect(OrbActivity.speaking.label == "Falando")
        #expect(OrbActivity.speaking.minFrameRate >= 20)
    }

    @Test func syllablesHaveASpeechLikeRhythm() {
        func rhythm(_ temperament: OrbTemperament) -> (changes: Double, pauses: Int, rests: Int) {
            var rng = SeededRandom(seed: 21)
            var syllables = Syllables(firstAt: 0)
            var changes = 0, pauses = 0, rests = 0
            var restStart: Double?
            for frame in 0..<(60 * 60) {
                let time = Double(frame) / 60
                guard syllables.update(at: time, rate: temperament.traits.syllableRate, using: &rng) else { continue }
                changes += 1
                if let start = restStart, time - start >= 0.1 { pauses += 1 }
                restStart = syllables.shape == .rest ? time : nil
                if syllables.shape == .rest { rests += 1 }
            }
            return (Double(changes) / 60, pauses, rests)
        }
        for temperament in OrbTemperament.allCases {
            let result = rhythm(temperament)
            #expect(result.changes >= 3.8 && result.changes <= 7, "\(temperament): \(result.changes)/s")
            #expect(result.pauses > 40, "\(temperament) word pauses")
            // The closed mouth only shows in pauses, never as a quick flicker inside a word.
            #expect(result.rests - result.pauses <= 1, "\(temperament) closed flickers")
        }
        #expect(rhythm(.animado).changes > rhythm(.calmo).changes)
    }

    @Test func syllablesRestWhenSpeechStops() {
        var rng = SeededRandom(seed: 1)
        var syllables = Syllables(firstAt: 0)
        for frame in 0..<30 { _ = syllables.update(at: Double(frame) / 60, rate: 5, using: &rng) }
        syllables.rest(at: 1)
        #expect(syllables.shape == .rest)
        #expect(OrbViseme.rest.opening < OrbViseme.wide.opening && OrbViseme.wide.opening < OrbViseme.open.opening)
    }

    @Test func visemesFallBackToRegularMouths() {
        var config = OrbConfig()
        config.mouth = "sorriso"
        let path = config.visemePath(.open)
        if OrbCatalog.shared.visemes.contains("fala-a") {
            #expect(path == "visemes/fala-a")
        } else {
            #expect(path == "mouth/sorrisao")
        }
        config.color = "perola"
        #expect(config.visemePath(.round).hasSuffix("-dark"))
        #expect(config.visemeLayers()?.count == OrbViseme.allCases.count)
        for layer in config.visemeLayers()?.values.map({ $0 }) ?? [] {
            #expect(OrbImages.cgImage(layer.path, pixels: 96, tint: nil) != nil, "\(layer.path)")
        }
        config.mouth = "nenhuma"
        #expect(config.visemeLayers() == nil)
    }

    @Test func mouthShapeSwapsAlwaysDraw() {
        var talking = OrbPose()
        talking.viseme = .open
        #expect(talking.pixelDistance(to: OrbPose(), size: 30, scale: 1) >= 1)
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
