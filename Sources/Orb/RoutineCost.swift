import Foundation

/// Whether a routine that runs often is on a model much dearer than one its provider also has: every run pays for the
/// routine's history again, so the model's price is multiplied by the schedule. Only advice: the person decides.
enum RoutineCost {
    /// Runs a day from which the price of the model is worth a look.
    static let frequentRuns = 6.0
    /// How many times cheaper the model offered has to be (input price): one tier down, not a rounding difference.
    static let cheaperBy = 3.0

    struct Advice: Equatable, Sendable {
        var runsPerDay: Int
        /// The routine's model now, and the cheaper one of the same provider ("provider/model" and the name to show).
        var current: String
        var cheaper: String
        var cheaperName: String
        /// How many times less the cheaper one costs per token of input (rounded down).
        var times: Int
    }

    /// How many times `schedule` runs in the 24 hours after `now`. A cron line is walked, up to `limit` runs: the app's
    /// schedules never run more than every 15 minutes (96 a day), and the walk of a day takes about 20 ms.
    static func runsPerDay(_ schedule: Schedule, now: Date = .now, calendar: Calendar = .autoupdatingCurrent, limit: Int = 100) -> Double {
        switch schedule {
        case .daily: return 1
        case .weekly: return 1.0 / 7
        case .everyHours(let hours): return 24 / Double(max(hours, 1))
        case .everyMinutes(let minutes): return 1_440 / Double(max(minutes, 1))
        case .once: return 0
        case .cron:
            let end = now.addingTimeInterval(86_400)
            var date = now, runs = 0
            while runs < limit {
                let next = schedule.next(after: date, calendar: calendar)
                guard next > date, next <= end else { break }
                runs += 1
                date = next
            }
            return Double(runs)
        }
    }

    /// The advice for a routine on `model` ("provider/model"), or nil: it runs seldom, its price is not known, or its
    /// provider has nothing cheap enough. The model offered is the dearest of the cheap enough ones: the next tier down,
    /// not the smallest model there is.
    static func advice(schedule: Schedule, model: String, prices: PriceBook, now: Date = .now,
                       calendar: Calendar = .autoupdatingCurrent) -> Advice? {
        let runs = runsPerDay(schedule, now: now, calendar: calendar)
        guard runs >= frequentRuns, let ref = ModelRef(model), let price = prices.price(for: model)?.price.input, price > 0,
              let account = prices.accounts.first(where: { $0.kind == ref.provider }) else { return nil }
        let cheaper = account.models.compactMap { candidate -> (text: String, name: String, input: Double)? in
            let text = ModelRef(provider: ref.provider, model: candidate.id).text
            guard candidate.id != ref.model, let input = prices.price(for: text)?.price.input, input > 0, input * cheaperBy <= price else { return nil }
            return (text, candidate.name, input)
        }
        // The dearest of them; the name settles a tie, so the advice does not flicker between two models of one price.
        guard let pick = cheaper.max(by: { ($0.input, $1.name) < ($1.input, $0.name) }) else { return nil }
        return Advice(runsPerDay: Int(runs.rounded()), current: model, cheaper: pick.text, cheaperName: pick.name, times: Int(price / pick.input))
    }
}
