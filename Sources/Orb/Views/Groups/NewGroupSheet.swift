import SwiftUI

/// What a new group starts with, as plain rules the tests read: how many Orbs, the suggested name, the budget presets.
enum NewGroupRules {
    static let limits = OrbGroup.memberLimits

    /// A group needs between two and eight Orbs.
    static func canCreate(selectedCount: Int) -> Bool { limits.contains(selectedCount) }

    /// One more Orb may be chosen.
    static func canSelectMore(selectedCount: Int) -> Bool { selectedCount < limits.upperBound }

    /// The name a group is suggested from the Orbs chosen, in the order chosen: "Atlas e Pesquisador", "Atlas, Pesquisador e
    /// Revisor", "Atlas e mais 3". Nothing until two Orbs are chosen (the field keeps its example).
    static func suggestedName(for looks: [BotLook]) -> String {
        let names = looks.map(\.name).filter { !$0.isEmpty }
        switch names.count {
        case ..<2: return ""
        case 2: return names.joined(separator: " e ")
        case 3: return names.dropLast().joined(separator: ", ") + " e " + names[2]
        default: return "\(names[0]) e mais \(names.count - 1)"
        }
    }

    /// The orchestrator when the chosen one is taken off: the first of those still chosen (nil with none).
    static func orchestrator(afterRemoving removed: UUID, current: UUID?, selected: [UUID]) -> UUID? {
        guard current == removed else { return current }
        return selected.first
    }

    /// The name the group is created with: what was written, else the suggestion, else "Grupo novo".
    static func name(written: String, suggested: String) -> String {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fallback = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Grupo novo" : fallback
    }
}

/// The budgets a group can start with (per request of the person): Econômico, Equilibrado, Amplo and Projeto (a request
/// that builds something from start to finish: as many turns and tokens as the panel's steppers go).
enum GroupBudgetPreset: String, CaseIterable, Identifiable {
    case economical, balanced, broad, project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .economical: "Econômico"
        case .balanced: "Equilibrado"
        case .broad: "Amplo"
        case .project: "Projeto"
        }
    }

    var budget: GroupBudget {
        switch self {
        case .economical: GroupBudget(maxTurns: 8, maxTokens: 100_000)
        case .balanced: GroupBudget(maxTurns: 12, maxTokens: 150_000)
        case .broad: GroupBudget(maxTurns: 24, maxTokens: 300_000)
        case .project: GroupBudget(maxTurns: 60, maxTokens: 2_000_000)
        }
    }

    /// The preset a budget is, when it is one of them.
    static func matching(_ budget: GroupBudget) -> GroupBudgetPreset? {
        allCases.first { $0.budget == budget }
    }
}

/// "Novo grupo": a name, the Orbs (two to eight, one of them the orchestrator), an objective and a budget. The Orbs scroll
/// above a fixed footer. Opened from the sidebar's "+", ⌥⌘G, the palette, or an Orb's menu ("Criar grupo com…", which starts
/// with that Orb as orchestrator).
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
    /// What the field shows: what the person wrote, or the suggestion until they write (their text is never replaced).
    private var nameShown: String { isNameEdited ? written : suggested }
    private var canCreate: Bool { NewGroupRules.canCreate(selectedCount: chosen.count) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                field("Nome") {
                    TextField("Ex.: Lançamento", text: Binding(get: { nameShown }, set: { written = $0; isNameEdited = true }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.surface, in: .rect(cornerRadius: 10))
                        .accessibilityLabel("Nome do grupo")
                }
                field("Orbs") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(looks, id: \.id) { look in
                            OrbChoiceCard(look: look, isChosen: chosen.contains(look.id),
                                          isOrchestrator: orchestrator == look.id,
                                          isEnabled: chosen.contains(look.id) || NewGroupRules.canSelectMore(selectedCount: chosen.count),
                                          starSpace: starSpace,
                                          toggle: { toggle(look.id) },
                                          makeOrchestrator: { makeOrchestrator(look.id) })
                        }
                    }
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
        // Taller than the default sheet: the grid, the objective and the budget fit without scrolling at the usual window size.
        .orbSheet("Novo grupo", subtitle: "O orquestrador recebe cada pedido e divide o trabalho.", size: .medium, maxHeight: 700) {
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
        guard let group = model.createGroup(name: NewGroupRules.name(written: nameShown, suggested: suggested), members: chosen,
                                            orchestrator: orchestrator, objective: objective, budget: preset.budget) else { return }
        model.selection = .group(group.id)
        dismiss()
    }
}

/// One Orb to choose, compact: the live 48 pt avatar, its name and role, a border in its color when chosen, a check at the
/// top right, and the orchestrator's star at the top left with the word "Orquestrador" under the role. The star is one view
/// that slides from card to card (matched geometry; under Reduce Motion it fades). A chosen Orb that is not the orchestrator
/// shows an empty star that makes it the orchestrator.
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
        ZStack(alignment: .topLeading) {
            Button(action: toggle) {
                VStack(spacing: 5) {
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
                    // Always one line, so the cards of a row keep the same height.
                    Text(isOrchestrator ? "Orquestrador" : " ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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

            // The star sits beside the button, not inside it: a button inside a button would take the other's taps.
            if isChosen {
                if isOrchestrator {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                        .frame(width: 22, height: 22)
                        .background(Palette.raised, in: .circle)
                        .modifier(StarSlide(space: starSpace, reduceMotion: reduceMotion))
                        .padding(6)
                        .accessibilityHidden(true)
                } else {
                    Button(action: makeOrchestrator) {
                        Image(systemName: "star")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 22, height: 22)
                            .background(Palette.raised, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Tornar \(look.name) o orquestrador")
                    .accessibilityLabel("Tornar \(look.name) orquestrador")
                }
            }
            if isChosen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.onInk, core)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
                    .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
