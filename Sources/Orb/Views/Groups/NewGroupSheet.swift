import SwiftUI

/// What a new group starts with, as plain rules the tests read: how many Orbs, the suggested name, the budget presets.
enum NewGroupRules {
    static let limits = OrbGroup.memberLimits

    /// A group needs between two and eight Orbs.
    static func canCreate(selectedCount: Int) -> Bool { limits.contains(selectedCount) }

    /// One more Orb may be chosen.
    static func canSelectMore(selectedCount: Int) -> Bool { selectedCount < limits.upperBound }

    /// The name a group gets when the person has not written one: the first word of each Orb's role, two at most, joined
    /// ("Pesquisa e Revisa"); an Orb without a role counts by its name. "Grupo novo" when nothing is chosen.
    static func suggestedName(for looks: [BotLook]) -> String {
        let words = looks.prefix(2).map { look -> String in
            let role = look.role.split(separator: " ").first.map(String.init)
            return (role?.isEmpty == false ? role : look.name) ?? look.name
        }
        .filter { !$0.isEmpty }
        switch words.count {
        case 0: return "Grupo novo"
        case 1: return words[0]
        default: return words.joined(separator: " e ")
        }
    }

    /// The orchestrator when the chosen one is taken off: the first of those still chosen (nil with none).
    static func orchestrator(afterRemoving removed: UUID, current: UUID?, selected: [UUID]) -> UUID? {
        guard current == removed else { return current }
        return selected.first
    }

    /// The name the group is created with: what was written, or the suggestion.
    static func name(written: String, suggested: String) -> String {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggested : trimmed
    }
}

/// The three budgets a group can start with (per request of the person): Econômico, Equilibrado and Amplo.
enum GroupBudgetPreset: String, CaseIterable, Identifiable {
    case economical, balanced, broad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .economical: "Econômico"
        case .balanced: "Equilibrado"
        case .broad: "Amplo"
        }
    }

    var budget: GroupBudget {
        switch self {
        case .economical: GroupBudget(maxTurns: 8, maxTokens: 100_000)
        case .balanced: GroupBudget(maxTurns: 12, maxTokens: 150_000)
        case .broad: GroupBudget(maxTurns: 24, maxTokens: 300_000)
        }
    }

    /// The preset a budget is, when it is one of them.
    static func matching(_ budget: GroupBudget) -> GroupBudgetPreset? {
        allCases.first { $0.budget == budget }
    }
}

/// "Novo grupo": a name, the Orbs (two to eight, one of them the orchestrator), an objective and a budget. Opened from the
/// sidebar's "+", ⌥⌘G, the palette, or an Orb's menu ("Criar grupo com…", which starts with that Orb as orchestrator).
struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Orb the sheet starts with (as the orchestrator), when it was opened from an Orb.
    var startingWith: UUID?
    @State private var chosen: [UUID] = []
    @State private var orchestrator: UUID?
    @State private var written = ""
    @State private var isNameEdited = false
    @State private var objective = ""
    @State private var preset = GroupBudgetPreset.balanced
    @Namespace private var starSpace

    private var looks: [BotLook] { model.botIDs.map { model.live($0).look } }
    private var chosenLooks: [BotLook] { chosen.compactMap { id in looks.first { $0.id == id } } }
    private var suggested: String { NewGroupRules.suggestedName(for: chosenLooks) }
    private var nameShown: String { isNameEdited ? written : suggested }
    private var canCreate: Bool { NewGroupRules.canCreate(selectedCount: chosen.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    field("Nome") {
                        TextField(suggested, text: Binding(get: { nameShown }, set: { written = $0; isNameEdited = true }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.surface, in: .rect(cornerRadius: 10))
                            .accessibilityLabel("Nome do grupo")
                    }
                    field("Orbs") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                            ForEach(looks, id: \.id) { look in
                                OrbChoiceCard(look: look, isChosen: chosen.contains(look.id),
                                              isOrchestrator: orchestrator == look.id,
                                              isEnabled: chosen.contains(look.id) || NewGroupRules.canSelectMore(selectedCount: chosen.count),
                                              starSpace: starSpace,
                                              toggle: { toggle(look.id) },
                                              makeOrchestrator: { makeOrchestrator(look.id) })
                            }
                        }
                        Text("Escolha de 2 a 8 Orbs. O orquestrador recebe cada pedido e divide o trabalho.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                    }
                    field("Objetivo (opcional)") {
                        TextField("O que o grupo deve entregar", text: $objective, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(2...3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.surface, in: .rect(cornerRadius: 10))
                    }
                    field("Orçamento por pedido") {
                        Picker("Orçamento", selection: $preset) {
                            ForEach(GroupBudgetPreset.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("\(preset.budget.maxTurns) turnos · \(GroupBudgetText.thousands(preset.budget.maxTokens)) tokens por pedido. Ao chegar ao limite, o grupo pergunta se deve continuar.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .padding(20)
            }
            HStack(spacing: 10) {
                if !canCreate {
                    Text("Escolha pelo menos 2 Orbs")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Button("Cancelar") { dismiss() }
                    .buttonStyle(GhostStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Criar grupo", action: create)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .orbSheet("Novo grupo", subtitle: "Orbs que trabalham juntos num pedido, com um orquestrador", size: .medium) {
            EmptyView()
        }
        .onAppear(perform: start)
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

    private func start() {
        guard chosen.isEmpty, let startingWith, looks.contains(where: { $0.id == startingWith }) else { return }
        chosen = [startingWith]
        orchestrator = startingWith
    }

    private func toggle(_ id: UUID) {
        if chosen.contains(id) {
            let next = NewGroupRules.orchestrator(afterRemoving: id, current: orchestrator, selected: chosen.filter { $0 != id })
            chosen.removeAll { $0 == id }
            withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { orchestrator = next }
        } else if NewGroupRules.canSelectMore(selectedCount: chosen.count) {
            chosen.append(id)
            if orchestrator == nil { orchestrator = id }
            model.live(id).glanced()
        }
    }

    private func makeOrchestrator(_ id: UUID) {
        guard chosen.contains(id) else { return }
        withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { orchestrator = id }
    }

    private func create() {
        guard canCreate, let orchestrator else { return }
        let group = model.createGroup(name: NewGroupRules.name(written: nameShown, suggested: suggested), memberIDs: chosen,
                                      orchestratorID: orchestrator, budget: preset.budget)
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { model.setGroupObjective(group.id, to: text) }
        model.selection = .group(group.id)
        dismiss()
    }
}

/// One Orb to choose: a live 48 pt avatar, its name and role, a border in its color when chosen, a check, and the star of the
/// orchestrator (one star, which slides to the chosen Orb when the role moves).
private struct OrbChoiceCard: View {
    let look: BotLook
    let isChosen: Bool
    let isOrchestrator: Bool
    let isEnabled: Bool
    let starSpace: Namespace.ID
    let toggle: () -> Void
    let makeOrchestrator: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let core = OrbColor.core(look.orb)
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: toggle) {
                    VStack(spacing: 6) {
                        BotAvatar(orb: look.orb, size: 48)
                            .frame(width: 48, height: 48)
                        Text(look.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(look.role.isEmpty ? " " : look.role)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 6)
                    .background(isChosen ? Palette.surface : Palette.chrome, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isChosen ? core : Palette.line, lineWidth: isChosen ? 2 : 1))
                    .opacity(isEnabled || isChosen ? 1 : 0.45)
                    .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled && !isChosen)
                .accessibilityLabel("\(look.name), \(look.role)")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
                .accessibilityValue(isOrchestrator ? "Orquestrador" : (isChosen ? "Escolhido" : ""))
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Palette.onInk, core)
                        .padding(6)
                        .transition(.adapted(.mark, reduceMotion: reduceMotion))
                        .allowsHitTesting(false)
                }
            }
            if isChosen {
                orchestratorStar
            } else {
                Color.clear.frame(height: 18)
            }
        }
    }

    @ViewBuilder private var orchestratorStar: some View {
        if isOrchestrator {
            Label("Orquestrador", systemImage: "star.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.warn)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.raised, in: .capsule)
                .modifier(StarSlide(space: starSpace, reduceMotion: reduceMotion))
        } else {
            Button(action: makeOrchestrator) {
                Label("Tornar orquestrador", systemImage: "star")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help("Tornar \(look.name) o orquestrador")
        }
    }
}

/// The orchestrator's star moves between the cards with a matched geometry; under Reduce Motion it only fades.
private struct StarSlide: ViewModifier {
    let space: Namespace.ID
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content.transition(.opacity)
        } else {
            content.matchedGeometryEffect(id: "orchestratorStar", in: space)
        }
    }
}
