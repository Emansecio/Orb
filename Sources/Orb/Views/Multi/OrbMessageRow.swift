import SwiftUI

/// A message between Orbs in a chat, as a small card on the text's left edge: the two mini avatars (a dot breathes between them
/// while the answer is awaited), the sentence as this chat's Orb reads it ("Pediu ajuda ao Revisor") over the start of the
/// message, the state and a chevron that unfolds the whole text (`Motion.panel`). "Ver troca" opens the exchange read-only
/// (`ExchangeSheet`). The card is as wide as the chat lets it, up to 560 pt: the words give way, never the marks.
struct OrbMessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: OrbMessageItem
    /// The Orb whose chat shows the line.
    let botID: UUID
    @State private var unfolded: Bool
    @State private var showsExchange = false
    @State private var showsWork = false
    /// The card is narrower than `narrowBelow`: the state goes without its word (the icon, the colour and the dot say it), so
    /// the sentence keeps the room. Changes only when the width crosses it, not at every step of a resize.
    @State private var isNarrow = false
    static let narrowBelow: CGFloat = 340

    /// `startsUnfolded` is for the review snapshots, which cannot press the line.
    init(message: OrbMessageItem, botID: UUID, startsUnfolded: Bool = false) {
        self.message = message
        self.botID = botID
        _unfolded = State(initialValue: startsUnfolded)
    }

    var body: some View {
        let to = message.to ?? message.from
        let awaits = message.state == .open
        let line = ExchangeWords.line(for: message, in: botID)
        let preview = Self.preview(message.text)
        let isGroup = Self.speaksWithGroup(message)
        // This chat's Orb asked: while the one asked works on it, the card says what it does; if it went wrong, it can be asked again.
        let ownAsk = message.direction == .sent && message.kind == .ask && message.from.id == botID
        VStack(alignment: .leading, spacing: 0) {
            Button {
                unfolded.toggle()
            } label: {
                HStack(spacing: Spacing.m) {
                    ExchangeGlyph(from: side(message.from, isGroup: isGroup && message.kind == .reply),
                                  to: side(to, isGroup: isGroup && message.kind == .ask), awaits: awaits)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                        if !unfolded, !preview.isEmpty {
                            Text(preview)
                                .font(Typography.label)
                                .foregroundStyle(Palette.faint)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                    ExchangeStateMark(state: message.state, showsWord: !isNarrow)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(unfolded ? 90 : 0))
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: unfolded)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(unfolded ? "Recolher a mensagem" : "Ver a mensagem")
            .accessibilityLabel(line)
            .accessibilityValue(ExchangeStateMark.spoken(message.state))
            .accessibilityHint(unfolded ? "Recolhe a mensagem" : "Desdobra a mensagem")

            if awaits, ownAsk, !isGroup {
                ExchangeWorkLine(botID: to.id, requestID: message.requestID) { showsWork = true }
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.s)
                    .transition(AnyTransition.adapted(.unfold, reduceMotion: reduceMotion))
            }

            if unfolded {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text(message.text.isEmpty ? "Sem texto." : message.text)
                        .font(Typography.text)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let wentWrong = ownAsk && Self.wentWrong(message.state)
                    if wentWrong, let reason = failureReason() {
                        Text("Motivo: \(reason)")
                            .font(Typography.label)
                            .foregroundStyle(Palette.warn)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: Spacing.s) {
                        Spacer(minLength: 0)
                        if wentWrong {
                            // Into the composer, not sent: the person reads it and sends it, or changes it.
                            Button("Pedir de novo") { model.addToDraft(Self.retryDraft(for: message), for: botID) }
                                .buttonStyle(GhostStyle(tint: nil))
                                .help("Escreve o pedido de novo na sua mensagem; você confere e envia")
                        }
                        Button("Ver troca") { showsExchange = true }
                            .buttonStyle(GhostStyle(tint: nil))
                    }
                }
                .padding([.horizontal, .bottom], Spacing.m)
                .transition(AnyTransition.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .card(radius: Radius.card, stroke: awaits ? Palette.accentText.opacity(0.3) : Palette.line)
        .frame(maxWidth: cardWidth, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowBelow } action: { isNarrow = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: unfolded)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: awaits)
        .sheet(isPresented: $showsExchange) {
            // The chat's own copy of the exchange; this line alone when the Orb that holds the rest is gone.
            let found = ExchangeSource.messages(chain: message.chainID, request: message.requestID, of: botID, in: model)
            let messages = found.isEmpty ? [message] : found
            ExchangeSheet(messages: messages, parties: ExchangeSource.parties(of: messages))
        }
        .sheet(isPresented: $showsWork) {
            SideWorkSheet(botID: to.id, requestID: message.requestID)
        }
    }

    /// One side of the exchange: the Orb, or, for a group, its members (the orchestrator first, as `ref` carries its id), without
    /// this chat's Orb, which is already the other side.
    private func side(_ ref: OrbRef, isGroup: Bool) -> [UUID] {
        guard isGroup, let group = message.groupID.flatMap(model.group) else { return [ref.id] }
        return [ref.id] + group.memberIDs.filter { $0 != ref.id && $0 != botID }
    }

    /// The answer that said why the request went wrong, from this chat (read only once the card is unfolded).
    private func failureReason() -> String? {
        let reply = model.orbTranscript(botID).items.lazy.compactMap { item -> OrbMessageItem? in
            if case .orbMessage(let reply) = item.kind, reply.direction == .reply, reply.requestID == message.requestID { return reply }
            return nil
        }.first
        return reply.map { MemoryText.clip(MemoryText.flatten($0.text), 300) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A request sent from the chat to a group, or its answer: the group speaks as one, under its orchestrator's id.
    static func speaksWithGroup(_ message: OrbMessageItem) -> Bool {
        message.fromChat == true && message.direction != .post && message.groupID != nil
    }

    static func wentWrong(_ state: OrbMessageItem.State) -> Bool {
        [.failed, .refused, .lost].contains(state)
    }

    /// What "Pedir de novo" writes for the person to send: "Peça de novo ao Revisor: Confere os impostos."
    static func retryDraft(for message: OrbMessageItem) -> String {
        let to = message.to?.name ?? "outro Orb"
        let target = speaksWithGroup(message) ? "ao grupo \(to)" : "\(PortugueseArticle.contraction(for: to)) \(to)"
        return "Peça de novo \(target): \(message.text)"
    }

    /// The start of the message under the sentence: its first line, at most 200 characters. A reply can be 6,000 long, and
    /// the line is laid out again at every width while the window is resized.
    static func preview(_ text: String) -> String {
        String(text.drop { $0.isWhitespace }.prefix(200).prefix { !$0.isNewline })
    }
}

/// The state of an exchange message as a small mark after its line: waiting (the word alone: the card's dot already breathes),
/// answered (a check), failed or refused (a warning), cancelled, or lost when the app closed before the answer came.
struct ExchangeStateMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: OrbMessageItem.State
    /// Off in a narrow card (`OrbMessageRow.narrowBelow`).
    var showsWord = true

    var body: some View {
        // The symbol alone is small and says nothing to someone who has not met it: every state but the answered one also
        // has its word beside it, in the symbol's colour (the answered one is the quiet, expected case).
        HStack(spacing: 4) {
            symbol
            if state != .replied, showsWord {
                Text(Self.tooltip(state))
                    .font(Typography.small)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true) // the line's value says it (`spoken`)
        .help(Self.tooltip(state))
    }

    private var tint: Color {
        switch state {
        // Orange, not red: red is kept for confirming a destructive action (UI-3).
        case .failed, .refused: Palette.warn
        case .replied: Palette.muted
        case .lost: Palette.warn // no answer came: the person may need to decide
        case .open, .cancelled: Palette.faint
        }
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .open:
            EmptyView()
        case .replied:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .transition(AnyTransition.adapted(.mark, reduceMotion: reduceMotion))
        case .failed, .refused:
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.small)
                .foregroundStyle(tint)
        case .cancelled:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
        case .lost:
            Image(systemName: "clock.badge.questionmark")
                .font(Typography.small)
                .foregroundStyle(tint)
        }
    }

    /// What the mark says when the pointer rests on it: every state has its words.
    static func tooltip(_ state: OrbMessageItem.State) -> String {
        switch state {
        case .open: "Aguardando"
        case .replied: "Respondido"
        case .failed: "Não deu certo"
        case .refused: "Recusado"
        case .cancelled: "Cancelado"
        case .lost: "Sem resposta"
        }
    }

    /// What VoiceOver says of the state (the line's value).
    static func spoken(_ state: OrbMessageItem.State) -> String {
        switch state {
        case .open: "aguardando"
        case .replied: "respondido"
        case .failed: "não deu certo"
        case .refused: "recusado"
        case .cancelled: "cancelado"
        case .lost: "sem resposta, o app fechou antes da resposta"
        }
    }
}

/// A run of rows that folds into one line: the summary (the caller's, with the state of `unfolded`) and, unfolded, the rows it
/// holds, each coming in after the one before (`Motion.stagger`, at most six). Its id is its first item's, so the run keeps
/// its state while it grows.
struct FoldedThread<Summary: View, Child: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [TranscriptItem]
    let summary: (_ unfolded: Bool) -> Summary
    let child: (TranscriptItem) -> Child
    @State private var unfolded: Bool

    /// `startsUnfolded` is for the review snapshots, which cannot press the line.
    init(items: [TranscriptItem], startsUnfolded: Bool = false, @ViewBuilder summary: @escaping (_ unfolded: Bool) -> Summary,
         @ViewBuilder child: @escaping (TranscriptItem) -> Child) {
        self.items = items
        self.summary = summary
        self.child = child
        _unfolded = State(initialValue: startsUnfolded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                unfolded.toggle()
            } label: {
                summary(unfolded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(unfolded ? "Recolhe" : "Desdobra")
            if unfolded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    child(item)
                        .transition(staggered(index))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: unfolded)
    }

    private func staggered(_ index: Int) -> AnyTransition {
        reduceMotion ? .quiet : AnyTransition.unfold.animation(Motion.enter.delay(Motion.staggerDelay(index)))
    }
}

/// The line of a folded exchange, drawn as the card of one message so both read as one family: the Orbs it speaks with,
/// stacked (up to three), the count and the partners ("3 mensagens com Revisor"), the state of all of them and the chevron.
struct ExchangeSummary: View {
    let items: [TranscriptItem]
    let botID: UUID
    let unfolded: Bool

    var body: some View {
        let partners = TranscriptFolding.partners(of: items, botID: botID)
        let state = OrbMessageItem.State.overall(items.compactMap { item in
            if case .orbMessage(let message) = item.kind { return message.state }
            return nil
        })
        HStack(spacing: Spacing.m) {
            MiniOrbs(ids: partners.map(\.id))
            Text(TranscriptFolding.exchangeTitle(items, botID: botID))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            ExchangeStateMark(state: state)
            // The chevron turns its sign rather than turning: nothing rotates in a row that folds under Reduce Motion.
            Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .card(radius: Radius.card, stroke: state == .open ? Palette.accentText.opacity(0.3) : Palette.line)
        .frame(maxWidth: cardWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(ExchangeStateMark.spoken(state))
    }
}
