import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Orb

/// The policies around window capture: the window cache, the two-at-a-time limit, when to fall back to `screencapture`,
/// which window is which, and the `screenshot` tool end to end against fakes. Nothing here captures the real screen.
struct WindowCaptureTests {
    /// Counts calls, safely from several tasks.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var inFlight = 0
        private var peakInFlight = 0
        var count: Int { lock.withLock { value } }
        var peak: Int { lock.withLock { peakInFlight } }
        func bump() { lock.withLock { value += 1 } }
        func begin() { lock.withLock { inFlight += 1; peakInFlight = max(peakInFlight, inFlight); value += 1 } }
        func end() { lock.withLock { inFlight -= 1 } }
    }

    private func window(_ id: UInt32, pid: Int32 = 100, frame: CGRect = CGRect(x: 100, y: 50, width: 400, height: 300), title: String = "Doc",
                        onScreen: Bool = true) -> CapturableWindow {
        CapturableWindow(windowID: id, pid: pid, frame: frame, title: title, isOnScreen: onScreen)
    }

    private func image() throws -> CGImage { try FakeWindowCapturer.image(width: 80, height: 60) }

    private struct Boom: Error {}

    // MARK: Limits

    @Test func theGateRunsAtMostTheLimitAtOnceAndLetsTheRestWait() async throws {
        let gate = AsyncGate(limit: 2)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.run {
                        counter.begin()
                        try await Task.sleep(for: .milliseconds(30))
                        counter.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.count == 8)
        #expect(counter.peak == 2)
        #expect(await gate.peak == 2)
    }

    @Test func aGateWithOnePermitRunsOneAtATimeAndSurvivesAFailure() async throws {
        let gate = AsyncGate(limit: 1)
        let counter = Counter()
        await #expect(throws: Boom.self) { try await gate.run { () async throws -> Int in throw Boom() } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await gate.run { counter.begin(); try await Task.sleep(for: .milliseconds(10)); counter.end() } }
            }
            try await group.waitForAll()
        }
        #expect(counter.peak == 1 && counter.count == 4)
    }

    @Test func theScreenRecordingRequestHappensOnlyOnce() {
        let once = RequestOnce()
        let counter = Counter()
        for _ in 0..<5 { once.fire { counter.bump() } }
        #expect(counter.count == 1)
        #expect(!once.fire { counter.bump() } && counter.count == 1)
        // A tool that finds the permission missing asks every time; the dialog still appears once.
        let access = ScreenCaptureAccess(isGranted: { false }, request: { once.fire { counter.bump() } })
        access.request(); access.request()
        #expect(counter.count == 1)
    }

    // MARK: The capturer

    private func backend(windows: @escaping @Sendable () async throws -> [CapturableWindow] = { [] },
                         primary: @escaping @Sendable (CapturableWindow, Int) async throws -> CGImage,
                         fallback: @escaping @Sendable (CapturableWindow, Int) async throws -> CGImage) -> CaptureBackend {
        CaptureBackend(windows: windows, primary: primary, fallback: fallback)
    }

    @Test func windowsAreListedOncePerCacheLifetimeAndFilteredByPid() async throws {
        let listings = Counter()
        let all = [window(1, pid: 100), window(2, pid: 200), window(3, pid: 100, title: "Outra")]
        func make(_ lifetime: Duration) -> LiveWindowCapturer {
            LiveWindowCapturer(backend: backend(windows: { listings.bump(); return all }, primary: { _, _ in try self.image() },
                                                fallback: { _, _ in try self.image() }), lifetime: lifetime)
        }
        let cached = make(.seconds(60))
        #expect(try await cached.windows(pid: 100).map(\.windowID) == [1, 3])
        #expect(try await cached.windows(pid: 200).map(\.windowID) == [2])
        #expect(try await cached.windows(pid: 300).isEmpty)
        #expect(listings.count == 1, "1.5 s of cache is the design; here a long lifetime proves the cache is used")

        let expired = make(.zero)
        _ = try await expired.windows(pid: 100)
        _ = try await expired.windows(pid: 100)
        #expect(listings.count == 3)
        #expect(LiveWindowCapturer.cacheLifetime == .milliseconds(1_500) && LiveWindowCapturer.maxConcurrentCaptures == 2)
    }

    @Test func theCacheExpiresAfterItsLifetime() async throws {
        let listings = Counter()
        let capturer = LiveWindowCapturer(backend: backend(windows: { listings.bump(); return [] }, primary: { _, _ in try self.image() },
                                                           fallback: { _, _ in try self.image() }), lifetime: .milliseconds(80))
        _ = try await capturer.windows(pid: 1)
        _ = try await capturer.windows(pid: 1)
        #expect(listings.count == 1)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await capturer.windows(pid: 1)
        #expect(listings.count == 2)
    }

    @Test func screenCaptureKitIsTriedFirstAndScreencaptureNotAtAllWhenItWorks() async throws {
        let primary = Counter(), fallback = Counter()
        let capturer = LiveWindowCapturer(backend: backend(primary: { _, _ in primary.bump(); return try self.image() },
                                                           fallback: { _, _ in fallback.bump(); return try self.image() }))
        _ = try await capturer.capture(window(1), maxSide: 1_280)
        #expect(primary.count == 1 && fallback.count == 0)
    }

    @Test func whenScreenCaptureKitFailsScreencaptureTakesOver() async throws {
        let seen = Counter()
        let capturer = LiveWindowCapturer(backend: backend(primary: { _, _ in throw Boom() },
                                                           fallback: { window, maxSide in seen.bump(); #expect(window.windowID == 9 && maxSide == 900); return try self.image() }))
        let picture = try await capturer.capture(window(9), maxSide: 900)
        #expect(picture.width == 80 && seen.count == 1)
    }

    @Test func aMissingPermissionIsReportedNotRetriedAnotherWay() async {
        let fallback = Counter()
        let declined = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        let capturer = LiveWindowCapturer(backend: backend(primary: { _, _ in throw declined }, fallback: { _, _ in fallback.bump(); return try self.image() }))
        do {
            _ = try await capturer.capture(window(1), maxSide: 1_000)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == MacPermissionProblem.screenRecording.modelMessage)
            #expect(fallback.count == 0)
        }
    }

    @Test func aWindowThatClosedIsNotChasedAndAFailingFallbackReportsItsMessage() async {
        let fallback = Counter()
        let gone = LiveWindowCapturer(backend: backend(primary: { window, _ in throw WindowCaptureError.windowGone(window.windowID) },
                                                       fallback: { _, _ in fallback.bump(); return try self.image() }))
        do {
            _ = try await gone.capture(window(5), maxSide: 800)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("fechou"))
        }
        #expect(fallback.count == 0)

        let both = LiveWindowCapturer(backend: backend(primary: { _, _ in throw Boom() }, fallback: { _, _ in throw WindowCaptureError.failed("could not create image from window") }))
        do {
            _ = try await both.capture(window(5), maxSide: 800)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("could not create image from window"))
        }
    }

    @Test func aCancelledTaskDoesNotFallBack() {
        #expect(!CaptureFallbackPolicy.shouldFallBack(after: CancellationError()))
        #expect(CaptureFallbackPolicy.shouldFallBack(after: Boom()))
        #expect(CaptureFallbackPolicy.shouldFallBack(after: NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3802)))
        #expect(!CaptureFallbackPolicy.shouldFallBack(after: NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)))
        #expect(CaptureFallbackPolicy.isPermissionDenied(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)))
        #expect(!CaptureFallbackPolicy.isPermissionDenied(NSError(domain: "other", code: -3801)))
    }

    @Test func atMostTwoCapturesRunAtOnce() async throws {
        let counter = Counter()
        let capturer = LiveWindowCapturer(backend: backend(primary: { _, _ in
            counter.begin()
            try await Task.sleep(for: .milliseconds(40))
            counter.end()
            return try self.image()
        }, fallback: { _, _ in try self.image() }))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<6 { group.addTask { _ = try await capturer.capture(self.window(UInt32(id)), maxSide: 800) } }
            try await group.waitForAll()
        }
        #expect(counter.count == 6 && counter.peak == 2)
    }

    // MARK: Which window is which

    @Test func aWindowIsMatchedByFrameWithinTwoPoints() {
        let a = window(1, frame: CGRect(x: 100, y: 50, width: 400, height: 300), title: "A")
        let b = window(2, frame: CGRect(x: 700, y: 50, width: 400, height: 300), title: "B")
        #expect(WindowMatcher.match(frame: CGRect(x: 101.5, y: 48.5, width: 401, height: 299), title: "", among: [a, b])?.windowID == 1)
        #expect(WindowMatcher.match(frame: CGRect(x: 700, y: 50, width: 400, height: 300), title: "A", among: [a, b])?.windowID == 2, "the frame decides before the title")
        #expect(WindowMatcher.match(frame: CGRect(x: 103, y: 50, width: 400, height: 300), title: "zzz", among: [a, b]) == nil, "3 pt off matches neither, and there are two")
        #expect(WindowMatcher.match(frame: nil, title: "b", among: [a, b])?.windowID == 2, "no frame: the title, ignoring case")
        #expect(WindowMatcher.match(frame: nil, title: "", among: [a, b]) == nil)
        #expect(WindowMatcher.match(frame: nil, title: "", among: []) == nil)
    }

    @Test func windowsOnTheSameSpotAreToldApartByTitleThenByBeingOnScreen() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hidden = window(1, frame: frame, title: "Aba 1", onScreen: false)
        let front = window(2, frame: frame, title: "Aba 2")
        #expect(WindowMatcher.match(frame: frame, title: "Aba 1", among: [hidden, front])?.windowID == 1)
        #expect(WindowMatcher.match(frame: frame, title: "outro", among: [hidden, front])?.windowID == 2, "no title match: the one on screen")
        #expect(WindowMatcher.match(frame: frame, title: "Aba 2", among: [hidden, front])?.windowID == 2)
    }

    @Test func aMovedWindowIsFoundByTitleAndSizeAndALoneWindowByDefault() {
        let a = window(1, frame: CGRect(x: 100, y: 50, width: 400, height: 300), title: "A")
        let b = window(2, frame: CGRect(x: 300, y: 80, width: 500, height: 200), title: "B")
        // The Accessibility frame is stale (the window moved): same size and title still finds it.
        #expect(WindowMatcher.match(frame: CGRect(x: 0, y: 0, width: 500, height: 200), title: "B", among: [a, b])?.windowID == 2)
        #expect(WindowMatcher.match(frame: CGRect(x: 0, y: 0, width: 9, height: 9), title: "?", among: [a])?.windowID == 1, "the app's only window")
    }

    @Test func withoutAccessibilityAWindowIsChosenByPositionTitleOrWhatIsOnScreen() {
        let list = [window(1, title: "Fundo", onScreen: false), window(2, title: "Relatório Anual"), window(3, title: "Notas")]
        #expect(WindowMatcher.choose(from: list, selector: nil)?.windowID == 2)
        #expect(WindowMatcher.choose(from: list, selector: "3")?.windowID == 3)
        #expect(WindowMatcher.choose(from: list, selector: "9") == nil)
        #expect(WindowMatcher.choose(from: list, selector: "relatorio")?.windowID == 2)
        #expect(WindowMatcher.choose(from: list, selector: "nada") == nil)
        #expect(WindowMatcher.choose(from: [list[0]], selector: nil)?.windowID == 1)
    }
}

// MARK: - The screenshot tool

struct ScreenshotToolTests {
    private let windowFrame = CGRect(x: 100, y: 50, width: 400, height: 300)
    private let editor = AccessibilityApp(name: "Editor", bundleID: "com.example.editor", pid: 100)

    private struct Rig {
        var tool: ScreenshotTool
        var system: FakeAccessibility
        var store: UISnapshotStore
        var requests: WindowCaptureTests.Counter
        var folder: URL
    }

    private func frame(_ element: FakeElement, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> FakeElement {
        element.frame = CGRect(x: x, y: y, width: width, height: height)
        return element
    }

    /// An "Editor" app (pid 100) with one window "Doc" at (100, 50) of 400×300, a front app that is the Orb (pid 1) and a
    /// capturable window with the same frame.
    private func rig(trusted: Bool = true, screen: Bool = true, extraLabels: Int = 0, children: [FakeElement]? = nil,
                     sessions: AXSessions = AXSessions(deadlines: .patient)) -> Rig {
        let system = FakeAccessibility()
        system.trusted = trusted
        system.apps = [FakeAccessibility.app("Editor", "com.example.editor", pid: 100), FakeAccessibility.app("Orb", "app.orb", pid: 1, active: true)]
        let content = children ?? [
            frame(fakeButton("Salvar"), 120, 70, 80, 24),                                          // w1.1 -> mark
            frame(fake("AXTextField", title: "Nome", placeholder: "seu nome"), 120, 110, 200, 24), // w1.2 -> mark
            frame(fake("AXStaticText", title: "Rótulo"), 120, 150, 80, 20),                        // w1.3 text
            frame(fakeButton("Mínimo"), 300, 70, 4, 4),                                            // w1.4 too small
            frame(fakeButton("Fora"), 700, 70, 80, 24),                                            // w1.5 outside
            frame(fake("AXButton", title: "Cinza", enabled: false, actions: ["AXPress"]), 120, 190, 80, 24), // w1.6 disabled
        ] + (0..<extraLabels).map { frame(fake("AXStaticText", title: "Texto \($0)"), 120, 220, 60, 12) }
        let window = fake("AXWindow", title: "Doc", content)
        window.frame = windowFrame
        system.roots[100] = fakeApp(windows: [window])
        system.windowCapturer.setWindows([CapturableWindow(windowID: 77, pid: 100, frame: windowFrame, title: "Doc")], pid: 100)
        let requests = WindowCaptureTests.Counter()
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-shots-\(UUID().uuidString)")
        let store = UISnapshotStore(directory: nil)
        let tool = ScreenshotTool(system: system, store: store, screenAccess: ScreenCaptureAccess(isGranted: { screen }, request: { requests.bump() }),
                                  folder: folder, ownPID: 1, frontWindowPID: { _ in 100 }, sessions: sessions)
        return Rig(tool: tool, system: system, store: store, requests: requests, folder: folder)
    }

    private func run(_ rig: Rig, _ arguments: [String: JSONValue] = [:]) async throws -> String {
        var arguments = arguments
        if arguments["ocr"] == nil { arguments["ocr"] = .string("off") } // Vision runs only in the tests about it
        return try await rig.tool.run(.object(arguments), context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
    }

    private func failure(_ body: () async throws -> String) async -> String {
        do { _ = try await body(); return "" } catch { return error.localizedDescription }
    }

    private func path(in report: String) -> String? {
        report.firstMatch(of: /Captura salva em (\S+\.jpg)/).map { String($0.1) }
    }

    // MARK: The spec

    @Test func theSpecKeepsTheWordsTheEconomyTestRequiresAndNamesTheNewArguments() {
        let spec = ScreenshotTool().spec
        let text = spec.description + " " + spec.parameters.jsonString
        for word in ["OCR", "Screen Recording", "window", "marks", "max_side", "ocr", "auto", "#12"] { #expect(text.contains(word), "\(word)") }
        #expect(spec.parameters["required"] == nil)
    }

    @Test func aWindowIsWantedWhenAskedForOrWhenAnAppOrWindowIsNamed() {
        func wants(_ arguments: [String: JSONValue]) -> Bool { ScreenshotTool.wantsWindow(.object(arguments)) }
        #expect(!wants([:]) && !wants(["display": .number(2)]))
        #expect(wants(["target": .string("window")]) && wants(["app": .string("Finder")]) && wants(["window": .number(2)]) && wants(["window": .string("Doc")]))
        #expect(!wants(["target": .string("display"), "app": .string("Finder")]))
        #expect(ScreenshotTool().summary(.object(["app": .string("Notas")])).title == "Capturando a janela")
        #expect(ScreenshotTool().summary(.object([:])).title == "Capturando a tela")
    }

    // MARK: A window with marks

    @Test func aWindowComesBackAsAJPEGWithMarksAndTheirLegend() async throws {
        let rig = rig()
        let report = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        let file = try #require(path(in: report))
        #expect(file.hasPrefix(rig.folder.path) && FileManager.default.fileExists(atPath: file))
        #expect(report.contains("800×600 px, 2 px/pt"), Comment(rawValue: report))
        #expect(report.contains("janela “Doc” de Editor"))
        #expect(report.contains("[1] w1.1 button “Salvar”") && report.contains("[2] w1.2 field “Nome”"))
        #expect(!report.contains("Mínimo") && !report.contains("Fora") && !report.contains("Cinza"), "too small, outside and disabled are not marked")
        #expect(!report.contains("OCR"), "ocr off says nothing about it")
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) && data.count <= 450_000)
        let size = try #require(ScreenshotImage.pixelSize(of: URL(fileURLWithPath: file)))
        #expect(size.width == 800 && size.height == 600)
        #expect(rig.system.windowCapturer.captures == [FakeWindowCapturer.Capture(windowID: 77, maxSide: 1_280)])
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func theSnapshotKeepsTheMarksTheGeometryAndTheFramesForUiAct() async throws {
        let rig = rig()
        _ = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        let snapshot = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(snapshot.marks == [1: "w1.1", 2: "w1.2"])
        let shot = try #require(snapshot.shot)
        #expect(shot.windowID == 77 && shot.scale == 2 && shot.pixelWidth == 800 && shot.pixelHeight == 600 && shot.windowFrame == windowFrame)
        #expect(snapshot.windowIndex == 1 && snapshot.windowTitle == "Doc")
        #expect(snapshot.entries["w1.1"]?.frame == CGRect(x: 20, y: 20, width: 80, height: 24))
        #expect(snapshot.entries["w1.1"]?.label == "Salvar" && snapshot.entries["w1.1"]?.actionable == true)
        // A click at pixel (100, 100) of the picture is at (50, 50) in the window and (150, 100) on screen.
        #expect(shot.windowPoint(fromPixel: CGPoint(x: 100, y: 100)) == CGPoint(x: 50, y: 50))
        #expect(shot.globalPoint(fromPixel: CGPoint(x: 100, y: 100)) == CGPoint(x: 150, y: 100))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func aScreenshotAfterAUiReadMergesWithItsSnapshot() async throws {
        let rig = rig()
        let read = UIReadTool(system: rig.system, store: rig.store)
        _ = try await read.run(.object(["app": .string("Editor")]), context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        let outline = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(outline.marks.isEmpty && outline.shot == nil && outline.entries["w1.3"]?.label == "Rótulo")

        _ = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        let merged = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(merged.marks == [1: "w1.1", 2: "w1.2"] && merged.shot?.windowID == 77)
        #expect(merged.entries["w1.3"]?.label == "Rótulo", "the ui_read entries are still there")
        #expect(merged.entries["w1.1"]?.frame != nil, "and the marked ones gained their frames")
        #expect(merged.takenAt == outline.takenAt && merged.generation == outline.generation)
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func marksOffGivesTheImageAloneAndLeavesTheSnapshotUntouched() async throws {
        let rig = rig()
        let report = try await run(rig, ["app": .string("Editor"), "marks": .bool(false), "ocr": .string("off")])
        #expect(path(in: report) != nil && !report.contains("[1]") && !report.contains("Marcas"))
        #expect(rig.store.snapshot(bot: nil, app: editor) == nil)
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func maxSideIsPassedToTheCapturerAndKeptBetween640And1568() async throws {
        let rig = rig()
        for (given, expected) in [(nil, 1_280), (1_000, 1_000), (100, 640), (5_000, 1_568)] as [(Int?, Int)] {
            var arguments: [String: JSONValue] = ["app": .string("Editor"), "ocr": .string("off"), "marks": .bool(false)]
            if let given { arguments["max_side"] = .number(Double(given)) }
            _ = try await run(rig, arguments)
            #expect(rig.system.windowCapturer.captures.last?.maxSide == expected)
        }
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func theWindowIsPickedLikeUiReadPicksIt() async throws {
        let rig = rig()
        let second = fake("AXWindow", title: "Segunda", [frame(fakeButton("Outro"), 640, 90, 80, 24)])
        second.frame = CGRect(x: 600, y: 50, width: 300, height: 200)
        let first = try #require(rig.system.roots[100]?.attrs["AXWindows"]?.elements?.first)
        rig.system.roots[100]?.attrs["AXWindows"] = .elements([first, second])
        rig.system.windowCapturer.setWindows([CapturableWindow(windowID: 77, pid: 100, frame: windowFrame, title: "Doc"),
                                              CapturableWindow(windowID: 78, pid: 100, frame: second.frame!, title: "Segunda")], pid: 100)
        let report = try await run(rig, ["app": .string("Editor"), "window": .string("segunda"), "ocr": .string("off")])
        #expect(report.contains("janela “Segunda”") && report.contains("[1] w2.1 button “Outro”"))
        #expect(rig.system.windowCapturer.captures.last?.windowID == 78)
        let byNumber = try await run(rig, ["app": .string("Editor"), "window": .number(1), "ocr": .string("off")])
        #expect(byNumber.contains("w1.1") && rig.system.windowCapturer.captures.last?.windowID == 77)
        let snapshot = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(snapshot.windowIndex == 1)
        let bad = await failure { try await run(rig, ["app": .string("Editor"), "window": .number(7)]) }
        #expect(bad.contains("2 janelas"))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func withoutAnAppItTakesTheFrontWindowOfAnotherApp() async throws {
        let rig = rig()
        let report = try await run(rig, ["target": .string("window"), "ocr": .string("off")])
        #expect(report.contains("de Editor") && report.contains("[1] w1.1"))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func anUnknownAppAndAnAmbiguousOneAreExplained() async {
        let rig = rig()
        rig.system.apps.append(FakeAccessibility.app("Editor de Texto", "com.example.text", pid: 300))
        #expect(await failure { try await run(rig, ["app": .string("Fantasma")]) }.contains("Não há nenhum app aberto chamado"))
        #expect(await failure { try await run(rig, ["app": .string("Edit")]) }.contains("vários apps"))
    }

    @Test func aWindowTheCapturerCannotSeeListsWhatItCan() async {
        let rig = rig()
        rig.system.windowCapturer.setWindows([CapturableWindow(windowID: 5, pid: 100, frame: CGRect(x: 900, y: 900, width: 50, height: 50), title: "Outra"),
                                              CapturableWindow(windowID: 6, pid: 100, frame: CGRect(x: 0, y: 0, width: 60, height: 60), title: "Mais")], pid: 100)
        let message = await failure { try await run(rig, ["app": .string("Editor")]) }
        #expect(message.contains("“Outra”") && message.contains("“Mais”"), Comment(rawValue: message))
        rig.system.windowCapturer.setWindows([], pid: 100)
        #expect(await failure { try await run(rig, ["app": .string("Editor")]) }.contains("nenhuma janela que possa ser capturada"))
    }

    // MARK: OCR

    @Test func autoOCRReadsThePictureWhenTheTreeNamesFewElementsAndSkipsItWhenItNamesMany() async throws {
        let few = rig()
        let withOCR = try await run(few, ["app": .string("Editor"), "ocr": .string("auto")])
        #expect(withOCR.contains("Não achei texto legível na imagem."), "the fake picture is a gradient without text, but OCR ran")
        let many = rig(extraLabels: 10)
        let without = try await run(many, ["app": .string("Editor"), "ocr": .string("auto")])
        #expect(!without.contains("legível") && !without.contains("(OCR)"))
        let forced = try await run(many, ["app": .string("Editor"), "ocr": .string("on")])
        #expect(forced.contains("legível"))
        let off = try await run(few, ["app": .string("Editor"), "ocr": .string("off")])
        #expect(!off.contains("legível"))
        try? FileManager.default.removeItem(at: few.folder)
        try? FileManager.default.removeItem(at: many.folder)
    }

    // MARK: Without a permission

    @Test func withoutScreenRecordingTheLegendComesAloneAndTheRequestIsMadeOnce() async throws {
        let rig = rig(screen: false)
        let report = try await run(rig, ["app": .string("Editor")])
        #expect(report.contains("Sem imagem") && report.contains("Screen Recording") && report.contains("[1] w1.1 button “Salvar”"))
        #expect(report.contains("Ajustes do Sistema → Privacidade e Segurança"), "the permission button can be offered")
        #expect(!report.contains("Captura salva"))
        #expect(rig.system.windowCapturer.captures.isEmpty)
        #expect(rig.requests.count == 1)
        let snapshot = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(snapshot.marks == [1: "w1.1", 2: "w1.2"] && snapshot.shot == nil, "#n still works; x,y has no picture to refer to")
        let capture = ScreenshotTool.Capture(header: "h", ocr: "", file: nil, legend: "l", ocrSkipped: true)
        #expect(capture.report(ocrLimit: 100) == "h\nl")
    }

    @Test func withoutAccessibilityThereIsOnlyTheImage() async throws {
        let rig = rig(trusted: false)
        let report = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        #expect(path(in: report) != nil)
        #expect(report.contains("Sem marcas") && report.contains("Acessibilidade") && !report.contains("[1]"))
        #expect(rig.system.rootCalls == 0, "the Accessibility API is never touched")
        #expect(rig.store.snapshot(bot: nil, app: editor) == nil)
        #expect(rig.system.windowCapturer.captures.last?.windowID == 77)
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func withNeitherPermissionTheCallFailsWithScreenRecordingAdvice() async {
        let rig = rig(trusted: false, screen: false)
        let message = await failure { try await run(rig, ["app": .string("Editor")]) }
        #expect(message == MacPermissionProblem.screenRecording.modelMessage)
        #expect(rig.requests.count == 1)
    }

    @Test func aFailedCaptureStillGivesTheLegendWhenTheTreeWasRead() async throws {
        let rig = rig()
        rig.system.windowCapturer.error = ToolError("could not create image from window")
        let report = try await run(rig, ["app": .string("Editor")])
        #expect(report.contains("Não consegui capturar a imagem") && report.contains("[1] w1.1"))
        #expect(!report.contains("Captura salva"))
        // Without marks there is nothing to give: the error stands.
        let message = await failure { try await run(rig, ["app": .string("Editor"), "marks": .bool(false)]) }
        #expect(message.contains("could not create image"))
    }

    @Test func aMinimizedWindowHasNoPictureButStillHasMarks() async throws {
        let rig = rig()
        let window = try #require(rig.system.roots[100]?.attrs["AXWindows"]?.elements?.first as? FakeElement)
        window.attrs["AXMinimized"] = .bool(true)
        let report = try await run(rig, ["app": .string("Editor")])
        #expect(report.contains("minimizada") && report.contains("Sem imagem"))
        #expect(rig.system.windowCapturer.captures.isEmpty)
    }

    @Test func aHungAppIsNamedAndTheMarksSoFarAreKept() async throws {
        let rig = rig(children: [frame(fakeButton("Salvar"), 120, 70, 80, 24), { let stuck = fakeButton("Preso"); stuck.failures["*"] = .cannotComplete; stuck.frame = CGRect(x: 120, y: 110, width: 80, height: 24); return stuck }()])
        let report = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        #expect(report.contains("não respondeu") && report.contains("incompletas") && report.contains("[1] w1.1 button “Salvar”"))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func aHungAppCostsOnlyTheMarksAndTheNextCallFailsAtOnce() async throws {
        // The window and the marks are read through the app's session, with its deadline: a hung app does not hold the
        // screenshot (nor a thread of the cooperative pool) until it answers, and while that call is out the next fails at once.
        let short = AXDeadlines(read: .milliseconds(150), readWithQuery: .milliseconds(150), action: .milliseconds(150))
        let rig = rig(sessions: AXSessions(deadlines: short))
        let root = try #require(rig.system.roots[100])
        // Long enough that a busy machine running the whole suite still sees the difference (before: ≥ 15 s per call).
        root.stall = .seconds(15)
        let clock = ContinuousClock()
        let begin = clock.now
        let report = try await run(rig, ["app": .string("Editor")])
        #expect(begin.duration(to: clock.now) < .seconds(10))
        #expect(report.contains("Captura salva") && report.contains("Sem marcas") && report.contains("não respondeu"))
        let again = clock.now
        let second = try await run(rig, ["app": .string("Editor")])
        #expect(again.duration(to: clock.now) < .seconds(5))
        #expect(second.contains("Captura salva") && second.contains("ainda está ocupado"))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func aWindowWithNothingToClickSaysSo() async throws {
        let rig = rig(children: [frame(fake("AXStaticText", title: "Só texto"), 120, 70, 80, 24)])
        let report = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        #expect(report.contains("Nenhum elemento clicável"))
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func thePictureAndTheLegendAreWithinTheirBudgets() async throws {
        // 70 buttons: the picture marks 60 and the legend names what fits in 4,000 characters.
        let buttons = (0..<70).map { frame(fakeButton("Botão número \($0) com um nome bem comprido para encher a legenda"), 110 + CGFloat($0 % 5) * 75, 60 + CGFloat($0 / 5) * 20, 70, 18) }
        let rig = rig(children: buttons)
        let report = try await run(rig, ["app": .string("Editor"), "ocr": .string("off")])
        let legend = try #require(report.components(separatedBy: "Marcas (").last)
        #expect(legend.contains("60 de 70 elementos acionáveis"))
        let snapshot = try #require(rig.store.snapshot(bot: nil, app: editor))
        #expect(snapshot.marks.count == 60)
        try? FileManager.default.removeItem(at: rig.folder)
    }
}

extension ScreenshotToolTests {
    @Test func theOrbsOwnWindowIsPhotographedButItsInterfaceIsNotRead() async throws {
        let rig = rig()
        rig.system.windowCapturer.setWindows([CapturableWindow(windowID: 5, pid: 1, frame: CGRect(x: 0, y: 0, width: 300, height: 200), title: "Orb")], pid: 1)
        let report = try await run(rig, ["app": .string("Orb"), "ocr": .string("off")])
        #expect(report.contains("Captura salva") && report.contains("não lê a própria interface") && !report.contains("[1]"))
        #expect(rig.system.rootCalls == 0)
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @Test func theFrontWindowSearchSkipsTheOrbAndEveryProcessOfItsBundle() {
        let windows = [WindowCandidate(id: 1, pid: 1, layer: 0, width: 900, height: 700, alpha: 1),
                       WindowCandidate(id: 2, pid: 50, layer: 0, width: 900, height: 700, alpha: 1),
                       WindowCandidate(id: 3, pid: 100, layer: 0, width: 900, height: 700, alpha: 1)]
        #expect(WindowCandidate.front(in: windows, excludingPIDs: [1, 50])?.pid == 100)
        #expect(WindowCandidate.front(in: windows, excludingPIDs: [])?.pid == 1)
        #expect(WindowCandidate.front(in: windows, excludingPIDs: [1, 50, 100]) == nil)
    }
}

// MARK: - Smoke test against the real screen

/// Captures a real Finder window while another window covers it. Off by default; needs Screen Recording for the process that
/// runs the tests: `ORB_AX_SMOKE=1 swift test --filter WindowCaptureSmokeTests`.
@Suite(.serialized)
struct WindowCaptureSmokeTests {
    private static let enabled = ProcessInfo.processInfo.environment["ORB_AX_SMOKE"] == "1" && CGPreflightScreenCaptureAccess()

    @Test(.enabled(if: WindowCaptureSmokeTests.enabled), .timeLimit(.minutes(1)))
    @MainActor
    func anOccludedFinderWindowIsCapturedWithItsOwnPixels() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let capturer = LiveWindowCapturer(backend: .screenCaptureKit)
        func usefulWindow() async throws -> CapturableWindow? {
            // A capturer of its own each time: the shared one would answer from its 1.5 s cache.
            try await LiveWindowCapturer(backend: .screenCaptureKit).windows(pid: finder.processIdentifier)
                .first { $0.isOnScreen && $0.frame.width >= 300 && $0.frame.height >= 200 }
        }
        var found = try await usefulWindow()
        if found == nil {
            // No Finder window open: open one on the temporary folder (the smoke is opt-in, so this is expected).
            NSWorkspace.shared.open(FileManager.default.temporaryDirectory)
            for _ in 0..<20 where found == nil {
                try await Task.sleep(for: .milliseconds(250))
                found = try await usefulWindow()
            }
        }
        let target = try #require(found, "Finder has no window of a useful size")

        // Cover it with a flat magenta window above everything: a screen grab would show magenta, the window's own pixels will not.
        _ = NSApplication.shared
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cover = NSWindow(contentRect: DisplayLayout.appKitRect(fromScreen: target.frame, mainDisplayHeight: mainHeight),
                             styleMask: .borderless, backing: .buffered, defer: false)
        cover.level = .screenSaver
        cover.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        cover.isOpaque = true
        cover.ignoresMouseEvents = true
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))

        // Proof that the cover is in front: in the on-screen list (front to back) it comes before the Finder window.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let coverIndex = order.firstIndex(of: UInt32(cover.windowNumber))
        let finderIndex = order.firstIndex(of: target.windowID)
        #expect(coverIndex != nil && finderIndex != nil && coverIndex! < finderIndex!, "the Finder window is not covered, so the test proves nothing")

        let clock = ContinuousClock()
        let started = clock.now
        let picture = try await capturer.capture(target, maxSide: 1_280)
        let cold = started.duration(to: clock.now)
        var warm = Duration.seconds(100)
        for _ in 0..<5 {
            let begin = clock.now
            _ = try await capturer.capture(target, maxSide: 1_280)
            warm = min(warm, begin.duration(to: clock.now))
        }
        print("smoke capture: first \(cold), best of 5 later \(warm), \(picture.width)x\(picture.height) for a \(target.frame.size) pt window")

        if let path = ProcessInfo.processInfo.environment["ORB_SMOKE_SAVE"], let data = ScreenshotJPEG.encode(picture) {
            try data.write(to: URL(fileURLWithPath: path))
            // The overlay on a real picture, with marks laid out by hand, to look at.
            let geometry = ShotGeometry(imageWidth: picture.width, imageHeight: picture.height, windowFrame: target.frame, windowID: target.windowID)
            let spots = [CGRect(x: 20, y: 8, width: 120, height: 26), CGRect(x: 40, y: 60, width: 200, height: 30), CGRect(x: 300, y: 90, width: 10, height: 10),
                         CGRect(x: 500, y: 20, width: 200, height: 30), CGRect(x: 400, y: 200, width: 100, height: 100), CGRect(x: 890, y: 410, width: 40, height: 40)]
            let marks = spots.enumerated().map { index, frame in
                UIMark(number: index * 11 + 1, candidate: UIMarkCandidate(id: "w1.\(index + 1)", rawRole: "AXButton", label: "x", frame: frame), visibleFrame: frame)
            }
            if let drawn = UIOverlay.render(picture, marks: marks, geometry: geometry), let marked = ScreenshotJPEG.encode(drawn) {
                try marked.write(to: URL(fileURLWithPath: path + ".overlay.jpg"))
            }
        }
        #expect(max(picture.width, picture.height) <= 1_280 && picture.width > 100)
        #expect(!ScreenshotImage.isBlank(picture), "a blank picture is a missing permission or an unreadable window")
        #expect(magentaShare(picture) < 0.2, "the cover must not be in the picture")
    }

    /// The whole tool on a real Finder window: the tree gives the marks, the picture gets them drawn, and the snapshot keeps
    /// them. Needs Accessibility too; `ORB_SMOKE_SAVE` names a file for the picture.
    @Test(.enabled(if: WindowCaptureSmokeTests.enabled && AXIsProcessTrusted()), .timeLimit(.minutes(1)))
    func theToolMarksARealFinderWindow() async throws {
        let store = UISnapshotStore(directory: nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = ScreenshotTool(system: LiveAccessibilitySystem(), store: store, folder: folder)
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let clock = ContinuousClock()
        let started = clock.now
        let report = try await tool.run(.object(["app": .string("Finder"), "ocr": .string("auto")]), context: context)
        print("smoke screenshot tool: \(started.duration(to: clock.now))\n\(report.prefix(1_800))")
        let path = try #require(report.firstMatch(of: /Captura salva em (\S+\.jpg)/).map { String($0.1) })
        if let save = ProcessInfo.processInfo.environment["ORB_SMOKE_SAVE"] {
            try? FileManager.default.removeItem(atPath: save + ".marks.jpg")
            try FileManager.default.copyItem(atPath: path, toPath: save + ".marks.jpg")
        }
        let app = try #require(store.candidates(matching: "Finder").first).app
        let snapshot = try #require(store.snapshot(bot: nil, app: app))
        #expect(snapshot.shot != nil && !snapshot.marks.isEmpty, "Finder's window has controls")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count <= 450_000)
    }

    /// The fraction of pixels close to the cover's colour (sampled on a coarse grid).
    private func magentaShare(_ image: CGImage) -> Double {
        let width = 64, height = 64
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hits = 0
        for index in stride(from: 0, to: data.count, by: 4) where data[index] > 230 && data[index + 1] < 40 && data[index + 2] > 230 { hits += 1 }
        return Double(hits) / Double(width * height)
    }
}
