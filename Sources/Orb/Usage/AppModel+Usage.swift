import Foundation

// The app's side of the usage history: the one place every use of a model is recorded from, and the prices the user corrected.

extension AppModel {
    /// Records a use of `model` ("provider/model") by the Orb `botID`. The single point: a turn's events come here
    /// (`BotSession.recordUsage`), and so does any call the app makes outside a turn (`recordAuxiliaryUsage`).
    /// Nothing is kept while the app is being reset.
    func recordUsage(_ totals: UsageTotals, botID: UUID, model: String, source: UsageSource) {
        guard !isResetting, let name = bot(botID)?.name else { return }
        usageLog.record(totals, orb: botID, name: name, model: model, source: source)
        // What a group's turn costs goes to the request's count (what the provider charges in full or writes to its cache).
        if source == .group { groupHub.noteTokens(totals.budgetTokens, botID: botID) }
    }

    /// For a call the app makes for itself whose reply is a single `TokenUsage` (the note on a stretch the next fold will
    /// take). The skill review, which runs the engine in the background, reports each call through `recordUsage` with the
    /// same `auxiliary` source.
    func recordAuxiliaryUsage(_ usage: TokenUsage, botID: UUID, model: String) {
        recordUsage(UsageTotals(usage), botID: botID, model: model, source: .auxiliary)
    }

    /// The prices the Uso page works with: the corrections, and the providers' lists.
    var priceBook: PriceBook { PriceBook(corrections: priceCorrections, accounts: providers) }

    /// Corrects the price of "provider/model" (nil: back to the table's or the provider's own).
    func correctPrice(of model: String, to price: ModelPrice?) {
        if let price {
            guard price.isValid else { return }
            priceCorrections[model] = price
        } else {
            priceCorrections[model] = nil
        }
    }
}
