import SwiftUI
import UniformTypeIdentifiers

// "Importar de outro assistente", inside the new-Orb sheet (it takes the place of the form while it is open): the prompt
// to copy, the answer to paste or drop, and a preview with a checkbox per item. Nothing is created here; the sheet
// keeps what was confirmed and "Criar Orb" writes it (`AppModel.createBot(importing:)`).

/// Fixed words of the import, shared by the panel, the sheet and the tests.
enum ImportText {
    static let title = "Importar de outro assistente"
    static let hint = "Traga o que o ChatGPT, o Gemini ou outro assistente já sabe de você."
    static let confirm = "Usar esta importação"
    static let notCreatedYet = "Nada foi criado ainda."
    static let suspicious = "Revise: parece dar ordens ao Orb"
    static let overflow = "O texto inteiro vai para a memória e é consultado quando precisa."

    /// What reading left out of long instructions.
    static func omitted(_ count: Int) -> String {
        "Passa do limite de leitura: os últimos \(count) caracteres ficam de fora."
    }

    /// The VoiceOver line once a reading is done.
    static func announcement(_ imported: OrbImport) -> String {
        let counts = imported.plan().summary
        return "Li a importação. \(counts.isEmpty ? ImportText.nothingChecked : counts + ".") Confira a prévia."
    }

    static let nothingChecked = "Nada marcado para importar."

    /// "ChatGPT · 1 instrução, 9 lembranças, 2 skills".
    static func summary(_ imported: OrbImport) -> String {
        let counts = imported.plan().summary
        return counts.isEmpty ? imported.source : "\(imported.source) · \(counts)"
    }
}

struct ImportPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The preview being reviewed; nil until something is read.
    @Binding var draft: OrbImport?
    let onBack: () -> Void

    @State private var pasted = ""
    @State private var error: String?
    @State private var isReading = false
    @State private var reading: Task<Void, Never>?
    @State private var copied = CopiedFlash()
    @State private var isPicking = false
    @State private var isTargeted = false
    @State private var locals: [LocalAssistant] = []
    /// Whether the preview came from the pasted text: emptying the text takes it away, a file's or folder's stays.
    @State private var draftIsFromText = false

    private static let previewID = "preview"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    promptStep
                    answerStep
                    if let draft {
                        ImportPreview(imported: Binding(get: { draft }, set: { self.draft = $0 }), onKind: { read(text: draft.freeText, asInstructions: $0) })
                            .id(Self.previewID)
                            .transition(.adapted(.rise, reduceMotion: reduceMotion))
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic)
            .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: draft != nil)
            // A short window shows the prompt and the answer first: the preview must come into view when it is ready.
            .onChange(of: draft != nil) {
                guard draft != nil else { return }
                withAnimation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion)) { proxy.scrollTo(Self.previewID, anchor: .top) }
            }
            .task { // "Revisar" comes back to a preview that already exists
                guard draft != nil else { return }
                await Task.yield()
                proxy.scrollTo(Self.previewID, anchor: .top)
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(Palette.chrome.opacity(0.85), in: .rect(cornerRadius: 12))
                    .overlay { Text("Solte para importar").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink) }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            read(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.plainText, .json, .folder, UTType(filenameExtension: "md") ?? .plainText]) { result in
            if case .success(let url) = result { read(url) }
        }
        .task { // only if they exist, and never in a developer run
            guard model.readsRealMac else { return }
            locals = await Task.detached(priority: .utility) { OrbImportReader.detectLocal() }.value
        }
        .onChange(of: pasted) {
            readSoon()
        }
    }

    // MARK: Steps

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onBack) {
                Label("Voltar", systemImage: "chevron.left").font(.system(size: 12))
            }
            .buttonStyle(GhostStyle())
            .help(Tip.importBack)
            Text(ImportText.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var promptStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepLabel("1. Peça um arquivo a ele")
            Text("Copie este prompt e cole no ChatGPT, Gemini, Claude, Copilot ou no assistente que já conhece você.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: copyPrompt) {
                ZStack {
                    Text("Copiar prompt").opacity(copied.isOn ? 0 : 1)
                    Text("Copiado ✓").opacity(copied.isOn ? 1 : 0)
                }
                .animation(Motion.press, value: copied.isOn)
            }
            .buttonStyle(SecondaryPillStyle())
            .help(Tip.importCopyPrompt)
            DisclosureGroup("Ver o prompt") {
                ScrollView {
                    Text(ImportPrompt.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(Palette.raised, in: .rect(cornerRadius: 8))
            }
            .font(.system(size: 12))
            Text("Num GPT, Gem ou Projeto, cole o prompt dentro dele. Se ele não mostrar as instruções, copie o texto da tela de configuração e cole abaixo.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var answerStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepLabel("2. Traga a resposta")
            PlaceholderTextEditor(placeholder: "Cole aqui a resposta do assistente", text: $pasted, minHeight: 110)
            HStack(spacing: 8) {
                Button("Escolher arquivo…") { isPicking = true }
                    .buttonStyle(SecondaryPillStyle())
                    .help(Tip.importChooseFile)
                Text("ou solte um arquivo ou pasta aqui")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                Spacer(minLength: 0)
                ZStack {
                    if isReading { DelayedSpinner().transition(.opacity) }
                }
                .motion(Motion.content, value: isReading)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
            if !locals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Neste Mac").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                    ForEach(locals) { local in
                        HStack {
                            Text("\(local.name) · \(local.display)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Ler") { read(local.url) }.buttonStyle(GhostStyle())
                                .help(Tip.importReadLocal)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: error)
    }

    // MARK: Reading

    private func copyPrompt() {
        Clipboard.copy(ImportPrompt.text)
        copied.trigger(animation: Motion.press)
    }

    /// Pasting reads by itself, a moment after the last change.
    private func readSoon() {
        reading?.cancel()
        let text = pasted
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isReading = false
            error = nil
            if draftIsFromText { draft = nil }
            return
        }
        reading = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await load(fromText: true) { try OrbImportReader.read(text: text) }
        }
    }

    /// The same text read the other way (instructions or memories): it comes from where the preview came from.
    private func read(text: String, asInstructions: Bool) {
        reading?.cancel()
        reading = Task { await load(fromText: draftIsFromText) { try OrbImportReader.read(text: text, asInstructions: asInstructions) } }
    }

    /// A file, a folder, or the pasted text: read off the main thread.
    private func read(_ url: URL) {
        reading?.cancel()
        reading = Task {
            await load(fromText: false) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try OrbImportReader.read(file: url)
            }
        }
    }

    private func load(fromText: Bool, _ work: @escaping @Sendable () throws -> OrbImport) async {
        isReading = true
        let outcome = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
        guard !Task.isCancelled else { return }
        isReading = false
        switch outcome {
        case .success(let found):
            error = nil
            draft = found
            draftIsFromText = fromText
            AccessibilityNotification.Announcement(ImportText.announcement(found)).post()
        case .failure(let failure):
            draft = nil
            error = (failure as? ImportFailure ?? .unrecognized).errorDescription
        }
    }
}

private struct StepLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Preview

/// What would be imported, each item with a checkbox. Items that look like orders to the Orb start unchecked.
private struct ImportPreview: View {
    @Binding var imported: OrbImport
    let onKind: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        let plan = imported.plan()
        VStack(alignment: .leading, spacing: 10) {
            StepLabel("3. Prévia")
            VStack(alignment: .leading, spacing: 2) {
                Text("De: \(imported.source)").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                let who = [imported.name, imported.role].filter { !$0.isEmpty }.joined(separator: " · ")
                if !who.isEmpty { Text(who).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                Text(plan.isEmpty ? ImportText.nothingChecked : "Vai importar: \(plan.summary)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
            }
            if imported.isFreeText {
                Picker("Isto é", selection: Binding(get: { imported.asInstructions }, set: { kind in MainActor.assumeIsolated { onKind(kind) } })) {
                    Text("Instruções do assistente").tag(true)
                    Text("Lembranças sobre você").tag(false)
                }
                .pickerStyle(.segmented)
                .help(Tip.importKind)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                if imported.identity != nil {
                    ImportGroup("Como funciona", count: nil) {
                        ImportRow(item: Binding(get: { imported.identity ?? ImportItem("") }, set: { imported.identity = $0 }), lines: nil)
                        if let identity = imported.identity {
                            if identity.text.count > ImportLimits.identity {
                                Text(ImportText.overflow).font(.system(size: 11)).foregroundStyle(Palette.faint)
                            }
                            if identity.omitted > 0 {
                                Text(ImportText.omitted(identity.omitted)).font(.system(size: 11)).foregroundStyle(Palette.warn)
                            }
                        }
                    }
                }
                group("Preferências", $imported.preferences)
                group("Sobre você", $imported.facts)
                group("Procedimentos", $imported.procedures)
                if !imported.skills.isEmpty {
                    ImportGroup("Skills", count: imported.skills.count) {
                        ForEach($imported.skills) { $skill in ImportSkillRow(skill: $skill) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: Binding<[ImportItem]>) -> some View {
        if !items.wrappedValue.isEmpty {
            ImportGroup(title, count: items.wrappedValue.count) {
                ForEach(items) { $item in ImportRow(item: $item, lines: 2) }
            }
        }
    }
}

private struct ImportGroup<Content: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let content: Content
    @State private var isExpanded = true

    init(_ title: String, count: Int?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Full width, so every checkbox of every group sits in the same column.
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(count.map { "\(title) (\($0))" } ?? title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
        }
    }
}

private struct ImportRow: View {
    @Binding var item: ImportItem
    /// nil shows the whole text (the identity).
    let lines: Int?

    var body: some View {
        Toggle(isOn: $item.isOn) {
            VStack(alignment: .leading, spacing: 2) {
                if !item.title.isEmpty { Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink) }
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
                if item.isSuspicious {
                    Text(ImportText.suspicious).font(.system(size: 11)).foregroundStyle(Palette.warn)
                }
            }
        }
        .toggleStyle(.checkbox)
        .help(Tip.importItem)
        .accessibilityElement(children: .combine)
    }
}

private struct ImportSkillRow: View {
    @Binding var skill: ImportSkill
    @State private var isShowing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Toggle(isOn: $skill.isOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(skill.slug)").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                        Text(skill.summary).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                        if skill.isSuspicious {
                            Text(ImportText.suspicious).font(.system(size: 11)).foregroundStyle(Palette.warn)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .help(Tip.importItem)
                Spacer(minLength: 4)
                Button(isShowing ? "Ocultar" : "Ver") { isShowing.toggle() }
                    .buttonStyle(GhostStyle())
                    .help(Tip.importToggleSkill(isShowing: isShowing))
            }
            if isShowing {
                Text(skill.instructions)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.raised, in: .rect(cornerRadius: 8))
                    .transition(.opacity)
            }
        }
        .animation(Motion.content, value: isShowing)
    }
}

// MARK: - In the form

/// What the "Começar de" section shows once an import is confirmed: where it came from and what it holds, with the two
/// ways out.
struct ImportSummaryRow: View {
    let imported: OrbImport
    let review: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").foregroundStyle(Palette.muted)
                Text(ImportText.summary(imported))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Button("Revisar", action: review).buttonStyle(GhostStyle())
                    .help(Tip.importReview)
                Button("Remover", action: remove).buttonStyle(GhostStyle())
                    .help(Tip.importRemove)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
