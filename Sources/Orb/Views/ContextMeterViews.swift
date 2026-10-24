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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // A detached task does not inherit the cancellation of this one: pass it on, so a measure that a newer
            // signal replaced stops instead of walking the whole history for a result nobody reads.
            let job = Task.detached(priority: .utility) { ContextReading.make(input) }
            reading = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        }
        guard !Task.isCancelled else { return }
        // The chip arriving (or its number gaining a digit) moves the model chip and the buttons beside it: the whole
        // bar slides with it, once per turn, instead of jumping. Not under Reduce Motion (the chip alone fades).
        let shown = gauge.reading?.botID == botID
        let moves = shown != (reading?.botID == botID) || (shown && gauge.reading?.percent != reading?.percent)
        if moves, !reduceMotion {
            withAnimation(Motion.content) { gauge.show(reading) }
        } else {
            gauge.show(reading)
        }
    }
}

// MARK: - Ring

/// A thin rim with a slice that fills clockwise. Decorative: the words next to it, or the button's value, say the same.
struct ContextRing: View {
    let fraction: Double
    let tone: ContextTone
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A pie in a thin rim: a short arc in a faint ring read as the system's spinner (something loading), a slice
        // filled from twelve o'clock reads as an amount.
        ZStack {
            Circle().strokeBorder(Palette.faint, lineWidth: 1.25)
            ContextSlice(fraction: Self.shown(fraction))
                .fill(tone.color)
                .padding(2.5)
        }
        .frame(width: size - 2, height: size - 2)
        .frame(width: size, height: size)
        .animation(Motion.availability(reduceMotion: reduceMotion), value: fraction)
        .accessibilityHidden(true)
    }

    /// The slice as drawn: never thinner than `minimumSlice` once something is in the conversation, or a few percent
    /// would be a hairline, like a clock's hand. The number (on hover and in the popover) is the exact one.
    static func shown(_ fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        return min(max(fraction, minimumSlice), 1)
    }

    static let minimumSlice = 0.08
}

/// The filled part of `ContextRing`: a slice from twelve o'clock, clockwise; it grows smoothly when `fraction` animates.
private struct ContextSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        guard fraction > 0 else { return path }
        if fraction >= 1 { return Path(ellipseIn: rect) }
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Meter in the bar

/// The meter as a chip in the composer's bar: the ring, and its percentage to the left of it (as the battery's is)
/// when there is something to read in it: from 70% on, while the pointer is over it, or while its popover is open.
/// The bar ends at the right, so the number grows the chip leftwards and the ring under the pointer stays put. Never
/// the number when the composer is narrow. Hidden while the conversation is empty. A button, so Tab reaches it with
/// keyboard navigation on; it opens the popover.
struct ContextMeterChip: View {
    let botID: UUID
    let gauge: ContextGauge
    let compact: Bool
    @State private var isOpen = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let reading = gauge.reading, reading.botID == botID { chip(reading) }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: gauge.reading?.botID == botID)
    }

    private func chip(_ reading: ContextReading) -> some View {
        let showsPercent = !compact && reading.tone.showsPercent(pointing: isHovering || isOpen)
        return Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                if showsPercent {
                    Text("\(reading.percent)%")
                        .monospacedDigit()
                        .foregroundStyle(reading.tone == .calm ? Palette.muted : reading.tone.color)
                        // The number rolls to the next one once per turn (never per token); it fades under Reduce Motion.
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(Motion.content, value: reading.percent)
                        .transition(.opacity)
                }
                ContextRing(fraction: reading.fraction, tone: reading.tone)
            }
            // The number comes and goes with the chip widening or narrowing under it; under Reduce Motion it only fades.
            .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: showsPercent)
        }
        .onHover { isHovering = $0 }
        .buttonStyle(ComposerChipStyle())
        .transition(.opacity) // appears with a fade once the first message is measured
        .help("Contexto desta conversa: \(reading.spokenState)")
        .accessibilityLabel("Contexto da conversa")
        .accessibilityValue(reading.spokenState)
        .accessibilityHint("Abre os detalhes e a opção de compactar")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ContextPopoverHost(botID: botID, reading: reading) { isOpen = false }
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
                           SettingsRouter.open(.orbs, using: openSettings)
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
            gauge
            kept
            Divider().padding(.top, 12)
            compactSection
        }
        .frame(width: 340)
        .motion(Motion.content, value: shownResult)
    }

    // MARK: How full

    private var gauge: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(reading.percent)%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(reading.tone == .calm ? Palette.ink : reading.tone.color)
                Text(reading.usageWords.prefix(1).uppercased() + reading.usageWords.dropFirst())
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressCapsule(fraction: reading.fraction, tone: reading.tone)
            if !reading.windowIsStated {
                Text("O provedor não informou a janela deste modelo: o limite é uma estimativa, que o Orb corrige se uma conversa for recusada.")
                    .font(Typography.small)
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
            row("text.quote", ContextWords.kept(totalRequests: reading.requestCount, foldedRequests: reading.foldedRequests))
            if reading.fill.budgetFraction > reading.fill.fraction, reading.fill.budgetFraction >= ContextReading.warmsAt {
                row("arrow.triangle.merge", "Contexto \(reading.memory.label.lowercased()): perto de ~\(ContextWords.approx(reading.fill.budgetTokens)) tokens de conversa, o começo vira resumo sozinho.")
            }
            if let hit = reading.cacheHit {
                row("bolt", ContextWords.cache(hit), detail: "na última chamada ao modelo")
            }
            Button("Ajustar o contexto das conversas…", action: adjustMemory)
                .buttonStyle(.link)
                .help(Tip.adjustContext)
                .font(Typography.small)
        }
        .padding(.horizontal, 14)
    }

    private func row(_ symbol: String, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                if let detail {
                    Text(detail).font(Typography.small).foregroundStyle(Palette.faint)
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
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if reading.canCompact {
                // Same field look as the app's multi-line inputs (PlaceholderTextEditor), not the system bezel.
                TextField("No que focar no resumo?", text: $focus)
                    .textFieldStyle(.plain)
                    .font(Typography.label)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Palette.raised, in: .rect(cornerRadius: Radius.small))
                    .disabled(isWorking)
                    .onSubmit(run)
                    .accessibilityLabel("Foco do resumo")
                    .accessibilityHint("Opcional")
            }
            HStack {
                if isWorking {
                    Text("Espere o Orb terminar para compactar.")
                        .font(Typography.small)
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
        if let compaction = reading.fill.compaction {
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
                        Text("O essencial vai para a memória do Orb.")
                            .font(Typography.small).foregroundStyle(Palette.muted)
                    }
                } else {
                    Text(result.message)
                        .font(Typography.label)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.medium))
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
