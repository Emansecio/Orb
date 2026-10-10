import SwiftUI

/// One step of an SVG path in absolute coordinates. Arcs are already cubic curves; `H`/`V`, relative commands and the
/// smooth shorthands (`S`, `T`) are already plain lines and curves.
enum PathSegment: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(control: CGPoint, to: CGPoint)
    case curve(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case close
}

/// The `d` attribute of an SVG `<path>` as a SwiftUI `Path`: M L H V C S Q T A Z in both cases, the command letter left
/// out when it repeats, numbers packed together as "1.5.5" or "-1-2" or with an exponent, and arc flags written without
/// a separator ("a1 1 0 00-1 2").
enum SVGPathData {
    /// The path, or nil when the text is not valid path data (the first command must be a move; a number with no command
    /// to use it, or a command short of numbers, is an error).
    static func path(_ data: String) -> Path? {
        guard let segments = segments(data) else { return nil }
        return Path { path in
            for segment in segments {
                switch segment {
                case .move(let point): path.move(to: point)
                case .line(let point): path.addLine(to: point)
                case .quad(let control, let point): path.addQuadCurve(to: point, control: control)
                case .curve(let c1, let c2, let point): path.addCurve(to: point, control1: c1, control2: c2)
                case .close: path.closeSubpath()
                }
            }
        }
    }

    static func segments(_ data: String) -> [PathSegment]? {
        var parser = Parser(bytes: Array(data.utf8))
        return parser.run()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var segments: [PathSegment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// The second control point of the last cubic and the control point of the last quadratic: what `S` and `T` mirror.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        /// After `Z` the pen sits at the start of the subpath; the next drawing command begins a new subpath there.
        var needsMove = false

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() -> [PathSegment]? {
            var command: UInt8?
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                let byte = bytes[index]
                if Self.isCommand(byte) {
                    command = byte
                    index += 1
                    // A path starts with a move; "M" is absolute even when written "m".
                    if segments.isEmpty, byte != UInt8(ascii: "M"), byte != UInt8(ascii: "m") { return nil }
                } else if let active = command {
                    // Numbers with no letter repeat the last command (the sets after a move's first are lines); after Z they are an error.
                    switch active {
                    case UInt8(ascii: "Z"), UInt8(ascii: "z"): return nil
                    case UInt8(ascii: "M"): command = UInt8(ascii: "L")
                    case UInt8(ascii: "m"): command = UInt8(ascii: "l")
                    default: break
                    }
                } else {
                    return nil
                }
                guard let active = command, apply(active) else { return nil }
            }
            return segments.isEmpty ? nil : segments
        }

        // MARK: Commands

        /// Reads the parameters of one command and adds its segments; false when they are missing or malformed.
        private mutating func apply(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let point = readPoint(origin) else { return false }
                segments.append(.move(point))
                current = point
                subpathStart = point
                needsMove = false
                resetSmooth()
            case UInt8(ascii: "l"):
                guard let point = readPoint(origin) else { return false }
                line(to: point)
            case UInt8(ascii: "h"):
                guard let x = readNumber() else { return false }
                line(to: CGPoint(x: relative ? current.x + x : x, y: current.y))
            case UInt8(ascii: "v"):
                guard let y = readNumber() else { return false }
                line(to: CGPoint(x: current.x, y: relative ? current.y + y : y))
            case UInt8(ascii: "c"):
                guard let c1 = readPoint(origin), let c2 = readPoint(origin), let end = readPoint(origin) else { return false }
                curve(c1, c2, end)
            case UInt8(ascii: "s"):
                guard let c2 = readPoint(origin), let end = readPoint(origin) else { return false }
                curve(lastCubic.map(reflected) ?? current, c2, end)
            case UInt8(ascii: "q"):
                guard let control = readPoint(origin), let end = readPoint(origin) else { return false }
                quad(control, end)
            case UInt8(ascii: "t"):
                guard let end = readPoint(origin) else { return false }
                quad(lastQuad.map(reflected) ?? current, end)
            case UInt8(ascii: "a"):
                guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                      let large = readFlag(), let sweep = readFlag(), let end = readPoint(origin) else { return false }
                beginDrawing()
                segments += Self.arc(from: current, radiusX: rx, radiusY: ry, rotation: rotation, large: large, sweep: sweep, to: end)
                current = end
                resetSmooth()
            case UInt8(ascii: "z"):
                segments.append(.close)
                current = subpathStart
                needsMove = true
                resetSmooth()
            default:
                return false
            }
            return true
        }

        private mutating func beginDrawing() {
            if needsMove {
                segments.append(.move(current))
                needsMove = false
            }
        }

        private mutating func resetSmooth() { lastCubic = nil; lastQuad = nil }

        private mutating func line(to point: CGPoint) {
            beginDrawing()
            segments.append(.line(point))
            current = point
            resetSmooth()
        }

        private mutating func curve(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
            beginDrawing()
            segments.append(.curve(control1: c1, control2: c2, to: end))
            current = end
            resetSmooth()
            lastCubic = c2
        }

        private mutating func quad(_ control: CGPoint, _ end: CGPoint) {
            beginDrawing()
            segments.append(.quad(control: control, to: end))
            current = end
            resetSmooth()
            lastQuad = control
        }

        /// The last control point mirrored through the current point.
        private func reflected(_ point: CGPoint) -> CGPoint { CGPoint(x: 2 * current.x - point.x, y: 2 * current.y - point.y) }

        // MARK: Reading

        private static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"), UInt8(ascii: "s"),
                 UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"): true
            default: false
            }
        }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || (0x09...0x0D).contains(bytes[index]) { index += 1 }
        }

        private mutating func readPoint(_ origin: CGPoint) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return CGPoint(x: origin.x + x, y: origin.y + y)
        }

        /// A number: sign, digits, a point and more digits, an exponent. It ends where the next one begins, so "1.5.5" is
        /// 1.5 and .5, and "-1-2" is -1 and -2.
        private mutating func readNumber() -> Double? {
            skipSeparators()
            let start = index
            var cursor = index
            func digits() -> Int {
                let begin = cursor
                while cursor < bytes.count, (0x30...0x39).contains(bytes[cursor]) { cursor += 1 }
                return cursor - begin
            }
            if cursor < bytes.count, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D { cursor += 1 }
            var count = digits()
            if cursor < bytes.count, bytes[cursor] == 0x2E {
                cursor += 1
                count += digits()
            }
            guard count > 0 else { return nil }
            // An exponent only counts when digits follow ("1e", "1em" are not numbers with an exponent).
            if cursor < bytes.count, bytes[cursor] | 0x20 == UInt8(ascii: "e") {
                var probe = cursor + 1
                if probe < bytes.count, bytes[probe] == 0x2B || bytes[probe] == 0x2D { probe += 1 }
                if probe < bytes.count, (0x30...0x39).contains(bytes[probe]) {
                    cursor = probe
                    _ = digits()
                }
            }
            index = cursor
            return Double(String(decoding: bytes[start..<cursor], as: UTF8.self))
        }

        /// An arc flag: one "0" or "1", with nothing needed after it.
        private mutating func readFlag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
            defer { index += 1 }
            return bytes[index] == 0x31
        }

        // MARK: Arcs

        /// An elliptical arc as cubic curves, one per quarter turn at most (SVG 1.1 implementation notes, F.6.5). A zero
        /// radius is a straight line; radii too small to reach the end point grow until they do.
        static func arc(from start: CGPoint, radiusX: Double, radiusY: Double, rotation: Double, large: Bool, sweep: Bool,
                        to end: CGPoint) -> [PathSegment] {
            if start == end { return [] }
            var rx = abs(radiusX), ry = abs(radiusY)
            if rx == 0 || ry == 0 { return [.line(end)] }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let scale = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if scale > 1 { rx *= scale.squareRoot(); ry *= scale.squareRoot() }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let factor = (max(0, numerator / denominator)).squareRoot() * (large == sweep ? -1 : 1)
            let cx1 = factor * rx * y1 / ry
            let cy1 = -factor * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2
            let theta = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
            var sweepAngle = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta
            if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }
            if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
            let pieces = max(1, Int((abs(sweepAngle) / (.pi / 2) - 1e-9).rounded(.up)))
            let delta = sweepAngle / Double(pieces)
            let handle = 4.0 / 3.0 * tan(delta / 4)
            func point(_ angle: Double) -> CGPoint {
                CGPoint(x: cx + rx * cos(angle) * cosPhi - ry * sin(angle) * sinPhi,
                        y: cy + rx * cos(angle) * sinPhi + ry * sin(angle) * cosPhi)
            }
            func tangent(_ angle: Double) -> CGPoint {
                CGPoint(x: -rx * sin(angle) * cosPhi - ry * cos(angle) * sinPhi,
                        y: -rx * sin(angle) * sinPhi + ry * cos(angle) * cosPhi)
            }
            return (0..<pieces).map { piece in
                let from = theta + Double(piece) * delta
                let to = from + delta
                let a = point(from), b = tangent(from), c = point(to), d = tangent(to)
                return .curve(control1: CGPoint(x: a.x + handle * b.x, y: a.y + handle * b.y),
                              control2: CGPoint(x: c.x - handle * d.x, y: c.y - handle * d.y),
                              // The last piece lands exactly on the end point, whatever the rounding.
                              to: piece == pieces - 1 ? end : c)
            }
        }
    }
}
