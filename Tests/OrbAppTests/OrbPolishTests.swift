import Foundation
import CoreGraphics
import Testing
@testable import Orb

/// The pure rules behind how the Orb moves and reacts: the wobble that comes only with a more stirred up face, the pause
/// between two tools, the waiting hops in cycles, joy in three sizes, the error that dies down, the frame rate floors, the
/// three jumps, the hover gate and the selection glance.
struct OrbPolishTests {
    // MARK: The wobble of a change of face

    @Test func onlyAMoreStirredUpFaceWobbles() {
        func wobbles(_ from: OrbActivity, _ to: OrbActivity) -> Bool { to.energy > from.energy }
        #expect(wobbles(.idle, .happy) && wobbles(.idle, .thinking) && wobbles(.thinking, .waiting) && wobbles(.speaking, .error))
        #expect(!wobbles(.happy, .idle) && !wobbles(.error, .idle) && !wobbles(.waiting, .thinking))
        #expect(!wobbles(.thinking, .typing) && !wobbles(.reading, .searching)) // same level: no kick either way
        #expect(OrbActivity.allCases.allSatisfy { $0.energy >= 0 && $0.energy <= 2 })
        #expect(OrbActivity.sleepy.energy == 0 && OrbActivity.idle.energy == 0)
    }

    // MARK: Tools in a row

    @Test func thinkingBetweenTwoToolsWaitsBeforeShowing() {
        var hold = OrbActivityHold()
        // The tool ends: still "typing" for 0.6 s...
        #expect(hold.resolve(wanted: .thinking, shown: .typing, at: 10) == .typing)
        #expect(hold.resolve(wanted: .thinking, shown: .typing, at: 10.5) == .typing)
        // ...and the next tool takes over at once, with nothing carried over.
        #expect(hold.resolve(wanted: .reading, shown: .typing, at: 10.55) == .reading)
        #expect(hold.resolve(wanted: .thinking, shown: .reading, at: 11) == .reading)
        #expect(hold.resolve(wanted: .thinking, shown: .reading, at: 11.59) == .reading)
        // Past the wait it is thinking for real.
        #expect(hold.resolve(wanted: .thinking, shown: .reading, at: 11.61) == .thinking)
        #expect(hold.resolve(wanted: .thinking, shown: .thinking, at: 12) == .thinking)
    }

    @Test func waitingErrorJoyAndSpeechAreNeverHeld() {
        for urgent in [OrbActivity.waiting, .error, .happy, .speaking, .idle, .attentive, .listening] {
            var hold = OrbActivityHold()
            #expect(hold.resolve(wanted: urgent, shown: .typing, at: 1) == urgent)
        }
        // An Orb that is not on screen or is at rest never waits.
        var hold = OrbActivityHold()
        #expect(hold.resolve(wanted: .thinking, shown: .typing, at: 1, applies: false) == .thinking)
        #expect([OrbActivity.typing, .browsing, .reading, .searching].allSatisfy { $0.isTool })
        #expect(![OrbActivity.thinking, .idle, .waiting, .happy].contains { $0.isTool })
    }

    // MARK: Waiting for you

    @Test func waitingHopsThreeTimesThenTwiceEverySevenSeconds() {
        func hops(_ range: Range<Double>) -> Int {
            var count = 0, wasUp = false
            for step in stride(from: range.lowerBound, to: range.upperBound, by: 0.005) {
                let up = OrbWaiting.state(at: step).hop > 0.6
                if up && !wasUp { count += 1 }
                wasUp = up
            }
            return count
        }
        #expect(hops(0..<3) == 3)
        #expect(hops(3..<10) == 2 && hops(10..<17) == 2 && hops(17..<24) == 2)
        // The first hops lose energy; the later ones are small.
        let heights = [0.5, 1.5, 2.5].map { OrbWaiting.state(at: $0).amplitude }
        #expect(heights[0] > heights[1] && heights[1] > heights[2] && heights[2] > OrbWaiting.small)
        #expect(OrbWaiting.state(at: 4).amplitude == OrbWaiting.small)
        // After a minute, 0.6× the height.
        let tired = OrbWaiting.state(at: 70).amplitude, rested = OrbWaiting.state(at: 10).amplitude
        #expect(abs(tired / rested - 0.6) < 1e-9)
        // Between the hops there is only the breathing.
        let quiet = OrbActivity.waiting.motion(at: 14, elapsed: 14) // 4 s into a cycle
        #expect(abs(quiet.lift) < 0.02 && abs(quiet.squash) < 0.02)
    }

    @Test func waitingNeedsFastFramesOnlyWhileItHops() {
        let waiting = OrbActivity.waiting
        #expect(waiting.minFrameRate(elapsed: 0.5) == 30 && waiting.minFrameRate(elapsed: 2.9) == 30)
        // Quiet: breathing at 10 fps.
        for quiet in [5.0, 6, 7, 8.5, 12, 13, 15, 26] {
            #expect(!OrbWaiting.isHopping(at: quiet), "\(quiet)")
        }
        #expect(waiting.minFrameRate(elapsed: 6) == OrbActivity.idle.minFrameRate)
        // A group of hops starts every 7 s after the first 3.
        #expect(waiting.minFrameRate(elapsed: 10.5) == 30 && waiting.minFrameRate(elapsed: 17.5) == 30)
        // Every moment the body hops, the floor is 30.
        for e in stride(from: 0.0, to: 80, by: 0.01) where OrbWaiting.state(at: e).hop > 0.001 {
            #expect(waiting.minFrameRate(elapsed: e) == 30, "\(e)")
        }
    }

    @Test func waitingMotionIsContinuousAcrossTheCycles() {
        let waiting = OrbActivity.waiting
        var last = waiting.motion(at: 0, elapsed: 0)
        for step in 1...80_000 {
            let e = Double(step) / 1000
            let motion = waiting.motion(at: e, elapsed: e)
            #expect(abs(motion.lift - last.lift) < 0.003, "lift at \(e)")
            #expect(abs(motion.squash - last.squash) < 0.005, "squash at \(e)")
            last = motion
        }
    }

    // MARK: Joy in three sizes

    @Test func happinessComesInThreeSizes() {
        func lifts(_ level: OrbCelebration, to end: Double = 4) -> [(t: Double, lift: Double)] {
            stride(from: 0.0, to: end, by: 0.005).map { ($0, OrbActivity.happy.motion(at: $0, elapsed: $0, celebration: level).lift) }
        }
        func peak(_ level: OrbCelebration) -> Double { lifts(level).map(\.lift).max() ?? 0 }
        #expect(abs(peak(.light) - 0.05) < 0.003 && abs(peak(.normal) - 0.08) < 0.004 && abs(peak(.big) - 0.1) < 0.005)
        // The light one hops once; the others keep going until they calm down.
        func hops(_ level: OrbCelebration) -> Int {
            let values = lifts(level).map(\.lift)
            var count = 0, wasUp = false
            for lift in values {
                let up = lift > 0.02
                if up && !wasUp { count += 1 }
                wasUp = up
            }
            return count
        }
        #expect(hops(.light) == 1 && hops(.normal) >= 2 && hops(.big) >= 3)
        // Calm by the end: normal after 0.3 + 1.6 s, big after 0.3 + 2.2 s.
        let calmNormal = lifts(.normal).filter { $0.t > 2.0 }.map { abs($0.lift) }.max() ?? 1
        #expect(calmNormal < 0.025)
        let calmBig = lifts(.big, to: 6).filter { $0.t > 2.6 }.map { abs($0.lift) }.max() ?? 1
        #expect(calmBig < 0.025)
        let bigStillHopping = lifts(.big).filter { $0.t > 1.9 && $0.t < 2.4 }.map { abs($0.lift) }.max() ?? 0
        let normalAtThatTime = lifts(.normal).filter { $0.t > 1.9 && $0.t < 2.4 }.map { abs($0.lift) }.max() ?? 1
        #expect(bigStillHopping > normalAtThatTime)
        // The smile of a click is only a face: no hops.
        #expect((lifts(.smile).map { abs($0.lift) }.max() ?? 1) < 0.02)
        #expect(OrbActivity.happy.motion(at: 1, elapsed: 1, celebration: .smile).squash < 0.02)
        // None of them jumps from one instant to the next, in any temperament.
        for level in OrbCelebration.allCases {
            for temperament in OrbTemperament.allCases {
                let traits = temperament.traits
                var last = OrbActivity.happy.motion(at: 0, elapsed: 0, traits: traits, celebration: level)
                for step in 1...6000 {
                    let t = Double(step) / 1000
                    let motion = OrbActivity.happy.motion(at: t, elapsed: t, traits: traits, celebration: level)
                    #expect(abs(motion.lift - last.lift) < 0.003 && abs(motion.squash - last.squash) < 0.006
                            && abs(motion.tilt - last.tilt) < 0.07, "\(level) \(temperament) at \(t)")
                    last = motion
                }
            }
        }
    }

    @Test func eachJoyNeedsFastFramesOnlyWhileItHops() {
        let happy = OrbActivity.happy
        for level in [OrbCelebration.light, .normal, .big] {
            #expect(happy.minFrameRate(elapsed: 0.5, celebration: level) == 30)
            let hopsEnd = (OrbActivity.happyReady + level.calm) / 0.7
            #expect(happy.minFrameRate(elapsed: hopsEnd - 0.05, celebration: level) == 30)
            #expect(happy.minFrameRate(elapsed: hopsEnd + 0.05, celebration: level) == OrbActivity.idle.minFrameRate)
        }
        #expect(happy.minFrameRate(elapsed: 0.5, celebration: .smile) == OrbActivity.idle.minFrameRate)
        #expect(OrbActivity.happy.minFrameRate(elapsed: .infinity) == OrbActivity.idle.minFrameRate)
    }

    @Test func theBlendRemembersHowBigTheJoyOnScreenIs() {
        let traits = OrbTemperament.Traits()
        var blend = OrbActivityBlend(.idle)
        blend.change(to: .happy, at: 5, body: 5, traits: traits, celebration: .light)
        #expect(blend.shownStyle == .light)
        blend.change(to: .idle, at: 6, body: 6, traits: traits)
        #expect(blend.previousStyle == .light)
        // Crossing from a light joy to idle midway does not jump, whatever the size.
        let eps = 1e-4
        blend.change(to: .happy, at: 10, body: 10, traits: traits, celebration: .normal)
        let before = blend.motion(at: 10.1 - eps, body: 10.1 - eps, traits: traits)
        blend.change(to: .idle, at: 10.1, body: 10.1, traits: traits)
        let after = blend.motion(at: 10.1 + eps, body: 10.1 + eps, traits: traits)
        #expect(abs(after.lift - before.lift) < 0.003 && abs(after.squash - before.squash) < 0.005)
    }

    @Test func anOrbThatAppearsInAReactionHasNothingNaN() {
        // An Orb that shows up in the error state, waiting or happy has been there "forever" (`elapsed` infinite): the
        // layers would get a NaN position and Core Animation raises.
        for activity in OrbActivity.allCases {
            for level in OrbCelebration.allCases {
                for elapsed in [Double.infinity, 1e9, 0] {
                    let m = activity.motion(at: 7.3, elapsed: elapsed, celebration: level)
                    let values = [m.lift, m.squash, m.tilt, m.shake, m.glow]
                    #expect(values.allSatisfy { $0.isFinite }, "\(activity) \(level) \(elapsed)")
                }
            }
        }
        #expect(!OrbWaiting.isHopping(at: .infinity))
        let quiet = OrbWaiting.state(at: .infinity)
        #expect(quiet.hop == 0 && quiet.contact == 0 && quiet.amplitude.isFinite)
        #expect(OrbActivity.waiting.minFrameRate(elapsed: .infinity) == OrbActivity.idle.minFrameRate)
        #expect(OrbActivity.error.minFrameRate(elapsed: .infinity) == OrbActivity.idle.minFrameRate)
    }

    // MARK: The error

    @Test func theErrorShakesNoThenSlumpsStill() {
        let error = OrbActivity.error
        let early = (0..<100).map { error.motion(at: Double($0) / 100, elapsed: Double($0) / 100).shake }
        #expect((early.map(abs).max() ?? 0) > 0.012)
        // The "no" is three shakes a second, dying out in about 1.2 s.
        let crossings = zip(early, early.dropFirst()).filter { $0 * $1 < 0 }.count
        #expect(crossings >= 4 && crossings <= 7)
        let late = (130..<400).map { error.motion(at: Double($0) / 100, elapsed: Double($0) / 100) }
        #expect(late.allSatisfy { abs($0.shake) < 0.002 })
        // Slumped (-3°), its glow still at 0.85.
        #expect(late.allSatisfy { abs($0.tilt + 3) < 0.01 && $0.glow == 0.85 })
        #expect(error.motion(at: 0.2, elapsed: 0.2).glow == 0.85)
        // 20 fps for the shake on small Orbs, 30 on big ones, and 10 once it is still.
        #expect(error.minFrameRate(elapsed: 0.5, size: 30) == 20 && error.minFrameRate(elapsed: 0.5, size: 96) == 30)
        #expect(error.minFrameRate(elapsed: 1.31, size: 30) == 10 && error.minFrameRate(elapsed: 1.31, size: 96) == 10)
    }

    // MARK: Frame rates and glow

    @Test func smallOrbsNeedFewerFramesForTheirSlowMotion() {
        for slow in [OrbActivity.thinking, .reading, .searching, .browsing] {
            #expect(slow.minFrameRate(elapsed: 1, size: 30) == 10, "\(slow)")
            #expect(slow.minFrameRate(elapsed: 1, size: 39.9) == 10)
            #expect(slow.minFrameRate(elapsed: 1, size: 40) == 15 && slow.minFrameRate(elapsed: 1, size: 96) == 15)
        }
        #expect(OrbActivity.typing.minFrameRate(elapsed: 5, size: 30) == 20 && OrbActivity.typing.minFrameRate(elapsed: 5, size: 79) == 20)
        #expect(OrbActivity.typing.minFrameRate(elapsed: 5, size: 80) == 30)
        #expect(OrbActivity.speaking.minFrameRate(elapsed: 5, size: 30) == 20)
        // The terminal's shake is slower now (28 rad/s), and nothing aliases at 20 fps (Nyquist 10 Hz, it is 4.5 Hz).
        let shakes = (0..<1000).map { OrbActivity.typing.motion(at: Double($0) / 1000).shake }
        let zero = zip(shakes, shakes.dropFirst()).filter { $0 * $1 < 0 }.count
        #expect(zero >= 8 && zero <= 10) // about 4.5 Hz over one second
    }

    @Test func theGlowPulseNeverClipsAndBarelyMovesAt10Fps() {
        for activity in [OrbActivity.thinking, .typing, .browsing, .reading, .searching, .waiting, .happy] {
            let glows = stride(from: 0.0, to: 20, by: 0.01).map { activity.motion(at: $0).glow }
            #expect((glows.max() ?? 2) <= 1, "\(activity) clips")
            #expect((glows.min() ?? 0) >= 0.779)
        }
        // A frame at 10 fps changes the glow by less than a quarter of a pixel (the limit below which frames are skipped).
        let glows = stride(from: 0.0, to: 20, by: 0.1).map { OrbActivity.thinking.motion(at: $0).glow }
        let step = zip(glows, glows.dropFirst()).map { abs($1 - $0) }.max() ?? 1
        var a = OrbPose(), b = OrbPose()
        a.glow = 1
        b.glow = 1 - step
        #expect(a.pixelDistance(to: b, size: 96, scale: 2) < 0.25)
    }

    // MARK: Breathing and springs

    @Test func breathingIsCalmerAndSlower() {
        let lifts = stride(from: 0.0, to: 30, by: 0.01).map { OrbActivity.idle.motion(at: $0).lift }
        let squashes = stride(from: 0.0, to: 30, by: 0.01).map { OrbActivity.idle.motion(at: $0).squash }
        #expect(abs((lifts.max() ?? 0) - 0.018) < 0.0003 && abs((squashes.max() ?? 0) - 0.016) < 0.0003)
        // The lift's period is 2π/1.3 ≈ 4.8 s.
        let crossings = zip(lifts, lifts.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(crossings == Int((30 * 1.3 / (2 * .pi)).rounded(.down)))
        #expect(OrbSprings.loose.damping == 0.5 && OrbSprings.swing.damping == 0.5)
    }

    // MARK: Jumps

    @Test func aPromptMakesASmallQuickNodWithNoWobble() {
        let ack = OrbJump.ack
        #expect(ack.duration == 0.35 && ack.kick == 0)
        let peak = stride(from: 0.0, to: 0.35, by: 0.001).map { ack.offset(at: $0, jump: 1).lift }.max() ?? 0
        let crouch = stride(from: 0.0, to: 0.35, by: 0.001).map { ack.offset(at: $0, jump: 1).squash }.max() ?? 0
        #expect(abs(peak - 0.08) < 0.001 && abs(crouch - 0.05) < 0.001)
        #expect(ack.offset(at: 0.35, jump: 1) == (0, 0) && ack.offset(at: -0.1, jump: 1) == (0, 0))
    }

    @Test func aClickKeepsTheBigJumpAndALandingHasNoRise() {
        let play = OrbJump.play
        let peak = stride(from: 0.0, to: 0.55, by: 0.001).map { play.offset(at: $0, jump: 1).lift }.max() ?? 0
        #expect(abs(peak - 0.16) < 0.001 && play.duration == 0.55 && play.kick == 1.6)
        let landing = OrbJump.landing
        #expect(landing.delay == 0.12 && landing.duration == 0.08 && landing.kick == 1)
        let rise = stride(from: 0.0, to: 0.08, by: 0.001).map { landing.offset(at: $0, jump: 1.4).lift }.max() ?? 1
        let squash = stride(from: 0.0, to: 0.08, by: 0.001).map { landing.offset(at: $0, jump: 1).squash }.max() ?? 0
        #expect(rise == 0 && abs(squash - 0.06) < 0.001)
        // The ack is lower than a click, the landing never rises: a sent prompt no longer hops like a click.
        #expect(OrbJump.ack.offset(at: 0.2, jump: 1).lift < play.offset(at: 0.3, jump: 1).lift)
    }

    @Test func theTemperamentScalesTheNodsHeight() {
        #expect(OrbJump.ack.offset(at: 0.21, jump: 1.4).lift > OrbJump.ack.offset(at: 0.21, jump: 0.65).lift)
    }

    // MARK: Hover

    /// (`#expect` cannot call a mutating method.)
    private func speeds(_ gate: inout HoverGate, _ point: CGPoint, _ time: Double) -> Bool {
        gate.shouldSpeedUp(at: point, time: time)
    }

    @Test func hoverSpeedsUpOnlyWhenThePointerReallyMoved() {
        var gate = HoverGate()
        #expect(speeds(&gate, CGPoint(x: 10, y: 10), 0)) // arriving
        #expect(!speeds(&gate, CGPoint(x: 11, y: 10), 0.5)) // 1 pt: a hand resting on the mouse
        #expect(!speeds(&gate, CGPoint(x: 13, y: 10), 0.6)) // exactly 3 pt: not more than 3
        #expect(!speeds(&gate, CGPoint(x: 30, y: 10), 0.05)) // far, but within 100 ms of the last speed-up
        #expect(speeds(&gate, CGPoint(x: 30, y: 10), 0.1))
        #expect(!speeds(&gate, CGPoint(x: 31, y: 11), 0.3))
        #expect(speeds(&gate, CGPoint(x: 31, y: 15), 0.3)) // moved 5 pt since the last speed-up
        gate.reset()
        #expect(speeds(&gate, CGPoint(x: 31, y: 15), 0.31)) // a new arrival counts
    }

    // MARK: The selection glance

    @Test func theGlanceTurnsSlowerLooksLessAndIsIgnoredWhenRepeated() {
        #expect(OrbGlance.look.x == 0.6 && OrbGlance.duration == 0.6 && OrbGlance.minimumGap == 1.2)
        // The turn takes 0.16 s now.
        #expect(OrbGlance.weight(0.08) < 1 && OrbGlance.weight(0.16) == 1 && OrbGlance.weight(0.3) == 1)
        #expect(OrbGlance.blinkAt == 0.16)
        // The eyes still lead the head by 50 ms and the hair trails it by 70 ms.
        #expect(OrbGlance.eyeLead == 0.05 && OrbGlance.hairDelay == 0.07)
    }

    @Test func theSelectionGlanceBlinksWithTheSameFactor() {
        var pose = OrbPose()
        OrbGlance.apply(to: &pose, elapsed: OrbGlance.blinkAt + Blinker.close + 0.01, blinkFactor: 0)
        #expect(pose.blink == 0)
        OrbGlance.apply(to: &pose, elapsed: OrbGlance.blinkAt + Blinker.close + 0.01, blinkFactor: 0.35)
        #expect(abs(pose.blink - 0.35) < 1e-9)
    }
}
