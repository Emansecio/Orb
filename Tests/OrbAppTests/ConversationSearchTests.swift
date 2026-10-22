import Foundation
import SwiftUI
import Testing
@testable import Orb

/// Search inside the open conversation (⌘F). The search reads the stored text of the conversation's items, off the main
/// actor, and answers with a short list of hits; it never builds or measures a row. The chat only scrolls to the hit
/// that is chosen (and its lazy list makes the rows around it).
@Suite("Conversation search") struct ConversationSearchTests {
    // MARK: Helpers

    private func user(_ text: String) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }
    private func bot(_ text: String, streaming: Bool = false) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: streaming)) }
    private func tool(_ title: String, detail: String = "", output: String? = nil) -> TranscriptItem {
        TranscriptItem(.tool(ToolCall(kind: .shell, title: title, detail: detail, state: .done, output: output)))
    }

    private func hits(_ query: String, in items: [TranscriptItem]) throws -> [ConversationSearch.Hit] {
        try ConversationSearch.scan(query, in: items).hits
    }

    // MARK: Matching

    @Test func findsWithoutCaringAboutCaseOrAccents() throws {
        let items = [user("Qual a ação de hoje?"), bot("A AÇÃO foi concluída."), bot("nada aqui"), bot("Coração, Ação e acao")]
        // "Coração" has "ação" inside it: three in the last message.
        #expect(try hits("acao", in: items).map(\.itemIndex) == [0, 1, 3, 3, 3])
        #expect(try hits("AÇÃO", in: items).count == 5)
        #expect(try hits("coracao", in: items).count == 1)
        #expect(try hits("ação", in: items).count == 5)
        // The other way too: plain text found by a query with accents.
        #expect(try hits("coração", in: [bot("o coracao bate")]).count == 1)
    }

    @Test func theActionThatSentAMessageBetweenOrbsIsNotAHit() throws {
        let atlas = OrbRef(id: UUID(), name: "Atlas"), lia = OrbRef(id: UUID(), name: "Lia")
        let ask = TranscriptItem(.orbMessage(OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: atlas, to: lia,
                                                            text: "Escreve o resumo.", requestID: UUID(), chainID: UUID())))
        let send = TranscriptItem(.tool(ToolCall(kind: .orbs, title: "Falando com Lia", detail: "Escreve o resumo.", state: .done)))
        // The message's card is the one hit: the action beside it has no row to scroll to.
        #expect(try hits("resumo", in: [ask, send]).map(\.itemIndex) == [0])
    }

    @Test func aLetterWrittenAsBaseAndCombiningMarkIsTheSameLetter() throws {
        let decomposed = "a\u{0327}\u{0303}" // a + cedilla + tilde, nothing a user types, but pasted text has it
        let items = [bot("Uma ac\u{0327}a\u{0303}o decomposta"), bot("Outra ação composta")]
        #expect(try hits("acao", in: items).count == 2)
        #expect(try hits("ação", in: items).count == 2)
        #expect(try hits(decomposed, in: [bot("xx a yy")]).count == 1)
        // The mark belongs to the match: the range covers the whole letter.
        let found = try #require(try hits("a", in: [bot("á\u{0301}")]).first)
        #expect(found.snippet.match == "á\u{0301}")
    }

    @Test func manyHitsInOneMessageAreNumberedInOrderAndDoNotOverlap() throws {
        let found = try hits("ab", in: [bot("ab ab ab"), bot("aaaa"), bot("abab")])
        #expect(found.map(\.occurrence) == [0, 1, 2, 0, 1])
        #expect(found.map(\.itemIndex) == [0, 0, 0, 2, 2])
        // "aa" in "aaaa": two matches, not three.
        #expect(try hits("aa", in: [bot("aaaa")]).count == 2)
        #expect(found.map(\.id) == Array(found.indices))
    }

    @Test func spacesAndLineBreaksAreTheSame() throws {
        #expect(try hits("bom dia", in: [bot("bom\n\ndia"), bot("bom   dia"), bot("bom\tdia"), bot("bomdia")]).map(\.itemIndex) == [0, 1, 2])
        #expect(try hits("  bom dia \n", in: [bot("bom dia")]).count == 1) // trimmed
    }

    @Test func aQueryOfNothingFindsNothing() throws {
        #expect(try hits("", in: [bot("abc")]).isEmpty)
        #expect(try hits("   \n", in: [bot("abc")]).isEmpty)
        #expect(SearchPattern("\u{0301}") == nil) // only a combining mark
        #expect(try hits("abcd", in: [bot("abc")]).isEmpty)
    }

    @Test func theMatchIsTheOriginalTextNotTheFoldedOne() throws {
        let text = "Preciso da Ação e da AÇÃO"
        let found = try hits("acao", in: [bot(text)])
        #expect(found.map(\.snippet.match) == ["Ação", "AÇÃO"])
    }

    @Test func curlyQuotesMatchStraightOnes() throws {
        #expect(try hits("it's", in: [bot("it’s here")]).count == 1)
        #expect(try hits("“oi”", in: [bot("diga \"oi\"")]).count == 1)
    }

    // MARK: What is searched

    @Test func searchesWhatTheRowsSayAndNotWhatIsHiddenInOutputs() throws {
        let huge = String(repeating: "agulha ", count: 10_000)
        let items = [
            user("agulha do usuário"),
            bot("agulha da resposta"),
            tool("Rodando no Terminal", detail: "grep agulha arquivo.txt", output: huge),
            tool("Lendo README.md", output: "agulha no resultado"),
            TranscriptItem(.notice("Conversa compactada: agulha")),
            TranscriptItem(.greeting("Oi! agulha")),
            TranscriptItem(.approval(ApprovalRequest(toolName: "run_command", title: "agulha", command: "agulha", reason: "agulha"))),
        ]
        let found = try hits("agulha", in: items)
        #expect(found.map(\.source) == [.user, .bot, .tool, .notice, .greeting])
        #expect(found.map(\.itemIndex) == [0, 1, 2, 4, 5])
    }

    @Test func aReplyStillBeingWrittenIsLeftOutUntilItIsClosed() throws {
        #expect(try hits("parcial", in: [bot("resposta parcial", streaming: true)]).isEmpty)
        #expect(try hits("parcial", in: [bot("resposta parcial", streaming: false)]).count == 1)
    }

    // MARK: Snippets

    @Test func aSnippetIsOneShortLineAroundTheMatch() throws {
        let long = String(repeating: "palavra ", count: 200)
        let text = long + "AGULHA\n\n**negrito** e `código`\n" + long
        let hit = try #require(try hits("agulha", in: [bot(text)]).first)
        #expect(hit.snippet.match == "AGULHA")
        #expect(hit.snippet.before.hasPrefix("…") && hit.snippet.after.hasSuffix("…"))
        #expect(!hit.snippet.text.contains("\n"))
        #expect(!hit.snippet.after.contains("*") && !hit.snippet.after.contains("`"))
        #expect(hit.snippet.text.count < 140, "\(hit.snippet.text.count)")
        // Cut between words.
        #expect(hit.snippet.before == "…" + String(repeating: "palavra ", count: 4))
    }

    @Test func aSnippetKeepsSomeContextWhenTheOnlySpaceTouchesTheMatch() throws {
        // A long word right after the match: the only space is the one against it, so the cut goes through the word.
        let after = try #require(try hits("alvo", in: [bot("veja alvo " + String(repeating: "x", count: 120))]).first)
        #expect(after.snippet.after.contains("xxx") && after.snippet.after.hasSuffix("…"))
        // And a long word right before it.
        let before = try #require(try hits("alvo", in: [bot(String(repeating: "y", count: 50) + " alvo fim")]).first)
        #expect(before.snippet.before.contains("yyy") && before.snippet.before.hasPrefix("…"))
    }

    @Test func aShortMessageIsItsOwnSnippetWithoutEllipsis() throws {
        let hit = try #require(try hits("mundo", in: [bot("Olá mundo cruel")]).first)
        #expect(hit.snippet == ConversationSearch.Snippet(before: "Olá ", match: "mundo", after: " cruel"))
        #expect(hit.position > 0.25 && hit.position < 0.35)
        #expect(hit.length == "Olá mundo cruel".utf8.count)
    }

    @Test func aMegabyteMessageStillGivesALightHit() throws {
        let text = String(repeating: "x", count: 1_000_000) + " alvo " + String(repeating: "y", count: 1_000_000)
        let hit = try #require(try hits("alvo", in: [bot(text)]).first)
        #expect(hit.snippet.text.count < 200)
        #expect(hit.position > 0.49 && hit.position < 0.51)
    }

    // MARK: A large conversation

    @Test func aLongConversationGivesAShortListWithoutTouchingTheOutputs() throws {
        var items: [TranscriptItem] = []
        for index in 0..<30_000 {
            switch index % 3 {
            case 0: items.append(user("pergunta número \(index)"))
            case 1: items.append(bot("resposta número \(index) sobre outro assunto"))
            default: items.append(tool("Lendo arquivo \(index)", detail: "src/arquivo\(index).swift", output: String(repeating: "saída ", count: 50)))
            }
        }
        items[12_345] = bot("aqui está a RARIDADE que procuro")
        items[29_998] = user("outra raridade, no fim")
        let results = try ConversationSearch.scan("raridade", in: items)
        #expect(results.hits.map(\.itemIndex) == [12_345, 29_998])
        #expect(results.itemsScanned == 30_000)
        #expect(!results.isTruncated)
        // What comes back is hits and snippets: nothing the size of the conversation.
        #expect(results.hits.allSatisfy { $0.snippet.text.count < 140 })
    }

    @Test func tooManyMatchesAreCutAndSaySo() throws {
        let items = (0..<500).map { _ in bot("a a a a a") }
        let results = try ConversationSearch.scan("a", in: items, maxHits: 100)
        #expect(results.hits.count == 100)
        #expect(results.isTruncated)
        #expect(results.positionLabel(index: 2) == "3 de 100+")
        #expect(results.spokenLabel(index: 2) == "3 de 100+ resultados")
        let exact = try ConversationSearch.scan("a", in: [bot("a a")], maxHits: 2)
        #expect(exact.hits.count == 2 && !exact.isTruncated)
    }

    // MARK: Off the main actor, and cancelled

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private let isSet = DispatchSemaphore(value: 0)
        private var onMain: [Bool] = []
        private var task: Task<ConversationSearch.Results, any Error>?

        func recordThread() { lock.withLock { onMain.append(Thread.isMainThread) } }
        var threads: [Bool] { lock.withLock { onMain } }

        /// Called by the search once it has begun: waits for the test to hand over the task, then cancels it.
        func cancelOnceSet() {
            isSet.wait()
            lock.withLock { task }?.cancel()
        }

        func set(_ task: Task<ConversationSearch.Results, any Error>) {
            lock.withLock { self.task = task }
            isSet.signal()
        }
    }

    @Test @MainActor func theSearchRunsOffTheMainThread() async throws {
        let box = Box()
        let items = [user("um"), bot("dois três")]
        let results = try await ConversationSearch.search("três", in: items, probe: { box.recordThread() })
        #expect(results.hits.count == 1)
        #expect(box.threads == [false], "o corpo da busca rodou na thread principal")
    }

    @Test func aCancelledSearchStopsAndThrows() async throws {
        let items = (0..<50_000).map { _ in bot("texto de preenchimento sem a palavra") }
        let box = Box()
        let task = Task { try await ConversationSearch.search("palavra", in: items, probe: { box.cancelOnceSet() }) }
        box.set(task)
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func scanStopsAtTheCheckpoint() {
        struct Stop: Error {}
        var seen = 0
        #expect(throws: Stop.self) {
            _ = try ConversationSearch.scan("x", in: (0..<100).map { _ in bot("xx") }) {
                seen += 1
                if seen == 10 { throw Stop() }
            }
        }
        #expect(seen == 10)
    }

    // MARK: Moving between hits

    @Test func nextAndPreviousWrapAround() {
        var cursor = FindCursor(count: 3)
        #expect(cursor.index == nil)
        #expect(cursor.next() == 0)
        #expect(cursor.next() == 1)
        #expect(cursor.next() == 2)
        #expect(cursor.next() == 0) // wraps
        #expect(cursor.previous() == 2) // and back
        #expect(cursor.previous() == 1)
        var none = FindCursor(count: 3)
        #expect(none.previous() == 2) // nothing chosen yet: the last
        var empty = FindCursor()
        #expect(empty.next() == nil && empty.previous() == nil)
        var one = FindCursor(count: 1, index: 0)
        #expect(one.next() == 0 && one.previous() == 0)
    }

    @Test func aSearchStartsAtTheNewestHitAndKeepsItsPlaceWhenTheConversationChanges() throws {
        #expect(FindCursor.initialIndex(count: 12) == 11)
        #expect(FindCursor.initialIndex(count: 0) == nil)
        let items = [bot("a"), bot("b"), bot("a a"), bot("c")]
        let before = try hits("a", in: items)
        let chosen = before[2] // the second "a" of the third message
        // A message arrives at the start and one at the end: the same match is still chosen.
        let after = try hits("a", in: [bot("a")] + items + [bot("a")])
        let index = try #require(FindCursor.index(keeping: chosen, in: after))
        #expect(after[index].itemID == chosen.itemID && after[index].occurrence == 1)
        // Its message is gone: the nearest at or after its place.
        let without = try hits("a", in: [items[0], items[1], items[3], bot("a final")])
        #expect(FindCursor.index(keeping: chosen, in: without) == 1)
        #expect(FindCursor.index(keeping: chosen, in: []) == nil)
    }

    @Test func theStatusReadsLikeASentence() throws {
        let results = try ConversationSearch.scan("a", in: (0..<12).map { _ in bot("a") })
        #expect(results.positionLabel(index: 2) == "3 de 12")
        #expect(results.spokenLabel(index: 2) == "3 de 12 resultados")
        let one = try ConversationSearch.scan("a", in: [bot("a")])
        #expect(one.spokenLabel(index: 0) == "1 de 1 resultado")
    }

    @Test func aMatchInALongMessageIsAlignedWhereItIs() {
        #expect(FindScroll.anchorY(position: 0.9, length: 100) == 0.4)
        #expect(FindScroll.anchorY(position: 0, length: 5_000) == 0.15)
        #expect(FindScroll.anchorY(position: 0.5, length: 5_000) == 0.5)
        #expect(FindScroll.anchorY(position: 1, length: 5_000) == 0.85)
    }

    // MARK: Marking the text of a row

    @MainActor @Test func theRowMarksEveryMatchInTheTextItDraws() {
        let text = AttributedString("Uma Ação boa e outra AÇÃO ruim")
        let marked = FindMarking.marked(text, query: "acao")
        let runs = marked.runs.filter { $0.backgroundColor != nil }
        #expect(runs.map { String(marked[$0.range].characters) } == ["Ação", "AÇÃO"])
        #expect(FindMarking.marked(text, query: nil) == text)
        #expect(FindMarking.marked(text, query: "zzz") == text)
        #expect(FindMarking.marked("sem marcas", query: "").runs.allSatisfy { $0.backgroundColor == nil })
    }

    @MainActor @Test func onlyTheChosenRowDiffersFromItsNeighbours() {
        let item = bot("texto")
        let plain = TranscriptRow(item: item, botID: UUID(), orb: OrbConfig())
        var marked = plain
        marked.find = FindFocus(itemID: item.id, query: "texto", isFlashing: true)
        #expect(plain != marked)
        var faded = marked
        faded.find?.isFlashing = false
        #expect(faded != marked) // the wash fades by the row being drawn again
        #expect(plain == TranscriptRow(item: item, botID: plain.botID, orb: plain.orb))
    }

    // MARK: The keys

    @Test func theKeysAreInTheCatalogAndNeverTakenFromTheMenus() {
        let keys = ShortcutCatalog.items.map(\.keys)
        #expect(keys.contains("⌘F") && keys.contains("⌘G") && keys.contains("⇧⌘G"))
        #expect(ShortcutCatalog.keys(for: .findNext) == "⌘G")
        #expect(ShortcutCatalog.keys(for: .findPrevious) == "⇧⌘G")
        #expect(ShortcutCatalog.groups.first { $0.title == "Conversa" }?.items.contains { $0.command == .find } == true)
        #expect(!AppShortcut.all.contains(AppShortcut.find))
        #expect(!AppShortcut.all.contains(AppShortcut.findNext) && !AppShortcut.all.contains(AppShortcut.findPrevious))
    }

    @Test func thePaletteOffersTheSearchWithTheCatalogKey() throws {
        let atlas = BotLook(Bot(id: UUID(), name: "Atlas", role: "", orb: OrbConfig()))
        let entries = PaletteBuilder.entries(orbs: [atlas], current: atlas.id, routines: [], skills: [])
        let entry = try #require(entries.first { $0.id == "find" })
        #expect(entry.action == .findInConversation)
        #expect(entry.shortcut == ShortcutCatalog.keys(for: .find))
        #expect(PaletteSearch.rank(entries, query: "buscar").first?.id == "find")
        #expect(!PaletteBuilder.entries(orbs: [], current: nil, routines: [], skills: []).contains { $0.id == "find" })
    }
}

/// The find bar's controller: it searches after a pause, one query at a time, and tells the chat what to show.
@Suite("Conversation find") @MainActor struct ConversationFindTests {
    private func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func tick() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func make(_ items: [TranscriptItem], typing: Duration = .zero, refresh: Duration = .zero, flash: Duration = .seconds(60),
                      counter: Counter = Counter()) -> ConversationFind {
        let find = ConversationFind(typingDelay: typing, refreshDelay: refresh, flashDuration: flash, probe: { counter.tick() })
        find.source = { items }
        return find
    }

    @Test func typingSearchesAndChoosesTheNewestHit() async {
        let items = [bot("um gato"), bot("nada"), bot("outro gato e mais um gato")]
        let find = make(items)
        var spoken: [String] = []
        find.announce = { spoken.append($0) }
        find.open()
        find.query = "GATO"
        await find.settled()
        #expect(find.results?.hits.count == 3)
        #expect(find.cursor.index == 2)
        #expect(find.statusText == "3 de 3")
        #expect(find.spokenStatus == "3 de 3 resultados")
        #expect(spoken == ["3 de 3 resultados"])
        #expect(find.jump?.itemID == items[2].id)
        #expect(find.focus == FindFocus(itemID: items[2].id, query: "GATO", isFlashing: true))
        #expect(find.pausesFollowing)
    }

    @Test func nextAndPreviousGoAroundAndAskTheChatToScroll() async {
        let items = (0..<4).map { bot("item \($0) alvo") }
        let find = make(items)
        find.open()
        find.query = "alvo"
        await find.settled()
        #expect(find.cursor.index == 3)
        let firstToken = find.jump?.token
        find.next()
        #expect(find.cursor.index == 0 && find.statusText == "1 de 4" && find.jump?.itemID == items[0].id)
        #expect(find.jump?.token != firstToken)
        find.previous()
        #expect(find.cursor.index == 3 && find.jump?.itemID == items[3].id)
        find.previous()
        #expect(find.cursor.index == 2)
        find.choose(1)
        #expect(find.cursor.index == 1 && find.jump?.itemID == items[1].id)
        find.choose(99) // not a result
        #expect(find.cursor.index == 1)
    }

    @Test func aNewerQueryReplacesTheOlderOneAndOnlyOneSearchRuns() async {
        let counter = Counter()
        let find = make([bot("alfa"), bot("zeta")], typing: .milliseconds(200), counter: counter)
        find.open()
        find.query = "z"
        find.query = "ze"
        find.query = "alfa"
        await find.settled()
        #expect(find.results?.query == "alfa")
        #expect(find.results?.hits.count == 1)
        #expect(counter.count == 1, "a busca rodou \(counter.count) vezes")
    }

    @Test func aSearchThatWasCancelledNeverShowsItsResults() async {
        let counter = Counter()
        let find = make([bot("alfa"), bot("zeta")], counter: counter)
        find.open()
        find.query = "zeta" // starts at once (no pause)…
        find.query = "alfa" // …and is replaced before it ran
        await find.settled()
        #expect(find.results?.query == "alfa")
        #expect(find.currentHit?.snippet.match == "alfa")
        #expect(counter.count == 1)
    }

    @Test func clearingTheFieldClearsTheResultsAtOnce() async {
        let find = make([bot("alfa")])
        find.open()
        find.query = "alfa"
        await find.settled()
        #expect(find.results != nil)
        find.query = ""
        #expect(find.results == nil && find.focus == nil && find.jump == nil && !find.pausesFollowing)
        #expect(find.statusText == "")
    }

    @Test func noResultsSaySoAndMarkNothing() async {
        let find = make([bot("alfa")])
        var spoken: [String] = []
        find.announce = { spoken.append($0) }
        find.open()
        find.query = "omega"
        await find.settled()
        #expect(find.statusText == "Sem resultados")
        #expect(find.spokenStatus == "Nenhum resultado")
        #expect(find.focus == nil && find.jump == nil && !find.pausesFollowing)
        #expect(spoken == ["Nenhum resultado"])
        find.next() // nothing to go to
        #expect(find.jump == nil)
    }

    @Test func aSearchThatFindsNothingLetsTheChatFollowAgain() async {
        let find = make([bot("alvo")])
        find.open()
        find.query = "alvo"
        await find.settled()
        #expect(find.pausesFollowing)
        find.query = "alvox"
        await find.settled()
        #expect(find.results?.hits.isEmpty == true && find.focus == nil && !find.pausesFollowing)
    }

    @Test func aQuoteClickedWithTheBarOpenGivesTheMarksBackToTheHitWhenTheWashFades() async {
        let target = bot("alvo")
        let find = make([target], flash: .milliseconds(30))
        find.open()
        find.query = "alvo"
        await find.settled()
        find.reveal(quoteOf: UUID(), words: "outras palavras")
        #expect(find.focus?.query == "outras palavras" && find.focus?.isFlashing == true)
        #expect(await waitUntil("a mancha da citação sumir") { find.focus?.isFlashing == false })
        #expect(find.focus == FindFocus(itemID: target.id, query: "alvo", isFlashing: false))
        #expect(find.pausesFollowing)
    }

    @Test func whenTheConversationChangesTheSelectionStaysWhereItWasAndNothingScrolls() async {
        final class Items { var all: [TranscriptItem] = [] }
        let items = Items()
        items.all = [bot("alvo um"), bot("meio"), bot("alvo dois")]
        let find = ConversationFind(typingDelay: .zero, refreshDelay: .zero, flashDuration: .seconds(60))
        find.source = { items.all }
        find.open()
        find.query = "alvo"
        await find.settled()
        find.previous() // the first one is chosen
        let token = find.jump?.token
        let chosen = find.currentHit?.itemID
        items.all.append(bot("alvo três"))
        items.all.insert(bot("alvo zero"), at: 0)
        find.itemsChanged()
        await find.settled()
        #expect(find.results?.hits.count == 4)
        #expect(find.currentHit?.itemID == chosen)
        #expect(find.jump?.token == token, "a conversa mudou e a lista não deve rolar")
        #expect(find.statusText == "2 de 4")
    }

    @Test func theWashFadesAfterAWhileAndTheMarksStay() async {
        let find = make([bot("alvo")], flash: .milliseconds(30))
        find.open()
        find.query = "alvo"
        await find.settled()
        #expect(find.focus?.isFlashing == true)
        #expect(await waitUntil("a mancha sumir") { find.focus?.isFlashing == false })
        #expect(find.focus?.query == "alvo")
    }

    @Test func closingTheBarForgetsTheResultsAndLetsTheChatFollowAgain() async {
        let find = make([bot("alvo")])
        find.open()
        find.query = "alvo"
        await find.settled()
        #expect(find.pausesFollowing)
        find.close()
        #expect(!find.isOpen && find.results == nil && find.focus == nil && find.jump == nil && !find.pausesFollowing)
        // Reopened, the last query is searched again at once.
        find.open()
        await find.settled()
        #expect(find.query == "alvo" && find.results?.hits.count == 1 && find.focus != nil)
    }

    @Test func sendingAMessageLetsTheChatFollowAgainWithoutClosingTheBar() async {
        let find = make([bot("alvo")])
        find.open()
        find.query = "alvo"
        await find.settled()
        find.resumeFollowing()
        #expect(find.isOpen && !find.pausesFollowing)
        #expect(find.results?.hits.count == 1)
    }

    @Test func aJumpBetweenNeighboursMayGlideAndAFarOneCuts() async {
        let items = (0..<40).map { bot("linha \($0) alvo") }
        let find = make(items)
        find.open()
        find.query = "alvo"
        await find.settled()
        #expect(find.jump?.glides == false, "o primeiro salto não tem de onde deslizar")
        find.previous()
        #expect(find.jump?.glides == true)
        find.choose(0)
        #expect(find.jump?.glides == false)
    }

    @Test func theSearchReadsTheStoredItemsOnceAndNeverTheRows() async {
        var reads = 0
        let items = (0..<500).map { bot("mensagem \($0) com o termo") }
        let find = ConversationFind(typingDelay: .zero, refreshDelay: .zero, flashDuration: .seconds(60))
        find.source = { reads += 1; return items }
        find.open()
        find.query = "termo"
        await find.settled()
        find.next(); find.next(); find.previous()
        #expect(reads == 1, "mover entre resultados não relê a conversa")
        #expect(find.results?.hits.count == 500)
    }
}
