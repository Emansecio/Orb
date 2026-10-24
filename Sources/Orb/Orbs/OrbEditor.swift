import SwiftUI

/// Full Orb customizer: a big live stage (with activity preview, "Sortear" and undo), categories grouped by
/// body, face and style, option grids whose thumbnails frame what they change, and named tint swatches.
///
/// A short editor (the "Novo Orb" sheet, or a sheet over a short window) uses a compact stage: a smaller Orb, the
/// buttons up in the room beside its head and no name under it, so the options keep most of the height.
struct OrbEditor: View {
    @Binding var config: OrbConfig
    var name = ""
    /// true/false forces the compact stage on or off; nil picks it from the editor's height.
    var compact: Bool?

    @State private var category: OrbCategory
    @State private var previewActivity: OrbActivity = .idle
    @State private var poke = 0
    /// The one highlight behind the chosen category slides to the new one through this namespace (both bars).
    @Namespace private var categoryHighlight
    /// Owns this editor's entries in the window's undo manager (dropped when the editor goes away).
    @State private var undoTarget = OrbEditUndo.Target()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Measured: the editor is shorter than `compactBelow` (used when `compact` is nil).
    @State private var isShort = false

    init(config: Binding<OrbConfig>, name: String = "", category: OrbCategory = .color, compact: Bool? = nil) {
        _config = config
        self.name = name
        self.compact = compact
        _category = State(initialValue: category)
    }

    private let previewActivities: [OrbActivity] = [.idle, .speaking, .thinking, .typing, .browsing, .searching, .waiting, .happy, .error, .sleepy]

    /// Categories grouped the way people think about a character.
    private static let bodyGroup: (title: String, categories: [OrbCategory]) = ("Corpo", [.color, .temperament])
    private static let faceGroup: (title: String, categories: [OrbCategory]) = ("Rosto", [.eyes, .mouth, .brows, .cheeks, .mustache])
    private static let styleGroup: (title: String, categories: [OrbCategory]) = ("Estilo", [.hair, .accessories])

    /// The stage's Orb (regular and compact), and the room it needs: hats and hair reach ~0.39 of its size above
    /// it, and a hop with a stretch adds ~0.3 more (lively temperaments jump 1.4× higher); below it, its shadow and
    /// glow. Both are proportional to the Orb (`OrbStageRoom`).
    nonisolated static let stageOrb: CGFloat = 144, compactStageOrb: CGFloat = 112
    /// Editors shorter than this get the compact stage (the regular one leaves the options too little room).
    nonisolated static let compactBelow: CGFloat = 680

    private var isCompact: Bool { compact ?? isShort }
    private var stageOrb: CGFloat { isCompact ? Self.compactStageOrb : Self.stageOrb }

    var body: some View {
        VStack(spacing: 0) {
            // The stage comes in first, 0.08 s after the sheet, and the Orb gives a little hop of "hi" when it lands;
            // the categories and the options follow (§2.6). Under Reduce Motion everything fades in together, no hop.
            stage
                .sheetSection(0) { if !reduceMotion { poke += 1 } }
            VStack(spacing: 0) {
                Divider().overlay(Palette.line)
                categoryBar
                Divider().overlay(Palette.line)
                ScrollView {
                    optionsContent
                        .padding(16)
                }
                .scrollIndicators(.automatic)
            }
            .sheetSection(1)
        }
        .background(Palette.canvas)
        .onGeometryChange(for: Bool.self) { $0.size.height < Self.compactBelow } action: { isShort = $0 }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: undoTarget)
            MemoryRelief.orbsClosed() // the variants it decoded: some 50 MB after a tour of the categories
        }
    }

    /// What the chosen category offers. Another category cross-fades with the one before (§2.6): the two are laid over
    /// each other for 0.18 s, never side by side, and their thumbnails are still Orbs (they only move on hover), so
    /// each is drawn once.
    private var optionsContent: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                if category == .temperament {
                    temperamentList
                } else {
                    optionGrid
                }
                tintRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(category)
            .transition(.pageSwap)
        }
        .motion(Motion.crossFade, value: category)
    }

    // MARK: Editing

    /// Every change goes through here: it can be undone and redone (the "Desfazer" button, ⌘Z and ⇧⌘Z, Edit menu),
    /// and the stage gives a little hop of approval.
    private func edit(hop: Bool = true, _ change: (inout OrbConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        let binding = $config
        let animation: Animation? = reduceMotion ? nil : .snappy
        OrbEditUndo.register(undoManager, target: undoTarget, from: config, to: next) { look in
            withAnimation(animation) { binding.wrappedValue = look }
        }
        withAnimation(animation) { config = next }
        if hop { poke += 1 }
    }

    private func undo() {
        guard OrbEditUndo.canUndo(undoManager) else { return }
        undoManager?.undo()
        poke += 1
    }

    // MARK: Stage

    private var stage: some View {
        let orb = stageOrb, compact = isCompact
        let spot = 230 * orb / Self.stageOrb
        return VStack(spacing: compact ? 8 : 10) {
            OrbView(config: config, activity: previewActivity, size: orb, poke: poke, interactive: true,
                    accessibilityText: "Prévia do Orb: \(config.summary). \(previewActivity.label).")
                .background {
                    // A soft neutral spotlight: the satin Orb has no glow of its own to spill around it.
                    // (A circle stretched sideways, so the gradient fades out exactly at its edge.)
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.02), .clear],
                                             center: .center, startRadius: 0, endRadius: spot / 2))
                        .frame(width: spot, height: spot)
                        .scaleEffect(x: 1.55, y: 1)
                        .accessibilityHidden(true)
                }
                .padding(.top, OrbStageRoom.headroom(for: orb))
                .padding(.bottom, OrbStageRoom.footroom(for: orb))
                .frame(maxWidth: .infinity)
                // Compact: the buttons sit up beside the head, where nothing of the Orb reaches (hats and hops stay
                // within the middle column).
                .overlay(alignment: .top) {
                    if compact {
                        HStack(spacing: 2) {
                            randomButton
                            Spacer(minLength: orb * 1.3)
                            undoButton.labelStyle(.iconOnly)
                            hopButton.labelStyle(.iconOnly)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    }
                }
                // ...and the activity preview becomes a menu in the corner beside the Orb's base.
                .overlay(alignment: .bottomLeading) {
                    if compact { previewMenu.padding(.leading, 12) }
                }
            // The "Novo Orb" form shows the name right beside it.
            if !compact, !name.isEmpty {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            if !compact {
                previewChips
                HStack(spacing: 8) {
                    randomButton
                    undoButton
                    hopButton
                }
            }
        }
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: .infinity)
        .background(Palette.chrome)
    }

    /// The activities the stage can preview, as a row of chips.
    private var previewChips: some View {
        // Centered on the stage's axis when they all fit; when they do not, the same row scrolls.
        ViewThatFits(in: .horizontal) {
            previewChipRow.frame(maxWidth: .infinity)
            ScrollView(.horizontal) { previewChipRow }
                .scrollIndicators(.never)
        }
    }

    private var previewChipRow: some View {
        HStack(spacing: 6) {
            ForEach(previewActivities) { activity in
                Button {
                    previewActivity = activity
                } label: {
                    Label(activity.label, systemImage: activity.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(previewActivity == activity ? Palette.onInk : Palette.secondary)
                        .background(previewActivity == activity ? Palette.ink : Color.white.opacity(0.07), in: .capsule)
                }
                .buttonStyle(.plain)
                .help(Tip.previewActivity(activity.label))
                .accessibilityLabel("Prévia: \(activity.label)")
                .accessibilityAddTraits(previewActivity == activity ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
    }

    /// The same choice in a menu (compact stage).
    private var previewMenu: some View {
        Menu {
            Picker("Prévia", selection: $previewActivity) {
                ForEach(previewActivities) { activity in
                    Label(activity.label, systemImage: activity.symbol).tag(activity)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(previewActivity.label, systemImage: previewActivity.symbol)
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.07), in: .capsule)
        .help(Tip.previewActivity(previewActivity.label))
        .accessibilityLabel("Prévia: \(previewActivity.label)")
    }

    private var randomButton: some View {
        Button("Sortear", systemImage: "dice") {
            // A new look that hangs together; the temperament stays.
            edit { config in
                let temperament = config.temperament
                config = OrbConfig.random()
                config.temperament = temperament
            }
        }
        .buttonStyle(SecondaryPillStyle())
        .help(Tip.randomLook)
    }

    private var undoButton: some View {
        let canUndo = OrbEditUndo.canUndo(undoManager)
        return Button("Desfazer", systemImage: "arrow.uturn.backward", action: undo)
            .buttonStyle(GhostStyle())
            .disabled(!canUndo)
            .opacity(canUndo ? 1 : 0.45)
            .help("Desfaz a última mudança no Orb, inclusive no jeito (⌘Z; ⇧⌘Z refaz)")
    }

    /// A hop shows nothing with Reduce Motion (the Orb holds still), so there is no button for it then.
    @ViewBuilder private var hopButton: some View {
        if !reduceMotion {
            Button("Pular", systemImage: "arrow.up.circle") { poke += 1 }
                .buttonStyle(GhostStyle())
                .help("Faz o Orb pular")
        }
    }

    // MARK: Categories

    /// One row when it fits; below that, Corpo and Estilo on top and Rosto underneath. The compact editor uses one
    /// row of icons instead, the chosen category with its name, the groups apart.
    @ViewBuilder private var categoryBar: some View {
        if isCompact { compactCategoryBar } else { groupedCategoryBar }
    }

    private var compactCategoryBar: some View {
        // Every category with its name under the icon when the width allows it; otherwise icons alone, the chosen one named.
        ViewThatFits(in: .horizontal) {
            compactCategoryRow(labeled: true)
            compactCategoryRow(labeled: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .center)
        // The highlight slides and the chosen one's name grows its width in the content curve; under Reduce Motion the
        // highlight jumps and the width changes at once.
        .animation(Motion.selection(reduceMotion: reduceMotion), value: category)
    }

    private func compactCategoryRow(labeled: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array([Self.bodyGroup, Self.faceGroup, Self.styleGroup].enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle().fill(Palette.line).frame(width: 1, height: 18).padding(.horizontal, 5)
                }
                ForEach(group.categories) { item in compactCategoryButton(item, labeled: labeled) }
            }
        }
    }

    private func compactCategoryButton(_ item: OrbCategory, labeled: Bool) -> some View {
        let isSelected = category == item
        return Button {
            category = item
        } label: {
            Group {
                if labeled {
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 16, height: 16)
                        Text(item.label)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 16, height: 16)
                        if isSelected {
                            Text(item.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, labeled ? 7 : 9)
            .frame(minWidth: 34, minHeight: labeled ? 38 : 30)
            .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
            .background { categoryHighlightShape(isSelected) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var groupedCategoryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                group(Self.bodyGroup)
                group(Self.faceGroup)
                group(Self.styleGroup)
            }
            VStack(alignment: .center, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    group(Self.bodyGroup)
                    group(Self.styleGroup)
                }
                group(Self.faceGroup)
            }
        }
        .animation(Motion.selection(reduceMotion: reduceMotion), value: category)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // On the same axis as the stage above (the preview, the name, the chips): centered, not left-anchored.
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The highlight of the chosen category: drawn by that button alone, the same view for all of them.
    @ViewBuilder private func categoryHighlightShape(_ isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 9)
                .fill(Palette.ghostSelected)
                .matchedGeometryEffect(id: "categoria", in: categoryHighlight)
        }
    }

    private func group(_ group: (title: String, categories: [OrbCategory])) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // The sidebar's section title (`SectionTitle`): normal case, not the only capitals in the app.
            Text(group.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 1) {
                ForEach(group.categories) { item in categoryButton(item) }
            }
        }
        .fixedSize()
    }

    private func categoryButton(_ item: OrbCategory) -> some View {
        Button {
            category = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .frame(height: 16)
                Text(item.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 42)
            .foregroundStyle(category == item ? Palette.ink : Palette.muted)
            .background { categoryHighlightShape(category == item) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(category == item ? .isSelected : [])
    }

    // MARK: Options

    private var optionGrid: some View {
        let framing = OptionCell.Framing(category)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(OrbCatalog.shared.options(category)) { option in
                OptionCell(label: option.label, isSelected: isSelected(option.id), preview: previewConfig(option.id),
                           framing: framing) {
                    edit { $0.set(category, option.id) }
                }
            }
        }
    }

    /// Picking one plays its signature move on the stage (see `OrbTemperament.showcase`).
    private var temperamentList: some View {
        VStack(spacing: 6) {
            ForEach(OrbTemperament.allCases) { temperament in
                TemperamentRow(temperament: temperament, isSelected: config.temperament == temperament) {
                    edit(hop: false) { $0.temperament = temperament }
                }
            }
        }
    }

    private func isSelected(_ id: String) -> Bool {
        category == .accessories ? config.accessories.contains(id) : config.value(for: category) == id
    }

    private func previewConfig(_ id: String) -> OrbConfig {
        var preview = config
        if category == .accessories {
            if !preview.accessories.contains(id) { preview.accessories = [id] }
        } else {
            preview.set(category, id)
        }
        return preview
    }

    // MARK: Tints

    @ViewBuilder
    private var tintRow: some View {
        switch category {
        case .hair where config.hair != "nenhum":
            TintPicker(title: "Cor do cabelo", value: config.hairColor, swatches: OrbSwatch.hair,
                       automatic: config.autoHairColor(OrbCatalog.shared.palette(config.color))) { tint in
                edit(hop: false) { $0.hairColor = tint }
            }
        case .mustache where config.mustache != "nenhum":
            TintPicker(title: "Cor do bigode", value: config.mustacheColor, swatches: OrbSwatch.mustache,
                       automatic: config.autoMustacheColor(OrbCatalog.shared.palette(config.color))) { tint in
                edit(hop: false) { $0.mustacheColor = tint }
            }
        case .accessories where config.accessories.contains(where: OrbCatalog.shared.tintedAccessories.contains):
            TintPicker(title: "Cor dos acessórios", value: config.accentColor, swatches: OrbSwatch.accent, automatic: nil) { tint in
                edit(hop: false) { $0.accentColor = tint }
            }
        case .accessories:
            Text("Combine quantos acessórios quiser. Clique de novo para remover.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
        case .temperament:
            Text("O jeito muda como o Orb se mexe, pisca e reage ao ponteiro, não a aparência.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
        default:
            EmptyView()
        }
    }
}

private struct OptionCell: View {
    /// What the thumbnail shows: the whole Orb (colors), a close-up of the face (eyes, mouth…), or the head with
    /// room above it (hair, hats).
    enum Framing {
        case whole, face, head

        init(_ category: OrbCategory) {
            switch category {
            case .eyes, .mouth, .brows, .cheeks, .mustache: self = .face
            case .hair, .accessories: self = .head
            case .color, .temperament: self = .whole
            }
        }
    }

    let label: String
    let isSelected: Bool
    let preview: OrbConfig
    let framing: Framing
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                thumbnail
                    .frame(height: 66)
                Text(label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            // The chosen one keeps its own fill, which changes with the press curve; hover is the shared fade (in 0.10 s,
            // out 0.22 s), colors only, so it stays under Reduce Motion too.
            .background { RoundedRectangle(cornerRadius: Radius.card).fill(Palette.ghostSelected).opacity(isSelected ? 1 : 0) }
            .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(isSelected ? Palette.lineStrong : .clear))
            .animation(Motion.press, value: isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch framing {
        case .whole:
            OrbView(config: preview, size: 46, animated: isHovering, followsPointer: false)
        case .head:
            // Hair and hats reach about half an orb above the head.
            OrbView(config: preview, size: 44, animated: isHovering, followsPointer: false)
                .offset(y: 10)
        case .face:
            // A close-up: the band from the brows to the mouth fills the cell. Static: the live orb is an AppKit
            // view, which the clip shape would not cut.
            OrbView(config: preview, size: 80, animated: false, followsPointer: false)
                .frame(width: 70, height: 52)
                .clipShape(.rect(cornerRadius: Radius.large))
                .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.white.opacity(0.06)))
        }
    }
}

private struct TemperamentRow: View {
    let temperament: OrbTemperament
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: temperament.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(isSelected ? 0.12 : 0.06), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(temperament.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.secondary)
                    Text(temperament.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // The chosen one keeps its own fill, which changes with the press curve; hover is the shared fade (in 0.10 s,
            // out 0.22 s), colors only, so it stays under Reduce Motion too.
            .background { RoundedRectangle(cornerRadius: Radius.card).fill(Palette.ghostSelected).opacity(isSelected ? 1 : 0) }
            .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(isSelected ? Palette.lineStrong : .clear))
            .animation(Motion.press, value: isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(temperament.label): \(temperament.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Auto" plus named swatches in a grid that wraps; the automatic chip shows the color it stands for, and a saved
/// color that isn't in the list shows as a custom swatch. Rings keep a 3:1 contrast on the dark background and on
/// light swatches alike (WCAG 1.4.11).
private struct TintPicker: View {
    let title: String
    let value: UInt32?
    let swatches: [OrbSwatch]
    /// The color "Auto" gives (nil: each accessory has its own).
    let automatic: UInt32?
    let pick: (UInt32?) -> Void

    private var shown: [OrbSwatch] {
        guard let value, !swatches.contains(where: { $0.hex == value }) else { return swatches }
        return [OrbSwatch(hex: value, name: "Cor personalizada")] + swatches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            HStack(alignment: .top, spacing: 7) {
                Button {
                    pick(nil)
                } label: {
                    HStack(spacing: 4) {
                        if let automatic {
                            Circle().fill(Color(hex: automatic)).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                        }
                        Text("Auto")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(value == nil ? Palette.onInk : Palette.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(value == nil ? Palette.ink : Color.white.opacity(0.08), in: .capsule)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help(Tip.autoColor)
                .accessibilityLabel("Cor automática")
                .accessibilityAddTraits(value == nil ? .isSelected : [])
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: 7)], alignment: .leading, spacing: 7) {
                    ForEach(shown, id: \.self) { swatch in
                        Button {
                            pick(swatch.hex)
                        } label: {
                            SwatchDot(color: Color(hex: swatch.hex), isSelected: value == swatch.hex)
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(value == swatch.hex ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// A color dot: a light hairline so dark colors stand out on the dark background; when selected, a white ring with a
/// dark inner ring, visible on white and on black swatches.
private struct SwatchDot: View {
    let color: Color
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0.4), lineWidth: isSelected ? 2 : 1))
            .overlay {
                if isSelected { Circle().inset(by: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 1) }
            }
    }
}

/// Orb edits in the window's undo manager (Edit ▸ Undo, ⌘Z and ⇧⌘Z, and the editor's "Desfazer"), each one
/// redoable. `apply` writes a look back; the entries belong to `target` so the editor can drop them when it closes.
@MainActor
enum OrbEditUndo {
    final class Target {}

    static let actionName = "Mudança no Orb"

    static func register(_ undoManager: UndoManager?, target: Target, from old: OrbConfig, to new: OrbConfig,
                         apply: @escaping @MainActor (OrbConfig) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated {
                apply(old)
                // Registered while undoing, so it lands on the redo stack.
                register(undoManager, target: target, from: new, to: old, apply: apply)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Whether ⌘Z would undo an Orb edit now (and not, say, typing in a field of the same window).
    static func canUndo(_ undoManager: UndoManager?) -> Bool {
        guard let undoManager, undoManager.canUndo else { return false }
        return undoManager.undoActionName == actionName
    }
}
