import SwiftUI

// MARK: Routines

struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Routine?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach($model.routines) { $routine in
                    if let bot = model.bot(routine.botID) {
                        RoutineCard(routine: $routine, bot: bot, isRunning: model.isWorking(bot.id)) {
                            model.runRoutine(routine.id)
                        } onEdit: {
                            editing = routine
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
    }
}

private struct RoutineCard: View {
    @Binding var routine: Routine
    let bot: Bot
    let isRunning: Bool
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BotAvatar(bot: bot, size: 26, activity: routine.isEnabled ? .idle : .sleepy, animated: false)
                Text(bot.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Toggle("Ativa", isOn: $routine.isEnabled)
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
            Text(routine.lastResult ?? "Ainda não rodou.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .lineLimit(3)
            HStack {
                Button("Editar", action: onEdit)
                Spacer()
                Button("Rodar agora", systemImage: "play.fill", action: onRun)
                    .disabled(isRunning)
            }
            .controlSize(.small)
        }
        .padding(16)
        .card(radius: 12)
        .opacity(routine.isEnabled ? 1 : 0.6)
    }
}

private struct RoutineEditor: View {
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
                        model.routines.removeAll { $0.id == routine.id }
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
            model.routines[index] = routine
        } else {
            model.routines.append(routine)
        }
        dismiss()
    }
}
