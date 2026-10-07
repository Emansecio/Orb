import SwiftUI
import AppKit
import ServiceManagement

// MARK: New bot

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var role = ""
    @State private var orb = OrbConfig.random()
    @State private var modelName = ""
    @State private var mode: PermissionMode = .ask

    var body: some View {
        HStack(spacing: 0) {
            OrbEditor(config: $orb, name: name)
                .frame(width: 520)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                Form {
                    Section("Bot") {
                        TextField("Nome", text: $name)
                        TextField("Papel", text: $role, prompt: Text("Ex.: Cuida da minha agenda"))
                    }
                    Section("Inteligência") {
                        ModelPicker(selection: $modelName)
                        Picker("Antes de agir", selection: $mode) {
                            ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(GhostStyle())
                    Button("Criar bot") {
                        model.createBot(name: name.trimmingCharacters(in: .whitespaces),
                                        role: role.isEmpty ? "Assistente pessoal" : role,
                                        orb: orb, model: modelName, mode: mode)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .frame(width: 300)
            .background(Palette.chrome)
        }
        .frame(height: 740)
    }
}

// MARK: Menu bar quick ask

struct QuickAskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var botID: UUID?
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(model.bots) { bot in
                    Button {
                        botID = bot.id
                    } label: {
                        BotAvatar(bot: bot, size: 28, activity: model.activity(for: bot.id))
                            .opacity(selectedID == bot.id ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .help(bot.name)
                }
            }
            TextField("Pergunte a \(model.bot(selectedID ?? UUID())?.name ?? "um bot")…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(send)
                .padding(10)
                .card(radius: 10)

            let working = model.bots.filter { model.isWorking($0.id) }
            if !working.isEmpty {
                Divider()
                ForEach(working) { bot in
                    HStack(spacing: 8) {
                        BotAvatar(bot: bot, size: 18, activity: model.activity(for: bot.id))
                        Text("\(bot.name): \(model.statusLine[bot.id] ?? "")…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Abrir OpenBot") { openMain() }
                Spacer()
                Text("↩ envia")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private var selectedID: UUID? { botID ?? model.selectedBot?.id ?? model.bots.first?.id }

    private func send() {
        guard let id = selectedID, !model.isWorking(id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(text, to: id)
        model.selection = .bot(id)
        text = ""
        openMain()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            ProviderSettings()
                .tabItem { Label("Modelos", systemImage: "cpu") }
            GeneralSettings()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            PermissionSettings()
                .tabItem { Label("Permissões do Mac", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 600)
    }
}

private struct GeneralSettings: View {
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Abrir ao iniciar sessão", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(Palette.warn)
            }
            Toggle("Avisar quando um bot terminar ou precisar de mim", isOn: $notifyWhenDone)
            LabeledContent("Dados") {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.standard.directory]) }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Não foi possível mudar: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct PermissionSettings: View {
    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Automação", detail: "Para usar Mail, Calendário, Notas e outros apps (AppleScript)",
                              pane: "Privacy_Automation")
                PermissionRow(title: "Acesso Total ao Disco", detail: "Opcional: para ler pastas protegidas como Mail e Mensagens",
                              pane: "Privacy_AllFiles")
            } footer: {
                Text("O macOS pede cada permissão no primeiro uso. Você pode revisar ou revogar aqui.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let pane: String

    var body: some View {
        LabeledContent {
            Button("Abrir Ajustes") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
