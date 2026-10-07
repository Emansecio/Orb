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
                                       description: Text("Peça a um bot para fazer algo sozinho, todo dia ou toda semana."))
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Rotinas")
        .navigationSubtitle("Tarefas que seus bots fazem sozinhos enquanto o OpenBot está aberto")
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
                Picker("Bot", selection: $routine.botID) {
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

// MARK: Connectors (MCP servers)

struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MCPServerConfig?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach($model.connectors) { $connector in
                    ConnectorCard(connector: $connector, status: model.connectorStatus[connector.id]) {
                        editing = connector
                    }
                }
            }
            .padding(24)
        }
        .overlay {
            if model.connectors.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum conector", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("Conectores são servidores MCP: dão novas ferramentas aos bots que têm “Conectores” ativado.")
                } actions: {
                    templateMenu
                }
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Conectores")
        .navigationSubtitle("Servidores MCP que seus bots podem usar")
        .toolbar {
            Button("Reconectar", systemImage: "arrow.clockwise") { model.syncConnectors() }
            templateMenu
        }
        .sheet(item: $editing) { connector in
            ConnectorEditor(connector: connector)
        }
    }

    private var templateMenu: some View {
        Menu("Adicionar", systemImage: "plus") {
            ForEach(MCPServerConfig.templates, id: \.name) { template in
                Button(template.name) { editing = template.withNewID() }
            }
            Divider()
            Button("Outro servidor…") { editing = MCPServerConfig(name: "", command: "") }
        }
    }
}

private struct ConnectorCard: View {
    @Binding var connector: MCPServerConfig
    let status: MCPStatus?
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(connector.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Ativo", isOn: $connector.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Text(([connector.command] + connector.arguments).joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            HStack {
                statusLabel
                Spacer()
                Button("Editar", action: onEdit)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .card(radius: 14)
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .ready(let count):
            Label("\(count) ferramentas", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn).lineLimit(2)
        case .starting:
            Label("Conectando…", systemImage: "hourglass").foregroundStyle(Palette.muted)
        case .stopped, nil:
            Label("Desligado", systemImage: "pause.circle").foregroundStyle(Palette.muted)
        }
    }
}

private struct ConnectorEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var connector: MCPServerConfig
    @State private var arguments = ""
    @State private var environment = ""

    private var isNew: Bool { !model.connectors.contains { $0.id == connector.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nome", text: $connector.name)
                TextField("Comando", text: $connector.command, prompt: Text("npx, uvx, /caminho/do/servidor"))
                Section {
                    TextEditor(text: $arguments).font(.body.monospaced()).frame(minHeight: 60)
                } header: {
                    Text("Argumentos (um por linha)")
                }
                Section {
                    TextEditor(text: $environment).font(.body.monospaced()).frame(minHeight: 44)
                } header: {
                    Text("Variáveis de ambiente (NOME=valor, uma por linha)")
                } footer: {
                    Text("O comando roda com o PATH do seu shell de login. As variáveis ficam no arquivo de dados do app, sem criptografia. Ferramentas de conectores pedem permissão no modo “Perguntar antes”.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Apagar", role: .destructive) {
                        model.connectors.removeAll { $0.id == connector.id }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Adicionar" : "Salvar", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connector.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || connector.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 500)
        .onAppear {
            arguments = connector.arguments.joined(separator: "\n")
            environment = connector.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private func save() {
        connector.arguments = lines(arguments)
        connector.environment = Dictionary(lines(environment).compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0].trimmingCharacters(in: .whitespaces), pair[1]) : nil
        }, uniquingKeysWith: { _, last in last })
        if let index = model.connectors.firstIndex(where: { $0.id == connector.id }) {
            model.connectors[index] = connector
        } else {
            model.connectors.append(connector)
        }
        dismiss()
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension MCPServerConfig {
    /// Well-known servers offered in the "Adicionar" menu.
    static let templates: [MCPServerConfig] = [
        MCPServerConfig(name: "Arquivos", command: "npx",
                        arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()]),
        MCPServerConfig(name: "Memória (grafo)", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
        MCPServerConfig(name: "Busca na web (Fetch)", command: "uvx", arguments: ["mcp-server-fetch"]),
        MCPServerConfig(name: "GitHub", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"],
                        environment: ["GITHUB_PERSONAL_ACCESS_TOKEN": ""]),
    ]

    func withNewID() -> MCPServerConfig {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

// MARK: Skills

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var editing: Skill?

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
            TableColumn("Usos") { skill in
                Text(skill.uses, format: .number).monospacedDigit()
            }
            .width(60)
        }
        .contextMenu(forSelectionType: Skill.ID.self) { ids in
            if let id = ids.first, let skill = model.skills.first(where: { $0.id == id }) {
                Button("Editar") { editing = skill }
                Button("Apagar", role: .destructive) { model.skills.removeAll { $0.id == id } }
            }
        } primaryAction: { ids in
            editing = ids.first.flatMap { id in model.skills.first { $0.id == id } }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .searchable(text: $query, prompt: "Buscar skills")
        .navigationTitle("Skills")
        .navigationSubtitle("Instruções reutilizáveis: comece a mensagem com /nome")
        .toolbar {
            Button("Nova skill", systemImage: "plus") {
                editing = Skill(slug: "", name: "", summary: "", instructions: "")
            }
        }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill)
        }
    }
}

private struct SkillEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill

    private var slugTaken: Bool { model.skills.contains { $0.slug == skill.slug && $0.id != skill.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nome", text: $skill.name)
                TextField("Atalho", text: $skill.slug, prompt: Text("ex.: resumir"))
                    .onChange(of: skill.slug) { skill.slug = Self.slugify(skill.slug) }
                TextField("O que faz", text: $skill.summary)
                Section {
                    TextEditor(text: $skill.instructions).font(.body).frame(minHeight: 140)
                } header: {
                    Text("Instruções para o bot")
                } footer: {
                    if slugTaken { Text("Já existe uma skill com /\(skill.slug).").foregroundStyle(Palette.warn) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    if let index = model.skills.firstIndex(where: { $0.id == skill.id }) {
                        model.skills[index] = skill
                    } else {
                        model.skills.append(skill)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skill.name.isEmpty || skill.slug.isEmpty || skill.instructions.isEmpty || slugTaken)
            }
            .padding(16)
        }
        .frame(width: 480, height: 500)
    }

    private static func slugify(_ text: String) -> String {
        String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(32))
    }
}
