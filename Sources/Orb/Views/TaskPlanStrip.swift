import SwiftUI

/// The plan of the task (`task_plan`) at the end of the chat, while some step of it is open: one quiet line
/// ("Plano  3 de 5 etapas · Próximo: …") that opens into the steps. It reads the plan itself, so an update redraws this
/// line alone, in place: the list does not animate for it (see the comment on the list's animations in `ChatView`),
/// only opening and closing the line does.
struct TaskPlanStrip: View {
    let transcript: OrbTranscript
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let plan = transcript.plan {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: ToolCall.Kind.plan.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .frame(width: 14)
                        (Text("Plano").foregroundColor(Palette.muted) + Text("  " + Self.summary(plan)).foregroundColor(Palette.faint))
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(reduceMotion ? nil : Motion.content, value: isExpanded)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Tip.togglePlan(isExpanded: isExpanded))
                .accessibilityLabel("Plano, " + Self.summary(plan))
                .accessibilityValue(isExpanded ? "expandido" : "recolhido")
                .accessibilityHint("Mostra as etapas")

                if isExpanded {
                    steps(plan)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: 10)
                        .transition(.adapted(.unfold, reduceMotion: reduceMotion))
                }
            }
            .padding(.leading, gutter)
        }
    }

    private func steps(_ plan: TaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.goal)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
            ForEach(plan.steps.indices, id: \.self) { index in
                let step = plan.steps[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(step.state))
                        .font(.system(size: 11))
                        .foregroundStyle(step.state == .blocked ? Palette.danger : step.state == .inProgress ? Palette.accentText : Palette.faint)
                        .frame(width: 14)
                        .accessibilityLabel(Self.stateName(step.state))
                    Text(step.text + (step.reason.map { " — " + $0 } ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(step.state == .done ? Palette.faint : Palette.secondary)
                }
            }
            if let next = plan.next {
                Text("Próximo: " + next)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
    }

    /// "3 de 5 etapas · Próximo: rodar os testes": the next step the model set, else the step in progress (or the first open one).
    nonisolated static func summary(_ plan: TaskPlan) -> String {
        let count = "\(plan.doneCount) de \(plan.steps.count) " + (plan.steps.count == 1 ? "etapa" : "etapas")
        guard let next = plan.next ?? plan.current?.text else { return count }
        return count + " · Próximo: " + next
    }

    nonisolated static func symbol(_ state: TaskPlan.State) -> String {
        switch state {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .done: "checkmark.circle"
        case .blocked: "exclamationmark.circle"
        }
    }

    nonisolated static func stateName(_ state: TaskPlan.State) -> String {
        switch state {
        case .pending: "Pendente"
        case .inProgress: "Em andamento"
        case .done: "Feita"
        case .blocked: "Bloqueada"
        }
    }
}
