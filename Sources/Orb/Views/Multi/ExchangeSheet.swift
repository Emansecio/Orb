import SwiftUI

/// The read-only view of one exchange between Orbs: the two Orbs at the top, linked by a still dotted line, and every
/// message of the exchange as the Orb's bubble on the left (`GroupMessageBubble`, the same as a group's, docs/historico/MULTI-ORBS.md
/// 8.3 and 8.10). Nothing
/// here answers or changes anything; "Ver o trabalho" of the one who answered is offered when the request still
/// has a side conversation to show (`work`) or when `onOpenWork` is given (the snapshots).
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
    /// A notice (`tell`) runs nothing, so it has none; a request to a group is worked in the group (`group`).
    private var work: (botID: UUID, requestID: UUID)? {
        guard group == nil, let answered = parties.last, model.bot(answered.id) != nil,
              let request = messages.last(where: { $0.to?.id == answered.id && $0.kind != .tell })?.requestID else { return nil }
        return (answered.id, request)
    }

    /// The group a request of this exchange went to from the chat (its work is in the group's thread).
    private var group: UUID? {
        messages.lazy.compactMap(\.groupID).first { id in model.group(id) != nil }
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
                            VStack(alignment: .leading, spacing: 4) {
                                GroupMessageBubble(message: Self.shown(message), look: model.liveBot(message.from.id)?.look,
                                                   isOrchestrator: false, showsHeader: !continues)
                                if let caption = Self.caption(for: message.state) {
                                    Text(caption.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(caption.tint)
                                        .padding(.leading, 44) // under the bubble, which `GroupMessageBubble` sets 44 pt from the edge
                                }
                            }
                            // A new speaker starts a group 8 pt further down (6 pt of the stack plus 8).
                            .padding(.top, continues ? 0 : 8)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.sheetEdge)
            .padding(.vertical, Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Opens at the latest message, as a chat does (a long exchange used to open at its first).
        .modifier(KeepsBottom(follows: true))
        .orbSheet(title, subtitle: "Somente leitura", size: .medium, onClose: { dismiss() }) {
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
        SheetFooterBar {
            Spacer(minLength: 0)
            if let group {
                Button("Ver no grupo") {
                    dismiss()
                    model.selection = .group(group)
                }
                .buttonStyle(SecondaryPillStyle())
            } else if let answered = parties.last, onOpenWork != nil || work != nil {
                Button("Ver o trabalho \(Self.ofThe(answered.name))") { if let onOpenWork { onOpenWork() } else { showsWork = true } }
                    .buttonStyle(SecondaryPillStyle())
            }
            Button(Self.backLabel(parties, viewing: viewing)) { dismiss() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The Orb whose chat is open behind the sheet (the exchange shows in both Orbs' chats).
    private var viewing: UUID? {
        if case .bot(let id) = model.selection { id } else { nil }
    }

    /// "Voltar ao Atlas": back to the one whose chat is open (`viewing`), else the one who asked; plain "Voltar" with
    /// no party to name.
    static func backLabel(_ parties: [OrbRef], viewing: UUID? = nil) -> String {
        let back = parties.first { $0.id == viewing } ?? parties.first
        return back.map { "Voltar \(toThe($0.name))" } ?? "Voltar"
    }

    /// "do Pesquisador", "da Lia": the name with its article after "de".
    static func ofThe(_ name: String) -> String {
        "\(PortugueseArticle.article(for: name) == "a" ? "da" : "do") \(name)"
    }

    /// "ao Atlas", "à Lia": the name with its article after "a".
    static func toThe(_ name: String) -> String {
        "\(PortugueseArticle.contraction(for: name)) \(name)"
    }

    /// The message with a placeholder for an empty text, so its bubble is not a blank one.
    static func shown(_ message: OrbMessageItem) -> OrbMessageItem {
        var shown = message
        if shown.text.isEmpty { shown.text = "(sem texto)" }
        return shown
    }

    /// What a message's state says under its bubble; nil for a reply that came.
    static func caption(for state: OrbMessageItem.State) -> (text: String, tint: Color)? {
        switch state {
        case .open: ("Aguardando resposta", Palette.faint)
        case .replied: nil
        case .failed: ("Não deu certo", Palette.danger)
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
        // Opens at the end, the latest of the work, as a chat does; a new scroll view once the saved work arrives (it
        // is read after the sheet opens), so it starts at its end instead of the empty list's top.
        .modifier(KeepsBottom(follows: true))
        .id(items.isEmpty)
        .overlay {
            if items.isEmpty {
                if isLoading { DelayedSpinner() } else { ContentUnavailableView("Sem registro do trabalho", systemImage: "text.bubble") }
            }
        }
        .frame(height: 400)
        .background(Palette.canvas)
        .orbSheet(bot?.name ?? "Orb", subtitle: live == nil ? "Trabalho do pedido, só para ler" : "Trabalhando agora", size: .large) {
            SheetFooterBar {
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.cancelAction)
            }
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
