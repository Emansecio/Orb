import SwiftUI

// Building blocks shared by the Skills and Connectors screens: the Instaladas/Explorar switch,
// the catalog search header, badges and loading/empty states.

enum CatalogTab: Hashable {
    /// The gallery of services (only the Conectores page has one).
    case gallery, installed, explore

    /// What VoiceOver says about a tab of the switch besides its name: the selected one is announced as such.
    static func traits(isSelected: Bool) -> AccessibilityTraits { isSelected ? .isSelected : [] }
}

/// Pill switch at the top of a catalog screen.
struct CatalogTabBar: View {
    @Binding var tab: CatalogTab
    let installedTitle: String
    let installedCount: Int
    /// The title of the gallery pill; nil leaves the pill out.
    var galleryTitle: String?
    /// What ⌘F does on the installed tab instead of going to the catalog; nil when that list has nothing to search.
    var findInstalled: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one dark pill slides to the chosen tab through this namespace.
    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 4) {
            if let galleryTitle { pill(.gallery, title: galleryTitle, symbol: "square.grid.2x2", count: nil) }
            pill(.installed, title: installedTitle, symbol: "checkmark.circle", count: installedCount)
            pill(.explore, title: "Explorar", symbol: "sparkle.magnifyingglass", count: nil)
        }
        // Bound to the choice: the pill slides and the titles change color with it; it jumps under Reduce Motion.
        .animation(Motion.selection(reduceMotion: reduceMotion), value: tab)
        .padding(3)
        .background(Color.white.opacity(0.06), in: .capsule)
        .background {
            // ⌘F outside the explore tab (the explore tab's header has its own button for it). Only the catalog has a
            // search field, so the page goes there (the field takes focus when it appears), unless the installed list
            // has a filter of its own (`findInstalled`: Skills, when the list is long).
            if tab != .explore {
                Button("Buscar no catálogo") {
                    if tab == .installed, let findInstalled { findInstalled() } else { tab = .explore }
                }
                    .keyboardShortcut(AppShortcut.find)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func pill(_ value: CatalogTab, title: String, symbol: String, count: Int?) -> some View {
        Button {
            tab = value
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
            .background {
                if tab == value {
                    Capsule().fill(Palette.ink).matchedGeometryEffect(id: "pilula", in: pillSpace)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(value == .installed ? Tip.showInstalled : value == .gallery ? Tip.showGallery : Tip.showCatalog)
        .accessibilityAddTraits(CatalogTab.traits(isSelected: tab == value))
    }
}

/// The same pill switch for any set of tabs that move between parts of one screen (the "Quem ele é | Aparência" of the
/// new Orb sheet). Native segmented controls stay for picking a value inside a form; a switch that moves between parts
/// looks like the catalog's, so the two never nest with the same face.
struct PillTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        let symbol: String
    }

    @Binding var selection: Value
    let items: [Item]
    /// A switch inside a part already chosen by louder pills ("Criar conversando | Formulário" under "Quem ele é"): the
    /// same track, the chosen one in gray instead of white, and no icons.
    var isQuiet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.value) { item in pill(item) }
        }
        .animation(Motion.selection(reduceMotion: reduceMotion), value: selection)
        .padding(3)
        .background(Color.white.opacity(0.06), in: .capsule)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func pill(_ item: Item) -> some View {
        let isSelected = selection == item.value
        return Button {
            selection = item.value
        } label: {
            Group {
                if isQuiet {
                    Text(item.title)
                } else {
                    Label(item.title, systemImage: item.symbol)
                        .labelStyle(FixedIconLabelStyle())
                }
            }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, isQuiet ? 4 : 6)
                .foregroundStyle(isSelected ? (isQuiet ? Palette.ink : Palette.onInk) : Palette.secondary)
                .background {
                    if isSelected {
                        Capsule().fill(isQuiet ? Palette.ghostSelected : Palette.ink).matchedGeometryEffect(id: "pilula", in: pillSpace)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(CatalogTab.traits(isSelected: isSelected))
    }
}

/// What a catalog page shows under its tabs. Another tab fades in over the one before (§2.13), which leaves faster
/// (`.pageSwap`): the two are laid over each other instead of stacked while they swap; the page's `tab` drives the fade.
struct CatalogTabContent<Content: View>: View {
    let tab: CatalogTab
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                .id(tab)
                .transition(.pageSwap)
        }
        .motion(Motion.crossFade, value: tab)
        // What scrolls up under the pills fades out instead of being cut. A gradient on top, not a mask: a mask would turn the
        // scroll content into one flat layer. The page's own top margin is deeper than this, so at rest nothing is dimmed.
        .overlay(alignment: .top) {
            LinearGradient(colors: [Palette.canvas, Palette.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Search field plus quick-search chips. Searching starts after a short pause in typing; ⌘F focuses the field.
struct CatalogSearchHeader: View {
    @Binding var query: String
    let prompt: String
    var suggestions: [String] = []
    /// A sentence behind an (i) button next to the field (where the results come from).
    var info: String?
    @FocusState private var isFocused: Bool
    @State private var isShowingInfo = false

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
                        .help(Tip.clearSearch)
                }
                if let info {
                    Button("Sobre a busca", systemImage: "info.circle") { isShowingInfo.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.muted)
                        .help(info)
                        .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
                            Text(info)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                                .frame(width: 260, alignment: .leading)
                                .padding(14)
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .card(radius: 12, stroke: isFocused ? Palette.lineStrong : Palette.line)
            .background {
                // ⌘F, like the search of the other pages.
                Button("Buscar") { isFocused = true }
                    .keyboardShortcut(AppShortcut.find)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { query = suggestion }
                                .buttonStyle(ChipStyle(isSelected: query.lowercased() == suggestion.lowercased()))
                                .help(Tip.searchFor(suggestion))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
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
            Text(text).lineLimit(1).contentTransition(.opacity)
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
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1) }
    }
}

/// What an "Explorar" page is showing, as one value (the page's swaps are bound to it): the hint before anything is
/// searched, the search loading, its error, no result, or the results. Typing is not a phase: the changes of the text
/// itself are never animated.
enum ExplorePhase: Equatable {
    case hint, loading, failed, empty, results

    static func of(isSearching: Bool, isLoading: Bool, error: String?, isEmpty: Bool) -> ExplorePhase {
        if !isSearching { return .hint }
        if isLoading { return .loading }
        if error != nil { return .failed }
        return isEmpty ? .empty : .results
    }
}

/// The wait before "this is taking long" shows: true only when it ran to the end, false when cancelled.
enum SlowHint {
    static func arrives(after interval: Duration = .seconds(3)) async -> Bool {
        do { try await Task.sleep(for: interval) } catch { return false }
        return !Task.isCancelled
    }
}

/// Whether a search that was started for some text is still the one the page is asking for. A "Tentar de novo" search runs
/// outside the page's `.task(id:)`, so typing never cancels it: when it comes back after the text changed, it must not
/// put its results, its error or its end of loading over the newer search.
enum RegistryQuery {
    static func isCurrent(_ started: String, query: String) -> Bool {
        started == query.trimmingCharacters(in: .whitespaces)
    }
}

/// Loading, error and empty states for a catalog search.
struct CatalogStateView: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    var slowHint: String?
    /// Draw still placeholders for result cards while loading (instead of a spinner alone).
    var skeleton = false
    let retry: () -> Void
    @State private var isSlow = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 18) {
                    if skeleton {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                            ForEach(0..<6, id: \.self) { _ in SkeletonCard() }
                        }
                        .accessibilityHidden(true)
                    }
                    DelayedSpinner()
                    if isSlow, let slowHint {
                        Text(slowHint).font(.system(size: 12)).foregroundStyle(Palette.faint)
                            .transition(.opacity)
                    }
                }
                .task {
                    // Each load starts without the hint; a cancelled wait never turns it on.
                    isSlow = false
                    isSlow = await SlowHint.arrives()
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
        .padding(.top, skeleton && isLoading ? 0 : 40)
    }
}

/// A result card's outline, still: a grid of cards loading at once should not run a shimmer each.
private struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(Palette.raised).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.raised).frame(width: 120, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(Palette.raised.opacity(0.6)).frame(width: 80, height: 8)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.raised.opacity(0.7)).frame(height: 8)
                RoundedRectangle(cornerRadius: 3).fill(Palette.raised.opacity(0.7)).frame(height: 8)
                RoundedRectangle(cornerRadius: 3).fill(Palette.raised.opacity(0.7)).frame(width: 150, height: 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

/// "Usar com": every Orb (the default) or only the ones ticked. Choosing an Orb is all it takes; the connector or
/// skill follows the choice (for connectors, the Orb's "Conectores" switch is turned on when the sheet is saved).
struct OrbScopePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var orbIDs: Set<UUID>?
    /// With its determiner, so the gender agrees ("este conector", "esta skill").
    var noun = "este conector"
    /// Added to the explanation while every Orb is chosen.
    var allNote = ""

    private var isChosen: Binding<Bool> {
        Binding(
            get: { orbIDs != nil },
            set: { chosen in
                if !chosen { orbIDs = nil; return }
                let first = model.lastSelectedBotID.flatMap { id in model.bots.first { $0.id == id }?.id } ?? model.bots.first?.id
                orbIDs = first.map { [$0] } ?? []
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Usar com", selection: isChosen) {
                Text("Todos os Orbs").tag(false)
                Text("Só alguns").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let selected = orbIDs {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.bots) { bot in
                        Toggle(bot.name, isOn: Binding(
                            get: { selected.contains(bot.id) },
                            set: { on in
                                var ids = orbIDs ?? []
                                if on { ids.insert(bot.id) } else { ids.remove(bot.id) }
                                orbIDs = ids
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 2)
                .transition(.quiet)
            }
            Text(orbIDs == nil
                 ? "Todos os Orbs, inclusive os que você criar depois, podem usar \(noun).\(allNote.isEmpty ? "" : " " + allNote) Você pode mudar depois."
                 : "Só os Orbs marcados usam \(noun). Você pode mudar depois.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
                .textSwap(orbIDs == nil)
        }
    }
}

extension Int {
    /// "206 mil instalações", "1,2 mi instalações", "980 instalações".
    var installsLabel: String {
        let value = Double(self)
        let number: String = switch self {
        // 999.500 and up round to "1.000 mil" in the thousands, so they already read as a million.
        case 999_500...: (value / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(.app)) + " mi"
        case 1_000...: (value / 1_000).formatted(.number.precision(.fractionLength(0)).locale(.app)) + " mil"
        default: "\(self)"
        }
        return number + (self == 1 ? " instalação" : " instalações")
    }
}
