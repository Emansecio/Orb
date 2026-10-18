import SwiftUI

// The small controls under the message field: the "+" (attach, skills), what the Orb may do (permissions) and the
// model. The permission chip says its mode in words only when it is not the usual one (and there is room).

/// A pill-shaped button for the composer's bar: icon and text, a soft fill on hover, a filled one when `filled`.
struct ComposerChipStyle: ButtonStyle {
    var filled = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 28)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .capsule,
                       color: Palette.ghostSelected, resting: filled ? Palette.raised : nil)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

// MARK: Permissions

/// The Orb's permission mode as a chip ("Perguntar antes · 4") that opens a short list of the four modes, each with
/// what it means. The standing grants are counted on the chip and managed in the Orb's panel.
struct PermissionChip: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let compact: Bool
    /// The list closed (a mode chosen, "Gerenciar", or a click away): the composer takes the focus back.
    var onClose: () -> Void = {}
    @State private var isOpen = false
    @State private var isConfirmingBypass = false

    var body: some View {
        let permission = model.live(botID).permission
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: permission.mode.symbol)
                if !compact, let text = PermissionChipText.barLabel(permission) { Text(text).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(Self.tint(permission.mode))
        }
        .buttonStyle(ComposerChipStyle())
        .help("Permissões: \(PermissionChipText.spoken(permission)) · \(Tip.withoutFullStop(permission.mode.shortSummary))" + grantsHelp(permission))
        .accessibilityLabel("Permissões")
        .accessibilityValue(PermissionChipText.spoken(permission))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PermissionPopover(permission: permission, choose: choose, manage: manage)
        }
        .bypassConfirmation(isPresented: $isConfirmingBypass) { apply(.bypass) }
        .onChange(of: isOpen) { if !isOpen { onClose() } }
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
        model.showPermissions(of: botID)
    }
}

struct PermissionPopover: View {
    let permission: PermissionState
    let choose: (PermissionMode) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quando este Orb pede sua permissão")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(PermissionMode.allCases) { mode in
                PermissionRow(mode: mode, isSelected: mode == permission.mode) { choose(mode) }
            }
            if let grants = PermissionChipText.grantsTitle(permission) {
                Divider().padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(grants)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Gerenciar", action: manage)
                            .buttonStyle(.link)
                            .help(Tip.manageGrants)
                            .font(.system(size: 12))
                    }
                    Text(PermissionMode.grantsNote)
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
                    Text(mode.shortSummary)
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
            .hoverFill(isHovering, in: .rect)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Skills

/// The "+" that starts the bar: a short menu to attach files or to pick a skill. The skill list (with search) opens
/// from the "+" itself; picking one puts `/slug` in the message, as `/` typed at the start of the field does.
struct ComposerPlusMenu: View {
    @Environment(AppModel.self) private var model
    /// The Orb whose skills are listed (a skill can be limited to some Orbs).
    let botID: UUID
    let attach: () -> Void
    let onPick: (String) -> Void
    @State private var isSkillsOpen = false

    var body: some View {
        Menu {
            Button("Anexar arquivos…", systemImage: "paperclip", action: attach)
            Button("Usar skill…", systemImage: "wand.and.stars", action: openSkills)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Tip.attach)
        .accessibilityLabel("Anexar ou usar skill")
        .popover(isPresented: $isSkillsOpen, arrowEdge: .bottom) {
            SkillsPopover(skills: model.skills(for: botID)) { slug in
                isSkillsOpen = false
                onPick(slug)
            }
        }
    }

    /// The menu is still closing when its item runs: the list opens a turn later, so the popover is not shown and
    /// taken away with the menu.
    private func openSkills() {
        Task { @MainActor in
            await Task.yield()
            isSkillsOpen = true
        }
    }
}

struct SkillsPopover: View {
    let skills: [Skill]
    let pick: (String) -> Void
    @State private var query = ""
    @FocusState private var isSearching: Bool
    /// The height of the whole list, measured once with nothing typed: the popover keeps it while the list is filtered,
    /// so it never resizes with a letter.
    @State private var listHeight: CGFloat?

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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if listHeight == nil, query.isEmpty { listHeight = height }
                    }
                }
            }
        }
        .frame(width: 340, height: Self.height(skillCount: skills.count, listHeight: listHeight))
        .onAppear { isSearching = true }
    }

    /// The search field and divider (about 48 pt, measured).
    private static let chrome: CGFloat = 48

    /// The popover's height: `chrome` over the whole list of skills, at most 380. Before the
    /// list is measured, an estimate of 52 pt a skill; it depends on the Orb's skills, never on the filtered ones.
    static func height(skillCount: Int, listHeight: CGFloat?) -> CGFloat {
        min(380, (listHeight ?? CGFloat(max(skillCount, 1)) * 52) + chrome)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover fades (fast in, slow out); the keyboard highlight does not: like a native menu it moves at once,
            // so holding ↓ never leaves a trail of rows fading out behind it. Both fills are rounded and sit 4 pt in
            // from the list's edges, so the corners of the list never show a square patch.
            .hoverFill(isHovering && !isHighlighted, in: .rect(cornerRadius: 8), color: Palette.ghostSelected)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(Palette.ghostSelected)
                    .opacity(isHighlighted ? 1 : 0)
                    .animation(nil, value: isHighlighted)
            }
            .padding(.horizontal, 4)
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
        .help("Modelo deste Orb" + (name.isEmpty ? "" : ": \(name)" + (provider.map { " · \($0)" } ?? "")) + " (\(AppShortcut.chooseModel.label))")
        .accessibilityLabel("Modelo")
        .accessibilityValue(name.isEmpty ? "Nenhum" : name)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { ModelPopover(botID: botID) { isOpen = false } }
    }
}

// MARK: Background processes

/// The processes the Orb left running (`run_command` with background), one line each: what runs, for how long, and a
/// button to stop it. Once the turn that started them ends nothing else on screen says they are there.
struct JobsStrip: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let jobs: [BackgroundJobs.Snapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(jobs, id: \.id) { job in
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .foregroundStyle(Palette.faint)
                    Text(job.command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(job.command)
                        .accessibilityLabel("Rodando em segundo plano: \(job.command)")
                    Spacer(minLength: 4)
                    Text(job.startedAt, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(Palette.faint)
                    Button("Parar", systemImage: "stop.fill") { model.stopJob(job.id, of: botID) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ComposerChipStyle())
                        .help("Parar este processo e o que ele iniciou")
                }
                .accessibilityElement(children: .contain) // the stop button stays reachable
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
    }
}
