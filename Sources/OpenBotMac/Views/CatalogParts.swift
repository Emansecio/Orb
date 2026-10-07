import SwiftUI

// Building blocks shared by the Skills and Connectors screens: the Instaladas/Explorar switch,
// the catalog search header, badges and loading/empty states.

enum CatalogTab: Hashable {
    case installed, explore
}

/// Pill switch at the top of a catalog screen.
struct CatalogTabBar: View {
    @Binding var tab: CatalogTab
    let installedTitle: String
    let installedCount: Int

    var body: some View {
        HStack(spacing: 4) {
            pill(.installed, title: installedTitle, symbol: "checkmark.circle", count: installedCount)
            pill(.explore, title: "Explorar", symbol: "sparkle.magnifyingglass", count: nil)
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: .capsule)
    }

    private func pill(_ value: CatalogTab, title: String, symbol: String, count: Int?) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(tab == value ? Palette.onInk.opacity(0.55) : Palette.faint)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tab == value ? Palette.onInk : Palette.secondary)
            .background(tab == value ? Palette.ink : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Search field plus quick-search chips. Searching starts after a short pause in typing.
struct CatalogSearchHeader: View {
    @Binding var query: String
    let prompt: String
    let suggestions: [String]
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.faint)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                if !query.isEmpty {
                    Button("Limpar", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .card(radius: 12, stroke: isFocused ? Palette.lineStrong : Palette.line)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { query = suggestion }
                            .buttonStyle(ChipStyle(isSelected: query.lowercased() == suggestion.lowercased()))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .onAppear { isFocused = true }
    }
}

struct ChipStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Palette.onInk : Palette.secondary)
            .background(isSelected ? Palette.ink : Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: .capsule)
    }
}

/// Small capsule label ("Fonte conhecida", "Remoto", "206 mil instalações").
struct CatalogBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = Palette.muted

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

/// Square icon tile used at the top-left of catalog cards.
struct CatalogIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .frame(width: 36, height: 36)
            .background(Palette.raised, in: .rect(cornerRadius: 10))
    }
}

/// Loading, error and empty states for a catalog search.
struct CatalogStateView: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    var slowHint: String?
    let retry: () -> Void
    @State private var isSlow = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if isSlow, let slowHint {
                        Text(slowHint).font(.system(size: 12)).foregroundStyle(Palette.faint)
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    isSlow = true
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Não foi possível buscar", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Tentar de novo", action: retry).buttonStyle(SecondaryPillStyle())
                }
            } else if isEmpty {
                ContentUnavailableView.search
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

extension Int {
    /// "206 mil instalações", "1,2 mi instalações", "980 instalações".
    var installsLabel: String {
        let value = Double(self)
        let number: String = switch self {
        case 1_000_000...: (value / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + " mi"
        case 1_000...: (value / 1_000).formatted(.number.precision(.fractionLength(0))) + " mil"
        default: "\(self)"
        }
        return number + (self == 1 ? " instalação" : " instalações")
    }
}
