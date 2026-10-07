import SwiftUI

/// Right-hand panel: who the bot is, what it may do, its workspace, memory and routines.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var isEditingOrb = false

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
                    Picker("Modelo", selection: binding(\.model)) {
                        ForEach(Catalog.models, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Orb") {
                    LabeledContent("Cor", value: OrbCatalog.shared.label(.color, bot.orb.color))
                    LabeledContent("Olhos", value: OrbCatalog.shared.label(.eyes, bot.orb.eyes))
                    if !bot.orb.accessories.isEmpty {
                        LabeledContent("Acessórios", value: bot.orb.accessories
                            .map { OrbCatalog.shared.label(.accessories, $0) }.joined(separator: ", "))
                    }
                    Button("Personalizar Orb…", systemImage: "paintpalette") { isEditingOrb = true }
                }

                Section("Permissões") {
                    Picker("Antes de agir", selection: binding(\.permissionMode)) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    ForEach(Capability.allCases) { capability in
                        Toggle(isOn: capabilityBinding(capability, of: bot)) {
                            Label(capability.label, systemImage: capability.symbol)
                        }
                    }
                }

                Section("Mesa de trabalho") {
                    WorkspaceRow(name: "Desktop", used: 0.12)
                    WorkspaceRow(name: "Documentos", used: 0.34)
                    WorkspaceRow(name: "Downloads", used: 0.71)
                    WorkspaceRow(name: "Projetos", used: 0.48)
                    LabeledContent("Local") {
                        Text("~/OpenBot/\(bot.name)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
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
                        LabeledContent(routine.name, value: routine.schedule)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $isEditingOrb) {
                VStack(spacing: 0) {
                    OrbEditor(config: binding(\.orb), name: bot.name)
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

    private func binding<Value>(_ keyPath: WritableKeyPath<Bot, Value>) -> Binding<Value> {
        Binding(
            get: { model.bot(botID)![keyPath: keyPath] },
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

private struct WorkspaceRow: View {
    let name: String
    let used: Double

    var body: some View {
        LabeledContent {
            ProgressView(value: used)
                .frame(width: 90)
                .tint(used > 0.66 ? Palette.warn : Palette.muted)
        } label: {
            Label(name, systemImage: "folder")
        }
    }
}
