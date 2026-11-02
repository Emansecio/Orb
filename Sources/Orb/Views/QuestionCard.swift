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
    /// False where the keys do not reach the card (a group's approval bar: esc skips the selected Orb's card).
    let showsKeyHints: Bool

    /// The card arrived while the chat was open: its border pulses once (as an approval card's does).
    @State private var pulsesOnArrival: Bool
    @State private var pulse = 0
    @State private var reply = ""
    /// What is picked of `multiple` options, and what is filled in of a form, a value per field.
    @State private var picked: Set<String> = []
    @State private var values: [String]
    /// Where the card's own keys are being typed in.
    private enum Spot: Hashable {
        case reply
        case field(Int)
    }

    @FocusState private var focus: Spot?
    /// Whether `focus` is on the card, as the key handler needs it (a focus state is only meant to be read while drawing).
    @State private var isTyping = false
    @State private var pressed: ApprovalShortcut?

    init(request: ApprovalRequest, question: OrbQuestion, botID: UUID, pulses: Bool = false, showsKeyHints: Bool = true) {
        self.request = request
        self.question = question
        self.botID = botID
        self.showsKeyHints = showsKeyHints
        _pulsesOnArrival = State(initialValue: pulses)
        _values = State(initialValue: Array(repeating: "", count: question.fields.count))
    }

    /// What "Responder" sends now.
    private var composed: String? { question.composed(picked: picked, values: values, reply: reply) }

    private var isPending: Bool { request.decision == nil }
    /// Whether this is the card esc answers, so "Pular" names the key.
    private var showsKeys: Bool { showsKeyHints && model.showsApprovalKeys(request.id, of: botID) }
    /// Whether ⌘↩ answers this card right now: it is the card the keys reach and something is written to send
    /// (the same rule as `accepts` in `body`).
    private var answerKeyApplies: Bool { showsKeys && composed != nil }
    private var orbName: String { model.live(botID).look.name }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPending {
                pendingCard.transition(.adapted(.cardLeaving, reduceMotion: reduceMotion))
            } else {
                answeredCard.transition(.opacity)
            }
        }
        .chatCard()
        .motion(Motion.content, value: request.decision)
        .onChange(of: focus) { isTyping = focus != nil }
        // ⌘↩ sends what is written on the card, so with nothing written the key is not ours.
        .approvalKeys(botID: botID, approvalID: request.id, isActive: isPending, noteFocused: isTyping, pressed: $pressed,
                      accepts: { $0 != .allow || composed != nil }, answer: perform)
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
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(question.options, id: \.self) { option in
                        if question.multiple {
                            QuestionOptionButton(text: option, isPicked: picked.contains(option)) {
                                if picked.insert(option).inserted == false { picked.remove(option) }
                            }
                        } else {
                            QuestionOptionButton(text: option) { answer(option) }
                        }
                    }
                }
            }
            ForEach(Array(question.fields.enumerated()), id: \.offset) { index, field in
                fieldRow(field, index: index, value: $values[index])
            }
            replyField
            ActionRow {
                Button(action: skip) {
                    HStack(spacing: 6) {
                        Text("Pular")
                        if showsKeys { Text("esc").font(Typography.small).foregroundStyle(Palette.muted) }
                    }
                }
                .buttonStyle(GhostStyle())
                .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
                .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
                .animation(Motion.press, value: pressed)
                .help(ApprovalHints.help(Tip.skipQuestion, key: "Esc", showsKeys: showsKeys))
                // The visible "esc" is a hint for the eye; VoiceOver gets the key as a hint, not in the name.
                .accessibilityLabel("Pular")
                .accessibilityHint(ApprovalHints.accessibilityHint("Esc", showsKeys: showsKeys))
                .hangsOnLeadingEdge()
            } trailing: {
                Button(action: sendComposed) {
                    HStack(spacing: 7) {
                        Text("Responder")
                        if answerKeyApplies {
                            Text(AppShortcut.commandReturn.label).font(Typography.small).opacity(0.55)
                        }
                    }
                }
                .buttonStyle(PrimaryPillStyle())
                .disabled(composed == nil)
                .help(ApprovalHints.help(Tip.answerQuestion, key: AppShortcut.commandReturn.label, showsKeys: answerKeyApplies))
                .accessibilityLabel("Responder")
                .accessibilityHint(ApprovalHints.accessibilityHint(AppShortcut.commandReturn.label, showsKeys: answerKeyApplies))
            }
        }
        .padding(14)
        .card(radius: Radius.card, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulsesOnArrival, reduceMotion: reduceMotion) {
                ApprovalPulseBorder(radius: Radius.card, trigger: pulse)
            }
        }
        .onAppear { if pulsesOnArrival { pulse += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QuestionSpeech.pending(botName: orbName.isEmpty ? "O Orb" : orbName, question: question))
    }

    private func header(asked: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark.bubble")
                .font(Typography.label)
                .foregroundStyle(Palette.accentText)
                .accessibilityHidden(true)
            Text("\(orbName.isEmpty ? "O Orb" : orbName) \(asked ? "perguntou" : "pergunta")")
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.muted)
        }
    }

    /// A line of a form: words to write, or its options as chips, of which one is picked.
    private func fieldRow(_ field: OrbQuestion.Field, index: Int, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.secondary)
            if field.options.isEmpty {
                TextField(field.label, text: value, prompt: nil)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(Typography.text)
                    .focused($focus, equals: .field(index))
                    .onSubmit { submit(from: index) }
                    .sheetTextField(fill: Palette.raised.opacity(0.6), radius: Radius.small)
            } else {
                WrappingLayout(spacing: Spacing.s) {
                    ForEach(field.options, id: \.self) { option in
                        QuestionChip(text: option, isPicked: value.wrappedValue == option) {
                            value.wrappedValue = value.wrappedValue == option ? "" : option
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
    }

    /// Your own words: with answers to pick it reads "Outra resposta…", without them it is the way to answer.
    private var replyField: some View {
        let offers = !question.options.isEmpty || !question.fields.isEmpty
        return TextField(offers ? "Outra resposta…" : "Sua resposta…", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Typography.text)
            .lineLimit(1...5)
            .focused($focus, equals: .reply)
            .onSubmit(sendComposed)
            .sheetTextField(fill: Palette.raised.opacity(0.6), radius: Radius.small)
            .accessibilityLabel(offers ? "Outra resposta" : "Sua resposta")
    }

    // MARK: Answered

    private var answeredCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(asked: true)
            Text(question.text)
                .font(Typography.text)
                .foregroundStyle(Palette.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let answer = question.answer {
                    Image(systemName: "checkmark")
                        .font(Typography.small.weight(.semibold))
                        .foregroundStyle(Palette.accentText)
                        .accessibilityHidden(true)
                    Text(answer)
                        .font(Typography.text.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Image(systemName: "arrow.uturn.forward")
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                        .accessibilityHidden(true)
                    Text("Sem resposta")
                        .font(Typography.text)
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

    private func sendComposed() {
        if let composed { answer(composed) }
    }

    /// Return walks the form and sends from its last line, so the first Return never sends half of it.
    private func submit(from index: Int) {
        if let next = question.textField(after: index) { focus = .field(next) } else { sendComposed() }
    }

    private func skip() {
        model.decide(.deny, approvalID: request.id, botID: botID)
    }

    private func perform(_ shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allow: sendComposed()
        case .deny: skip()
        }
    }
}

extension OrbQuestion {
    /// The next field to write in; lines of options take no typing.
    func textField(after index: Int) -> Int? {
        fields.indices.first { $0 > index && fields[$0].options.isEmpty }
    }
}

/// One answer to pick: a click sends it. With `isPicked` it is one of several: a click marks it, and "Responder" sends them.
private struct QuestionOptionButton: View {
    let text: String
    var isPicked: Bool?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let isPicked {
                    Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isPicked ? Palette.accentText : Palette.muted)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.hint)
                    .opacity(isHovering && isPicked == nil ? 1 : 0)
                    .animation(Motion.hover(isHovering), value: isHovering)
                    .accessibilityHidden(true)
            }
            .font(Typography.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .hoverFill(isHovering, in: .rect(cornerRadius: Radius.small), color: Palette.raised, resting: Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .clickablePointer()
        .onHover { isHovering = $0 }
        .help(isPicked == nil ? Tip.pickAnswer : Tip.markAnswer)
        .accessibilityHint(isPicked == nil ? "Responde com esta opção" : "Marca ou desmarca esta opção")
        .accessibilityAddTraits(isPicked == true ? .isSelected : [])
    }
}

/// An option of a form's line.
private struct QuestionChip: View {
    let text: String
    let isPicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Typography.label)
                .foregroundStyle(isPicked ? Palette.ink : Palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isPicked ? Palette.ghostSelected : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(isPicked ? Palette.lineStrong : Palette.line))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .clickablePointer()
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// What VoiceOver says for a question card.
enum QuestionSpeech {
    static func pending(botName: String, question: OrbQuestion) -> String {
        let names = question.fields.isEmpty ? question.options : question.fields.map(\.label)
        let options = names.isEmpty ? "" : (question.fields.isEmpty ? ". Opções: " : ". Campos: ") + names.joined(separator: "; ")
        return "\(botName) pergunta: \(question.text)\(options)"
    }

    static func answered(_ question: OrbQuestion) -> String {
        "Pergunta: \(question.text). " + (question.answer.map { "Você respondeu: \($0)" } ?? "Sem resposta")
    }
}
