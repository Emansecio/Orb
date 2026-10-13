import Foundation
import Testing
@testable import Orb

/// The time above a new moment of the conversation: which rows get one and what it says.
struct TimeSeparatorsTests {
    private let calendar = Calendar.current

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func theFirstRowANewDayAndAPauseBeginAMoment() {
        let ids = (0..<6).map { _ in UUID() }
        let rows: [(id: UUID, dates: [Date])] = [
            (ids[0], [date(12, 9, 0)]),
            (ids[1], [date(12, 9, 5)]),                   // five minutes later: same moment
            (ids[2], [date(12, 9, 10), date(12, 9, 40)]), // a run of actions that lasted half an hour
            (ids[3], [date(12, 9, 50)]),                  // ten minutes after the run ended: same moment
            (ids[4], [date(12, 10, 10)]),                 // twenty minutes of silence
            (ids[5], [date(13, 0, 2)]),                   // past midnight, however close
        ]
        let breaks = TimeSeparators.breaks(rows, calendar: calendar)
        #expect(Set(breaks.keys) == [ids[0], ids[4], ids[5]])
        #expect(breaks[ids[4]] == date(12, 10, 10))
        #expect(TimeSeparators.breaks([], calendar: calendar).isEmpty)
    }

    @Test func theLabelSaysTheDayAsAPersonWould() {
        let now = date(13, 15) // a Tuesday
        #expect(TimeSeparators.label(date(13, 14, 5), now: now, calendar: calendar) == "Hoje, 14:05")
        #expect(TimeSeparators.label(date(12, 9, 12), now: now, calendar: calendar) == "Ontem, 09:12")
        #expect(TimeSeparators.label(date(8, 10), now: now, calendar: calendar) == "Quinta-feira, 10:00")
        #expect(TimeSeparators.label(date(3, 14, 5), now: now, calendar: calendar) == "3 de outubro, 14:05")
        #expect(TimeSeparators.label(date(3, 14, 5, year: 2025), now: now, calendar: calendar) == "3 de outubro de 2025, 14:05")
    }

    @Test func theLabelReadsOnlyTheDayOfNow() {
        // The separator's timeline gives today's midnight as "now".
        #expect(TimeSeparators.label(date(13, 14, 5), now: date(13, 0), calendar: calendar) == "Hoje, 14:05")
    }

    @MainActor @Test func theTranscriptMarksTheRowsThatBeginAMoment() {
        var first = TranscriptItem(.user(text: "oi", attachments: []))
        first.date = date(12, 9)
        var reply = TranscriptItem(.bot(text: "olá", isStreaming: false))
        reply.date = date(12, 9, 1)
        var later = TranscriptItem(.user(text: "voltei", attachments: []))
        later.date = date(12, 18)
        let transcript = OrbTranscript(items: [first, reply, later])
        #expect(transcript.timeBreaks == [first.id: first.date, later.id: later.date])
    }
}
