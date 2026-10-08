import SwiftUI

/// Right-hand panel: who the bot is, what it may do, its workspace, memory and routines.
struct BotInspector: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var isEditingOrb = false
    @State private var isPickingFolder = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingBypass = false
    @State private var isEditingIdentity = false
    @State private var identityDraft = ""
    /// The instruction file in the Orb's folder, if any (read off the main thread when the folder changes).
    @State private var instructionFile: FolderInstructions?

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
                    if let file = instructionFile {
                        // Claude Code loads CLAUDE.md by itself as the project's instructions: trusting it here would change nothing.
                        if !InstructionsText.claudeCodeReadsItself(file, usesClaudeCode: usesClaudeCode(bot)) {
                            Toggle(isOn: instructionsTrustBinding(file, of: bot)) {
                                Label("Confiar nas instruções desta pasta", systemImage: "checkmark.shield")
                            }
                        }
                        Button("Ver \(file.fileName) no Finder", systemImage: "doc.text.magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([bot.workingURL.appending(path: file.fileName)])
                        }
                    }
                    ForEach(bot.permissionRules, id: \.self) { rule in
                        LabeledContent {
                            Button("Revogar") { model.update(bot.id) { $0.permissionRules.removeAll { $0 == rule } } }
                                .controlSize(.small)
                        } label: {
                            Text(rule.title)
                        }
                    }
                    if bot.permissionRules.count > 1 {
                        Button("Revogar tudo", role: .destructive) { model.update(bot.id) { $0.permissionRules = [] } }
                            .controlSize(.small)
                    }
                } header: {
                    Text("Trabalho")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let file = instructionFile {
                            Text(InstructionsText.footer(for: file, name: bot.name, trustedHash: bot.trustedInstructionsHash,
                                                         usesClaudeCode: usesClaudeCode(bot)))
                        }
                        if !bot.permissionRules.isEmpty {
                            Text("Estas ações rodam sem perguntar em “Perguntar antes” (“Sempre permitir”). Comandos arriscados sempre perguntam.")
                        }
                    }
                }

                memorySection(bot)

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
            .task(id: bot.workingDirectory) {
                instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL)
            }
            // The file may have been edited while the panel stayed open: read it again on coming back to the app.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { instructionFile = await FolderInstructions.loadInBackground(from: bot.workingURL) }
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.update(bot.id) { $0.workingDirectory = url.path } }
            }
            .confirmationDialog("Apagar \(bot.name)?", isPresented: $isConfirmingDelete) {
                Button("Apagar o Orb e a memória", role: .destructive) { model.deleteBot(bot.id) }
                Button("Apagar o Orb e guardar a memória") { model.deleteBot(bot.id, keepMemory: true) }
            } message: {
                Text(DeleteOrbText.message)
            }
            .sheet(isPresented: $isEditingIdentity) {
                IdentityEditor(name: bot.name, text: $identityDraft) {
                    model.setIdentity(identityDraft, of: bot.id)
                    isEditingIdentity = false
                } cancel: {
                    isEditingIdentity = false
                }
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

    /// The Orb's own memory: identity notes, what it keeps (preferences, facts, procedures) and its conversations.
    @ViewBuilder
    private func memorySection(_ bot: Bot) -> some View {
        let memory = model.memories[bot.id] ?? MemorySnapshot()
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Identidade")
                    Spacer()
                    Button("Editar…") {
                        Task {
                            // From the file, not the panel's snapshot: the Orb may have added notes meanwhile.
                            identityDraft = await model.identityText(of: bot.id)
                            isEditingIdentity = true
                        }
                    }
                    .controlSize(.small)
                }
                Text(memory.identity.isEmpty ? "Ainda sem notas sobre como \(bot.name) deve funcionar."
                     : memory.identity.replacingOccurrences(of: "## ", with: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .truncationMode(.middle)
                if memory.identity.count > MemoryBank.identityShare {
                    Text("Longa: em cada conversa vão o começo e o fim (cerca de \(MemoryBank.identityShare) caracteres).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if memory.interviewPending {
                    Label("Vai te fazer perguntas nas primeiras mensagens", systemImage: "questionmark.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Fazer a entrevista de novo", systemImage: "questionmark.bubble") { model.restartInterview(of: bot.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Na próxima conversa, \(bot.name) faz algumas perguntas para entender como te ajudar")
                }
            }
            ForEach([MemoryKind.preferencia, .fato, .procedimento], id: \.self) { kind in
                ForEach(memory.items(kind)) { item in
                    MemoryRow(item: item) { model.forgetMemory(item.path, of: bot.id) }
                }
            }
            let sessions = memory.items(.sessao)
            if !sessions.isEmpty {
                DisclosureGroup("Conversas guardadas (\(sessions.count))") {
                    ForEach(sessions.prefix(30)) { item in
                        MemoryRow(item: item) { model.forgetMemory(item.path, of: bot.id) }
                    }
                    if sessions.count > 30 {
                        Text("E mais \(sessions.count - 30) na pasta da memória.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("Abrir pasta da memória", systemImage: "folder") {
                NSWorkspace.shared.open(model.memory.directory(for: bot.id))
            }
        } header: {
            Text("Memória")
        } footer: {
            Text(memory.items.isEmpty
                 ? "Memória só de \(bot.name). Começa a crescer na primeira conversa: preferências, fatos, procedimentos e um resumo de cada conversa (salvo depois de 30 minutos sem mensagens ou ao começar outra)."
                 : "Memória só de \(bot.name). São arquivos .md (dá para abrir no Obsidian); conversas antigas são compactadas, nunca apagadas sem você.")
        }
    }

    /// Falls back to the last rendered value, so a sheet closing after deletion never reads a missing bot.
    private func binding<Value>(_ keyPath: WritableKeyPath<Bot, Value>, of bot: Bot) -> Binding<Value> {
        Binding(
            get: { model.bot(botID)?[keyPath: keyPath] ?? bot[keyPath: keyPath] },
            set: { value in model.update(botID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func usesClaudeCode(_ bot: Bot) -> Bool { model.modelRef(for: bot)?.provider == .claudeCode }

    /// On remembers the hash of the file as it is on disk right now, not as the panel last showed it: what the user
    /// trusts is what the next turn will read. If the file changed, the toggle shows off again.
    private func instructionsTrustBinding(_ file: FolderInstructions, of bot: Bot) -> Binding<Bool> {
        Binding(
            get: { file.isTrusted(by: model.bot(botID)?.trustedInstructionsHash) },
            set: { isOn in
                let current = FolderInstructions.load(from: bot.workingURL)
                instructionFile = current
                model.update(bot.id) { $0.trustedInstructionsHash = isOn ? current?.hash : nil }
            }
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

enum InstructionsText {
    /// CLAUDE.md in the folder of an Orb that runs on Claude Code: Claude Code reads it as instructions on its own.
    static func claudeCodeReadsItself(_ file: FolderInstructions, usesClaudeCode: Bool) -> Bool {
        usesClaudeCode && file.fileName == "CLAUDE.md"
    }

    static func footer(for file: FolderInstructions, name: String, trustedHash: String?, usesClaudeCode: Bool = false) -> String {
        if claudeCodeReadsItself(file, usesClaudeCode: usesClaudeCode) {
            return "\(file.fileName) é lido pelo próprio Claude Code como instruções do projeto."
        }
        if file.isTrusted(by: trustedHash) { return "\(file.fileName) vale como instruções de \(name) nesta pasta." }
        if trustedHash != nil {
            return "\(file.fileName) mudou desde que você confiou nele: \(name) o lê só como referência, até você confiar de novo."
        }
        return "\(file.fileName) é lido por \(name) como material de referência, não como ordens. Confie para valer como instruções."
    }
}

/// What the delete dialogs say: the choice is whether the Orb's memory goes with it.
enum DeleteOrbText {
    static let message = "A conversa e as rotinas deste Orb serão apagadas. A memória dele pode ir junto ou ficar guardada em memoria/_guardadas, na pasta de dados do app (Ajustes → Geral → Mostrar no Finder)."
}

private struct MemoryRow: View {
    let item: MemorySnapshot.Item
    let forget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .sessao || item.title == item.body ? item.title : item.body)
                    .lineLimit(item.kind == .sessao ? 1 : 3)
                Text(item.kind == .sessao
                     ? MemoryBank.dayFormat.string(from: item.date) + (item.compacted ? " · compactada" : "")
                     : item.kind.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Esquecer", systemImage: "xmark.circle.fill", action: forget)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Esquecer (apaga de vez)")
                .accessibilityLabel("Esquecer: \(item.title)")
        }
    }
}

/// Edits the Orb's identity notes: how it should work, in your words.
private struct IdentityEditor: View {
    let name: String
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Identidade de \(name)")
                .font(.headline)
            Text("Como \(name) deve funcionar com você. Vai em toda conversa; o que ele aprender na entrevista entra em “Como funcionar”. ⌘↩ salva.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                // Return adds a line in the editor; ⌘↩ saves.
                Button("Salvar", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
