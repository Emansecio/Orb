import Foundation
import Testing
@testable import Orb

// ui_read and ui_act against a fake interface tree. The real Accessibility API is never called here: no other app is
// read or clicked and no permission prompt can appear.

// MARK: - A fake interface

final class FakeElement: AccessibilityElement, @unchecked Sendable {
    private let lock = NSLock()
    var attrs: [String: AXAttributeValue] = [:]
    var children: [FakeElement] = []
    var actions: [String] = []
    var settable: Set<String> = []
    var onPerform: (@Sendable (String) -> Void)?
    private var log: [String] = []
    private var performedActions: [String] = []
    private var assigned: [String: AXAttributeValue] = [:]

    /// Names of the attributes that were asked of this element.
    var reads: [String] { lock.withLock { log } }
    var performed: [String] { lock.withLock { performedActions } }
    func assignedValue(_ name: String) -> AXAttributeValue? { lock.withLock { assigned[name] } }

    func attribute(_ name: String) -> AXAttributeValue? {
        lock.withLock { log.append(name) }
        if name == "AXChildren" { return .elements(children) }
        return attrs[name]
    }

    func actionNames() -> [String] { actions }
    func isSettable(_ name: String) -> Bool { settable.contains(name) }

    func perform(_ action: String) throws {
        guard actions.contains(action) else { throw AXFailure.notSupported }
        lock.withLock { performedActions.append(action) }
        onPerform?(action)
    }

    func setValue(_ value: AXAttributeValue, for name: String) throws {
        guard settable.contains(name) else { throw AXFailure.notSupported }
        lock.withLock { assigned[name] = value }
        attrs[name] = value
    }
}

func fake(_ role: String, title: String? = nil, description: String? = nil, value: AXAttributeValue? = nil, placeholder: String? = nil,
          size: CGSize? = CGSize(width: 80, height: 20), subrole: String? = nil, enabled: Bool? = nil, focused: Bool? = nil,
          selected: Bool? = nil, hidden: Bool? = nil, actions: [String] = [], _ children: [FakeElement] = []) -> FakeElement {
    let element = FakeElement()
    element.attrs["AXRole"] = .string(role)
    if let title { element.attrs["AXTitle"] = .string(title) }
    if let description { element.attrs["AXDescription"] = .string(description) }
    if let value { element.attrs["AXValue"] = value }
    if let placeholder { element.attrs["AXPlaceholderValue"] = .string(placeholder) }
    if let size { element.attrs["AXSize"] = .size(size) }
    if let subrole { element.attrs["AXSubrole"] = .string(subrole) }
    if let enabled { element.attrs["AXEnabled"] = .bool(enabled) }
    if let focused { element.attrs["AXFocused"] = .bool(focused) }
    if let selected { element.attrs["AXSelected"] = .bool(selected) }
    if let hidden { element.attrs["AXHidden"] = .bool(hidden) }
    element.actions = actions
    element.children = children
    return element
}

func fakeButton(_ title: String, actions: [String] = ["AXPress"]) -> FakeElement { fake("AXButton", title: title, actions: actions) }

/// An app with windows and a menu bar.
func fakeApp(windows: [FakeElement], menus: [FakeElement]? = nil) -> FakeElement {
    let root = fake("AXApplication", size: nil)
    root.attrs["AXWindows"] = .elements(windows)
    if let menus { root.attrs["AXMenuBar"] = .element(fake("AXMenuBar", size: nil, menus)) }
    if let first = windows.first { root.attrs["AXFocusedWindow"] = .element(first) }
    return root
}

/// `Arquivo > Exportar… > PDF…`, as the real tree nests it: bar item → AXMenu → items.
func fakeMenu(_ title: String, _ items: [FakeElement]) -> FakeElement {
    fake("AXMenuBarItem", title: title, actions: ["AXPress"], [fake("AXMenu", size: nil, items)])
}

func fakeMenuItem(_ title: String, enabled: Bool? = nil, submenu: [FakeElement]? = nil) -> FakeElement {
    fake("AXMenuItem", title: title, enabled: enabled, actions: ["AXPress"], submenu.map { [fake("AXMenu", size: nil, $0)] } ?? [])
}

final class FakeAccessibility: AccessibilitySystem, @unchecked Sendable {
    private let lock = NSLock()
    var trusted = true
    var apps: [RunningAppInfo] = []
    var roots: [Int32: FakeElement] = [:]
    private var rootRequests = 0
    private var activations: [Int32] = []

    var rootCalls: Int { lock.withLock { rootRequests } }
    var activated: [Int32] { lock.withLock { activations } }

    func isTrusted() -> Bool { trusted }
    func runningApps() async -> [RunningAppInfo] { apps }
    func root(of app: AccessibilityApp) -> any AccessibilityElement {
        lock.withLock { rootRequests += 1 }
        return roots[app.pid] ?? fake("AXApplication", size: nil)
    }
    func activate(_ app: AccessibilityApp) { lock.withLock { activations.append(app.pid) } }

    static func app(_ name: String, _ bundleID: String, pid: Int32, active: Bool = false) -> RunningAppInfo {
        RunningAppInfo(name: name, bundleID: bundleID, pid: pid, isActive: active, isHidden: false, isRegular: true)
    }
}

private let notes = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 100)

// MARK: - Outline

struct UIOutlineTests {
    private func sampleWindow() -> FakeElement {
        fake("AXWindow", title: "Notas", [
            fake("AXToolbar", [
                fakeButton("Nova nota"),
                fake("AXButton", description: "Compartilhar"),
                fake("AXTextField", title: "Buscar", placeholder: "Digite aqui"),
            ]),
            fake("AXGroup", [
                fake("AXList", [fake("AXRow", [fake("AXStaticText", value: .string("Compras")), fake("AXStaticText", value: .string("Leite e pão"))])]),
            ]),
            fake("AXTextField", value: .string("segredo"), subrole: "AXSecureTextField"),
            fake("AXCheckBox", title: "Fixar", value: .number(1), enabled: false, focused: true),
            fake("AXGroup", size: .zero, [fakeButton("Fantasma")]),
            fake("AXImage"),
        ])
    }

    @Test func rolesLayoutGroupsAndEmptyLeavesShapeTheOutline() {
        let outline = UIOutlineBuilder.outline(of: sampleWindow(), prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(outline.lines == [
            "w1 window “Notas”",
            "  w1.1 toolbar",
            "    w1.1.1 button “Nova nota”",
            "    w1.1.2 button “Compartilhar”",
            "    w1.1.3 field “Buscar” placeholder=\"Digite aqui\"",
            "  w1.2.1 list",
            "    w1.2.1.1 row",
            "      w1.2.1.1.1 text “Compras”",
            "      w1.2.1.1.2 text “Leite e pão”",
            "  w1.3 field value=<oculto>",
            "  w1.4 checkbox “Fixar” value=\"1\" [desativado, foco]",
        ])
        #expect(outline.cuts.isEmpty)
    }

    @Test func idsCountEveryChildSoSkippedSiblingsDoNotShiftThem() {
        let outline = UIOutlineBuilder.outline(of: sampleWindow(), prefix: "w2", query: nil, limits: UIOutlineLimits())
        // The invisible group (5th) and the empty image (6th) are not listed, and the layout group (2nd) is folded away,
        // yet the list under it keeps the path through the group.
        #expect(outline.entries["w2.2.1"]?.rawRole == "AXList")
        #expect(outline.entries["w2.4"]?.label == "Fixar")
        #expect(outline.entries["w2.5"] == nil && outline.entries["w2.5.1"] == nil)
    }

    @Test func aPasswordFieldIsNeverReadAndIsMarkedHidden() throws {
        let window = sampleWindow()
        let secure = window.children[2]
        _ = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(!secure.reads.contains("AXValue"))
        #expect(window.children[3].reads.contains("AXValue"))
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: "segredo", limits: UIOutlineLimits())
        #expect(outline.lines.isEmpty, "the value must not be searchable either")
        #expect(outline.entries["w1.3"] == nil)
    }

    @Test func aSecureFieldIsRecognizedByItsRoleDescriptionToo() {
        let field = fake("AXTextField", value: .string("x"))
        field.attrs["AXRoleDescription"] = .string("secure text field")
        let outline = UIOutlineBuilder.outline(of: fake("AXWindow", [field]), prefix: "w1", query: nil, limits: UIOutlineLimits())
        #expect(outline.lines.contains("  w1.1 field value=<oculto>"))
        #expect(!field.reads.contains("AXValue"))
    }

    @Test func valuesAreFlattenedAndCutAtEightyCharacters() throws {
        let long = String(repeating: "abcdefghij", count: 12) + "\nsegunda linha"
        let window = fake("AXWindow", title: "T", [fake("AXTextArea", title: "Corpo", value: .string(long))])
        let line = try #require(UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: UIOutlineLimits()).lines.last)
        let value = try #require(line.range(of: #"value="([^"]*)""#, options: .regularExpression).map { String(line[$0]) })
        #expect(value.hasSuffix("…\""))
        #expect(value.count <= "value=\"".count + 80 + 1)
        #expect(!line.contains("segunda"))
    }

    @Test func theLineCapCutsTheOutlineAndSaysHowMuchWasLeftOut() {
        let window = fake("AXWindow", title: "Grande", (1...30).map { fakeButton("Botão \($0)") })
        var limits = UIOutlineLimits()
        limits.maxLines = 10
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: limits)
        #expect(outline.lines.count == 10 && outline.total == 31)
        #expect(outline.cuts == [.lines])
        #expect(outline.entries.count == 10, "only the ids that were shown can be acted on")
    }

    @Test func theDepthCapStopsDescendingAndReportsIt() {
        var element = fakeButton("fundo")
        for _ in 0..<6 { element = fake("AXToolbar", [element]) }
        let window = fake("AXWindow", title: "Fundo", [element])
        var limits = UIOutlineLimits()
        limits.maxDepth = 3
        let outline = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: limits)
        #expect(outline.cuts.contains(.depth))
        #expect(outline.lines.count == 4, "window plus three levels")
        #expect(!outline.lines.joined().contains("fundo"))
    }

    @Test func theVisitCapAndTheClockStopAHugeOrSlowWalk() {
        let window = fake("AXWindow", title: "Enorme", (1...50).map { fakeButton("B\($0)") })
        var limits = UIOutlineLimits()
        limits.maxVisited = 10
        #expect(UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: limits).cuts.contains(.visited))

        limits = UIOutlineLimits()
        limits.seconds = 0
        let slow = UIOutlineBuilder.outline(of: window, prefix: "w1", query: nil, limits: limits)
        #expect(slow.cuts.contains(.time) && slow.lines.isEmpty)
    }

    @Test func aQueryKeepsTheMatchesAndTheElementsAroundThem() {
        let outline = UIOutlineBuilder.outline(of: sampleWindow(), prefix: "w1", query: "COMPRAS", limits: UIOutlineLimits())
        #expect(outline.lines == [
            "w1 window “Notas”",
            "  w1.2.1 list",
            "    w1.2.1.1 row",
            "      w1.2.1.1.1 text “Compras”",
        ])
        #expect(outline.matched == 1)
        // Role names are searchable, accents and case do not matter.
        let buttons = UIOutlineBuilder.outline(of: sampleWindow(), prefix: "w1", query: "Button", limits: UIOutlineLimits())
        #expect(buttons.matched == 2)
        #expect(UIOutlineBuilder.outline(of: sampleWindow(), prefix: "w1", query: "pao", limits: UIOutlineLimits()).matched == 1)
    }

    @Test func roleNamesAreShort() {
        #expect(UIRole.short("AXButton") == "button" && UIRole.short("AXMenuBarItem") == "menubaritem")
        #expect(UIRole.short("AXCustomThing") == "customthing" && UIRole.short("") == "element")
    }

    @Test func theMenuBarListsItsTopLevelMenusWithIds() throws {
        let root = fakeApp(windows: [], menus: [fakeMenu("Arquivo", []), fakeMenu("Editar", [])])
        let menus = try #require(UIOutlineBuilder.menuBar(of: root))
        #expect(menus.lines == ["m1 menubaritem “Arquivo”", "m2 menubaritem “Editar”"])
        #expect(menus.entries["m2"]?.label == "Editar")
        #expect(UIOutlineBuilder.menuBar(of: fakeApp(windows: [])) == nil)
    }
}

// MARK: - ui_read

struct UIReadToolTests {
    private let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())

    private func setup(trusted: Bool = true, windows: [FakeElement], menus: [FakeElement]? = nil,
                       active: Bool = true) -> (UIReadTool, FakeAccessibility, UISnapshotStore) {
        let system = FakeAccessibility()
        system.trusted = trusted
        system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100, active: active),
                       FakeAccessibility.app("Safari", "com.apple.Safari", pid: 200)]
        system.roots[100] = fakeApp(windows: windows, menus: menus)
        let store = UISnapshotStore(directory: nil)
        return (UIReadTool(system: system, store: store), system, store)
    }

    private func read(_ tool: UIReadTool, _ arguments: [String: JSONValue] = [:]) async throws -> String {
        try await tool.run(.object(arguments), context: context)
    }

    private func failure(_ body: () async throws -> String) async -> String {
        do { _ = try await body(); return "" } catch { return error.localizedDescription }
    }

    @Test func withoutTheAccessibilityPermissionItReturnsThePermissionProblemAndTouchesNothing() async {
        let (tool, system, _) = setup(trusted: false, windows: [fake("AXWindow", title: "A")])
        let message = await failure { try await read(tool) }
        #expect(message == MacPermissionProblem.accessibility.modelMessage)
        #expect(MacPermissionProblem.detect(in: message) == .accessibility, "the transcript row offers Abrir Ajustes")
        #expect(message.contains("Acessibilidade"))
        #expect(system.rootCalls == 0)
    }

    @Test func readsTheFrontmostAppByDefaultAndShowsTheWindowList() async throws {
        let (tool, _, _) = setup(windows: [fake("AXWindow", title: "Compras", [fakeButton("Salvar")]), fake("AXWindow", title: "Rascunho")])
        let text = try await read(tool)
        #expect(text.hasPrefix("App: Notas (com.apple.Notes)\nJanelas: 1 “Compras” (lida) · 2 “Rascunho”\n"))
        #expect(text.contains("w1 window “Compras”") && text.contains("  w1.1 button “Salvar”"))
        #expect(!text.contains("Menus da barra"), "menus only on request")
    }

    @Test func chooseTheWindowByNumberOrTitleAndTheFocusedOneWhenNoneIsGiven() async throws {
        let first = fake("AXWindow", title: "Primeira", [fakeButton("A")])
        let second = fake("AXWindow", title: "Segunda Janela", focused: true, [fakeButton("B")])
        let (tool, _, _) = setup(windows: [first, second])
        #expect(try await read(tool).contains("w2 window “Segunda Janela”"), "the focused window wins over the first")
        #expect(try await read(tool, ["window": .string("1")]).contains("w1 window “Primeira”"))
        #expect(try await read(tool, ["window": .number(1)]).contains("w1 window “Primeira”"), "a JSON number is a position too")
        #expect(try await read(tool, ["window": .string("primeira")]).contains("w1 window “Primeira”"))
        let outOfRange = await failure { try await read(tool, ["window": .string("5")]) }
        #expect(outOfRange.contains("2 janelas") && outOfRange.contains("Janelas: 1"))
        let unknown = await failure { try await read(tool, ["window": .string("nada")]) }
        #expect(unknown.contains("Nenhuma janela"))
    }

    @Test func menusAreListedOnRequestAndTheirIdsWork() async throws {
        let (tool, _, store) = setup(windows: [fake("AXWindow", title: "A")], menus: [fakeMenu("Arquivo", []), fakeMenu("Editar", [])])
        let text = try await read(tool, ["include_menus": .bool(true)])
        #expect(text.contains("Menus da barra:\nm1 menubaritem “Arquivo”\nm2 menubaritem “Editar”"))
        let snapshot = try #require(store.snapshot(bot: context.botID, app: notes))
        #expect(snapshot.entries["m2"]?.label == "Editar" && snapshot.entries["w1"]?.rawRole == "AXWindow")
    }

    @Test func anAppWithoutWindowsSaysSoAndOffersTheMenus() async throws {
        let (tool, _, store) = setup(windows: [], menus: [fakeMenu("Arquivo", [])])
        let text = try await read(tool)
        #expect(text.contains("não tem janelas") && text.contains("m1 menubaritem “Arquivo”") && text.contains("pick_menu"))
        #expect(store.snapshot(bot: context.botID, app: notes)?.windowIndex == nil)
    }

    @Test func anAppThatIsNotRunningOrDoesNotAnswerIsAClearError() async {
        let (tool, system, _) = setup(windows: [])
        let closed = await failure { try await read(tool, ["app": .string("Pages")]) }
        #expect(closed.contains("\"Pages\" não está aberto") && closed.contains("open"))

        system.roots[100] = FakeElement() // answers nothing at all, like a hung app
        let silent = await failure { try await read(tool) }
        #expect(silent.contains("não respondeu"))
    }

    @Test func theFrontmostAppIsNeverTheOrbItselfAndTheOrbCannotBeNamed() async {
        let system = FakeAccessibility()
        system.apps = [FakeAccessibility.app("Orb", "app.orb", pid: 1, active: true), FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100)]
        system.roots[100] = fakeApp(windows: [fake("AXWindow", title: "A")])
        #expect(UIAppResolver.resolve(nil, in: system.apps, ownPID: 1, ownBundleID: "app.orb") == .failure(.frontmostIsOrb))
        #expect(UIAppResolver.resolve("Orb", in: system.apps, ownPID: 1, ownBundleID: "app.orb") == .failure(.isOrb))
        #expect(UIAppResolver.resolve("app.orb", in: system.apps, ownPID: 999, ownBundleID: "app.orb") == .failure(.isOrb),
                "the Claude Code tools server is another process of the same app")
        #expect(UIAppResolver.resolve("notas", in: system.apps, ownPID: 1, ownBundleID: "app.orb") == .success(notes))
        #expect(UIAppResolver.resolve(nil, in: [], ownPID: 1, ownBundleID: nil) == .failure(.noFrontmost))
    }

    @Test func ambiguousNamesAskForTheExactOne() {
        let apps = [FakeAccessibility.app("Pages", "com.apple.iWork.Pages", pid: 1), FakeAccessibility.app("Page Maker", "x.pm", pid: 2)]
        guard case .failure(.ambiguous(let names)) = UIAppResolver.resolve("page", in: apps, ownPID: 9, ownBundleID: nil) else {
            Issue.record("expected ambiguity")
            return
        }
        #expect(names == ["Page Maker", "Pages"])
    }

    @Test func aQueryThatMatchesNothingSaysSoAndMaxDepthIsClamped() async throws {
        let (tool, _, _) = setup(windows: [fake("AXWindow", title: "A", [fakeButton("Salvar")])])
        #expect(try await read(tool, ["query": .string("zzz")]).contains("Nenhum elemento combina com “zzz”"))
        var instant = UIOutlineLimits()
        instant.seconds = 0 // the clock stops the walk before the first line
        let blank = try UIReadTool.read(root: fakeApp(windows: [fake("AXWindow", title: "Vazia", [fakeButton("A")])]), app: notes, window: nil,
                                        query: nil, includeMenus: false, limits: instant)
        #expect(blank.text.contains("Não consegui ler elementos desta janela.") && !blank.text.contains("combina com"))
        let shallow = try await read(tool, ["max_depth": .number(1)])
        #expect(shallow.contains("w1.1 button") && !shallow.contains("Saída cortada"))
        let tooDeep = try await read(tool, ["max_depth": .number(99)])
        #expect(tooDeep.contains("w1.1 button"))
        let cut = try await read(tool, ["max_depth": .number(0)]) // clamped to 1: the window and its direct children
        #expect(cut.contains("w1.1 button"))
    }

    @Test func aCutOutlineSaysSo() async throws {
        let (_, system, store) = setup(windows: [fake("AXWindow", title: "Grande", (1...30).map { fakeButton("Botão \($0)") })])
        var limits = UIOutlineLimits()
        limits.maxLines = 5
        let tool = UIReadTool(system: system, store: store, limits: limits)
        let text = try await read(tool)
        #expect(text.contains("[Saída cortada: mostrei 5 de 31 elementos"))
        #expect(text.contains("query"))
    }

    @Test func readingSavesTheSnapshotPerOrb() async throws {
        let (tool, _, store) = setup(windows: [fake("AXWindow", title: "A", [fakeButton("Salvar")])])
        _ = try await read(tool)
        let snapshot = try #require(store.snapshot(bot: context.botID, app: notes))
        #expect(snapshot.windowIndex == 1 && snapshot.windowTitle == "A" && snapshot.entries["w1.1"]?.label == "Salvar")
        #expect(snapshot.app == notes)
    }

    @Test func readIsSafeAndNeedsTheMacCapability() {
        let tool = UIReadTool(system: FakeAccessibility(), store: UISnapshotStore(directory: nil))
        #expect(tool.risk(.object([:])) == .safe && tool.capability == .computerUse && tool.kind == .computer)
        #expect(tool.summary(.object(["app": .string("Notas"), "query": .string("x")])).title == "Lendo a interface de Notas")
    }
}

// MARK: - ui_act

struct UIActToolTests {
    private let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())

    private struct Rig {
        var read: UIReadTool
        var act: UIActTool
        var system: FakeAccessibility
        var store: UISnapshotStore
        var root: FakeElement
    }

    private func rig(windows: [FakeElement], menus: [FakeElement]? = nil, directory: URL? = nil) -> Rig {
        let system = FakeAccessibility()
        system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 100, active: true)]
        let root = fakeApp(windows: windows, menus: menus)
        system.roots[100] = root
        let store = UISnapshotStore(directory: directory)
        return Rig(read: UIReadTool(system: system, store: store),
                   act: UIActTool(system: system, store: store, settle: .zero, activation: .zero), system: system, store: store, root: root)
    }

    private func act(_ rig: Rig, _ arguments: [String: JSONValue]) async throws -> String {
        try await rig.act.run(.object(arguments), context: context)
    }

    private func readFirst(_ rig: Rig) async throws {
        _ = try await rig.read.run(.object([:]), context: context)
    }

    private func failure(_ body: () async throws -> String) async -> String {
        do { _ = try await body(); return "" } catch { return error.localizedDescription }
    }

    // MARK: Pressing and checking

    @Test func pressClicksTheElementTheIdNamedAndReportsWhatChanged() async throws {
        let open = fakeButton("Abrir")
        let window = fake("AXWindow", title: "Principal", [fakeButton("Outro"), open])
        let rig = rig(windows: [window])
        open.onPerform = { _ in rig.root.attrs["AXWindows"] = .elements([window, fake("AXWindow", title: "Salvar como")]) }
        try await readFirst(rig)

        let text = try await act(rig, ["action": .string("press"), "id": .string("w1.2")])
        #expect(text.hasPrefix("Cliquei em button “Abrir” (w1.2)."))
        #expect(text.contains("Mudou: abriu a janela “Salvar como”"))
        #expect(open.performed == ["AXPress"])
    }

    @Test func aValueThatChangedIsReportedWithTheOldOne() async throws {
        let box = fake("AXCheckBox", title: "Fixar", value: .number(0), actions: ["AXPress"])
        box.onPerform = { _ in box.attrs["AXValue"] = .number(1) }
        let rig = rig(windows: [fake("AXWindow", title: "A", [box])])
        try await readFirst(rig)
        let text = try await act(rig, ["action": .string("press"), "id": .string("w1.1")])
        #expect(text.contains("valor “1”") && text.contains("antes: valor “0”"))
    }

    @Test func whenNothingChangesTheModelIsToldToLookAgain() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("Nada")])])
        try await readFirst(rig)
        let text = try await act(rig, ["action": .string("press"), "id": .string("w1.1")])
        #expect(text.contains("Nada visível mudou") && text.contains("ui_read"))
    }

    @Test func actingBeforeReadingOrWithAnUnknownIdIsRefused() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("X")])])
        let early = await failure { try await act(rig, ["action": .string("press"), "id": .string("w1.1")]) }
        #expect(early.contains("chame ui_read antes"))
        try await readFirst(rig)
        let unknown = await failure { try await act(rig, ["action": .string("press"), "id": .string("w1.9")]) }
        #expect(unknown.contains("não está na última leitura"))
        let malformed = await failure { try await act(rig, ["action": .string("press"), "id": .string("botão salvar")]) }
        #expect(malformed.contains("Id inválido"))
    }

    @Test func aChangedInterfaceIsDetectedBeforeAnythingIsClicked() async throws {
        func build() -> (Rig, FakeElement, FakeElement) {
            let target = fakeButton("Salvar")
            let window = fake("AXWindow", title: "Doc", [fakeButton("Antes"), target])
            return (rig(windows: [window]), window, target)
        }
        let stale = "chame ui_read de novo"

        // The element was renamed.
        var (r, _, target) = build()
        try await readFirst(r)
        target.attrs["AXTitle"] = .string("Salvar como…")
        var message = await failure { try await act(r, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains(stale) && target.performed.isEmpty)

        // Something before it disappeared, so the path now leads to another element.
        var window: FakeElement
        (r, window, target) = build()
        try await readFirst(r)
        window.children.removeFirst()
        message = await failure { try await act(r, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains(stale) && target.performed.isEmpty)

        // The element changed role.
        (r, _, target) = build()
        try await readFirst(r)
        target.attrs["AXRole"] = .string("AXCheckBox")
        message = await failure { try await act(r, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains(stale))

        // The window has another title now (a different document).
        (r, window, target) = build()
        try await readFirst(r)
        window.attrs["AXTitle"] = .string("Outro documento")
        message = await failure { try await act(r, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains(stale))

        // The app was relaunched.
        (r, _, target) = build()
        try await readFirst(r)
        r.system.apps = [FakeAccessibility.app("Notas", "com.apple.Notes", pid: 101, active: true)]
        r.system.roots[101] = r.root
        message = await failure { try await act(r, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(message.contains(stale))
    }

    @Test func aWindowThatMovedInTheListIsStillFoundByItsTitle() async throws {
        let target = fakeButton("OK")
        let mine = fake("AXWindow", title: "Minha", [target])
        let rig = rig(windows: [mine, fake("AXWindow", title: "Outra")])
        try await readFirst(rig)
        rig.root.attrs["AXWindows"] = .elements([fake("AXWindow", title: "Outra"), mine])
        _ = try await act(rig, ["action": .string("press"), "id": .string("w1.1")])
        #expect(target.performed == ["AXPress"])
    }

    @Test func elementsWithoutPressFallBackToSelectionOrExplainWhatTheyCanDo() async throws {
        let row = fake("AXRow", title: "Linha")
        row.settable = ["AXSelected"]
        let label = fake("AXStaticText", value: .string("texto"), actions: ["AXShowMenu"])
        let rig = rig(windows: [fake("AXWindow", title: "A", [row, label])])
        try await readFirst(rig)
        #expect(try await act(rig, ["action": .string("press"), "id": .string("w1.1")]).hasPrefix("Selecionei"))
        #expect(row.assignedValue("AXSelected")?.bool == true)
        let refused = await failure { try await act(rig, ["action": .string("press"), "id": .string("w1.2")]) }
        #expect(refused.contains("não aceita clique") && refused.contains("ShowMenu"))
    }

    // MARK: Values, focus, steppers

    @Test func setValueWritesTextOrNumbersAndRefusesReadOnlyElements() async throws {
        let field = fake("AXTextField", title: "Nome", value: .string("velho"))
        field.settable = ["AXValue"]
        let slider = fake("AXSlider", title: "Volume", value: .number(3), actions: ["AXIncrement", "AXDecrement"])
        slider.settable = ["AXValue"]
        let readOnly = fake("AXStaticText", value: .string("fixo"))
        let rig = rig(windows: [fake("AXWindow", title: "A", [field, slider, readOnly])])
        try await readFirst(rig)

        let text = try await act(rig, ["action": .string("set_value"), "id": .string("w1.1"), "value": .string("novo")])
        #expect(text.hasPrefix("Escrevi em field “Nome”") && text.contains("valor “novo”") && text.contains("antes: valor “velho”"))
        #expect(field.assignedValue("AXValue")?.string == "novo")

        _ = try await act(rig, ["action": .string("set_value"), "id": .string("w1.2"), "value": .string("7,5")])
        if case .number(let number)? = slider.assignedValue("AXValue") { #expect(number == 7.5) } else { Issue.record("expected a number") }

        let refused = await failure { try await act(rig, ["action": .string("set_value"), "id": .string("w1.3"), "value": .string("x")]) }
        #expect(refused.contains("não aceita receber um valor"))
        let missing = await failure { try await act(rig, ["action": .string("set_value"), "id": .string("w1.1")]) }
        #expect(missing.contains("\"value\""))
    }

    @Test func incrementDecrementAndFocus() async throws {
        let slider = fake("AXSlider", title: "Volume", value: .number(3), actions: ["AXIncrement"])
        slider.onPerform = { _ in slider.attrs["AXValue"] = .number(4) }
        let field = fake("AXTextField", title: "Busca")
        field.settable = ["AXFocused"]
        let rig = rig(windows: [fake("AXWindow", title: "A", [slider, field])])
        try await readFirst(rig)

        #expect(try await act(rig, ["action": .string("increment"), "id": .string("w1.1")]).contains("valor “4”"))
        let down = await failure { try await act(rig, ["action": .string("decrement"), "id": .string("w1.1")]) }
        #expect(down.contains("não aceita diminuir"))
        #expect(try await act(rig, ["action": .string("focus"), "id": .string("w1.2")]).hasPrefix("Dei foco"))
        #expect(field.assignedValue("AXFocused")?.bool == true)
    }

    @Test func focusFallsBackToRaiseForAWindowThatCannotTakeFocus() async throws {
        let inner = fake("AXWindow", title: "Dentro", actions: ["AXRaise"])
        let rig = rig(windows: [fake("AXWindow", title: "A", [inner])])
        try await readFirst(rig)
        _ = try await act(rig, ["action": .string("focus"), "id": .string("w1.1")])
        #expect(inner.performed == ["AXRaise"])
    }

    @Test func unknownActionsAndFailuresFromTheAPIAreExplained() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("X")])])
        try await readFirst(rig)
        let unknown = await failure { try await act(rig, ["action": .string("triple_click"), "id": .string("w1.1")]) }
        #expect(unknown.contains("Ação desconhecida") && unknown.contains("pick_menu"))
        let noID = await failure { try await act(rig, ["action": .string("press")]) }
        #expect(noID.contains("\"id\""))

        #expect(UIAccess.error(for: AXFailure.cannotComplete, app: notes).localizedDescription.contains("não respondeu a tempo"))
        #expect(UIAccess.error(for: AXFailure.apiDisabled, app: notes).message == MacPermissionProblem.accessibility.modelMessage)
        #expect(UIAccess.error(for: AXFailure.invalidElement, app: notes).message.contains("chame ui_read de novo"))
        #expect(UIAccess.error(for: AXFailure.other(-25205), app: notes).message.contains("-25205"))
    }

    // MARK: Menus

    private func menuRig() -> (Rig, FakeElement, FakeElement) {
        let pdf = fakeMenuItem("PDF…")
        let export = fakeMenuItem("Exportar…", submenu: [fakeMenuItem("Texto"), pdf])
        let print = fakeMenuItem("Imprimir…", enabled: false)
        let rig = rig(windows: [fake("AXWindow", title: "A")],
                      menus: [fakeMenu("Arquivo", [fakeMenuItem("Novo"), export, print]), fakeMenu("Editar", [fakeMenuItem("Copiar")])])
        return (rig, pdf, export)
    }

    @Test func pickMenuWalksThePathAndPressesTheLastItem() async throws {
        let (rig, pdf, _) = menuRig()
        let text = try await act(rig, ["action": .string("pick_menu"), "menu_path": .array(["Arquivo", "Exportar…", "PDF…"].map(JSONValue.string))])
        #expect(text.hasPrefix("Escolhi Arquivo → Exportar… → PDF… em Notas."))
        #expect(pdf.performed == ["AXPress"])
        #expect(rig.system.activated == [100], "the app is brought forward first")
    }

    @Test func menuTitlesMatchIgnoringAccentsCaseAndEllipsisStyle() async throws {
        let (rig, pdf, _) = menuRig()
        for path in [["arquivo", "EXPORTAR...", "pdf..."], ["Arquivo", "Exportar", "PDF"], ["ARQUIVO", "exportar…", "Pdf…"]] {
            pdf.onPerform = nil
            _ = try await act(rig, ["action": .string("pick_menu"), "menu_path": .array(path.map(JSONValue.string))])
        }
        #expect(pdf.performed.count == 3)

        // The same through the helper, including accents on the menu side.
        let items: [any AccessibilityElement] = [fakeMenuItem("Opções…"), fakeMenuItem("Preferências...")]
        #expect(UIMenu.find("opcoes...", in: items)?.title == "Opções…")
        #expect(UIMenu.find("PREFERENCIAS…", in: items)?.title == "Preferências...")
        #expect(UIMenu.find("Opções", in: items)?.title == "Opções…")
        #expect(UIMenu.find("Outra", in: items) == nil)
    }

    @Test func anExactTitleBeatsALooseOne() {
        let items: [any AccessibilityElement] = [fakeMenuItem("Exportar…"), fakeMenuItem("Exportar")]
        #expect(UIMenu.find("Exportar", in: items)?.title == "Exportar")
    }

    @Test func pickMenuExplainsWhatWentWrong() async throws {
        let (rig, _, _) = menuRig()
        func attempt(_ path: [String]) async -> String {
            await failure { try await act(rig, ["action": .string("pick_menu"), "menu_path": .array(path.map(JSONValue.string))]) }
        }
        let unknownTop = await attempt(["Arquivos", "Novo"])
        #expect(unknownTop.contains("Não achei “Arquivos” na barra de menus") && unknownTop.contains("Opções: Arquivo, Editar"))
        let unknownItem = await attempt(["Arquivo", "Fechar"])
        #expect(unknownItem.contains("no menu Arquivo") && unknownItem.contains("Novo, Exportar…, Imprimir…"))
        let disabled = await attempt(["Arquivo", "Imprimir"])
        #expect(disabled.contains("desativado"))
        let noSubmenu = await attempt(["Arquivo", "Novo", "Algo"])
        #expect(noSubmenu.contains("não abre um submenu"))
        let none = await failure { try await act(rig, ["action": .string("pick_menu")]) }
        #expect(none.contains("menu_path"))
    }

    @Test func aMenuPathCanBeGivenAsText() {
        #expect(UIActTool.menuPath(in: .object(["menu_path": .string("Arquivo > Exportar… → PDF")])) == ["Arquivo", "Exportar…", "PDF"])
        #expect(UIActTool.menuPath(in: .object(["menu_path": .array([])])) == nil)
        #expect(UIActTool.menuPath(in: .object([:])) == nil)
    }

    @Test func showMenuOpensAMenuBarMenuAndListsItsItems() async throws {
        let (rig, _, _) = menuRig()
        _ = try await rig.read.run(.object(["include_menus": .bool(true)]), context: context)
        let text = try await act(rig, ["action": .string("show_menu"), "id": .string("m1")])
        #expect(text.contains("Abri o menu"))
        #expect(text.contains("Itens do menu:\n- Novo\n- Exportar… ▸\n- Imprimir… (desativado)"))
        #expect(rig.system.activated == [100])
    }

    // MARK: Danger

    @Test func destructiveWordsAreRecognizedWhateverTheLanguageOrAccent() {
        let dangerous = ["Excluir", "excluir conta", "Apagar tudo", "Deletar", "Delete", "Remove", "Remover item", "Esvaziar Lixeira…",
                         "Empty Trash…", "Esvaziar a Lixeira", "Comprar", "Buy now", "Pagar", "Pay", "Sair sem salvar", "Don't Save",
                         "Don’t Save", "Não Salvar", "Nao salvar", "Formatar…", "Erase Disk", "Descartar alterações"]
        for label in dangerous {
            #expect(UIDanger.reason(forLabel: label, appName: "Finder", bundleID: nil) != nil, Comment(rawValue: label))
        }
        let harmless = ["Salvar", "Comprimir", "Cancelar", "Nova nota", "Enviado", "Paying attention", "Removed from list?", "Abrir", "Formato"]
        for label in harmless {
            // "Removed" is a different word from "Remove": only whole words count.
            #expect(UIDanger.reason(forLabel: label, appName: "Finder", bundleID: nil) == nil, Comment(rawValue: label))
        }
    }

    @Test func sendingOnlyCountsInMailAndMessagingApps() {
        #expect(UIDanger.reason(forLabel: "Enviar", appName: "Mail", bundleID: "com.apple.mail") != nil)
        #expect(UIDanger.reason(forLabel: "Send", appName: "Mensagens", bundleID: nil) != nil)
        #expect(UIDanger.reason(forLabel: "Enviar", appName: "Notas", bundleID: "com.apple.Notes") == nil)
        #expect(UIDanger.reason(forLabel: "Send", appName: nil, bundleID: nil) == nil)
    }

    @Test func pressOnADestructiveElementIsDangerousUsingTheLastReading() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("Excluir"), fakeButton("Salvar")])])
        // Before any reading the tool cannot know what an id is.
        #expect(rig.act.danger(.object(["action": .string("press"), "id": .string("w1.1")])) == nil)
        try await readFirst(rig)
        let delete = rig.act.danger(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Notas")]))
        #expect(delete != nil && delete?.contains("apaga") == true)
        #expect(rig.act.danger(.object(["action": .string("press"), "id": .string("w1.2")])) == nil)
        // Only pressing is judged by the name; the same element is not "dangerous" to focus.
        #expect(rig.act.danger(.object(["action": .string("focus"), "id": .string("w1.1")])) == nil)
        // Another app's name does not borrow Notas's reading.
        #expect(rig.act.danger(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Safari")])) == nil)
        // A partial name resolves to the app (as ui_read does), so it finds the reading too.
        #expect(rig.act.danger(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Not")])) != nil)
    }

    @Test func aPartialAppNameStillFindsTheReadingOfTheFullName() {
        let outlook = AccessibilityApp(name: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", pid: 7)
        let store = UISnapshotStore(directory: nil)
        store.save(UISnapshot(app: outlook, windowIndex: 1, windowTitle: "Caixa", entries: ["w1.5": .init(rawRole: "AXButton", label: "Excluir", secure: false)]), bot: nil)
        let tool = UIActTool(system: FakeAccessibility(), store: store, settle: .zero, activation: .zero)
        let call: JSONValue = .object(["action": .string("press"), "id": .string("w1.5"), "app": .string("Outlook")])
        #expect(tool.danger(call) != nil)
        #expect(tool.summary(call).title == "Clicando em “Excluir”")
    }

    @Test func whenReadingsDisagreeOnAnIdTheDangerousOneDecides() {
        let store = UISnapshotStore(directory: nil)
        let notes = AccessibilityApp(name: "Notas", bundleID: "com.apple.Notes", pid: 1)
        let safari = AccessibilityApp(name: "Safari", bundleID: "com.apple.Safari", pid: 2)
        func reading(_ app: AccessibilityApp, _ label: String, at seconds: TimeInterval) -> UISnapshot {
            UISnapshot(app: app, windowIndex: 1, windowTitle: "A", entries: ["w1.1": .init(rawRole: "AXButton", label: label, secure: false)],
                       takenAt: Date(timeIntervalSince1970: seconds))
        }
        // Two Orbs read the same app and saw different things at w1.3; a newer reading of another app has w1.1 too.
        store.save(reading(notes, "Excluir", at: 10), bot: UUID())
        store.save(reading(notes, "Salvar", at: 20), bot: UUID())
        store.save(reading(safari, "Salvar", at: 30), bot: UUID())
        let tool = UIActTool(system: FakeAccessibility(), store: store, settle: .zero, activation: .zero)
        #expect(tool.danger(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Notas")])) != nil)
        #expect(tool.danger(.object(["action": .string("press"), "id": .string("w1.1")])) != nil, "no app named: every reading counts")
        #expect(tool.danger(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Safari")])) == nil)
        let summary = tool.summary(.object(["action": .string("press"), "id": .string("w1.1")]))
        #expect(summary.title == "Clicando em “Excluir”", "the card shows the element that makes it dangerous")
    }

    @Test func pickMenuIsJudgedByItsLastItem() {
        let rig = rig(windows: [])
        func danger(_ path: [String], app: String? = nil) -> String? {
            var arguments: [String: JSONValue] = ["action": .string("pick_menu"), "menu_path": .array(path.map(JSONValue.string))]
            if let app { arguments["app"] = .string(app) }
            return rig.act.danger(.object(arguments))
        }
        #expect(danger(["Finder", "Esvaziar Lixeira…"]) != nil)
        #expect(danger(["Arquivo", "Mover para a Lixeira"]) == nil)
        // A menu called "Formatar" is only the way there; bold is not an erase.
        #expect(danger(["Formatar", "Negrito"]) == nil)
        #expect(danger(["Mensagem", "Enviar"], app: "Mail") != nil)
        #expect(danger(["Mensagem", "Enviar"], app: "Notas") == nil)
        // With no app named the call is about the frontmost one, which is unknown: sending is asked.
        #expect(danger(["Mensagem", "Enviar"]) != nil)
    }

    @Test func pickMenuWithoutAnAppIsAskedEvenAfterReadingAnotherApp() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("Salvar")])])
        try await readFirst(rig)
        let call: JSONValue = .object(["action": .string("pick_menu"), "menu_path": .array(["Mensagem", "Enviar"].map(JSONValue.string))])
        #expect(rig.act.danger(call) != nil)
    }

    @Test func fillingAPasswordFieldAlwaysAsks() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fake("AXTextField", subrole: "AXSecureTextField"), fake("AXTextField", title: "Nome")])])
        try await readFirst(rig)
        let secure = rig.act.danger(.object(["action": .string("set_value"), "id": .string("w1.1"), "value": .string("x")]))
        #expect(secure?.contains("senha") == true)
        #expect(rig.act.danger(.object(["action": .string("set_value"), "id": .string("w1.2"), "value": .string("x")])) == nil)
        let summary = rig.act.summary(.object(["action": .string("set_value"), "id": .string("w1.1"), "value": .string("topsecret")]))
        #expect(!summary.detail.contains("topsecret"), "the approval card must not print what goes into a password field")
    }

    @Test func theApprovalCardNamesWhatWillBeClicked() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("Excluir nota")])])
        try await readFirst(rig)
        let summary = rig.act.summary(.object(["action": .string("press"), "id": .string("w1.1"), "app": .string("Notas")]))
        #expect(summary.title == "Clicando em “Excluir nota”" && summary.detail == "button w1.1 · Notas")
        let blind = rig.act.summary(.object(["action": .string("press"), "id": .string("w9.9"), "app": .string("Notas")]))
        #expect(blind.title == "Clicando em o elemento w9.9" || blind.title.contains("w9.9"))
        let menu = rig.act.summary(.object(["action": .string("pick_menu"), "menu_path": .array(["Arquivo", "Exportar…"].map(JSONValue.string))]))
        #expect(menu.detail == "Arquivo → Exportar…")
    }

    @Test func dangerReachesThePermissionPolicyAsAForcedAsk() async throws {
        let rig = rig(windows: [fake("AXWindow", title: "A", [fakeButton("Apagar")])])
        try await readFirst(rig)
        let call = PermissionPolicy.call(for: rig.act, arguments: .object(["action": .string("press"), "id": .string("w1.1")]),
                                         context: context)
        #expect(call.family == .appInterface && call.risk == .sensitive && call.danger != nil)
    }

    // MARK: Without the permission

    @Test func actingWithoutThePermissionReturnsTheProblemBeforeTouchingAnything() async {
        let rig = rig(windows: [])
        rig.system.trusted = false
        let message = await failure { try await act(rig, ["action": .string("pick_menu"), "menu_path": .array([.string("Arquivo")])]) }
        #expect(MacPermissionProblem.detect(in: message) == .accessibility)
        #expect(rig.system.rootCalls == 0 && rig.system.activated.isEmpty)
    }
}

// MARK: - Snapshots

struct UISnapshotStoreTests {
    private func snapshot(app: AccessibilityApp = notes, label: String = "Excluir", at date: Date = .now) -> UISnapshot {
        UISnapshot(app: app, windowIndex: 1, windowTitle: "A",
                   entries: ["w1.1": UISnapshot.Entry(rawRole: "AXButton", label: label, secure: false)], takenAt: date)
    }

    @Test func eachOrbKeepsItsOwnReading() {
        let store = UISnapshotStore(directory: nil)
        let one = UUID(), two = UUID()
        store.save(snapshot(label: "Um"), bot: one)
        store.save(snapshot(label: "Dois"), bot: two)
        #expect(store.snapshot(bot: one, app: notes)?.entries["w1.1"]?.label == "Um")
        #expect(store.snapshot(bot: two, app: notes)?.entries["w1.1"]?.label == "Dois")
        #expect(store.snapshot(bot: UUID(), app: notes) == nil, "no file mirror here")
        #expect(store.candidates(matching: "com.apple.notes").count == 2 && store.candidates(matching: "Safari").isEmpty)
        #expect(store.candidates(matching: nil).count == 2)
    }

    @Test func aReadingMadeByAnotherProcessIsFoundThroughTheMirrorFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbAX-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let toolsServer = UISnapshotStore(directory: folder)
        toolsServer.save(snapshot(label: "Apagar"), bot: nil)

        let appProcess = UISnapshotStore(directory: folder)
        #expect(appProcess.candidates(matching: "Notas").first?.entries["w1.1"]?.label == "Apagar")
        #expect(appProcess.snapshot(bot: UUID(), app: notes)?.entries["w1.1"]?.label == "Apagar")
        // Garbage in the folder is ignored.
        try Data("lixo".utf8).write(to: folder.appending(path: "ax-lixo.json"))
        #expect(appProcess.candidates(matching: nil).count == 1)
    }

    @Test func aSnapshotFileWithMissingFieldsStillLoads() throws {
        let json = #"{"app":{"name":"Notas","pid":5},"entries":{"w1":{"rawRole":"AXWindow"},"w1.2":{"bogus":1}},"extra":true}"#
        let loaded = try JSONDecoder().decode(UISnapshot.self, from: Data(json.utf8))
        #expect(loaded.app.pid == 5 && loaded.windowIndex == nil && loaded.windowTitle == "")
        #expect(loaded.entries["w1"]?.label == "" && loaded.entries["w1.2"]?.secure == false)
        let bare = try JSONDecoder().decode(UISnapshot.self, from: Data(#"{"app":{"name":"X","pid":1},"entries":7}"#.utf8))
        #expect(bare.entries.isEmpty)
    }

    @Test func newestReadingsComeFirst() {
        let store = UISnapshotStore(directory: nil)
        store.save(snapshot(app: AccessibilityApp(name: "Antigo", bundleID: nil, pid: 1), at: Date(timeIntervalSince1970: 10)), bot: nil)
        store.save(snapshot(app: AccessibilityApp(name: "Novo", bundleID: nil, pid: 2), at: Date(timeIntervalSince1970: 20)), bot: nil)
        #expect(store.candidates(matching: nil).map(\.app.name) == ["Novo", "Antigo"])
    }
}

// MARK: - What changed

struct UIStateTests {
    @Test func describesWindowsSheetsFocusAndTargetChanges() {
        var before = UIState()
        before.windows = ["A"]
        before.focusedWindow = "A"
        var after = before
        #expect(UIState.describe(from: before, to: after).hasPrefix("Nada visível mudou"))

        after.windows = ["A", "B"]
        #expect(UIState.describe(from: before, to: after) == "Mudou: abriu a janela “B”.")
        after.windows = []
        #expect(UIState.describe(from: before, to: after) == "Mudou: fechou a janela “A”.")

        after = before
        after.focusedWindow = "C"
        after.sheet = true
        after.focusedElement = "field “Nome”"
        #expect(UIState.describe(from: before, to: after) == "Mudou: janela em foco agora: “C”; apareceu um painel (folha) na janela; foco em field “Nome”.")

        after = before
        after.targetGone = true
        #expect(UIState.describe(from: before, to: after) == "Mudou: o elemento não está mais na tela.")
    }

    @Test func untitledWindowsAreNamed() {
        var after = UIState()
        after.windows = [""]
        #expect(UIState.describe(from: UIState(), to: after).contains("(sem título)"))
    }
}

// MARK: - Wiring

struct UIToolWiringTests {
    @Test func theToolsAreRegisteredWithTheRightRiskCapabilityAndFamily() {
        let tools = Dictionary(uniqueKeysWithValues: ToolBox.macTools.map { ($0.spec.name, $0) })
        let read = tools["ui_read"], act = tools["ui_act"]
        #expect(read?.risk(.object([:])) == .safe && read?.capability == .computerUse && read?.kind == .computer)
        #expect(act?.risk(.object([:])) == .sensitive && act?.capability == .computerUse && act?.kind == .computer)
        #expect(PermissionPolicy.family(ofTool: "ui_read", kind: .computer) == .appInterface)
        #expect(PermissionPolicy.family(ofTool: "ui_act", kind: .computer) == .appInterface)
        #expect(PermissionPolicy.legacyRule(forToolName: "ui_act") == PermissionRule(family: .appInterface))
        #expect(PermissionPolicy.legacyRule(forToolName: ClaudeCodeTools.memoryPrefix + "ui_act") == PermissionRule(family: .appInterface))
    }

    @Test func theSchemasNameTheirArguments() throws {
        let read = try #require(ToolBox.macTools.first { $0.spec.name == "ui_read" })
        for key in ["app", "window", "query", "max_depth", "include_menus"] {
            #expect(read.spec.parameters["properties"]?[key] != nil, Comment(rawValue: key))
        }
        let act = try #require(ToolBox.macTools.first { $0.spec.name == "ui_act" })
        let actions = act.spec.parameters["properties"]?["action"]?["enum"]?.array?.compactMap(\.string)
        #expect(actions == ["press", "focus", "set_value", "increment", "decrement", "show_menu", "pick_menu"])
        #expect(act.spec.parameters["required"]?.array?.compactMap(\.string) == ["action"])
    }

    @Test func claudeCodeGetsBothToolsThroughTheToolsServerOnlyWithMacAccess() async throws {
        func listed(mac: Bool) async throws -> [String] {
            let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])
            let reply = try #require(await OrbToolsMCPServer.handle(request, context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory), mac: mac))
            return reply["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        }
        let withMac = try await listed(mac: true)
        #expect(withMac.contains("ui_read") && withMac.contains("ui_act"))
        let without = try await listed(mac: false)
        #expect(!without.contains("ui_read") && !without.contains("ui_act"))

        let tool = try #require(OrbToolsMCPServer.tool(claudeCodeName: ClaudeCodeTools.memoryPrefix + "ui_act"))
        #expect(tool.spec.name == "ui_act")
        let call = PermissionPolicy.call(claudeCodeTool: ClaudeCodeTools.memoryPrefix + "ui_read", input: .object([:]), workspace: nil)
        #expect(call.family == .appInterface && call.risk == .safe)
    }

    @Test func thePromptPointsToAppleScriptFirstAndToReadingBeforeActing() {
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig())
        #expect(bot.capabilities.contains(.computerUse))
        let hints = PromptParts.nativeToolHints(bot)
        #expect(hints.contains("applescript and shortcuts_run") && hints.contains("ui_read then ui_act"))
        #expect(hints.contains("no AppleScript or Shortcuts support") && hints.contains("read the screen before acting"))
        var noMac = bot
        noMac.capabilities.remove(.computerUse)
        #expect(!PromptParts.nativeToolHints(noMac).contains("ui_read"))
    }
}
