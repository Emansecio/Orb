import SwiftUI

// The context meter: a small ring in the composer's bar (how much of the model's window the conversation takes), the
// popover it opens ("Contexto desta conversa", with "Compactar agora"), and the one-line card above the composer that
// appears when the conversation is getting long. The numbers come from `ContextGauge`; nothing here measures.

extension ContextTone {
    var color: Color {
        switch self {
        case .calm: Palette.muted
        case .warming: Palette.warn.opacity(0.7)
        case .full: Palette.warn
        }
    }
}

// MARK: - Driver

/// Measures the Orb's conversation when something that changes the numbers does, and hands the reading to the gauge.
/// An invisible view of its own, so what it reads (the transcript's revision, the model, the last request's usage)
/// re-renders nothing but itself, and the measuring (which walks the whole history) runs off the main thread.
struct ContextGaugeDriver: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let gauge: ContextGauge

    private struct Signal: Hashable {
        var botID: UUID
        var revision: Int
        var isWorking: Bool
        var modelID: String
        var defaultModel: String
        var memory: ContextMemoryLevel
        var promptTokens: Int?
        var cacheRead: Int?
        var compactedTo: Int?
    }

    var body: some View {
        let live = model.live(botID)
        let usage = live.lastUsage
        let signal = Signal(botID: botID, revision: model.orbTranscript(botID).revision, isWorking: live.isWorking,
                            modelID: live.modelID, defaultModel: model.defaultModel, memory: model.contextMemory,
                            promptTokens: usage?.promptTokens, cacheRead: usage?.cacheRead, compactedTo: live.compactedTo)
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: signal) { await measure() }
    }

    private func measure() async {
        // A burst of changes (a tool finishing, the next one starting) is measured once.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        var reading: ContextReading?
        if let input = model.contextInput(for: botID) {
            reading = await Task.detached(priority: .utility) { ContextReading.make(input) }.value
        }
        guard !Task.isCancelled else { return }
        gauge.show(reading)
    }
}

// MARK: - Ring

/// A thin ring that fills clockwise. Decorative: the words next to it, or the button's value, say the same.
struct ContextRing: View {
    let fraction: Double
    let tone: ContextTone
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Palette.lineStrong, lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tone.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size - 2, height: size - 2)
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

// MARK: - Meter in the bar

/// The meter as a chip in the composer's bar: the ring and the percentage (the ring alone when the composer is narrow).
/// Hidden while the conversation is empty. A button, so Tab reaches it with keyboard navigation on; it opens the popover.
struct ContextMeterChip: View {
    let botID: UUID
    let gauge: ContextGauge
    let compact: Bool
    @State private var isOpen = false

    var body: some View {
        if let reading = gauge.reading, reading.botID == botID {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 5) {
                    if reading.fill != nil {
                        ContextRing(fraction: reading.fraction, tone: reading.tone)
                        if !compact {
                            Text("\(reading.percent)%")
                                .monospacedDigit()
                                .foregroundStyle(reading.tone == .calm ? Palette.muted : reading.tone.color)
                        }
                    } else {
                        Image(systemName: "gauge.with.needle")
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .buttonStyle(ComposerChipStyle())
            .help("Contexto desta conversa: \(reading.spokenState)")
            .accessibilityLabel("Contexto da conversa")
            .accessibilityValue(reading.spokenState)
            .accessibilityHint("Abre os detalhes e a opção de compactar")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                ContextPopoverHost(botID: botID, reading: reading) { isOpen = false }
            }
        }
    }
}

// MARK: - Popover

/// Gives the popover what only the model knows (is the Orb busy; how to compact; how to open Ajustes).
private struct ContextPopoverHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let botID: UUID
    let reading: ContextReading
    let close: () -> Void

    var body: some View {
        ContextPopover(reading: reading, isWorking: model.live(botID).isWorking,
                       compact: { model.compactFromMeter(botID, focus: $0) },
                       adjustMemory: {
                           close()
                           SettingsRouter.open(.general, using: openSettings)
                       })
    }
}

/// "Contexto desta conversa": how full it is, what is kept word for word, what the provider's cache served, and
/// "Compactar agora" with an optional focus for the summary and the result after.
struct ContextPopover: View {
    let reading: ContextReading
    var isWorking = false
    /// What an earlier compaction said (the review snapshots show the popover after one).
    var result: CompactionResult?
    let compact: (String?) -> CompactionResult
    let adjustMemory: () -> Void

    @State private var focus = ""
    @State private var done: CompactionResult?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shownResult: CompactionResult? { done ?? result }
    private var canRun: Bool { reading.canCompact && !isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contexto desta conversa")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            if reading.fill != nil { gauge }
            kept
            Divider().padding(.top, 12)
            compactSection
        }
        .frame(width: 340)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shownResult)
    }

    // MARK: How full

    private var gauge: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(reading.percent)%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(reading.tone == .calm ? Palette.ink : reading.tone.color)
                Text(reading.usageWords.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressCapsule(fraction: reading.fraction, tone: reading.tone)
            if !reading.windowIsStated {
                Text("O provedor não informou a janela deste modelo: o limite é uma estimativa, que o Orb corrige se uma conversa for recusada.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uso do contexto")
        .accessibilityValue(reading.spokenState)
    }

    // MARK: What is kept

    private var kept: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("O que fica na conversa")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .accessibilityAddTraits(.isHeader)
            if reading.isClaudeCode {
                row("sparkles", "O Claude Code cuida do próprio contexto: ele resume a sessão sozinho quando ela enche.")
            } else {
                row("text.quote", ContextWords.kept(totalRequests: reading.requestCount, foldedRequests: reading.foldedRequests))
                if let fill = reading.fill, fill.budgetFraction > fill.fraction, fill.budgetFraction >= ContextReading.warmsAt {
                    row("arrow.triangle.merge", "Memória \(reading.memory.label.lowercased()): perto de ~\(ContextWords.approx(fill.budgetTokens)) tokens de conversa, o começo vira resumo sozinho.")
                }
                if let hit = reading.cacheHit {
                    row("bolt", ContextWords.cache(hit), detail: "na última chamada ao modelo")
                }
            }
            if !reading.isClaudeCode {
                Button("Ajustar a memória das conversas…", action: adjustMemory)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
    }

    private func row(_ symbol: String, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Compact now

    private var compactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(compactingExplanation)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if reading.canCompact {
                TextField("No que focar no resumo?", text: $focus)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isWorking)
                    .onSubmit(run)
                    .accessibilityLabel("Foco do resumo")
                    .accessibilityHint("Opcional")
            }
            HStack {
                if isWorking {
                    Text("Espere o Orb terminar para compactar.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 8)
                Button("Compactar agora", action: run)
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(AppShortcut.commandReturn)
                    .disabled(!canRun)
                    .help("Compactar agora (\(AppShortcut.commandReturn.label))")
            }
            if let shownResult { resultView(shownResult) }
        }
        .padding(14)
    }

    private var compactingExplanation: String {
        if reading.isClaudeCode {
            return "Compactar agora faz um resumo desta conversa e encerra a sessão atual do Claude Code: a próxima mensagem começa uma sessão nova, a partir desse resumo."
        }
        if let compaction = reading.fill?.compaction {
            return ContextWords.wouldFree(requests: compaction.turns, alreadySummarized: reading.foldedRequests > 0,
                                          tokens: compaction.tokensFreed)
        }
        return ContextWords.nothingToCompact(requests: reading.requestCount - reading.foldedRequests, alreadySummarized: reading.foldedRequests > 0)
    }

    private func run() {
        guard canRun else { return }
        let text = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        done = compact(text.isEmpty ? nil : text)
    }

    private func resultView(_ result: CompactionResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.didCompact ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(result.didCompact ? Palette.ok : Palette.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if result.didCompact {
                    Text(ContextWords.compaction(before: result.tokensBefore, after: result.tokensAfter))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if result.savedToMemory {
                        Text("O essencial ficou guardado na memória do Orb.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    if result.status == .claudeSessionRestarted {
                        Text(AppModel.claudeRestartNote)
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                } else {
                    Text(result.message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Palette.raised, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

/// A thin bar for the share of the window in use.
private struct ProgressCapsule: View {
    let fraction: Double
    let tone: ContextTone

    var body: some View {
        Capsule()
            .fill(Palette.lineStrong)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tone.color)
                        .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Card above the composer

/// "Esta conversa está ficando longa. Compactar agora ou começar uma nova?": one gentle line above the composer when
/// the conversation is near the point where its start is folded away. Shown once per conversation: dismissing it, or
/// acting on it, keeps it from coming back.
struct ContextNudge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    let gauge: ContextGauge
    /// Why a try at compacting did not happen ("Espere o Orb terminar…"), in place of the question.
    @State private var note: String?
    var body: some View {
        // Nothing (no height, no spacing) while the card is not due: the composer sits exactly where it did without it.
        ZStack {
            if gauge.showsNudge, gauge.reading?.botID == botID {
                card
                    .padding(.bottom, 6)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: gauge.showsNudge)
        .onChange(of: gauge.reading?.conversationKey) { note = nil }
    }

    private var canCompact: Bool { gauge.reading?.canCompact ?? false }

    private var question: String { note ?? ContextWords.nudgeQuestion(canCompact: canCompact) }

    private var card: some View {
        content
        .font(.system(size: 12))
        .foregroundStyle(Palette.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .card(radius: 14, fill: Palette.raised.opacity(0.7), stroke: Palette.line)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aviso: a conversa está ficando longa")
    }

    /// The question and the buttons on one line; when they do not fit, the buttons drop to a line of their own. The
    /// layout decides by the width it is offered, in the same pass. The question is capped at two lines: text that may
    /// wrap without limit has no bounded height for the chat's bottom inset to reserve (with `ViewThatFits` and an
    /// unbounded wrapping `Text` the inset grew past the window and pushed the composer out of it).
    private var content: some View {
        OneLineOrTwo(spacing: 10, lineSpacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                Text(question).lineLimit(2)
            }
            actions
        }
    }

    private var icon: some View {
        Image(systemName: "text.append")
            .foregroundStyle(ContextTone.full.color)
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            primaryButtons
            dismiss
        }
    }

    @ViewBuilder private var primaryButtons: some View {
        // With one request there is nothing older to summarize: only a new conversation helps.
        if canCompact {
            Button("Compactar agora", action: compact)
                .buttonStyle(CardButtonStyle(isProminent: true))
                .disabled(model.live(botID).isWorking)
                .help(model.live(botID).isWorking ? "Espere o Orb terminar para compactar" : "Resumir o começo da conversa para liberar espaço")
        }
        Button("Nova conversa") {
            gauge.handleNudge()
            model.newConversation(botID)
        }
        .buttonStyle(CardButtonStyle(isProminent: !canCompact))
        .help("Guardar esta conversa em Conversas e começar outra")
    }

    private var dismiss: some View {
        Button("Dispensar", systemImage: "xmark") { gauge.handleNudge() }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.muted)
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .help("Dispensar: não avisar de novo nesta conversa")
    }

    private func compact() {
        let result = model.compactFromMeter(botID, focus: nil)
        if result.didCompact { gauge.handleNudge() } else { note = result.message }
    }
}

/// Two children side by side when they fit in the width offered (the first keeps its natural width), else the first
/// across the full width (its text wraps) with the second below it, at the trailing edge.
private struct OneLineOrTwo: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func fitsOneLine(_ subviews: Subviews, width: CGFloat) -> Bool {
        guard subviews.count == 2 else { return true }
        return subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let first = subviews[0].sizeThatFits(.unspecified), second = subviews[1].sizeThatFits(.unspecified)
        let natural = first.width + spacing + second.width
        guard let width = proposal.width else { return CGSize(width: natural, height: max(first.height, second.height)) }
        if natural <= width { return CGSize(width: width, height: max(first.height, second.height)) }
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: wrapped.height + lineSpacing + second.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let second = subviews[1].sizeThatFits(.unspecified)
        if fitsOneLine(subviews, width: bounds.width) {
            let first = subviews[0].sizeThatFits(.unspecified)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: first.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + wrapped.height + lineSpacing + second.height / 2),
                              anchor: .trailing, proposal: .unspecified)
        }
    }
}

/// The small pills of the card above the composer.
private struct CardButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isProminent ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isProminent
                        ? Palette.ink.opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.3))
                        : (configuration.isPressed || isHovering ? Palette.ghostSelected : Palette.ghostHover),
                        in: .capsule)
            .opacity(isEnabled || isProminent ? 1 : 0.5)
            .onHover { isHovering = $0 }
    }
}
