import AppKit
import ApplicationServices
import Foundation
import ImageIO
import Testing
@testable import Orb

// The live tools (ui_read, ui_act, screenshot) against a real app: `OrbAXFixture`, an AppKit app that never activates itself
// and logs what it received. Needs the Accessibility permission for whatever runs the tests, and is off unless asked:
//
//   ORB_AX_SMOKE=1                 these tests
//   ORB_AX_TAKEOVER=1              also the ones that really take the screen over (the cursor jumps, an app comes forward)
//   ORB_AX_SMOKE_SYSTEM=1          also a read-only look at Finder
//   (Screen Recording, for the capture ones, is checked with CGPreflightScreenCaptureAccess)
//
// Do not touch the mouse or keyboard while they run: "nothing changed on the person's desk" is what most of them check
// (a check during which the person did move the mouse, click or type is reported as a known issue, not as a failure).
//
// Time budgets are the design's for a release build (`swift test -c release -Xswiftc -enable-testing`, which `@testable`
// needs); a debug build gets them × `AXSmoke.budgetFactor`.
// Tests marked `WP-A` or `WP-B` below were written against docs/USO-DO-COMPUTADOR.md before those packages landed and pass
// only with them; the rest run on what exists.

enum AXSmoke {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ORB_AX_SMOKE"] == "1" && AXIsProcessTrusted() }
    static var takeover: Bool { ProcessInfo.processInfo.environment["ORB_AX_TAKEOVER"] == "1" }
    static var system: Bool { ProcessInfo.processInfo.environment["ORB_AX_SMOKE_SYSTEM"] == "1" }
    static var capture: Bool { CGPreflightScreenCaptureAccess() }
    static let appName = "OrbAXFixture"

    /// How much slower a debug build may be. The design's budgets are for the release build the app ships as. In a debug
    /// build the Orb's own work runs unoptimized: measured on this Mac, an outline of 1,200 elements takes 22 ms against
    /// 11 ms, drawing and encoding a 1520×1336 JPEG 6 ms against 5 ms, and the async plumbing around each call is slower
    /// too. Most of every budget is the other side (the app answering Accessibility, ScreenCaptureKit, the window server),
    /// which is the same in both builds, so the whole call is far less than 2× slower: 1.6 covers it with room to spare.
    static let budgetFactor: Double = {
        #if DEBUG
        1.6
        #else
        1
        #endif
    }()

    /// A budget in milliseconds for this build.
    static func budget(_ releaseMilliseconds: Double) -> Double { releaseMilliseconds * budgetFactor }
    static func budget(_ release: Duration) -> Duration { release * budgetFactor }
}

// MARK: - The fixture

/// A running `OrbAXFixture`, with what it logged.
final class FixtureApp: @unchecked Sendable {
    let child: ChildProcess
    let pid: Int32
    /// The center of its canvas in screen points (origin at the top left of the main display).
    let canvasCenter: CGPoint
    /// The same point in points from the window's top left corner (title bar included): where a screenshot of the window has it.
    let canvasInWindow: CGPoint
    let frame: CGRect

    private init(child: ChildProcess, ready: JSONValue) {
        self.child = child
        func number(_ value: JSONValue?) -> Double { if case .number(let n)? = value { n } else { 0 } }
        let center = ready["canvasCenter"]?.array ?? []
        let box = ready["frame"]?.array ?? []
        let inWindow = ready["canvasInWindow"]?.array ?? []
        pid = Int32(number(ready["pid"]))
        canvasCenter = CGPoint(x: number(center.first), y: number(center.last))
        canvasInWindow = CGPoint(x: number(inWindow.first), y: number(inWindow.last))
        frame = CGRect(x: number(box.first), y: number(box.dropFirst().first), width: number(box.dropFirst(2).first), height: number(box.last))
    }

    static func launch() async throws -> FixtureApp {
        guard let binary = BuiltProduct.url("OrbAXFixture") else { throw ToolError("O OrbAXFixture não foi compilado (swift build).") }
        let child = try ChildProcess(binary, [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let ready = child.replies.first(where: { $0["event"]?.string == "ready" }) {
                // Let the window reach the screen before anything captures it.
                try await Task.sleep(for: .milliseconds(500))
                return FixtureApp(child: child, ready: ready)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ToolError("O OrbAXFixture não ficou pronto em 30 s.")
    }

    var logged: [JSONValue] { child.replies }
    func events(_ name: String) -> [JSONValue] { logged.filter { $0["event"]?.string == name } }

    /// The first matching event logged after `index` events, waiting up to `timeout`.
    func waitFor(_ name: String, timeout: Duration = .seconds(3), where matches: (JSONValue) -> Bool = { _ in true }) async -> JSONValue? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let found = events(name).last(where: matches) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return events(name).last(where: matches)
    }

    func send(_ command: String) { child.sendLine(command) }
    func stop() {
        kill(pid, SIGCONT)
        send("quit")
        child.closeInput()
    }
}

/// What the person would notice: which app is in front, and where the cursor is.
struct Desk {
    var frontPID: Int32?
    var cursor: CGPoint

    static func now() -> Desk {
        Desk(frontPID: LiveTakeoverPlatform().frontmost()?.pid, cursor: CGEvent(source: nil)?.location ?? .zero)
    }

    func distance(to other: Desk) -> CGFloat { hypot(cursor.x - other.cursor.x, cursor.y - other.cursor.y) }

    /// Seconds since the person last moved the mouse, clicked or typed, from the hardware's own events (`hidSystemState`:
    /// the events the tools send to a process are not among them).
    static func secondsSincePersonActed() -> TimeInterval {
        let kinds: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
}

/// Whether the person used the mouse or keyboard during the `seconds` that just passed: then a moved cursor or another
/// app in front may be theirs, and the check says nothing about the tools.
func personActed(within seconds: TimeInterval, idle: TimeInterval = Desk.secondsSincePersonActed()) -> Bool {
    idle < seconds
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))]
}

/// The tools, called the way the engines call them.
struct SmokeSession {
    let fixture: FixtureApp
    var context: ToolContext

    init(_ fixture: FixtureApp) {
        self.fixture = fixture
        context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.botID = UUID()
        context.computerUseAllowed = true
        context.acceptsImages = true
        context.imageStore = ImageStore(directory: FileManager.default.temporaryDirectory.appending(path: "OrbAXSmoke-\(UUID().uuidString)"))
    }

    func tool(_ name: String) throws -> any AgentTool {
        guard let tool = ToolBox.macTools.first(where: { $0.spec.name == name }) else { throw ToolError("Ferramenta \(name) não existe.") }
        return tool
    }

    @discardableResult
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> String {
        var arguments = arguments
        if arguments["app"] == nil { arguments["app"] = .string(AXSmoke.appName) }
        return try await tool(name).run(.object(arguments), context: context)
    }

    func read(_ extra: [String: JSONValue] = [:]) async throws -> String { try await call("ui_read", extra) }
    func act(_ action: String, _ extra: [String: JSONValue] = [:]) async throws -> String {
        try await call("ui_act", ["action": .string(action)].merging(extra) { $1 })
    }

    /// The id (first word) of the first line of a reading that contains `needle`.
    func id(of needle: String, in reading: String) throws -> String {
        guard let line = reading.split(separator: "\n").first(where: { $0.contains(needle) }),
              let id = line.split(separator: " ", omittingEmptySubsequences: true).first
        else { throw ToolError("Não achei \"\(needle)\" na leitura:\n\(reading.prefix(1_500))") }
        return String(id)
    }

    func capture(_ extra: [String: JSONValue] = [:]) async throws -> ToolResult {
        var arguments = extra
        if arguments["app"] == nil { arguments["app"] = .string(AXSmoke.appName) }
        if arguments["target"] == nil { arguments["target"] = .string("window") }
        return try await tool("screenshot").runWithImages(.object(arguments), context: context)
    }
}

/// Runs `body` and checks the person's desk is as it was: same app in front, cursor within 2 points, and the fixture never
/// became the active app. Strict while the person keeps still; when they moved the mouse, clicked or typed meanwhile, a
/// difference may be theirs, and it is recorded as a known issue (inconclusive) instead of a failure.
private func expectUndisturbed(_ fixture: FixtureApp, _ comment: Comment, _ body: () async throws -> Void) async throws {
    let before = Desk.now()
    let started = ContinuousClock.now
    try await body()
    try await Task.sleep(for: .milliseconds(150))
    let after = Desk.now()
    let spent = started.duration(to: .now)
    let seconds = Double(spent.components.seconds) + Double(spent.components.attoseconds) / 1e18 + 0.05
    let disturbed = after.frontPID != before.frontPID || after.distance(to: before) > 2 || !fixture.events("activated").isEmpty
    if disturbed, personActed(within: seconds) {
        withKnownIssue("Inconclusivo: a pessoa mexeu no mouse ou no teclado durante \(comment); o cursor andou \(Int(after.distance(to: before))) pt.",
                       isIntermittent: true) {
            Issue.record("desk changed while the person was using it: \(comment)")
        }
        return
    }
    #expect(after.frontPID == before.frontPID, comment)
    #expect(after.distance(to: before) <= 2, comment)
    #expect(fixture.events("activated").isEmpty, "the fixture must not have become the active app: \(comment)")
}

private func text(_ event: JSONValue?, _ key: String) -> String? { event?[key]?.string }
private func number(_ event: JSONValue?, _ key: String) -> Double? { if case .number(let n)? = event?[key] { n } else { nil } }

// MARK: - Smoke

@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: AXSmoke.enabled))
struct AXSmokeTests {
    // MARK: Works with the code that exists

    @Test func readingTheFixtureShowsItsControlsAndNeverTheSecret() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        try await expectUndisturbed(fixture, "ui_read") {
            let reading = try await session.read()
            #expect(reading.contains("Somar") && reading.contains("Mudar depois") && reading.contains("Contagem: 0"))
            #expect(reading.contains("Nome") && reading.contains("Senha"))
            let secret = try session.id(of: "Senha", in: reading)
            #expect(!secret.isEmpty)
            let line = reading.split(separator: "\n").first { $0.contains("Senha") && ($0.contains("field") || $0.contains("campo")) }
            #expect(line.map { $0.contains("<oculto>") || !$0.contains("value=") } ?? true, "a password field has no readable value")
        }
    }

    @Test func pressingAButtonDoesNotMoveTheFrontAppOrTheCursor() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let reading = try await session.read()
        let button = try session.id(of: "button “Somar”", in: reading)
        try await expectUndisturbed(fixture, "press") {
            _ = try await session.act("press", ["id": .string(button)])
        }
        let logged = await fixture.waitFor("button") { text($0, "name") == "Somar" }
        #expect(number(logged, "count") == 1)
    }

    @Test func setValueFillsTheFieldAndTheReadingShowsIt() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let reading = try await session.read()
        let field = try session.id(of: "field “Nome”", in: reading)
        try await expectUndisturbed(fixture, "set_value") {
            _ = try await session.act("set_value", ["id": .string(field), "value": .string("Ana Souza")])
        }
        #expect(try await session.read().contains("Ana Souza"))
    }

    @Test func aStoppedAppDoesNotHangTheReader() async throws {
        // WP-A: the first failed call ends the reading (cut `.hung`) within the messaging timeout.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        _ = try await session.read()
        kill(fixture.pid, SIGSTOP)
        defer { kill(fixture.pid, SIGCONT) }
        let clock = ContinuousClock()
        let begin = clock.now
        _ = try? await session.read()
        #expect(begin.duration(to: clock.now) <= .milliseconds(1_500), "ui_read returns within 1.5 s of a stopped app")
    }

    @Test func aCallPastItsDeadlineLeavesTheSessionBusyAndTheNextOneFailsAtOnce() async throws {
        // WP-A: a deadline shorter than the 1 s messaging timeout, so the call to the stopped app is still out when the next
        // one comes: that one must fail at once ("ainda está ocupado"), not wait on the app again.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let sessions = AXSessions(deadlines: AXDeadlines(read: .milliseconds(300), readWithQuery: .milliseconds(300), action: .milliseconds(300)))
        let reader = UIReadTool(system: LiveAccessibilitySystem(), store: UISnapshotStore(directory: nil), sessions: sessions, live: UILiveElements())
        let context = SmokeSession(fixture).context
        let arguments = JSONValue.object(["app": .string(AXSmoke.appName)])
        _ = try await reader.run(arguments, context: context)
        kill(fixture.pid, SIGSTOP)
        defer { kill(fixture.pid, SIGCONT) }
        let clock = ContinuousClock()
        let begin = clock.now
        var first = ""
        do { _ = try await reader.run(arguments, context: context) } catch { first = error.localizedDescription }
        #expect(first.contains("não respondeu"), "the first call hits its deadline: \(first)")
        #expect(begin.duration(to: clock.now) <= .milliseconds(800), "the 300 ms deadline, plus finding the app by name")
        let again = clock.now
        var second = ""
        do { _ = try await reader.run(arguments, context: context) } catch { second = error.localizedDescription }
        #expect(clock.now - again <= .milliseconds(200), "the second call fails at once")
        #expect(second.contains("ainda está ocupado"), "because the session is busy: \(second)")
    }

    // MARK: Needs WP-A (sessions, events, the ladder)

    @Test func typingGoesToTheFieldAndNotToTheFocusOfThePerson() async throws {
        // WP-A: `focus` then `type` through events sent to the process.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let field = try session.id(of: "field “Nome”", in: try await session.read())
        try await expectUndisturbed(fixture, "type") {
            _ = try await session.act("focus", ["id": .string(field)])
            _ = try await session.act("type", ["value": .string("Olá, mundo")])
        }
        let logged = await fixture.waitFor("text") { text($0, "field") == "Nome" && text($0, "value") == "Olá, mundo" }
        #expect(logged != nil)
    }

    @Test func aPasswordFieldIsTypedIntoOnlyWhenNamedAndOnlyItsLengthIsEverLogged() async throws {
        // WP-A: typing "into the focused field" cannot be judged before running; the real NSSecureTextField must be seen as a
        // password field then and refused (the card did not say so). Named by id, the card asks first, and then it goes.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let secret = try session.id(of: "field “Senha”", in: try await session.read())
        _ = try await session.act("focus", ["id": .string(secret)])
        let blind: [String: JSONValue] = ["action": .string("type"), "value": .string("abc123"), "app": .string(AXSmoke.appName)]
        #expect(try session.tool("ui_act").danger(.object(blind)) == nil, "the card cannot tell: it names no field")
        var refusal = ""
        do { _ = try await session.act("type", ["value": .string("abc123")]) } catch { refusal = error.localizedDescription }
        #expect(refusal.contains("campo de senha"), "the focused NSSecureTextField is recognized at run time: \(refusal)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.events("text").allSatisfy { text($0, "field") != "Senha" }, "nothing reached the password field")

        let named: [String: JSONValue] = ["action": .string("type"), "id": .string(secret), "value": .string("abc123"), "app": .string(AXSmoke.appName)]
        #expect(try session.tool("ui_act").danger(.object(named))?.contains("senha") == true, "named, the card says it is a password field")
        _ = try await session.act("type", ["id": .string(secret), "value": .string("abc123")])
        let logged = await fixture.waitFor("text") { text($0, "field") == "Senha" && number($0, "length") == 6 }
        #expect(logged != nil)
        #expect(!(try await session.read()).contains("abc123"))
    }

    @Test func selectingARowDoesNotDisturbTheDesk() async throws {
        // WP-A: `select` on the row (the reading's line is its cell's text): the table's `AXSelectedRows`, else the row's
        // `AXSelected`, read back before saying it is done.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let row = try session.id(of: "Linha 5", in: try await session.read(["query": .string("Linha 5")]))
        try await expectUndisturbed(fixture, "select") { _ = try await session.act("select", ["id": .string(row)]) }
        let logged = await fixture.waitFor("select") { number($0, "row") == 5 }
        #expect(logged != nil)
    }

    @Test func scrollingTheTallAreaDoesNotDisturbTheDesk() async throws {
        // WP-A: `AXScrollToVisible` / the scroll bar, or a scroll-wheel event to the process.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let area = try session.id(of: "Rolagem", in: try await session.read(["query": .string("Rolagem")]))
        try await expectUndisturbed(fixture, "scroll") {
            _ = try await session.act("scroll", ["id": .string(area), "direction": .string("down"), "amount": .number(2)])
        }
        let logged = await fixture.waitFor("scroll") { (number($0, "y") ?? 0) > 50 }
        #expect(logged != nil)
    }

    @Test func pickingAMenuItemDoesNotBringTheAppForward() async throws {
        // WP-A: `pick_menu` presses `AXMenuBar → AXMenu → item` without activating the app (today it calls `activate`).
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        _ = try await session.read()
        try await expectUndisturbed(fixture, "pick_menu") {
            _ = try await session.act("pick_menu", ["menu_path": .array([.string("Ações"), .string("Marcar")])])
        }
        let logged = await fixture.waitFor("menu") { text($0, "item") == "Marcar" }
        #expect(logged != nil)
    }

    @Test func aShortcutRunsTheMenuItemThatOwnsItInTheBackground() async throws {
        // WP-A/B: "cmd+k" finds the menu item by its key equivalent and presses it.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        _ = try await session.read()
        try await expectUndisturbed(fixture, "key") { _ = try await session.act("key", ["keys": .string("cmd+k")]) }
        let logged = await fixture.waitFor("menu") { text($0, "item") == "Marcar" }
        #expect(logged != nil)
    }

    @Test func waitReturnsRightAfterTheLabelChanges() async throws {
        // WP-A: `ui_read wait` is woken by the AX notification, not by polling.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let button = try session.id(of: "button “Mudar depois”", in: try await session.read())
        let clock = ContinuousClock()
        let begin = clock.now
        _ = try await session.act("press", ["id": .string(button)])
        let reading = try await session.read(["wait": .string("appears"), "query": .string("Pronto"), "timeout": .number(5)])
        #expect(reading.contains("Pronto"))
        // The label changes 500 ms after the press: that part is the fixture's, the rest is a budget.
        #expect(begin.duration(to: clock.now) <= .milliseconds(500) + AXSmoke.budget(.milliseconds(200)),
                "press → label changed (500 ms) → read, all within 700 ms (release)")
    }

    @Test func aThousandSubscriptionsLeaveNothingBehind() async throws {
        // WP-A: the hub drops the observer when the stream is no longer iterated, and a new subscription still works.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let system = LiveAccessibilitySystem()
        for _ in 0..<1_000 {
            let stream = system.events.events(pid: fixture.pid, [.valueChanged, .layoutChanged])
            let task = Task { for await _ in stream {} }
            task.cancel()
        }
        let session = SmokeSession(fixture)
        let button = try session.id(of: "button “Mudar depois”", in: try await session.read())
        let stream = system.events.events(pid: fixture.pid, [.valueChanged, .titleChanged, .layoutChanged])
        let first = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        _ = try await session.act("press", ["id": .string(button)])
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await first.value }
            group.addTask { try? await Task.sleep(for: .seconds(3)); first.cancel(); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(received, "a subscription made after a thousand dropped ones still gets notifications")
    }

    @Test func typingTwoThousandCharactersIsFast() async throws {
        // WP-A/B: events to the process in chunks of at most 20 UTF-16 units.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let notes = try session.id(of: "textarea “Notas”", in: try await session.read())
        _ = try await session.act("focus", ["id": .string(notes)])
        let clock = ContinuousClock()
        let begin = clock.now
        _ = try await session.act("type", ["value": .string(String(repeating: "abcdefghij", count: 200))])
        #expect(begin.duration(to: clock.now) <= AXSmoke.budget(.milliseconds(400)))
        let logged = await fixture.waitFor("text") { text($0, "field") == "Notas" && (text($0, "value")?.count ?? 0) >= 2_000 }
        #expect(logged != nil)
    }

    // MARK: Budgets (read and press run on what exists; the budgets are the design's)

    @Test func readingAnAppWithAThousandElementsMeetsItsBudget() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        _ = try await session.read()
        var times: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<20 {
            let begin = clock.now
            _ = try await session.read(["query": .string("Trecho 599")])
            let spent = begin.duration(to: clock.now)
            times.append(Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15)
        }
        #expect(percentile(times, 0.95) <= AXSmoke.budget(800), "p95 \(percentile(times, 0.95)) ms (budget \(AXSmoke.budget(800)) ms)")
    }

    @Test func pressingMeetsItsBudget() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let button = try session.id(of: "button “Somar”", in: try await session.read())
        var times: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<20 {
            let begin = clock.now
            _ = try await session.act("press", ["id": .string(button)])
            let spent = begin.duration(to: clock.now)
            times.append(Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15)
        }
        #expect(percentile(times, 0.95) <= AXSmoke.budget(250), "p95 \(percentile(times, 0.95)) ms (budget \(AXSmoke.budget(250)) ms)")
        #expect(fixture.events("button").count == 20)
    }

    // MARK: Needs WP-B (capture, marks, synthetic input) and Screen Recording

    @Test(.enabled(if: AXSmoke.capture))
    func aCoveredWindowIsCapturedWholeNotBlankAndNotTheCover() async throws {
        // WP-B: ScreenCaptureKit captures the window's own pixels, whatever is on top of it.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        fixture.send("cover")
        #expect(await fixture.waitFor("cover") != nil, "the fixture put its cover over its own window")
        try await Task.sleep(for: .milliseconds(500))
        let session = SmokeSession(fixture)
        let result = try await session.capture(["window": .string("Fixture")])
        let path = result.images.first?.path
            ?? result.text.range(of: #"/[^\s"]+\.(png|jpg|jpeg)"#, options: .regularExpression).map { String(result.text[$0]) }
        let file = try #require(path, "the capture reports where the picture is")
        let colors = try Self.colors(inImageAt: URL(fileURLWithPath: file))
        #expect(colors.magentaShare < 0.05, "the cover (magenta) is not in the picture: \(colors.magentaShare)")
        #expect(colors.distinct >= 8, "not blank: \(colors.distinct) distinct colors")
    }

    @Test(.enabled(if: AXSmoke.capture))
    func clickingACanvasWithNoAccessibilityWorksWithoutTheCursor() async throws {
        // WP-B: a mouse event to the process (`postToPid`) at a point read from the last screenshot with marks.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let shot = try await session.capture()
        // The canvas is at a known place in the window; the screenshot's own scale turns points into its pixels.
        let scale = shot.text.range(of: #"(\d+(?:[.,]\d+)?)\s*px/pt"#, options: .regularExpression)
            .flatMap { Double(shot.text[$0].replacingOccurrences(of: ",", with: ".").split(separator: " ").first ?? "") } ?? 1
        let x = fixture.canvasInWindow.x * scale, y = fixture.canvasInWindow.y * scale
        try await expectUndisturbed(fixture, "click") {
            _ = try await session.act("click", ["x": .number(x), "y": .number(y)])
        }
        let logged = await fixture.waitFor("canvas")
        #expect(logged != nil)
    }

    @Test(.enabled(if: AXSmoke.capture))
    func captureOfAWindowMeetsItsBudget() async throws {
        // WP-B: cold ≤ 500 ms, warm p95 ≤ 120 ms.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let clock = ContinuousClock()
        func milliseconds(_ spent: Duration) -> Double { Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15 }
        let cold = clock.now
        _ = try await session.capture(["marks": .bool(false), "ocr": .string("off")])
        #expect(milliseconds(cold.duration(to: clock.now)) <= AXSmoke.budget(500))
        var times: [Double] = []
        for _ in 0..<20 {
            let begin = clock.now
            _ = try await session.capture(["marks": .bool(false), "ocr": .string("off")])
            times.append(milliseconds(begin.duration(to: clock.now)))
        }
        #expect(percentile(times, 0.95) <= AXSmoke.budget(120), "p95 \(percentile(times, 0.95)) ms (budget \(AXSmoke.budget(120)) ms)")
    }

    private static func colors(inImageAt url: URL) throws -> (magentaShare: Double, distinct: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("Não consegui abrir a imagem \(url.path).")
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ToolError("Não consegui ler os pixels da imagem.") }
        var magenta = 0, total = 0
        var seen = Set<Int>()
        for offset in stride(from: 0, to: pixels.count, by: 16) {
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            total += 1
            if r > 200, g < 60, b > 200 { magenta += 1 }
            seen.insert((r / 32) << 6 | (g / 32) << 3 | (b / 32))
        }
        return (Double(magenta) / Double(max(total, 1)), seen.count)
    }

    // MARK: Taking the screen over (ORB_AX_TAKEOVER=1)

    @Test(.enabled(if: AXSmoke.takeover))
    func aTakeoverClicksWithTheRealMouseAndGivesTheDeskBack() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let before = Desk.now()
        let target = AccessibilityApp(name: AXSmoke.appName, bundleID: nil, pid: fixture.pid)
        let center = fixture.canvasCenter
        let report = try await LiveAccessibilitySystem().screen.takeOver(target, window: nil, limit: .seconds(10)) { hand in
            try await hand.click(at: center, button: .left, count: 1)
            return true
        }
        #expect(report.value)
        let clicked = await fixture.waitFor("canvas")
        #expect(clicked != nil, "the real click reached the canvas")
        try await Task.sleep(for: .milliseconds(300))
        let after = Desk.now()
        #expect(after.frontPID == before.frontPID, "the app that was in front is in front again")
        #expect(after.distance(to: before) <= 2, "the cursor is back within 2 points")
        #expect(report.cursorRestored)
        #expect(report.duration < .seconds(10))
    }

    @Test(.enabled(if: AXSmoke.takeover))
    func cancellingATakeoverStillGivesTheDeskBack() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let before = Desk.now()
        let target = AccessibilityApp(name: AXSmoke.appName, bundleID: nil, pid: fixture.pid)
        let center = fixture.canvasCenter
        let started = ContinuousClock.now
        let task = Task {
            try await LiveAccessibilitySystem().screen.takeOver(target, window: nil, limit: .seconds(10)) { hand in
                try await hand.click(at: center, button: .left, count: 1)
                try await Task.sleep(for: .seconds(30))
            }
        }
        _ = await fixture.waitFor("canvas", timeout: .seconds(5))
        task.cancel()
        _ = try? await task.value
        #expect(started.duration(to: .now) < .seconds(8))
        let after = Desk.now()
        #expect(after.frontPID == before.frontPID)
        #expect(after.distance(to: before) <= 2)
    }

    @Test(.enabled(if: AXSmoke.takeover))
    func theToolEscalatesToATakeoverWhenAskedAndSaysSo() async throws {
        // WP-A/B: `ui_act click` with `takeover: true` after a screenshot with marks.
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        _ = try await session.capture()
        let before = Desk.now()
        let output = try await session.act("click", ["x": .number(220), "y": .number(500), "takeover": .bool(true)])
        #expect(output.contains("assumi a tela"))
        try await Task.sleep(for: .milliseconds(300))
        let after = Desk.now()
        #expect(after.frontPID == before.frontPID && after.distance(to: before) <= 2)
    }

    // MARK: Real apps, read only (ORB_AX_SMOKE_SYSTEM=1)

    @Test(.enabled(if: AXSmoke.system))
    func finderCanBeReadWithoutTouchingTheDesk() async throws {
        let fixture = try await FixtureApp.launch()
        defer { fixture.stop() }
        let session = SmokeSession(fixture)
        let before = Desk.now()
        let reading = try await session.call("ui_read", ["app": .string("Finder")])
        #expect(reading.split(separator: "\n").count >= 3)
        let after = Desk.now()
        #expect(after.frontPID == before.frontPID && after.distance(to: before) <= 2)
    }
}
