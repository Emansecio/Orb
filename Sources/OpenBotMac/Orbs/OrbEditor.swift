import SwiftUI

/// Full Orb customizer: live preview (with activity preview), category tabs, option grid with
/// rendered thumbnails, tint swatches and randomize.
struct OrbEditor: View {
    @Binding var config: OrbConfig
    var name = ""

    @State private var category: OrbCategory = .color
    @State private var previewActivity: OrbActivity = .idle
    @State private var poke = 0

    private let previewActivities: [OrbActivity] = [.idle, .thinking, .typing, .browsing, .searching, .waiting, .happy, .error, .sleepy]

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider().overlay(Palette.line)
            categoryBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    optionGrid
                    tintRow
                }
                .padding(16)
            }
            .scrollIndicators(.automatic)
        }
        .background(Palette.canvas)
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 12) {
            OrbView(config: config, activity: previewActivity, size: 132, poke: poke, interactive: true)
                .frame(height: 190)
                .padding(.top, 26)
            if !name.isEmpty {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            ScrollView(.horizontal) {
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
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
            HStack(spacing: 8) {
                Button("Sortear", systemImage: "dice") {
                    withAnimation(.snappy) { config = .random() }
                    poke += 1
                }
                .buttonStyle(SecondaryPillStyle())
                Button("Pular", systemImage: "arrow.up.circle") { poke += 1 }
                    .buttonStyle(GhostStyle())
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.chrome)
    }

    // MARK: Categories

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(OrbCategory.allCases) { item in
                    Button {
                        category = item
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14))
                            Text(item.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 74, height: 46)
                        .foregroundStyle(category == item ? Palette.ink : Palette.muted)
                        .background(category == item ? Palette.ghostSelected : .clear, in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    // MARK: Options

    private var optionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(OrbCatalog.shared.options(category)) { option in
                OptionCell(label: option.label, isSelected: isSelected(option.id), preview: previewConfig(option.id)) {
                    withAnimation(.snappy) { config.set(category, option.id) }
                    poke += 1
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

    private static let swatches: [UInt32] = [0x1C1A2B, 0x5A3B22, 0xC98A3A, 0xF4F2FF, 0xFF5A3D, 0xFF4F8B,
                                             0x8A5BFF, 0x2E9BFF, 0x14C08C, 0xFFC83D, 0x2B2B36]

    @ViewBuilder
    private var tintRow: some View {
        switch category {
        case .hair where config.hair != "nenhum":
            TintPicker(title: "Cor do cabelo", value: $config.hairColor, swatches: Self.swatches)
        case .mustache where config.mustache != "nenhum":
            TintPicker(title: "Cor do bigode", value: $config.mustacheColor, swatches: Self.swatches)
        case .accessories where config.accessories.contains(where: OrbCatalog.shared.tintedAccessories.contains):
            TintPicker(title: "Cor dos acessórios", value: $config.accentColor, swatches: Self.swatches)
        case .accessories:
            Text("Combine quantos acessórios quiser. Clique de novo para remover.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
        default:
            EmptyView()
        }
    }
}

private struct OptionCell: View {
    let label: String
    let isSelected: Bool
    let preview: OrbConfig
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                OrbView(config: preview, size: 40, animated: isHovering, followsPointer: false)
                    .frame(height: 62)
                Text(label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Palette.ghostSelected : (isHovering ? Palette.ghostHover : .clear), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Palette.lineStrong : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TintPicker: View {
    let title: String
    @Binding var value: UInt32?
    let swatches: [UInt32]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 7) {
                Button {
                    value = nil
                } label: {
                    Text("Auto")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(value == nil ? Palette.onInk : Palette.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(value == nil ? Palette.ink : Color.white.opacity(0.08), in: .capsule)
                }
                .buttonStyle(.plain)
                ForEach(swatches, id: \.self) { hex in
                    Button {
                        value = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.white.opacity(value == hex ? 0.9 : 0.15), lineWidth: value == hex ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
