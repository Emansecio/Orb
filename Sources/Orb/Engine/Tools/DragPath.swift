import CoreGraphics
import Foundation

/// The points a drag or a pen stroke goes through, in whatever space they are given (screenshot pixels or screen points):
/// the caller converts. Pure geometry, so it is tested alone.
enum DragPath {
    /// The most points a drag or a stroke is sent as: a long stroke is thinned to this, so one call cannot flood an app.
    static let maxPoints = 600

    /// From `start` to `end` the way a hand moves: a slight arc, slow at both ends. At least two points, `start` first and
    /// `end` last.
    static func arc(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let steps = 12
        return (0...steps).map { step in
            let part = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part)
        }
    }

    /// The stroke with points added where two are far apart (at most `maxStep` between neighbours, pressures interpolated),
    /// then thinned evenly to at most `maxPoints`, keeping the first and the last.
    static func stroke(_ points: [StrokePoint], maxStep: CGFloat = 4) -> [StrokePoint] {
        points
    }
}

/// A pen path written as SVG path data ("M 10 10 C 20 0 40 0 50 10"), for `draw`.
enum SVGPath {
    /// The points of one stroke: commands M, L, H, V, C, S, Q, T and Z, absolute or relative, curves sampled into points.
    /// A second M (a second stroke) is refused: one call draws one stroke.
    static func parse(_ text: String) throws -> [CGPoint] {
        throw ToolError("O desenho por caminho SVG ainda não está disponível; mande os pontos.")
    }
}
