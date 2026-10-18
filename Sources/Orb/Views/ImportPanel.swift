import SwiftUI
import UniformTypeIdentifiers

// "Importar de outro assistente", inside the new-Orb sheet (it takes the place of the form while it is open): the prompt
// to copy, the answer to paste or drop, and a preview with a checkbox per item. Nothing is created here; the sheet
// keeps what was confirmed and "Criar Orb" writes it (`AppModel.createBot(importing:)`).

/// Fixed words of the import, shared by the panel, the sheet and the tests.
enum ImportText {
    static let title = "Importar de outro assistente"
    static let fromMarketplace = "Importar um bot do Grok Bot ou de outro assistente"
    static let hint = "Traga o que o ChatGPT ou o Gemini já sabe de você, ou um bot pronto do marketplace do Grok Bot."
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

/// Where an import comes from: another assistant's answer (or file), or a bot of the Grok Bot marketplace by its link.
enum ImportSource: String, CaseIterable, Identifiable {
    case assistant, marketplace

    var id: Self { self }

    var label: String {
        switch self {
        case .assistant: "Outro assistente"
        case .marketplace: "Marketplace do Grok Bot"
        }
    }

    /// Whether `imported` was read from this source.
    func made(_ imported: OrbImport) -> Bool { imported.link.isEmpty == (self == .assistant) }

    /// The source the panel opens on: the one that made the preview it comes back to ("Revisar"), whichever it was;
    /// without a preview, the source it was asked to open on.
    static func opening(draft: OrbImport?, default fallback: ImportSource) -> ImportSource {
        guard let draft else { return fallback }
        return draft.link.isEmpty ? .assistant : .marketplace
    }
}

/// What the panel does once a change of source has stopped the old source's reading and cleared what was not its own.
enum ImportSourceSwitch {
    struct Action: Equatable {
        /// A file dropped on the panel while the other source was showing: read it now, after the reset that would have cancelled it.
        var readsDrop: URL?
        /// The pasted text (or the link) the field still holds, with no preview to show for it: read it again.
        var rereadsText = false
        var rereadsLink = false
    }

    static func after(switchingTo source: ImportSource, pasted: String, link: String, hasDraft: Bool, pendingDrop: URL?) -> Action {
        if let pendingDrop, source == .assistant { return Action(readsDrop: pendingDrop) }
        guard !hasDraft else { return Action() }
        switch source {
        case .assistant: return Action(rereadsText: !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .marketplace: return Action(rereadsLink: !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The marketplace page being read, for the spinner on its row. Each reading holds a token: one that is cancelled after a
/// newer reading of the same page began must not clear that newer reading's spinner.
struct LinkReading: Equatable {
    private(set) var page: String?
    private var current = 0

    /// Starts reading `page`; the token is what `end` needs to clear it.
    mutating func begin(_ page: String) -> Int {
        current += 1
        self.page = page
        return current
    }

    /// Ends the reading that holds `token`; an older one's end leaves the newer reading as it is.
    mutating func end(_ token: Int) {
        if token == current { page = nil }
    }

    /// Whoever stopped the reading (another source, an empty field) clears it, whichever it is.
    mutating func clear() {
        current += 1
        page = nil
    }
}

struct ImportPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The preview being reviewed; nil until something is read.
    @Binding var draft: OrbImport?
    let onBack: () -> Void

    @State private var source: ImportSource
    @State private var pasted = ""
    @State private var link = ""
    @State private var error: String?
    @State private var isReading = false
    /// The marketplace page being read (from the gallery or the link field), for the spinner on its row.
    @State private var linkReading = LinkReading()
    private var readingLink: String? { linkReading.page }
    @State private var reading: Task<Void, Never>?
    /// A file dropped while the other source was showing, read once the panel has switched to the assistant source.
    @State private var pendingDrop: URL?
    @State private var copied = CopiedFlash()
    @State private var isPicking = false
    @State private var isTargeted = false
    @State private var locals: [LocalAssistant] = []
    /// Whether the preview came from the pasted text: emptying the text takes it away, a file's or folder's stays.
    @State private var draftIsFromText = false

    init(draft: Binding<OrbImport?>, opensOn: ImportSource = .assistant, onBack: @escaping () -> Void) {
        _draft = draft
        _source = State(initialValue: opensOn)
        self.onBack = onBack
    }

    private static let previewID = "preview"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sourcePicker
                    switch source {
                    case .assistant:
                        promptStep
                        answerStep
                    case .marketplace:
                        marketplaceStep
                    }
                    if let draft, source.made(draft) {
                        ImportPreview(imported: Binding(get: { draft }, set: { self.draft = $0 }), step: source == .assistant ? 3 : 2,
                                      onKind: { read(text: draft.freeText, asInstructions: $0) })
                            .id(Self.previewID)
                            .transition(.adapted(.rise, reduceMotion: reduceMotion))
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic)
            .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: draft != nil)
            .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: source)
            // A short window shows the prompt and the answer first: the preview must come into view when it is ready.
            .onChange(of: draft != nil) {
                guard draft != nil else { return }
                withAnimation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion)) { proxy.scrollTo(Self.previewID, anchor: .top) }
            }
            .task { // "Revisar" comes back to a preview that already exists
                guard let draft else { return }
                // The source that made it, so the preview is in view (and what "Usar esta importação" imports is what is shown);
                // in the marketplace its row in the gallery shows it chosen.
                source = ImportSource.opening(draft: draft, default: source)
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
            if source == .assistant {
                read(url)
            } else {
                // Changing the source cancels the reading of the old one, so the file waits for that reset.
                pendingDrop = url
                source = .assistant
            }
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
        .onChange(of: link) {
            readLinkSoon()
        }
        .onChange(of: source) {
            // Each source keeps its own reading: what the other one was doing stops, and its preview is not this one's.
            reading?.cancel()
            isReading = false
            linkReading.clear()
            error = nil
            if let draft, !source.made(draft) { self.draft = nil }
            // What the fields of this source still hold is read again: the other source's reset took the preview away, not the text.
            let hasDraft = draft.map(source.made) ?? false
            let action = ImportSourceSwitch.after(switchingTo: source, pasted: pasted, link: link, hasDraft: hasDraft, pendingDrop: pendingDrop)
            pendingDrop = nil
            if let url = action.readsDrop { read(url) }
            if action.rereadsText { readSoon() }
            if action.rereadsLink { readLinkSoon(delay: .zero) }
        }
    }

    // MARK: Steps

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onBack) {
                Label("Voltar", systemImage: "chevron.left").font(.system(size: 12))
            }
            .buttonStyle(GhostStyle())
            .hangsOnLeadingEdge()
            .help(Tip.importBack)
            Text(ImportText.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var sourcePicker: some View {
        // The quiet pills of the sheet's other inner switch ("Criar conversando | Formulário").
        PillTabs(selection: $source, items: ImportSource.allCases.map { .init(value: $0, title: $0.label, symbol: "") }, isQuiet: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Importar de")
            .help(Tip.importSource)
    }

    private var marketplaceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepLabel("1. Escolha um bot")
            Text("O Orb lê as instruções, as memórias e as skills do bot que você escolher.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            MarketplaceGallery(chosen: draft?.link, reading: readingLink) { bot in read(link: .page(bot.id)) }
            // Drawn like the gallery's search field above it: one kind of field in the panel.
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(Palette.faint).accessibilityHidden(true)
                TextField("Link do bot", text: $link, prompt: Text("Ou cole o link de um bot: https://x.ai/bot/…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { readLinkSoon(delay: .zero) }
                ZStack {
                    if isReading, let readingLink, GrokMarketplace.link(in: link)?.url.absoluteString == readingLink {
                        DelayedSpinner().transition(.opacity)
                    }
                }
                .motion(Motion.content, value: isReading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .card(radius: 10)
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: error)
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
                    .fixedSize()
                    .help(Tip.importChooseFile)
                Text("ou solte arquivo ou pasta aqui")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                ZStack {
                    if isReading { DelayedSpinner().transition(.opacity) }
                }
                .motion(Motion.content, value: isReading)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
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

    /// A pasted link reads by itself, a moment after the last change: the marketplace page, off the main thread.
    private func readLinkSoon(delay: Duration = .milliseconds(400)) {
        reading?.cancel()
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { // the preview stays: it may be a bot picked in the gallery
            isReading = false
            linkReading.clear()
            error = nil
            return
        }
        reading = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let found = GrokMarketplace.link(in: text) else {
                isReading = false
                error = MarketplaceFailure.notALink.errorDescription
                return
            }
            await readBot(found)
        }
    }

    /// A bot picked in the gallery: read at once.
    private func read(link found: GrokMarketplace.Link) {
        reading?.cancel()
        reading = Task { await readBot(found) }
    }

    /// The bot's page, off the main thread, into the preview.
    private func readBot(_ found: GrokMarketplace.Link) async {
        let page = found.url.absoluteString
        // The same bot already in the preview ("Revisar", or Return on the same link) is not read again.
        if let draft, draft.link == page {
            isReading = false
            linkReading.clear()
            return
        }
        isReading = true
        let token = linkReading.begin(page)
        let reading = Task.detached(priority: .userInitiated) { () -> Result<OrbImport, any Error> in
            do { return .success(try await GrokMarketplace.read(found)) } catch { return .failure(error) }
        }
        // Another link (or closing the panel) stops the request too, not only the wait for it.
        let outcome = await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }
        guard !Task.isCancelled else {
            // Only this reading's own spinner: a newer reading of the same page keeps its.
            linkReading.end(token)
            return
        }
        isReading = false
        linkReading.end(token)
        switch outcome {
        case .success(let imported):
            error = nil
            draft = imported
            AccessibilityNotification.Announcement(ImportText.announcement(imported)).post()
        case .failure(let failure):
            if let draft, !draft.link.isEmpty { self.draft = nil }
            error = (failure as? MarketplaceFailure ?? .unreadable).errorDescription
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
    let step: Int
    let onKind: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        let plan = imported.plan()
        VStack(alignment: .leading, spacing: 10) {
            StepLabel("\(step). Prévia")
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
                group(imported.link.isEmpty ? "Sobre você" : "O que ele sabe", $imported.facts)
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
                Text(ImportRow.shown(item.text))
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

    /// The text as read, not as typed: Markdown list marks ("- ", "* ") become "• ". What is imported stays as it was.
    static func shown(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return String(line) }
            return String(indent) + "• " + String(rest.dropFirst(2))
        }.joined(separator: "\n")
    }
}

private struct ImportSkillRow: View {
    @Binding var skill: ImportSkill
    @State private var isShowing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
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
                // Under the skill's text, on its left edge (the checkbox's own indent), not loose at the far edge of the column.
                Button(isShowing ? "Ocultar" : "Ver") { isShowing.toggle() }
                    .buttonStyle(GhostStyle())
                    .padding(.leading, 7)
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
                // With their icons, so the two read as buttons and not as words of the line above.
                Button("Revisar", systemImage: "doc.text.magnifyingglass", action: review).buttonStyle(GhostStyle())
                    .help(Tip.importReview)
                Button("Remover", systemImage: "xmark", action: remove).buttonStyle(GhostStyle())
                    .help(Tip.importRemove)
            }
            .hangsOnLeadingEdge()
        }
        .accessibilityElement(children: .contain)
    }
}
