import SwiftUI

/// The right side of "Quem ele é" (in the assistant and in the form): the Orb being made, alive on a stage with its glow on the
/// floor, its name and role, how it works and what it may use. The look is always the one the PERSON chose (`look`: the assistant
/// never designs it), with "Personalizar" and "Sortear" under the Orb. In the assistant each `orb_draft` call changes the rest in
/// front of the person (`OrbDraft.revision`): a new name or role changes by fading and is washed for a moment, the instructions
/// unfold, the chips come in one after another; a new look cross-fades and the Orb hops. When the assistant says it is ready the
/// final card enters at the foot. Under Reduce Motion nothing slides, scales or hops: everything changes by opacity.
struct WizardPreviewPane: View {
    let draft: OrbDraft
    let look: OrbConfig
    var activity: OrbActivity = .idle
    var emptyText = "Seu Orb aparece aqui conforme vocês conversam"
    let onAdjust: () -> Void
    let onBack: () -> Void
    /// "Personalizar": the Aparência tab.
    let onDraw: () -> Void
    /// "Sortear": a new look, in place.
    let onRandom: () -> Void

    /// `flashed`: the parts washed at the start (a review snapshot of the moment a call changed them).
    init(draft: OrbDraft, look: OrbConfig, activity: OrbActivity = .idle, emptyText: String = "Seu Orb aparece aqui conforme vocês conversam",
         flashed: Set<DraftField> = [], onAdjust: @escaping () -> Void = {}, onBack: @escaping () -> Void = {},
         onDraw: @escaping () -> Void, onRandom: @escaping () -> Void) {
        self.draft = draft
        self.look = look
        self.activity = activity
        self.emptyText = emptyText
        self.onAdjust = onAdjust
        self.onBack = onBack
        self.onDraw = onDraw
        self.onRandom = onRandom
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
    /// With the final card at the foot: a smaller Orb, so the name, the chips and "Como funciona" fit over the card without
    /// scrolling.
    static let readyOrbSize: CGFloat = 128

    private var hasDraft: Bool { draft.revision > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    stage
                    lookActions
                    if hasDraft {
                        identity
                        // What it will get, from the start (the form's own defaults until the assistant says otherwise).
                        chips(leading: false)
                        if !draft.instructions.isEmpty { howItWorks.transition(.adapted(.unfold, reduceMotion: reduceMotion)) }
                    } else {
                        Text("\(emptyText)")
                            .font(Typography.text)
                            .foregroundStyle(Palette.faint)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                            .transition(.opacity)
                        chips(leading: false)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // What scrolls under the final card fades out instead of being cut. A gradient on top, not a mask: a mask makes the
            // scroll content one flat layer, and the buttons in it (Personalizar, Sortear) stop being found under the pointer.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Palette.chrome.opacity(0), Palette.chrome], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if draft.ready {
                WizardReadyCard(draft: draft, adjust: onAdjust, back: onBack)
                    .padding(.horizontal, 28)
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
        // A new look, from "Sortear" here or from the editor: the Orb that is in hops (the crossfade is the stage's).
        .onChange(of: look) { lookChanged() }
        .onChange(of: draft.ready) { readyChanged() }
        .onDisappear {
            flashTask?.cancel()
            happyTask?.cancel()
        }
        .accessibilityIdentifier("wizard-preview")
    }

    // MARK: Stage

    private var shownActivity: OrbActivity {
        let live = activity
        if live != .idle { return live }
        return isHappy ? .happy : .idle
    }

    private var stage: some View {
        let size = draft.ready ? Self.readyOrbSize : Self.orbSize
        let curve = Motion.adapted(Motion.crossFade, reduceMotion: reduceMotion)
        return ZStack {
            // A soft neutral spotlight behind the Orb (the satin Orb has no glow of its own; its shadow on the floor is
            // drawn by OrbView).
            Ellipse()
                .fill(RadialGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.02), .clear],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 360, height: 300)
                .offset(y: -6)
                .allowsHitTesting(false).accessibilityHidden(true) // light only: it spills past the stage onto Personalizar/Sortear
            ZStack {
                OrbView(config: look, activity: shownActivity, size: size, poke: poke, interactive: true,
                        accessibilityText: "Prévia do Orb: \(look.summary). \(shownActivity.label).")
                    .id(look)
                    .transition(.opacity)
            }
            .frame(width: size, height: size)
        }
        .animation(curve, value: look)
        .frame(height: size + 64)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
    }

    /// "Personalizar" (the Aparência tab) and "Sortear" (a new look, here): the look is the person's, one click away.
    private var lookActions: some View {
        HStack(spacing: 8) {
            Button(action: onDraw) {
                Label("Personalizar", systemImage: "paintbrush")
            }
            .buttonStyle(SecondaryPillStyle())
            .help("Abre a aba Aparência para personalizar o Orb")
            .accessibilityIdentifier("preview-draw")
            Button(action: onRandom) {
                Label("Sortear", systemImage: "dice")
            }
            .buttonStyle(SecondaryPillStyle())
            .help("Sorteia outra aparência para o Orb")
            .accessibilityIdentifier("preview-random")
        }
        .font(Typography.label)
        .padding(.top, -8)
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
                .background(wash(.name), in: .rect(cornerRadius: Radius.small))
                .motion(Motion.content, value: draft.name)
            Text(draft.role.isEmpty ? " " : draft.role)
                .font(Typography.text)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contentTransition(.opacity)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(wash(.role), in: .rect(cornerRadius: Radius.small))
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
                        .font(Typography.small)
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
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
                .lineLimit(isHowOpen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.content, value: draft.instructions)
        }
        .padding(12)
        .background(wash(.instructions), in: .rect(cornerRadius: Radius.card))
        .card(radius: Radius.card)
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

    /// The chips sit centered, under the centered name and role (or the line of copy before there is a draft); `leading`
    /// is kept for a layout that puts them against the boxes' left edge.
    private func chips(leading: Bool) -> some View {
        WizardWrap(spacing: 6, alignment: leading ? .leading : .center) {
            ForEach(Array(chipItems.enumerated()), id: \.element.id) { index, item in
                Label(item.title, systemImage: item.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    // A label, not a button: no fill of its own (only the wash of a change), since nothing here is clickable.
                    .background(flashed.contains(item.field) ? Palette.findWash : .clear, in: .capsule)
                    .transition(reduceMotion ? .quiet
                                : AnyTransition.rise.animation(Motion.enter.delay(Motion.staggerDelay(index))))
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: chipItems.map(\.id))
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: flashed)
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
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
    }

    /// The look cross-fades (the old Orb and the new one are laid over each other); once the new one is in, it hops.
    private func lookChanged() {
        guard !reduceMotion else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            poke += 1
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

/// The card that closes the interview: what is about to be created and the two ways out besides the footer's "Criar Orb". (The Orb creation card of the
/// "Orb cria Orb" feature, `OrbProposalCard`, is built for a proposal that waits in a chat; this one is the assistant's own
/// and has the same look. Not `OrbProposalCard`: that card takes a finished proposal, not a draft.)
struct WizardReadyCard: View {
    let draft: OrbDraft
    let adjust: () -> Void
    let back: () -> Void

    var body: some View {
        // One left edge for the title, the line under it and the buttons: the card's inner padding.
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Tudo pronto: \(draft.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ok)
                        .accessibilityHidden(true)
                }
                Text("Revise ao lado e clique em Criar Orb.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The two are the same kind of button (the one next step is the footer's "Criar Orb"): one style, one height.
            HStack(spacing: 8) {
                Button("Ajustar", action: adjust)
                    .buttonStyle(SecondaryPillStyle())
                    .help("Leva o rascunho para o formulário, para mudar qualquer detalhe")
                Button("Voltar a conversar", action: back)
                    .buttonStyle(SecondaryPillStyle())
                    .help("Continua a conversa com o assistente")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tudo pronto para criar \(draft.name). Clique em Criar Orb, ou escolha Ajustar ou Voltar a conversar.")
    }
}
