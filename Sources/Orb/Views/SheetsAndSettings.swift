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
    @State private var identity = ""
    @State private var interview = true
    @State private var mode: PermissionMode = .ask
    @State private var isConfirmingBypass = false
    @State private var folder = OrbFolderChoice.own

    var body: some View {
        HStack(spacing: 0) {
            OrbEditor(config: $orb, name: name)
                .frame(width: 520)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                Form {
                    Section("Orb") {
                        TextField("Nome", text: $name)
                        TextField("Papel", text: $role, prompt: Text("Ex.: Cuida da minha agenda"))
                    }
                    Section {
                        TextField("Como deve funcionar", text: $identity,
                                  prompt: Text("Ex.: Seja direto, cuide da minha agenda de trabalho e me lembre de fazer pausas."),
                                  axis: .vertical)
                            .lineLimit(3...6)
                        Toggle("Na primeira conversa, me fazer perguntas", isOn: $interview)
                    } header: {
                        Text("Identidade")
                    } footer: {
                        Text("Fica na memória deste Orb, que começa a crescer a partir da primeira conversa. Dá para editar depois no painel.")
                    }
                    NewBotFolderSection(name: name, choice: $folder)
                    Section("Inteligência") {
                        ModelPicker(selection: $modelName)
                        Picker("Antes de agir", selection: $mode.confirmingBypass { isConfirmingBypass = true }) {
                            ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                        }
                        .bypassConfirmation(isPresented: $isConfirmingBypass) { mode = .bypass }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(GhostStyle())
                    Button("Criar Orb") {
                        model.createBot(name: name.trimmingCharacters(in: .whitespaces),
                                        role: role.isEmpty ? "Assistente pessoal" : role,
                                        orb: orb, model: modelName, mode: mode, identity: identity, interview: interview,
                                        folder: folder)
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

/// Where the new Orb will work: by default a folder of its own in ~/Orbs, named after it.
private struct NewBotFolderSection: View {
    let name: String
    @Binding var choice: OrbFolderChoice
    @State private var isPicking = false

    var body: some View {
        Section {
            LabeledContent("Vai morar em") {
                Text(shownPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Escolher outra pasta…", systemImage: "folder") { isPicking = true }
            if choice != .home {
                Button("Usar a pasta pessoal", systemImage: "house") { choice = .home }
            }
            if choice != .own {
                Button("Criar pasta própria em ~/Orbs", systemImage: "folder.badge.plus") { choice = .own }
            }
        } header: {
            Text("Pasta de trabalho")
        } footer: {
            Text(footer)
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choice = .existing(url) }
        }
    }

    private var shownPath: String {
        switch choice {
        case .own:
            name.trimmingCharacters(in: .whitespaces).isEmpty
                ? "~/Orbs/…"
                : OrbFolder.display(OrbFolder.availableURL(for: name, in: OrbFolder.defaultBase))
        case .home: "~ (pasta pessoal)"
        case .existing(let url): OrbFolder.display(url)
        }
    }

    private var footer: String {
        switch choice {
        case .own: "A pasta é criada com o Orb. Dentro dela ele escreve sem perguntar em “Perguntar antes”; ele pode usar o Mac todo quando a tarefa pedir."
        case .home: "Sem pasta própria, em “Perguntar antes” ele pergunta antes de escrever. Dá para criar uma depois, no painel."
        case .existing: "Esta pasta é usada como está: nada é criado nem apagado nela."
        }
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
            PendingApprovalsSection()
            HStack(spacing: 6) {
                ForEach(model.botIDs, id: \.self) { id in
                    QuickAskOrbButton(botID: id, selectedID: selectedID, chosen: $botID)
                }
            }
            TextField("Pergunte a \(selectedID.flatMap { model.liveBot($0)?.look.name } ?? "um Orb")…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(send)
                .padding(10)
                .card(radius: 10)

            if !model.workingIDs.isEmpty {
                Divider()
                ForEach(model.workingIDs, id: \.self) { id in
                    QuickAskWorkingRow(botID: id)
                }
            }
            HStack {
                Button("Abrir o app") { openMain() }
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

    private var selectedID: UUID? {
        if let botID { return botID }
        if case .bot(let id) = model.selection, model.botIDs.contains(id) { return id }
        return model.botIDs.first
    }

    private func send() {
        guard let id = selectedID, !model.isWorking(id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.sendWhenLoaded(text, to: id)
        model.selection = .bot(id)
        text = ""
        openMain()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// One Orb's avatar in the menu bar panel. Reads its own Orb only: another Orb's status does not redraw it.
private struct QuickAskOrbButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let selectedID: UUID?
    @Binding var chosen: UUID?

    var body: some View {
        let live = model.live(botID)
        Button { chosen = botID } label: {
            // Only the chosen Orb and those with something going on move; the rest rest (no frames).
            BotAvatar(orb: live.look.orb, size: 28, activity: live.activity,
                      paused: selectedID != botID && live.activity == .idle)
                .opacity(selectedID == botID ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .help(live.look.name)
    }
}

/// A working Orb's line in the menu bar panel: its avatar and what it is doing.
private struct QuickAskWorkingRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let live = model.live(botID)
        HStack(spacing: 8) {
            BotAvatar(orb: live.look.orb, size: 18, activity: live.activity)
            Text("\(live.look.name): \(live.status ?? "")…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Every Orb's open approval cards, answerable from the menu bar without opening the app.
private struct PendingApprovalsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.pendingApprovals
        if !pending.isEmpty {
            // Scrolls past a height, so several waiting Orbs do not push the question field off the panel.
            ViewThatFits(in: .vertical) {
                cards(pending)
                ScrollView { cards(pending) }
                    .frame(maxHeight: 280)
            }
        }
    }

    private func cards(_ pending: [PendingApproval]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pending) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        BotAvatar(orb: entry.bot.orb, size: 18, activity: model.live(entry.bot.id).activity)
                        Text(entry.bot.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text("precisa de você")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.request.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(entry.request.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Button("Não permitir") {
                            model.decide(.deny, approvalID: entry.request.id, botID: entry.bot.id)
                        }
                        .buttonStyle(GhostStyle())
                        Spacer()
                        Button(entry.request.isBatch ? "Permitir as \(entry.request.items.count)" : "Permitir") {
                            model.decide(.once, approvalID: entry.request.id, botID: entry.bot.id)
                        }
                        .buttonStyle(PrimaryPillStyle())
                    }
                }
                .padding(10)
                .card(radius: 10, stroke: Palette.lineStrong)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(entry.bot.name) precisa da sua permissão")
            }
        }
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
            MacPermissionsView()
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
            Toggle("Avisar quando um Orb terminar ou precisar de mim", isOn: $notifyWhenDone)
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
