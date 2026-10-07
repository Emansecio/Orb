import SwiftUI

// MARK: Routines

struct RoutinesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach($model.routines) { $routine in
                    if let bot = model.bot(routine.botID) {
                        RoutineCard(routine: $routine, bot: bot)
                    }
                }
            }
            .padding(24)
        }
        .background(Palette.canvas)
        .navigationTitle("Rotinas")
        .navigationSubtitle("Tarefas que seus bots fazem sozinhos")
        .toolbar {
            Button("Nova rotina", systemImage: "plus") {}
                .help("Nova rotina (em breve)")
        }
    }
}

private struct RoutineCard: View {
    @Binding var routine: Routine
    let bot: Bot

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
            Label(routine.schedule, systemImage: "clock")
                .font(.callout)
            if routine.isEnabled {
                (Text("Próxima: ") + Text(routine.nextRun, style: .relative))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            Divider()
            if routine.pausedForInactivity {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(Palette.warn)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pausada para não gastar à toa: \(routine.lastResult.lowercased()).")
                            .font(.caption)
                        Button("Retomar") { routine.pausedForInactivity = false }
                            .controlSize(.small)
                    }
                }
            } else {
                Label(routine.lastResult, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(16)
        .card(radius: 12)
        .opacity(routine.isEnabled ? 1 : 0.6)
    }
}

// MARK: Connectors

struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var categories: [String] {
        var seen = Set<String>()
        return model.connectors.map(\.category).filter { seen.insert($0).inserted }
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(categories, id: \.self) { category in
                    let indices = model.connectors.indices.filter {
                        model.connectors[$0].category == category && matches(model.connectors[$0])
                    }
                    if !indices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category)
                                .font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(indices, id: \.self) { index in
                                    ConnectorCard(connector: $model.connectors[index])
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Palette.canvas)
        .searchable(text: $query, prompt: "Buscar conectores")
        .navigationTitle("Conectores")
        .navigationSubtitle("Apps e serviços que seus bots podem usar")
    }

    private func matches(_ connector: Connector) -> Bool {
        query.isEmpty || connector.name.localizedCaseInsensitiveContains(query)
            || connector.summary.localizedCaseInsensitiveContains(query)
    }
}

private struct ConnectorCard: View {
    @Binding var connector: Connector

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connector.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Palette.raised, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                    .fontWeight(.medium)
                Text(connector.summary)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if connector.isConnected {
                Menu {
                    Button("Desconectar", role: .destructive) { connector.isConnected = false }
                } label: {
                    Label("Conectado", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.ok)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button("Conectar") { connector.isConnected = true }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .card(radius: 14)
    }
}

// MARK: Skills

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var filtered: [Skill] {
        query.isEmpty ? model.skills : model.skills.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Table(filtered) {
            TableColumn("Skill") { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).fontWeight(.medium)
                    Text("/\(skill.slug)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            TableColumn("O que faz", value: \.summary)
            TableColumn("Criada por", value: \.owner)
                .width(110)
            TableColumn("Usos") { skill in
                Text(skill.uses, format: .number).monospacedDigit()
            }
            .width(60)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .searchable(text: $query, prompt: "Buscar skills")
        .navigationTitle("Skills")
        .navigationSubtitle("Habilidades reutilizáveis — use com / no chat")
        .toolbar {
            Button("Nova skill", systemImage: "plus") {}
                .help("Nova skill (em breve)")
        }
    }
}
