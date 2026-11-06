import Foundation
import Testing
@testable import Orb

/// The pure parts of the sidebar footer, Início's day groups and the menu bar panel's approvals.
@Suite struct NavigationLogicTests {
    @Test func profileNameShortensToFirstNameAndLastInitial() {
        #expect(ProfileNameText.short("Thiago Emanuel Velozo") == "Thiago V.")
        #expect(ProfileNameText.short("Ana Lima") == "Ana L.")
        #expect(ProfileNameText.short("Thiago") == "Thiago")
        #expect(ProfileNameText.short("  maria   souza ") == "maria S.")
        #expect(ProfileNameText.short("") == "")
    }

    @Test func inicioNewsGroupByDayInTheOrderTheyAppear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15))!
        func news(daysAgo: Int, hour: Int = 10) -> InicioNews {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            let id = UUID()
            return InicioNews(entry: InicioEntry(id: id, sequence: 0, date: date,
                                                 origin: .chat(bot: UUID(), chat: UUID(), item: id), outcome: .completed, summary: ""))
        }
        let list = [news(daysAgo: 0, hour: 14), news(daysAgo: 0, hour: 9), news(daysAgo: 1), news(daysAgo: 3), news(daysAgo: 6), news(daysAgo: 7), news(daysAgo: 20)]
        let groups = InicioDays.group(list, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Hoje", "Ontem", "Esta semana", "Mais antigas"])
        #expect(groups.map(\.items.count) == [2, 1, 2, 2])
        #expect(groups[0].items.map(\.id) == [list[0].id, list[1].id]) // keeps the newest-first order inside a group
        #expect(InicioDays.group([], now: now, calendar: calendar).isEmpty)
        // Midnight is the boundary: 23:59 yesterday is "Ontem" even one minute before now crosses it.
        let lateNow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 0, minute: 1))!
        let lastNight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23, minute: 59))!
        #expect(InicioDays.title(of: lastNight, now: lateNow, calendar: calendar) == "Ontem")
    }

    @Test func inicioMoreLinkCountsWhatIsHidden() {
        #expect(InicioDays.moreLabel(hidden: 1) == "Ver mais 1 item")
        #expect(InicioDays.moreLabel(hidden: 9) == "Ver mais 9 itens")
    }

    @Test func quickAskGroupsApprovalsByOrbKeepingFirstAppearance() {
        let atlas = Bot(name: "Atlas", role: "", orb: OrbConfig()), luna = Bot(name: "Luna", role: "", orb: OrbConfig())
        func pending(_ bot: Bot) -> PendingApproval {
            PendingApproval(bot: bot, request: ApprovalRequest(toolName: "run_command", title: "x", command: "ls", reason: ""))
        }
        let a1 = pending(atlas), l1 = pending(luna), a2 = pending(atlas)
        let groups = QuickAskApprovalGroups.byOrb([a1, l1, a2])
        #expect(groups.map { $0.map(\.bot.name) } == [["Atlas", "Atlas"], ["Luna"]])
        #expect(groups[0].map(\.id) == [a1.id, a2.id])
        #expect(QuickAskApprovalGroups.byOrb([]).isEmpty)
    }
}
