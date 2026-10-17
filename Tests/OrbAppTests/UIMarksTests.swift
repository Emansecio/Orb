import CoreGraphics
import Foundation
import Testing
@testable import Orb

/// The numbered marks of `screenshot`: which elements get one, the legend, the maths between pixels and screen points, the
/// overlay and JPEG budgets, and the snapshot a screenshot leaves for `ui_act`.
struct UIMarksTests {
    private func candidate(_ id: String, _ role: String = "AXButton", label: String = "Item", frame: CGRect, hint: String = "", secure: Bool = false) -> UIMarkCandidate {
        UIMarkCandidate(id: id, rawRole: role, label: label, hint: hint, frame: frame, secure: secure)
    }

    /// A small deterministic generator, so the property tests repeat.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    // MARK: Which elements get a mark

    @Test func onlyVisibleElementsOfUsableSizeInsideTheWindowGetAMark() {
        let window = CGSize(width: 400, height: 300)
        let found = UIMarkSelector.select([
            candidate("w1.1", frame: CGRect(x: 10, y: 10, width: 80, height: 24)),
            candidate("w1.2", frame: CGRect(x: 10, y: 50, width: 5, height: 40)),       // too narrow
            candidate("w1.3", frame: CGRect(x: 10, y: 100, width: 40, height: 5.9)),     // too short
            candidate("w1.4", frame: CGRect(x: 450, y: 10, width: 80, height: 24)),      // wholly outside
            candidate("w1.5", frame: CGRect(x: 380, y: 10, width: 80, height: 24)),      // 20 pt inside: kept, clipped
            candidate("w1.6", frame: CGRect(x: 396, y: 200, width: 80, height: 24)),     // 4 pt inside: not enough
            candidate("w1.7", frame: CGRect(x: 10, y: 140, width: 6, height: 6)),        // exactly the minimum
            candidate("w1.8", frame: CGRect(x: -30, y: 180, width: 40, height: 20)),     // 10 pt inside on the left
        ], windowSize: window)
        #expect(found.marks.map(\.candidate.id) == ["w1.1", "w1.5", "w1.7", "w1.8"])
        #expect(found.total == 4)
        let clipped = found.marks.first { $0.candidate.id == "w1.5" }
        #expect(clipped?.visibleFrame == CGRect(x: 380, y: 10, width: 20, height: 24))
        #expect(clipped?.candidate.frame == CGRect(x: 380, y: 10, width: 80, height: 24), "the element keeps its real frame")
    }

    @Test func marksAreNumberedInReadingOrderAndTallNeighboursDoNotSwallowARow() {
        let found = UIMarkSelector.select([
            candidate("side", "AXList", frame: CGRect(x: 0, y: 0, width: 100, height: 280)),
            candidate("b", frame: CGRect(x: 300, y: 12, width: 60, height: 20)),
            candidate("a", frame: CGRect(x: 120, y: 10, width: 60, height: 20)),
            candidate("c", frame: CGRect(x: 120, y: 60, width: 60, height: 20)),
            candidate("d", frame: CGRect(x: 300, y: 58, width: 60, height: 20)),
        ], windowSize: CGSize(width: 400, height: 300))
        #expect(found.marks.map(\.candidate.id) == ["side", "a", "b", "c", "d"])
        #expect(found.marks.map(\.number) == [1, 2, 3, 4, 5])
    }

    @Test func atMostSixtyMarksAreDrawnAndTheTotalIsKept() {
        let many = (0..<75).map { index in
            candidate("w1.\(index + 1)", frame: CGRect(x: CGFloat(index % 5) * 70 + 5, y: CGFloat(index / 5) * 28 + 5, width: 60, height: 20))
        }
        let found = UIMarkSelector.select(many, windowSize: CGSize(width: 400, height: 500))
        #expect(found.marks.count == UIMarkSelector.maxMarks && UIMarkSelector.maxMarks == 60)
        #expect(found.total == 75)
        #expect(found.marks.map(\.number) == Array(1...60))
        #expect(found.marks.first?.candidate.id == "w1.1" && found.marks.last?.candidate.id == "w1.60")
    }

    @Test func theSameElementReportedTwiceIsMarkedOnce() {
        let frame = CGRect(x: 10, y: 10, width: 80, height: 24)
        let found = UIMarkSelector.select([candidate("w1.1", frame: frame), candidate("w1.1.1", frame: frame),
                                           candidate("w1.2", "AXLink", frame: frame)], windowSize: CGSize(width: 200, height: 100))
        #expect(found.marks.map(\.candidate.id) == ["w1.1", "w1.2"], "different role, different thing; same role, label and frame, one")
    }

    // MARK: The legend

    @Test func theLegendNamesNumberIdRoleAndLabel() {
        let found = UIMarkSelector.select([
            candidate("w1.3.2", label: "Salvar", frame: CGRect(x: 10, y: 10, width: 80, height: 24)),
            candidate("w1.4", "AXTextField", label: "", frame: CGRect(x: 10, y: 50, width: 80, height: 24), hint: "Nome"),
            candidate("w1.5", "AXCheckBox", label: "", frame: CGRect(x: 10, y: 90, width: 80, height: 24)),
        ], windowSize: CGSize(width: 200, height: 200))
        #expect(UIMarkLegend.lines(for: found.marks) == ["[1] w1.3.2 button “Salvar”", "[2] w1.4 field “Nome”", "[3] w1.5 checkbox"])
    }

    @Test func theLegendStaysUnderFourThousandCharactersAndCountsWhatItLeavesOut() {
        let marks = (1...60).map { number in
            UIMark(number: number, candidate: candidate("w1.\(number).\(number).\(number)", label: String(repeating: "Título muito longo ", count: 8),
                                                       frame: CGRect(x: 0, y: CGFloat(number) * 20, width: 50, height: 18)),
                   visibleFrame: CGRect(x: 0, y: CGFloat(number) * 20, width: 50, height: 18))
        }
        let text = UIMarkLegend.text(for: marks, total: 80)
        let body = text.split(separator: "\n").dropLast().joined(separator: "\n")
        #expect(body.count <= UIMarkLegend.budget && UIMarkLegend.budget == 4_000)
        #expect(text.contains("marcas sem legenda"))
        #expect(text.contains("60 de 80 elementos acionáveis"))
        // A short legend has no notes.
        let few = Array(marks.prefix(3))
        #expect(!UIMarkLegend.text(for: few, total: 3).contains("("))
        #expect(UIMarkLegend.text(for: [], total: 0).isEmpty)
    }

    // MARK: Pixels, window points and screen points

    @Test func aScreenshotAtTwoTimesMapsPixelsToPointsExactly() {
        let geometry = ShotGeometry(imageWidth: 2_400, imageHeight: 1_600, windowFrame: CGRect(x: 100, y: 50, width: 1_200, height: 800), windowID: 9)
        #expect(geometry.scale == 2)
        #expect(geometry.pixelRect(fromWindowRect: CGRect(x: 10, y: 20, width: 30, height: 40)) == CGRect(x: 20, y: 40, width: 60, height: 80))
        #expect(geometry.contains(pixel: CGPoint(x: 0, y: 0)) && !geometry.contains(pixel: CGPoint(x: 2_400, y: 10)) && !geometry.contains(pixel: CGPoint(x: -1, y: 10)))
    }

    // MARK: Drawing

    private func screenLikeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var random = Generator(state: 11)
        for _ in 0..<150 {
            context.setFillColor(CGColor(srgbRed: Double.random(in: 0.2...1, using: &random), green: Double.random(in: 0.2...1, using: &random),
                                         blue: Double.random(in: 0.2...1, using: &random), alpha: 1))
            context.fill(CGRect(x: Int.random(in: 0..<width - 60, using: &random), y: Int.random(in: 0..<height - 20, using: &random),
                                width: Int.random(in: 20...300, using: &random), height: Int.random(in: 6...30, using: &random)))
        }
        return try #require(context.makeImage())
    }

    private func sixtyMarks(in size: CGSize) -> [UIMark] {
        (0..<60).map { index in
            let frame = CGRect(x: CGFloat(index % 6) * 200 + 10, y: CGFloat(index / 6) * 75 + 10, width: 150, height: 32)
            return UIMark(number: index + 1, candidate: candidate("w1.\(index + 1)", label: "Botão \(index + 1)", frame: frame), visibleFrame: frame)
        }
    }

    /// The fastest of several runs: another process using the CPU makes single runs vary, not the best one.
    private func best(of runs: Int, _ body: () throws -> Void) rethrows -> Double {
        var fastest = Double.infinity
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            let elapsed = start.duration(to: .now)
            fastest = min(fastest, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return fastest
    }

    @Test func theOverlayOf60MarksOn1280x800TakesUnder30Milliseconds() throws {
        let image = try screenLikeImage(width: 1_280, height: 800)
        let geometry = ShotGeometry(imageWidth: 1_280, imageHeight: 800, windowFrame: CGRect(x: 0, y: 0, width: 1_280, height: 800), windowID: 1)
        let marks = sixtyMarks(in: CGSize(width: 1_280, height: 800))
        _ = UIOverlay.render(image, marks: marks, geometry: geometry) // warm-up: fonts, colour spaces
        let milliseconds = best(of: 9) { _ = UIOverlay.render(image, marks: marks, geometry: geometry) }
        #expect(milliseconds <= 30, "\(milliseconds) ms")
        print("overlay 1280x800 / 60 marks: \(milliseconds) ms")
    }

    @Test func encodingA1280x800PictureAsJPEGTakesUnder30MillisecondsAndFitsTheFileLimit() throws {
        let image = try screenLikeImage(width: 1_280, height: 800)
        let geometry = ShotGeometry(imageWidth: 1_280, imageHeight: 800, windowFrame: CGRect(x: 0, y: 0, width: 1_280, height: 800), windowID: 1)
        let drawn = try #require(UIOverlay.render(image, marks: sixtyMarks(in: CGSize(width: 1_280, height: 800)), geometry: geometry))
        _ = ScreenshotJPEG.encode(drawn)
        let milliseconds = best(of: 9) { _ = ScreenshotJPEG.encode(drawn) }
        #expect(milliseconds <= 30, "\(milliseconds) ms")
        let data = try #require(ScreenshotJPEG.encode(drawn))
        #expect(data.count <= 450_000 && ScreenshotJPEG.maxBytes == 450_000, "\(data.count) bytes")
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        print("jpeg 1280x800: \(milliseconds) ms, \(data.count) bytes")
    }

    @Test func aPictureTooBigForTheLimitLosesQualityThenSize() throws {
        // Noise does not compress: at quality 0.8 this is far over 450 KB.
        var random = SystemRandomNumberGenerator()
        let width = 1_280, height = 800
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8.random(in: 0...255, using: &random)
            bytes[index + 1] = UInt8.random(in: 0...255, using: &random)
            bytes[index + 2] = UInt8.random(in: 0...255, using: &random)
            bytes[index + 3] = 255
        }
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(context.makeImage())
        }
        #expect(try #require(ScreenshotJPEG.encode(image)).count > 450_000)
        let fitted = try #require(ScreenshotJPEG.encode(fitting: image))
        #expect(fitted.data.count <= 450_000, "\(fitted.data.count) bytes")
        #expect(fitted.image.width < width, "noise this heavy cannot fit without shrinking")
        #expect(abs(fitted.image.width * 800 - fitted.image.height * 1_280) <= 1_280, "the proportions are kept")
    }

    @Test func theOverlayDrawsOnlyWhereTheMarksAre() throws {
        let width = 400, height = 300
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let geometry = ShotGeometry(imageWidth: width, imageHeight: height, windowFrame: CGRect(x: 0, y: 0, width: 200, height: 150), windowID: 1) // 2x
        let frame = CGRect(x: 20, y: 20, width: 60, height: 40) // window points: pixels (40,40)-(160,120)
        let mark = UIMark(number: 7, candidate: candidate("w1.1", frame: frame), visibleFrame: frame)
        let plain = try #require(UIOverlay.render(image, marks: [], geometry: geometry))
        let marked = try #require(UIOverlay.render(image, marks: [mark], geometry: geometry))
        #expect(plain.width == width && marked.height == height)
        #expect(!isWhite(pixel(marked, x: 41, y: 100)), "the outline is drawn on the left edge of the box")
        #expect(isWhite(pixel(marked, x: 300, y: 250)), "far from the mark nothing changes")
        #expect(isWhite(pixel(plain, x: 41, y: 100)))
        #expect(isWhite(pixel(marked, x: 100, y: 100)), "the inside of the box stays clear")
    }

    /// RGB at (x, y), counted from the top left.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    private func isWhite(_ pixel: (UInt8, UInt8, UInt8)) -> Bool { pixel.0 > 245 && pixel.1 > 245 && pixel.2 > 245 }

    // MARK: Walking a window

    private func window(_ children: [FakeElement], frame: CGRect = CGRect(x: 100, y: 50, width: 400, height: 300)) -> FakeElement {
        let window = fake("AXWindow", title: "Doc", children)
        window.frame = frame
        return window
    }

    private func element(_ element: FakeElement, at frame: CGRect) -> FakeElement {
        element.frame = frame
        return element
    }

    @Test func theWalkMarksControlsInTheIdsUiReadWouldGive() {
        let save = element(fakeButton("Salvar"), at: CGRect(x: 120, y: 70, width: 80, height: 24))
        let label = element(fake("AXStaticText", title: "Rótulo"), at: CGRect(x: 120, y: 100, width: 80, height: 20))
        let field = element(fake("AXTextField", title: "Nome", placeholder: "seu nome"), at: CGRect(x: 120, y: 130, width: 200, height: 24))
        let group = element(fake("AXGroup", [element(fakeButton("Dentro"), at: CGRect(x: 130, y: 170, width: 60, height: 20))]), at: CGRect(x: 120, y: 165, width: 200, height: 40))
        let doc = window([save, label, field, group])
        let reading = UIMarkCollector.collect(window: doc, prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.candidates.map(\.id) == ["w1.1", "w1.3", "w1.4.1"])
        #expect(reading.candidates[0].frame == CGRect(x: 20, y: 20, width: 80, height: 24), "relative to the window")
        #expect(reading.candidates[1].hint == "seu nome" && reading.candidates[1].label == "Nome")
        // The ids are the ones the outline gives.
        let outline = UIOutlineBuilder.outline(of: doc, prefix: "w1", query: nil, limits: UIOutlineLimits())
        for candidate in reading.candidates {
            #expect(outline.entries[candidate.id]?.rawRole == candidate.rawRole, "\(candidate.id)")
            #expect(outline.entries[candidate.id]?.label == candidate.label)
        }
        #expect(reading.failure == nil && !reading.cancelled)
    }

    @Test func aControlIsNotEnteredAndWhatLiesOutsideTheWindowIsSkipped() {
        let inner = element(fakeButton("Interno"), at: CGRect(x: 125, y: 75, width: 20, height: 20))
        let outer = element(fake("AXButton", title: "Externo", actions: ["AXPress"], [inner]), at: CGRect(x: 120, y: 70, width: 80, height: 24))
        let far = element(fakeButton("Longe"), at: CGRect(x: 900, y: 70, width: 80, height: 24))
        let hidden = element(fake("AXButton", title: "Oculto", hidden: true, actions: ["AXPress"]), at: CGRect(x: 120, y: 200, width: 80, height: 24))
        let disabled = element(fake("AXButton", title: "Cinza", enabled: false, actions: ["AXPress"]), at: CGRect(x: 120, y: 230, width: 80, height: 24))
        let reading = UIMarkCollector.collect(window: window([outer, far, hidden, disabled]), prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.candidates.map(\.label) == ["Externo"])
        #expect(inner.roundTrips == 0, "the inside of a control is not read")
        #expect(far.roundTrips == 1, "one read tells it is outside")
    }

    @Test func containersAreMarkedOnlyWhenTheyAreClickableAndRowsWhenTheyCanBeSelected() {
        let card = element(fake("AXGroup", title: "Cartão", actions: ["AXPress"]), at: CGRect(x: 10, y: 10, width: 100, height: 60))
        let plainGroup = element(fake("AXGroup", title: "Moldura"), at: CGRect(x: 10, y: 80, width: 100, height: 60))
        let row = element(fake("AXRow"), at: CGRect(x: 10, y: 150, width: 300, height: 20))
        row.settable = ["AXSelected"]
        let fixedRow = element(fake("AXRow"), at: CGRect(x: 10, y: 180, width: 300, height: 20))
        let reading = UIMarkCollector.collect(window: window([card, plainGroup, row, fixedRow]), prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.candidates.map(\.id) == ["w1.1", "w1.3"])
    }

    @Test func aHungAppEndsTheWalkAndKeepsWhatWasRead() {
        let first = element(fakeButton("Primeiro"), at: CGRect(x: 120, y: 70, width: 80, height: 24))
        let stuck = element(fakeButton("Preso"), at: CGRect(x: 120, y: 110, width: 80, height: 24))
        stuck.failures["*"] = .cannotComplete
        let last = element(fakeButton("Último"), at: CGRect(x: 120, y: 150, width: 80, height: 24))
        let reading = UIMarkCollector.collect(window: window([first, stuck, last]), prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.candidates.map(\.label) == ["Primeiro"])
        #expect(reading.failure == .cannotComplete)
        #expect(last.roundTrips == 0)
    }

    @Test func aVanishedElementIsSkippedWithoutStoppingTheWalk() {
        let gone = element(fakeButton("Sumiu"), at: CGRect(x: 120, y: 70, width: 80, height: 24))
        gone.failures["*"] = .invalidElement
        let stays = element(fakeButton("Fica"), at: CGRect(x: 120, y: 110, width: 80, height: 24))
        let reading = UIMarkCollector.collect(window: window([gone, stays]), prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.candidates.map(\.label) == ["Fica"] && reading.failure == nil)
    }

    @Test func theWalkOnTheAppsQueueStopsWhenItsCallWasCancelled() {
        let buttons = (0..<5).map { element(fakeButton("B\($0)"), at: CGRect(x: 10, y: 10 + Double($0) * 30, width: 80, height: 24)) }
        let doc = window(buttons)
        // The work runs outside any task: what tells it to stop is the token of its session call (deadline passed, or Stop).
        let token = AXWorkToken()
        token.cancel()
        let reading = AXWorkToken.$current.withValue(token) {
            UIMarkCollector.collect(window: doc, prefix: "w1", origin: .zero, size: CGSize(width: 400, height: 300))
        }
        #expect(reading.cancelled && reading.candidates.isEmpty && doc.roundTrips == 0)
    }

    @Test func theWalkEndsBeforeTheReadDeadlineSoASlowAppGivesFewerMarksNotAnError() {
        #expect(UIMarkCollector.Limits().seconds < UIReadTool.seconds(AXDeadlines.standard.read))
    }

    @Test func eachElementCostsAtMostTwoRoundTripsAndTheBudgetsStopTheWalk() {
        let buttons = (0..<40).map { element(fakeButton("B\($0)"), at: CGRect(x: 10, y: 10 + Double($0) * 6, width: 80, height: 5.5)) }
        let groups = (0..<40).map { element(fake("AXGroup", title: "G\($0)"), at: CGRect(x: 200, y: 10 + Double($0) * 6, width: 80, height: 5.5)) }
        let doc = window(buttons + groups, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let reading = UIMarkCollector.collect(window: doc, prefix: "w1", origin: .zero, size: CGSize(width: 400, height: 300))
        #expect(doc.treeRoundTrips <= 2 * reading.visited)
        #expect(buttons.allSatisfy { $0.roundTrips == 1 }, "a control is known by its role: one read")
        #expect(groups.allSatisfy { $0.roundTrips == 2 }, "a group is asked for its actions")
        var limits = UIMarkCollector.Limits()
        limits.maxVisited = 10
        let cut = UIMarkCollector.collect(window: doc, prefix: "w1", origin: .zero, size: CGSize(width: 400, height: 300), limits: limits)
        #expect(cut.visited == 10 && cut.cuts.contains(.visited))
    }

    @Test func labeledElementsAreCounted() {
        let doc = window([fakeButton("A"), fake("AXStaticText", title: "B"), fake("AXImage"), fake("AXTextField", placeholder: "c")].map { element($0, at: CGRect(x: 120, y: 70, width: 80, height: 24)) })
        let reading = UIMarkCollector.collect(window: doc, prefix: "w1", origin: CGPoint(x: 100, y: 50), size: CGSize(width: 400, height: 300))
        #expect(reading.labeled == 4, "the window's own title, A, B and the placeholder")
    }

    // MARK: The snapshot

    private let editor = AccessibilityApp(name: "Editor", bundleID: "com.example.editor", pid: 100)
    private let geometry = ShotGeometry(imageWidth: 800, imageHeight: 600, windowFrame: CGRect(x: 100, y: 50, width: 400, height: 300), windowID: 77)

    private func reading(candidates: [UIMarkCandidate], windowIndex: Int = 1, title: String = "Doc", shot: ShotGeometry? = nil) -> ScreenshotReading {
        let marks = UIMarkSelector.select(candidates, windowSize: CGSize(width: 400, height: 300)).marks
        return ScreenshotReading(app: editor, windowIndex: windowIndex, windowTitle: title, candidates: candidates, marks: marks, shot: shot ?? geometry)
    }

    private let save = UIMarkCandidate(id: "w1.2", rawRole: "AXButton", label: "Salvar", frame: CGRect(x: 20, y: 20, width: 80, height: 24))
    private let cancel = UIMarkCandidate(id: "w1.3", rawRole: "AXButton", label: "Cancelar", frame: CGRect(x: 120, y: 20, width: 80, height: 24))

    private func outline(takenAt: Date, generation: Int = 4) -> UISnapshot {
        UISnapshot(app: editor, windowIndex: 1, windowTitle: "Doc", entries: [
            "w1": .init(rawRole: "AXWindow", label: "Doc", secure: false),
            "w1.1": .init(rawRole: "AXStaticText", label: "Título", secure: false),
            "w1.2": .init(rawRole: "AXButton", label: "Salvar", secure: false),
        ], takenAt: takenAt, generation: generation)
    }

    @Test func aScreenshotAloneLeavesMarksGeometryAndFramesForUiAct() {
        let snapshot = UISnapshot.merging(reading(candidates: [save, cancel]), into: nil)
        #expect(snapshot.marks == [1: "w1.2", 2: "w1.3"])
        #expect(snapshot.shot == geometry)
        #expect(snapshot.windowIndex == 1 && snapshot.windowTitle == "Doc" && snapshot.app == editor)
        #expect(snapshot.entries["w1.2"]?.frame == save.frame && snapshot.entries["w1.2"]?.actionable == true)
        #expect(snapshot.entries["w1.3"]?.label == "Cancelar")
        #expect(snapshot.generation == 0)
    }

    @Test func aMarkSurvivesTheMergeWithAUiReadOfTheSameWindow() {
        let now = Date.now
        let before = outline(takenAt: now.addingTimeInterval(-20))
        let merged = UISnapshot.merging(reading(candidates: [save, cancel]), into: before, now: now)
        #expect(merged.marks == [1: "w1.2", 2: "w1.3"], "#2 is w1.3, which ui_read never listed")
        #expect(Set(merged.entries.keys) == ["w1", "w1.1", "w1.2", "w1.3"], "the outline's entries are kept and the marks' are added")
        #expect(merged.entries["w1.1"]?.label == "Título")
        #expect(merged.entries["w1.2"]?.frame == save.frame && merged.entries["w1.2"]?.actionable == true, "the outline's entry is completed")
        #expect(merged.takenAt == before.takenAt && merged.generation == 4, "it is still that reading, so its live references stay valid")
        #expect(merged.shot == geometry)
        // The mark numbers of an earlier screenshot give way to the new picture's.
        var older = before
        older.marks = [9: "w1.1"]
        #expect(UISnapshot.merging(reading(candidates: [save]), into: older, now: now).marks == [1: "w1.2"])
    }

    @Test func aReadingThatIsOldOrOfAnotherWindowIsNotMergedWith() {
        let now = Date.now
        let stale = outline(takenAt: now.addingTimeInterval(-61))
        let fresh = UISnapshot.merging(reading(candidates: [save]), into: stale, now: now)
        #expect(Set(fresh.entries.keys) == ["w1.2"] && fresh.takenAt == now && fresh.generation == 5)
        let recent = outline(takenAt: now.addingTimeInterval(-59))
        #expect(UISnapshot.merging(reading(candidates: [save]), into: recent, now: now).entries.count == 3)
        let otherTitle = UISnapshot.merging(reading(candidates: [save], title: "Outro"), into: recent, now: now)
        #expect(Set(otherTitle.entries.keys) == ["w1.2"])
        let otherWindow = UISnapshot.merging(reading(candidates: [save], windowIndex: 2), into: recent, now: now)
        #expect(Set(otherWindow.entries.keys) == ["w1.2"])
        var otherApp = recent
        otherApp.app = AccessibilityApp(name: "Editor", bundleID: "com.example.editor", pid: 555)
        #expect(Set(UISnapshot.merging(reading(candidates: [save]), into: otherApp, now: now).entries.keys) == ["w1.2"])
    }

    @Test func anIdThatNowNamesAnotherElementIsReplacedNotKept() {
        let now = Date.now
        let before = outline(takenAt: now)
        let moved = UIMarkCandidate(id: "w1.2", rawRole: "AXCheckBox", label: "Lembrar", frame: CGRect(x: 20, y: 20, width: 80, height: 24))
        let merged = UISnapshot.merging(reading(candidates: [moved]), into: before, now: now)
        #expect(merged.entries["w1.2"]?.rawRole == "AXCheckBox" && merged.entries["w1.2"]?.label == "Lembrar")
        #expect(merged.entries["w1.1"]?.label == "Título")
    }

    @Test func marksAndGeometrySurviveTheStore() throws {
        let store = UISnapshotStore()
        let snapshot = UISnapshot.merging(reading(candidates: [save, cancel]), into: outline(takenAt: .now))
        store.save(snapshot, bot: nil)
        let loaded = try #require(store.snapshot(bot: nil, app: editor))
        #expect(loaded.marks == [1: "w1.2", 2: "w1.3"] && loaded.shot == geometry)
        #expect(loaded.entries["w1.3"]?.frame == cancel.frame && loaded.entries["w1.3"]?.actionable == true)
        // Saving again with the next screenshot merges with what the store holds.
        let next = UISnapshot.merging(reading(candidates: [cancel]), into: store.snapshot(bot: nil, app: editor))
        #expect(next.marks == [1: "w1.3"] && next.entries.count == 4)
    }

    // MARK: Text recognition

    @Test func autoReadsThePictureOnlyWhenTheTreeNamesFewerThanEightElements() {
        #expect(OCRPolicy.autoThreshold == 8)
        #expect(OCRPolicy.shouldRun(mode: "auto", labeledElements: 7))
        #expect(!OCRPolicy.shouldRun(mode: "auto", labeledElements: 8))
        #expect(OCRPolicy.shouldRun(mode: nil, labeledElements: 0))
        #expect(OCRPolicy.shouldRun(mode: "auto", labeledElements: nil), "no Accessibility, no tree: read the picture")
        #expect(OCRPolicy.shouldRun(mode: "on", labeledElements: 500))
        #expect(!OCRPolicy.shouldRun(mode: "off", labeledElements: 0))
        #expect(OCRPolicy.shouldRun(mode: "whatever", labeledElements: 3))
    }

    @Test func recognizedLinesAreMeasuredInPicturePixelsFromTheTopLeft() {
        let box = TextRecognizer.pixelBox(fromNormalized: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), width: 1_000, height: 500)
        #expect(abs(box.minX - 100) < 1e-9 && abs(box.minY - 100) < 1e-9 && abs(box.width - 200) < 1e-9 && abs(box.height - 50) < 1e-9)
        let lines = [OCRLine(text: "baixo", box: CGRect(x: 10, y: 300, width: 100, height: 20)),
                     OCRLine(text: "direita", box: CGRect(x: 400, y: 12, width: 100, height: 20)),
                     OCRLine(text: "esquerda", box: CGRect(x: 10, y: 10, width: 100, height: 20))]
        let ordered = TextRecognizer.readingOrder(lines)
        #expect(ordered.map(\.text) == ["esquerda", "direita", "baixo"])
        #expect(TextRecognizer.format(ordered) == "(60,20) esquerda\n(450,22) direita\n(60,310) baixo")
    }

    @Test func imagesAreShrunkToTheLongerSideAndNeverEnlarged() throws {
        #expect(ImageScaling.targetSize(width: 3_000, height: 1_500, maxSide: 1_280) == (1_280, 640))
        #expect(ImageScaling.targetSize(width: 800, height: 600, maxSide: 1_280) == (800, 600))
        #expect(ImageScaling.targetSize(width: 600, height: 2_400, maxSide: 640) == (160, 640))
        let image = try screenLikeImage(width: 2_000, height: 1_000)
        let scaled = ImageScaling.scaled(image, maxSide: 1_000)
        #expect(scaled.width == 1_000 && scaled.height == 500)
        #expect(ImageScaling.scaled(image, maxSide: 4_000).width == 2_000)
    }
}
