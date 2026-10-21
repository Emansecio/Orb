import Foundation
import os
import Testing
@testable import Orb

// What the browser side of the live screen (docs/TELA-AO-VIVO.md) gives the app: where the Orb's pointer is about to go, and
// whether the page it looked at last looked sensitive.

struct LiveScreenPointerTests {
    private let setup = FakeBrowserSetup()
    private let heard = OSAllocatedUnfairLock<[LivePointer]>(initialState: [])
    private let owners = OSAllocatedUnfairLock<[UUID]>(initialState: [])

    private func listen() {
        let heard = heard
        let owners = owners
        setup.hub.setPointerHandler { botID, pointer in
            owners.withLock { $0.append(botID) }
            heard.withLock { $0.append(pointer) }
        }
    }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: setup.context())
    }

    @Test func withoutAListenerTheBrowserIsAskedForNoBoxAtAll() async throws {
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        _ = try await run(BrowseClickTool(), ["ref": .string("e1")])
        _ = try await run(BrowseClickTool(), ["ref": .string("e1"), "action": .string("hover")])
        _ = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("olá")])
        _ = try await run(BrowseSelectTool(), ["ref": .string("e1"), "value": .string("BR")])
        let calls = setup.driver.calls
        #expect(!calls.contains { $0.hasPrefix("box") })
        #expect(calls.contains("click e1") && calls.contains("fill e1 olá") && calls.contains("select e1 BR"), "the actions themselves are untouched")
    }

    @Test func aListenerHearsWhereEachActionGoesAndTheBoxIsAskedJustBefore() async throws {
        let button = CGRect(x: 599, y: 698.5, width: 82, height: 18)
        setup.driver.state.withLock { $0.boxes["e1"] = button }
        listen()

        _ = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(heard.withLock { $0 } == [LivePointer(rect: button, kind: .click)])
        #expect(owners.withLock { $0 } == [setup.botID])
        let calls = setup.driver.calls
        let box = try #require(calls.firstIndex(of: "box e1")), click = try #require(calls.firstIndex(of: "click e1"))
        #expect(box < click, "the box is the element before the action moves it")

        for (action, kind) in [("dblclick", LivePointer.Kind.click), ("check", .click), ("uncheck", .click), ("hover", .hover), ("focus", .hover)] {
            heard.withLock { $0 = [] }
            _ = try await run(BrowseClickTool(), ["ref": .string("e1"), "action": .string(action)])
            #expect(heard.withLock { $0 } == [LivePointer(rect: button, kind: kind)], "\(action)")
        }

        heard.withLock { $0 = [] }
        _ = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("olá")])
        _ = try await run(BrowseSelectTool(), ["ref": .string("e1"), "value": .string("BR")])
        #expect(heard.withLock { $0 } == [LivePointer(rect: button, kind: .type), LivePointer(rect: button, kind: .click)])
    }

    @Test func scrollingAndDraggingHaveNoPointAndAreNotAsked() async throws {
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4); $0.boxes["e2"] = CGRect(x: 5, y: 6, width: 7, height: 8) }
        listen()
        _ = try await run(BrowseClickTool(), ["ref": .string("e1"), "action": .string("scrollintoview")])
        _ = try await run(BrowseClickTool(), ["ref": .string("e1"), "action": .string("drag"), "to": .string("e2")])
        #expect(heard.withLock { $0.isEmpty })
        #expect(!setup.driver.calls.contains { $0.hasPrefix("box") })
    }

    @Test func aBoxThatCannotBeHadOrFailsLeavesTheActionAloneAndQuiet() async throws {
        listen()
        // No box for e1.
        #expect(try await run(BrowseClickTool(), ["ref": .string("e1")]).contains("Clicked e1"))
        #expect(heard.withLock { $0.isEmpty })
        #expect(setup.driver.calls.contains("click e1"))

        // The browser fails for the box and for nothing else: the same failure on the action itself is still the action's.
        setup.driver.state.withLock { $0.failure = .failed("Element @e9 not found") }
        await #expect(throws: BrowserDriverError.self) { _ = try await run(BrowseClickTool(), ["ref": .string("e9")]) }
        #expect(heard.withLock { $0.isEmpty })
    }

    @Test func aSecretFieldRefusedIsNotPointedAt() async throws {
        setup.driver.state.withLock {
            $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4)
            $0.attributes["e1.type"] = "password"
        }
        listen()
        await #expect(throws: ToolError.self) { _ = try await run(BrowseFillTool(), ["ref": .string("e1"), "text": .string("x")]) }
        #expect(heard.withLock { $0.isEmpty })
        #expect(!setup.driver.calls.contains("box e1"))
    }

    @Test func aListenerForAnotherOrbCostsThisOneNoBox() async throws {
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        let heard = heard
        setup.hub.setPointerHandler({ _, pointer in heard.withLock { $0.append(pointer) } }, only: UUID())
        _ = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(heard.withLock { $0.isEmpty })
        #expect(setup.driver.calls.contains("click e1") && !setup.driver.calls.contains("box e1"))
    }

    @Test func removingTheListenerBringsBackTheOldBehavior() async throws {
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        listen()
        setup.hub.setPointerHandler(nil)
        _ = try await run(BrowseClickTool(), ["ref": .string("e1")])
        #expect(setup.driver.calls.contains("click e1") && !setup.driver.calls.contains("box e1"))
        #expect(heard.withLock { $0.isEmpty })
    }

    @Test func theFakeBrowserSaysItsStreamPort() async throws {
        let session = try await setup.hub.session(botID: setup.botID, mode: .background)
        #expect(try await session.driver.streamPort() == nil)
        setup.driver.state.withLock { $0.streamPort = 51955 }
        #expect(try await session.driver.streamPort() == 51955)
    }
}

struct LiveScreenSensitivePageTests {
    private let setup = FakeBrowserSetup()

    private func look(_ tool: some AgentTool, _ arguments: [String: JSONValue] = [:]) async throws {
        _ = try await tool.run(.object(arguments), context: setup.context())
    }

    private func snapshot(_ tree: String, refs: [String: BrowserRef]) {
        setup.driver.state.withLock { $0.snapshot = BrowserSnapshot(url: "https://shop.test/", tree: tree, refs: refs) }
    }

    @Test func anOrbThatHasLookedAtNothingHasNoSensitivePage() {
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    @Test func aLoginOrChallengePageOnOpenIsSensitiveAndAnOrdinaryOneClearsIt() async throws {
        setup.driver.state.withLock { $0.title = "Entrar" }
        try await look(BrowseOpenTool(), ["url": .string("https://site.test/login")])
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))

        setup.driver.state.withLock { $0.title = "Home" }
        try await look(BrowseOpenTool(), ["url": .string("https://site.test/")])
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))

        setup.driver.state.withLock { $0.title = "Just a moment..." }
        try await look(BrowseOpenTool(), ["url": .string("https://site.test/")])
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    @Test func aSnapshotWithAPasswordOrCardFieldIsSensitive() async throws {
        snapshot("- link \"Ajuda\" [ref=e1]", refs: ["e1": BrowserRef(role: "link", name: "Ajuda")])
        try await look(BrowseSnapshotTool())
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))

        snapshot("- textbox \"Email\" [ref=e1]\n- textbox \"Senha\" [ref=e2]",
                 refs: ["e1": BrowserRef(role: "textbox", name: "Email"), "e2": BrowserRef(role: "textbox", name: "Senha")])
        try await look(BrowseSnapshotTool())
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))

        // A card field is not a login, but it is a secret all the same.
        snapshot("- textbox \"Número do cartão\" [ref=e1]", refs: ["e1": BrowserRef(role: "textbox", name: "Número do cartão")])
        try await look(BrowseSnapshotTool())
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))

        snapshot("- button \"Comprar\" [ref=e1]", refs: ["e1": BrowserRef(role: "button", name: "Comprar")])
        try await look(BrowseSnapshotTool())
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    @Test func aReadOfACaptchaPageIsSensitive() async throws {
        setup.driver.state.withLock { $0.readContent = "Please verify you are human to continue" }
        try await look(BrowseReadTool())
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))
        setup.driver.state.withLock { $0.readContent = "Receita de bolo" }
        try await look(BrowseReadTool(), ["offset": .number(0)])
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    @Test func eachOrbHasItsOwnVerdictAndClosingTheBrowserForgetsIt() async throws {
        setup.driver.state.withLock { $0.title = "Entrar" }
        try await look(BrowseOpenTool(), ["url": .string("https://site.test/login")])
        #expect(setup.hub.pageLooksSensitive(botID: setup.botID))
        #expect(!setup.hub.pageLooksSensitive(botID: UUID()))
        await setup.hub.close(botID: setup.botID)
        #expect(!setup.hub.pageLooksSensitive(botID: setup.botID))
    }

    @Test func askingAsksTheBrowserNothing() async throws {
        let before = setup.driver.calls
        _ = setup.hub.pageLooksSensitive(botID: setup.botID)
        #expect(setup.driver.calls == before)
    }
}
