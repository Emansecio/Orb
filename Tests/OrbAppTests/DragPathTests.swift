import CoreGraphics
import Foundation
import Testing
@testable import Orb

// The points a drag or a pen stroke goes through, and the SVG path data a model can write instead of points. Pure
// geometry: nothing here touches the system.

private func distance(_ one: CGPoint, _ other: CGPoint) -> CGFloat { hypot(one.x - other.x, one.y - other.y) }

// MARK: - The arc of a drag

struct DragArcTests {
    @Test func theArcStartsAndEndsExactlyAtTheGivenPoints() {
        let start = CGPoint(x: 10.3, y: 20.7), end = CGPoint(x: 410.1, y: 220.9)
        let points = DragPath.arc(from: start, to: end)
        #expect(points.first == start && points.last == end)
    }

    @Test func theArcBowsByHalfTheControlOffsetAtMost() {
        // The control point is 12% of the distance to the side, up to 40 pt; the curve bulges half as far as its control.
        for (end, offset) in [(CGPoint(x: 300, y: 0), 36.0), (CGPoint(x: 0, y: 1000), 40.0), (CGPoint(x: 100, y: 100), 0.12 * 141.4213562)] {
            let points = DragPath.arc(from: .zero, to: end)
            let length = hypot(end.x, end.y)
            let sides = points.map { ($0.x * end.y - $0.y * end.x) / length }
            #expect(sides.allSatisfy { abs($0) <= offset / 2 + 1e-9 }, "no point strays further than half the offset from the line")
            #expect(sides.map(abs).max()! > offset / 2 - 1, "and the curve really bows, not a ruler line")
        }
    }

    @Test func theArcAlwaysBowsToTheSameSide() {
        let points = DragPath.arc(from: .zero, to: CGPoint(x: 300, y: 0))
        #expect(points.dropFirst().dropLast().allSatisfy { $0.y > 0 } || points.dropFirst().dropLast().allSatisfy { $0.y < 0 })
    }

    @Test func theArcAdvancesAlongTheLineAtEveryPoint() {
        let end = CGPoint(x: 300, y: 120)
        let length = hypot(end.x, end.y)
        let progress = DragPath.arc(from: .zero, to: end).map { ($0.x * end.x + $0.y * end.y) / length }
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 }, "the pointer never turns back")
    }

    @Test func theNumberOfPointsFollowsTheDistance() {
        // 12 to 60 steps by distance (one per 10 pt), plus the end and the two early points.
        func count(_ length: CGFloat) -> Int { DragPath.arc(from: .zero, to: CGPoint(x: length, y: 0)).count }
        #expect(count(20) == 12 + 3, "short: the least, 12 steps")
        #expect(count(300) == 30 + 3)
        #expect(count(2_000) == 60 + 3, "long: the most, 60 steps")
        #expect(count(5) == 12 + 1, "under 8 pt there are no early points")
    }

    @Test func theMoveIsSlowAtBothEnds() {
        let points = DragPath.arc(from: .zero, to: CGPoint(x: 600, y: 0))
        let steps = zip(points, points.dropFirst()).map { distance($0, $1) }
        let middle = steps[steps.count / 2]
        #expect(steps.prefix(3).allSatisfy { $0 < middle / 3 }, "the first steps are short")
        #expect(steps.suffix(2).allSatisfy { $0 < middle / 3 }, "and so are the last")
    }

    @Test func twoSmallStepsFirstCrossTheDragThresholdAtOnce() {
        for length in [30.0, 200, 1_000] {
            let points = DragPath.arc(from: .zero, to: CGPoint(x: length, y: 0))
            #expect(distance(points[0], points[1]) < 2.5 && distance(points[0], points[2]) < 4.5)
            #expect(distance(points[0], points[2]) > distance(points[0], points[1]))
        }
    }

    @Test func aDragOfNoLengthStaysPutWithoutBadNumbers() {
        let here = CGPoint(x: 42, y: 17)
        let points = DragPath.arc(from: here, to: here)
        #expect(points.count == 13 && points.allSatisfy { distance($0, here) < 1e-9 })
        #expect(points.first == here && points.last == here)
    }

    @Test func aHugeDistanceStillMakesTheLongestArc() {
        let points = DragPath.arc(from: .zero, to: CGPoint(x: 1e300, y: 0))
        #expect(points.count == 60 + 3 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func aPointThatIsNotANumberGivesJustTheTwoEnds() {
        let points = DragPath.arc(from: .zero, to: CGPoint(x: CGFloat.nan, y: 5))
        #expect(points.count == 2)
    }
}

// MARK: - A pen stroke

struct StrokeDensityTests {
    private func points(_ values: [(CGFloat, CGFloat)], pressure: [Double?]? = nil) -> [StrokePoint] {
        values.enumerated().map { StrokePoint(point: CGPoint(x: $1.0, y: $1.1), pressure: pressure?[$0]) }
    }

    @Test func fewerThanTwoPointsComeBackAsTheyWere() {
        #expect(DragPath.stroke([]).isEmpty)
        let one = points([(3, 4)], pressure: [0.5])
        #expect(DragPath.stroke(one) == one)
    }

    @Test func pointsThatFarApartGetPointsBetweenThem() {
        let result = DragPath.stroke(points([(0, 0), (10, 0)]), maxStep: 4)
        #expect(result.count == 4)
        #expect(result.first?.point == .zero && result.last?.point == CGPoint(x: 10, y: 0), "the ends are kept exactly")
        #expect(zip(result, result.dropFirst()).allSatisfy { distance($0.point, $1.point) <= 4 + 1e-9 })
    }

    @Test func pointsAlreadyCloseAreLeftAlone() {
        let close = points([(0, 0), (1, 0), (2, 1), (4, 1)])
        #expect(DragPath.stroke(close, maxStep: 4) == close)
    }

    @Test func theOriginalPointsAreAllKept() {
        let original = points([(0, 0), (30, 0), (30, 50)])
        let result = DragPath.stroke(original, maxStep: 4).map(\.point)
        #expect(original.allSatisfy { result.contains($0.point) })
    }

    @Test func pressureIsInterpolatedBetweenTwoReadings() {
        let result = DragPath.stroke(points([(0, 0), (10, 0)], pressure: [0.2, 0.8]), maxStep: 2.5)
        #expect(result.count == 5)
        let pressures = result.compactMap(\.pressure)
        #expect(pressures.count == 5)
        for (got, want) in zip(pressures, [0.2, 0.35, 0.5, 0.65, 0.8]) { #expect(abs(got - want) < 1e-9) }
    }

    @Test func noPressureStaysNoPressure() {
        let result = DragPath.stroke(points([(0, 0), (20, 0)]), maxStep: 4)
        #expect(result.count > 2 && result.allSatisfy { $0.pressure == nil })
    }

    @Test func aMissingReadingIsNotInventedBetweenPoints() {
        // Between a reading and none there is nothing to interpolate: the new points keep what the one before them had.
        let rising = DragPath.stroke(points([(0, 0), (10, 0)], pressure: [nil, 0.9]), maxStep: 4)
        #expect(rising.dropLast().allSatisfy { $0.pressure == nil } && rising.last?.pressure == 0.9)
        let ending = DragPath.stroke(points([(0, 0), (10, 0)], pressure: [0.4, nil]), maxStep: 4)
        #expect(ending.dropLast().allSatisfy { $0.pressure == 0.4 } && ending.last?.pressure == nil)
    }

    @Test func aLongStrokeIsThinnedEvenlyKeepingBothEnds() {
        // 2,000 points 3 pt apart need no new points, and are too many.
        let long = (0..<2_000).map { StrokePoint(point: CGPoint(x: CGFloat($0) * 3, y: 0), pressure: Double($0) / 2_000) }
        let result = DragPath.stroke(long)
        #expect(result.count == DragPath.maxPoints)
        #expect(result.first == long.first && result.last == long.last)
        let gaps = zip(result, result.dropFirst()).map { $1.point.x - $0.point.x }
        #expect(gaps.min()! > 0, "in order, none twice")
        #expect(gaps.max()! - gaps.min()! <= 3, "spread evenly: neighbours differ by at most one original point")
    }

    @Test func twoPointsFarApartDoNotMakeMillionsOfPoints() {
        let result = DragPath.stroke(points([(0, 0), (1_000_000_000, 0)]))
        #expect(result.count <= DragPath.maxPoints && result.count > 100)
        #expect(result.first?.point == .zero && result.last?.point == CGPoint(x: 1_000_000_000, y: 0))
    }

    @Test func aPointThatIsNotANumberDoesNotCrash() {
        let result = DragPath.stroke(points([(0, 0), (CGFloat.nan, 5), (10, 10)]))
        #expect(result.count == 3, "left as it came: it is for the caller to refuse")
    }

    @Test func aStepOfNothingAddsNothing() {
        let original = points([(0, 0), (10, 0)])
        #expect(DragPath.stroke(original, maxStep: 0) == original)
    }
}

// MARK: - SVG path data

struct SVGPathTests {
    private func parse(_ text: String) throws -> [CGPoint] { try SVGPath.parse(text) }
    private func error(_ text: String) -> String? {
        do { _ = try SVGPath.parse(text); return nil } catch let error as ToolError { return error.message } catch { return "\(error)" }
    }
    private func has(_ points: [CGPoint], near point: CGPoint) -> Bool { points.contains { distance($0, point) < 1e-9 } }

    @Test func absoluteCommandsGoStraightToTheirPoints() throws {
        #expect(try parse("M 10 20 L 30 40") == [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)])
        #expect(try parse("M 0 0 H 10 V 5 H 6 V 0") == [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 6, y: 5), CGPoint(x: 6, y: 0)])
    }

    @Test func relativeCommandsCountFromWhereThePenIs() throws {
        #expect(try parse("m 10 20 l 5 5 l -2 3") == [CGPoint(x: 10, y: 20), CGPoint(x: 15, y: 25), CGPoint(x: 13, y: 28)])
        #expect(try parse("M 0 0 h 10 v 5 h -4 v -5") == [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 6, y: 5), CGPoint(x: 6, y: 0)])
    }

    @Test func pairsAfterAMoveAreLines() throws {
        #expect(try parse("M 0 0 10 0 10 10") == [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        #expect(try parse("m 0 0 10 0 0 10") == [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)], "relative, so each from the one before")
        #expect(try parse("M 0 0 L 5 0 5 5 L 0 5") == [.zero, CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 0, y: 5)])
    }

    @Test func numbersCanBeWrittenTheWaysSVGAllows() throws {
        #expect(try parse("M0,0L1e1,-5.5L+3.5,.5") == [.zero, CGPoint(x: 10, y: -5.5), CGPoint(x: 3.5, y: 0.5)])
        #expect(try parse("M0 0l-1-2") == [.zero, CGPoint(x: -1, y: -2)])
        #expect(try parse("M 1.5.5 L 2 2") == [CGPoint(x: 1.5, y: 0.5), CGPoint(x: 2, y: 2)])
        #expect(try parse("  M\t0\n0  L 4 4  ") == [.zero, CGPoint(x: 4, y: 4)])
    }

    @Test func aCubicIsSampledEndingExactlyAtItsEnd() throws {
        let points = try parse("M 0 0 C 0 40 40 40 40 0")
        // The control polygon is 120 long, so 30 points after the start, and the 15th is the middle of the curve.
        #expect(points.count == 31)
        #expect(points.first == .zero && points.last == CGPoint(x: 40, y: 0))
        #expect(distance(points[15], CGPoint(x: 20, y: 30)) < 1e-9)
    }

    @Test func aShortCurveStillGetsAtLeastEightPoints() throws {
        let points = try parse("M 0 0 C 1 0 2 1 3 1")
        #expect(points.count == 9)
        #expect(points.last == CGPoint(x: 3, y: 1))
    }

    @Test func aQuadraticIsSampledEndingExactlyAtItsEnd() throws {
        let points = try parse("M 0 0 Q 20 20 40 0")
        #expect(points.first == .zero && points.last == CGPoint(x: 40, y: 0))
        #expect(points.map(\.y).max()! > 9.9 && points.map(\.y).max()! <= 10 + 1e-9, "the apex of this curve is at y = 10")
    }

    @Test func relativeCurvesCountFromTheirStart() throws {
        let absolute = try parse("M 10 10 C 10 50 50 50 50 10")
        let relative = try parse("M 10 10 c 0 40 40 40 40 0")
        #expect(absolute == relative)
    }

    @Test func aSmoothCubicMirrorsTheLastControlPoint() throws {
        let points = try parse("M 0 0 C 0 10 10 10 10 0 S 20 -10 20 0")
        // The second curve starts with the control (10, -10), the mirror of (10, 10) through (10, 0); its middle is (15, -7.5).
        #expect(has(points, near: CGPoint(x: 15, y: -7.5)))
        #expect(points.last == CGPoint(x: 20, y: 0))
    }

    @Test func aSmoothCubicAfterAnythingElseStartsFromThePenItself() throws {
        // No cubic before it: the first control point is the pen's position, so this is the curve (0,0) (0,0) (16,-16) (16,0),
        // 10 steps long, whose middle is (8, -6).
        let points = try parse("M 0 0 S 16 -16 16 0")
        #expect(has(points, near: CGPoint(x: 8, y: -6)))
    }

    @Test func aSmoothQuadraticMirrorsTheLastControlPoint() throws {
        let points = try parse("M 0 0 Q 10 10 20 0 T 40 0")
        // Second control (30, -10); the middle of the second curve is (30, -5).
        #expect(has(points, near: CGPoint(x: 30, y: -5)))
        #expect(points.last == CGPoint(x: 40, y: 0))
    }

    @Test func closingGoesBackToTheStart() throws {
        let points = try parse("M 2 3 L 10 3 L 10 10 Z")
        #expect(points == [CGPoint(x: 2, y: 3), CGPoint(x: 10, y: 3), CGPoint(x: 10, y: 10), CGPoint(x: 2, y: 3)])
        #expect(try parse("m 2 3 l 8 0 z").count == 3)
    }

    @Test func closingWhereThePenAlreadyIsAddsNothing() throws {
        #expect(try parse("M 0 0 L 10 0 L 0 0 Z") == [.zero, CGPoint(x: 10, y: 0), .zero])
    }

    @Test func aStrokeCanKeepGoingAfterClosing() throws {
        // After Z the pen is at the start; drawing on from there is still one stroke.
        #expect(try parse("M 0 0 L 10 0 Z L 5 5") == [.zero, CGPoint(x: 10, y: 0), .zero, CGPoint(x: 5, y: 5)])
    }

    @Test func aSecondMoveIsRefused() {
        let message = "Um desenho por chamada: o caminho tem mais de um M."
        #expect(error("M 0 0 L 5 5 M 10 10 L 20 20") == message)
        #expect(error("M 0 0 L 5 5 m 10 10 l 20 20") == message)
        #expect(error("M 0 0 L 5 0 Z M 9 9 L 1 1") == message)
    }

    @Test func arcsAreRefusedWithAWayOut() {
        for path in ["M 0 0 A 5 5 0 0 1 10 0", "M 0 0 a 5 5 0 0 1 10 0", "M 0 0 L 5 5 A 3 3 0 1 1 9 9 Z"] {
            #expect(error(path)?.contains("Arcos") == true && error(path)?.contains("C ou Q") == true, Comment(rawValue: path))
        }
    }

    @Test func textThatIsNotAPathIsRefusedSayingWhatIsWrong() {
        #expect(error("")?.contains("vazio") == true)
        #expect(error("   ")?.contains("vazio") == true)
        #expect(error("L 5 5")?.contains("começar com M") == true)
        #expect(error("hello")?.contains("começar com M") == true)
        #expect(error("10 20 L 5 5")?.contains("começar com M") == true)
        #expect(error("M 0 0 X 5 5")?.contains("\"X\"") == true)
        #expect(error("M 0 0 L 5 5 @")?.contains("desconhecido") == true)
        #expect(error("M 0 0 L 5")?.contains("Faltam números") == true)
        #expect(error("M 10")?.contains("Faltam números") == true)
        #expect(error("M 0 0 C 1 2 3 4 5")?.contains("Faltam números") == true)
        #expect(error("M 0 0 Z 5 5")?.contains("Faltam números") == true, "numbers with no command after a Z")
    }

    @Test func aPathWithNoStrokeIsRefused() {
        #expect(error("M 5 5")?.contains("não desenha nada") == true)
    }

    @Test func aPathTooLongIsRefused() throws {
        // 5 characters for the move and 6 for each " L 1 1".
        let fits = "M 0 0" + String(repeating: " L 1 1", count: 665)
        #expect(fits.count <= SVGPath.maxLength)
        #expect(try parse(fits).count == 666)
        let tooLong = fits + String(repeating: " ", count: SVGPath.maxLength)
        #expect(error(tooLong)?.contains("\(SVGPath.maxLength)") == true)
    }

    @Test func numbersTooBigToUseAreRefusedNotTrapped() throws {
        #expect(error("M 0 0 L 1e999 0") != nil)
        #expect(error("M 0 0 C 1e999 0 0 0 5 5") != nil)
        // Big but finite: sampled with a bounded number of points.
        let huge = try parse("M 0 0 C 1e300 0 1e300 0 1e300 0")
        #expect(huge.count <= DragPath.maxPoints + 1 && huge.last == CGPoint(x: 1e300, y: 0))
    }

    @Test func aDrawingStaysInsideTheStrokeLimitAfterDensifying() throws {
        let points = try parse("M 0 0 C 0 3000 3000 3000 3000 0")
        #expect(DragPath.stroke(points.map { StrokePoint(point: $0) }).count <= DragPath.maxPoints)
    }
}
