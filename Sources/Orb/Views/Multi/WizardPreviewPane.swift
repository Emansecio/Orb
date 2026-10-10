import SwiftUI

/// The right side of "Criar conversando": the Orb being made, alive on a stage with its glow on the floor, its name and role,
/// how it works and what it may use. Each `orb_draft` call changes it in front of the person (`OrbDraft.revision`): a new look
/// cross-fades and the Orb hops, a new name or role changes by fading and is washed for a moment, the instructions unfold,
/// the chips come in one after another. When the assistant says it is ready the final card enters at the foot.
/// Under Reduce Motion nothing slides, scales or hops: everything changes by opacity.
struct WizardPreviewPane: View {
    let runner: WizardRunner
    let onCreate: () -> Void
    let onAdjust: () -> Void

    /// `flashed`: the parts washed at the start (a review snapshot of the moment a call changed them).
    init(runner: WizardRunner, flashed: Set<DraftField> = [], onCreate: @escaping () -> Void, onAdjust: @escaping () -> Void) {
        self.runner = runner
        self.onCreate = onCreate
        self.onAdjust = onAdjust
        _flashed = State(initialValue: flashed)
    }

    @State private var poke = 0
    @State private var flashed: Set<DraftField>
    @State private var flashTask: Task<Void, Never>?
    @State private var isHappy = false
    @State private var happyTask: Task<Void, Never>?
    @State private var isHowOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let orbSize: CGFloat = 168

    private var draft: OrbDraft { runner.draft }
    private var hasDraft: Bool { draft.revision > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    stage
                    if hasDraft {
                        identity
                        if !draft.instructions.isEmpty { howItWorks.transition(.adapted(.unfold, reduceMotion: reduceMotion)) }
                        chips
                    } else {
                        Text("Seu Orb aparece aqui conforme vocês conversam")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.faint)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            if draft.ready {
                WizardReadyCard(draft: draft, create: onCreate, adjust: onAdjust, back: runner.backToChatting)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.chrome)
        .animation(Motion.adapted(Motion.emphasis, reduceMotion: reduceMotion), value: draft.ready)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: hasDraft)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: draft.instructions.isEmpty)
        .task {
            // The Orb waves when the assistant opens.
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(350))
            poke += 1
        }
        .onChange(of: draft.revision) { revisionChanged() }
        .onChange(of: draft.ready) { readyChanged() }
        .onDisappear {
            flashTask?.cancel()
            happyTask?.cancel()
        }
        .accessibilityIdentifier("wizard-preview")
    }

    // MARK: Stage

    private var shownActivity: OrbActivity {
        let live = runner.activity
        if live != .idle { return live }
        return isHappy ? .happy : .idle
    }

    private var stage: some View {
        let palette = OrbCatalog.shared.palette(draft.orb.color)
        let size = Self.orbSize
        let curve = Motion.adapted(Motion.crossFade, reduceMotion: reduceMotion)
        return ZStack {
            // A soft spotlight behind the Orb and the pool of light on the floor under it, in the Orb's own color. The color
            // changes on the same curve as the look.
            Ellipse()
                .fill(RadialGradient(colors: [palette.glow.opacity(0.2), palette.core.opacity(0.06), .clear],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 360, height: 300)
                .offset(y: -6)
            Ellipse()
                .fill(RadialGradient(colors: [palette.glow.opacity(0.34), palette.core.opacity(0.1), .clear],
                                     center: .center, startRadius: 0, endRadius: 130))
                .frame(width: 300, height: 58)
                .offset(y: size / 2 + 4)
            Ellipse()
                .strokeBorder(palette.core.opacity(0.3), lineWidth: 1)
                .frame(width: 214, height: 30)
                .offset(y: size / 2 + 6)
            ZStack {
                OrbView(config: draft.orb, activity: shownActivity, size: size, poke: poke, interactive: true,
                        accessibilityText: "Prévia do Orb: \(draft.orb.summary). \(shownActivity.label).")
                    .id(draft.orb)
                    .transition(.opacity)
            }
            .frame(width: size, height: size)
        }
        .animation(curve, value: draft.orb)
        .frame(height: size + 88)
        .padding(.top, 36)
        .accessibilityElement(children: .contain)
    }

    // MARK: Name, role, instructions, chips

    private var identity: some View {
        VStack(spacing: 4) {
            Text(draft.name.isEmpty ? "Sem nome ainda" : draft.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(draft.name.isEmpty ? Palette.faint : Palette.ink)
                .lineLimit(1)
                .contentTransition(.opacity)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(wash(.name), in: .rect(cornerRadius: 8))
                .motion(Motion.content, value: draft.name)
            Text(draft.role.isEmpty ? " " : draft.role)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contentTransition(.opacity)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(wash(.role), in: .rect(cornerRadius: 8))
                .motion(Motion.content, value: draft.role)
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: flashed)
        .accessibilityElement(children: .combine)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isHowOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Como funciona")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.faint)
                    Spacer(minLength: 4)
                    Text(isHowOpen ? "Mostrar menos" : "Ver tudo")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                    Image(systemName: isHowOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isHowOpen ? "Como funciona, recolher" : "Como funciona, expandir")
            Text(draft.instructions)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
                .lineLimit(isHowOpen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.content, value: draft.instructions)
        }
        .padding(12)
        .background(wash(.instructions), in: .rect(cornerRadius: 12))
        .card(radius: 12)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: isHowOpen)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: flashed)
    }

    private struct ChipItem: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var field: DraftField
    }

    private var chipItems: [ChipItem] {
        var items: [ChipItem] = OrbDraft.offeredCapabilities.filter(draft.capabilities.contains).map {
            ChipItem(id: "cap-\($0.rawValue)", symbol: $0.symbol, title: $0.label, field: .capabilities)
        }
        if items.isEmpty { items.append(ChipItem(id: "cap-none", symbol: "bubble.left", title: "Sem ferramentas extras", field: .capabilities)) }
        items.append(ChipItem(id: "mode", symbol: draft.mode.symbol, title: draft.mode.label, field: .mode))
        return items
    }

    private var chips: some View {
        WizardWrap(spacing: 6, alignment: .center) {
            ForEach(Array(chipItems.enumerated()), id: \.element.id) { index, item in
                Label(item.title, systemImage: item.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(flashed.contains(item.field) ? Palette.findWash : Palette.raised, in: .capsule)
                    .transition(reduceMotion ? .quiet
                                : AnyTransition.rise.animation(Motion.enter.delay(Motion.staggerDelay(index))))
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: chipItems.map(\.id))
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: flashed)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pode usar: " + chipItems.map(\.title).joined(separator: ", "))
    }

    /// The brief wash behind the part the last call changed.
    private func wash(_ field: DraftField) -> Color { flashed.contains(field) ? Palette.findWash : .clear }

    // MARK: Reactions

    private func revisionChanged() {
        let changed = draft.changed
        if !changed.isEmpty {
            flashTask?.cancel()
            flashed = changed
            flashTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                flashed = []
            }
        }
        // The look cross-fades (the old Orb and the new one are laid over each other); once the new one is in, it hops.
        if changed.contains(.look), !reduceMotion {
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                poke += 1
            }
        }
    }

    private func readyChanged() {
        happyTask?.cancel()
        guard draft.ready else {
            isHappy = false
            return
        }
        isHappy = true
        happyTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            isHappy = false
        }
    }
}

// MARK: - The final card

/// The card that closes the interview: what is about to be created and the three ways out. (The Orb creation card of the
/// "Orb cria Orb" feature, `OrbProposalCard`, is built for a proposal that waits in a chat; this one is the assistant's own
/// and has the same look. TODO: swap for `OrbProposalCard` fed by the draft when that card takes a draft.)
struct WizardReadyCard: View {
    let draft: OrbDraft
    let create: () -> Void
    let adjust: () -> Void
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ok)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tudo pronto: \(draft.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text("Nada foi criado ainda. Crie agora, ajuste no formulário ou volte a conversar.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Criar", action: create)
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Cria o Orb (⌘↩)")
                    .accessibilityIdentifier("wizard-ready-create")
                Button("Ajustar", action: adjust)
                    .buttonStyle(SecondaryPillStyle())
                    .help("Leva o rascunho para o formulário, para mudar qualquer detalhe")
                Button("Voltar a conversar", action: back)
                    .buttonStyle(GhostStyle())
                    .help("Continua a conversa com o assistente")
            }
        }
        .padding(14)
        .card(radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tudo pronto para criar \(draft.name). Botões: Criar, Ajustar, Voltar a conversar.")
    }
}
