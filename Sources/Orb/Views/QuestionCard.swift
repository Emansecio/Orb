import SwiftUI

/// The card of `ask_user`: the Orb's question, its answers to pick (one click answers), a line to answer in your own words
/// and "Pular" (Esc). Writing in the message box answers it too (`AppModel.submit`). Answered, it shrinks to the question and
/// the answer with a check, and stays in view: what was asked and answered is part of the conversation.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let request: ApprovalRequest
    let question: OrbQuestion
    let botID: UUID

    /// The card arrived while the chat was open: its border pulses once (as an approval card's does).
    @State private var pulsesOnArrival: Bool
    @State private var pulse = 0
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    /// `replyFocused` as the key handler needs it (a focus state is only meant to be read while drawing).
    @State private var isTyping = false
    @State private var pressed: ApprovalShortcut?

    init(request: ApprovalRequest, question: OrbQuestion, botID: UUID, pulses: Bool = false) {
        self.request = request
        self.question = question
        self.botID = botID
        _pulsesOnArrival = State(initialValue: pulses)
    }

    private var isPending: Bool { request.decision == nil }
    /// Whether this is the card esc answers, so "Pular" names the key.
    private var showsKeys: Bool { model.showsApprovalKeys(request.id, of: botID) }
    private var orbName: String { model.live(botID).look.name }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPending {
                pendingCard.transition(.adapted(Self.leaving, reduceMotion: reduceMotion))
            } else {
                answeredCard.transition(.opacity)
            }
        }
        .padding(.leading, 36)
        .frame(maxWidth: 560, alignment: .leading)
        .motion(Motion.content, value: request.decision)
        .onChange(of: replyFocused) { isTyping = replyFocused }
        .background { if isPending { ApprovalKeyMonitor(handler: handleKey) } }
        .task(id: pressed) { await answerPressed() }
    }

    private static var leaving: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }

    // MARK: Pending

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(asked: false)
            Text(question.text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        QuestionOptionButton(text: option) { answer(option) }
                    }
                }
            }
            replyField
            ActionRow {
                Button(action: skip) {
                    HStack(spacing: 6) {
                        Text("Pular")
                        if showsKeys { Text("esc").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    }
                }
                .buttonStyle(GhostStyle())
                .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
                .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
                .animation(Motion.press, value: pressed)
                .help(Tip.skipQuestion)
                .accessibilityHint("Atalho: Esc")
                .hangsOnLeadingEdge()
            } trailing: {
                Button("Responder") { answer(reply) }
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(OrbQuestion.clean(reply) == nil)
                    .help(Tip.answerQuestion)
            }
        }
        .padding(14)
        .card(radius: 12, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulsesOnArrival, reduceMotion: reduceMotion) {
                ApprovalPulseBorder(radius: 12, trigger: pulse)
            }
        }
        .onAppear { if pulsesOnArrival { pulse += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QuestionSpeech.pending(botName: orbName.isEmpty ? "O Orb" : orbName, question: question))
    }

    private func header(asked: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            Text("\(orbName.isEmpty ? "O Orb" : orbName) \(asked ? "perguntou" : "pergunta")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
        }
    }

    /// Your own words: with answers to pick it reads "Outra resposta…", without them it is the way to answer.
    private var replyField: some View {
        TextField(question.options.isEmpty ? "Sua resposta…" : "Outra resposta…", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...5)
            .focused($replyFocused)
            .onSubmit { answer(reply) }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 8))
            .accessibilityLabel(question.options.isEmpty ? "Sua resposta" : "Outra resposta")
    }

    // MARK: Answered

    private var answeredCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(asked: true)
            Text(question.text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let answer = question.answer {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                        .accessibilityHidden(true)
                    Text(answer)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .accessibilityHidden(true)
                    Text("Sem resposta")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(QuestionSpeech.answered(question))
    }

    // MARK: Answers

    private func answer(_ text: String) {
        guard let reply = OrbQuestion.clean(text) else { return }
        model.decide(.once, reply: reply, approvalID: request.id, botID: botID)
    }

    private func skip() {
        model.decide(.deny, approvalID: request.id, botID: botID)
    }

    /// Esc skips, and ⌘↩ sends what is written on the card, when it is the newest open card of the Orb being shown.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id,
              !model.findFieldHasFocus else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: isTyping)
        let typingInComposer = ApprovalShortcut.isTypingInComposer(isEditing: editing, noteFocused: isTyping)
        guard let shortcut = ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      isEditingText: editing, isTypingInComposer: typingInComposer) else { return false }
        if shortcut == .allow, OrbQuestion.clean(reply) == nil { return false } // nothing written to send
        press(shortcut)
        return true
    }

    private func press(_ shortcut: ApprovalShortcut) {
        guard pressed == nil else { return }
        if ApprovalShortcut.pressDelay(reduceMotion: reduceMotion) == .zero {
            perform(shortcut)
        } else {
            pressed = shortcut
        }
    }

    private func answerPressed() async {
        guard let shortcut = pressed else { return }
        try? await Task.sleep(for: ApprovalShortcut.pressDelay(reduceMotion: reduceMotion))
        perform(shortcut)
        pressed = nil
    }

    private func perform(_ shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allow: answer(reply)
        case .deny: skip()
        }
    }
}

/// One answer to pick: a click sends it.
private struct QuestionOptionButton: View {
    let text: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(text)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.hint)
                    .opacity(isHovering ? 1 : 0)
                    .animation(Motion.hover(isHovering), value: isHovering)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .hoverFill(isHovering, in: .rect(cornerRadius: 8), color: Palette.raised, resting: Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickablePointer()
        .onHover { isHovering = $0 }
        .help(Tip.pickAnswer)
        .accessibilityHint("Responde com esta opção")
    }
}

/// What VoiceOver says for a question card.
enum QuestionSpeech {
    static func pending(botName: String, question: OrbQuestion) -> String {
        let options = question.options.isEmpty ? "" : ". Opções: " + question.options.joined(separator: "; ")
        return "\(botName) pergunta: \(question.text)\(options)"
    }

    static func answered(_ question: OrbQuestion) -> String {
        "Pergunta: \(question.text). " + (question.answer.map { "Você respondeu: \($0)" } ?? "Sem resposta")
    }
}
