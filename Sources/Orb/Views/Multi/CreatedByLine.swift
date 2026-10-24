import SwiftUI

/// "Criado por Atlas" under the Orb's name in its panel, for an Orb another Orb made (docs/historico/MULTI-ORBS.md 4.4). The name is a
/// link to the creator while it exists; deleting the creator leaves the line with the name it had.
struct CreatedByLine: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    /// The creator's name as it is now while it exists (it may have been renamed); the name the Orb kept once it is gone.
    static func displayName(bot: Bot, creator: Bot?) -> String? {
        bot.createdByName.map { creator?.name ?? $0 }
    }

    var body: some View {
        let creator = bot.createdBy.flatMap { model.bot($0) }
        if let name = Self.displayName(bot: bot, creator: creator) {
            HStack(spacing: 4) {
                Text("Criado por")
                    .foregroundStyle(Palette.faint)
                if let creator {
                    Button(name) { model.selection = .bot(creator.id) }
                        .buttonStyle(.link)
                        .help("Abrir a conversa com \(name)")
                } else {
                    Text(name).foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .font(Typography.small)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Criado por \(name)")
            .accessibilityIdentifier("orb-created-by")
        }
    }
}
