import AppKit
import SwiftUI

// MARK: Routines

/// What the page can have open on top of it: one at a time, and one can hand over to the next (a run's report
/// "Ver conversa" opens the routine's conversation).
private enum RoutinesSheet: Identifiable {
    case edit(Routine)
    case conversation(UUID)
    case run(routine: UUID, run: UUID)

    var id: String {
        switch self {
        case .edit(let routine): "edit-\(routine.id)"
        case .conversation(let id): "conversation-\(id)"
        case .run(_, let run): "run-\(run)"
        }
    }
}

struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: RoutinesSheet?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Empty and full cross-fade in a ZStack (§2.13), never side by side. A card that is born or goes away comes and
            // leaves like a routine in the Orb's panel (`arrive`: rises 6 pt, leaves by fading), the others slide, bound to
            // the ids, so a run or a clock tick moves nothing.
            ZStack(alignment: .top) {
                if model.routines.isEmpty {
                    RoutinesEmptyState(start: model.routineStart,
                                       onNew: { newRoutine(nil) },
                                       onTemplate: { newRoutine($0) })
                        .transition(.opacity)
                } else {
                    // One header per Orb, in the order of the sidebar, with that Orb's cards under it. Not sorted by next run:
                    // a run would make the cards jump. Each card gets its routine by value, plus a callback for the switch.
                    // With a single Orb the header would only repeat what every card shows.
                    let owners = model.bots.filter { bot in model.routines.contains { $0.botID == bot.id } }
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        ForEach(owners) { bot in
                            VStack(alignment: .leading, spacing: Spacing.m) {
                                if owners.count > 1 {
                                    // The Orb is named once, here: its cards start at the routine's name (`showsOrb`).
                                    Button { openOrb(bot.id) } label: {
                                        HStack(spacing: 8) {
                                            BotAvatar(orb: bot.orb, size: 22, animated: false)
                                            Text(bot.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(Palette.ink)
                                                .lineLimit(1)
                                        }
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(.isHeader)
                                    .help("Abrir \(bot.name) e suas rotinas")
                                }
                                // Up to 460 pt a card, so one routine does not stretch across the page; the cards keep their own
                                // height instead of matching the tallest of the row.
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: Spacing.cardSpacing, alignment: .top)],
                                          alignment: .leading, spacing: Spacing.cardSpacing) {
                                    ForEach(model.routines(for: bot.id)) { routine in
                                        RoutineCard(routine: routine, botName: bot.name, orb: bot.orb, showsOrb: owners.count == 1,
                                                    isRunning: model.isRoutineRunning(routine.id),
                                                    isQueued: model.isRoutineQueued(routine.id),
                                                    onToggle: { model.setRoutineEnabled(routine.id, $0) },
                                                    onRun: { model.runRoutine(routine.id, manual: true) },
                                                    onEdit: { sheet = .edit(routine) },
                                                    onOpen: { sheet = .conversation(routine.id) },
                                                    onOpenRun: { sheet = .run(routine: routine.id, run: $0) },
                                                    onOpenOrb: { openOrb(bot.id) },
                                                    onDelete: { model.deleteRoutine(routine.id) })
                                            .id(routine.id)
                                            .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                                    }
                                }
                            }
                        }
                    }
                    .animateChanges(of: model.routines.map { "\($0.id)\($0.botID)" })
                    .transition(.opacity)
                }
            }
            .motion(Motion.crossFade, value: model.routines.isEmpty)
            .pageColumn()
        }
        .onAppear { focusInicioRoutine(using: proxy) }
        .onChange(of: model.inicioRoutineFocus) { focusInicioRoutine(using: proxy) }
        }
        .background(Palette.canvas)
        .navigationTitle("Rotinas")
        .navigationSubtitle("Tarefas que seus Orbs fazem sozinhos enquanto o app está aberto")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Em branco", systemImage: "plus") { newRoutine(nil) }
                    Divider()
                    Section("Começar de um modelo") {
                        ForEach(RoutineTemplate.all) { template in
                            Button(template.title, systemImage: template.symbol) { newRoutine(template) }
                        }
                    }
                } label: {
                    Label("Nova rotina", systemImage: "plus")
                } primaryAction: {
                    newRoutine(nil)
                }
                .help(Tip.newRoutine(for: model.routineStart))
            }
        }
        .onAppear(perform: takeRequest)
        .onChange(of: model.routineToShow) { takeRequest() }
        .onChange(of: model.routineRunToShow) { takeRequest() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let routine):
                RoutineEditor(routine: routine)
            case .conversation(let id):
                RoutineConversationSheet(routineID: id)
            case .run(let routineID, let runID):
                RoutineRunSheet(routineID: routineID, runID: runID,
                                onConversation: { self.sheet = .conversation(routineID) })
            }
        }
    }

    /// The Orb that owns a routine, with its panel on the routines tab.
    private func openOrb(_ id: UUID) {
        model.setInspector(true)
        model.request(.showTab(.routines), of: id)
    }

    private func focusInicioRoutine(using proxy: ScrollViewProxy) {
        guard let id = model.inicioRoutineFocus else { return }
        model.inicioRoutineFocus = nil
        guard model.routines.contains(where: { $0.id == id }) else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func newRoutine(_ template: RoutineTemplate?) {
        // With no Orb the Atlas is made first, or the welcome screen asks for a model (no draft then).
        Task {
            if let draft = await model.beginRoutine(from: template) { sheet = .edit(draft) }
        }
    }

    /// A routine waiting for an answer was asked for ("Ver pedido", its banner): its conversation opens.
    private func takeRequest() {
        if let target = model.routineRunToShow {
            model.routineRunToShow = nil
            sheet = .run(routine: target.routineID, run: target.runID)
            return
        }
        guard let id = model.routineToShow else { return }
        model.routineToShow = nil
        sheet = .conversation(id)
    }
}

// MARK: Empty state

/// Nothing yet: what a routine is, one button, and the templates to start from.
private struct RoutinesEmptyState: View {
    let start: RoutineStart
    let onNew: () -> Void
    let onTemplate: (RoutineTemplate) -> Void

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.faint)
                    .accessibilityHidden(true)
                Text("Nenhuma rotina ainda")
                    .font(Typography.title)
                    .accessibilityAddTraits(.isHeader)
                Text("Uma rotina é uma tarefa que um Orb faz sozinho, no horário. O app precisa estar aberto.")
                    .font(Typography.text)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Nova rotina", systemImage: "plus", action: onNew)
                .buttonStyle(PrimaryPillStyle())
                .help(Tip.newRoutine(for: start))
            if let caption = start.caption {
                Text(caption)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
            }
            VStack(spacing: Spacing.m) {
                Text("Ou comece por um modelo")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.m) { templateCards(width: 176) }
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: Spacing.m) { templateCards(width: nil) }
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: 760)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder private func templateCards(width: CGFloat?) -> some View {
        ForEach(RoutineTemplate.all) { template in
            TemplateCard(template: template, start: start) { onTemplate(template) }
                .frame(width: width)
        }
    }
}

private struct TemplateCard: View {
    let template: RoutineTemplate
    let start: RoutineStart
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: template.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 20, height: 18, alignment: .leading)
                    .accessibilityHidden(true)
                Text(template.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 6) {
                    Text(template.whenText)
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.secondary)
                    if template.goal != nil { CatalogBadge(text: "Com meta", symbol: "target") }
                }
                // A short description that always ends in a full stop; the whole prompt is the tooltip.
                Text(template.blurb)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Spacing.catalogCardPadding)
            .hoverCard(isHovering, radius: Radius.card)
            .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .help("\(template.prompt)\n\n\(Tip.routineTemplate(for: start))") // the card cuts a long prompt; the tooltip has it whole
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(template.title), \(template.whenText)\(template.goal == nil ? "" : ", com meta")")
        .accessibilityHint(start.templateHint)
    }
}

// MARK: Card

private struct RoutineCard: View {
    @Environment(AppModel.self) private var model
    let routine: Routine
    /// The Orb that owns it: its name and avatar, not the whole `Bot`.
    let botName: String
    let orb: OrbConfig
    /// The card names its Orb (avatar and name) only when the page has no section header for it, which is when one Orb owns
    /// every routine: otherwise the header says it once for all its cards.
    let showsOrb: Bool
    /// This routine is running now / is waiting for its Orb to be free.
    let isRunning: Bool
    let isQueued: Bool
    /// The switch (the model refuses to turn on a routine whose date has passed).
    let onToggle: (Bool) -> Void
    let onRun: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onOpenRun: (UUID) -> Void
    /// Opens the Orb that owns the routine, with its panel on the routines tab.
    let onOpenOrb: () -> Void
    let onDelete: () -> Void
    @State private var isConfirmingDelete = false
    @State private var showsAllFollowUps = false

    /// The last run failed: said in the header, not only in the line at the bottom.
    private var lastRunFailed: Bool { routine.runs.first?.succeeded == false }
    /// A paused routine dims only its name and its Orb; the badge and the switch that bring it back stay at full contrast.
    private var dimming: Double { routine.isEnabled ? 1 : 0.6 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            let datePassed = !routine.canBeEnabled()
            // The label is hidden but read by VoiceOver: it names the routine, since every card has the same switch.
            let toggle = Toggle("Ativar \(routine.name)", isOn: Binding(get: { routine.isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(datePassed)
                .help(datePassed ? Tip.routineDatePassed : Tip.routineToggle(isOn: routine.isEnabled))
            let modeBadge = routine.permissionMode.map { mode in
                CatalogBadge(text: mode.label, symbol: mode.symbol)
                    .help("Esta rotina roda em “\(mode.label)”, mesmo que o Orb use outro modo")
            }
            if showsOrb {
                HStack(spacing: 8) {
                    Button(action: onOpenOrb) {
                        HStack(spacing: 8) {
                            BotAvatar(orb: orb, size: 30, activity: routine.isEnabled ? .idle : .sleepy, animated: false)
                            Text(botName)
                                .font(Typography.text.weight(.semibold))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                        .opacity(dimming)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Abrir \(botName) e suas rotinas")
                    modeBadge
                    Spacer()
                    toggle
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(routine.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .opacity(dimming)
                if lastRunFailed {
                    CatalogBadge(text: "Falhou", symbol: "exclamationmark.triangle.fill", tint: Palette.danger)
                        .fixedSize()
                }
                if !showsOrb {
                    // Under the Orb's section header the card starts here: the routine's name, the switch at its end.
                    modeBadge
                    Spacer(minLength: 8)
                    toggle
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(routine.schedule.plainLabel, systemImage: "clock")
                    .font(Typography.label)
                if let mismatch = RoutineText.nameMismatch(of: routine) {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.small)
                        .foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NextRunLine(routine: routine)
            }
            if let goal = routine.goal { GoalProgressView(goal: goal) }
            let openFollowUps = routine.followUps.filter { !$0.resolved }
            if !openFollowUps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    // A section label, not a heading: the routine's name above is what the card is about.
                    Text("Acompanhamentos em aberto")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.secondary)
                    ForEach(RoutineText.visibleFollowUps(openFollowUps, showsAll: showsAllFollowUps)) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.subject).font(Typography.label.weight(.medium))
                                Text("\(item.channel) · \(item.nextStep)")
                                    .font(Typography.small).foregroundStyle(Palette.muted)
                                    .lineLimit(2)
                                    .help(item.nextStep)
                                if let checked = item.lastChecked {
                                    Text("Verificado \(RoutineText.stamp(checked))").font(Typography.small).foregroundStyle(Palette.faint)
                                }
                            }
                            Spacer()
                            Button("Concluir", systemImage: "checkmark.circle") {
                                guard let r = model.routines.firstIndex(where: { $0.id == routine.id }),
                                      let i = model.routines[r].followUps.firstIndex(where: { $0.id == item.id }) else { return }
                                model.routines[r].followUps[i].resolved = true
                                model.routines[r].followUps[i].updatedAt = .now
                            }
                            .buttonStyle(GhostStyle())
                            .accessibilityLabel("Concluir acompanhamento: \(item.subject)")
                        }
                    }
                    if openFollowUps.count > RoutineText.followUpsShown {
                        Button(showsAllFollowUps ? "Ver menos" : "Ver todos (\(openFollowUps.count))") { showsAllFollowUps.toggle() }
                            .buttonStyle(LinkTextStyle())
                    }
                }
            }
            Divider()
            if routine.runs.isEmpty {
                Text(routine.lastResult ?? "Ainda não rodou.")
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
            } else {
                RunHistory(runs: routine.runs, onOpen: onOpenRun)
            }
            // The same buttons as the routine's card in the Orb's panel: ghosts for what opens something, a pill for the run.
            HStack(spacing: Spacing.xs + Spacing.hairline) {
                Button("Editar", systemImage: "pencil", action: onEdit)
                    .buttonStyle(GhostStyle())
                    .help(Tip.editRoutine)
                    .hangsOnLeadingEdge()
                Button("Ver conversa", systemImage: "text.bubble", action: onOpen)
                    .buttonStyle(GhostStyle())
                    .help(Tip.routineConversation)
                MoreMenu(name: routine.name, tip: "Mais ações: editar ou apagar a rotina") {
                    Button("Editar rotina…", systemImage: "pencil", action: onEdit)
                        .help(Tip.editRoutine)
                    Divider()
                    Button("Apagar rotina…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .help(Tip.deleteRoutine)
                }
                Spacer()
                RoutineRunControl(state: RoutineRunState(isRunning: isRunning, isQueued: isQueued), alignment: .trailing,
                                  run: onRun)
            }
            .controlSize(.small)
        }
        .padding(Spacing.cardPadding)
        .card(radius: Radius.large)
        .animateChanges(of: routine.isEnabled)
        .animateChanges(of: lastRunFailed)
        .confirmationDialog("Apagar “\(RoutineText.resolvedName(routine.name, prompt: routine.prompt))”?",
                            isPresented: $isConfirmingDelete) {
            Button("Apagar rotina", role: .destructive, action: onDelete)
        } message: {
            Text("A rotina e o histórico dela serão apagados. Não dá para desfazer.")
        }
    }
}

/// Which of "Rodar agora", "Rodando…" and "Na fila" a routine's card shows.
struct RoutineRunState: Equatable {
    let isRunning: Bool
    let isQueued: Bool
}

/// "Rodar agora", "Rodando…" and "Na fila", on the Rotinas page and in the Orb's panel. They swap in place, one over the
/// other, cross-fading, for the card not to shift while they trade places.
struct RoutineRunControl: View {
    let state: RoutineRunState
    var alignment: Alignment = .leading
    let run: () -> Void

    var body: some View {
        ZStack(alignment: alignment) {
            if state.isRunning {
                Label("Rodando…", systemImage: "hourglass").foregroundStyle(Palette.muted)
                    .transition(.opacity)
            } else if state.isQueued {
                Label("Na fila", systemImage: "clock").foregroundStyle(Palette.muted)
                    .help(Tip.queuedRoutine)
                    .transition(.opacity)
            } else {
                Button("Rodar agora", systemImage: "play", action: run)
                    .buttonStyle(SecondaryPillStyle())
                    .help(Tip.runRoutineNow)
                    .transition(.opacity)
            }
        }
        .font(Typography.label)
        .animateChanges(of: state)
    }
}

/// "Próxima: hoje às 09:00 · em 3 h", kept right as the minutes pass; "Concluída" once a one-time routine ran; "Pausada" when it is switched off.
struct NextRunLine: View {
    let routine: Routine

    var body: some View {
        if routine.isEnabled {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(RoutineText.nextRun(of: routine, now: context.date) ?? "")
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
            }
        } else if RoutineText.isConcluded(routine) {
            Label("Concluída", systemImage: "checkmark.circle")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
        } else {
            Label("Pausada", systemImage: "pause.circle")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
        }
    }
}

/// A routine's goal at a glance: what it is after, how far the last check put it (a thin bar in the status's color)
/// and that check's note; an orange flag when it needs attention. Also in the Orb's panel, with its type size and
/// without the note (the last run's line right under it says much the same).
struct GoalProgressView: View {
    let goal: RoutineGoal
    var font: Font = Typography.small
    var showsNote = true

    var body: some View {
        let check = goal.check
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: check?.status.symbol ?? "target")
                    .foregroundStyle(check?.status.tint ?? Palette.faint)
                Text("Meta: \(goal.target)")
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(check?.label ?? "avaliada na 1ª rodada")
                    .monospacedDigit()
                    .foregroundStyle(check.map { $0.status == .onTrack ? Palette.accentText : $0.status.tint } ?? Palette.faint)
                    .fixedSize()
            }
            // No bar before the first check: an empty one reads as 0%.
            if let check { GoalBar(progress: check.progress, tint: check.status.tint) }
            if showsNote, let note = check?.note, !note.isEmpty {
                Text(note)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(font)
        .help(goal.target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goal.spokenSummary)
        .accessibilityValue(goal.target)
    }
}

/// The goal's 5 pt bar; it grows to a new check with the content curve (at once under Reduce Motion).
private struct GoalBar: View {
    let progress: Int
    let tint: Color

    var body: some View {
        Capsule()
            .fill(Palette.lineStrong)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: progress > 0 ? max(proxy.size.width * Double(progress) / 100, 5) : 0)
                }
            }
            .animateChanges(of: progress)
            .accessibilityHidden(true)
    }
}

extension GoalStatus {
    var tint: Color {
        switch self {
        case .onTrack: Palette.accent
        case .attention: Palette.warn
        case .done: Palette.ok
        }
    }

    var symbol: String {
        switch self {
        case .onTrack: "target"
        case .attention: "flag.fill"
        case .done: "checkmark.seal.fill"
        }
    }
}

/// The routine's recent runs, newest first: the latest in full, the others behind a disclosure. Each one opens its
/// report.
private struct RunHistory: View {
    let runs: [RoutineRun]
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let latest = runs.first {
                RunLine(run: latest, lineLimit: 3, showsMore: RoutineText.hasMore(latest)) { onOpen(latest.id) }
            }
            if runs.count > 1, let current = runs[0].openFollowUps, let previous = runs[1].openFollowUps,
               let line = RoutineText.sinceLastRun(added: Set(current).subtracting(previous).count,
                                                   completed: Set(previous).subtracting(current).count, open: current.count) {
                Text(line).font(Typography.small).foregroundStyle(Palette.muted)
            }
            if runs.count > 1 {
                DisclosureGroup("Execuções anteriores (\(runs.count - 1))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(runs.dropFirst()) { run in
                            RunLine(run: run, lineLimit: 1) { onOpen(run.id) }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct RunLine: View {
    let run: RoutineRun
    let lineLimit: Int
    /// The summary is cut or the report has more: said as a link-colored "Ver mais" (the whole line opens the report), as in
    /// the Orb's panel, so a cut summary does not read as broken.
    var showsMore = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: run.wasStopped ? "stop.circle.fill" : run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(run.wasStopped ? Palette.muted : run.succeeded ? Palette.ok : Palette.danger)
                    .font(Typography.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text([RoutineText.stamp(run.date), RoutineText.duration(of: run)].compactMap { $0 }.joined(separator: " · "))
                        .font(Typography.small)
                        .foregroundStyle(Palette.faint)
                    Text(run.summary)
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                    if showsMore {
                        Text("Ver mais")
                            .font(Typography.small)
                            .foregroundStyle(Palette.accentText)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 4)
                // A goal's runs read as its timeline: where each check put it.
                if let check = run.check {
                    HStack(spacing: 3) {
                        if check.status == .attention { Image(systemName: "flag.fill") }
                        Text("\(check.progress)%").monospacedDigit()
                    }
                    .font(Typography.small.weight(.medium))
                    .foregroundStyle(check.status == .onTrack ? Palette.secondary : check.status.tint)
                    .help(check.label)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.xs + Spacing.hairline)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(RunLineStyle())
        .help(Tip.openRunReport)
        .padding(.horizontal, -(Spacing.xs + Spacing.hairline))
        .accessibilityLabel("\(RoutineText.outcome(run)), \(RoutineText.stamp(run.date)). \(run.summary)"
                            + (run.check.map { ". " + $0.spokenLabel } ?? ""))
        .accessibilityHint("Abre o relatório desta execução")
    }
}

private struct RunLineStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.ghostSelected : (isHovering ? Palette.ghostHover : .clear),
                        in: .rect(cornerRadius: 6))
            .onHover { isHovering = $0 }
    }
}

// MARK: Run report

/// One run's result: the report as the Orb wrote it, how it went, and the ways on from it.
struct RoutineRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineID: UUID
    let runID: UUID
    let onConversation: () -> Void

    @State private var blocks: [ReportBlock] = []
    /// The saved report file, when it is still there (looked for off `body`).
    @State private var fileURL: URL?
    /// The report's height, so the sheet is as tall as the text (up to a limit, then it scrolls).
    @State private var contentHeight: CGFloat = 120

    private var routine: Routine? { model.routines.first { $0.id == routineID } }
    private var run: RoutineRun? { routine?.runs.first { $0.id == runID } }

    var body: some View {
        ZStack { sheet }
            .motion(Motion.content, value: routine != nil && run != nil)
    }

    @ViewBuilder private var sheet: some View {
        if let routine, let run {
            let title = "\(routine.name) · \(RoutineText.stamp(run.date))"
            let how = RoutineText.outcome(run)
            ScrollView {
                reportContent(run)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: max(80, min(contentHeight, 340)))
            .orbSheet(title, subtitle: [how, RoutineText.duration(of: run), run.check?.label].compactMap { $0 }.joined(separator: " · "),
                      size: .medium) {
                footer(run: run)
            }
            .task(id: runID) {
                blocks = RoutineText.reportBlocks(run.report ?? "")
                fileURL = await Self.existingFile(run, of: model.bot(routine.botID))
            }
        } else {
            ContentUnavailableView("Esta execução não está mais aqui", systemImage: "clock.arrow.circlepath")
                .frame(width: 540, height: 300)
                .overlay(alignment: .bottom) { Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction).padding() }
        }
    }

    private func reportContent(_ run: RoutineRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !run.succeeded {
                Label(run.summary, systemImage: "exclamationmark.triangle")
                    .font(Typography.text)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if (run.report ?? "").isEmpty {
                Text(run.summary)
                    .font(Typography.text)
                    .foregroundStyle(Palette.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReportBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(Spacing.sheetEdge)
    }

    private func footer(run: RoutineRun) -> some View {
        SheetFooterBar {
            Button("Copiar", systemImage: "doc.on.doc") { Clipboard.copy(run.report ?? run.summary) }
                .buttonStyle(GhostStyle())
                .help(Tip.copyReport)
                .hangsOnLeadingEdge()
            if let fileURL {
                Button("Abrir arquivo", systemImage: "doc.text") { NSWorkspace.shared.open(fileURL) }
                    .buttonStyle(GhostStyle())
                    .help(Tip.openReportFile)
            }
            if !run.succeeded {
                Button("Rodar de novo", systemImage: "arrow.clockwise") {
                    model.runRoutine(routineID, manual: true)
                    dismiss()
                }
                .buttonStyle(GhostStyle())
                .help(Tip.runRoutineAgain)
                .disabled(model.isRoutineRunning(routineID))
            }
            Spacer(minLength: Spacing.s)
            // "Fechar" is quiet (Esc does it); the way on, the routine's conversation, is the main action.
            Button("Fechar") { dismiss() }
                .buttonStyle(GhostStyle())
                .keyboardShortcut(.cancelAction)
            Button("Ver conversa", systemImage: "text.bubble", action: onConversation)
                .buttonStyle(PrimaryPillStyle())
                .help(Tip.routineConversation)
        }
        .labelStyle(FixedIconLabelStyle())
    }

    /// The report file of the run, if it is still there (where it was written, or in the Orb's folder for older runs).
    private static func existingFile(_ run: RoutineRun, of bot: Bot?) async -> URL? {
        let orbFolder = bot?.workingURL
        return await Task.detached { run.existingReportFile(inOrbFolder: orbFolder) }.value
    }
}

private struct ReportBlockView: View {
    let block: ReportBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(MarkdownCache.attributed(text))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Palette.faint)
                Text(MarkdownCache.attributed(text))
            }
            .font(Typography.text)
            .foregroundStyle(Palette.ink) // the report is what the sheet is for: full contrast, not the gray of captions
        case .paragraph(let text):
            Text(MarkdownCache.attributed(text))
                .font(Typography.text)
                .foregroundStyle(Palette.ink)
                .lineSpacing(3)
        }
    }
}

// MARK: The routine's conversation

/// A routine's own conversation, read-only: the last runs, live while one is running.
struct RoutineConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineID: UUID
    @State private var saved: [TranscriptItem] = []
    @State private var isLoading = true

    private var routine: Routine? { model.routines.first { $0.id == routineID } }

    var body: some View {
        let live = model.liveRoutineItems(routineID)
        let items = live ?? saved
        Group {
            if let routine, let bot = model.bot(routine.botID) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ReadOnlyTranscriptRows(items: items, isLive: live != nil, botID: bot.id, orb: bot.orb)
                    }
                    .padding(Spacing.sheetEdge)
                }
                // A run going on keeps its end in view, as the chat does.
                .modifier(KeepsBottom(follows: true))
                // The conversation fades in when it arrives; until then (after the 150 ms) a spinner, and if it never ran, the
                // empty message (§2.13).
                .motion(Motion.content, value: items.isEmpty)
                .overlay {
                    ZStack {
                        if items.isEmpty {
                            if isLoading {
                                DelayedSpinner().transition(.opacity)
                            } else {
                                ContentUnavailableView("Ainda não rodou", systemImage: "text.bubble").transition(.opacity)
                            }
                        }
                    }
                    .motion(Motion.content, value: isLoading)
                }
            } else {
                // The Orb deleted it from the chat while this was open.
                ContentUnavailableView("Esta rotina não está mais aqui", systemImage: "clock.arrow.circlepath")
            }
        }
        // An empty conversation is a short sheet, not 400 pt of black around one line.
        .frame(height: items.isEmpty && !isLoading ? 200 : 400)
        .background(Palette.canvas)
        .orbSheet(routine?.name ?? "Rotina",
                  subtitle: live == nil ? "Conversa da rotina, só para ler"
                      : routine.map { model.needsYou($0.botID) } == true ? ApprovalGate.waitingStatus : "Rodando agora",
                  size: .large) {
            SheetFooterBar {
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task(id: live == nil) {
            saved = await model.routineTranscript(routineID)
            isLoading = false
        }
    }
}

// MARK: Editor

/// Also opened from an Orb's panel (`BotInspector`), prefilled with that Orb.
struct RoutineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine

    private enum Kind: String, CaseIterable { case daily, weekly, hourly, minutes, once, cron }

    @State private var kind = Kind.daily
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? .now
    @State private var weekday = 2
    @State private var hours = 4
    @State private var minutes = 30
    @State private var onceDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var cronExpression = "0 9 * * 1-5"
    /// Empty: the Mac's own time zone.
    @State private var cronTimeZone = ""
    @State private var showsAdvanced = false
    /// Why the Orb could not be changed on save (the routine is running).
    @State private var moveProblem: String?
    /// The routine was deleted (by the Orb) while this sheet was open: saving asks before bringing it back.
    @State private var isConfirmingRecreate = false
    @State private var runsNow = false
    @State private var isConfirmingDelete = false
    /// The "Meta" section, apart from `routine.goal` so switching it off and on keeps what was typed.
    @State private var tracksGoal = false
    /// Read once when the editor opens, so turning the goal on or off does not move the section.
    @State private var leadsWithGoal = false
    @State private var goalTarget = ""
    /// The routine as the editor opened it: `save()` applies only what the editor changed over it (`Routine.merged`).
    @State private var original: Routine?

    private var isStored: Bool { model.routines.contains { $0.id == routine.id } }
    /// Fixed when the editor opens: the routine may be deleted meanwhile (the Orb can do it from the chat) and it is
    /// still the one being edited, not a new one.
    @State private var opensNew: Bool?
    private var isNew: Bool { opensNew ?? !isStored }
    private var hasPrompt: Bool { !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var trimmedGoal: String { goalTarget.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var lacksGoal: Bool { tracksGoal && trimmedGoal.isEmpty }
    private var bot: Bot? { model.bot(routine.botID) }

    /// The schedule as the controls have it now.
    private var draftSchedule: Schedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 9, minute = parts.minute ?? 0
        let zone = cronTimeZone.trimmingCharacters(in: .whitespaces)
        return switch kind {
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute)
        case .hourly: .everyHours(hours)
        case .minutes: .everyMinutes(minutes)
        case .once: .once(onceDate)
        case .cron: .cron(expression: cronExpression.trimmingCharacters(in: .whitespaces),
                          timeZone: zone.isEmpty ? nil : zone)
        }
    }

    /// What the schedule has to say about itself: its problem and the line with the next runs. `problem()` and `preview(of:)`
    /// walk the calendar (a cron line can scan up to 8 years of days), so they are worked out when the schedule changes
    /// (`.task(id: draftSchedule)`), not on every render, which a keystroke in the cron field repeats several times.
    private struct ScheduleCheck {
        var problem: String?
        var preview: String
        init(_ schedule: Schedule) {
            problem = schedule.problem()
            preview = RoutineText.preview(of: schedule)
        }
    }

    /// nil until the first pass; the getters below compute directly then, so the first frame is never empty.
    @State private var scheduleCheck: ScheduleCheck?

    /// Why the schedule cannot be saved; a routine saved earlier with a moment now past is not this editor's to block.
    private var scheduleProblem: String? {
        if !isNew && draftSchedule == routine.schedule { return nil }
        return (scheduleCheck ?? ScheduleCheck(draftSchedule)).problem
    }

    /// Refreshes `scheduleCheck` after the schedule changes. A cron line is typed key by key, so it waits for a pause.
    private func refreshScheduleCheck() async {
        let schedule = draftSchedule
        if case .cron = schedule {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        scheduleCheck = ScheduleCheck(schedule)
    }

    /// Beside the expression: "Válida" (with the line in words when it is a common one) or what is wrong with it.
    @ViewBuilder private var cronStatusLine: some View {
        switch RoutineText.cronStatus(cronExpression) {
        case .valid(let plain):
            Label(plain.map { "Válida · \($0)" } ?? "Válida", systemImage: "checkmark.circle")
                .font(Typography.small)
                .foregroundStyle(Palette.ok)
        case .invalid(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(Typography.small)
                .foregroundStyle(Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zoneProblem: String? {
        let zone = cronTimeZone.trimmingCharacters(in: .whitespaces)
        return zone.isEmpty ? nil : Schedule.zoneProblem(zone)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $routine.name, prompt: Text("Opcional. Ex.: Resumo da manhã"))
                Picker("Orb", selection: $routine.botID) {
                    ForEach(model.bots) { Text($0.name).tag($0.id) }
                }
                .onChange(of: routine.botID) { moveProblem = nil }
                if let moveProblem {
                    Text(moveProblem).font(Typography.label).foregroundStyle(Palette.warn)
                }
            }
            if let bot, RoutineText.waitsForAnswer(orbMode: bot.permissionMode, routineMode: routine.permissionMode) {
                // Right under the Orb it depends on, so it is seen before the rest of the form.
                Section { waitingWarning(bot).transition(.quiet) }
            }
            // What the routine does comes before when it runs: it is the heart of it. A routine made for a goal (a goal idea or
            // template) shows the goal first: below "O que fazer" it would open off screen.
            if leadsWithGoal { goalSection }
            Section("O que fazer") {
                PlaceholderTextEditor(placeholder: "Ex.: Leia meus e-mails não lidos e resuma os importantes em 5 tópicos.",
                                      text: $routine.prompt, minHeight: 70)
                if isNew {
                    Toggle("Rodar uma vez agora, para testar", isOn: $runsNow)
                        .help(Tip.runOnceNow)
                }
            }
            Section("Quando") {
                Picker("Repetir", selection: $kind) {
                    Text("Todo dia").tag(Kind.daily)
                    Text("Toda semana").tag(Kind.weekly)
                    Text("A cada X horas").tag(Kind.hourly)
                    Text("A cada X minutos").tag(Kind.minutes)
                    Text("Uma vez só").tag(Kind.once)
                    Text("Agenda avançada").tag(Kind.cron)
                }
                // What the kind of repetition adds or swaps fades by itself (`.quiet`): a Form is a table, and its rows
                // taking their new height at once looks calmer than a table sliding them.
                if kind == .weekly {
                    Picker("Dia", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.app.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                    }
                    .transition(.quiet)
                }
                if kind == .hourly {
                    Stepper("A cada \(hours) h", value: $hours, in: 1...24)
                        .transition(.quiet)
                } else if kind == .minutes {
                    Stepper("A cada \(minutes) min", value: $minutes, in: Schedule.minuteRange, step: 5)
                        .transition(.quiet)
                } else if kind == .once {
                    DatePicker("Data e hora", selection: $onceDate, displayedComponents: [.date, .hourAndMinute])
                        .transition(.quiet)
                } else if kind == .cron {
                    TextField("Expressão", text: $cronExpression, prompt: Text("minuto hora dia mês dia-da-semana"))
                        .font(Typography.text.monospaced())
                        .help(Tip.cronExpression)
                        .transition(.quiet)
                    cronStatusLine
                        .transition(.quiet)
                    TextField("Fuso", text: $cronTimeZone, prompt: Text(TimeZone.current.identifier))
                        .transition(.quiet)
                    if let zoneProblem {
                        // Also in the footer, but there it is far from the field that is wrong.
                        Text(zoneProblem)
                            .font(Typography.small)
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.quiet)
                    }
                } else {
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                        .transition(.quiet)
                }
                Label(preview, systemImage: "clock")
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .textSwap(preview)
            }
            if !leadsWithGoal { goalSection }
            Section {
                DisclosureGroup("Avançado", isExpanded: $showsAdvanced) {
                    Picker("Permissões da rotina", selection: $routine.permissionMode) {
                        Text("Igual ao Orb\(bot.map { " (\($0.permissionMode.label))" } ?? "")").tag(PermissionMode?.none)
                        Text(PermissionMode.auto.label).tag(PermissionMode?.some(.auto))
                        Text(PermissionMode.readOnly.label).tag(PermissionMode?.some(.readOnly))
                    }
                    .help(Tip.routinePermissions)
                    Picker("Contexto da rotina", selection: $routine.contextMemory) {
                        Text("Igual às outras rotinas (\(model.routineContextMemory.label))").tag(ContextMemoryLevel?.none)
                        ForEach(ContextMemoryLevel.allCases, id: \.self) { Text($0.label).tag(ContextMemoryLevel?.some($0)) }
                    }
                    .help(Tip.routineContext)
                    Text(advancedExplanation)
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .formStyle(.grouped)
        .orbSheet(isNew ? "Nova rotina" : "Editar rotina",
                  subtitle: "Uma tarefa que o Orb faz sozinho, no horário. O app precisa estar aberto.",
                  size: .medium, maxHeight: 720) {
            SheetFooter(message: footerMessage,
                        destructiveTitle: isNew ? nil : "Apagar rotina…",
                        destructive: { isConfirmingDelete = true },
                        cancel: { dismiss() },
                        primaryTitle: isNew ? "Criar rotina" : "Salvar",
                        isPrimaryDisabled: !hasPrompt || lacksGoal || scheduleProblem != nil || editProblem != nil,
                        primary: save)
        }
        .confirmationDialog("Apagar “\(RoutineText.resolvedName(routine.name, prompt: routine.prompt))”?",
                            isPresented: $isConfirmingDelete) {
            Button("Apagar rotina", role: .destructive) {
                model.deleteRoutine(routine.id)
                dismiss()
            }
        } message: {
            Text("A rotina e o histórico dela serão apagados. Não dá para desfazer.")
        }
        .confirmationDialog("Esta rotina foi apagada", isPresented: $isConfirmingRecreate) {
            Button("Recriar rotina") {
                routine.createdAt = .now
                routine.lastRun = nil
                model.routines.append(routine)
                dismiss()
            }
            Button("Voltar ao texto", role: .cancel) {}
        } message: {
            Text("O Orb apagou esta rotina enquanto você editava. Recriar com o que está na folha, ou voltar ao texto?")
        }
        .onAppear(perform: load)
        .task(id: draftSchedule) { await refreshScheduleCheck() }
    }

    /// What the footer says: what is missing. The "will wait for approval" case lives only in the warning above.
    private var footerMessage: String? {
        if !hasPrompt { return "Escreva o que o Orb deve fazer." }
        if lacksGoal { return "Escreva como saber que a meta deu certo." }
        if let scheduleProblem { return scheduleProblem }
        return editProblem
    }

    /// The `schedule` tool's limits (unique name, task count, prompt size), which the tool applies to what an Orb creates.
    private var editProblem: String? { model.routineEditProblem(routine, original: isNew ? nil : original) }

    private var preview: String {
        if !isNew, !routine.isEnabled { return "Esta rotina está pausada. Ative-a no cartão para voltar a rodar." }
        if !isNew, draftSchedule == routine.schedule {
            return RoutineText.preview(nextRun: routine.nextRun)
        }
        return (scheduleCheck ?? ScheduleCheck(draftSchedule)).preview
    }

    private var advancedExplanation: String {
        let mode = routine.permissionMode ?? bot?.permissionMode ?? .ask
        return "\(mode.label): \(mode.summary) Ninguém está presente para responder durante a rotina."
    }

    private func waitingWarning(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(bot.name) pergunta antes de agir; sem ninguém aqui, a rotina vai esperar você.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(Typography.label)
            .foregroundStyle(Palette.warn)
            HStack(spacing: 8) {
                Button("Rodar no modo Automático") { choose(.auto) }
                    .help(Tip.routineUseAuto)
                Button("Rodar em Só leitura") { choose(.readOnly) }
                    .help(Tip.routineUseReadOnly)
            }
            .buttonStyle(SecondaryPillStyle())
            .controlSize(.small)
            // `choose` sets this routine's own mode (under "Avançado"): the Orb keeps its mode for the rest.
            Text("Vale só para esta rotina; \(bot.name) continua como está nas conversas.")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// "Meta": whether runs track a goal, and what reaching it looks like.
    private var goalSection: some View {
        Section("Meta") {
            Toggle("Acompanhar uma meta", isOn: $tracksGoal)
                .help("Cada execução confere o progresso até a meta ser alcançada")
            if tracksGoal {
                PlaceholderTextEditor(placeholder: "Como saber que deu certo. Ex.: Nenhum arquivo antigo solto na pasta Downloads.",
                                      text: $goalTarget, minHeight: 44)
                    .transition(.quiet)
                Text("A cada execução o Orb confere o progresso, dá um pequeno passo quando é seguro e termina o relatório com uma linha como “Progresso: 35% · em dia”. Quando a meta é alcançada, a rotina pausa sozinha.")
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.quiet)
            }
        }
    }

    /// The warning's way out: set the mode and show it under "Avançado", where it can be changed back.
    private func choose(_ mode: PermissionMode) {
        routine.permissionMode = mode
        showsAdvanced = true
    }

    private func load() {
        opensNew = !isStored
        if original == nil { original = routine }
        let calendar = Calendar.current
        showsAdvanced = routine.permissionMode != nil || routine.contextMemory != nil
        tracksGoal = routine.goal != nil
        leadsWithGoal = tracksGoal
        goalTarget = routine.goal?.target ?? ""
        switch routine.schedule {
        case .daily(let hour, let minute):
            kind = .daily
            time = calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? time
        case .weekly(let day, let hour, let minute):
            kind = .weekly
            weekday = day
            time = calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? time
        case .everyHours(let value):
            kind = .hourly
            hours = value
        case .everyMinutes(let value):
            kind = .minutes
            minutes = Schedule.clampedMinutes(value)
        case .once(let date):
            kind = .once
            onceDate = date
        case .cron(let expression, let timeZone):
            kind = .cron
            cronExpression = expression
            cronTimeZone = timeZone ?? ""
        }
    }

    private func save() {
        let schedule = draftSchedule
        // Checked again here, not from `scheduleCheck`, which may still wait for the pause after a keystroke.
        guard hasPrompt, !lacksGoal, (!isNew && schedule == routine.schedule) || schedule.problem() == nil else { return }
        guard editProblem == nil else { return }
        routine.name = model.routineSaveName(routine)
        routine.goal = tracksGoal ? RoutineGoal(target: String(trimmedGoal.prefix(RoutineGoal.targetLimit))) : nil
        let scheduleChanged = schedule != routine.schedule
        routine.schedule = schedule
        if let index = model.routines.firstIndex(where: { $0.id == routine.id }) {
            // The Orb or a run may have changed it while the editor was open: only what this editor changed is written,
            // so history, on/off switch, precheck and the Orb's own edits stay.
            let current = model.routines[index]
            let merged = Routine.merged(edited: routine, original: original ?? current, current: current)
            if merged.botID != current.botID,
               !model.moveRoutineConversation(routine.id, from: current.botID, to: merged.botID) {
                moveProblem = "Esta rotina está rodando ou na fila. Espere terminar para trocar o Orb."
                return
            }
            model.routines[index] = merged
            dismiss()
        } else if isNew {
            if scheduleChanged {
                // Count the next run from now, not from when the draft was created.
                routine.createdAt = .now
                routine.lastRun = nil
            }
            model.routines.append(routine)
            if runsNow { model.runRoutine(routine.id, manual: true) }
            dismiss()
        } else {
            // Deleted while open: closing in silence would lose the typed text, so the person chooses (the sheet stays
            // open on "Voltar", with the text). Recreating is never automatic.
            isConfirmingRecreate = true
        }
    }
}

// MARK: Snapshots

#if DEBUG || ORB_DEV_TOOLS
/// Screens of this file for `Orb --snapshot <mode> out.png` (see `Snapshot`).
@MainActor
enum RoutinesSnapshots {
    /// Routines of the first Orb (one with a good and a failed run, two with a goal: on track and needing attention) so
    /// the routine screens have something to show.
    static func seed(_ model: AppModel) {
        guard model.routines.isEmpty, let bot = model.bots.first else { return }
        var morning = Routine(name: "Resumo da manhã", botID: bot.id,
                              prompt: "Faça um resumo da minha manhã usando a agenda e o e-mail.", schedule: .daily(hour: 8, minute: 30))
        morning.lastRun = Date.now.addingTimeInterval(-3600)
        morning.lastResult = "3 reuniões hoje, 12 e-mails novos."
        morning.followUps = [RoutineFollowUp(subject: "Ana", channel: "E-mail", nextStep: "Verificar resposta à proposta")]
        morning.runs = [
            RoutineRun(date: Date.now.addingTimeInterval(-3600), finishedAt: Date.now.addingTimeInterval(-3500), succeeded: true,
                       summary: "3 reuniões hoje, 12 e-mails novos.", report: "Hoje: 3 reuniões (10h, 14h, 16h).\n12 e-mails novos, 2 pedem resposta."),
            RoutineRun(date: Date.now.addingTimeInterval(-90_000), finishedAt: Date.now.addingTimeInterval(-89_900), succeeded: false,
                       summary: "O conector de agenda não respondeu.", report: nil),
        ]
        let weekly = Routine(name: "Revisar a semana", botID: bot.id, prompt: "Revise a minha semana.",
                             schedule: .weekly(weekday: 6, hour: 17, minute: 0))
        // A cron line and a long summary: the card says the schedule in words and does not end in a cut word.
        var rounds = Routine(name: "Rodada WhatsApp 30min 8h-23h", botID: bot.id, prompt: "Responda as conversas novas do WhatsApp.",
                             schedule: .cron(expression: "*/30 8-23 * * *", timeZone: TimeZone.current.identifier))
        let roundsSummary = "Rodada das 22:00: respondi Bruno Santos, Glauber, Letícia Moura e Paulo; dois pedidos de preço ficaram para amanhã."
        rounds.runs = [RoutineRun(date: Date.now.addingTimeInterval(-1_800), finishedAt: Date.now.addingTimeInterval(-1_700),
                                  succeeded: true, summary: roundsSummary,
                                  report: roundsSummary + "\n\nBruno: plano anual. Glauber: horário. Letícia: trancamento. Paulo: avaliação.")]
        rounds.lastRun = rounds.runs.first?.date
        model.routines = [rounds, morning, weekly,
                          goal(RoutineTemplate.desktopGoal.routine(for: bot.id), checks: [
                              (35, .onTrack, "Faltam 26 arquivos antigos; movi 14 para Documentos."),
                              (20, .onTrack, "Movi 9 imagens para Imagens."),
                              (8, .onTrack, ""),
                          ]),
                          goal(Routine(name: "Conciliar faturas", botID: bot.id, prompt: "Confira as faturas do mês.",
                                       schedule: .everyHours(4), goal: RoutineGoal(target: "Todas as faturas do mês conciliadas.")),
                               checks: [(60, .attention, "Duas faturas sem comprovante: preciso de você."), (55, .onTrack, "")])]
    }

    /// A routine whose runs, newest first, reported these checks.
    private static func goal(_ routine: Routine, checks: [(Int, GoalStatus, String)]) -> Routine {
        var routine = routine
        routine.runs = checks.enumerated().map { index, check in
            let date = Date.now.addingTimeInterval(-86_400 * Double(index + 1))
            let line = GoalCheck(progress: check.0, status: check.1, note: check.2)
            return RoutineRun(date: date, finishedAt: date.addingTimeInterval(95), succeeded: true,
                              summary: check.2.isEmpty ? "Conferi o progresso da meta." : check.2,
                              report: "Progresso: \(line.label)", check: line)
        }
        routine.lastRun = routine.runs.first?.date
        routine.goal?.check = routine.runs.first?.check
        routine.goal?.updatedAt = routine.lastRun
        return routine
    }

    static func view(_ screen: String, model: AppModel) -> AnyView? {
        switch screen {
        case "routine-editor":
            guard let routine = model.routines.first else { return nil }
            return AnyView(RoutineEditor(routine: routine))
        case "routine-editor-new":
            guard let routine = model.draftRoutine(from: RoutineTemplate.all[1]) else { return nil }
            return AnyView(RoutineEditor(routine: routine))
        case "empty-routines":
            // Not seeded (the name does not start with "routine"): the empty page and its templates.
            return AnyView(RoutinesView())
        case "routine-editor-goal":
            guard let routine = model.draftRoutine(from: RoutineTemplate.desktopGoal) else { return nil }
            return AnyView(RoutineEditor(routine: routine))
        case "routine-run", "routine-run-failed":
            guard let routine = model.routines.first,
                  let run = routine.runs.first(where: { $0.succeeded == (screen == "routine-run") }) else { return nil }
            // A real sheet takes its ideal height; the offscreen window would stretch it.
            return AnyView(RoutineRunSheet(routineID: routine.id, runID: run.id, onConversation: {})
                .fixedSize(horizontal: false, vertical: true))
        case "routine-conversation":
            guard let routine = model.routines.first else { return nil }
            return AnyView(RoutineConversationSheet(routineID: routine.id))
        default:
            return nil
        }
    }
}
#endif

