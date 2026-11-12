import SwiftUI

/// "Gostei" and "Não gostei" for a reply or an action of the Orb. A good one is one click; a bad one opens its reasons,
/// and is given when they close, with or without one (the click already said it was bad). Clicking the chosen one takes
/// it back. The Orb is told with your next message (`AppModel.react`).
///
/// The bad mark is given by the reasons as they leave the screen, not by these buttons: the row may take the buttons
/// away in the same update that closes the reasons (the pointer is no longer on it).
struct ReactionButtons: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID
    let botID: UUID
    let reaction: Reaction?
    /// The reasons are open. The parent's, so it keeps these buttons up after the pointer left the row.
    @Binding var isAsking: Bool
    /// On a line of work: bare symbols, as quiet as the line. Beside a reply: the chips of its other buttons.
    var isInline = false
    /// The pointer is elsewhere: only the mark of what was chosen stays.
    var showsOnlyChosen = false

    var body: some View {
        HStack(spacing: isInline ? 6 : 4) {
            if !showsOnlyChosen || reaction?.isGood == true {
                thumb(isGood: true) { give(reaction?.isGood == true ? nil : Reaction(isGood: true)) }
            }
            if !showsOnlyChosen || reaction?.isGood == false || isAsking {
                thumb(isGood: false) {
                    if reaction?.isGood == false { give(nil) } else { isAsking = true }
                }
                .popover(isPresented: $isAsking, arrowEdge: .bottom) {
                    // Closed any way (a reason, "Enviar", Esc, a click outside): given once, with what was written.
                    ReactionReasons(close: { isAsking = false }) { [model, itemID, botID] reason in
                        model.react(Reaction(isGood: false, reason: reason), to: itemID, of: botID)
                    }
                }
            }
        }
    }

    private func give(_ reaction: Reaction?) { model.react(reaction, to: itemID, of: botID) }

    @ViewBuilder private func thumb(isGood: Bool, action: @escaping () -> Void) -> some View {
        let isChosen = reaction?.isGood == isGood || (!isGood && isAsking)
        let help = isChosen ? Tip.reactUndo : isGood ? Tip.reactGood : Tip.reactBad
        let symbol = Image(systemName: (isGood ? "hand.thumbsup" : "hand.thumbsdown") + (isChosen ? ".fill" : ""))
            .font((isInline ? Typography.small : Typography.small.weight(.medium)))
            .foregroundStyle(isChosen ? Palette.ink : Palette.muted)
        Group {
            if isInline {
                Button(action: action) { symbol.frame(width: 18, height: 18).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .clickablePointer()
            } else {
                Button(action: action) { symbol }.buttonStyle(MessageActionStyle(shape: .circle))
            }
        }
        .help(help)
        .accessibilityLabel(isGood ? "Gostei" : "Não gostei")
        .accessibilityValue(isChosen ? "marcado" : "")
    }
}

/// Why it was bad: a reason in one click, or your own words. Optional: closing it gives the bad mark all the same.
private struct ReactionReasons: View {
    let close: () -> Void
    /// Called once, as the reasons leave the screen, with what was chosen or written (empty: no reason).
    let given: (String) -> Void
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("O que não ficou bom?")
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Reaction.quickReasons, id: \.self) { quick in
                    Button(quick) { reason = quick; close() }
                        .buttonStyle(GhostStyle())
                }
            }
            HStack(spacing: Spacing.xs) {
                TextField("Outro motivo", text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(close)
                Button("Enviar", action: close)
                    .buttonStyle(PrimaryPillStyle())
            }
            Text("O Orb fica sabendo na sua próxima mensagem.")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
        }
        .frame(width: 280, alignment: .leading)
        .padding(Spacing.m)
        .onDisappear { given(reason) }
    }
}
