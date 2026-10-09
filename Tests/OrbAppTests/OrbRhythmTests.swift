import Foundation
import Testing
@testable import Orb

/// How often and how an Orb blinks, looks around and gestures: the minimum gap between blinks, the eyes that do not blink,
/// and the table of temperaments with the rhythm it gives (blinks, fixations and gestures per minute).
struct OrbRhythmTests {
    // MARK: Blinks

    @Test func aRequestedBlinkWaitsForTheLastOneToBeOldEnough() {
        var rng = SeededRandom(seed: 5)
        var blinker = Blinker(firstAt: 0)
        blinker.gap = 100...101 // nothing on its own for a long while
        blinker.doubleChance = 0
        // A first blink starts and ends...
        var time = 0.0
        _ = blinker.amount(at: time, using: &rng)
        while blinker.isBlinking {
            time += 0.01
            _ = blinker.amount(at: time, using: &rng)
        }
        let ended = time
        // ...a face change right after it asks for another one: ignored.
        blinker.trigger(at: ended + 0.5)
        #expect(blinker.nextBlink > ended + 50)
        blinker.trigger(at: ended + 1.49)
        #expect(blinker.nextBlink > ended + 50)
        // Once 1.5 s have gone by, it blinks at once.
        blinker.trigger(at: ended + 1.6)
        #expect(blinker.nextBlink == ended + 1.6)
    }

    @Test func aBlinkInProgressIsNeverRestartedNorFollowedTooSoon() {
        var rng = SeededRandom(seed: 6)
        var blinker = Blinker(firstAt: 1)
        _ = blinker.amount(at: 1, using: &rng) // starts blinking
        #expect(blinker.isBlinking)
        let scheduled = blinker.nextBlink
        blinker.trigger(at: 1.05)
        #expect(blinker.nextBlink == scheduled)
        // Right after it, a request waits for the minimum gap.
        var time = 1.0
        while blinker.isBlinking { time += 0.01; _ = blinker.amount(at: time, using: &rng) }
        blinker.trigger(at: time + 0.1)
        #expect(blinker.nextBlink == scheduled)
    }

    @Test func faceChangesInARowBlinkAtMostEveryOneAndAHalfSeconds() {
        var rng = SeededRandom(seed: 8)
        var blinker = Blinker(firstAt: 1000)
        blinker.doubleChance = 0 // (a double blink is the one thing that follows another at once, and is no face change)
        var starts: [Double] = []
        var wasClosed = false
        // A change of face every 0.4 s for a minute.
        for frame in 0..<(60 * 100) {
            let time = Double(frame) / 100
            if frame % 40 == 0 { blinker.trigger(at: time) }
            let closed = blinker.amount(at: time, using: &rng) > 0.5
            if closed && !wasClosed { starts.append(time) }
            wasClosed = closed
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(starts.count > 15 && starts.count < 40)
        #expect(gaps.allSatisfy { $0 >= Blinker.minimumGap + Blinker.duration - 0.05 })
    }

    @Test func closedEyesDoNotBlinkAndDizzyOnesBlinkLess() {
        #expect(Blinker.factor(eyes: "felizes") == 0 && Blinker.factor(eyes: "sono") == 0)
        #expect(Blinker.factor(eyes: "tontos") == 0.35)
        for open in ["pilulas", "pontos", "ovais", "grandes", "fendas", "estrelas", "coracoes", "bravos", "piscadela"] {
            #expect(Blinker.factor(eyes: open) == 1, "\(open)")
        }
        // The activities' own eyes decide: happy, error and sleeping.
        #expect(Blinker.factor(eyes: OrbActivity.happy.eyes ?? "") == 0)
        #expect(Blinker.factor(eyes: OrbActivity.error.eyes ?? "") == 0.35)
        #expect(Blinker.factor(eyes: OrbActivity.sleepy.eyes ?? "") == 0)
    }

    // MARK: Temperaments

    /// Blinks, fixations and gestures per minute of a temperament, from the rules the live Orb uses.
    private func rates(_ temperament: OrbTemperament) -> (blinks: Double, saccades: Double, gestures: Double) {
        let traits = temperament.traits
        var rng = SeededRandom(seed: 17)
        let minutes = 120.0
        var blinker = Blinker(firstAt: 0)
        blinker.gap = traits.blinkGap
        blinker.skew = traits.blinkSkew
        blinker.doubleChance = traits.doubleBlink
        var saccades = Saccades(firstAt: 0)
        saccades.hold = traits.saccadeHold
        saccades.reach = traits.saccadeReach
        var flourishes = Flourishes(firstAt: traits.flourishGap.lowerBound)
        var blinks = 0, fixations = 0, gestures = 0
        var wasClosed = false
        for frame in 0..<Int(minutes * 60 * 30) {
            let time = Double(frame) / 30
            let closed = blinker.amount(at: time, using: &rng) > 0.5
            if closed && !wasClosed { blinks += 1 }
            wasClosed = closed
            if saccades.update(at: time, using: &rng) { fixations += 1 }
            if flourishes.update(at: time, kinds: traits.flourishes, gap: traits.flourishGap, allowed: true, using: &rng) != nil {
                gestures += 1
            }
        }
        return (Double(blinks) / minutes, Double(fixations) / minutes, Double(gestures) / minutes)
    }

    @Test func theTemperamentsFollowTheTable() {
        let balanced = OrbTemperament.equilibrado.traits, lively = OrbTemperament.animado.traits
        let shy = OrbTemperament.timido.traits, curious = OrbTemperament.curioso.traits, calm = OrbTemperament.calmo.traits
        #expect(balanced.blinkGap == 2.5...8 && balanced.blinkSkew == 1.5 && balanced.saccadeHold == 1.25 && balanced.flourishes.isEmpty)
        #expect(lively.blinkGap == 1.8...5.5 && lively.saccadeHold == 0.75 && lively.flourishGap == 18...40 && lively.doubleBlink == 0.15)
        #expect(shy.blinkGap == 2.2...7 && shy.saccadeHold == 1.25 && shy.doubleBlink == 0.25)
        #expect(shy.flourishes == [.bashful] && shy.flourishGap == 45...90)
        #expect(curious.blinkGap == 2...6.5 && curious.saccadeHold == 0.95 && curious.flourishGap == 14...30)
        #expect(calm.blinkGap == 3.5...9 && calm.saccadeHold == 1.8 && calm.flourishGap == 40...90 && calm.flourishes == [.sigh])
        // The wiggle is gentler: 7 degrees.
        let tilt = stride(from: 0.0, to: OrbFlourish.wiggle.duration, by: 0.005).map { abs(OrbFlourish.wiggle.offset(at: $0).tilt) }.max() ?? 0
        #expect(tilt <= 7 && tilt > 6)
    }

    @Test func theRhythmsMatchTheRecommendedFrequencies() {
        // Per minute, with a little room for chance (two hours of each).
        let table: [(OrbTemperament, blinks: ClosedRange<Double>, saccades: ClosedRange<Double>, gestures: ClosedRange<Double>)] = [
            (.equilibrado, 13...17, 26...34, 0...0),
            (.animado, 19...24, 44...56, 1.5...3.5), // one every 18-40 s
            (.timido, 17...21, 22...30, 0.6...1.6),  // one every 45-90 s
            (.curioso, 16...20, 38...50, 2...4.5),   // one every 14-30 s
            (.calmo, 10...13.5, 15...23, 0.6...1.6), // one every 40-90 s
        ]
        for (temperament, blinks, saccades, gestures) in table {
            let measured = rates(temperament)
            #expect(blinks.contains(measured.blinks), "\(temperament) blinks \(measured.blinks)")
            #expect(saccades.contains(measured.saccades), "\(temperament) saccades \(measured.saccades)")
            #expect(gestures.contains(measured.gestures), "\(temperament) gestures \(measured.gestures)")
        }
    }
}
