import SwiftUI

/// The plan of the task (`task_plan`) in the working line, while some step of it is open: a small ring that fills as
/// steps are done, "2/5" beside it, and a click shows the steps. A plan whose steps the model never marked (none done or
/// in progress) is an empty, dimmed ring that says "Plano", not "0/5": a count that never moves would say the work has
/// not begun while the Orb works. It reads the plan itself, so an update redraws the ring alone, in place.
struct TaskPlanRing: View {
    let transcript: OrbTranscript
    /// Whether the steps are open; the working line holds it, so VoiceOver can open them from the line's actions.
    @Binding var showsSteps: Bool
    @State private var isHovering = false

    var body: some View {
        if let plan = transcript.plan {
            let tended = Self.isTended(plan)
            Button { showsSteps.toggle() } label: {
                HStack(spacing: 5) {
                    ring(plan)
                    Text(tended ? "\(plan.doneCount)/\(plan.steps.count)" : "Plano")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(tended ? Palette.muted : Palette.faint)
                        .contentTransition(.numericText())
                }
                .padding(.leading, 4)
                .padding(.trailing, 7)
                .padding(.vertical, 2)
                .background(isHovering ? Palette.ghostSelected : Palette.ghostHover, in: .capsule)
                .opacity(tended ? 1 : 0.7)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { isHovering = $0 }
            .animation(Motion.hover(isHovering), value: isHovering)
            .animation(Motion.content, value: plan.doneCount)
            .clickablePointer()
            .help("Plano: " + Self.summary(plan))
            .popover(isPresented: $showsSteps, arrowEdge: .bottom) {
                TaskPlanSteps(plan: plan)
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
            }
            .accessibilityLabel("Plano, " + Self.summary(plan))
            .accessibilityHint("Mostra as etapas")
        }
    }

    /// The steps done, as a share of the circle, from the top; red when a step is blocked.
    private func ring(_ plan: TaskPlan) -> some View {
        let done = plan.steps.isEmpty ? 0 : Double(plan.doneCount) / Double(plan.steps.count)
        let blocked = plan.steps.contains { $0.state == .blocked }
        return ZStack {
            Circle().stroke(blocked ? Palette.danger.opacity(0.5) : Palette.hint, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: done)
                .stroke(Palette.accentText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    /// Whether the model marks the steps as it goes: one of them is done, in progress or blocked.
    nonisolated static func isTended(_ plan: TaskPlan) -> Bool {
        plan.steps.contains { $0.state != .pending }
    }

    /// "2 de 5 etapas · Próximo: rodar os testes": the next step the model set, else the step in progress (or the first open
    /// one). "5 etapas, nenhuma marcada" while the model has not marked any.
    nonisolated static func summary(_ plan: TaskPlan) -> String {
        let steps = plan.steps.count == 1 ? "etapa" : "etapas"
        let count = isTended(plan) ? "\(plan.doneCount) de \(plan.steps.count) \(steps)"
            : "\(plan.steps.count) \(steps), " + (plan.steps.count == 1 ? "não marcada" : "nenhuma marcada")
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

/// The goal and the steps of a plan, with the state of each: the popover of the ring and of the line of a finished plan.
struct TaskPlanSteps: View {
    let plan: TaskPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.goal)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
            ForEach(plan.steps.indices, id: \.self) { index in
                let step = plan.steps[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: TaskPlanRing.symbol(step.state))
                        .font(.system(size: 11))
                        .foregroundStyle(step.state == .blocked ? Palette.danger : step.state == .inProgress ? Palette.accentText : Palette.faint)
                        .frame(width: 14)
                        .accessibilityLabel(TaskPlanRing.stateName(step.state))
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
}

/// The ring of a plan left open when the turn ended, alone at the end of the chat, at the tool lines' edge.
struct IdlePlanRing: View {
    let transcript: OrbTranscript
    @State private var showsSteps = false

    var body: some View {
        TaskPlanRing(transcript: transcript, showsSteps: $showsSteps)
            .padding(.leading, gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
