import SwiftUI

/// What you said while the Orb was working, shown at the end of the chat as waiting, each with where it is going: into
/// the task at the next step, or after it. Each one leaves this list for the transcript proper when the Orb takes it
/// in (see `AppModel.deliverSteered`).
struct QueuedMessages: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentedQueued) private var presented
    let botID: UUID

    var body: some View {
        let presented = presented
        let lane = model.composerLane(botID)
        ForEach(lane.queued) { message in
            // Each bubble says where it goes; "Parar e enviar" speaks for the whole queue and shows once, under the last one.
            QueuedBubble(message: message, whenText: whenText(message.delivery), canInterrupt: QueuedMessages.canInterrupt(canSteer: model.canSteer(botID), pendingPictures: lane.pendingPictures), needsYou: needsYou,
                         isLast: message.id == lane.queued.last?.id, canSwitch: model.canSteer(botID),
                         edit: { model.unqueue(message.id, botID: botID) },
                         switchMode: { model.switchDelivery(message.id, botID: botID) },
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

    /// Where it goes and when it will be read (see `whenText(needsYou:delivery:)`).
    private func whenText(_ delivery: SteeringDelivery) -> String {
        QueuedMessages.whenText(needsYou: needsYou, delivery: delivery)
    }

    /// A picture still on its way would miss the message that stops the turn (the composer's button waits too).
    nonisolated static func canInterrupt(canSteer: Bool, pendingPictures: Int) -> Bool { canSteer && pendingPictures == 0 }

    /// The line under a waiting message. A steered one is read at the next step (after your answer to the open permission
    /// request, when it waits for one) and the others after the task.
    nonisolated static func whenText(needsYou: Bool, delivery: SteeringDelivery) -> String {
        if delivery == .afterTask { return "Depois da tarefa" }
        return needsYou ? "Entra depois que você responder ao pedido" : "Entra no próximo passo"
    }

    /// The icon of that line: a steered message is on its way into the task; the others wait.
    nonisolated static func whenSymbol(delivery: SteeringDelivery) -> String {
        delivery == .steer ? "arrow.turn.down.right" : "clock"
    }

    /// The bubble's button that moves the message to the other mode, named for where it would go.
    nonisolated static func switchTitle(from delivery: SteeringDelivery) -> String { delivery == .steer ? "Pôr na fila" : "Direcionar" }

    nonisolated static func switchHelp(from delivery: SteeringDelivery) -> String { delivery == .steer ? Tip.queueAfterTask : Tip.steerNow }
}

private struct QueuedBubble: View {
    let message: SteeredMessage
    let whenText: String
    let canInterrupt: Bool
    let needsYou: Bool
    let isLast: Bool
    /// The engine can take a message in the middle of the task, so the mode can be changed.
    let canSwitch: Bool
    let edit: () -> Void
    let switchMode: () -> Void
    let interrupt: () -> Void

    private var symbol: String { QueuedMessages.whenSymbol(delivery: message.delivery) }

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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        // The same shape as the bubble it becomes (`UserBubble`: radius 16).
                        .background(Palette.userBubble.opacity(0.5), in: .rect(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                }
                // One row when it fits; the line above the buttons when the chat is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        stateLine
                        buttons
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        stateLine
                        buttons
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mensagem pendente (\(whenText)): \(message.text)")
    }

    private var stateLine: some View {
        Label(whenText, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Editar", action: edit)
                .help("Tirar da fila e voltar ao campo de mensagem para editar")
            if canSwitch {
                Button(QueuedMessages.switchTitle(from: message.delivery), action: switchMode)
                    .help(QueuedMessages.switchHelp(from: message.delivery))
            }
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
