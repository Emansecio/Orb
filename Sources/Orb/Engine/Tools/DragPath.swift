import CoreGraphics
import Foundation

/// The points a drag or a pen stroke goes through, in whatever space they are given (screenshot pixels or screen points):
/// the caller converts. Pure geometry, so it is tested alone.
enum DragPath {
    /// The most points a drag or a stroke is sent as: a long stroke is thinned to this, so one call cannot flood an app.
    static let maxPoints = 600

    /// Below this distance (points) a drag is too short to curve or to need the early steps: the whole move is inside the
    /// threshold apps use to tell a click from a drag.
    private static let handMinimum: CGFloat = 8

    /// From `start` to `end` the way a hand moves: a slight arc, slow at both ends. At least two points, `start` first and
    /// `end` last.
    static func arc(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        // A point that is not a number cannot be walked towards (and would trap in the conversion below).
        guard distance.isFinite else { return [start, end] }

        // A quadratic Bézier whose control point sits to the side of the middle: a hand does not move in a ruler line, and
        // some apps look at the first moves to tell a drag from a click. The curve itself bulges half as far as the control.
        var control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        if distance >= handMinimum {
            let offset = min(0.12 * distance, 40)
            control.x -= dy / distance * offset
            control.y += dx / distance * offset
        }

        // Two small steps first, 1.5 and 3.5 points out. AppKit (and the lists and canvases built on it) only starts a drag
        // once the pointer has left the press by a few points; the easing alone makes the first step a fraction of a point on
        // a long move, so without these the drag would start late and far from where it was pressed.
        var floor: CGFloat = 0
        var parameters: [CGFloat] = [0]
        if distance >= handMinimum {
            floor = 3.5 / distance
            parameters += [1.5 / distance, floor]
        }
        // More points for a longer move, but never fewer than 12 or more than 60.
        let segments = Int(min(60, max(12, distance / 10)))
        for index in 1..<segments {
            let part = CGFloat(index) / CGFloat(segments)
            // Smoothstep: slow at both ends. It runs on what is left after the early steps, so the points keep increasing.
            parameters.append(floor + (1 - floor) * part * part * (3 - 2 * part))
        }
        parameters.append(1)

        var points = parameters.map { t -> CGPoint in
            let rest = 1 - t
            return CGPoint(x: rest * rest * start.x + 2 * rest * t * control.x + t * t * end.x,
                           y: rest * rest * start.y + 2 * rest * t * control.y + t * t * end.y)
        }
        // The ends exactly, whatever the rounding.
        points[0] = start
        points[points.count - 1] = end
        return points
    }

    /// The stroke with points added where two are far apart (at most `maxStep` between neighbours, pressures interpolated),
    /// then thinned evenly to at most `maxPoints`, keeping the first and the last.
    static func stroke(_ points: [StrokePoint], maxStep: CGFloat = 4) -> [StrokePoint] {
        guard points.count >= 2 else { return points }
        var dense = points
        let length = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y) }
        if maxStep > 0, length.isFinite {
            // A long stroke would be thinned right after, so never add more than the final size asks for: this also keeps
            // two far-apart points from allocating millions of steps.
            let step = max(maxStep, length / CGFloat(maxPoints))
            dense = [points[0]]
            for (from, to) in zip(points, points.dropFirst()) {
                let distance = hypot(to.point.x - from.point.x, to.point.y - from.point.y)
                let pieces = distance.isFinite ? Int((distance / step).rounded(.up)) : 1
                if pieces > 1 {
                    for piece in 1..<pieces {
                        let part = CGFloat(piece) / CGFloat(pieces)
                        // Pressure is only interpolated between two readings; next to a gap the new points keep the one before.
                        let pressure: Double?
                        if let before = from.pressure, let after = to.pressure { pressure = before + (after - before) * Double(part) } else { pressure = from.pressure }
                        dense.append(StrokePoint(point: CGPoint(x: from.point.x + (to.point.x - from.point.x) * part,
                                                                y: from.point.y + (to.point.y - from.point.y) * part),
                                                 pressure: pressure))
                    }
                }
                dense.append(to)
            }
        }
        guard dense.count > maxPoints else { return dense }
        // Evenly by position in the list: the added points are already evenly spaced, so this keeps the shape.
        let last = dense.count - 1
        return (0..<maxPoints).map { dense[$0 * last / (maxPoints - 1)] }
    }
}

/// A pen path written as SVG path data ("M 10 10 C 20 0 40 0 50 10"), for `draw`.
enum SVGPath {
    /// The longest path accepted, in characters: a drawing this detailed is better sent as points, and a limit keeps one
    /// call from carrying a huge text.
    static let maxLength = 4_000

    /// The points of one stroke: commands M, L, H, V, C, S, Q, T and Z, absolute or relative, curves sampled into points.
    /// A second M (a second stroke) is refused: one call draws one stroke.
    static func parse(_ text: String) throws -> [CGPoint] {
        guard text.utf8.count <= maxLength else {
            throw ToolError("O caminho passa de \(maxLength) caracteres: simplifique ou mande menos curvas.")
        }
        // 'A' and 'a' can only be the arc command (a number's exponent is 'e'). The Catalog parser turns arcs into curves;
        // here they are refused so the model draws with commands whose result it can predict.
        if text.utf8.contains(where: { $0 | 0x20 == UInt8(ascii: "a") }) {
            throw ToolError("Arcos (A) não são aceitos no caminho: use C ou Q para curvas.")
        }
        // The same reader as the brand marks: it already handles signs, exponents, packed numbers ("1.5.5") and commands
        // left out when they repeat. Its answer is only yes or no, so what went wrong is worked out afterwards.
        guard let segments = SVGPathData.segments(text) else { throw ToolError(problem(in: text)) }

        var points: [CGPoint] = []
        var start = CGPoint.zero
        var current = CGPoint.zero
        var justClosed = false
        for segment in segments {
            defer { if case .close = segment { justClosed = true } else { justClosed = false } }
            switch segment {
            case .move(let point):
                if points.isEmpty {
                    start = point
                    points = [point]
                } else if !(justClosed && point == start) {
                    // After Z the reader starts a new subpath at the start point on its own; that is the same stroke going on.
                    throw ToolError("Um desenho por chamada: o caminho tem mais de um M.")
                }
                current = point
            case .line(let point):
                points.append(point)
                current = point
            case .quad(let control, let end):
                points += try sample([current, control, end])
                current = end
            case .curve(let control1, let control2, let end):
                points += try sample([current, control1, control2, end])
                current = end
            case .close:
                if current != start { points.append(start) }
                current = start
            }
        }
        guard points.count >= 2 else { throw ToolError("O caminho não desenha nada: depois do M falta um traço (L, C, Q…).") }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw ToolError("O caminho tem um número grande demais.") }
        return points
    }

    /// The points of a quadratic (3 control points) or cubic (4) Bézier after its first, the last being exactly the end
    /// point. About one point per 4 units of control polygon, which follows the curve closely enough for a pen, and at
    /// least 8 so even a short curve bends.
    private static func sample(_ controls: [CGPoint]) throws -> [CGPoint] {
        let length = zip(controls, controls.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // A number like 1e999 reads as infinity and would trap in the conversion below.
        guard length.isFinite else { throw ToolError("O caminho tem um número grande demais.") }
        // Capped so a curve of huge coordinates cannot make millions of points.
        let count = Int(min((length / 4).rounded(.up), CGFloat(DragPath.maxPoints)))
        let steps = max(8, count)
        var result = (1..<steps).map { step in bezier(controls, at: CGFloat(step) / CGFloat(steps)) }
        result.append(controls[controls.count - 1])
        return result
    }

    private static func bezier(_ controls: [CGPoint], at t: CGFloat) -> CGPoint {
        let rest = 1 - t
        if controls.count == 3 {
            return CGPoint(x: rest * rest * controls[0].x + 2 * rest * t * controls[1].x + t * t * controls[2].x,
                           y: rest * rest * controls[0].y + 2 * rest * t * controls[1].y + t * t * controls[2].y)
        }
        let a = rest * rest * rest, b = 3 * rest * rest * t, c = 3 * rest * t * t, d = t * t * t
        return CGPoint(x: a * controls[0].x + b * controls[1].x + c * controls[2].x + d * controls[3].x,
                       y: a * controls[0].y + b * controls[1].y + c * controls[2].y + d * controls[3].y)
    }

    /// What is wrong with a path the reader refused, in a line the model can act on.
    private static func problem(in text: String) -> String {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return "O caminho está vazio: comece com M x y." }
        guard first == "M" || first == "m" else { return "O caminho precisa começar com M (por exemplo M 10 10 L 50 50)." }
        let allowed = Set("MmLlHhVvCcSsQqTtZz0123456789+-.,eE")
        if let unknown = text.first(where: { !$0.isWhitespace && !allowed.contains($0) }) {
            return "Comando desconhecido \"\(unknown)\" no caminho: use M, L, H, V, C, S, Q, T e Z."
        }
        return "Faltam números em algum comando do caminho (M e L pedem 2, H e V 1, Q e S 4, C 6)."
    }
}
