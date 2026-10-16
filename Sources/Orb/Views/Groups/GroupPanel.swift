import SwiftUI

/// The panel of a group (the inspector column, as the Orb's panel is): Membros, Quadro and Ajustes.
struct GroupPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groupID: UUID
    @State private var tab = GroupPanelTab.members

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
                        GroupSettingsTab(group: group)
                    }
                }
                .id(tab)
                .transition(.pageSwap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .motion(Motion.adapted(Motion.crossFade, reduceMotion: reduceMotion), value: tab)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.chrome)
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
                .help(looks.count >= OrbGroup.memberLimits.upperBound ? "Um grupo tem até 8 Orbs" : "Põe mais um Orb neste grupo")
                .padding(.top, 8)
                // The "+" lines up with the avatars above (the rows' own 8 pt), not with the button's hover shape.
                .padding(.leading, Spacing.s - Spacing.ghostInset)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
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
            if isOrchestrator {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warn)
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

    var body: some View {
        let preset = GroupBudgetPreset.matching(group.budget)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                field("Nome") {
                    TextField("Nome do grupo", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Palette.surface, in: .rect(cornerRadius: 8))
                        .onSubmit { commitName() }
                }
                field("Orçamento por pedido") {
                    let choice = Binding(get: { preset ?? .balanced }, set: { model.setGroupBudget($0.budget, of: group.id) })
                    // Four segments need the panel wider than its narrowest: there, the same choice is a menu.
                    ViewThatFits(in: .horizontal) {
                        budgetPicker(choice).pickerStyle(.segmented)
                        budgetPicker(choice).pickerStyle(.menu)
                    }
                    Stepper(value: Binding(get: { group.budget.maxTurns }, set: { setBudget(turns: $0) }), in: 2...60, step: 2) {
                        Text("Turnos: \(group.budget.maxTurns)").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    Stepper(value: Binding(get: { group.budget.maxTokens }, set: { setBudget(tokens: $0) }),
                            in: 20_000...2_000_000, step: 10_000) {
                        Text("Tokens: \(GroupBudgetText.thousands(group.budget.maxTokens))")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    Text("Quando um pedido chega ao limite, o grupo pausa e pergunta se deve continuar. O que já estava rodando termina, então o total pode passar um pouco do limite.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                field("Conversa") {
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
                    .confirmationDialog("Apagar o grupo \(group.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button("Apagar grupo", role: .destructive) { delete() }
                    } message: {
                        Text("A conversa do grupo e o quadro saem com ele. Os Orbs continuam como estavam.")
                    }
            }
            .padding(16)
        }
        .onAppear { nameDraft = group.name }
        .onChange(of: group.name) { nameDraft = group.name }
    }

    private func budgetPicker(_ choice: Binding<GroupBudgetPreset>) -> some View {
        Picker("Orçamento", selection: choice) {
            ForEach(GroupBudgetPreset.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != group.name else { nameDraft = group.name; return }
        model.renameGroup(group.id, to: name)
    }

    private func setBudget(turns: Int? = nil, tokens: Int? = nil) {
        model.setGroupBudget(GroupBudget(maxTurns: turns ?? group.budget.maxTurns, maxTokens: tokens ?? group.budget.maxTokens),
                             of: group.id)
    }

    private func delete() {
        model.deleteGroup(group.id)
        model.selection = model.botIDs.first.map { .bot($0) }
    }
}
