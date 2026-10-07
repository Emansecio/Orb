import SwiftUI

/// Right-hand panel: who the bot is, what it may do, its workspace, memory and routines.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var isEditingOrb = false
    @State private var isPickingFolder = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingBypass = false

    var body: some View {
        if let bot = model.bot(botID) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        BotAvatar(bot: bot, size: 60, activity: model.activity(for: bot.id), poke: model.pokes[bot.id, default: 0],
                                  interactive: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bot.name)
                                .font(.system(size: 15, weight: .semibold))
                            Text(bot.role)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    ModelPicker(selection: binding(\.model, of: bot))
                }

                Section("Orb") {
                    LabeledContent("Cor", value: OrbCatalog.shared.label(.color, bot.orb.color))
                    LabeledContent("Olhos", value: OrbCatalog.shared.label(.eyes, bot.orb.eyes))
                    LabeledContent("Jeito", value: bot.orb.temperament.label)
                    if !bot.orb.accessories.isEmpty {
                        LabeledContent("Acessórios", value: bot.orb.accessories
                            .map { OrbCatalog.shared.label(.accessories, $0) }.joined(separator: ", "))
                    }
                    Button("Personalizar Orb…", systemImage: "paintpalette") { isEditingOrb = true }
                }

                Section {
                    Picker("Antes de agir", selection: binding(\.permissionMode, of: bot).confirmingBypass {
                        isConfirmingBypass = true
                    }) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    ForEach(Capability.allCases) { capability in
                        Toggle(isOn: capabilityBinding(capability, of: bot)) {
                            Label(capability.label, systemImage: capability.symbol)
                        }
                    }
                } header: {
                    Text("Permissões")
                } footer: {
                    Text(bot.permissionMode.summary)
                        .foregroundStyle(bot.permissionMode == .bypass ? Palette.warn : .secondary)
                }
                .bypassConfirmation(isPresented: $isConfirmingBypass) {
                    model.update(bot.id) { $0.permissionMode = .bypass }
                }

                Section {
                    LabeledContent("Pasta") {
                        Text(bot.workingURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Button("Escolher pasta…", systemImage: "folder") { isPickingFolder = true }
                    ForEach(bot.allowedTools.sorted(), id: \.self) { tool in
                        LabeledContent(tool) {
                            Button("Revogar") { model.update(bot.id) { $0.allowedTools.remove(tool) } }
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Trabalho")
                } footer: {
                    if !bot.allowedTools.isEmpty {
                        Text("Ações acima rodam sem perguntar (“Sempre permitir”).")
                    }
                }

                Section {
                    if bot.memory.isEmpty {
                        Text("Nada lembrado ainda.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bot.memory) { fact in
                        HStack {
                            Text(fact.text)
                            Spacer()
                            Button("Esquecer", systemImage: "xmark.circle.fill") {
                                model.update(bot.id) { $0.memory.removeAll { $0.id == fact.id } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Memória")
                } footer: {
                    Text("O que \(bot.name) aprendeu sobre você. Apague o que não quiser que ele lembre.")
                }

                Section("Rotinas") {
                    let routines = model.routines(for: bot.id)
                    if routines.isEmpty {
                        Text("Nenhuma rotina.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(routines) { routine in
                        LabeledContent(routine.name, value: routine.schedule.label)
                    }
                }

                Section {
                    Button("Apagar \(bot.name)…", role: .destructive) { isConfirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.update(bot.id) { $0.workingDirectory = url.path } }
            }
            .confirmationDialog("Apagar \(bot.name)?", isPresented: $isConfirmingDelete) {
                Button("Apagar bot e conversa", role: .destructive) { model.deleteBot(bot.id) }
            } message: {
                Text("A conversa, a memória e as rotinas deste bot serão apagadas.")
            }
            .sheet(isPresented: $isEditingOrb) {
                VStack(spacing: 0) {
                    OrbEditor(config: binding(\.orb, of: bot), name: bot.name)
                    HStack {
                        Spacer()
                        Button("Pronto") { isEditingOrb = false }
                            .buttonStyle(PrimaryPillStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(14)
                    .background(Palette.chrome)
                }
                .frame(width: 560, height: 720)
            }
            .background(Palette.chrome)
        }
    }

    /// Falls back to the last rendered value, so a sheet closing after deletion never reads a missing bot.
    private func binding<Value>(_ keyPath: WritableKeyPath<Bot, Value>, of bot: Bot) -> Binding<Value> {
        Binding(
            get: { model.bot(botID)?[keyPath: keyPath] ?? bot[keyPath: keyPath] },
            set: { value in model.update(botID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func capabilityBinding(_ capability: Capability, of bot: Bot) -> Binding<Bool> {
        Binding(
            get: { bot.capabilities.contains(capability) },
            set: { isOn in
                model.update(bot.id) {
                    if isOn { $0.capabilities.insert(capability) } else { $0.capabilities.remove(capability) }
                }
            }
        )
    }
}
