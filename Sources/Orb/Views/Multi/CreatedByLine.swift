import SwiftUI

/// "Criado por Atlas" under the Orb's name in its panel, for an Orb another Orb made (docs/MULTI-ORBS.md 4.4). The name is a
/// link to the creator while it exists; deleting the creator leaves the line with the name it had.
struct CreatedByLine: View {
    @Environment(AppModel.self) private var model
    let bot: Bot

    var body: some View {
        if let name = bot.createdByName {
            let creator = bot.createdBy.flatMap { model.bot($0) }
            HStack(spacing: 4) {
                Text("Criado por")
                    .foregroundStyle(Palette.faint)
                if let creator {
                    Button(name) { model.selection = .bot(creator.id) }
                        .buttonStyle(.link)
                        .help("Abrir a conversa com \(creator.name)")
                } else {
                    Text(name).foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Criado por \(name)")
            .accessibilityIdentifier("orb-created-by")
        }
    }
}
