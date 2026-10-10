import SwiftUI
import AppKit

/// The left side of "Criar conversando": the bubbles, the assistant's first line with its three ways to begin, the "escrevendo…"
/// line, a failure with "Tentar de novo", and the message field. Nothing here knows the model: it reads and writes a `WizardRunner`.
struct WizardChatView: View {
    let runner: WizardRunner
    /// The look the person chose: the assistant's avatar wears it, so the chat is the Orb being made.
    let look: OrbConfig

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .task { isFocused = true }
        // "Voltar a conversar": the field is where to write.
        .onChange(of: runner.draft.ready) { if !runner.draft.ready { isFocused = true } }
        .accessibilityIdentifier("wizard-chat")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(runner.messages) { item in
                        row(item)
                            .transition(.adapted(.rise, reduceMotion: reduceMotion))
                    }
                    if runner.offersSuggestions {
                        suggestions
                            .padding(.leading, 40)
                            .transition(.opacity)
                    }
                    if !runner.liveText.isEmpty {
                        WizardBotRow(orb: look) {
                            MarkdownChunk(source: runner.liveText, streaming: true, cached: false)
                        }
                    } else if runner.isThinking {
                        writing.transition(.opacity)
                    }
                    if let failure = runner.failure {
                        WizardFailure(message: failure, retry: runner.retry)
                            .transition(.adapted(.rise, reduceMotion: reduceMotion))
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .motion(Motion.enter, value: runner.messages.count)
            .motion(Motion.content, value: runner.isThinking)
            .motion(Motion.content, value: runner.failure)
            .onChange(of: runner.messages.count) { scrollToEnd(proxy) }
            .onChange(of: runner.isThinking) { scrollToEnd(proxy) }
            .onChange(of: runner.failure) { scrollToEnd(proxy) }
            .onChange(of: runner.liveText.count) { scrollToEnd(proxy, animated: false) }
        }
    }

    private static let bottom = "wizard-bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated, !reduceMotion {
            withAnimation(Motion.content) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottom, anchor: .bottom)
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let text, _):
            WizardUserBubble(text: text)
        case .bot(let text, _):
            WizardBotRow(orb: look) { MarkdownChunk(source: text).equatable() }
        default:
            EmptyView()
        }
    }

    /// The three ways to begin: a click sends it.
    private var suggestions: some View {
        WizardWrap(spacing: 8) {
            ForEach(WizardPrompt.suggestions, id: \.self) { suggestion in
                WizardChip(title: suggestion) { runner.send(suggestion) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sugestões para começar")
    }

    /// "escrevendo…" with three dots, while the assistant answers and nothing has streamed yet.
    private var writing: some View {
        HStack(spacing: 8) {
            BotAvatar(orb: look, size: 30, animated: false)
                .accessibilityHidden(true)
            HStack(spacing: 7) {
                WizardTypingDots(animated: !reduceMotion)
                    .frame(width: 22, height: 8)
                Text("escrevendo…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("O assistente está escrevendo")
    }

    // MARK: Composer

    private var canSendNow: Bool { runner.canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if runner.hitLimit { return "Vamos fechar: toque em Criar Orb" }
        if runner.failure != nil { return "Toque em Tentar de novo" }
        return "Responda aqui…"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(runner.isFinished || runner.hitLimit)
                .onSubmit(submit)
                .accessibilityLabel("Mensagem para o assistente de criação")
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSendNow ? Palette.ink : Palette.hint)
            }
            .buttonStyle(.plain)
            .disabled(!canSendNow)
            .help("Enviar (↩)")
            .accessibilityLabel("Enviar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isFocused ? Palette.surfaceFocused : Palette.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isFocused ? Palette.lineStrong : Palette.line))
        .animation(Motion.fade, value: isFocused)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func submit() {
        guard canSendNow else { return }
        let sent = text
        if runner.send(sent) { text = "" }
    }
}

// MARK: - Rows

/// What the assistant says: the Orb being made beside it (still: the live one is on the preview), the words in Markdown.
private struct WizardBotRow<Content: View>: View {
    let orb: OrbConfig
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(orb: orb, size: 30, animated: false)
                .accessibilityHidden(true)
            content
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resposta do assistente")
    }
}

private struct WizardUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.userBubble, in: .rect(cornerRadius: 16))
                .accessibilityLabel("Você: \(text)")
        }
    }
}

/// A failure of the assistant's turn, in the app's usual notice style, with the way out.
private struct WizardFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Label("Não deu certo", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.warn)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button(action: retry) {
                Label("Tentar de novo", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryPillStyle())
            .accessibilityIdentifier("wizard-retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aviso: não deu certo. \(message)")
    }
}

/// A clickable suggestion.
private struct WizardChip: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .hoverFill(isHovering, in: .capsule, color: Palette.raised, resting: Palette.surface)
                .overlay(Capsule().strokeBorder(Palette.line))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Responder: \(title)")
    }
}

// MARK: - Layout

/// Children side by side, wrapping onto the next line when the width runs out.
struct WizardWrap: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, max(width, 0)) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = alignment == .center ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if rows[rows.count - 1].width + needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Typing dots

/// Three dots that rise and fall in turn: Core Animation, so the main thread does nothing per frame. Still when `animated` is false.
struct WizardTypingDots: NSViewRepresentable {
    var animated = true

    func makeNSView(context: Context) -> WizardTypingDotsView { WizardTypingDotsView(animated: animated) }
    func updateNSView(_ view: WizardTypingDotsView, context: Context) { view.animated = animated }
}

final class WizardTypingDotsView: NSView {
    private var dots: [CALayer] = []
    private static let key = "typing"
    var animated: Bool { didSet { if animated != oldValue { updateAnimation() } } }
    /// For tests: whether the dots are moving.
    var isAnimating: Bool { dots.first?.animation(forKey: Self.key) != nil }

    init(animated: Bool) {
        self.animated = animated
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NSColor(Palette.muted).cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        updateAnimation()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let step = bounds.width / 3
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(x: step * (CGFloat(index) + 0.5), y: bounds.midY)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        for (index, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: Self.key)
            guard animated else { dot.opacity = 0.7; continue }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.3, 1, 0.3]
            fade.keyTimes = [0, 0.4, 1]
            fade.duration = 1.1
            fade.repeatCount = .infinity
            fade.beginTime = CACurrentMediaTime() + Double(index) * 0.16
            fade.fillMode = .backwards
            dot.add(fade, forKey: Self.key)
        }
    }
}
