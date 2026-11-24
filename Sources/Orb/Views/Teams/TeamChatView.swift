import SwiftUI

/// Main shared Mission workspace when a `Time` is selected: header with Pausar/Retomar, live Mission progress,
/// shared thread (`times/<teamID>/thread.json`), and composer to steer or reopen the Team.
struct TeamChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let teamID: UUID
    @State private var isConfirmingDelete = false

    var body: some View {
        if let team = model.team(teamID) {
            let items = model.teamThreadItems(for: team.id)
            VStack(spacing: 0) {
                TeamChatHeaderBar(team: team, requestDelete: { isConfirmingDelete = true })

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            TeamProgressCard(team: team)
                                .transition(.adapted(.arrive, reduceMotion: reduceMotion))

                            if items.isEmpty {
                                TeamThreadEmptyCard(team: team) {
                                    model.startTeam(team.id)
                                }
                            } else {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    Text("Fio da missão")
                                        .font(Typography.label.weight(.medium))
                                        .foregroundStyle(Palette.faint)
                                    ForEach(items) { item in
                                        TeamThreadItemRow(item: item)
                                            .transition(.adapted(.rise, reduceMotion: reduceMotion))
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("team-thread-bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onChange(of: items.count) {
                        withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("team-thread-bottom", anchor: .bottom)
                        }
                    }
                }

                TeamComposerBar(teamID: team.id)
            }
            .background(Palette.canvas)
            .onAppear { model.loadTeamThreadIfNeeded(team.id) }
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
        }
    }
}

private struct TeamChatHeaderBar: View {
    @Environment(AppModel.self) private var model
    let team: OrbTeam
    let requestDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StackedAvatars(members: team.members.map {
                StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: $0.state.orbActivity)
            }, size: 24, overlap: 9)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(team.name)
                        .font(Typography.text.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    TeamPill(text: team.status.label, tint: statusTint)
                }
                let folder = team.projectFolder.isEmpty ? "Espaço exclusivo do time" : team.projectFolder
                Text(folder)
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder)
            }

            Spacer(minLength: 8)

            if team.status.isWorking {
                Button("Pausar") { model.pauseTeam(team.id) }
                    .buttonStyle(SecondaryPillStyle())
                    .controlSize(.small)
            } else {
                Button(team.status == .completed ? "Retomar" : "Iniciar") { model.startTeam(team.id) }
                    .buttonStyle(SecondaryPillStyle())
                    .controlSize(.small)
            }

            Menu {
                Button("Apagar time…", systemImage: "trash", role: .destructive) { requestDelete() }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var statusTint: Color {
        switch team.status {
        case .preparing, .running: Palette.accentText
        case .completed: Palette.ok
        case .waitingUser: Palette.warn
        case .paused, .failed: Palette.faint
        }
    }
}

private struct TeamThreadEmptyCard: View {
    let team: OrbTeam
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(team.status.isWorking ? "Time trabalhando em segundo plano" : "Pronto para avançar")
                .font(Typography.text.weight(.medium))
                .foregroundStyle(Palette.ink)
            Text("As entregas aprovadas na revisão, verificações e marcos da missão aparecem neste fio compartilhado.")
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !team.status.isWorking {
                Button("Iniciar execução autônoma", action: start)
                    .chipButton()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct TeamThreadItemRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text, _):
            HStack {
                Spacer(minLength: TranscriptLayout.bubbleSpacer)
                Text(text)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(Palette.conversationLineSpacing)
                    .userBubble()
            }
        case .bot(let text, _):
            MarkdownChunk(source: text).equatable()
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineSpacing(Palette.conversationLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        case .notice(let text):
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                Text(text)
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
            }
            .padding(.vertical, 2)
        default:
            EmptyView()
        }
    }
}

private struct TeamComposerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let teamID: UUID
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private func send() {
        guard model.postTeamMessage(text, to: teamID) else { return }
        text = ""
    }

    var body: some View {
        let enabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Direcionar o time ou continuar a missão…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit { send() }

            SendArrowButton(canSend: enabled, help: "Enviar direcionamento ao time", action: send)
        }
        .padding(.horizontal, Spacing.m + Spacing.xs)
        .padding(.vertical, 10)
        .background {
            ComposerSurface(isFocused: isFocused, isDropTargeted: false, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, 24)
        .padding(.top, Spacing.xs + Spacing.hairline)
        .padding(.bottom, Spacing.m)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }
}
