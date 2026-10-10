import SwiftUI

/// The read-only view of one exchange between Orbs: the two Orbs at the top, linked by a still dotted line, and every
/// message of the exchange as the Orb's bubble on the left (the same as a group's, docs/MULTI-ORBS.md 8.3 and 8.10). Nothing
/// here answers or changes anything; "Ver o trabalho" of the one who answered is offered only when `onOpenWork` is given.
struct ExchangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messages: [OrbMessageItem]
    /// The Orbs of the exchange (two, the asker and the one asked), in the order they first speak.
    let parties: [OrbRef]
    /// Opens the work of the Orb that answered (its side conversation), when the app can show it.
    var onOpenWork: (() -> Void)?

    var body: some View {
        let title = parties.map(\.name).joined(separator: " e ")
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if messages.isEmpty {
                    Text("Nada foi trocado ainda.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    // Messages of one Orb in a row share its avatar and header (as an Orb's replies do in the chat).
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            let continues = index > 0 && messages[index - 1].from.id == message.from.id
                            VStack(alignment: .leading, spacing: 4) {
                                OrbSpeechBubble(orb: model.live(message.from.id).look.orb, name: message.from.name,
                                                role: model.bot(message.from.id)?.role, text: message.text.isEmpty ? "(sem texto)" : message.text,
                                                continues: continues)
                                if let caption = Self.caption(for: message.state) {
                                    Text(caption.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(caption.tint)
                                        .padding(.leading, 40)
                                }
                            }
                            // A new speaker starts a group 8 pt further down (6 pt of the stack plus 8).
                            .padding(.top, continues ? 0 : 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .orbSheet(title, subtitle: "Somente leitura", size: .medium) {
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Array(parties.prefix(2).enumerated()), id: \.offset) { index, party in
                if index > 0 {
                    // A still dotted line between the two Orbs: the exchange is over or waiting, nothing moves here.
                    HStack(spacing: 3) {
                        ForEach(0..<16, id: \.self) { _ in
                            Circle().fill(Palette.hint).frame(width: 2, height: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 22)
                }
                VStack(spacing: 6) {
                    BotAvatar(orb: model.live(party.id).look.orb, size: 40, animated: false)
                    Text(party.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                .frame(width: 96)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Troca entre \(parties.map(\.name).joined(separator: " e "))")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let onOpenWork, let answered = parties.last {
                Button("Ver o trabalho de \(answered.name)") { onOpenWork() }
                    .buttonStyle(SecondaryPillStyle())
            }
            Button("Voltar a \(parties.first?.name ?? "")") { dismiss() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// What a message's state says under its bubble; nil for a reply that came.
    static func caption(for state: OrbMessageItem.State) -> (text: String, tint: Color)? {
        switch state {
        case .open: ("Sem resposta ainda", Palette.faint)
        case .replied: nil
        case .failed: ("Não deu certo", Palette.warn)
        case .refused: ("Recusado", Palette.warn)
        case .cancelled: ("Cancelado", Palette.faint)
        case .lost: ("Perdido: o app fechou antes da resposta", Palette.faint)
        }
    }
}
