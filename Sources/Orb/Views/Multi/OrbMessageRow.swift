import SwiftUI

/// A message between Orbs in a chat, as one centred line: the two mini avatars and an arrow, the sentence ("Atlas pediu
/// ajuda ao Revisor"), the state of the message and a chevron that unfolds its text (`Motion.panel`). "Ver troca" opens the
/// exchange read-only (`ExchangeSheet`).
struct OrbMessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: OrbMessageItem
    /// The Orb whose chat shows the line.
    let botID: UUID
    @State private var unfolded: Bool
    @State private var showsExchange = false

    /// `startsUnfolded` is for the review snapshots, which cannot press the line.
    init(message: OrbMessageItem, botID: UUID, startsUnfolded: Bool = false) {
        self.message = message
        self.botID = botID
        _unfolded = State(initialValue: startsUnfolded)
    }

    var body: some View {
        let to = message.to ?? message.from
        VStack(spacing: 6) {
            Button {
                unfolded.toggle()
            } label: {
                HStack(spacing: 8) {
                    ExchangeGlyph(from: message.from.id, to: to.id)
                    Text(ExchangeWords.line(for: message))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    ExchangeStateMark(state: message.state)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(unfolded ? 90 : 0))
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: unfolded)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(unfolded ? "Recolher a mensagem" : "Ver a mensagem")
            .accessibilityLabel(ExchangeWords.line(for: message))
            .accessibilityValue(ExchangeStateMark.spoken(message.state))
            .accessibilityHint(unfolded ? "Recolhe a mensagem" : "Desdobra a mensagem")

            if unfolded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.text.isEmpty ? "Sem texto." : message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if message.state == .open {
                            Text("Esperando a resposta")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.faint)
                        }
                        Spacer(minLength: 0)
                        Button("Ver troca") { showsExchange = true }
                            .buttonStyle(GhostStyle(tint: nil))
                    }
                }
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .card(radius: 10)
                .transition(AnyTransition.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: unfolded)
        .sheet(isPresented: $showsExchange) {
            // The chat's own copy of the exchange; this line alone when the Orb that holds the rest is gone.
            let found = ExchangeSource.messages(chain: message.chainID, of: botID, in: model)
            let messages = found.isEmpty ? [message] : found
            ExchangeSheet(messages: messages, parties: ExchangeSource.parties(of: messages))
        }
    }
}

/// The state of an exchange message as a small mark after its line: waiting (three dots that pulse, still under Reduce Motion),
/// answered (a check), failed or refused (a warning), cancelled, or lost when the app closed before the answer came.
struct ExchangeStateMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: OrbMessageItem.State

    var body: some View {
        Group {
            switch state {
            case .open:
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
            case .replied:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .transition(AnyTransition.adapted(.mark, reduceMotion: reduceMotion))
            case .failed, .refused:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warn)
            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            case .lost:
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
        }
        .accessibilityHidden(true) // the line's value says it (`spoken`)
        .help(Self.tooltip(state))
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
        VStack(spacing: 6) {
            Button {
                unfolded.toggle()
            } label: {
                summary(unfolded)
                    .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: unfolded)
    }

    private func staggered(_ index: Int) -> AnyTransition {
        reduceMotion ? .quiet : AnyTransition.unfold.animation(Motion.enter.delay(Motion.staggerDelay(index)))
    }
}

/// The line of a folded exchange: the Orbs it speaks with, stacked (up to three, 6 pt over each other), the count and the
/// partners ("3 mensagens com Revisor"), and the chevron.
struct ExchangeSummary: View {
    let items: [TranscriptItem]
    let botID: UUID
    let unfolded: Bool

    var body: some View {
        let partners = TranscriptFolding.partners(of: items, botID: botID)
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(partners.prefix(3), id: \.id) { partner in
                    MiniOrb(botID: partner.id)
                }
            }
            Text(TranscriptFolding.exchangeTitle(items, botID: botID))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            // The chevron turns its sign rather than turning: nothing rotates in a row that folds under Reduce Motion.
            Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .combine)
    }
}
