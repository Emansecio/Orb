import Foundation
import Testing
@testable import Orb

/// After a compaction the chat folds what the summary stands for into one line, from the items alone.
@MainActor
struct CompactedFoldTests {
    private func ask(_ text: String, duringTask: Bool = false) -> TranscriptItem {
        TranscriptItem(.user(text: text, attachments: []), duringTask: duringTask)
    }

    private func say(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }

    private func tool() -> TranscriptItem {
        TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls", state: .done)))
    }

    private let compacted = TranscriptItem(.notice("Compactei a conversa: os 2 primeiros pedidos viraram um resumo."))

    @Test func compactingByHandFoldsAllButTheLastExchange() {
        let items = [ask("a"), say("1"), ask("b"), tool(), say("2"), ask("c"), say("3"), compacted]
        let fold = CompactedFold.of(items)
        #expect(fold == CompactedFold(count: 5, messages: 4))
        #expect(fold.title == "4 mensagens anteriores foram resumidas")
    }

    @Test func compactingAtSendingKeepsTheMessageJustSent() {
        let items = [ask("a"), say("1"), ask("b"), say("2"), ask("novo"), compacted, say("3")]
        #expect(CompactedFold.of(items) == CompactedFold(count: 4, messages: 4))
    }

    @Test func aFoldInsideATurnKeepsTheTurnAndItsSteeredMessages() {
        let items = [ask("a"), say("1"), ask("b"), tool(), ask("e mais isso", duringTask: true), tool(), compacted, say("2")]
        #expect(CompactedFold.of(items) == CompactedFold(count: 2, messages: 2))
    }

    @Test func theLatestCompactionDecides() {
        let older = TranscriptItem(.notice("Conversa compactada: o começo virou um resumo.")) // as older versions wrote it
        let items = [ask("a"), say("1"), ask("b"), older, say("2"), ask("c"), say("3"), compacted]
        #expect(CompactedFold.of(items).count == 5)
        #expect(CompactedFold.of(Array(items.prefix(5))) == CompactedFold(count: 2, messages: 2))
    }

    @Test func nothingFoldsWithoutAnEarlierMessageOrForStepsSetAside() {
        #expect(CompactedFold.of([ask("a"), say("1")]) == .none)
        #expect(CompactedFold.of([ask("a"), say("1"), compacted]) == .none)
        let steps = TranscriptItem(.notice("Neste pedido, resumi os 3 primeiros passos para caber no modelo."))
        #expect(CompactedFold.of([ask("a"), say("1"), ask("b"), steps]) == .none)
        #expect(CompactedFold(count: 1, messages: 1).title == "1 mensagem anterior foi resumida")
    }

    @Test func theTranscriptKnowsWhatIsFoldedAndFollowsTheItems() {
        let first = ask("a")
        let items = [first, say("1"), ask("b"), say("2")]
        let transcript = OrbTranscript(items: items)
        #expect(transcript.fold == .none)
        transcript.show(items + [compacted])
        #expect(transcript.fold == CompactedFold(count: 2, messages: 2))
        #expect(transcript.folds(first.id))
        #expect(!transcript.folds(items[2].id))
        // A rewind past the notice unfolds the chat.
        transcript.show(Array(items.prefix(3)))
        #expect(transcript.fold == .none)
        #expect(!transcript.folds(first.id))
    }

    @Test func foldedRowsCountOnlyRowsMadeOfFoldedItems() {
        let atlas = OrbRef(id: UUID(), name: "Atlas"), lia = OrbRef(id: UUID(), name: "Lia")
        let created = TranscriptItem(.event(OrbEvent(kind: .orbCreated, actor: atlas, subject: lia, detail: nil, chainID: nil)))
        let alsoCreated = TranscriptItem(.event(OrbEvent(kind: .orbCreated, actor: atlas, subject: lia, detail: nil, chainID: nil)))
        let items = [ask("a"), created, alsoCreated, say("1"), ask("b"), say("2"), compacted]
        let transcript = OrbTranscript(items: items)
        #expect(transcript.rows != nil) // the two events fold into one row
        #expect(transcript.fold.count == 4)
        #expect(transcript.foldedRows == 3)
    }
}
