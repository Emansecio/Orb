import Foundation
import Observation
import Testing
@testable import Orb

/// Set from an observation callback (which is `@Sendable`).
private final class Flag: @unchecked Sendable {
    var isSet = false
}

/// A reply that streams costs the same whatever its length: it is split into paragraphs as it arrives, its text is
/// kept apart from the conversation, and the chat view of an Orb is redrawn only by that Orb's own changes.
@Suite("Transcript streaming") struct TranscriptStreamingTests {
    // MARK: Paragraphs

    private func chunks(of text: String, sizes: [Int]) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        var turn = 0
        while !rest.isEmpty {
            let size = max(1, sizes[turn % sizes.count])
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
            turn += 1
        }
        return result
    }

    private let sample = """
        Primeiro parágrafo com **negrito** e `código`.

        Segundo:
        - item um
        - item dois


        Depois de três quebras.

        ```swift
        func a() {

            print("linha em branco acima")
        }
        ```

        Texto com acentuação, emoji 🙂 e fim.
        """

    @Test func splitsAtBlankLinesAndGivesBackTheText() {
        let paragraphs = ReplyParagraphs("um\n\ndois\n\ntrês")
        #expect(paragraphs.closed == ["um", "dois"])
        #expect(paragraphs.tail == "três")
        #expect(paragraphs.text == "um\n\ndois\n\ntrês")
    }

    @Test func aTextWithoutABlankLineIsOneParagraph() {
        let paragraphs = ReplyParagraphs("linha\noutra linha\n")
        #expect(paragraphs.closed.isEmpty)
        #expect(paragraphs.tail == "linha\noutra linha\n")
    }

    @Test func arrivingInAnyChunkingGivesTheSameParagraphsAsAllAtOnce() {
        let whole = ReplyParagraphs(sample)
        for sizes in [[1], [2], [3, 1], [5, 2, 7], [13], [64], [1, 1, 40]] {
            var incremental = ReplyParagraphs()
            for chunk in chunks(of: sample, sizes: sizes) { incremental.append(chunk) }
            #expect(incremental.closed == whole.closed, "chunks \(sizes)")
            #expect(incremental.tail == whole.tail, "chunks \(sizes)")
            #expect(incremental.text == sample)
        }
    }

    @Test func aBlankLineSplitAcrossTwoChunksStillEndsTheParagraph() {
        var paragraphs = ReplyParagraphs("fim do primeiro\n")
        #expect(paragraphs.closed.isEmpty)
        paragraphs.append("\nsegundo")
        #expect(paragraphs.closed == ["fim do primeiro"])
        #expect(paragraphs.tail == "segundo")
    }

    @Test func extraBlankLinesStartTheNextParagraphWithTheirNewlines() {
        // The same pieces as splitting the text at "\n\n": nothing is lost or invented.
        let paragraphs = ReplyParagraphs("a\n\n\nb\n\n\n\nc")
        #expect(paragraphs.closed == ["a", "\nb", ""])
        #expect(paragraphs.tail == "c")
        #expect(paragraphs.text == "a\n\n\nb\n\n\n\nc")
    }

    @Test func aFinishedParagraphNeverChangesWhenMoreTextArrives() {
        var paragraphs = ReplyParagraphs()
        var seen: [String] = []
        for chunk in chunks(of: sample, sizes: [4]) {
            paragraphs.append(chunk)
            #expect(Array(paragraphs.closed.prefix(seen.count)) == seen)
            seen = paragraphs.closed
        }
        #expect(seen.count == ReplyParagraphs(sample).closed.count)
    }

    @Test func aBlankLineInsideACodeBlockIsNotAParagraphBreak() {
        let code = "```swift\nlet a = 1\n\nlet b = 2\n```"
        let paragraphs = ReplyParagraphs("antes\n\n" + code + "\n\ndepois")
        #expect(paragraphs.closed == ["antes", code])
        #expect(paragraphs.tail == "depois")
    }

    @Test func aCodeBlockThatIsNeverClosedStaysInOneParagraph() {
        let paragraphs = ReplyParagraphs("antes\n\n```\numa\n\nduas\n\ntrês")
        #expect(paragraphs.closed == ["antes"])
        #expect(paragraphs.tail == "```\numa\n\nduas\n\ntrês")
    }

    @Test func aFenceIsClosedOnlyByAtLeastAsManyBackticksAndNothingElse() {
        // Four backticks open it, so three do not close it; a closing fence carries no text.
        let text = "````\na\n\n```\nb\n\n```x\n\n````\n\nfora"
        let paragraphs = ReplyParagraphs(text)
        #expect(paragraphs.closed == ["````\na\n\n```\nb\n\n```x\n\n````"])
        #expect(paragraphs.tail == "fora")
    }

    @Test func backticksInsideALineAreCodeSpansNotFences() {
        let paragraphs = ReplyParagraphs("use ```assim``` no meio\n\nOutro\n\nFim")
        #expect(paragraphs.closed == ["use ```assim``` no meio", "Outro"])
    }

    @Test func aFenceLineWithBackticksInItsInfoIsNotAFence() {
        let paragraphs = ReplyParagraphs("``` a`b\n\nsegundo")
        #expect(paragraphs.closed == ["``` a`b"])
        #expect(paragraphs.tail == "segundo")
    }

    // MARK: Live text and what views observe of it

    @MainActor @Test func aFlushWithoutAParagraphBreakChangesOnlyTheLastParagraph() {
        let live = LiveText(itemID: UUID(), text: "primeiro\n\nsegundo")
        let closedChanged = Flag(), tailChanged = Flag()
        withObservationTracking { _ = live.closed } onChange: { closedChanged.isSet = true }
        withObservationTracking { _ = live.tail } onChange: { tailChanged.isSet = true }

        live.append(" e continua")
        #expect(tailChanged.isSet)
        #expect(!closedChanged.isSet)
        #expect(live.text == "primeiro\n\nsegundo e continua")

        live.append("\n\nterceiro")
        #expect(closedChanged.isSet)
        #expect(live.closed == ["primeiro", "segundo e continua"])
        #expect(live.tail == "terceiro")
    }

    @MainActor @Test func showingTheSameItemsAgainChangesNothing() {
        let items = [TranscriptItem(.notice("um")), TranscriptItem(.notice("dois"))]
        let transcript = OrbTranscript(items: items)
        let copy = items // the same storage, as a conversation that was only read
        transcript.show(copy)
        #expect(transcript.revision == 0)

        var changed = items
        changed.append(TranscriptItem(.notice("três")))
        transcript.show(changed)
        #expect(transcript.revision == 1)
        #expect(transcript.items.count == 3)

        let observed = Flag()
        withObservationTracking { _ = transcript.items } onChange: { observed.isSet = true }
        transcript.show(changed)
        #expect(!observed.isSet)
    }

    @Test func arraysShareStorageOnlyWhenTheyAreTheSameBuffer() {
        let a = [1, 2, 3]
        var b = a
        #expect(a.isSameStorage(as: b))
        b[0] = 9
        #expect(!a.isSameStorage(as: b))
        #expect([Int]().isSameStorage(as: []))
    }

    // MARK: The model

    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbStreaming-\(UUID().uuidString)")

    @MainActor private func twoOrbs() -> (AppModel, UUID, UUID) {
        var state = AppState.initial
        state.bots.append(Bot(name: "Luna", role: "", orb: OrbConfig()))
        let store = Store(directory: root)
        store.save(state)
        for bot in state.bots {
            store.save(Conversation(items: [TranscriptItem(.user(text: "oi", attachments: []))], messages: [.user("oi")]), for: bot.id)
        }
        store.flush()
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        return (model, state.bots[0].id, state.bots[1].id)
    }

    private func botText(_ item: TranscriptItem?) -> String? {
        if case .bot(let text, _)? = item?.kind { text } else { nil }
    }

    @MainActor @Test func theTextOfAStreamingReplyIsKeptApartFromTheItems() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, _) = twoOrbs()
        model.apply(.text("Olá"), to: first)
        model.flushText(first)

        let item = try #require(model.transcript(first).last)
        let live = try #require(model.liveText(for: item.id, of: first))
        let revision = model.orbTranscript(first).revision

        for word in [", tudo", " bem?\n\n", "Segundo parágrafo", " continua"] {
            model.apply(.text(word), to: first)
            model.flushText(first)
        }
        #expect(live.text == "Olá, tudo bem?\n\nSegundo parágrafo continua")
        #expect(live.closed == ["Olá, tudo bem?"])
        // The list never saw it: the items are the ones from the first flush.
        #expect(model.orbTranscript(first).revision == revision)
        #expect(botText(model.transcript(first).last) == "Olá")
        #expect(model.liveText(for: UUID(), of: first) == nil)
    }

    @MainActor @Test func closingAReplyPutsTheWholeTextInTheItem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, _) = twoOrbs()
        model.apply(.text("\n\n  Olá"), to: first) // newlines before the first word are dropped
        model.flushText(first)
        let id = try #require(model.transcript(first).last?.id)
        model.apply(.text(" de novo.\n\n"), to: first)
        model.apply(.text("Fim.\n\n"), to: first)

        model.apply(.notice("terminou"), to: first) // anything that adds to the transcript closes the reply first
        let items = model.transcript(first)
        guard case .bot(let text, let isStreaming) = items[items.count - 2].kind else { Issue.record("no reply"); return }
        #expect(text == "Olá de novo.\n\nFim.")
        #expect(!isStreaming)
        #expect(items[items.count - 2].id == id)
        #expect(model.liveText(for: id, of: first) == nil)
        #expect(items.last.map { if case .notice("terminou") = $0.kind { true } else { false } } == true)
    }

    @MainActor @Test func theReplyIsWrittenToDiskWhileItStreams() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, _) = twoOrbs()
        model.apply(.text("Começo"), to: first)
        model.flushText(first)
        model.apply(.text(" e meio\n\ne mais um pouco"), to: first)
        model.flushText(first)

        model.saveNow() // quitting in the middle of a reply
        let saved = try #require(Store(directory: root).loadConversation(first))
        #expect(botText(saved.items.last) == "Começo e meio\n\ne mais um pouco")
        // The model's own items were not rewritten for it.
        #expect(botText(model.transcript(first).last) == "Começo")
    }

    @MainActor @Test func aReplyStreamingInAnotherOrbDoesNotTouchTheChatOfThisOne() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, second) = twoOrbs()
        let visible = model.orbTranscript(first)
        let revision = visible.revision
        let redrawn = Flag()
        withObservationTracking { _ = visible.items; _ = visible.revision } onChange: { redrawn.isSet = true }

        for word in ["a", "b", "c", "d"] {
            model.apply(.text(word + "\n\n"), to: second)
            model.flushText(second)
        }
        model.apply(.notice("fim"), to: second)
        model.apply(.text("outra resposta"), to: second)
        model.flushText(second)

        #expect(!redrawn.isSet)
        #expect(visible.revision == revision)
        #expect(model.transcript(second).count == 4)
    }

    @MainActor @Test func theChatViewStaysInStepWithTheConversation() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, second) = twoOrbs()
        model.selection = .bot(second) // starts reading its conversation, off the main thread
        await model.loadedConversation(second)
        let shown = model.orbTranscript(second)
        #expect(shown.items.count == 1)

        model.apply(.notice("um aviso"), to: second)
        #expect(shown.items.count == 2)
        #expect(model.transcript(first).count == 1)

        model.newConversation(second)
        #expect(shown.items.isEmpty)
        model.deleteBot(second)
        #expect(model.transcript(second).isEmpty)
    }

    // MARK: Parsed Markdown

    @MainActor @Test func parsedMarkdownIsKeptForFinishedTextAndBounded() {
        MarkdownCache.removeAll()
        let first = MarkdownCache.attributed("**olá** mundo")
        #expect(String(first.characters) == "olá mundo")
        #expect(MarkdownCache.count == 1)
        _ = MarkdownCache.attributed("**olá** mundo")
        #expect(MarkdownCache.count == 1)

        // A paragraph followed by another carries the blank line between them; text still being written is not kept.
        #expect(String(MarkdownCache.attributed("p", endsParagraph: true).characters) == "p\n")
        _ = MarkdownCache.attributed("ainda chegando", cached: false)
        #expect(MarkdownCache.count == 2)

        // Far more text than a generation holds: the cache does not grow without bound.
        let block = String(repeating: "x", count: 40_000)
        for index in 0..<40 { _ = MarkdownCache.attributed("\(index)" + block) }
        #expect(MarkdownCache.count <= 28)
        MarkdownCache.removeAll()
    }

    // MARK: Following the bottom

    @Test func aScrollRunsAtOnceThenAtMostOncePerInterval() {
        let start = ContinuousClock.now
        var throttle = ScrollThrottle(interval: .milliseconds(200))
        #expect(throttle.request(at: start) == .now)
        #expect(throttle.request(at: start + .milliseconds(50)) == .after(.milliseconds(150)))
        #expect(throttle.request(at: start + .milliseconds(80)) == .wait) // that run will do for both
        throttle.ranScheduled(at: start + .milliseconds(200))
        #expect(throttle.request(at: start + .milliseconds(250)) == .after(.milliseconds(150)))
        throttle.ranScheduled(at: start + .milliseconds(400))
        #expect(throttle.request(at: start + .milliseconds(900)) == .now) // quiet for longer than the interval
    }
}
