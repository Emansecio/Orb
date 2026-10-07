import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: New bot

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var role = ""
    @State private var orb = OrbConfig.random()
    @State private var modelName = Catalog.models[0]
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
                        Picker("Modelo", selection: $modelName) {
                            ForEach(Catalog.models, id: \.self) { Text($0).tag($0) }
                        }
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
        guard let id = selectedID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
            GeneralSettings()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            ProviderSettings()
                .tabItem { Label("Provedores", systemImage: "cpu") }
            PermissionSettings()
                .tabItem { Label("Permissões do Mac", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @AppStorage("pauseIdleRoutines") private var pauseIdleRoutines = true

    var body: some View {
        Form {
            Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
            Toggle("Avisar quando um bot terminar ou precisar de mim", isOn: $notifyWhenDone)
            Toggle("Pausar rotinas que ninguém está lendo", isOn: $pauseIdleRoutines)
            LabeledContent("Atalho rápido", value: "⌥ Espaço")
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettings: View {
    @AppStorage("compatBaseURL") private var compatBaseURL = "http://127.0.0.1:11434/v1"
    // Keys stay in memory in this prototype; the real app stores them in the Keychain.
    @State private var xaiKey = ""
    @State private var openAIKey = ""
    @State private var compatKey = ""

    var body: some View {
        Form {
            Section("xAI (Grok)") {
                SecureField("Chave de API", text: $xaiKey)
            }
            Section("OpenAI") {
                SecureField("Chave de API", text: $openAIKey)
            }
            Section {
                TextField("URL base", text: $compatBaseURL)
                SecureField("Chave (opcional)", text: $compatKey)
            } header: {
                Text("Compatível com OpenAI")
            } footer: {
                Text("Ollama, LM Studio, OpenRouter… No app final as chaves ficam no Keychain do macOS.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Acessibilidade", detail: "Para clicar e digitar por você",
                              granted: accessibility, pane: "Privacy_Accessibility")
                PermissionRow(title: "Gravação de Tela", detail: "Para ver o que está na tela",
                              granted: screenRecording, pane: "Privacy_ScreenCapture")
                PermissionRow(title: "Automação", detail: "Para usar Mail, Calendário e Notas",
                              granted: nil, pane: "Privacy_Automation")
            } footer: {
                Text("Só é necessário para os bots com “Controlar o Mac” ou apps conectados ativados.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accessibility = AXIsProcessTrusted()
            screenRecording = CGPreflightScreenCaptureAccess()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool?
    let pane: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                switch granted {
                case .some(true):
                    Label("Permitido", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                case .some(false):
                    Label("Não permitido", systemImage: "exclamationmark.circle").foregroundStyle(Palette.warn)
                case .none:
                    Label("Pedido no primeiro uso", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Button("Abrir Ajustes") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .font(.caption)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
