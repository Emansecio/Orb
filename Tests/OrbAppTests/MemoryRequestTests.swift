import Foundation
import Testing
@testable import Orb

/// What the app does when you asked an Orb to remember something and the model didn't save it (`keepRequestedMemory`).
@Suite @MainActor final class MemoryRequestTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbMemoryRequest-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func setUp() -> (AppModel, BotSession) {
        let store = Store(directory: root.appending(path: "dados"))
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        return (model, model.session(model.bots[0].id))
    }

    private func notices(_ session: BotSession) -> [String] {
        (session.conversation?.items ?? []).compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    private func card(_ decision: ApprovalDecision, tool: String = "remember") -> TranscriptItem.Kind {
        .approval(ApprovalRequest(toolName: tool, title: "Guardar na memória", command: "prefiro respostas curtas", reason: "", decision: decision))
    }

    @Test func aDeniedCardIsNotOverriddenByTheApp() async {
        let (model, session) = setUp()
        session.append(.user(text: "lembre-se de que prefiro respostas curtas", attachments: []))
        session.memoryRequest = (MemoryIntent(content: "prefiro respostas curtas"), 0)
        session.append(card(.deny))
        session.keepRequestedMemory(succeeded: true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await model.memory.bank(for: session.id).snapshot().items(.fato).isEmpty)
        #expect(!notices(session).contains { $0.hasPrefix("Guardado na memória") })
        #expect(notices(session).contains { $0.hasPrefix("Não guardei") })
    }

    @Test func aDeniedCardOfTheClaudeCodeToolOrOfAGroupCountsToo() async {
        for kind in [card(.deny, tool: "mcp__orb_memoria__remember"),
                     .approval(ApprovalRequest(toolName: "batch", title: "Duas ações", command: "", reason: "", decision: .deny,
                                               items: [ApprovalItem(toolName: "remember", title: "a", command: "x"),
                                                       ApprovalItem(toolName: "read_file", title: "b", command: "y")]))] {
            let (model, session) = setUp()
            session.append(.user(text: "lembre-se de que prefiro respostas curtas", attachments: []))
            session.memoryRequest = (MemoryIntent(content: "prefiro respostas curtas"), 0)
            session.append(kind)
            session.keepRequestedMemory(succeeded: true)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(await model.memory.bank(for: session.id).snapshot().items(.fato).isEmpty)
        }
    }

    @Test func withoutADenialTheAppKeepsWhatYouSaid() async {
        let (model, session) = setUp()
        session.append(.user(text: "memorize que prefiro respostas curtas", attachments: []))
        session.memoryRequest = (MemoryIntent(content: "prefiro respostas curtas"), 0)
        session.append(card(.once)) // an allowed card, but the model never saved
        session.keepRequestedMemory(succeeded: true)
        let bank = model.memory.bank(for: session.id)
        await waitUntil("the fact") { await !bank.snapshot().items(.fato).isEmpty }
        #expect(await waitUntil("the notice, once it was kept") { notices(session).contains { $0.hasPrefix("Guardado na memória: prefiro respostas curtas") } })
    }

    @Test func whatCouldNotBeKeptIsNotSaidToBeKept() async {
        let (model, session) = setUp()
        session.append(.user(text: "memorize que prefiro respostas curtas", attachments: []))
        session.memoryRequest = (MemoryIntent(content: "prefiro respostas curtas"), 0)
        model.memory.bank(for: session.id).close() // the page cannot be written
        session.keepRequestedMemory(succeeded: true)
        #expect(await waitUntil("the notice") { notices(session).contains { $0.hasPrefix("Não consegui guardar na memória") } })
        #expect(!notices(session).contains { $0.hasPrefix("Guardado na memória") })
    }

    @Test func aStretchWhosePageWasNotWrittenIsTakenAgainNextTime() async {
        let (model, session) = setUp()
        session.append(.user(text: "vamos planejar a viagem", attachments: []))
        session.append(.bot(text: "Combinado: saímos sexta.", isStreaming: false))
        model.memory.bank(for: session.id).close()
        #expect(session.saveMemory())
        #expect(!session.hasUnsavedStretch()) // marked at once, so a second save does not take it twice
        #expect(await waitUntil("the mark goes back") { session.hasUnsavedStretch() })
        #expect(session.conversation?.memorySavedCount == 0)
    }

    /// A later stretch marked before the earlier page failed does not leave the earlier one behind the mark.
    @Test func aFailedEarlierPageIsTakenAgainWithTheStretchesMarkedSince() async {
        let (model, session) = setUp()
        model.memory.bank(for: session.id).close()
        session.append(.user(text: "Pedido A", attachments: []))
        session.append(.bot(text: "feito A", isStreaming: false))
        #expect(session.saveMemory())
        session.append(.user(text: "Pedido B", attachments: []))
        session.append(.bot(text: "feito B", isStreaming: false))
        #expect(session.saveMemory())
        #expect(await waitUntil("the mark goes back to the first stretch") { session.conversation?.memorySavedCount == 0 })
        _ = await session.memoryWrites?.value
        #expect(session.conversation?.memorySavedCount == 0)
    }

    /// The body is what you said, so the same fact saved later by the model is the same page.
    @Test func theFactSavedByTheAppIsRecognizedWhenTheModelSavesItLater() async {
        let (model, session) = setUp()
        session.append(.user(text: "memorize que meu aniversário é 3 de maio", attachments: []))
        session.memoryRequest = (MemoryIntent(content: "meu aniversário é 3 de maio"), 0)
        session.keepRequestedMemory(succeeded: true)
        let bank = model.memory.bank(for: session.id)
        await waitUntil("the fact") { await !bank.snapshot().items(.fato).isEmpty }
        let saved = await bank.snapshot().items(.fato)
        #expect(saved.map(\.body) == ["meu aniversário é 3 de maio"])
        let page = try? String(contentsOf: bank.directory.appending(path: saved[0].path), encoding: .utf8)
        #expect(page?.contains("origem: \(MemoryOrigin.voce.rawValue)") == true) // who asked stays in the origin
        switch await bank.remember("meu aniversário é 3 de maio") {
        case .alreadyKnown, .updated: break
        default: Issue.record("the same fact must not become a second page")
        }
        #expect(await bank.snapshot().items(.fato).count == 1)
    }
}
