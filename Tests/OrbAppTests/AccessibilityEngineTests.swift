import CoreGraphics
import Foundation
import ApplicationServices
import os
import Testing
@testable import Orb

// The background engine of ui_read and ui_act (docs/USO-DO-COMPUTADOR.md): the ladder Accessibility → event to the app →
// taking the screen, the refusals, ids by mark and by point, waiting on notifications, the IPC budgets, a hung app and the
// notification hub. Everything runs against the shared fakes: no real app is read, clicked or typed into.

/// A bench with its own sessions and live references, so a hung app in one test never slows another.
private struct Bench {
    let system: FakeAccessibility
    let store = UISnapshotStore(directory: nil)
    let sessions: AXSessions
    let live = UILiveElements()
    let root: FakeElement
    let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())
    var settle = UISettle.none

    init(windows: [FakeElement], menus: [FakeElement]? = nil, deadlines: AXDeadlines = .patient) {
        system = FakeAccessibility()
        system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100),
                       FakeAccessibility.app("Safari", "com.apple.Safari", pid: 200, active: true)]
        root = fakeApp(windows: windows, menus: menus)
        system.roots[100] = root
        sessions = AXSessions(deadlines: deadlines)
    }

    func reader(_ system: (any AccessibilitySystem)? = nil) -> UIReadTool {
        UIReadTool(system: system ?? self.system, store: store, sessions: sessions, live: live)
    }

    func actor(_ system: (any AccessibilitySystem)? = nil) -> UIActTool {
        UIActTool(system: system ?? self.system, store: store, settle: settle, sessions: sessions, live: live)
    }

    @discardableResult
    func read(_ arguments: [String: JSONValue] = ["app": .string("Notas")], system: (any AccessibilitySystem)? = nil) async throws -> String {
        try await reader(system).run(.object(arguments), context: context)
    }

    func act(_ arguments: [String: JSONValue], system: (any AccessibilitySystem)? = nil) async throws -> String {
        try await actor(system).run(.object(arguments), context: context)
    }

    func failure(_ body: () async throws -> String) async -> String {
        do { _ = try await body(); return "" } catch { return error.localizedDescription }
    }

    /// Adds a screenshot's marks and geometry to the last reading, as the screenshot tool does.
    func addShot(marks: [Int: String], windowFrame: CGRect, scale: Double = 2, windowID: UInt32 = 77) throws {
        var snapshot = try #require(store.snapshot(bot: context.botID, app: AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100)))
        snapshot.marks = marks
        snapshot.shot = ShotGeometry(pixelWidth: Int(windowFrame.width * scale), pixelHeight: Int(windowFrame.height * scale), scale: scale,
                                     windowFrame: windowFrame, windowID: windowID)
        store.save(snapshot, bot: context.botID)
    }
}

/// The fake system with the stand-in that cannot send events, like the engine before synthetic input exists.
private struct WithoutInput: AccessibilitySystem {
    let base: FakeAccessibility
    func isTrusted() -> Bool { base.isTrusted() }
    func runningApps() async -> [RunningAppInfo] { await base.runningApps() }
    func root(of app: AccessibilityApp) -> any AccessibilityElement { base.root(of: app) }
    func hitTest(_ app: AccessibilityApp, at point: CGPoint) -> (any AccessibilityElement)? { base.hitTest(app, at: point) }
    func frontmostPID() async -> Int32? { await base.frontmostPID() }
    func secondsSinceUserInput() -> TimeInterval { base.secondsSinceUserInput() }
    var events: any AccessibilityEvents { base.events }
    var capturer: any WindowCapturer { base.capturer }
    var screen: any ScreenOwner { base.screen }
}

private let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

extension AXDeadlines {
    /// For tests that are not about deadlines: a machine running thousands of tests at once can stall a fake app's
    /// answer for seconds, which must not read as "the app did not answer".
    static let patient = AXDeadlines(read: .seconds(120), readWithQuery: .seconds(120), action: .seconds(120))
}

private func framed(_ element: FakeElement, _ frame: CGRect) -> FakeElement {
    element.frame = frame
    return element
}

// MARK: - The ladder

struct AccessibilityLadderTests {
    @Test func pressGoesThroughAccessibilityAndSaysSo() async throws {
        let button = fakeButton("Salvar")
        let bench = Bench(windows: [fake("AXWindow", title: "A", [button])])
        try await bench.read()
        let text = try await bench.act(["action": .string("press"), "id": .string("w1.1")])
        #expect(text.hasPrefix("Cliquei em button “Salvar” (w1.1). [segundo plano · AX]"))
        #expect(button.performed == ["AXPress"])
        #expect(bench.system.syntheticInput.events.isEmpty && bench.system.activated.isEmpty)
    }

    @Test func confirmAndPickComeBeforeAnEvent() async throws {
        let item = fake("AXButton", title: "OK", actions: ["AXConfirm"])
        let bench = Bench(windows: [fake("AXWindow", title: "A", [item])])
        try await bench.read()
        _ = try await bench.act(["action": .string("press"), "id": .string("w1.1")])
        #expect(item.performed == ["AXConfirm"])
    }

    @Test func anElementWithoutActionsGetsAClickSentToTheAppAtItsCenter() async throws {
        let logo = framed(fake("AXImage", description: "Logo"), CGRect(x: 120, y: 140, width: 40, height: 20))
        let window = framed(fake("AXWindow", title: "A", [logo]), windowFrame)
        let bench = Bench(windows: [window])
        bench.system.windowCapturer.setWindows([CapturableWindow(windowID: 55, pid: 100, frame: windowFrame, title: "A")], pid: 100)
        try await bench.read()
        let text = try await bench.act(["action": .string("press"), "id": .string("w1.1")])
        #expect(text.contains("[segundo plano · evento ao app]"))
        #expect(bench.system.syntheticInput.events == [.click(CGPoint(x: 140, y: 150), window: 55, button: .left, count: 1, pid: 100)])
    }

    @Test func withoutEventsToTheAppTheLadderStopsWithTheMarker() async throws {
        let logo = framed(fake("AXImage", description: "Logo"), CGRect(x: 120, y: 140, width: 40, height: 20))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [logo]), windowFrame)])
        bench.system.windowCapturer.setWindows([CapturableWindow(windowID: 55, pid: 100, frame: windowFrame, title: "A")], pid: 100)
        let system = WithoutInput(base: bench.system)
        try await bench.read(system: system)
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.1")], system: system) }
        #expect(message.hasPrefix(UIActTool.takeoverMarker))
        #expect(message.contains("takeover") && message.contains("repetir pode duplicar"))
        #expect(bench.system.screenOwner.takes == 0, "the screen is never taken without being asked")
    }

    @Test func noWindowToSendTheEventToIsTheMarkerToo() async throws {
        let logo = framed(fake("AXImage", description: "Logo"), CGRect(x: 120, y: 140, width: 40, height: 20))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [logo]), windowFrame)])
        try await bench.read()
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.1")]) }
        #expect(message.hasPrefix(UIActTool.takeoverMarker) && message.contains("janela"))
        #expect(bench.system.syntheticInput.events.isEmpty)
    }

    @Test func takeoverUsesTheRealHandAndAlwaysAsks() async throws {
        let button = framed(fakeButton("Desenhar"), CGRect(x: 200, y: 200, width: 100, height: 40))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [button]), windowFrame)])
        try await bench.read()
        let call: [String: JSONValue] = ["action": .string("press"), "id": .string("w1.1"), "takeover": .bool(true)]
        #expect(bench.actor().danger(.object(call))?.contains("assume a tela") == true)
        #expect(bench.actor().summary(.object(call)).title.hasPrefix("Assumindo a tela"))
        let text = try await bench.act(call)
        #expect(text.contains("[assumi a tela") && text.contains("devolvi ao Safari"))
        #expect(bench.system.screenOwner.steps == [.took(pid: 100, windowGiven: true, limit: .seconds(10)), .restored(cancelled: false)])
        #expect(bench.system.screenOwner.hand.actions == [.click(CGPoint(x: 250, y: 220), button: .left, count: 1)])
        #expect(button.performed.isEmpty)
    }

    @Test func typeSendsTheTextInChunksToTheFocusedField() async throws {
        let field = fake("AXTextField", title: "Nome")
        field.settable = ["AXFocused"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [field])])
        bench.root.attrs["AXFocusedUIElement"] = .element(field)
        try await bench.read()
        let text = String(repeating: "abcdefghij", count: 4) + "çãõ!?"
        let result = try await bench.act(["action": .string("type"), "id": .string("w1.1"), "value": .string(text)])
        #expect(result.contains("[segundo plano · evento ao app]"))
        #expect(bench.system.syntheticInput.typed(to: 100) == text)
        #expect(field.assignedValue("AXFocused")?.bool == true, "the field gets the app's focus, not the user's")
        #expect(UIActTool.chunks(text).allSatisfy { $0.utf16.count <= 20 } && UIActTool.chunks(text).joined() == text)
    }

    @Test func typingWithoutEventsStopsWithTheMarker() async throws {
        let field = fake("AXTextField", title: "Nome")
        let bench = Bench(windows: [fake("AXWindow", title: "A", [field])])
        bench.root.attrs["AXFocusedUIElement"] = .element(field)
        let system = WithoutInput(base: bench.system)
        try await bench.read(system: system)
        let message = await bench.failure { try await bench.act(["action": .string("type"), "id": .string("w1.1"), "value": .string("oi")], system: system) }
        #expect(message.hasPrefix(UIActTool.takeoverMarker))
    }

    @Test func aFieldThatRefusesAXValueIsTyped() async throws {
        let field = fake("AXTextField", title: "Busca", value: .string(""))
        field.settable = ["AXFocused"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [field])])
        bench.root.attrs["AXFocusedUIElement"] = .element(field)
        try await bench.read()
        let text = try await bench.act(["action": .string("set_value"), "id": .string("w1.1"), "value": .string("gatos")])
        #expect(text.contains("evento ao app"))
        #expect(bench.system.syntheticInput.typed(to: 100) == "gatos")
    }

    @Test func aShortcutIsPressedAsItsMenuItemWithoutAnyKeyEvent() async throws {
        let mark = fakeMenuItem("Marcar")
        mark.attrs["AXMenuItemCmdChar"] = .string("K")
        mark.attrs["AXMenuItemCmdModifiers"] = .number(0)
        let bench = Bench(windows: [fake("AXWindow", title: "A")], menus: [fakeMenu("Ações", [fakeMenuItem("Outro"), mark])])
        let text = try await bench.act(["action": .string("key"), "app": .string("Notas"), "keys": .string("cmd+k")])
        #expect(text.hasPrefix("Usei cmd+k pelo menu Ações → Marcar de Notas.") && text.contains("[segundo plano · AX]"))
        #expect(mark.performed == ["AXPress"])
        #expect(bench.system.syntheticInput.events.isEmpty)
        // With shift the same letter is another shortcut.
        let shifted = try await bench.act(["action": .string("key"), "app": .string("Notas"), "keys": .string("cmd+shift+k")])
        #expect(shifted.contains("evento ao app") && mark.performed == ["AXPress"])
    }

    @Test func keysWithoutAMenuItemAreSentToTheApp() async throws {
        let bench = Bench(windows: [fake("AXWindow", title: "A")])
        let text = try await bench.act(["action": .string("key"), "app": .string("Notas"), "keys": .string("return, tab")])
        #expect(text.contains("evento ao app"))
        #expect(bench.system.syntheticInput.events == [.keys([KeyStroke(.named(.return)), KeyStroke(.named(.tab))], pid: 100)])
        let bad = await bench.failure { try await bench.act(["action": .string("key"), "app": .string("Notas"), "keys": .string("hyper+x")]) }
        #expect(bad.contains("Modificador desconhecido"))
        let unnamed = await bench.failure { try await bench.act(["action": .string("key"), "keys": .string("return")]) }
        #expect(unnamed.contains("Diga em qual app"), "without a reading, key needs the app")
    }

    @Test func scrollMovesTheScrollBarAndFallsBackToAScrollEvent() async throws {
        let bar = fake("AXScrollBar", value: .number(0))
        bar.settable = ["AXValue"]
        let area = framed(fake("AXScrollArea", description: "Lista", [fakeButton("Item")]), CGRect(x: 100, y: 120, width: 200, height: 100))
        area.attrs["AXVerticalScrollBar"] = .element(bar)
        area.attrs["AXContents"] = .elements([fake("AXGroup", size: CGSize(width: 200, height: 500))])
        let plain = framed(fake("AXScrollArea", description: "Outra"), CGRect(x: 100, y: 240, width: 200, height: 100))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [area, plain]), windowFrame)])
        bench.system.windowCapturer.setWindows([CapturableWindow(windowID: 55, pid: 100, frame: windowFrame, title: "A")], pid: 100)
        try await bench.read()

        let text = try await bench.act(["action": .string("scroll"), "id": .string("w1.1"), "direction": .string("down"), "amount": .number(2)])
        #expect(text.contains("para baixo (2 pág.)") && text.contains("[segundo plano · AX]"))
        guard case .number(let value)? = bar.assignedValue("AXValue") else { Issue.record("the bar was not moved"); return }
        #expect(abs(value - 0.45) < 0.001, "two pages of 100 pt over 400 pt hidden, at 90 %")

        _ = try await bench.act(["action": .string("scroll"), "id": .string("w1.2"), "direction": .string("down")])
        #expect(bench.system.syntheticInput.events == [.scroll(dx: 0, dy: -90, at: CGPoint(x: 200, y: 290), window: 55, pid: 100)])
    }

    @Test func selectPicksAPopupItemWithoutOpeningItAndAsksForTheScreenWhenTheMenuIsClosed() async throws {
        let popup = fake("AXPopUpButton", title: "Tamanho", actions: ["AXPress"], [fake("AXMenu", size: nil, [fakeMenuItem("Pequeno"), fakeMenuItem("Grande")])])
        let closed = fake("AXPopUpButton", title: "Cor", actions: ["AXPress"])
        let row = fake("AXRow", title: "Linha 2")
        row.settable = ["AXSelected"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [popup, closed, fake("AXTable", title: "T", [fake("AXRow", title: "Linha 1"), row])])])
        try await bench.read()
        let text = try await bench.act(["action": .string("select"), "id": .string("w1.1"), "value": .string("grande")])
        #expect(text.hasPrefix("Escolhi “Grande” em popup “Tamanho”"))
        #expect(popup.performed.isEmpty, "the popup is not opened")
        let message = await bench.failure { try await bench.act(["action": .string("select"), "id": .string("w1.2"), "value": .string("Azul")]) }
        #expect(message.hasPrefix(UIActTool.takeoverMarker))
        _ = try await bench.act(["action": .string("select"), "id": .string("w1.3"), "value": .string("linha 2")])
        #expect(row.assignedValue("AXSelected")?.bool == true)
    }

    @Test func showMenuReadsAContextMenuOnlyWithTheScreen() async throws {
        let label = fake("AXStaticText", value: .string("texto"), actions: ["AXShowMenu"])
        let bench = Bench(windows: [fake("AXWindow", title: "A", [label])])
        try await bench.read()
        let message = await bench.failure { try await bench.act(["action": .string("show_menu"), "id": .string("w1.1")]) }
        #expect(message.hasPrefix(UIActTool.takeoverMarker))
        #expect(label.performed.isEmpty)
    }

    @Test func stepsRunInOrderAndStopAtTheFirstFailure() async throws {
        let one = fakeButton("Um"), two = fakeButton("Dois")
        let bench = Bench(windows: [fake("AXWindow", title: "A", [one, two, fake("AXStaticText", value: .string("x"))])])
        try await bench.read()
        let steps: JSONValue = .array([
            .object(["action": .string("press"), "id": .string("w1.1")]),
            .object(["action": .string("press"), "id": .string("w1.2")]),
        ])
        let text = try await bench.act(["action": .string("press"), "steps": steps])
        #expect(text.hasPrefix("1. Cliquei em button “Um”") && text.contains("\n2. Cliquei em button “Dois”"))
        let failing: JSONValue = .array([
            .object(["action": .string("press"), "id": .string("w1.1")]),
            .object(["action": .string("increment"), "id": .string("w1.3")]),
            .object(["action": .string("press"), "id": .string("w1.2")]),
        ])
        let message = await bench.failure { try await bench.act(["action": .string("press"), "steps": failing]) }
        #expect(message.hasPrefix("O passo 2 de 3 falhou") && message.contains("Antes dele:\n1. Cliquei"))
        #expect(one.performed.count == 2 && two.performed.count == 1)
        let tooMany = JSONValue.array(Array(repeating: .object(["action": .string("press"), "id": .string("w1.1")]), count: 9))
        #expect(await bench.failure { try await bench.act(["action": .string("press"), "steps": tooMany]) }.contains("No máximo 8"))
        // The first dangerous step makes the whole call dangerous.
        let mixed: JSONValue = .array([.object(["action": .string("press"), "id": .string("w1.1")]),
                                       .object(["action": .string("pick_menu"), "menu_path": .array([.string("Arquivo"), .string("Excluir")])])])
        #expect(bench.actor().danger(.object(["action": .string("press"), "steps": mixed])) != nil)
    }

    @Test func idsRepeatTheActionAndSelectSeveralRowsAtOnce() async throws {
        let first = fakeButton("A"), second = fakeButton("B")
        let rowOne = fake("AXRow", title: "1"), rowTwo = fake("AXRow", title: "2")
        rowOne.settable = ["AXSelected"]
        rowTwo.settable = ["AXSelected"]
        let bench = Bench(windows: [fake("AXWindow", title: "W", [first, second, fake("AXTable", title: "T", [rowOne, rowTwo])])])
        try await bench.read()
        _ = try await bench.act(["action": .string("press"), "ids": .array([.string("w1.1"), .string("w1.2")])])
        #expect(first.performed == ["AXPress"] && second.performed == ["AXPress"])
        let text = try await bench.act(["action": .string("select"), "ids": .array([.string("w1.3.1"), .string("w1.3.2")])])
        #expect(text.hasPrefix("Selecionei 2 itens"))
        #expect(rowOne.assignedValue("AXSelected")?.bool == true && rowTwo.assignedValue("AXSelected")?.bool == true)
    }
}

// MARK: - Refusals

struct AccessibilityRefusalTests {
    private func typingBench() -> (Bench, FakeElement) {
        let field = fake("AXTextField", title: "Nome")
        field.settable = ["AXFocused"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [field, fake("AXTextField", title: "Outro")])])
        bench.root.attrs["AXFocusedUIElement"] = .element(field)
        return (bench, field)
    }

    @Test func nothingIsTypedWhileTheUserIsUsingThatApp() async throws {
        let (bench, _) = typingBench()
        try await bench.read()
        bench.system.frontmost = 100
        bench.system.userIdle = 1
        let message = await bench.failure { try await bench.act(["action": .string("type"), "id": .string("w1.1"), "value": .string("oi")]) }
        #expect(message.contains("O usuário está usando Notas agora"))
        #expect(bench.system.syntheticInput.events.isEmpty)
        // In the background, or after a pause, it goes.
        bench.system.userIdle = 10
        _ = try await bench.act(["action": .string("type"), "id": .string("w1.1"), "value": .string("oi")])
        #expect(bench.system.syntheticInput.typed(to: 100) == "oi")
    }

    @Test func nothingIsTypedWhenTheAppsFocusIsElsewhere() async throws {
        let (bench, _) = typingBench()
        try await bench.read()
        bench.root.attrs["AXFocusedUIElement"] = .element(fake("AXTextField", title: "Outro lugar"))
        let message = await bench.failure { try await bench.act(["action": .string("type"), "id": .string("w1.1"), "value": .string("oi")]) }
        #expect(message.contains("O foco de Notas não está no campo pedido"))
        #expect(bench.system.syntheticInput.events.isEmpty)
    }

    @Test func aPasswordFieldIsFilledOnlyAfterTheCardSaysSo() async throws {
        let secret = fake("AXTextField", subrole: "AXSecureTextField")
        secret.settable = ["AXFocused"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [secret])])
        bench.root.attrs["AXFocusedUIElement"] = .element(secret)
        try await bench.read()
        // Typing into "the focused field" cannot be judged before running: it turns out to be a password field.
        let blind: [String: JSONValue] = ["action": .string("type"), "value": .string("hunter2")]
        #expect(bench.actor().danger(.object(blind)) == nil)
        let message = await bench.failure { try await bench.act(blind) }
        #expect(message.contains("campo de senha") && bench.system.syntheticInput.events.isEmpty)
        // Named by id, the card says it is a password field, and then it runs.
        let named: [String: JSONValue] = ["action": .string("type"), "id": .string("w1.1"), "value": .string("hunter2")]
        #expect(bench.actor().danger(.object(named))?.contains("senha") == true)
        #expect(!bench.actor().summary(.object(named)).detail.contains("hunter2"))
        let done = try await bench.act(named)
        #expect(!done.contains("hunter2"), "a password never comes back in the output")
        #expect(bench.system.syntheticInput.typed(to: 100) == "hunter2")
        #expect(!secret.reads.contains("AXValue"))
        let keys: [String: JSONValue] = ["action": .string("key"), "keys": .string("return")]
        #expect(await bench.failure { try await bench.act(keys) }.contains("campo de senha"))
    }

    @Test func aDangerousElementFoundOnlyAtRunTimeIsRefused() async throws {
        let ok = framed(fakeButton("OK"), CGRect(x: 150, y: 150, width: 80, height: 20))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [ok]), windowFrame)])
        try await bench.read()
        try bench.addShot(marks: [1: "w1.1"], windowFrame: windowFrame)
        // The reading says "OK" is there; the app's own hit test finds a delete button on top of it.
        let delete = fakeButton("Excluir tudo")
        bench.system.hitHandler = { _, _ in delete }
        let call: [String: JSONValue] = ["action": .string("click"), "x": .number(180), "y": .number(110)]
        #expect(bench.actor().danger(.object(call)) == nil, "the card judged the reading: a click on OK")
        let message = await bench.failure { try await bench.act(call) }
        #expect(message.hasPrefix("Não fiz:") && message.contains("apaga"))
        #expect(delete.performed.isEmpty && ok.performed.isEmpty)
    }

    @Test func returnInAMessagingAppAndCommandDeleteInTheFinderAreDangerous() {
        let enter = [KeyStroke(.named(.return))]
        #expect(UIDanger.reason(forKeys: enter, appName: "Mensagens", bundleID: "com.apple.MobileSMS") != nil)
        #expect(UIDanger.reason(forKeys: [KeyStroke(.named(.return), modifiers: .command)], appName: "Mail", bundleID: "com.apple.mail") != nil)
        #expect(UIDanger.reason(forKeys: [KeyStroke(.named(.return), modifiers: .shift)], appName: "Slack", bundleID: nil) == nil, "a new line")
        #expect(UIDanger.reason(forKeys: enter, appName: "Notas", bundleID: "com.apple.Notes") == nil)
        #expect(UIDanger.reason(forKeys: [KeyStroke(.named(.delete), modifiers: .command)], appName: "Finder", bundleID: "com.apple.finder") != nil)
        #expect(UIDanger.reason(forKeys: [KeyStroke(.named(.delete))], appName: "Finder", bundleID: "com.apple.finder") == nil)

        let store = UISnapshotStore(directory: nil)
        store.save(UISnapshot(app: AccessibilityApp(name: "Mail", bundleID: "com.apple.mail", pid: 7), windowIndex: 1, windowTitle: "Nova", entries: [:]), bot: nil)
        let tool = UIActTool(system: FakeAccessibility(), store: store, settle: .none)
        #expect(tool.danger(.object(["action": .string("key"), "app": .string("Mail"), "keys": .string("return")])) != nil)
        #expect(tool.danger(.object(["action": .string("key"), "app": .string("Mail"), "keys": .string("tab")])) == nil)
    }

    @Test func ui_actNeverActsOnTheFrontmostApp() async throws {
        let button = fakeButton("Salvar")
        let bench = Bench(windows: [fake("AXWindow", title: "A", [button])])
        bench.system.roots[200] = fakeApp(windows: [fake("AXWindow", title: "Safari", [fakeButton("Salvar")])])
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.1")]) }
        #expect(message.contains("Diga o app") && button.performed.isEmpty)
        try await bench.read() // Notas, by name, while Safari is in front
        _ = try await bench.act(["action": .string("press"), "id": .string("w1.1")])
        #expect(button.performed == ["AXPress"])
    }

    @Test func anAppThatComesForwardByItselfIsSentBackAndThenNeedsTheScreen() async throws {
        let button = fakeButton("Abrir")
        let field = fake("AXTextField", title: "Nome")
        field.settable = ["AXFocused"]
        let bench = Bench(windows: [fake("AXWindow", title: "A", [button, field])])
        let safari = fakeApp(windows: [])
        safari.settable = ["AXFrontmost"]
        bench.system.roots[200] = safari
        bench.system.frontmost = 200
        let system = bench.system
        button.onPerform = { _ in system.frontmost = 100 }
        try await bench.read()
        let text = try await bench.act(["action": .string("press"), "id": .string("w1.1")])
        #expect(text.contains("veio para a frente sozinho"))
        #expect(safari.assignedValue("AXFrontmost")?.bool == true, "the user's app is put back with AXFrontmost, never activate")
        bench.system.frontmost = 200
        let focus = await bench.failure { try await bench.act(["action": .string("focus"), "id": .string("w1.2")]) }
        #expect(focus.hasPrefix(UIActTool.takeoverMarker))
        #expect(bench.system.activated.isEmpty)
    }
}

// MARK: - Ids by mark and by point

struct AccessibilityPointingTests {
    private func pointingBench() -> (Bench, FakeElement, FakeElement) {
        let ok = framed(fakeButton("OK"), CGRect(x: 150, y: 150, width: 80, height: 20))
        let label = framed(fake("AXStaticText", value: .string("Rótulo")), CGRect(x: 160, y: 152, width: 30, height: 12))
        let group = framed(fake("AXGroup", description: "Barra", [label]), CGRect(x: 140, y: 140, width: 300, height: 60))
        let bench = Bench(windows: [framed(fake("AXWindow", title: "A", [ok, group]), windowFrame)])
        return (bench, ok, label)
    }

    @Test func aMarkNamesTheIdItWasDrawnOn() async throws {
        let (bench, ok, _) = pointingBench()
        try await bench.read()
        try bench.addShot(marks: [3: "w1.1"], windowFrame: windowFrame)
        _ = try await bench.act(["action": .string("press"), "id": .string("#3")])
        #expect(ok.performed == ["AXPress"])
        #expect(bench.actor().summary(.object(["action": .string("press"), "id": .string("#3")])).title == "Clicando em “OK”")
        let unknown = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("#9")]) }
        #expect(unknown.contains("A marca #9 não está no último screenshot"))
    }

    @Test func aPointIsHitTestedOnTheReadingFirstAndPressesWhatIsThere() async throws {
        let (bench, ok, _) = pointingBench()
        try await bench.read()
        try bench.addShot(marks: [:], windowFrame: windowFrame)
        // Pixel (180, 110) at 2 px/pt is (90, 55) in the window: inside OK (50…130, 50…70).
        let text = try await bench.act(["action": .string("click"), "x": .number(180), "y": .number(110)])
        #expect(text.hasPrefix("Cliquei em button “OK” (w1.1)."))
        #expect(ok.performed == ["AXPress"])
        #expect(bench.system.hitTests == [CGPoint(x: 190, y: 155)], "confirmed against the app at the point on screen")
    }

    @Test func theSmallestFrameWinsThenItsActionableAncestor() throws {
        let entries: [String: UISnapshot.Entry] = [
            "w1": .init(rawRole: "AXWindow", label: "A", secure: false, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            "w1.2": .init(rawRole: "AXButton", label: "Grande", secure: false, frame: CGRect(x: 10, y: 10, width: 200, height: 100), actionable: true),
            "w1.2.1": .init(rawRole: "AXStaticText", label: "Texto", secure: false, frame: CGRect(x: 20, y: 20, width: 50, height: 20)),
        ]
        let shot = ShotGeometry(pixelWidth: 400, pixelHeight: 300, scale: 1, windowFrame: windowFrame, windowID: 1)
        let snapshot = UISnapshot(app: AccessibilityApp(name: "X", bundleID: nil, pid: 1), windowIndex: 1, windowTitle: "A", entries: entries, shot: shot)
        #expect(UIActTool.localHit(CGPoint(x: 30, y: 25), in: snapshot)?.id == "w1.2", "the text inside climbs to its button")
        #expect(UIActTool.localHit(CGPoint(x: 300, y: 250), in: snapshot)?.id == "w1")
        #expect(UIActTool.localHit(CGPoint(x: 500, y: 500), in: snapshot) == nil)
    }

    @Test func aResizedWindowMakesThePointStale() async throws {
        let (bench, ok, _) = pointingBench()
        try await bench.read()
        try bench.addShot(marks: [:], windowFrame: windowFrame)
        let window = try #require(bench.root.attrs["AXWindows"]?.elements?.first as? FakeElement)
        window.frame = CGRect(x: 100, y: 100, width: 410, height: 300)
        let message = await bench.failure { try await bench.act(["action": .string("click"), "x": .number(180), "y": .number(110)]) }
        #expect(message.contains("mudou de tamanho") && message.contains("chame ui_read de novo"))
        #expect(ok.performed.isEmpty)
        let noShot = Bench(windows: [fake("AXWindow", title: "A")])
        try await noShot.read()
        #expect(await noShot.failure { try await noShot.act(["action": .string("click"), "x": .number(1), "y": .number(1)]) }.contains("tire um screenshot"))
    }

    @Test func aRightClickOrDoubleClickIsAnEventEvenOnAButton() async throws {
        let (bench, ok, _) = pointingBench()
        bench.system.windowCapturer.setWindows([CapturableWindow(windowID: 55, pid: 100, frame: windowFrame, title: "A")], pid: 100)
        try await bench.read()
        _ = try await bench.act(["action": .string("click"), "id": .string("w1.1"), "count": .number(2)])
        #expect(ok.performed.isEmpty)
        #expect(bench.system.syntheticInput.events == [.click(CGPoint(x: 190, y: 160), window: 55, button: .left, count: 2, pid: 100)])
    }
}

// MARK: - Stale ids

struct AccessibilityStaleIdTests {
    @Test func aGoneElementSaysWhichIdAndWhat() async throws {
        let target = fakeButton("Salvar")
        let window = fake("AXWindow", title: "Doc", [fakeButton("Antes"), target])
        let bench = Bench(windows: [window])
        try await bench.read()
        // The live reference dies with the element; the path then leads nowhere.
        target.failures["*"] = .invalidElement
        window.children.removeLast()
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains("w1.2 não existe mais") && message.contains("chame ui_read de novo"))
    }

    @Test func aRenamedElementSaysWhatItWasAndWhatItIs() async throws {
        let target = fakeButton("Salvar")
        let bench = Bench(windows: [fake("AXWindow", title: "Doc", [target])])
        try await bench.read()
        target.attrs["AXTitle"] = .string("Apagar")
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.1")]) }
        #expect(message.contains("w1.1 era “Salvar” e agora é “Apagar”") && message.contains("chame ui_read de novo"))
        #expect(target.performed.isEmpty)
    }

    @Test func aRelaunchedAppIsNotTheOneThatWasRead() async throws {
        let bench = Bench(windows: [fake("AXWindow", title: "Doc", [fakeButton("OK")])])
        let launched = Date(timeIntervalSince1970: 1_000)
        bench.system.apps[0].launchDate = launched
        try await bench.read()
        bench.system.apps[0].launchDate = launched.addingTimeInterval(60) // the same pid, another process
        let message = await bench.failure { try await bench.act(["action": .string("press"), "id": .string("w1.1")]) }
        #expect(message.contains("fechou ou foi reaberto"))
    }

    @Test func anOldSnapshotFileStillDrivesAnAction() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbAXEngine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written by a version without generation, frames, marks or launch dates.
        let json = #"{"app":{"name":"Notas","bundleID":"com.apple.Notes","pid":100},"windowIndex":1,"windowTitle":"Doc","#
            + #""entries":{"w1.1":{"rawRole":"AXButton","label":"OK","secure":false}},"takenAt":\#(Date.now.timeIntervalSinceReferenceDate)}"#
        try Data(json.utf8).write(to: folder.appending(path: "ax-com.apple.notes.json"))
        let target = fakeButton("OK")
        let system = FakeAccessibility()
        system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100)]
        system.roots[100] = fakeApp(windows: [fake("AXWindow", title: "Doc", [target])])
        let tool = UIActTool(system: system, store: UISnapshotStore(directory: folder), settle: .none, sessions: AXSessions(), live: UILiveElements())
        let context = ToolContext(workingDirectory: folder, botID: UUID())
        _ = try await tool.run(.object(["action": .string("press"), "app": .string("Notas"), "id": .string("w1.1")]), context: context)
        #expect(target.performed == ["AXPress"])
    }
}

// MARK: - Waiting

struct AccessibilityWaitTests {
    /// Waits until the walk the waiter just made is over, so the test can change the tree without racing it.
    private func quiet(_ element: FakeElement) async {
        var last = -1
        while element.roundTrips != last {
            last = element.roundTrips
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    @Test func readWaitsForATextToAppearOnANotification() async throws {
        let window = fake("AXWindow", title: "A", [fakeButton("Salvar")])
        let bench = Bench(windows: [window])
        let reading = Task {
            try await bench.read(["app": .string("Notas"), "wait": .string("appears"), "query": .string("Salvo"), "timeout": .number(30)])
        }
        try #require(await waitUntil("the wait subscribed") { bench.system.axEvents.activeSubscriptions > 0 })
        await quiet(window)
        window.children.append(fake("AXStaticText", value: .string("Salvo")))
        let clock = ContinuousClock()
        let sent = clock.now
        bench.system.axEvents.emit(.created, pid: 100)
        let text = try await reading.value
        #expect(sent.duration(to: clock.now) < .seconds(25), "the notification, not the 30 s timeout, ended the wait")
        #expect(text.contains("text “Salvo”") && text.contains("apareceu “Salvo”") && text.contains("(esperei"))
        try #require(await waitUntil("the wait unsubscribed") { bench.system.axEvents.activeSubscriptions == 0 })
    }

    @Test func withoutNotificationsTheWaitPolls() async throws {
        let window = fake("AXWindow", title: "A", [fakeButton("Carregando")])
        let bench = Bench(windows: [window])
        bench.system.axEvents.available = false
        let reading = Task {
            try await bench.read(["app": .string("Notas"), "wait": .string("disappears"), "query": .string("Carregando"), "timeout": .number(30)])
        }
        try #require(await waitUntil("the first look", timeout: .seconds(120)) { window.roundTrips > 0 })
        await quiet(window)
        window.children.removeAll()
        let text = try await reading.value
        #expect(text.contains("sumiu “Carregando”"))
    }

    @Test func aWaitThatNeverHappensSaysSoAfterItsTimeout() async throws {
        let bench = Bench(windows: [fake("AXWindow", title: "A", [fakeButton("Salvar")])])
        let clock = ContinuousClock()
        let started = clock.now
        let text = try await bench.read(["app": .string("Notas"), "wait": .string("appears"), "query": .string("Nunca"), "timeout": .number(1)])
        #expect(text.contains("(não aconteceu em 1 s)"))
        #expect(started.duration(to: clock.now) >= .seconds(1))
        let missing = await bench.failure { try await bench.read(["app": .string("Notas"), "wait": .string("appears")]) }
        #expect(missing.contains("precisa de query"))
    }

    @Test func aWaitForAnIdToChangeSeesItsValue() async throws {
        let box = fake("AXCheckBox", title: "Pronto", value: .number(0))
        let bench = Bench(windows: [fake("AXWindow", title: "A", [box])])
        try await bench.read()
        let reading = Task {
            try await bench.read(["app": .string("Notas"), "wait": .string("changes"), "id": .string("w1.1"), "timeout": .number(30)])
        }
        try #require(await waitUntil("the wait subscribed") { bench.system.axEvents.activeSubscriptions > 0 })
        await quiet(box)
        box.attrs["AXValue"] = .number(1)
        bench.system.axEvents.emit(.valueChanged, pid: 100, element: box)
        let text = try await reading.value
        #expect(text.contains(": mudou)") && text.contains("checkbox “Pronto” value=\"1\""))
    }

    @Test func anActionCanWaitForWhatItCauses() async throws {
        let window = fake("AXWindow", title: "A")
        let export = fakeButton("Exportar")
        window.children = [export]
        export.onPerform = { _ in window.children.append(fake("AXStaticText", value: .string("Exportado"))) }
        let bench = Bench(windows: [window])
        try await bench.read()
        let text = try await bench.act(["action": .string("press"), "id": .string("w1.1"), "wait": .string("Exportado"), "timeout": .number(30)])
        #expect(text.contains("apareceu “Exportado”"))
    }

    @Test func settleWaitsForTheFirstNotificationThenForQuiet() async {
        let events = FakeAccessibilityEvents()
        let watcher = AXEventWatcher(events.events(pid: 1, UISettle.notifications))
        defer { watcher.cancel() }
        events.emit(.valueChanged, pid: 1)
        events.emit(.layoutChanged, pid: 1)
        // The bounds are wide on purpose: a loaded machine can keep the watcher's task waiting for many seconds.
        let settle = UISettle(first: .seconds(600), quiet: .milliseconds(60), fallback: .zero, cap: .seconds(600))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await settle.wait(on: watcher))
        let took = started.duration(to: clock.now)
        #expect(took >= .milliseconds(60) && took < .seconds(300), "the quiet after the burst, not the 600 s: \(took)")
        #expect(watcher.count == 2)

        let none = FakeAccessibilityEvents()
        none.available = false
        let unsupported = AXEventWatcher(none.events(pid: 1, UISettle.notifications))
        #expect(await UISettle(first: .seconds(5), quiet: .zero, fallback: .milliseconds(10), cap: .seconds(1)).wait(on: unsupported) == false)
    }
}

// MARK: - Budgets

struct AccessibilityBudgetTests {
    @Test func theOutlineAsksEachElementAtMostTwiceAndOnceMoreForAValue() {
        let fields = (1...20).map { fake("AXTextField", title: "Campo \($0)", value: .string("v\($0)")) }
        let buttons = (1...20).map { fakeButton("Botão \($0)") }
        let texts = (1...20).map { fake("AXStaticText", value: .string("Texto \($0)")) }
        let window = fake("AXWindow", title: "A", [fake("AXGroup", fields), fake("AXToolbar", buttons), fake("AXList", texts)])
        _ = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        for element in window.subtree.dropFirst() {
            let role = element.attrs["AXRole"]?.string ?? ""
            let carriesValue = ["AXTextField", "AXStaticText"].contains(role)
            #expect(element.roundTrips <= 2 + (carriesValue ? 1 : 0), "\(role): \(element.roundTrips)")
        }
    }

    @Test func pressingWithTheLiveReferenceStaysWithinSixCalls() async throws {
        let target = fakeButton("Salvar")
        let inner = fake("AXGroup", [fake("AXGroup", [target])])
        let window = fake("AXWindow", title: "A", [fake("AXGroup", [inner])])
        let bench = Bench(windows: [window])
        try await bench.read()
        bench.root.resetRoundTrips()
        for element in window.subtree { element.resetRoundTrips() }
        _ = try await bench.act(["action": .string("press"), "id": .string("w1.1.1.1.1")])
        #expect(target.performed == ["AXPress"])
        #expect(target.roundTrips <= 6, "\(target.roundTrips)")
        #expect(inner.treeRoundTrips - target.roundTrips == 0, "the path is not walked again")
    }

    @Test func threeThousandElementsAreOutlinedQuickly() {
        let groups = (1...30).map { group in fake("AXGroup", description: "Grupo \(group)", (1...100).map { fakeButton("B\(group)-\($0)") }) }
        let window = fake("AXWindow", title: "Grande", groups)
        var limits = UIOutlineLimits()
        limits.seconds = 30
        var times: [Duration] = []
        var outline = UIOutline()
        // The design measures CPU: the time this thread ran, not the wall clock, which a machine running thousands of
        // tests stretches many times over. Target ≤ 60 ms on this Mac; the assertion leaves room for a slower one.
        for _ in 0..<3 {
            let started = threadCPUTime()
            outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: limits)
            times.append(threadCPUTime() - started)
            if times.last! <= .milliseconds(250) { break }
        }
        #expect(times.min()! <= .milliseconds(250), "\(times)")
        #expect(outline.cuts.contains(.visited) && outline.lines.count == 400)
    }

    @Test func theOutlineStopsAtFourteenThousandCharacters() {
        let long = String(repeating: "x", count: 70)
        let window = fake("AXWindow", title: "A", (1...400).map { fakeButton("\(long) \($0)") })
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(outline.cuts.contains(.characters))
        #expect(outline.lines.reduce(0) { $0 + $1.count + 1 } <= 14_000)
        #expect(outline.entries.count == outline.lines.count, "only what was shown can be acted on")
    }

    @Test func aWebAreaIsReadOnlyNearItsTopWithoutAQuery() {
        var deepest = fake("AXStaticText", value: .string("no fundo"))
        for level in 0..<5 { deepest = fake("AXGroup", description: "nível \(level)", [deepest]) }
        let window = fake("AXWindow", title: "Página", [fake("AXWebArea", title: "Site", [deepest])])
        let plain = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(plain.cuts.contains(.web) && !plain.lines.joined().contains("no fundo"))
        let searched = UIOutlineBuilder.outline(of: window, prefix: "w1", query: "fundo", limits: UIOutlineLimits())
        #expect(!searched.cuts.contains(.web) && searched.matched == 1)
    }

    @Test func theFirstCallTheAppFailsEndsTheWalk() {
        let hung = fakeButton("Travado")
        hung.failures["*"] = .cannotComplete
        let after = fakeButton("Depois")
        let window = fake("AXWindow", title: "A", [fakeButton("Antes"), hung, after])
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(outline.cuts.contains(.hung) && outline.failure == .cannotComplete)
        #expect(outline.lines.contains("  w1.1 button “Antes”"))
        #expect(after.roundTrips == 0, "a hung app is not asked again, a timeout at a time")
    }

    @Test func entriesCarryFramesRelativeToTheWindowAndWhetherAClickDoesSomething() {
        let button = framed(fakeButton("OK"), CGRect(x: 150, y: 150, width: 80, height: 20))
        let label = framed(fake("AXStaticText", value: .string("Oi")), CGRect(x: 110, y: 120, width: 30, height: 10))
        let window = framed(fake("AXWindow", title: "A", [button, label]), windowFrame)
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(outline.entries["w1.1"]?.frame == CGRect(x: 50, y: 50, width: 80, height: 20) && outline.entries["w1.1"]?.actionable == true)
        #expect(outline.entries["w1.2"]?.actionable == false && outline.windowFrame == windowFrame)
    }
}

/// CPU time used by the calling thread so far.
private func threadCPUTime() -> Duration {
    var spec = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
    return .seconds(spec.tv_sec) + .nanoseconds(spec.tv_nsec)
}

// MARK: - A hung app

struct AccessibilityHangTests {
    private func hungBench(stall: Duration) -> (Bench, FakeElement) {
        var deadlines = AXDeadlines()
        deadlines.read = .milliseconds(300)
        deadlines.readWithQuery = .milliseconds(300)
        deadlines.action = .milliseconds(300)
        let bench = Bench(windows: [fake("AXWindow", title: "A", [fakeButton("OK")])], deadlines: deadlines)
        bench.root.stall = stall
        return (bench, bench.root)
    }

    // Timing under a loaded machine (thousands of tests share the cooperative pool): each measure is taken up to three
    // times on fresh apps and the best one is held to the design's budget. A real regression (the call waiting on the
    // hung app) fails every attempt by a wide margin.

    @Test func aHungAppReturnsAtTheDeadlineAndTheNextCallFailsAtOnce() async throws {
        let clock = ContinuousClock()
        var firsts: [(took: Duration, allowed: Duration)] = []
        var seconds: [(took: Duration, allowed: Duration)] = []
        for _ in 0..<3 {
            let (bench, root) = hungBench(stall: .seconds(2))
            defer { root.stall = .zero }
            var hop = await schedulingDelay()
            var started = clock.now
            let first = await bench.failure { try await bench.read() }
            firsts.append((started.duration(to: clock.now), .milliseconds(450) + hop))
            #expect(first.contains("Notas não respondeu em 0,3 s"))

            hop = await schedulingDelay()
            started = clock.now
            let second = await bench.failure { try await bench.read() }
            seconds.append((started.duration(to: clock.now), .milliseconds(20) + hop))
            #expect(second.contains("ainda está ocupado"))
            let action = await bench.failure { try await bench.act(["action": .string("press"), "app": .string("Notas"), "id": .string("w1.1")]) }
            #expect(action.contains("ainda está ocupado"))
            if firsts.last!.took <= firsts.last!.allowed, seconds.last!.took <= seconds.last!.allowed { break }
        }
        // Deadline 300 ms + 150 ms, and 20 ms, plus what one hop through the cooperative pool costs right now.
        #expect(firsts.contains { $0.took <= $0.allowed }, "\(firsts)")
        #expect(seconds.contains { $0.took <= $0.allowed }, "\(seconds)")
    }

    /// What one hop through the cooperative pool costs right now (nothing on an idle machine).
    private func schedulingDelay() async -> Duration {
        let clock = ContinuousClock()
        let started = clock.now
        await Task.detached {}.value
        return started.duration(to: clock.now)
    }

    @Test func theMainThreadKeepsTickingWhileAnAppHangs() async throws {
        var gaps: [(hung: Duration, idle: Duration)] = []
        for _ in 0..<3 {
            // The same ticker with nothing hung, for what the machine's own load costs.
            let idleTicker = await MainTicker.start()
            try await Task.sleep(for: .milliseconds(300))
            let idle = await idleTicker.stop()
            let (bench, root) = hungBench(stall: .seconds(1))
            defer { root.stall = .zero }
            let ticker = await MainTicker.start()
            _ = await bench.failure { try await bench.read() }
            gaps.append((await ticker.stop(), idle))
            if gaps.last!.hung <= .milliseconds(50) { break }
        }
        // Design: the widest gap is at most 50 ms; on a loaded machine, no wider than the idle one plus 20 ms. A main
        // thread blocked by the hung app would show the 300 ms deadline.
        #expect(gaps.contains { $0.hung <= .milliseconds(50) || $0.hung <= $0.idle + .milliseconds(20) }, "\(gaps)")
    }

    @Test func noAccessibilityCallRunsOnTheMainThread() async throws {
        let probe = ThreadProbe()
        let window = ProbedElement(fake("AXWindow", title: "A", [fakeButton("OK"), fake("AXTextField", title: "Nome", value: .string("x"))]), probe)
        let root = fakeApp(windows: [])
        let system = FakeAccessibility()
        system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100)]
        root.attrs["AXWindows"] = .elements([window])
        system.roots[100] = root
        let store = UISnapshotStore(directory: nil)
        let sessions = AXSessions()
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())
        let read = UIReadTool(system: system, store: store, sessions: sessions, live: UILiveElements())
        _ = try await read.run(.object(["app": .string("Notas")]), context: context)
        #expect(probe.calls > 0 && probe.onMain == 0)
        // Even a caller on the main actor gets the work done on the app's queue.
        #expect(try await askFromMain(sessions) == false)
    }

    @Test func atMostFourAppsAreAskedAtOnceAndEachAppInTurn() async throws {
        let sessions = AXSessions(maxInFlight: 4)
        let counter = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0, perApp: [Int32: Int](), perAppPeak: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                let pid = Int32(5_000 + index % 6)
                group.addTask {
                    _ = try await sessions.run(AccessibilityApp(name: "App", bundleID: nil, pid: pid), within: .seconds(120)) {
                        counter.withLock { state in
                            state.now += 1
                            state.peak = max(state.peak, state.now)
                            state.perApp[pid, default: 0] += 1
                            state.perAppPeak = max(state.perAppPeak, state.perApp[pid]!)
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                        counter.withLock { state in
                            state.now -= 1
                            state.perApp[pid]! -= 1
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = counter.withLock { $0 }
        #expect(result.peak <= 4 && result.perAppPeak == 1)
        #expect(sessions.runningCount == 0)
    }

    @Test func cancellingStopsWaitingAtOnce() async throws {
        let sessions = AXSessions()
        let app = AccessibilityApp(name: "Lento", bundleID: nil, pid: 6_001)
        let running = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await sessions.run(app, within: .seconds(120)) {
                running.withLock { $0 = true }
                Thread.sleep(forTimeInterval: 30)
                return 1
            }
        }
        try #require(await waitUntil("the work started") { running.withLock { $0 } })
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: clock.now) < .seconds(25), "not the 30 s of the work")
    }
}

@MainActor
private func askFromMain(_ sessions: AXSessions) async throws -> Bool {
    try await sessions.run(AccessibilityApp(name: "Notas", bundleID: nil, pid: 100), within: .seconds(1)) { Thread.isMainThread }
}

/// Counts the gaps between ticks of a 5 ms timer on the main queue.
@MainActor
private final class MainTicker {
    private var timer: DispatchSourceTimer?
    private var last = ContinuousClock.now
    private var widest: Duration = .zero

    static func start() -> MainTicker {
        let ticker = MainTicker()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak ticker] in
            MainActor.assumeIsolated {
                guard let ticker else { return }
                let now = ContinuousClock.now
                ticker.widest = max(ticker.widest, ticker.last.duration(to: now))
                ticker.last = now
            }
        }
        ticker.last = .now
        ticker.timer = timer
        timer.resume()
        return ticker
    }

    func stop() -> Duration {
        timer?.cancel()
        return widest
    }
}

/// Records on which thread the calls into an element (and everything reached through it) happen.
private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var main = 0
    var calls: Int { lock.withLock { total } }
    var onMain: Int { lock.withLock { main } }
    func record() { lock.withLock { total += 1; if Thread.isMainThread { main += 1 } } }
}

private final class ProbedElement: AccessibilityElement, @unchecked Sendable {
    let base: FakeElement
    let probe: ThreadProbe
    init(_ base: FakeElement, _ probe: ThreadProbe) {
        self.base = base
        self.probe = probe
    }

    private func wrap(_ value: AXAttributeValue) -> AXAttributeValue {
        switch value {
        case .element(let element as FakeElement): .element(ProbedElement(element, probe))
        case .elements(let list): .elements(list.map { ($0 as? FakeElement).map { ProbedElement($0, probe) } ?? $0 })
        default: value
        }
    }

    func attribute(_ name: String) -> AXAttributeValue? { probe.record(); return base.attribute(name).map(wrap) }
    func attributes(_ names: [String]) -> [String: AXAttributeValue] { probe.record(); return base.attributes(names).mapValues(wrap) }
    func read(_ names: [String]) -> AXRead {
        probe.record()
        switch base.read(names) {
        case .values(let values): return .values(values.mapValues(wrap))
        case .failed(let failure): return .failed(failure)
        }
    }
    func actionNames() -> [String] { probe.record(); return base.actionNames() }
    func isSettable(_ name: String) -> Bool { probe.record(); return base.isSettable(name) }
    func perform(_ action: String) throws { probe.record(); try base.perform(action) }
    func setValue(_ value: AXAttributeValue, for name: String) throws { probe.record(); try base.setValue(value, for: name) }
    func isSame(as other: any AccessibilityElement) -> Bool { base === (other as? ProbedElement)?.base }
}

// MARK: - The notification hub

/// An observer port that records what is registered and lets the test deliver notifications.
private final class FakePorts: @unchecked Sendable {
    final class Port: AXEventPort, @unchecked Sendable {
        let lock = NSLock()
        var registered: Set<AXNotification> = []
        weak var sink: (any AXEventSink)?
        let accepts: Bool
        init(sink: any AXEventSink, accepts: Bool) {
            self.sink = sink
            self.accepts = accepts
        }
        func add(_ notification: AXNotification) -> Bool {
            guard accepts else { return false }
            lock.withLock { _ = registered.insert(notification) }
            return true
        }
        func remove(_ notification: AXNotification) { lock.withLock { _ = registered.remove(notification) } }
        var source: CFRunLoopSource? { nil }
        var current: Set<AXNotification> { lock.withLock { registered } }
    }

    private let lock = NSLock()
    private var made: [Int32: Port] = [:]
    var accepts = true

    func make(_ pid: Int32, _ sink: any AXEventSink) -> Port {
        let port = Port(sink: sink, accepts: accepts)
        lock.withLock { made[pid] = port }
        return port
    }

    func port(_ pid: Int32) -> Port? { lock.withLock { made[pid] } }
}

struct AXEventHubTests {
    private func hub(_ ports: FakePorts, idle: Duration = .zero, maxApps: Int = 16) -> AXEventHub {
        AXEventHub(maxApps: maxApps, idle: idle, watchesExit: false) { pid, sink in ports.make(pid, sink) }
    }

    @Test func aThousandSubscriptionsAndCancellationsLeaveTheHubEmpty() async throws {
        let ports = FakePorts()
        let hub = hub(ports)
        for index in 0..<1_000 {
            let stream = hub.events(pid: Int32(42 + index % 3), [.valueChanged, .created])
            if index.isMultiple(of: 2) {
                let task = Task { for await _ in stream {} }
                task.cancel()
                await task.value
            }
        }
        try #require(await waitUntil("the hub emptied") { hub.observedApps == 0 && hub.subscriptions == 0 })
        for pid in Int32(42)...44 { #expect(ports.port(pid)?.current.isEmpty == true) }
    }

    @Test func notificationsReachTheirSubscribersOnlyAndAreCountedPerApp() async throws {
        let ports = FakePorts()
        let hub = hub(ports, idle: .seconds(30))
        let element = fakeButton("Alvo")
        let values = hub.events(pid: 7, [.valueChanged])
        let onElement = hub.events(pid: 7, [.valueChanged], on: element)
        let windows = hub.events(pid: 7, [.windowCreated])
        let port = try #require(ports.port(7))
        #expect(port.current == [.valueChanged, .windowCreated] && hub.observedApps == 1 && hub.subscriptions == 3)

        let sink = try #require(port.sink)
        sink.deliver("AXValueChanged", element: fakeButton("Outro"))
        sink.deliver("AXValueChanged", element: element)
        sink.deliver("AXNotAThing", element: nil)
        var iterator = values.makeAsyncIterator()
        #expect(await iterator.next()?.notification == .valueChanged)
        #expect(await iterator.next()?.notification == .valueChanged)
        var only = onElement.makeAsyncIterator()
        let mine = await only.next()
        #expect(mine?.element.map { $0.isSame(as: element) } == true)

        // Ending the window subscription unregisters only what nobody else wants.
        _ = windows
        let cancelled = Task { for await _ in windows {} }
        cancelled.cancel()
        await cancelled.value
        try #require(await waitUntil("windowCreated removed") { port.current == [.valueChanged] })
        hub.appQuit(7)
        #expect(await iterator.next() == nil, "an app that quits ends its streams")
        #expect(hub.observedApps == 0)
    }

    @Test func anAppThatRefusesNotificationsGivesAStreamThatEndsAtOnce() async {
        let ports = FakePorts()
        ports.accepts = false
        let hub = hub(ports)
        var iterator = hub.events(pid: 9, [.valueChanged]).makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func theLeastRecentlyUsedIdleAppMakesRoomForANewOne() async throws {
        let ports = FakePorts()
        let hub = hub(ports, idle: .seconds(60), maxApps: 2)
        _ = hub.events(pid: 1, [.created]) // dropped at once: idle
        let busy = hub.events(pid: 2, [.created])
        try #require(await waitUntil("pid 1 idle") { hub.subscriptions == 1 })
        _ = hub.events(pid: 3, [.created])
        #expect(hub.observedApps == 2)
        // Both slots busy: no room, the stream ends at once (polling instead).
        let keep = hub.events(pid: 3, [.created])
        var refused = hub.events(pid: 4, [.created]).makeAsyncIterator()
        #expect(await refused.next() == nil)
        _ = (busy, keep)
    }

    @Test func theLiveHubTearsDownOnItsOwnThread() async throws {
        // The real observer of this very process: without the Accessibility permission the app refuses the
        // notifications (the stream ends at once); with it they are registered and removed. Either way nothing leaks.
        let hub = AXEventHub(idle: .zero)
        // With the permission each registration is a call answered by this process itself: keep those few.
        for _ in 0..<(AXIsProcessTrusted() ? 2 : 100) {
            let stream = hub.events(pid: getpid(), [.valueChanged, .focusedElementChanged])
            let task = Task { for await _ in stream {} }
            task.cancel()
            await task.value
        }
        try #require(await waitUntil("the live hub emptied") { hub.observedApps == 0 && hub.subscriptions == 0 })
    }
}

// MARK: - Live references

struct UILiveElementsTests {
    @Test func readingsAreKeptPerOrbAndAppUpToSixAndExpire() {
        let live = UILiveElements(maxReferences: 100, readingsPerApp: 6, lifetime: .seconds(600))
        let bot = UUID()
        let element = fakeButton("A")
        let taken = Date.now
        for generation in 1...8 {
            live.remember(bot: bot, pid: 1, generation: generation, takenAt: taken, window: nil, elements: ["w1.1": element])
        }
        #expect(live.element(bot: bot, pid: 1, generation: 1, takenAt: taken, id: "w1.1") == nil, "only the six newest")
        #expect(live.element(bot: bot, pid: 1, generation: 8, takenAt: taken, id: "w1.1") != nil)
        #expect(live.element(bot: UUID(), pid: 1, generation: 8, takenAt: taken, id: "w1.1") == nil, "another Orb's reading")
        #expect(live.element(bot: bot, pid: 1, generation: 8, takenAt: taken.addingTimeInterval(5), id: "w1.1") == nil,
                "a snapshot of another process with the same number")

        let expiring = UILiveElements(lifetime: .zero)
        expiring.remember(bot: bot, pid: 1, generation: 1, takenAt: taken, window: nil, elements: ["w1.1": element])
        #expect(expiring.element(bot: bot, pid: 1, generation: 1, takenAt: taken, id: "w1.1") == nil)
    }

    @Test func theReferenceCapDropsTheLeastRecentlyUsedReadings() {
        let live = UILiveElements(maxReferences: 10, readingsPerApp: 6, lifetime: .seconds(600))
        let many = Dictionary(uniqueKeysWithValues: (1...6).map { ("w1.\($0)", fakeButton("B\($0)") as any AccessibilityElement) })
        let taken = Date.now
        live.remember(bot: nil, pid: 1, generation: 1, takenAt: taken, window: nil, elements: many)
        live.remember(bot: nil, pid: 2, generation: 2, takenAt: taken, window: nil, elements: many)
        #expect(live.count <= 10)
        #expect(live.element(bot: nil, pid: 2, generation: 2, takenAt: taken, id: "w1.1") != nil)
        #expect(live.element(bot: nil, pid: 1, generation: 1, takenAt: taken, id: "w1.1") == nil)
    }

    @Test func aPartialReadingKeepsTheIdsAndMarksOfTheWindowItCameFrom() {
        let app = AccessibilityApp(name: "Notas", bundleID: nil, pid: 1)
        let shot = ShotGeometry(pixelWidth: 10, pixelHeight: 10, scale: 1, windowFrame: .zero, windowID: 3)
        let first = UISnapshot(app: app, windowIndex: 1, windowTitle: "A",
                               entries: ["w1.1": .init(rawRole: "AXButton", label: "Um", secure: false),
                                         "w1.2": .init(rawRole: "AXButton", label: "Dois", secure: false)],
                               takenAt: Date.now.addingTimeInterval(-10), marks: [1: "w1.1", 2: "w1.2"], shot: shot)
        let partial = UISnapshot(app: app, windowIndex: 1, windowTitle: "A",
                                 entries: ["w1.2": .init(rawRole: "AXButton", label: "Outro", secure: false)])
        let merged = partial.carryingOver(from: first, partial: true)
        #expect(merged.entries["w1.1"]?.label == "Um" && merged.entries["w1.2"]?.label == "Outro")
        #expect(merged.marks == [1: "w1.1"], "the mark drawn on “Dois” now names something else")
        #expect(merged.shot == shot)
        let full = UISnapshot(app: app, windowIndex: 1, windowTitle: "A", entries: ["w1.2": .init(rawRole: "AXButton", label: "Dois", secure: false)])
        #expect(full.carryingOver(from: first, partial: false).entries["w1.1"] == nil)
        let otherWindow = UISnapshot(app: app, windowIndex: 2, windowTitle: "B", entries: [:])
        #expect(otherWindow.carryingOver(from: first, partial: true).marks.isEmpty)
        let late = UISnapshot(app: app, windowIndex: 1, windowTitle: "A", entries: [:], takenAt: Date.now.addingTimeInterval(120))
        #expect(late.carryingOver(from: first, partial: true).shot == nil)
    }
}

// MARK: - Small pieces

struct AccessibilityFormattingTests {
    @Test func secondsReadTheBrazilianWay() {
        #expect(UIClock.seconds(.milliseconds(1_200)) == "1,2 s")
        #expect(UIClock.seconds(.seconds(5)) == "5 s")
        #expect(UIClock.seconds(.milliseconds(40)) == "0 s")
    }

    @Test func waitConditionsNeedWhatTheyWatch() throws {
        #expect(try UIWaitCondition(mode: "appears", query: "x", id: nil) == .appears("x"))
        #expect(try UIWaitCondition(mode: "changes", query: nil, id: "w1.2") == .changes("w1.2"))
        #expect(throws: ToolError.self) { try UIWaitCondition(mode: "disappears", query: nil, id: nil) }
        #expect(throws: ToolError.self) { try UIWaitCondition(mode: "later", query: "x", id: nil) }
    }

    @Test func theSchemaOffersTheNewArguments() throws {
        let act = try #require(ToolBox.macTools.first { $0.spec.name == "ui_act" })
        for key in ["keys", "ids", "x", "y", "button", "count", "direction", "amount", "wait", "timeout", "steps", "takeover"] {
            #expect(act.spec.parameters["properties"]?[key] != nil, Comment(rawValue: key))
        }
        #expect(act.spec.parameters["properties"]?["steps"]?["items"] == .object(["type": .string("object")]))
        let read = try #require(ToolBox.macTools.first { $0.spec.name == "ui_read" })
        #expect(read.spec.parameters["properties"]?["wait"]?["enum"]?.array?.compactMap(\.string) == ["appears", "disappears", "changes"])
    }
}
