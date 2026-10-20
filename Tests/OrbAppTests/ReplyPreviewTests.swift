import Foundation
import Testing
@testable import Orb

/// The second line and the time of an Orb's row in the sidebar: the shortened reply, how the time is written, and that
/// the preview is saved with the state without breaking older files.
@Suite struct ReplyPreviewTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-10-20 (a Tuesday) at the given time, in the fixed zone.
    private func date(_ day: Int, month: Int = 10, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: A conversation saved before the previews

    @Test func theLastFinishedReplyOfASavedConversationIsTheOne() {
        var older = TranscriptItem(.bot(text: "**Feito.** Duas vendas hoje.", isStreaming: false))
        older.date = date(19, 9, 0)
        var newer = TranscriptItem(.bot(text: "Tudo certo por aqui.", isStreaming: false))
        newer.date = date(20, 16, 23)
        let items = [TranscriptItem(.user(text: "oi", attachments: [])), older,
                     TranscriptItem(.user(text: "e agora?", attachments: [])), newer,
                     TranscriptItem(.notice("Compactei a conversa")),
                     TranscriptItem(.bot(text: "pela met", isStreaming: true)),
                     TranscriptItem(.bot(text: "```\n```", isStreaming: false))]
        #expect(ReplyPreview.last(in: items) == ReplyPreview(text: "Tudo certo por aqui.", date: date(20, 16, 23)))
        #expect(ReplyPreview.last(in: [TranscriptItem(.user(text: "oi", attachments: []))]) == nil)
    }

    // MARK: The time

    @Test func todayShowsTheHour() {
        let now = date(20, 18, 5)
        #expect(ReplyTime.label(date(20, 17, 28), now: now, calendar: calendar) == "17:28")
        #expect(ReplyTime.label(date(20, 0, 3), now: now, calendar: calendar) == "00:03")
    }

    @Test func yesterdayIsNamedEvenJustAfterMidnight() {
        #expect(ReplyTime.label(date(19, 23, 59), now: date(20, 0, 1), calendar: calendar) == "Ontem")
        #expect(ReplyTime.label(date(19, 8, 0), now: date(20, 18, 0), calendar: calendar) == "Ontem")
    }

    @Test func untilSixDaysAgoItIsTheWeekday() {
        let now = date(20)
        #expect(ReplyTime.label(date(18), now: now, calendar: calendar) == "dom.")
        #expect(ReplyTime.label(date(14), now: now, calendar: calendar) == "qua.")
        #expect(ReplyTime.label(date(17), now: now, calendar: calendar) == "sáb.")
        #expect(ReplyTime.label(date(15), now: now, calendar: calendar) == "qui.")
    }

    @Test func aWeekAgoOrMoreIsTheDate() {
        let now = date(20)
        #expect(ReplyTime.label(date(13), now: now, calendar: calendar) == "13/10")
        #expect(ReplyTime.label(date(5, month: 3), now: now, calendar: calendar) == "05/03")
    }

    // MARK: The preview

    @Test func aMarkdownReplyBecomesOneLine() throws {
        let reply = "## Resumo\n\nCaixa de entrada **zerada**, 5 rascunhos guardados.\n\n- um\n- dois"
        let preview = try #require(ReplyPreview.make(from: reply, at: date(20)))
        #expect(!preview.text.contains("\n") && !preview.text.contains("**") && !preview.text.contains("##"))
        #expect(preview.text.contains("Caixa de entrada zerada, 5 rascunhos guardados."))
        #expect(preview.date == date(20))
    }

    @Test func aLongReplyIsShortenedAndABlankOneMakesNoPreview() throws {
        let long = try #require(ReplyPreview.make(from: String(repeating: "palavra ", count: 100)))
        #expect(long.text.count <= 141)
        #expect(ReplyPreview.make(from: "  \n \n") == nil)
    }

    // MARK: Saved with the state

    @Test func anOldStateWithoutPreviewsStillLoads() throws {
        let id = UUID()
        let json = #"{"bots":[{"id":"\#(id.uuidString)","name":"A"}],"unread":{"\#(id.uuidString)":2}}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.bots.count == 1 && state.unread.count == 1)
        #expect(state.replies.isEmpty)
    }

    @Test func aDamagedPreviewNeverLosesTheFile() throws {
        let json = #"{"bots":[],"replies":"nada"}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.replies.isEmpty)
    }

    @Test func thePreviewRoundTrips() throws {
        var state = AppState(bots: [Bot(name: "A", role: "x", orb: OrbConfig())])
        let preview = ReplyPreview(text: "Pronto.", date: Date(timeIntervalSince1970: 1_700_000_000))
        state.replies = [state.bots[0].id.uuidString: preview]
        let again = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(again.replies == state.replies)
    }

    @Test @MainActor func theRowOfAnOrbPublishesItsOwnPreview() {
        let live = BotLive(Bot(name: "A", role: "x", orb: OrbConfig()))
        #expect(live.lastReply == nil)
        let preview = ReplyPreview(text: "Feito.", date: .now)
        live.setLastReply(preview)
        #expect(live.lastReply == preview)
    }
}
