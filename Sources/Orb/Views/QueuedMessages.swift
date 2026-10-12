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

    /// Where the message goes; while the pointer is on one of the buttons, what that button does (at once, where a tooltip
    /// would wait a second).
    private var stateLine: some View {
        let hint = hovered.map(hintText)
        return Label(hint ?? whenText, systemImage: hovered.map(hintSymbol) ?? symbol)
            .font(.system(size: 11))
            .foregroundStyle(hint == nil ? Palette.muted : Palette.secondary)
            .lineLimit(1)
            .contentTransition(.identity)
    }

    private enum Action { case edit, switchMode, interrupt }

    @State private var hovered: Action?

    private func hintText(_ action: Action) -> String {
        switch action {
        case .edit: "Editar: volta para o campo de mensagem"
        case .switchMode: message.delivery == .steer ? "Pôr na fila: entra depois da tarefa" : "Direcionar: entra no próximo passo"
        case .interrupt: needsYou ? "Parar e enviar agora (recusa o pedido aberto)" : "Parar o que o Orb faz e enviar agora"
        }
    }

    private func hintSymbol(_ action: Action) -> String {
        switch action {
        case .edit: "pencil"
        case .switchMode: switchSymbol
        case .interrupt: "arrow.up.circle.fill"
        }
    }

    /// The mode the message would move to, by its own symbol (the one its state line has in that mode).
    private var switchSymbol: String {
        QueuedMessages.whenSymbol(delivery: message.delivery == .steer ? .afterTask : .steer)
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            iconButton(.edit, symbol: "pencil", help: "Editar: tira da fila e volta ao campo de mensagem", action: edit)
            if canSwitch {
                iconButton(.switchMode, symbol: switchSymbol, help: QueuedMessages.switchHelp(from: message.delivery), action: switchMode)
            }
            if isLast, canInterrupt {
                iconButton(.interrupt, symbol: "arrow.up.circle.fill", tint: Palette.accentText,
                           help: needsYou
                               ? "Parar e enviar: interrompe o que o Orb está fazendo, recusa o pedido aberto e envia agora"
                               : "Parar e enviar: interrompe o que o Orb está fazendo e envia agora (\(AppShortcut.commandReturn.label))",
                           action: interrupt)
            }
        }
    }

    private func iconButton(_ kind: Action, symbol: String, tint: Color = Palette.muted, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .buttonStyle(CircleGhostStyle(side: 24, fontSize: 12))
        .help(help)
        .accessibilityLabel(hintText(kind))
        .onHover { inside in
            if inside { hovered = kind } else if hovered == kind { hovered = nil }
        }
    }
}
