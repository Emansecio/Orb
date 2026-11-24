import SwiftUI

/// Plain strings and status marks derived from `OrbTeam` for the sidebar wing (`Times`), keeping tests free of SwiftUI.
enum TeamRowText {
    static func subtitle(for team: OrbTeam) -> String {
        if let progress = team.mission.progress.stageSummary {
            return "\(team.status.label) · \(progress)"
        }
        let count = team.members.count
        let membersLabel = "\(count) \(count == 1 ? "integrante" : "integrantes")"
        return "\(team.status.label) · \(membersLabel)"
    }

    static func marker(for team: OrbTeam) -> SidebarMarker? {
        if team.status == .waitingUser { return nil }
        if team.unread > 0 { return .unread }
        return team.status.isWorking ? .working : nil
    }

    static func accessibilityLabel(for team: OrbTeam) -> String {
        var parts = [team.name, "time", team.status.label]
        if let progress = team.mission.progress.stageSummary { parts.append(progress) }
        if team.unread > 0 { parts.append("não lido") }
        return parts.joined(separator: ", ")
    }
}

/// Separate wing in the sidebar (`Times`) listing autonomous Teams generated from ideas and their exclusive members.
struct SidebarTeamsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectionSpace: Namespace.ID
    @State private var unfolded = true

    var body: some View {
        let holdsSelection = !unfolded && model.selectedTeamID != nil
        let needsAttention = model.teams.contains { $0.status == .waitingUser }
        let anyUnread = model.teams.contains { $0.unread > 0 }
        let anyWorking = model.teams.contains { $0.status.isWorking }
        VStack(alignment: .leading, spacing: 1) {
            TeamsWingHeader(unfolded: unfolded, holdsSelection: holdsSelection, needsAttention: needsAttention,
                            anyUnread: anyUnread, anyWorking: anyWorking, teamCount: model.teams.count,
                            selectionSpace: selectionSpace) {
                withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { unfolded.toggle() }
            } create: {
                model.showNewTeam = true
            }
            if unfolded {
                if model.teams.isEmpty {
                    SidebarRow(isSelected: false, selectionSpace: selectionSpace, isDashed: true,
                               help: "Crie um Time a partir de uma ideia") {
                        model.showNewTeam = true
                    } content: { _ in
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(SectionPlus.glyph)
                                .foregroundStyle(Palette.muted)
                            Text("Criar Time a partir de uma ideia")
                                .font(Typography.label)
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: SidebarCategoryLayout.headerContentHeight, alignment: .leading)
                    }
                    .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                }
                ForEach(model.teams) { team in
                    SidebarTeamRow(team: team, selectionSpace: selectionSpace)
                        .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                }
            }
        }
        .animateChanges(of: model.teams.map(\.id))
        .animateChanges(of: model.expandedTeamIDs)
    }
}

private struct TeamsWingHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let unfolded: Bool
    let holdsSelection: Bool
    let needsAttention: Bool
    let anyUnread: Bool
    let anyWorking: Bool
    let teamCount: Int
    let selectionSpace: Namespace.ID
    let toggle: () -> Void
    let create: () -> Void

    var body: some View {
        let collapsed = !unfolded
        HStack(spacing: 0) {
            SidebarRow(isSelected: holdsSelection, selectionSpace: selectionSpace,
                       help: collapsed ? "Mostra os Times" : "Recolhe os Times") {
                toggle()
            } content: { _ in
                HStack(spacing: 4) {
                    Text("Times")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(collapsed && holdsSelection ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(SectionPlus.chevron)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: collapsed)
                        .foregroundStyle(Palette.faint)
                    Spacer(minLength: 4)
                    if collapsed && teamCount > 0 {
                        CollapsedTeamsMarks(needsAttention: needsAttention, anyUnread: anyUnread, anyWorking: anyWorking, count: teamCount)
                    }
                }
                .frame(minHeight: SidebarCategoryLayout.headerContentHeight)
            }
            Button { create() } label: { SectionPlus() }
                .buttonStyle(.plain)
                .help("Novo time a partir de uma ideia")
                .accessibilityLabel("Novo time")
                .accessibilityIdentifier("sidebar-new-team")
                .padding(.trailing, 2)
        }
    }
}

private struct CollapsedTeamsMarks: View {
    let needsAttention: Bool
    let anyUnread: Bool
    let anyWorking: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            if needsAttention {
                Circle().fill(Palette.warn).frame(width: 6, height: 6)
            } else if anyUnread {
                Circle().fill(Palette.accentText).frame(width: 6, height: 6)
            } else if anyWorking {
                WorkingRing()
            }
            Text("\(count)")
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
        }
    }
}

/// One Team row with its stacked avatars, live progress subtitle, disclosure toggle, and expandable exclusive members.
struct SidebarTeamRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let team: OrbTeam
    let selectionSpace: Namespace.ID
    @State private var isHovering = false
    @State private var isConfirmingDelete = false

    var body: some View {
        let isSelected = model.selection == .team(team.id)
        let isExpanded = model.isTeamExpanded(team.id)
        let holdsMember = !isExpanded && team.members.contains { model.selection == .teamMember(teamID: team.id, memberID: $0.id) }
        let highlighted = isSelected || holdsMember
        let subtitle = TeamRowText.subtitle(for: team)
        let marker = TeamRowText.marker(for: team)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Button {
                    model.selection = .team(team.id)
                    if !model.isTeamExpanded(team.id) {
                        withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) {
                            model.setTeamExpanded(team.id, expanded: true)
                        }
                    }
                } label: {
                    HStack(spacing: SidebarGroupRow.stackGap) {
                        StackedAvatars(members: team.members.map {
                            StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: $0.state.orbActivity)
                        }, size: SidebarGroupRow.stackSize, overlap: SidebarGroupRow.stackOverlap)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name)
                                .font(Typography.text.weight(.medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(Typography.small)
                                .foregroundStyle(team.status == .waitingUser ? Palette.warn : Palette.faint)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                                .help("\(team.name) — \(subtitle)")
                        }
                        .frame(minHeight: 32, alignment: .leading)
                        Spacer(minLength: 4)
                        TeamRowStatusMark(marker: marker, completed: team.status == .completed)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) {
                        model.toggleTeamExpanded(team.id)
                    }
                } label: {
                    FoldChevron(isOpen: isExpanded, size: 9)
                        .frame(width: 20, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Recolher integrantes" : "Mostrar integrantes")
                .accessibilityLabel(isExpanded ? "Recolher integrantes de \(team.name)" : "Mostrar integrantes de \(team.name)")
                .padding(.trailing, 4)
            }
            .hoverFill(isHovering && !highlighted, in: .rect(cornerRadius: Radius.medium))
            .background {
                if highlighted { SlidingSelectionFill(space: selectionSpace, radius: Radius.medium) }
            }
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Abrir o time", systemImage: "person.3") { model.selection = .team(team.id) }
                Button(isExpanded ? "Recolher integrantes" : "Mostrar integrantes",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) {
                        model.toggleTeamExpanded(team.id)
                    }
                }
                Divider()
                Button("Apagar time…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            }
            .confirmationDialog("Apagar o time “\(team.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Apagar time", role: .destructive) {
                    withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                        model.deleteTeam(team.id)
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Todos os \(team.members.count) integrantes e os arquivos do time serão removidos juntos.")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TeamRowText.accessibilityLabel(for: team))
            .accessibilityAddTraits(highlighted ? .isSelected : [])

            if isExpanded {
                TeamMembersSublist(team: team, selectionSpace: selectionSpace)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
    }
}

private struct TeamRowStatusMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let marker: SidebarMarker?
    let completed: Bool

    var body: some View {
        ZStack {
            if let marker {
                switch marker {
                case .working:
                    WorkingRing()
                        .transition(.adapted(.mark, reduceMotion: reduceMotion))
                case .unread:
                    Circle()
                        .fill(Palette.accentText)
                        .frame(width: 8, height: 8)
                        .transition(.adapted(.mark, reduceMotion: reduceMotion))
                }
            } else if completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ok)
                    .transition(.adapted(.mark, reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: marker)
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: completed)
    }
}

private struct TeamMembersSublist: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let team: OrbTeam
    let selectionSpace: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(Palette.line)
                .frame(width: 1)
                .padding(.leading, 16)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(team.members.enumerated()), id: \.element.id) { index, member in
                    SidebarTeamMemberRow(team: team, member: member, isOrchestrator: member.id == team.orchestratorID,
                                         selectionSpace: selectionSpace)
                        .animation(reduceMotion ? nil : Motion.enter.delay(Motion.staggerDelay(index)), value: team.members.count)
                }
            }
        }
    }
}

private struct SidebarTeamMemberRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let team: OrbTeam
    let member: TeamMember
    let isOrchestrator: Bool
    let selectionSpace: Namespace.ID
    @State private var isHovering = false

    var body: some View {
        let isSelected = model.selection == .teamMember(teamID: team.id, memberID: member.id)
        let activity = member.state.orbActivity
        Button {
            model.selection = .teamMember(teamID: team.id, memberID: member.id)
        } label: {
            HStack(spacing: 8) {
                SettlingOrb(idle: activity == .idle, wake: isSelected ? 1 : 0) { paused in
                    BotAvatar(orb: member.orb, size: 22, activity: activity, paused: paused)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(member.name)
                            .font(Typography.label.weight(.medium))
                            .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
                            .lineLimit(1)
                        if isOrchestrator {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Palette.faint)
                                .help("Líder do time")
                        }
                    }
                    Text(member.role.isEmpty ? member.state.label : member.role)
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .help("\(member.name)\(member.role.isEmpty ? "" : " — \(member.role)")")
                }
                Spacer(minLength: 4)
                MemberStateIndicator(state: member.state, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: Radius.medium))
            .background {
                if isSelected { SlidingSelectionFill(space: selectionSpace, radius: Radius.medium) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Abrir integrante", systemImage: "bubble.left.and.text.bubble.right") {
                model.selection = .teamMember(teamID: team.id, memberID: member.id)
            }
            Button("Promover para meus Orbs", systemImage: "arrow.up.forward.app") {
                model.promoteMemberToOrb(teamID: team.id, memberID: member.id, select: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(member.name), \(member.role.isEmpty ? "integrante" : member.role), \(member.state.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MemberStateIndicator: View {
    let state: TeamMemberState
    let reduceMotion: Bool

    var body: some View {
        switch state {
        case .working, .reviewing:
            WorkingRing()
                .transition(.adapted(.mark, reduceMotion: reduceMotion))
        case .done:
            Circle()
                .fill(Palette.ok)
                .frame(width: 6, height: 6)
                .transition(.adapted(.mark, reduceMotion: reduceMotion))
        case .blocked:
            Circle()
                .fill(Palette.warn)
                .frame(width: 6, height: 6)
                .transition(.adapted(.mark, reduceMotion: reduceMotion))
        case .idle:
            EmptyView()
        }
    }
}
