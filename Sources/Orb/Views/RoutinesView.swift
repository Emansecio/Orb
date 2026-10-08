import SwiftUI

// MARK: Routines

struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Routine?
    @State private var viewing: Routine?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach($model.routines) { $routine in
                    if let bot = model.bot(routine.botID) {
                        RoutineCard(routine: $routine, bot: bot, isRunning: model.isRoutineRunning(routine.id),
                                    isQueued: model.isRoutineQueued(routine.id)) {
                            model.runRoutine(routine.id)
                        } onEdit: {
                            editing = routine
                        } onOpen: {
                            viewing = routine
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if model.routines.isEmpty {
                ContentUnavailableView("Nenhuma rotina", systemImage: "clock.arrow.circlepath",
                                       description: Text("Peça a um Orb para fazer algo sozinho, todo dia ou toda semana."))
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Rotinas")
        .navigationSubtitle("Tarefas que seus Orbs fazem sozinhos enquanto o app está aberto")
        .toolbar {
            Button("Nova rotina", systemImage: "plus") {
                if let bot = model.selectedBot ?? model.bots.first {
                    editing = Routine(name: "", botID: bot.id, prompt: "", schedule: .daily(hour: 9, minute: 0))
                }
            }
            .disabled(model.bots.isEmpty)
        }
        .sheet(item: $editing) { routine in
            RoutineEditor(routine: routine)
        }
        .sheet(item: $viewing) { routine in
            RoutineConversationSheet(routineID: routine.id)
        }
    }
}

private struct RoutineCard: View {
    @Binding var routine: Routine
    let bot: Bot
    /// This routine is running now / is waiting for its Orb to be free.
    let isRunning: Bool
    let isQueued: Bool
    let onRun: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 26, activity: routine.isEnabled ? .idle : .sleepy, animated: false)
                Text(bot.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Toggle("Ativa", isOn: Binding(get: { routine.isEnabled }, set: { routine.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Text(routine.name)
                .font(.system(size: 15, weight: .semibold))
            Label(routine.schedule.label, systemImage: "clock")
                .font(.callout)
            if routine.isEnabled {
                (Text("Próxima: ") + Text(routine.nextRun, style: .relative))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Divider()
            if routine.runs.isEmpty {
                Text(routine.lastResult ?? "Ainda não rodou.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
            } else {
                RunHistory(runs: routine.runs)
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

/// The routine's recent runs, newest first: the latest in full, the others behind a disclosure.
private struct RunHistory: View {
    let runs: [RoutineRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let latest = runs.first { RunLine(run: latest, lineLimit: 3) }
            if runs.count > 1 {
                DisclosureGroup("Execuções anteriores (\(runs.count - 1))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(runs.dropFirst()) { RunLine(run: $0, lineLimit: 1) }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(run.succeeded ? Palette.ok : Palette.danger)
                .font(.caption)
                .accessibilityLabel(run.succeeded ? "Deu certo" : "Não deu certo")
            VStack(alignment: .leading, spacing: 1) {
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Palette.faint)
                Text(run.summary)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(lineLimit)
                if let file = run.reportFile {
                    Label(file, systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine?.name ?? "Rotina").font(.headline)
                    Text(live == nil ? "Conversa da rotina, só para ler" : "Rodando agora")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let routine, let bot = model.bot(routine.botID) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            TranscriptRow(item: item, bot: bot).equatable()
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
        .frame(width: 640, height: 560)
        .background(Palette.canvas)
        .task(id: live == nil) {
            saved = await model.routineTranscript(routineID)
            isLoading = false
        }
    }
}

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

    private var isNew: Bool { !model.routines.contains { $0.id == routine.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nome", text: $routine.name, prompt: Text("Ex.: Resumo da manhã"))
                Picker("Orb", selection: $routine.botID) {
                    ForEach(model.bots) { Text($0.name).tag($0.id) }
                }
                Section {
                    Picker("Permissões da rotina", selection: $routine.permissionMode) {
                        Text("Igual ao Orb").tag(PermissionMode?.none)
                        Text(PermissionMode.auto.label).tag(PermissionMode?.some(.auto))
                        Text(PermissionMode.readOnly.label).tag(PermissionMode?.some(.readOnly))
                    }
                } footer: {
                    Text("Ninguém está presente quando a rotina roda: com “Perguntar antes” ela espera sua aprovação.")
                }
                Section("O que fazer") {
                    TextEditor(text: $routine.prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                }
                Section("Quando") {
                    Picker("Repetir", selection: $kind) {
                        Text("Todo dia").tag(Kind.daily)
                        Text("Toda semana").tag(Kind.weekly)
                        Text("A cada X horas").tag(Kind.hourly)
                    }
                    if kind == .weekly {
                        Picker("Dia", selection: $weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                    }
                    if kind == .hourly {
                        Stepper("A cada \(hours) h", value: $hours, in: 1...24)
                    } else {
                        DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Apagar", role: .destructive) {
                        model.deleteRoutine(routine.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Criar" : "Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(routine.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        let calendar = Calendar.current
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
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 9, minute = parts.minute ?? 0
        let schedule: Schedule = switch kind {
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute)
        case .hourly: .everyHours(hours)
        }
        if schedule != routine.schedule {
            // Count the next run from now, not from when the routine was created.
            routine.schedule = schedule
            routine.createdAt = .now
            routine.lastRun = nil
        }
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
        dismiss()
    }
}
