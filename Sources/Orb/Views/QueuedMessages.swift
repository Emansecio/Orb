import SwiftUI

/// What you said while the Orb was working, shown at the end of the chat as waiting. Each one leaves this list for
/// the transcript proper when the Orb takes it in (see `AppModel.deliverSteered`).
struct QueuedMessages: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let lane = model.composerLane(botID)
        ForEach(lane.queued) { message in
            // The state line and "Parar e enviar" speak for the whole queue: they show once, under the last bubble.
            QueuedBubble(message: message, whenText: whenText, canInterrupt: model.canSteer(botID),
                         isLast: message.id == lane.queued.last?.id,
                         edit: { model.unqueue(message.id, botID: botID) },
                         interrupt: { model.stopAndSend(botID) })
                .transition(.opacity)
        }
    }

    /// When it will be read: at the next step for Orb's own engine, after the answer for Claude Code.
    private var whenText: String {
        model.steersMidTurn(botID) ? "Na fila · entra no próximo passo" : "Na fila · segue quando a resposta terminar"
    }
}

private struct QueuedBubble: View {
    let message: SteeredMessage
    let whenText: String
    let canInterrupt: Bool
    let isLast: Bool
    let edit: () -> Void
    let interrupt: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachmentPaths.isEmpty {
                        Label(attachmentSummary, systemImage: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(Palette.conversationFont)
                            .foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.userBubble.opacity(0.3), in: .rect(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
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
                            .help("Interrompe o que o Orb está fazendo e envia o que está na fila agora (⌘↩)")
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mensagem na fila: \(message.text)")
    }

    private var attachmentSummary: String {
        let count = message.attachmentPaths.count
        return count == 1 ? (message.attachmentPaths[0] as NSString).lastPathComponent : "\(count) anexos"
    }
}
