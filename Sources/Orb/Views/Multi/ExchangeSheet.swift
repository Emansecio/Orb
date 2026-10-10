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
    @State private var showsWork = false

    /// The side conversation of the Orb that answered (`pedido-<id>.json`): the request addressed to it, when the Orb still exists.
    private var work: (botID: UUID, requestID: UUID)? {
        guard let answered = parties.last, model.bot(answered.id) != nil,
              let request = messages.last(where: { $0.to?.id == answered.id })?.requestID else { return nil }
        return (answered.id, request)
    }

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
                            // The role is said once per Orb, at its first message; later headers show the name only.
                            let isFirst = messages.firstIndex(where: { $0.from.id == message.from.id }) == index
                            VStack(alignment: .leading, spacing: 4) {
                                OrbSpeechBubble(orb: model.live(message.from.id).look.orb, name: message.from.name,
                                                role: isFirst ? model.bot(message.from.id)?.role : nil,
                                                text: message.text.isEmpty ? "(sem texto)" : message.text,
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
        .sheet(isPresented: $showsWork) {
            if let work { SideWorkSheet(botID: work.botID, requestID: work.requestID) }
        }
    }

    /// The two Orbs as a centred pair: 48 pt avatars 24 pt apart, joined by a 1 pt connector across that gap at their middle, and
    /// a name under each. The exchange is over or waiting, so nothing moves here.
    private var header: some View {
        let pair = Array(parties.prefix(2))
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(pair.enumerated()), id: \.offset) { index, party in
                if index == 1 {
                    Rectangle()
                        .fill(Palette.hint)
                        .frame(width: 24, height: 1)
                        .padding(.top, 24)
                }
                partyView(party)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Troca entre \(parties.map(\.name).joined(separator: " e "))")
    }

    private func partyView(_ party: OrbRef) -> some View {
        VStack(spacing: 6) {
            BotAvatar(orb: model.live(party.id).look.orb, size: 48, animated: false)
            Text(party.name)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize()
        }
        .frame(width: 48)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let answered = parties.last, onOpenWork != nil || work != nil {
                Button("Ver o trabalho \(Self.ofThe(answered.name))") { if let onOpenWork { onOpenWork() } else { showsWork = true } }
                    .buttonStyle(SecondaryPillStyle())
            }
            Button("Voltar \(Self.toThe(parties.first?.name ?? ""))") { dismiss() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// "do Pesquisador", "da Lia": the name with its article after "de".
    static func ofThe(_ name: String) -> String {
        "\(PortugueseArticle.article(for: name) == "a" ? "da" : "do") \(name)"
    }

    /// "ao Atlas", "à Lia": the name with its article after "a".
    static func toThe(_ name: String) -> String {
        "\(PortugueseArticle.contraction(for: name)) \(name)"
    }

    /// What a message's state says under its bubble; nil for a reply that came.
    static func caption(for state: OrbMessageItem.State) -> (text: String, tint: Color)? {
        switch state {
        case .open: ("Aguardando resposta", Palette.faint)
        case .replied: nil
        case .failed: ("Não deu certo", Palette.warn)
        case .refused: ("Recusado", Palette.warn)
        case .cancelled: ("Cancelado", Palette.faint)
        case .lost: ("Sem resposta", Palette.faint)
        }
    }
}

/// The work an Orb did for a request from another Orb (`pedido-<id>.json`), read-only; live while the Orb is still on it.
struct SideWorkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    let requestID: UUID
    @State private var saved: [TranscriptItem] = []
    @State private var isLoading = true

    private var isLive: Bool { model.sessions[botID]?.servingRequest == requestID }

    var body: some View {
        let live = isLive ? model.sessions[botID]?.conversation?.items : nil
        let items = live ?? saved
        let bot = model.bot(botID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let bot {
                    ForEach(items) { item in
                        TranscriptRow(item: item, botID: botID, orb: bot.orb).equatable()
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            if items.isEmpty {
                if isLoading { DelayedSpinner() } else { ContentUnavailableView("Sem registro do trabalho", systemImage: "text.bubble") }
            }
        }
        .frame(height: 400)
        .background(Palette.canvas)
        .orbSheet(bot?.name ?? "Orb", subtitle: live == nil ? "Trabalho do pedido, só para ler" : "Trabalhando agora", size: .large) {
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
        .task(id: isLive) {
            saved = await model.store.readSideConversationAsync(prefix: Store.pedidoPrefix, id: requestID, for: botID).value?.items ?? []
            isLoading = false
        }
    }
}

/// A request's side conversation to open (see `AppModel.sideWorkToShow`).
struct SideWorkTarget: Identifiable, Equatable {
    let botID: UUID
    let requestID: UUID
    var id: UUID { requestID }
}
