import SwiftUI

/// The panel of a group (the inspector column, as the Orb's panel is): Membros, Quadro and Ajustes.
struct GroupPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groupID: UUID
    @State private var tab = GroupPanelTab.members
    /// "Renomear…" in the sidebar asked for the name field: the Ajustes tab takes it once it is on screen.
    @State private var isFocusingName = false

    var body: some View {
        if let group = model.groups.first(where: { $0.id == groupID }) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Seção do painel do grupo", selection: $tab) {
                    ForEach(GroupPanelTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                ZStack {
                    switch tab {
                    case .members:
                        GroupMembersTab(group: group)
                    case .board:
                        GroupBoardTab(groupID: group.id)
                    case .settings:
                        GroupSettingsTab(group: group, focusName: $isFocusingName)
                    }
                }
                .id(tab)
                .transition(.pageSwap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .motion(Motion.adapted(Motion.crossFade, reduceMotion: reduceMotion), value: tab)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.chrome)
            .onAppear { takeRequests() }
            .onChange(of: model.pendingChatRequest) { takeRequests() }
        }
    }

    private func takeRequests() {
        if model.takeChatRequest(.renameGroup, of: groupID) {
            tab = .settings
            isFocusingName = true
        }
    }
}

/// The tabs of the group panel.
enum GroupPanelTab: String, CaseIterable, Identifiable {
    case members, board, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .members: "Membros"
        case .board: "Quadro"
        case .settings: "Ajustes"
        }
    }
}

// MARK: - Membros

private struct GroupMembersTab: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup

    var body: some View {
        let looks = model.groupLooks(group)
        let candidates = model.botIDs.filter { !group.memberIDs.contains($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ReadOnlyNotes(group: group)
                ForEach(looks, id: \.id) { look in
                    MemberRow(look: look, group: group, canRemove: looks.count > OrbGroup.memberLimits.lowerBound)
                }
                Menu {
                    ForEach(candidates, id: \.self) { id in
                        Button(model.live(id).look.name) { model.addMember(id, to: group.id) }
                    }
                } label: {
                    Label("Adicionar Orb", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(GhostStyle())
                .disabled(looks.count >= OrbGroup.memberLimits.upperBound || candidates.isEmpty)
                .help(looks.count >= OrbGroup.memberLimits.upperBound ? "Um grupo tem até 8 Orbs"
                      : candidates.isEmpty ? "Todos os seus Orbs já estão neste grupo" : "Põe mais um Orb neste grupo")
                .padding(.top, 8)
                // The "+" lines up with the avatars above (the rows' own 8 pt), not with the button's hover shape.
                .padding(.leading, Spacing.s - Spacing.ghostInset)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
    }
}

/// Who in the group is in Só leitura and what that keeps them from doing; an orchestrator in it can be swapped from here.
private struct ReadOnlyNotes: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup

    var body: some View {
        let lines = model.readOnlyNotes(members: group.memberIDs, orchestrator: group.orchestratorID)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.text) { line in
                    Label(line.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warn)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if line.isOrchestrator {
                        Menu("Trocar orquestrador") {
                            ForEach(group.memberIDs.filter { $0 != group.orchestratorID }, id: \.self) { id in
                                Button(model.live(id).look.name) { model.setOrchestrator(id, of: group.id) }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(SecondaryPillStyle())
                        .controlSize(.small)
                        .fixedSize()
                        .help("Escolhe outro membro para receber os pedidos e distribuir o trabalho")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

private struct MemberRow: View {
    @Environment(AppModel.self) private var model
    let look: BotLook
    let group: OrbGroup
    let canRemove: Bool
    @State private var isHovering = false

    var body: some View {
        let isOrchestrator = look.id == group.orchestratorID
        HStack(spacing: 10) {
            // Avatar, name and role open the member's own chat; the icon buttons stay outside, as a button cannot hold a button.
            Button {
                model.selection = .bot(look.id)
            } label: {
                HStack(spacing: 10) {
                    BotAvatar(orb: look.orb, size: 30, animated: false)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(look.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(isOrchestrator ? "Orquestrador" : (look.role.isEmpty ? "Membro" : look.role))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Abrir a conversa de \(look.name)")
            if isOrchestrator {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 26, height: 26) // as wide as the round buttons beside it, so the stars line up
                    .accessibilityLabel("Orquestrador")
            } else {
                Button("Tornar orquestrador", systemImage: "star") {
                    model.setOrchestrator(look.id, of: group.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(CircleGhostStyle(side: 26, fontSize: 12))
                .foregroundStyle(Palette.muted)
                .help("Tornar \(look.name) o orquestrador")
            }
            Button("Remover do grupo", systemImage: "minus.circle") {
                model.removeMember(look.id, from: group.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(CircleGhostStyle(side: 26, fontSize: 12))
            .foregroundStyle(Palette.muted)
            .disabled(!canRemove)
            .help(canRemove ? "Tira \(look.name) do grupo" : "Um grupo tem pelo menos 2 Orbs")
            .opacity(isHovering || !canRemove ? 1 : 0.55)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .hoverFill(isHovering, in: .rect(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Quadro

private struct GroupBoardTab: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID

    var body: some View {
        GroupBoardView(memory: model.groupBoard(groupID),
                       setObjective: { model.setGroupObjective(groupID, to: $0) },
                       remember: { model.rememberGroupAgreement(groupID, text: $0) },
                       forget: { model.forgetGroupNote($0, of: groupID) },
                       restore: { model.restoreGroupNote($0, of: groupID) })
            .id(model.groupBoard(groupID).identity) // the objective field starts from the board once it is read
            .task { await model.refreshGroupBoard(groupID) }
    }
}

// MARK: - Ajustes

private struct GroupSettingsTab: View {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    @State private var nameDraft = ""
    @State private var isConfirmingDelete = false
    @Binding var focusName: Bool
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TitledSection("Nome") {
                    TextField("Nome do grupo", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Palette.surface, in: .rect(cornerRadius: 8))
                        .focused($isNameFocused)
                        .onSubmit { commitName() }
                }
                TitledSection("Conversa") {
                    Toggle(isOn: Binding(
                        get: { group.policy.membersMayTalk },
                        set: { model.setGroupPolicy(GroupPolicy(membersMayTalk: $0), of: group.id) })) {
                        Text("Membros podem conversar entre si").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    Text("Desligado, os membros respondem só ao orquestrador e a você.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Button("Apagar grupo…", systemImage: "trash") { isConfirmingDelete = true }
                    .buttonStyle(GhostStyle(tint: Palette.danger))
                    .deleteGroupDialog(group, isPresented: $isConfirmingDelete)
            }
            .padding(16)
        }
        .onAppear { nameDraft = group.name }
        // A task, not an `onChange`: when the request also switched the tab, this view is new and `focusName` was set before it.
        .task(id: focusName) {
            guard focusName else { return }
            focusName = false
            isNameFocused = true
        }
        .onChange(of: group.name) { nameDraft = group.name }
        // Leaving the field (another tab, the panel closed, another group) keeps what was typed, as the Orb's inspector does.
        .onChange(of: isNameFocused) { old, new in if old && !new { commitName() } }
        .onDisappear { if GroupNameEdit.commit(draft: nameDraft, current: group.name) != nil { commitName() } }
    }

    private func commitName() {
        guard let name = GroupNameEdit.commit(draft: nameDraft, current: group.name) else { nameDraft = group.name; return }
        model.renameGroup(group.id, to: name)
    }
}

/// What the group's name field writes: the typed name, trimmed, when it is a new one (nil for an empty draft or the same name).
enum GroupNameEdit {
    static func commit(draft: String, current: String) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == current ? nil : name
    }
}

/// A small faint title over its content: a field of a group's panel or sheet, or a section of its board.
struct TitledSection<Content: View>: View {
    let title: String
    var isHeader = false
    @ViewBuilder let content: Content

    init(_ title: String, isHeader: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isHeader = isHeader
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .accessibilityAddTraits(isHeader ? .isHeader : [])
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
