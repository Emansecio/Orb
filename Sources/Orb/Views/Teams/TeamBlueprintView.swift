import SwiftUI

/// Right-hand / lower live blueprint panel of `NewTeamSheet`: displays what the Olheiro scouted and lets the user
/// edit team name, Mission criteria, and member cards directly before clicking "Criar e iniciar".
struct TeamBlueprintView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var runner: TeamScouterRunner
    @State private var newCriterion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !runner.proposal.hasContent {
                    EmptyBlueprintCard(isThinking: runner.isThinking)
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                } else {
                    if !runner.proposal.analysisSummary.isEmpty || !runner.proposal.scoutNote.isEmpty {
                        ScoutDiscoveryCard(summary: runner.proposal.analysisSummary,
                                           note: runner.proposal.scoutNote,
                                           highlighted: runner.highlightedFields.contains(.analysisSummary))
                            .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                    }

                    MissionDraftCard(proposal: $runner.proposal,
                                     newCriterion: $newCriterion,
                                     highlighted: runner.highlightedFields,
                                     addCriterion: {
                                         runner.addCriterion(newCriterion)
                                         newCriterion = ""
                                     },
                                     removeCriterion: { runner.removeCriterion(at: $0) })
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))

                    MembersDraftSection(runner: runner,
                                        highlighted: runner.highlightedFields.contains(.members))
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: runner.proposal.hasContent)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: runner.highlightedFields)
    }
}

private struct EmptyBlueprintCard: View {
    let isThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StackedAvatars(members: [
                    StackedAvatars.Member(id: UUID(), orb: TeamMemberDraft.preset(at: 0)),
                    StackedAvatars.Member(id: UUID(), orb: TeamMemberDraft.preset(at: 1)),
                    StackedAvatars.Member(id: UUID(), orb: TeamMemberDraft.preset(at: 2)),
                ], size: 26, overlap: 9)
                Text(isThinking ? "Montando a escalação…" : "A prancheta do time aparece aqui")
                    .font(Typography.text.weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Assim que você mandar a ideia ao lado, o Olheiro analisa a pasta (se houver) e propõe os papéis ideais com critérios verificáveis:")
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                BlueprintRoleHint(icon: "star.fill", title: "Líder coordenador", detail: "Divide frentes, mantém contratos e integra")
                BlueprintRoleHint(icon: "hammer.fill", title: "Especialistas em paralelo", detail: "Executam funções e testes em worktrees")
                BlueprintRoleHint(icon: "checkmark.shield.fill", title: "Revisor independente", detail: "Audita critérios antes de concluir")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct BlueprintRoleHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Palette.accentText)
                .frame(width: 16)
            Text(title)
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.ink)
            Text("· \(detail)")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
        }
    }
}

private struct ScoutDiscoveryCard: View {
    let summary: String
    let note: String
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accentText)
                Text("Notas do Olheiro")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.faint)
            }
            if !note.isEmpty {
                Text(note)
                    .font(Typography.text)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(stroke: highlighted ? Palette.accentText.opacity(0.5) : Palette.line)
    }
}

private struct MissionDraftCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var proposal: TeamProposal
    @Binding var newCriterion: String
    let highlighted: Set<TeamProposalField>
    let addCriterion: () -> Void
    let removeCriterion: (Int) -> Void

    var body: some View {
        let isHighlighted = highlighted.contains(.teamName) || highlighted.contains(.objective) || highlighted.contains(.criteria)
        VStack(alignment: .leading, spacing: 10) {
            Text("Missão do time")
                .font(Typography.label.weight(.medium))
                .foregroundStyle(Palette.faint)

            TextField("Nome do time", text: $proposal.teamName)
                .textFieldStyle(.plain)
                .font(Typography.text.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.raised, in: .rect(cornerRadius: Radius.medium))

            TextField("Objetivo claro da missão", text: $proposal.objective, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.label)
                .lineLimit(2...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.raised, in: .rect(cornerRadius: Radius.medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Critérios de pronto")
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(Palette.faint)

                ForEach(Array(proposal.criteria.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ok)
                        Text(item)
                            .font(Typography.label)
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                                removeCriterion(index)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.faint)
                        }
                        .buttonStyle(.plain)
                        .help("Remover critério")
                    }
                    .transition(.adapted(.mark, reduceMotion: reduceMotion))
                }

                if proposal.criteria.count < 8 {
                    HStack(spacing: 6) {
                        TextField("Adicionar critério verificável…", text: $newCriterion)
                            .textFieldStyle(.plain)
                            .font(Typography.label)
                            .onSubmit { addCriterion() }
                        Button("Adicionar") { addCriterion() }
                            .chipButton()
                            .disabled(newCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(stroke: isHighlighted ? Palette.accentText.opacity(0.5) : Palette.line)
    }
}

private struct MembersDraftSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var runner: TeamScouterRunner
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Integrantes (\(runner.proposal.members.count))")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.faint)
                if runner.proposal.hasDuplicateNames {
                    Text("· nomes repetidos")
                        .font(Typography.small)
                        .foregroundStyle(Palette.warn)
                }
                Spacer()
                if runner.proposal.members.count < OrbTeam.maxMembers {
                    Button {
                        withAnimation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion)) {
                            runner.addMemberDraft()
                        }
                    } label: {
                        Label("Adicionar", systemImage: "plus")
                    }
                    .chipButton()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: Spacing.cardSpacing, alignment: .top)],
                      alignment: .leading, spacing: Spacing.cardSpacing) {
                ForEach(Array(runner.proposal.members.enumerated()), id: \.element.id) { index, _ in
                    TeamMemberDraftCard(
                        member: $runner.proposal.members[index],
                        canRemove: runner.proposal.members.count > OrbTeam.recommendedLimits.lowerBound,
                        makeOrchestrator: { runner.setOrchestratorDraft(runner.proposal.members[index].id) },
                        cycleLook: { runner.cycleMemberOrb(runner.proposal.members[index].id) },
                        remove: {
                            withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                                runner.removeMemberDraft(runner.proposal.members[index].id)
                            }
                        }
                    )
                    .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                    .animation(reduceMotion ? nil : Motion.enter.delay(Motion.staggerDelay(index)), value: runner.proposal.members.count)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(stroke: highlighted ? Palette.accentText.opacity(0.5) : Palette.line)
    }
}

private struct TeamMemberDraftCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var member: TeamMemberDraft
    let canRemove: Bool
    let makeOrchestrator: () -> Void
    let cycleLook: () -> Void
    let remove: () -> Void
    @State private var avatarHop = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Motion.press) {
                        cycleLook()
                        avatarHop += 1
                    }
                } label: {
                    BotAvatar(orb: member.orb, size: 28, poke: avatarHop)
                }
                .buttonStyle(.plain)
                .help("Trocar aparência do integrante")

                TextField("Nome", text: $member.name)
                    .textFieldStyle(.plain)
                    .font(Typography.text.weight(.medium))
                    .foregroundStyle(Palette.ink)

                Button {
                    withAnimation(Motion.press) { makeOrchestrator() }
                } label: {
                    Image(systemName: member.isOrchestrator ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(member.isOrchestrator ? Palette.accentText : Palette.faint)
                }
                .buttonStyle(.plain)
                .help(member.isOrchestrator ? "Líder do time" : "Definir como líder")

                if canRemove {
                    Button { remove() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Remover integrante")
                }
            }

            TextField("Papel ou especialidade", text: $member.role, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.small)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1...3)

            ModelPicker(selection: $member.model, title: "Modelo", allowsDefault: true)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.medium, fill: Palette.raised.opacity(0.75))
    }
}
