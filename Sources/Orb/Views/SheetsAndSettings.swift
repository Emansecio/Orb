import SwiftUI
import AppKit

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
    @State private var isShowingAdvanced = false
    @State private var folder = OrbFolderChoice.own
    @FocusState private var isNameFocused: Bool
    /// The window's height less a margin when the window is short (the form scrolls then).
    @State private var height: CGFloat

    /// `height`: a fixed sheet height (review snapshots of a short window); by default it follows the window.
    init(height: CGFloat? = nil) {
        _height = State(initialValue: height ?? NewBotSheetLayout.height())
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why "Criar Orb" waits, or a gentle note; nil when there is nothing to say.
    private var hint: String? {
        if trimmedName.isEmpty { return "Dê um nome ao Orb para criar." }
        if folder == .own, model.bots.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return "Já existe um Orb com esse nome. A pasta ganha outro nome."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                form
                    .frame(width: 380)
                    .background(Palette.chrome)
                    // The form comes in after the sheet, the footer after the form (MOVIMENTO.md §2.6). The editor
                    // on the right is the Orb editor's own (it brings its stage in itself).
                    .sheetSection(0)
                Divider().overlay(Palette.line)
                // Compact: the form beside it already shows the name, and the options need the height.
                OrbEditor(config: $orb, name: name, compact: true)
                    .frame(width: 440)
            }
            SheetFooter(message: hint, cancel: { dismiss() }, primaryTitle: "Criar Orb",
                        isPrimaryDisabled: trimmedName.isEmpty, primary: create)
                .background(Palette.chrome)
                .sheetSection(1)
        }
        .frame(width: 820, height: height)
        .task { isNameFocused = true }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Nome", text: $name, prompt: Text("Ex.: Atlas"))
                    .focused($isNameFocused)
                TextField("Papel", text: $role, prompt: Text("Ex.: Cuida da minha agenda"))
            } header: {
                Text("Quem é")
            }
            Section {
                ModelPicker(selection: $modelName)
            } header: {
                Text("Inteligência")
            }
            NewBotFolderSection(name: name, choice: $folder)
            Section {
                DisclosureGroup("Opções avançadas", isExpanded: $isShowingAdvanced) {
                    Picker("Permissões", selection: $mode.confirmingBypass { isConfirmingBypass = true }) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .bypassConfirmation(isPresented: $isConfirmingBypass) { mode = .bypass }
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundStyle(mode == .bypass ? Palette.warn : .secondary)
                    TextField("Como funciona", text: $identity,
                              prompt: Text("Ex.: Seja direto e me lembre de fazer pausas"), axis: .vertical)
                        .lineLimit(3...6)
                    Toggle("Na primeira conversa, me fazer perguntas", isOn: $interview)
                    Text("Isso fica na memória do Orb, que começa a crescer na primeira conversa. Dá para editar depois, no painel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        model.createBot(name: trimmedName,
                        role: role.isEmpty ? "Assistente pessoal" : role,
                        orb: orb, model: modelName, mode: mode, identity: identity, interview: interview,
                        folder: folder)
        dismiss()
    }
}

/// Where the new Orb will work: by default a folder of its own in ~/Orbs, named after it.
private struct NewBotFolderSection: View {
    let name: String
    @Binding var choice: OrbFolderChoice
    @State private var isPicking = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Text(shownPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(shownPath)
                Spacer(minLength: 4)
                Menu("Mudar…") {
                    Button("Escolher outra pasta…", systemImage: "folder") { isPicking = true }
                    if choice != .home {
                        Button("Usar a pasta pessoal", systemImage: "house") { choice = .home }
                    }
                    if choice != .own {
                        Button("Criar pasta própria em ~/Orbs", systemImage: "folder.badge.plus") { choice = .own }
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
        } header: {
            Text("Pasta")
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
        case .own: "Uma pasta só dele, criada com o Orb. Dentro dela ele escreve sem perguntar em “Perguntar antes”."
        case .home: "Sem pasta própria, em “Perguntar antes” ele pergunta antes de escrever. Dá para criar uma depois, no painel."
        case .existing: "Esta pasta é usada como está: nada é criado nem apagado nela."
        }
    }
}
