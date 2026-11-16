import SwiftUI

/// Live detail view for an exclusive `Integrante` inside a Team: role, goal, assigned stages,
/// and recent auditable actions from `times/<teamID>/audit.jsonl`.
struct TeamMemberChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let teamID: UUID
    let memberID: UUID
    @State private var recentAudit: [TeamAuditEntry] = []
    @State private var promotedNotice: (botID: UUID, name: String)?

    var body: some View {
        if let team = model.team(teamID), let member = team.member(id: memberID) {
            let assignedStages = team.mission.stages.filter {
                $0.ownerMemberID == member.id || $0.reviewerMemberID == member.id
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button {
                            model.selection = .team(team.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(team.name)
                            }
                            .font(Typography.label.weight(.medium))
                            .foregroundStyle(Palette.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let promotedNotice {
                            HStack(spacing: 6) {
                                Text("Promovido: \(promotedNotice.name)")
                                    .font(Typography.small)
                                    .foregroundStyle(Palette.ok)
                                Button("Abrir em Orbs") { model.selection = .bot(promotedNotice.botID) }
                                    .chipButton()
                            }
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            SettlingOrb(idle: member.state.orbActivity == .idle) { paused in
                                BotAvatar(orb: member.orb, size: 44, activity: member.state.orbActivity, paused: paused, interactive: true)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(member.name)
                                        .font(Typography.title)
                                        .foregroundStyle(Palette.ink)
                                    TeamPill(text: member.state.label, tint: stateColor(member.state))
                                }
                                if !member.role.isEmpty {
                                    Text(member.role)
                                        .font(Typography.text)
                                        .foregroundStyle(Palette.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Menu {
                                Button("Promover para meus Orbs", systemImage: "arrow.up.forward.app") {
                                    if let bot = model.promoteMemberToOrb(teamID: team.id, memberID: member.id, select: false) {
                                        withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                                            promotedNotice = (bot.id, bot.name)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .accessibilityHidden(true)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
                            .fixedSize()
                            .help("Mais ações")
                            .accessibilityLabel("Mais ações")
                        }
                        if !member.systemGoal.isEmpty {
                            Text(member.systemGoal)
                                .font(Typography.text)
                                .foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            if !member.model.isEmpty { TeamPill(text: member.model, tint: Palette.faint) }
                            TeamPill(text: team.permissionMode.label,
                                     tint: team.permissionMode == .bypass ? Palette.warn : Palette.faint)
                            if member.id == team.orchestratorID {
                                TeamPill(text: "Líder do time", tint: Palette.accentText)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    if !assignedStages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Etapas atribuídas")
                                .font(Typography.label.weight(.medium))
                                .foregroundStyle(Palette.faint)
                            ForEach(assignedStages) { stage in
                                MissionStageRow(
                                    stage: stage,
                                    ownerName: stage.ownerMemberID.flatMap { team.member(id: $0)?.name },
                                    reviewerName: stage.reviewerMemberID.flatMap { team.member(id: $0)?.name },
                                    reduceMotion: reduceMotion
                                )
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Registro de atividade")
                            .font(Typography.label.weight(.medium))
                            .foregroundStyle(Palette.faint)
                        if recentAudit.isEmpty {
                            Text("Nenhuma ação registrada ainda para este integrante.")
                                .font(Typography.label)
                                .foregroundStyle(Palette.faint)
                        } else {
                            ForEach(recentAudit) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary)
                                        .font(Typography.label.weight(.medium))
                                        .foregroundStyle(Palette.ink)
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(Typography.codeSmall)
                                            .foregroundStyle(Palette.faint)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Palette.canvas)
            .task(id: team.updatedAt) {
                let url = model.store.teamAuditURL(team.id)
                let id = member.id
                let entries = await Task.detached(priority: .utility) {
                    TeamAuditLog.readRecent(from: url, limit: 80).filter { $0.memberID == id }.suffix(15).reversed()
                }.value
                recentAudit = Array(entries)
            }
        }
    }

    private func stateColor(_ state: TeamMemberState) -> Color {
        switch state {
        case .working, .reviewing: Palette.accentText
        case .done: Palette.ok
        case .blocked: Palette.warn
        case .idle: Palette.faint
        }
    }
}
