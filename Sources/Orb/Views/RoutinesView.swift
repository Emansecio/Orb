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
    @State private var sheet: RoutinesSheet?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            Group {
                if model.routines.isEmpty {
                    RoutinesEmptyState(canCreate: !model.bots.isEmpty,
                                       onNew: { newRoutine(nil) },
                                       onTemplate: { newRoutine($0) })
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach($model.routines) { $routine in
                            if let bot = model.bot(routine.botID) {
                                RoutineCard(routine: $routine, bot: bot, isRunning: model.isRoutineRunning(routine.id),
                                            isQueued: model.isRoutineQueued(routine.id),
                                            onRun: { model.runRoutine(routine.id) },
                                            onEdit: { sheet = .edit(routine) },
                                            onOpen: { sheet = .conversation(routine.id) },
                                            onOpenRun: { sheet = .run(routine: routine.id, run: $0) })
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(24)
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
                .disabled(model.bots.isEmpty)
                .help("Nova rotina")
            }
        }
        .onAppear(perform: takeRequest)
        .onChange(of: model.routineToShow) { takeRequest() }
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

    private func newRoutine(_ template: RoutineTemplate?) {
        if let draft = model.draftRoutine(from: template) { sheet = .edit(draft) }
    }

    /// A routine waiting for an answer was asked for ("Ver pedido", its banner): its conversation opens.
    private func takeRequest() {
        guard let id = model.routineToShow else { return }
        model.routineToShow = nil
        sheet = .conversation(id)
    }
}

// MARK: Empty state

/// Nothing yet: what a routine is, one button, and three to start from.
private struct RoutinesEmptyState: View {
    let canCreate: Bool
    let onNew: () -> Void
    let onTemplate: (RoutineTemplate) -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.faint)
                    .accessibilityHidden(true)
                Text("Nenhuma rotina ainda")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Uma rotina é uma tarefa que um Orb faz sozinho, no horário. O app precisa estar aberto.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Nova rotina", systemImage: "plus", action: onNew)
                .buttonStyle(PrimaryPillStyle())
                .disabled(!canCreate)
            if !canCreate {
                Text("Crie um Orb primeiro: é ele quem faz a rotina.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            VStack(spacing: 10) {
                Text("Ou comece por um modelo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { templateCards(width: 236) }
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 12) { templateCards(width: nil) }
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: 760)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }
}

extension RoutinesEmptyState {
    @ViewBuilder fileprivate func templateCards(width: CGFloat?) -> some View {
        ForEach(RoutineTemplate.all) { template in
            TemplateCard(template: template, isEnabled: canCreate) { onTemplate(template) }
                .frame(width: width)
        }
    }
}

private struct TemplateCard: View {
    let template: RoutineTemplate
    let isEnabled: Bool
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
                Text(template.whenText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.secondary)
                Text(template.prompt)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .card(radius: 12, fill: isHovering ? Palette.raised : Palette.surface)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(template.title), \(template.whenText)")
        .accessibilityHint("Abre o editor já preenchido")
    }
}

// MARK: Card

private struct RoutineCard: View {
    @Binding var routine: Routine
    let bot: Bot
    /// This routine is running now / is waiting for its Orb to be free.
    let isRunning: Bool
    let isQueued: Bool
    let onRun: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onOpenRun: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 30, activity: routine.isEnabled ? .idle : .sleepy, animated: false)
                Text(bot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                if let mode = routine.permissionMode {
                    Label(mode.label, systemImage: mode.symbol)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Palette.raised, in: .capsule)
                        .help("Esta rotina roda em “\(mode.label)”, mesmo que o Orb use outro modo")
                }
                Spacer()
                Toggle("Ativa", isOn: Binding(get: { routine.isEnabled }, set: { routine.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(routine.isEnabled ? "Pausar esta rotina" : "Ativar esta rotina")
            }
            Text(routine.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 4) {
                Label(routine.schedule.label, systemImage: "clock")
                    .font(.callout)
                NextRunLine(routine: routine)
            }
            Divider()
            if routine.runs.isEmpty {
                Text(routine.lastResult ?? "Ainda não rodou.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
            } else {
                RunHistory(runs: routine.runs, onOpen: onOpenRun)
            }
            HStack {
                Button("Editar", action: onEdit)
                Button("Ver conversa", systemImage: "text.bubble", action: onOpen)
                Spacer()
                if isRunning {
                    Label("Rodando…", systemImage: "hourglass").foregroundStyle(Palette.muted)
                } else if isQueued {
                    Label("Na fila", systemImage: "clock").foregroundStyle(Palette.muted)
                        .help("Roda assim que o Orb terminar o que está fazendo")
                } else {
                    Button("Rodar agora", systemImage: "play.fill", action: onRun)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .card(radius: 12)
        .opacity(routine.isEnabled ? 1 : 0.6)
    }
}

/// "Próxima: em 3 h · hoje às 09:00", kept right as the minutes pass; "Pausada" when it is switched off.
private struct NextRunLine: View {
    let routine: Routine

    var body: some View {
        if routine.isEnabled {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(RoutineText.nextRun(of: routine, now: context.date) ?? "")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
        } else {
            Label("Pausada", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(Palette.muted)
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
            if let latest = runs.first { RunLine(run: latest, lineLimit: 3) { onOpen(latest.id) } }
            if runs.count > 1 {
                DisclosureGroup("Execuções anteriores (\(runs.count - 1))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(runs.dropFirst()) { run in
                            RunLine(run: run, lineLimit: 1) { onOpen(run.id) }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct RunLine: View {
    let run: RoutineRun
    let lineLimit: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(run.succeeded ? Palette.ok : Palette.danger)
                    .font(.caption)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text([RoutineText.stamp(run.date), RoutineText.duration(of: run)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(Palette.faint)
                    Text(run.summary)
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(RunLineStyle())
        .padding(.horizontal, -6)
        .accessibilityLabel("\(run.succeeded ? "Deu certo" : "Não deu certo"), \(RoutineText.stamp(run.date)). \(run.summary)")
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
private struct RoutineRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineID: UUID
    let runID: UUID
    let onConversation: () -> Void

    @State private var blocks: [ReportBlock]
    /// The saved report file, when it is still there (looked for off `body`).
    @State private var fileURL: URL?
    /// The report's height, so the sheet is as tall as the text (up to a limit, then it scrolls).
    @State private var contentHeight: CGFloat = 120

    init(routineID: UUID, runID: UUID, onConversation: @escaping () -> Void) {
        self.routineID = routineID
        self.runID = runID
        self.onConversation = onConversation
        _blocks = State(initialValue: [])
    }

    private var routine: Routine? { model.routines.first { $0.id == routineID } }
    private var run: RoutineRun? { routine?.runs.first { $0.id == runID } }

    var body: some View {
        if let routine, let run {
            let title = "\(routine.name) · \(RoutineText.stamp(run.date))"
            let how = run.succeeded ? "Deu certo" : "Não deu certo"
            ScrollView {
                reportContent(run)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: max(80, min(contentHeight, 340)))
            .orbSheet(title, subtitle: [how, RoutineText.duration(of: run)].compactMap { $0 }.joined(separator: " · "),
                      size: .medium) {
                footer(routine: routine, run: run)
            }
            .task(id: runID) {
                blocks = RoutineText.reportBlocks(run.report ?? "")
                fileURL = await Self.existingFile(run.reportFile, of: model.bot(routine.botID))
            }
        } else {
            ContentUnavailableView("Esta execução não está mais aqui", systemImage: "clock.arrow.circlepath")
                .frame(width: 540, height: 300)
                .overlay(alignment: .bottom) { Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction).padding() }
        }
    }

    private func reportContent(_ run: RoutineRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !run.succeeded {
                Label(run.summary, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if (run.report ?? "").isEmpty {
                Text(run.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReportBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(20)
    }

    private func footer(routine: Routine, run: RoutineRun) -> some View {
        HStack(spacing: 4) {
            Button("Copiar", systemImage: "doc.on.doc") { copy(run) }
                .buttonStyle(GhostStyle())
            if let fileURL {
                Button("Abrir arquivo", systemImage: "doc.text") { NSWorkspace.shared.open(fileURL) }
                    .buttonStyle(GhostStyle())
            }
            Button("Ver conversa", systemImage: "text.bubble", action: onConversation)
                .buttonStyle(GhostStyle())
            if !run.succeeded {
                Button("Rodar de novo", systemImage: "arrow.clockwise") {
                    model.runRoutine(routineID)
                    dismiss()
                }
                .buttonStyle(GhostStyle())
                .disabled(model.isRoutineRunning(routineID))
            }
            Spacer(minLength: 8)
            Button("Fechar") { dismiss() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.cancelAction)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private func copy(_ run: RoutineRun) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.report ?? run.summary, forType: .string)
    }

    /// The report file of the run inside the Orb's folder, if it is still there.
    private static func existingFile(_ path: String?, of bot: Bot?) async -> URL? {
        guard let path, let bot else { return nil }
        let url = bot.workingURL.appendingPathComponent(path)
        return await Task.detached { FileManager.default.fileExists(atPath: url.path) ? url : nil }.value
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
        case .paragraph(let text):
            Text(MarkdownCache.attributed(text))
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
        }
    }
}

// MARK: The routine's conversation

/// A routine's own conversation, read-only: the last runs, live while one is running.
private struct RoutineConversationSheet: View {
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
                        ForEach(items) { item in
                            TranscriptRow(item: item, botID: bot.id, orb: bot.orb).equatable()
                        }
                    }
                    .padding(20)
                }
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(isLoading ? "Carregando…" : "Ainda não rodou", systemImage: "text.bubble")
                    }
                }
            }
        }
        .frame(height: 400)
        .background(Palette.canvas)
        .orbSheet(routine?.name ?? "Rotina",
                  subtitle: live == nil ? "Conversa da rotina, só para ler"
                      : routine.map { model.needsYou($0.botID) } == true ? "Esperando sua resposta" : "Rodando agora",
                  size: .large) {
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
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

    private enum Kind: String, CaseIterable { case daily, weekly, hourly }

    @State private var kind = Kind.daily
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? .now
    @State private var weekday = 2
    @State private var hours = 4
    @State private var showsAdvanced = false
    @State private var runsNow = false
    @State private var isConfirmingDelete = false

    private var isNew: Bool { !model.routines.contains { $0.id == routine.id } }
    private var hasPrompt: Bool { !routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var bot: Bot? { model.bot(routine.botID) }

    /// The schedule as the controls have it now.
    private var draftSchedule: Schedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 9, minute = parts.minute ?? 0
        return switch kind {
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute)
        case .hourly: .everyHours(hours)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $routine.name, prompt: Text("Opcional. Ex.: Resumo da manhã"))
                Picker("Orb", selection: $routine.botID) {
                    ForEach(model.bots) { Text($0.name).tag($0.id) }
                }
            }
            if let bot, RoutineText.waitsForAnswer(orbMode: bot.permissionMode, routineMode: routine.permissionMode) {
                // Right under the Orb it depends on, so it is seen before the rest of the form.
                Section { waitingWarning(bot) }
            }
            Section("Quando") {
                Picker("Repetir", selection: $kind) {
                    Text("Todo dia").tag(Kind.daily)
                    Text("Toda semana").tag(Kind.weekly)
                    Text("A cada X horas").tag(Kind.hourly)
                }
                if kind == .weekly {
                    Picker("Dia", selection: $weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1].capitalized).tag($0) }
                    }
                }
                if kind == .hourly {
                    Stepper("A cada \(hours) h", value: $hours, in: 1...24)
                } else {
                    DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                }
                Label(preview, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Section("O que fazer") {
                PlaceholderTextEditor(placeholder: "Ex.: Leia meus e-mails não lidos e resuma os importantes em 5 tópicos.",
                                      text: $routine.prompt, minHeight: 70)
                if isNew {
                    Toggle("Rodar uma vez agora, para testar", isOn: $runsNow)
                }
            }
            Section {
                DisclosureGroup("Avançado", isExpanded: $showsAdvanced) {
                    Picker("Permissões da rotina", selection: $routine.permissionMode) {
                        Text("Igual ao Orb\(bot.map { " (\($0.permissionMode.label))" } ?? "")").tag(PermissionMode?.none)
                        Text(PermissionMode.auto.label).tag(PermissionMode?.some(.auto))
                        Text(PermissionMode.readOnly.label).tag(PermissionMode?.some(.readOnly))
                    }
                    Text(advancedExplanation)
                        .font(.caption)
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
                        isPrimaryDisabled: !hasPrompt,
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
        .onAppear(perform: load)
    }

    /// What the footer says: what is missing, or that the run would wait (the warning itself is further down).
    private var footerMessage: String? {
        if !hasPrompt { return "Escreva o que o Orb deve fazer." }
        if let bot, RoutineText.waitsForAnswer(orbMode: bot.permissionMode, routineMode: routine.permissionMode) {
            return "\(bot.name) vai esperar sua aprovação."
        }
        return nil
    }

    private var preview: String {
        if !isNew, !routine.isEnabled { return "Esta rotina está pausada. Ative-a no cartão para voltar a rodar." }
        if !isNew, draftSchedule == routine.schedule {
            return RoutineText.preview(nextRun: routine.nextRun)
        }
        return RoutineText.preview(of: draftSchedule)
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
            .font(.system(size: 12))
            .foregroundStyle(Palette.warn)
            HStack(spacing: 8) {
                Button("Usar Automático") { choose(.auto) }
                Button("Usar Só leitura") { choose(.readOnly) }
            }
            .buttonStyle(SecondaryPillStyle())
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// The warning's way out: set the mode and show it under "Avançado", where it can be changed back.
    private func choose(_ mode: PermissionMode) {
        routine.permissionMode = mode
        showsAdvanced = true
    }

    private func load() {
        let calendar = Calendar.current
        showsAdvanced = routine.permissionMode != nil
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
        }
    }

    private func save() {
        guard hasPrompt else { return }
        let schedule = draftSchedule
        routine.name = RoutineText.resolvedName(routine.name, prompt: routine.prompt)
        if schedule != routine.schedule {
            // Count the next run from now, not from when the routine was created.
            routine.schedule = schedule
            routine.createdAt = .now
            routine.lastRun = nil
        }
        let wasNew = isNew
        if let index = model.routines.firstIndex(where: { $0.id == routine.id }) {
            // A run may have ended while the editor was open: its history is not the editor's to overwrite.
            let current = model.routines[index]
            routine.runs = current.runs
            routine.lastResult = current.lastResult
            if routine.schedule == current.schedule { routine.lastRun = current.lastRun }
            model.routines[index] = routine
        } else {
            model.routines.append(routine)
        }
        if wasNew && runsNow { model.runRoutine(routine.id) }
        dismiss()
    }
}

// MARK: Snapshots

/// Screens of this file for `Orb --snapshot <mode> out.png` (see `Snapshot`).
@MainActor
enum RoutinesSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        switch screen {
        case "routine-editor":
            guard let routine = model.routines.first else { return nil }
            return AnyView(RoutineEditor(routine: routine))
        case "routine-editor-new":
            guard let routine = model.draftRoutine(from: RoutineTemplate.all[1]) else { return nil }
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
        case "conversations":
            guard let bot = model.bots.first else { return nil }
            Self.seedArchive(for: bot.id)
            return AnyView(ConversationsMenu(botID: bot.id, onClose: {}).background(Palette.chrome).frame(width: 380, height: 520, alignment: .top))
        default:
            return nil
        }
    }

    /// A few earlier conversations at different days, so the grouped list has something to show.
    private static func seedArchive(for botID: UUID) {
        let store = Store.standard
        guard store.readArchive(botID).isEmpty else { return }
        let titles: [(String, Double, Int)] = [
            ("Qual é a melhor forma de organizar meus PDFs de contratos por cliente e ano?", 0.2, 12),
            ("Resuma o artigo que salvei ontem", 1.1, 4),
            ("Me ajuda a planejar a viagem de dezembro", 2.4, 18),
            ("Revisar o texto da apresentação", 3.5, 6),
            ("Como configuro o backup automático?", 9, 2),
            ("Ideias de nome para o projeto", 40, 1),
        ]
        for (title, daysAgo, count) in titles {
            let when = Date.now.addingTimeInterval(-daysAgo * 86_400)
            var conversation = Conversation()
            for index in 0..<max(2, count) {
                var item = TranscriptItem(index % 2 == 0 ? .user(text: index == 0 ? title : "Mais uma coisa", attachments: []) : .bot(text: "Claro.", isStreaming: false))
                item.date = when.addingTimeInterval(Double(index) * 60)
                conversation.items.append(item)
            }
            store.archive(conversation, for: botID)
        }
        store.flush()
    }
}
