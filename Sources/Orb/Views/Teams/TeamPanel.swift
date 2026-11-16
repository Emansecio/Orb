import SwiftUI

enum TeamPanelTab: String, CaseIterable, Identifiable {
    case mission, members, board, usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mission: "Missão"
        case .members: "Integrantes"
        case .board: "Quadro"
        case .usage: "Uso"
        }
    }
}

/// Right-hand inspector column for a selected Team (`Missão`, `Integrantes`, `Quadro`, `Uso`).
struct TeamPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let teamID: UUID
    @State private var tab = TeamPanelTab.mission

    var body: some View {
        VStack(spacing: 0) {
            Picker("Aba do time", selection: $tab) {
                ForEach(TeamPanelTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Palette.line)

            if let team = model.team(teamID) {
                ZStack {
                    switch tab {
                    case .mission:
                        TeamMissionInspectorTab(team: team)
                            .transition(.pageSwap)
                    case .members:
                        TeamMembersInspectorTab(team: team)
                            .transition(.pageSwap)
                    case .board:
                        TeamBoardInspectorTab(team: team)
                            .transition(.pageSwap)
                    case .usage:
                        TeamUsageInspectorTab(team: team)
                            .transition(.pageSwap)
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: tab)
            }
        }
        .background(Palette.chrome)
    }
}

private struct TeamMissionInspectorTab: View {
    @Environment(AppModel.self) private var model
    let team: OrbTeam
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TeamProgressCard(team: team)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Controles")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.faint)
                    HStack(spacing: 8) {
                        if team.status.isWorking {
                            Button("Pausar time") { model.pauseTeam(team.id) }
                                .buttonStyle(SecondaryPillStyle())
                                .controlSize(.small)
                        } else {
                            Button(team.status == .completed ? "Retomar" : "Iniciar") { model.startTeam(team.id) }
                                .buttonStyle(SecondaryPillStyle())
                                .controlSize(.small)
                        }
                        Spacer()
                        Menu {
                            Button("Apagar time…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .accessibilityHidden(true)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .buttonStyle(CircleGhostStyle(side: 26, fontSize: 12))
                        .fixedSize()
                        .iconTip(Tip.moreOptions(of: team.name))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(14)
        }
        .confirmationDialog("Apagar o time “\(team.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Apagar time", role: .destructive) { model.deleteTeam(team.id) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Todos os \(team.members.count) integrantes e os arquivos do time serão removidos juntos.")
        }
    }
}

private struct TeamMembersInspectorTab: View {
    @Environment(AppModel.self) private var model
    let team: OrbTeam

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(team.members) { member in
                    HStack(spacing: 10) {
                        Button {
                            model.selection = .teamMember(teamID: team.id, memberID: member.id)
                        } label: {
                            HStack(spacing: 10) {
                                BotAvatar(orb: member.orb, size: 26, activity: member.state.orbActivity)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name)
                                        .font(Typography.text.weight(.medium))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(member.role.isEmpty ? member.state.label : member.role)
                                        .font(Typography.small)
                                        .foregroundStyle(Palette.faint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button("Abrir integrante", systemImage: "person") {
                                model.selection = .teamMember(teamID: team.id, memberID: member.id)
                            }
                            Button("Promover para meus Orbs", systemImage: "arrow.up.forward.app") {
                                model.promoteMemberToOrb(teamID: team.id, memberID: member.id, select: true)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .accessibilityHidden(true)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .buttonStyle(CircleGhostStyle(side: 24, fontSize: 11))
                        .fixedSize()
                        .iconTip(Tip.moreOptions(of: member.name))
                    }
                    .padding(10)
                    .card(radius: Radius.medium, fill: Palette.surface)
                }
            }
            .padding(14)
        }
    }
}

private struct TeamBoardInspectorTab: View {
    @Environment(AppModel.self) private var model
    let team: OrbTeam
    @State private var boardBrief = ""
    @State private var auditEntries: [TeamAuditEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quadro vivo")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.faint)
                    Text(boardBrief.isEmpty ? "Nenhum registro salvo ainda." : boardBrief)
                        .font(Typography.small)
                        .foregroundStyle(Palette.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Auditoria recente")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.faint)
                    if auditEntries.isEmpty {
                        Text("Sem eventos gravados.")
                            .font(Typography.small)
                            .foregroundStyle(Palette.faint)
                    } else {
                        ForEach(auditEntries) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(entry.memberName): \(entry.summary)")
                                    .font(Typography.small.weight(.medium))
                                    .foregroundStyle(Palette.ink)
                                if !entry.commit.isEmpty {
                                    Text("Commit \(entry.commit)")
                                        .font(Typography.codeSmall)
                                        .foregroundStyle(Palette.faint)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(14)
        }
        .task(id: team.updatedAt) {
            let bank = model.memory.teamBank(for: team.id)
            boardBrief = await TeamBoard.brief(bank: bank, team: team, message: team.mission.objective)
            let auditURL = model.store.teamAuditURL(team.id)
            auditEntries = await Task.detached(priority: .utility) {
                Array(TeamAuditLog.readRecent(from: auditURL, limit: 15).reversed())
            }.value
        }
    }
}

private struct TeamUsageInspectorTab: View {
    @Environment(AppModel.self) private var model
    let team: OrbTeam
    @State private var requests = 0
    @State private var tokens = 0
    @State private var cost = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Consumo nos últimos 30 dias")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.faint)
                    HStack {
                        Text("Chamadas")
                            .font(Typography.label)
                            .foregroundStyle(Palette.secondary)
                        Spacer()
                        Text("\(requests)")
                            .font(Typography.text.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    HStack {
                        Text("Tokens")
                            .font(Typography.label)
                            .foregroundStyle(Palette.secondary)
                        Spacer()
                        Text(GroupUsageText.tokens(tokens))
                            .font(Typography.text.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    HStack {
                        Text("Custo estimado")
                            .font(Typography.label)
                            .foregroundStyle(Palette.secondary)
                        Spacer()
                        Text(String(format: "US$ %.4f", cost))
                            .font(Typography.text.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(14)
        }
        .task(id: team.updatedAt) {
            let now = Date.now
            let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            let read = await model.store.readUsage(from: start, to: now)
            let teamBuckets = read.buckets.filter { $0.key.orb == team.id }
            let report = UsageReport.make(buckets: teamBuckets, period: .month30, now: now,
                                          book: model.priceBook, orbNames: [team.id: team.name])
            requests = report.totalRequests
            tokens = report.totalTokens
            cost = report.totalCost
        }
    }
}
