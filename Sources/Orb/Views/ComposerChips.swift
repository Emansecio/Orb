import SwiftUI

// The small controls under the message field: what the Orb may do (permissions), the skills, and the model. Each
// shows its state in words when there is room and only its icon when the composer is narrow.

/// A pill-shaped button for the composer's bar: icon and text, a soft fill on hover, a filled one when `filled`.
struct ComposerChipStyle: ButtonStyle {
    var filled = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 28)
            .background(background(pressed: configuration.isPressed), in: .capsule)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if pressed || isHovering { return Palette.ghostSelected }
        return filled ? Palette.raised : .clear
    }
}

// MARK: Permissions

/// The Orb's permission mode as a chip ("Perguntar antes · 4") that opens a short list of the four modes, each with
/// what it means. The standing grants are counted on the chip and managed in the Orb's panel.
struct PermissionChip: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let compact: Bool
    @State private var isOpen = false
    @State private var isConfirmingBypass = false

    var body: some View {
        let permission = model.live(botID).permission
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: permission.mode.symbol)
                if !compact { Text(PermissionChipText.label(permission)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(Self.tint(permission.mode))
        }
        .buttonStyle(ComposerChipStyle())
        .help("Permissões: \(PermissionChipText.spoken(permission)). \(permission.mode.composerSummary)" + grantsHelp(permission))
        .accessibilityLabel("Permissões")
        .accessibilityValue(PermissionChipText.spoken(permission))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PermissionPopover(permission: permission, choose: choose, manage: manage)
        }
        .bypassConfirmation(isPresented: $isConfirmingBypass) { apply(.bypass) }
    }

    static func tint(_ mode: PermissionMode) -> Color {
        switch mode {
        case .ask, .readOnly: Palette.muted
        case .auto: Palette.accentText
        case .bypass: Palette.warn
        }
    }

    private func grantsHelp(_ permission: PermissionState) -> String {
        guard permission.mode == .ask, !permission.rules.isEmpty else { return "" }
        return "\n\nLiberado:\n" + permission.rules.map { "• " + $0.title }.joined(separator: "\n")
    }

    private func choose(_ mode: PermissionMode) {
        isOpen = false
        guard mode != model.live(botID).permission.mode else { return }
        if mode == .bypass { isConfirmingBypass = true } else { apply(mode) }
    }

    private func apply(_ mode: PermissionMode) {
        model.update(botID) { $0.permissionMode = mode }
    }

    private func manage() {
        isOpen = false
        model.showInspector = true
    }
}

struct PermissionPopover: View {
    let permission: PermissionState
    let choose: (PermissionMode) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("O que este Orb pode fazer sem perguntar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(PermissionMode.pickerOrder) { mode in
                PermissionRow(mode: mode, isSelected: mode == permission.mode) { choose(mode) }
            }
            if let grants = PermissionChipText.grantsLine(permission) {
                Divider().padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(grants) permanentes")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Gerenciar", action: manage)
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                    Text("Estas liberações valem em “Perguntar antes”. Comandos arriscados sempre perguntam.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .frame(width: 330)
    }
}

private struct PermissionRow: View {
    let mode: PermissionMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.symbol)
                    .foregroundStyle(mode == .auto || mode == .bypass ? PermissionChip.tint(mode) : Palette.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mode == .bypass ? Palette.warn : Palette.ink)
                    Text(mode.composerSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Palette.ghostHover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Skills

/// "Skills": a popover with search, each skill with its summary. Picking one puts `/slug` in the message.
struct SkillsChip: View {
    @Environment(AppModel.self) private var model
    /// The Orb whose skills are listed (a skill can be limited to some Orbs).
    let botID: UUID
    let compact: Bool
    let onPick: (String) -> Void
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                if !compact { Text("Skills") }
            }
        }
        .buttonStyle(ComposerChipStyle())
        .help("Usar uma skill: escolha uma ou digite / no começo da mensagem")
        .accessibilityLabel("Skills")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SkillsPopover(skills: model.skills(for: botID)) { slug in
                isOpen = false
                onPick(slug)
            }
        }
    }
}

struct SkillsPopover: View {
    let skills: [Skill]
    let pick: (String) -> Void
    @State private var query = ""
    @FocusState private var isSearching: Bool

    var body: some View {
        let shown = SkillSearch.matches(skills, query)
        VStack(spacing: 0) {
            TextField("Buscar skill", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearching)
                .onSubmit { if let first = shown.first { pick(first.slug) } }
                .padding(10)
            Divider()
            if skills.isEmpty {
                empty("Nenhuma skill ativa", "Instale ou ative skills na seção Skills da barra lateral.")
            } else if shown.isEmpty {
                empty("Nenhuma skill encontrada", "Tente outra palavra.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { skill in SkillRow(skill: skill) { pick(skill.slug) } }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 340, height: min(380, CGFloat(max(shown.count, 1)) * 52 + 64))
        .onAppear { isSearching = true }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct SkillRow: View {
    let skill: Skill
    var isHighlighted = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Text("/" + skill.slug).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering || isHighlighted ? Palette.ghostSelected : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

// MARK: Model

/// The Orb's model as a chip that opens `ModelPopover`.
struct ModelChip: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @Binding var isOpen: Bool

    var body: some View {
        let modelID = model.live(botID).modelID
        let name = model.modelName(forModel: modelID)
        let provider = ModelRef(modelID.isEmpty ? model.defaultModel : modelID)?.provider.label
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(name.isEmpty ? "Sem modelo" : name).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .buttonStyle(ComposerChipStyle(filled: true))
        .foregroundStyle(name.isEmpty ? Palette.warn : Palette.secondary)
        .help("Modelo deste Orb" + (name.isEmpty ? "" : ": \(name)" + (provider.map { " · \($0)" } ?? "")) + " (⇧⌘M)")
        .accessibilityLabel("Modelo")
        .accessibilityValue(name.isEmpty ? "Nenhum" : name)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { ModelPopover(botID: botID) { isOpen = false } }
    }
}
