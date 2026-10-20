import Foundation
import Testing
@testable import Orb

@Suite struct ProseWidthTests {
    @Test func atRestTheWidthIsExact() {
        #expect(ProseWidth.layoutWidth(517.5, moving: false) == 517.5)
    }

    @Test func movingStepsDownAndNeverAbove() {
        for width in stride(from: CGFloat(17), through: 900, by: 3.7) {
            let stepped = ProseWidth.layoutWidth(width, moving: true)
            #expect(stepped <= width)
            #expect(width - stepped < ProseWidth.step)
            #expect(stepped.truncatingRemainder(dividingBy: ProseWidth.step) == 0)
        }
        #expect(ProseWidth.layoutWidth(10, moving: true) == 10)
    }

    @Test func motionStartsAfterSeveralFramesOfChangeAndSettlesAfterTheDelay() {
        var motion = ProseWidth.Motion()
        func note(_ width: CGFloat, _ time: TimeInterval) -> Bool { motion.note(width, at: time) }
        #expect(!note(500, 1))
        #expect(!note(500, 1.5))
        #expect(!note(490, 2))              // a change, or several widths in one pass: not yet movement
        #expect(!note(480, 2.0001))
        #expect(!note(470, 2.0002))
        #expect(!note(460, 2.02))           // second frame
        #expect(note(450, 2.04))            // third frame: moving
        #expect(note(450, 2.04 + ProseWidth.settle / 2))
        #expect(!note(450, 2.04 + ProseWidth.settle + 0.01))   // still long enough: exact again
        #expect(!note(440, 3))              // starts over
    }
}
