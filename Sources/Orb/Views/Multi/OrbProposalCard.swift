import SwiftUI

/// What VoiceOver reads for the creation card, and the words the card uses for what the new Orb can use.
enum ProposalSpeech {
    /// "terminal", "web", "apps do Mac": the capability as a sentence says it.
    static func word(_ capability: Capability) -> String {
        switch capability {
        case .terminal: "terminal"
        case .browser: "web"
        case .computerUse: "apps do Mac"
        case .connectors: "conectores"
        }
    }

    /// The chip's short label.
    static func chip(_ capability: Capability) -> String {
        switch capability {
        case .terminal: "Terminal"
        case .browser: "Web"
        case .computerUse: "Apps do Mac"
        case .connectors: "Conectores"
        }
    }

    /// "terminal e web", "terminal, web e apps do Mac".
    static func list(_ capabilities: Set<Capability>) -> String {
        let words = Capability.allCases.filter(capabilities.contains).map(word)
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " e " + words[words.count - 1]
        }
    }

    /// The start of the instructions for the card's collapsed view: at most `maxLines` lines and `maxCharacters` characters, cut at a
    /// word, with the trailing punctuation and blanks dropped and one "…" in their place (never "pasta...."). The whole text when it fits.
    static func excerpt(_ text: String, maxLines: Int = 3, maxCharacters: Int = 120) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept = lines.prefix(maxLines).joined(separator: "\n")
        var cut = lines.count > maxLines
        if kept.count > maxCharacters {
            kept = String(kept.prefix(maxCharacters))
            if let space = kept.lastIndex(where: \.isWhitespace), kept.distance(from: kept.startIndex, to: space) > maxCharacters / 2 {
                kept = String(kept[..<space])
            }
            cut = true
        }
        guard cut else { return text }
        // Only the end is cleaned: a list's "- ", a "(" or a quote opening the text belong to it.
        let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ")]}\"”»"))
        var scalars = Substring(kept).drop(while: \.isWhitespace).unicodeScalars
        while let last = scalars.last, dropped.contains(last) { scalars = scalars.dropLast() }
        return String(scalars) + "…"
    }

    /// The "Pasta …" line of the card, when it has one: the folder a pending card's Orb would get. Once the Orb is created that
    /// folder exists, so asking again would name the next free one ("Pesquisador 2") and the line is left out.
    static func folderFact(name: String, base: URL, wasCreated: Bool) -> String? {
        wasCreated ? nil : "Pasta " + OrbFolder.display(OrbFolder.availableURL(for: name, in: base))
    }

    /// "Atlas propõe criar o Orb Pesquisador, Cuida de pesquisas. Pode usar terminal e web. Botões: Criar, Editar antes, Não criar."
    static func card(_ proposal: OrbProposal) -> String {
        var parts = ["\(proposal.creator.name) propõe criar o Orb \(proposal.name)" + (proposal.role.isEmpty ? "" : ", \(proposal.role)") + "."]
        let uses = list(proposal.capabilities)
        parts.append(uses.isEmpty ? "Não usa ferramentas." : "Pode usar \(uses).")
        parts.append("Botões: Criar, Editar antes, Não criar.")
        return parts.joined(separator: " ")
    }
}

/// The card an Orb's proposal for a new Orb opens: the new Orb on a little stage, what it is for, what it may use, and Criar /
/// Editar antes / Não criar (docs/historico/MULTI-ORBS.md 8.4). Criar is ⌘↩ and Esc is Não criar, as on the other cards. Answered, it
/// folds into one line, "Criado: Pesquisador".
struct OrbProposalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let request: ApprovalRequest
    let proposal: OrbProposal
    /// The Orb that proposes it, whose chat shows the card.
    let botID: UUID
    /// The card arrived while the chat was open: its border pulses once (as an approval card's does).
    var pulses = false

    /// What the person is editing (the card shows it in place of `proposal` while "Editar antes" is open).
    @State private var draft: OrbProposal
    @State private var isEditing: Bool
    @State private var showsAll = false
    /// The "Pasta …" line, looked up off the main thread when the name changes: asking the disk in `body` would repeat on every keystroke.
    @State private var folderLine: String?
    /// The card has come in (`Motion.emphasis`) and the Orb has dropped onto its stage.
    @State private var entered = false
    @State private var dropped = false
    @State private var poke = 0
    @State private var activity = OrbActivity.idle
    @State private var pulse = 0
    @State private var pressed: ApprovalShortcut?
    /// A text field of the card has the focus (Esc then belongs to the field).
    @FocusState private var fieldFocused: Bool
    @State private var isTyping = false
    /// An answered card shown in full.
    @State private var isOpen = false

    init(request: ApprovalRequest, proposal: OrbProposal, botID: UUID, pulses: Bool = false, startsEditing: Bool = false) {
        self.request = request
        self.proposal = proposal
        self.botID = botID
        self.pulses = pulses
        _draft = State(initialValue: proposal)
        _isEditing = State(initialValue: startsEditing)
    }

    private var isPending: Bool { request.decision == nil }
    /// Whether this is the card ⌘↩ and esc answer, so its buttons name the keys.
    private var showsKeys: Bool { model.showsApprovalKeys(request.id, of: botID) }
    /// What the card shows: while pending, what "Criar" will create (the draft, even with the editor closed); the proposal once answered.
    private var shown: OrbProposal { isPending ? draft : proposal }
    private var creator: String { proposal.creator.name }
    private var wasCreated: Bool { request.decision != nil && request.decision != .deny }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPending {
                pendingCard.transition(.adapted(Self.leaving, reduceMotion: reduceMotion))
            } else {
                answeredCard.transition(.opacity)
            }
        }
        .padding(.leading, gutter)
        .frame(maxWidth: 560, alignment: .leading)
        .motion(Motion.content, value: request.decision)
        .motion(Motion.content, value: isEditing)
        .background { if isPending { ApprovalKeyMonitor(handler: handleKey) } }
        .task(id: pressed) { await answerPressed() }
        .accessibilityIdentifier("orb-proposal-card")
    }

    private static var leaving: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }

    // MARK: Pending

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 18) {
                stage
                VStack(alignment: .leading, spacing: 10) {
                    if isEditing { editFields } else { description }
                    chips
                    facts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isEditing {
                editor.transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            buttons
        }
        .padding(16)
        .card(radius: 14, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulses, reduceMotion: reduceMotion) { ApprovalPulseBorder(radius: 14, trigger: pulse) }
        }
        .scaleEffect(reduceMotion || entered ? 1 : 0.97, anchor: .topLeading)
        .opacity(entered ? 1 : 0)
        .animation(Motion.adapted(Motion.emphasis, reduceMotion: reduceMotion), value: entered)
        .task { await arrive() }
        .onChange(of: fieldFocused) { isTyping = fieldFocused }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProposalSpeech.card(shown))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            if !request.reason.isEmpty {
                Text(request.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The Orb on its stage

    private var stage: some View {
        ZStack {
            Circle()
                .fill(Palette.raised)
                .shadow(color: Palette.stageGlow.opacity(0.12), radius: 18)
            Circle()
                .fill(RadialGradient(colors: [Palette.stageGlow.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 52))
            SettlingOrb(idle: activity == .idle, wake: poke) { settled in
                BotAvatar(orb: shown.orb, size: 72, activity: activity, celebration: .light, paused: settled, poke: poke)
            }
                .offset(y: reduceMotion || dropped ? 0 : -8)
                .scaleEffect(reduceMotion || dropped ? 1 : 0.94)
                .opacity(dropped ? 1 : 0)
                .animation(Motion.adapted(Motion.enter, reduceMotion: reduceMotion), value: dropped)
        }
        .frame(width: 104, height: 104)
        .accessibilityHidden(true)
    }

    /// The card has come in (the border pulse, then the Orb falls onto the stage and says "oi"); under Reduce Motion everything is
    /// there at once, in a fade.
    private func arrive() async {
        entered = true
        if pulses { pulse += 1 }
        if reduceMotion || OrbView.forceStatic {
            dropped = true
            return
        }
        try? await Task.sleep(for: .milliseconds(160))
        dropped = true
        try? await Task.sleep(for: .milliseconds(320))
        activity = .happy
        poke += 1
        try? await Task.sleep(for: .milliseconds(1_800))
        activity = .idle
    }

    // MARK: What it is

    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shown.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if !shown.role.isEmpty {
                Text(shown.role)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if !shown.instructions.isEmpty {
                instructions
                    .padding(.top, 4)
            }
        }
    }

    /// Three lines of the instructions, and "Ver tudo" when there is more.
    private var instructions: some View {
        let excerpt = ProposalSpeech.excerpt(shown.instructions)
        let isLong = excerpt != shown.instructions
        return VStack(alignment: .leading, spacing: 4) {
            Text(showsAll || !isLong ? shown.instructions : excerpt)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .lineLimit(showsAll ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if isLong {
                Button(showsAll ? "Ver menos" : "Ver tudo") {
                    withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { showsAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accentText)
                .accessibilityHint("Mostra as instruções por inteiro")
            }
        }
        .motion(Motion.content, value: showsAll)
    }

    private var chips: some View {
        WrappingLayout(spacing: 6) {
            ForEach(Capability.allCases.filter { $0 != .connectors && shown.capabilities.contains($0) }) { capability in
                chip(ProposalSpeech.chip(capability), symbol: capability.symbol)
            }
            chip(shown.mode.label, symbol: shown.mode == .readOnly ? "eye" : "hand.raised")
        }
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.raised, in: .capsule)
    }

    /// The model, the folder and the connectors: read only, even when editing.
    private var facts: some View {
        let folder = wasCreated ? nil : folderLine
        let taken = isPending ? model.isOrbNameTaken(draft.name) : proposal.nameTaken
        return VStack(alignment: .leading, spacing: 3) {
            fact("Mesmo modelo que \(creator)", symbol: "cpu")
            if let folder { fact(folder, symbol: "folder") }
            if taken {
                fact("Já existe um Orb com esse nome: a pasta ganha outro nome", symbol: "exclamationmark.circle", tint: Palette.warn)
            }
            fact("Sem conectores", symbol: "puzzlepiece.extension")
        }
        .padding(.top, 2)
        .task(id: FolderKey(name: shown.name, wasCreated: wasCreated)) {
            guard !wasCreated else { return folderLine = nil }
            let (name, base) = (shown.name, model.proposedOrbFolderBase)
            // A short pause while typing; the first lookup goes at once.
            if folderLine != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let line = await Task.detached { ProposalSpeech.folderFact(name: name, base: base, wasCreated: false) }.value
            if !Task.isCancelled { folderLine = line }
        }
    }

    private struct FolderKey: Equatable {
        let name: String
        let wasCreated: Bool
    }

    private func fact(_ text: String, symbol: String, tint: Color = Palette.faint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 16, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(tint)
    }

    // MARK: Editing

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Nome", text: $draft.name)
                .focused($fieldFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .fieldBackground()
                .onChange(of: draft.name) { if draft.name.count > OrbProposal.nameLimit { draft.name = String(draft.name.prefix(OrbProposal.nameLimit)) } }
                .accessibilityLabel("Nome do Orb")
            TextField("O que ele faz, numa linha", text: $draft.role)
                .focused($fieldFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .fieldBackground()
                .onChange(of: draft.role) { if draft.role.count > OrbProposal.roleLimit { draft.role = String(draft.role.prefix(OrbProposal.roleLimit)) } }
                .accessibilityLabel("Papel do Orb")
            TextEditor(text: $draft.instructions)
                .focused($fieldFocused)
                .scrollContentBackground(.hidden)
                .font(.system(size: 12))
                .frame(height: 104)
                .padding(4)
                .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 8))
                .onChange(of: draft.instructions) {
                    if draft.instructions.count > OrbProposeTool.instructionsLimit {
                        draft.instructions = String(draft.instructions.prefix(OrbProposeTool.instructionsLimit))
                    }
                }
                .accessibilityLabel("Instruções do Orb")
            Text("\(draft.instructions.count)/\(OrbProposeTool.instructionsLimit)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The switches (only the ones the creator has can be on), the mode up to the creator's own, and "Sortear" for the look.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.line)
            Text("O que \(draft.name.isEmpty ? "ele" : draft.name) pode usar")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
            ForEach(Capability.allCases.filter { $0 != .connectors }) { capability in
                let has = draft.creatorCapabilities.contains(capability)
                HStack(spacing: 8) {
                    // The icons share one width, so every label starts at the same x (a globe is narrower than a terminal).
                    HStack(spacing: 6) {
                        Image(systemName: capability.symbol)
                            .frame(width: 20, alignment: .center)
                            .accessibilityHidden(true)
                        Text(capability.label)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(has ? Palette.secondary : Palette.faint)
                    .frame(width: 200, alignment: .leading)
                    Toggle(capability.label, isOn: Binding(get: { draft.capabilities.contains(capability) && has },
                                                          set: { on in
                                                              if on { draft.capabilities.insert(capability) } else { draft.capabilities.remove(capability) }
                                                          }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!has)
                    if !has {
                        Text("\(creator) não tem isso")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Text("Modo")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                if draft.allowedModes.count > 1 {
                    Picker("Modo", selection: $draft.mode) {
                        ForEach(draft.allowedModes) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(draft.mode.label).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if draft.modeCeiling != .auto {
                    Text("até onde \(creator) chega")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            Button {
                draft.orb = OrbConfig.random()
                if !reduceMotion { poke += 1 }
            } label: {
                Label("Sortear aparência", systemImage: "dice")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accentText)
            .help("Um jeito novo para o Orb")
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        // The same row as an approval's: the quiet "Não criar" at the leading edge, the buttons at the trailing one, the
        // primary one last.
        ViewThatFits(in: .horizontal) {
            ActionRow { denyButton.hangsOnLeadingEdge() } trailing: { editButton; createButton }
            VStack(alignment: .trailing, spacing: Spacing.controlGap) {
                ActionRow { denyButton.hangsOnLeadingEdge() } trailing: { EmptyView() }
                ActionRow { EmptyView() } trailing: { editButton; createButton }
            }
        }
    }

    private var createButton: some View {
        Button(action: create) {
            HStack(spacing: 7) {
                Text("Criar")
                if showsKeys {
                    Text(AppShortcut.commandReturn.label)
                        .font(.system(size: 11))
                        .opacity(0.55)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 14)
            .frame(minHeight: ControlHeight.regular)
            .background(Palette.ink, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(pressed == .allow ? 0.85 : 1)
        .scaleEffect(pressed == .allow ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
        .disabled(!draft.canCreate)
        .help("Criar \(shown.name) (\(AppShortcut.commandReturn.label))")
        .accessibilityLabel("Criar")
        .accessibilityHint("Atalho: ⌘↩")
    }

    private var editButton: some View {
        Button(isEditing ? "Fechar edição" : "Editar antes") {
            withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { isEditing.toggle() }
        }
        .buttonStyle(SecondaryPillStyle())
        .help(isEditing ? "Voltar ao cartão" : "Mudar o nome, as instruções e o que ele pode usar antes de criar")
        .accessibilityLabel(isEditing ? "Fechar edição" : "Editar antes")
    }

    private var denyButton: some View {
        Button(action: decline) {
            HStack(spacing: 6) {
                Text("Não criar")
                if showsKeys {
                    Text("esc")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .buttonStyle(GhostStyle())
        .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
        .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
        .help("Não criar esse Orb (\(ShortcutCatalog.keys(for: .denyApproval)))")
        .accessibilityLabel("Não criar")
        .accessibilityHint("Atalho: Esc")
    }

    // MARK: Answered

    private var answeredCard: some View {
        let shown = proposal
        let title = (wasCreated ? "Criado: " : "Não criado: ") + shown.name
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    BotAvatar(orb: shown.orb, size: 18, animated: false)
                    Image(systemName: wasCreated ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(wasCreated ? Palette.ok : Palette.danger)
                        .frame(width: 14)
                        .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(wasCreated ? Palette.secondary : Palette.muted)
                        .lineLimit(1)
                    if let note = request.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(reduceMotion ? nil : Motion.content, value: isOpen)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Esconder o pedido" : "Ver o pedido")
            .accessibilityLabel("\(title). \(creator) propôs, \(shown.role)")
            .accessibilityValue(isOpen ? "expandido" : "recolhido")
            .accessibilityHint("Mostra o que foi proposto")

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    description
                    chips
                    facts
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: 14, stroke: Palette.line)
                .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
    }

    // MARK: Answers

    /// "Criar": what was edited is kept on the card first, then the card is answered.
    private func create() {
        guard isPending, draft.canCreate else { return }
        if draft != proposal { model.updateProposal(draft, approvalID: request.id, botID: botID) }
        model.decide(.once, approvalID: request.id, botID: botID)
    }

    private func decline() {
        model.decide(.deny, approvalID: request.id, botID: botID)
    }

    /// ⌘↩ and Esc answer this card when it is the newest open one of the Orb being shown.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id,
              !model.findFieldHasFocus else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: isTyping)
        let typingInComposer = ApprovalShortcut.isTypingInComposer(isEditing: editing, noteFocused: isTyping)
        guard let shortcut = ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      isEditingText: editing, isTypingInComposer: typingInComposer) else { return false }
        press(shortcut)
        return true
    }

    private func press(_ shortcut: ApprovalShortcut) {
        guard pressed == nil else { return }
        if ApprovalShortcut.pressDelay(reduceMotion: reduceMotion) == .zero {
            answer(shortcut)
        } else {
            pressed = shortcut
        }
    }

    private func answerPressed() async {
        guard let shortcut = pressed else { return }
        try? await Task.sleep(for: ApprovalShortcut.pressDelay(reduceMotion: reduceMotion))
        answer(shortcut)
        pressed = nil
    }

    private func answer(_ shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allow: create()
        case .deny: decline()
        }
    }
}

private extension View {
    /// A text field on the card: a quiet rounded fill.
    func fieldBackground() -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}
