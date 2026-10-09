import SwiftUI

/// What you said while the Orb was working, shown at the end of the chat as waiting. Each one leaves this list for
/// the transcript proper when the Orb takes it in (see `AppModel.deliverSteered`).
struct QueuedMessages: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentedQueued) private var presented
    let botID: UUID

    var body: some View {
        let presented = presented
        let lane = model.composerLane(botID)
        ForEach(lane.queued) { message in
            // The state line and "Parar e enviar" speak for the whole queue: they show once, under the last bubble.
            QueuedBubble(message: message, whenText: whenText, canInterrupt: model.canSteer(botID), needsYou: needsYou,
                         isLast: message.id == lane.queued.last?.id,
                         edit: { model.unqueue(message.id, botID: botID) },
                         interrupt: { model.stopAndSend(botID) })
                // Comes in like the others (rises 6 pt, fades under Reduce Motion) without animating the list; it leaves at
                // once, because the real bubble rises in the same place right after.
                // Only the first time it is made: one that was already on show (chat reopened, row made again) is just there.
                .entrance(.rise, enters: !(presented?.contains(message.id) ?? false))
                .onAppear { presented?.insert(message.id) }
                .transition(.identity)
        }
    }

    private var needsYou: Bool { model.live(botID).needsYou }

    /// When it will be read: at the next step for Orb's own engine, after the answer for Claude Code; after your
    /// answer to the open permission request when the engine is waiting for one.
    private var whenText: String {
        QueuedMessages.whenText(needsYou: needsYou, steersMidTurn: model.steersMidTurn(botID))
    }

    nonisolated static func whenText(needsYou: Bool, steersMidTurn: Bool) -> String {
        if needsYou { return "Na fila · entra depois que você responder ao pedido" }
        return steersMidTurn ? "Na fila · entra no próximo passo" : "Na fila · segue quando a resposta terminar"
    }
}

private struct QueuedBubble: View {
    let message: SteeredMessage
    let whenText: String
    let canInterrupt: Bool
    let needsYou: Bool
    let isLast: Bool
    let edit: () -> Void
    let interrupt: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentPaths.isEmpty { AttachmentStack(paths: message.attachmentPaths, dimmed: true) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Palette.conversationFont)
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        // The same shape as the bubble it becomes (`UserBubble`: radius 18).
                        .background(Palette.userBubble.opacity(0.3), in: .rect(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                }
                HStack(spacing: 10) {
                    if isLast {
                        Label(whenText, systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    Button("Editar", action: edit)
                        .help("Tirar da fila e voltar ao campo de mensagem para editar")
                    if isLast, canInterrupt {
                        Button("Parar e enviar", action: interrupt)
                            .help(needsYou
                                  ? "Interrompe o que o Orb está fazendo, recusa o pedido aberto e envia o que está na fila agora"
                                  : "Interrompe o que o Orb está fazendo e envia o que está na fila agora (\(AppShortcut.commandReturn.label))")
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mensagem na fila: \(message.text)")
    }
}
