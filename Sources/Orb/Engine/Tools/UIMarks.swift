import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The numbered marks of `screenshot` (docs/USO-DO-COMPUTADOR.md, section 2): which elements get one, the badges drawn over
// the picture, the legend that names them, the maths that turns a pixel of the picture into a point on screen, and the
// snapshot that lets `ui_act` use "#12" or an x,y read off the picture.

// MARK: - Coordinates

extension ShotGeometry {
    // The picture shows the window at `scale` pixels per point, its top-left pixel being the window's top-left corner.

    func pixelRect(fromWindowRect rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// Whether a pixel lies on the picture.
    func contains(pixel: CGPoint) -> Bool {
        pixel.x >= 0 && pixel.y >= 0 && pixel.x < Double(pixelWidth) && pixel.y < Double(pixelHeight)
    }

    /// The geometry of a picture of `frame` that is `width`×`height` pixels.
    init(imageWidth width: Int, imageHeight height: Int, windowFrame frame: CGRect, windowID: UInt32) {
        self.init(pixelWidth: width, pixelHeight: height, scale: frame.width > 0 ? Double(width) / frame.width : 1,
                  windowFrame: frame, windowID: windowID)
    }
}

// MARK: - Choosing the marks

/// An element a click can act on, found while walking the window.
struct UIMarkCandidate: Sendable, Equatable {
    /// The id `ui_read` would give it (w1.3.2).
    var id: String
    var rawRole: String
    /// Title, else description: what `ui_act` compares to know it found the same element.
    var label: String
    /// A placeholder or help text, for the legend when there is no label.
    var hint: String
    /// Position and size in points, relative to the window's top-left corner.
    var frame: CGRect
    var secure: Bool

    init(id: String, rawRole: String, label: String, hint: String = "", frame: CGRect, secure: Bool = false) {
        self.id = id
        self.rawRole = rawRole
        self.label = label
        self.hint = hint
        self.frame = frame
        self.secure = secure
    }
}

struct UIMark: Sendable, Equatable {
    var number: Int
    var candidate: UIMarkCandidate
    /// The part of the element that lies inside the window.
    var visibleFrame: CGRect
}

enum UIMarkSelector {
    static let maxMarks = 60
    /// Smaller than this and nobody can aim at it.
    static let minSide: CGFloat = 6

    /// Marks for the candidates that are visible (at least `minSide` points each way inside the window), numbered in
    /// reading order, at most `limit` of them. `total` counts the eligible ones before the limit.
    static func select(_ candidates: [UIMarkCandidate], windowSize: CGSize, limit: Int = maxMarks) -> (marks: [UIMark], total: Int) {
        let bounds = CGRect(origin: .zero, size: windowSize)
        var seen = Set<String>()
        var eligible: [(candidate: UIMarkCandidate, visible: CGRect)] = []
        for candidate in candidates {
            let visible = candidate.frame.intersection(bounds)
            guard !visible.isNull, visible.width >= minSide, visible.height >= minSide else { continue }
            // The same thing reported twice (a control and the view that wraps it) is marked once.
            let key = "\(candidate.rawRole)|\(UIText.fold(candidate.label))|\(Int(visible.minX.rounded())),\(Int(visible.minY.rounded())),\(Int(visible.width.rounded())),\(Int(visible.height.rounded()))"
            guard seen.insert(key).inserted else { continue }
            eligible.append((candidate, visible))
        }
        let ordered = readingOrder(eligible.map(\.visible)).map { eligible[$0] }
        let marks = ordered.prefix(limit).enumerated().map { UIMark(number: $0.offset + 1, candidate: $0.element.candidate, visibleFrame: $0.element.visible) }
        return (marks, eligible.count)
    }

    /// Indices of `frames` in reading order: rows from top to bottom, each from left to right. Two elements share a row when
    /// their vertical centres are closer than half the smaller height, so a tall sidebar does not swallow what is beside it.
    static func readingOrder(_ frames: [CGRect]) -> [Int] {
        let byTop = frames.indices.sorted { a, b in
            (frames[a].minY, frames[a].minX, a) < (frames[b].minY, frames[b].minX, b)
        }
        var rows: [[Int]] = []
        for index in byTop {
            if let anchor = rows.last?.first {
                let tolerance = min(frames[anchor].height, frames[index].height) / 2
                if abs(frames[index].midY - frames[anchor].midY) <= tolerance {
                    rows[rows.count - 1].append(index)
                    continue
                }
            }
            rows.append([index])
        }
        return rows.flatMap { row in row.sorted { (frames[$0].minX, $0) < (frames[$1].minX, $1) } }
    }
}

// MARK: - Walking a window for marks

struct UIMarkReading: Sendable {
    var candidates: [UIMarkCandidate] = []
    /// Visible elements that carry a title, description, help or placeholder: how much text the tree has.
    var labeled = 0
    var visited = 0
    var cuts: Set<UIOutlineCut> = []
    /// The app stopped answering (or the Accessibility API was refused); what was read before is kept.
    var failure: AXFailure?
    var cancelled = false
}

enum UIMarkCollector {
    struct Limits: Sendable {
        var maxVisited = 3_000
        var maxDepth = 16
        var seconds: Double = 4
    }

    /// Roles that are controls whatever their actions say.
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSearchField", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXLink", "AXColorWell",
    ]
    /// Roles that are only clickable when they say so with an action (a clickable card in a web page, a custom view).
    static let askActions: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXUnknown", "AXHeading", "AXList"]
    static let clickActions: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXOpen", "AXIncrement", "AXDecrement"]

    static let attributeNames = UIElementInfo.attributeNames + ["AXPosition", "AXChildren"]

    private final class Walk {
        var reading = UIMarkReading()
        let started = Date()
    }

    /// Walks `window` (ids `<prefix>.<position>`, counted like `ui_read` counts them) and collects the elements a click can
    /// act on. `origin` is the window's position on screen, `size` its size, both in points. Blocking: call it off the
    /// main actor. A control is not entered (its insides are part of it); a subtree that lies wholly outside the window is skipped.
    static func collect(window: any AccessibilityElement, prefix: String, origin: CGPoint, size: CGSize, limits: Limits = Limits()) -> UIMarkReading {
        let walk = Walk()
        visit(window, id: prefix, depth: 0, origin: origin, bounds: CGRect(origin: .zero, size: size), limits: limits, walk: walk)
        return walk.reading
    }

    private static func visit(_ element: any AccessibilityElement, id: String, depth: Int, origin: CGPoint, bounds: CGRect,
                              limits: Limits, walk: Walk) {
        if Task.isCancelled { walk.reading.cancelled = true; return }
        if walk.reading.failure != nil { return }
        if walk.reading.visited >= limits.maxVisited { walk.reading.cuts.insert(.visited); return }
        if Date().timeIntervalSince(walk.started) >= limits.seconds { walk.reading.cuts.insert(.time); return }
        walk.reading.visited += 1

        let attributes: [String: AXAttributeValue]
        switch element.read(attributeNames) {
        case .failed(let failure):
            // A vanished element is just skipped; a hung app ends the walk.
            if failure != .invalidElement { walk.reading.failure = failure }
            return
        case .values(let values):
            attributes = values
        }
        let info = UIElementInfo(attributes: attributes)
        if info.isInvisible { return }

        var relative: CGRect?
        if case .point(let position)? = attributes["AXPosition"], let size = info.size {
            relative = CGRect(x: position.x - origin.x, y: position.y - origin.y, width: size.width, height: size.height)
        }
        if let relative, relative.width > 0, relative.height > 0, !relative.intersects(bounds) { return }
        if info.title != nil || info.description != nil || info.help != nil || info.placeholder != nil { walk.reading.labeled += 1 }

        var enteredControl = false
        if depth > 0, let relative, info.enabled, isActionable(element, role: info.rawRole) {
            walk.reading.candidates.append(UIMarkCandidate(id: id, rawRole: info.rawRole, label: info.identity,
                                                           hint: info.placeholder ?? info.help ?? "", frame: relative, secure: info.secure))
            enteredControl = controls.contains(info.rawRole)
        }
        guard !enteredControl, depth < limits.maxDepth else { return }
        for (index, child) in (attributes["AXChildren"]?.elements ?? []).enumerated() {
            visit(child, id: "\(id).\(index + 1)", depth: depth + 1, origin: origin, bounds: bounds, limits: limits, walk: walk)
        }
    }

    private static func isActionable(_ element: any AccessibilityElement, role: String) -> Bool {
        if controls.contains(role) { return true }
        if role == "AXRow" { return element.isSettable("AXSelected") }
        if askActions.contains(role) { return !clickActions.isDisjoint(with: element.actionNames()) }
        return false
    }
}

// MARK: - The legend

enum UIMarkLegend {
    static let budget = 4_000

    /// `[12] w1.3.2 button “Salvar”`, one per line, at most `budget` characters (marks that do not fit are counted).
    static func lines(for marks: [UIMark]) -> [String] {
        marks.map { mark in
            let candidate = mark.candidate
            var line = "[\(mark.number)] \(candidate.id) \(UIRole.short(candidate.rawRole))"
            let text = candidate.label.isEmpty ? candidate.hint : candidate.label
            if !text.isEmpty { line += " " + UIText.quoted(UIText.clean(text, limit: 50)) }
            return line
        }
    }

    static func text(for marks: [UIMark], total: Int, budget: Int = UIMarkLegend.budget) -> String {
        guard !marks.isEmpty else { return "" }
        let fitted = ToolOutputBudget.fit(lines(for: marks), budget: budget)
        var text = fitted.kept.joined(separator: "\n")
        var notes: [String] = []
        if fitted.omitted > 0 { notes.append("+\(fitted.omitted) marcas sem legenda (estão na imagem)") }
        if total > marks.count { notes.append("\(marks.count) de \(total) elementos acionáveis") }
        if !notes.isEmpty { text += "\n(" + notes.joined(separator: "; ") + ")" }
        return text
    }
}

// MARK: - Drawing

enum UIOverlay {
    private static let palette: [CGColor] = [
        CGColor(srgbRed: 0.84, green: 0.11, blue: 0.11, alpha: 1), CGColor(srgbRed: 0.10, green: 0.35, blue: 0.85, alpha: 1),
        CGColor(srgbRed: 0.04, green: 0.52, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.55, green: 0.20, blue: 0.75, alpha: 1),
        CGColor(srgbRed: 0.85, green: 0.42, blue: 0.00, alpha: 1), CGColor(srgbRed: 0.00, green: 0.48, blue: 0.55, alpha: 1),
        CGColor(srgbRed: 0.78, green: 0.10, blue: 0.48, alpha: 1), CGColor(srgbRed: 0.48, green: 0.30, blue: 0.10, alpha: 1),
    ]

    /// The picture with an outline and a numbered badge on every mark, drawn with Core Graphics, on an opaque bitmap (so it
    /// encodes as JPEG without an alpha channel). With no marks it is just the opaque copy.
    static func render(_ image: CGImage, marks: [UIMark], geometry: ShotGeometry) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !marks.isEmpty else { return context.makeImage() }

        // From here the origin is the top left, like the coordinates of the marks.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(11, min(15, CGFloat(max(width, height)) / 105)), nil)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let lineWidth = max(1.5, min(3, geometry.scale))
        context.setLineWidth(lineWidth)
        for mark in marks {
            let color = palette[(mark.number - 1) % palette.count]
            let box = geometry.pixelRect(fromWindowRect: mark.visibleFrame).intersection(bounds)
            guard !box.isNull else { continue }
            context.setStrokeColor(color.copy(alpha: 0.9) ?? color)
            context.stroke(box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))

            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            let text = CFAttributedStringCreate(nil, String(mark.number) as CFString, attributes as CFDictionary)
            guard let text else { continue }
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let padX: CGFloat = 3, padY: CGFloat = 1.5
            let badge = CGSize(width: textWidth + 2 * padX, height: ascent + descent + 2 * padY)

            // Inside the corner when the box is big enough to stay readable, else above it, else inside anyway.
            var origin = CGPoint(x: box.minX, y: box.minY)
            if box.height < badge.height * 2.2 || box.width < badge.width * 1.6, box.minY - badge.height >= 0 {
                origin.y = box.minY - badge.height
            }
            origin.x = min(max(0, origin.x), CGFloat(width) - badge.width)
            origin.y = min(max(0, origin.y), CGFloat(height) - badge.height)
            let badgeRect = CGRect(origin: origin, size: badge)
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.textPosition = CGPoint(x: badgeRect.minX + padX, y: badgeRect.minY + padY + ascent)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}

// MARK: - JPEG

enum ScreenshotJPEG {
    /// The largest file a screenshot is saved as (the model is billed for the picture's pixels, and the attachment limit is near).
    static let maxBytes = 450_000
    static let quality = 0.8

    static func encode(_ image: CGImage, quality: Double = ScreenshotJPEG.quality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Quality 0.8; when that is over `maxBytes`, lower quality, then shrink the picture, until it fits. Returns the picture
    /// as encoded (its size may have changed).
    static func encode(fitting image: CGImage, maxBytes: Int = ScreenshotJPEG.maxBytes) -> (data: Data, image: CGImage)? {
        var current = image
        for attempt in 0..<8 {
            let qualities = attempt == 0 ? [quality, 0.65, 0.5] : [0.6]
            for quality in qualities {
                guard let data = encode(current, quality: quality) else { return nil }
                if data.count <= maxBytes || (attempt == 7 && quality == qualities.last) { return (data, current) }
            }
            let target = ImageScaling.targetSize(width: current.width, height: current.height, maxSide: max(64, Int(Double(max(current.width, current.height)) * 0.82)))
            current = ImageScaling.scaled(current, maxSide: max(target.width, target.height))
        }
        return nil
    }
}

// MARK: - The snapshot a screenshot leaves

/// What a screenshot read of one window.
struct ScreenshotReading: Sendable {
    var app: AccessibilityApp
    /// Position of the window among the app's windows, from 1 (the number in the ids).
    var windowIndex: Int
    var windowTitle: String
    var candidates: [UIMarkCandidate]
    var marks: [UIMark]
    /// Where the picture sits; nil when no picture was taken.
    var shot: ShotGeometry?
}

extension UISnapshot {
    /// A reading made this recently of the same window is merged with, not replaced.
    static let mergeWindow: TimeInterval = 60

    /// The snapshot after a screenshot: marks and geometry from the screenshot, the entries of a reading of the same
    /// window made less than 60 s ago kept (a `ui_read` outline and the marks of a screenshot name the same ids) and
    /// completed with the frames and click ability the screenshot found. Anything else starts over.
    static func merging(_ reading: ScreenshotReading, into existing: UISnapshot?, now: Date = .now) -> UISnapshot {
        var marks: [Int: String] = [:]
        for mark in reading.marks { marks[mark.number] = mark.candidate.id }

        func entry(for candidate: UIMarkCandidate) -> Entry {
            Entry(rawRole: candidate.rawRole, label: candidate.label, secure: candidate.secure, frame: candidate.frame, actionable: true)
        }

        guard let existing, existing.app.pid == reading.app.pid, existing.windowIndex == reading.windowIndex,
              UIText.fold(existing.windowTitle) == UIText.fold(reading.windowTitle),
              now.timeIntervalSince(existing.takenAt) < mergeWindow else {
            var entries: [String: Entry] = [:]
            for candidate in reading.candidates { entries[candidate.id] = entry(for: candidate) }
            return UISnapshot(app: reading.app, windowIndex: reading.windowIndex, windowTitle: reading.windowTitle, entries: entries,
                              takenAt: now, generation: (existing?.generation ?? -1) + 1, marks: marks, shot: reading.shot)
        }
        var entries = existing.entries
        for candidate in reading.candidates {
            if var known = entries[candidate.id], known.rawRole == candidate.rawRole,
               known.label.isEmpty || UIText.fold(known.label) == UIText.fold(candidate.label) {
                known.frame = candidate.frame
                known.actionable = true
                entries[candidate.id] = known
            } else {
                entries[candidate.id] = entry(for: candidate)
            }
        }
        // Same reading, so its time and generation stay: live references taken by the outline still belong to it.
        return UISnapshot(app: existing.app, windowIndex: existing.windowIndex, windowTitle: existing.windowTitle, entries: entries,
                          takenAt: existing.takenAt, generation: existing.generation, marks: marks, shot: reading.shot)
    }
}

// MARK: - Text recognition policy

enum OCRPolicy {
    /// Below this many labeled elements the Accessibility tree says too little and `ocr: auto` reads the picture.
    static let autoThreshold = 8

    /// `mode` is the `ocr` argument ("auto", "on", "off"; anything else is auto). `labeledElements` is how many visible
    /// elements had a name; nil (no Accessibility, no tree) counts as none.
    static func shouldRun(mode: String?, labeledElements: Int?) -> Bool {
        switch mode?.lowercased() {
        case "on", "true", "yes", "sim": return true
        case "off", "false", "no", "não", "nao": return false
        default: return (labeledElements ?? 0) < autoThreshold
        }
    }
}
