import AppKit
import SwiftUI

/// "Novo time": interactive sheet with the Olheiro (Team Scouter) on one side and the live editable Team blueprint on the other.
struct NewTeamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runner: TeamScouterRunner
    @State private var isCompact = false
    @State private var scoutPoke = 0

    nonisolated static let compactBelow: CGFloat = 720

    init(runner: TeamScouterRunner? = nil) {
        _runner = State(initialValue: runner ?? TeamScouterRunner())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScoutHeader(runner: runner, scoutPoke: $scoutPoke) {
                runner.cancel()
                dismiss()
            }
            Divider().overlay(Palette.line)

            Group {
                if isCompact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ScoutConversationPane(runner: runner, scoutPoke: $scoutPoke, compact: true)
                            Divider().overlay(Palette.line)
                            TeamBlueprintView(runner: runner)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ScoutConversationPane(runner: runner, scoutPoke: $scoutPoke, compact: false)
                            .frame(width: 360)
                        Divider().overlay(Palette.line)
                        TeamBlueprintView(runner: runner)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Palette.line)
            ScoutFooter(runner: runner) {
                runner.cancel()
                dismiss()
            } create: {
                if runner.createTeam(startNow: true) != nil {
                    dismiss()
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 860, maxWidth: 940, minHeight: 520, idealHeight: 620, maxHeight: 700)
        .background(Palette.chrome)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBelow } action: { isCompact = $0 }
        .onAppear {
            if runner.model == nil { runner.permissionMode = model.defaultTeamPermissionMode }
            runner.attach(model)
        }
        .accessibilityIdentifier("new-team-sheet")
    }
}

private struct ScoutHeader: View {
    let runner: TeamScouterRunner
    @Binding var scoutPoke: Int
    let close: () -> Void

    private var subtitle: String {
        if runner.isThinking { return runner.currentSearchingPhrase }
        if runner.proposal.canCreate { return "Proposta pronta — ajuste como quiser ou crie o time" }
        return "Descreva a ideia e escolha o modelo que vai escalar o time"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                scoutPoke += 1
            } label: {
                SettlingOrb(idle: runner.activity == .idle, wake: scoutPoke) { paused in
                    BotAvatar(orb: TeamScouterRunner.scoutOrb, size: 38, activity: runner.activity,
                              paused: paused, poke: scoutPoke, ack: runner.scoutAck, landing: runner.scoutLanding,
                              interactive: true)
                }
            }
            .buttonStyle(.plain)
            .help("Olheiro de times")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Novo time")
                        .font(Typography.title)
                        .foregroundStyle(Palette.ink)
                    Text("com Olheiro")
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.14), in: Capsule())
                }
                Text(subtitle)
                    .font(Typography.label)
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            SheetCloseButton(action: close)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct ScoutConversationPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var runner: TeamScouterRunner
    @Binding var scoutPoke: Int
    let compact: Bool
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScoutConfigStrip(runner: runner)
            Divider().overlay(Palette.line)

            if compact {
                conversationBody
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        conversationBody
                            .padding(.bottom, 8)
                        Color.clear.frame(height: 1).id("scout-bottom")
                    }
                    .onChange(of: runner.messages.count) {
                        withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("scout-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            if let failure = runner.failure {
                ScoutFailureBanner(message: failure, retry: { runner.retry() })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }

            ScoutComposerBar(runner: runner, inputFocused: $inputFocused)
        }
        .task { inputFocused = true }
    }

    private var conversationBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(runner.messages) { item in
                ScoutChatRow(item: item)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
            if runner.offersStarters {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Começos rápidos")
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                    ForEach(TeamScouterPrompt.starterIdeas, id: \.title) { idea in
                        Button {
                            runner.send(idea.prompt)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.accentText)
                                Text(idea.title)
                                    .font(Typography.label)
                                    .foregroundStyle(Palette.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .card(radius: Radius.medium, fill: Palette.raised)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
            if runner.offersRefinements {
                ScoutRefinementChips { prompt in runner.send(prompt) }
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            if runner.isSpeaking {
                Text(runner.liveText)
                    .font(Typography.text)
                    .foregroundStyle(Palette.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: Radius.medium, fill: Palette.surface)
            } else if runner.isThinking {
                HStack(spacing: 8) {
                    WorkingRing()
                    Text(runner.currentSearchingPhrase)
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .shimmer()
                        .id(runner.searchingStep)
                        .transition(.adapted(.swap, reduceMotion: reduceMotion))
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScoutConfigStrip: View {
    @Bindable var runner: TeamScouterRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Olheiro")
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 68, alignment: .leading)
                ModelPicker(selection: $runner.scouterModel, title: "Olheiro", allowsDefault: true)
                    .labelsHidden()
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("Pasta")
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 68, alignment: .leading)
                Button {
                    pickFolder()
                } label: {
                    let label = runner.projectFolder.isEmpty ? "Opcional — escolher pasta…" : runner.projectFolder
                    Text(label)
                        .font(Typography.label)
                        .foregroundStyle(runner.projectFolder.isEmpty ? Palette.faint : Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(runner.projectFolder.isEmpty ? "Escolha uma pasta para o Olheiro espiar antes de escalar" : runner.projectFolder)

                if !runner.projectFolder.isEmpty {
                    Button { runner.projectFolder = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Limpar pasta")
                }
            }

            HStack(spacing: 8) {
                Text("Modo")
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 68, alignment: .leading)
                Picker("Modo", selection: $runner.permissionMode) {
                    ForEach(PermissionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if runner.permissionMode == .bypass {
                Label("Autonomia total: integrantes rodam comandos e edições sem pedir confirmação.", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.small)
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher pasta"
        if !runner.projectFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: runner.projectFolder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            runner.projectFolder = url.path
        }
    }
}

private struct ScoutChatRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text, _):
            HStack {
                Spacer(minLength: 24)
                Text(text)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Palette.userBubble, in: .rect(cornerRadius: Radius.medium))
            }
        case .bot(let text, _):
            Text(text)
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: Radius.medium, fill: Palette.surface)
        default:
            EmptyView()
        }
    }
}

private struct ScoutRefinementChips: View {
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Ajustes rápidos com o Olheiro")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
            FlowWrap {
                ForEach(TeamScouterPrompt.quickRefinements, id: \.label) { chip in
                    Button(chip.label) { send(chip.prompt) }
                        .chipButton()
                }
            }
        }
    }
}

private struct ScoutFailureBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(Typography.small)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Tentar de novo", action: retry)
                .chipButton()
        }
        .padding(10)
        .card(radius: Radius.medium, stroke: Palette.danger.opacity(0.35))
    }
}

private struct ScoutComposerBar: View {
    @Bindable var runner: TeamScouterRunner
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(runner.proposal.hasContent ? "Peça ajustes ao Olheiro…" : "Conte sua ideia de time…",
                      text: $runner.idea, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.text)
                .lineLimit(1...4)
                .focused(inputFocused)
                .onSubmit { submit() }

            if runner.isThinking {
                Button {
                    runner.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help("Parar Olheiro")
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSubmit ? Palette.accentText : Palette.hint)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help(runner.proposal.hasContent ? "Enviar ajuste para o Olheiro" : "Convocar Olheiro")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.line))
        .padding(12)
    }

    private var canSubmit: Bool {
        runner.canSend && !runner.idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = runner.idea
        guard runner.send(text) else { return }
        runner.idea = ""
    }
}

private struct ScoutFooter: View {
    let runner: TeamScouterRunner
    let cancel: () -> Void
    let create: () -> Void

    private var summary: String {
        if !runner.proposal.hasContent { return "Converse com o Olheiro para montar a escalação" }
        if runner.proposal.hasDuplicateNames { return "Cada integrante precisa de um nome único no time" }
        if runner.proposal.members.count < OrbTeam.recommendedLimits.lowerBound {
            return "Inclua ao menos 2 integrantes para criar"
        }
        return "\(runner.proposal.members.count) integrantes escalados"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(Typography.small)
                .foregroundStyle(runner.proposal.hasDuplicateNames ? Palette.warn : Palette.faint)
                .lineLimit(1)
            Spacer()
            Button("Cancelar", action: cancel)
                .buttonStyle(SecondaryPillStyle())
                .keyboardShortcut(.cancelAction)
            Button("Criar e iniciar", action: create)
                .buttonStyle(PrimaryPillStyle())
                .disabled(!runner.proposal.canCreate)
                .accessibilityIdentifier("create-team-button")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// Simple wrapping layout for playful refinement chips.
private struct FlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in laid.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: ProposedViewSize(laid.sizes[index]))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            lineHeight = max(lineHeight, size.height)
            maxWidth = max(maxWidth, x + size.width)
            x += size.width + spacing
        }
        return (CGSize(width: maxWidth, height: y + lineHeight), origins, sizes)
    }
}
