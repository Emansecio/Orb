import AppKit
import SwiftUI

// "Importar de outro assistente → Marketplace do Grok Bot": the marketplace's bots to pick from, with a search and the
// marketplace's categories. Picking one reads its page into the same preview a pasted link gets (`ImportPanel`).

struct MarketplaceGallery: View {
    /// The page of the bot in the preview, and of the one being read (links, as `OrbImport.link`).
    let chosen: String?
    let reading: String?
    let onPick: (MarketplaceBot) -> Void

    /// The list a `--snapshot` draws, without the network.
    @MainActor static var preloaded: [MarketplaceBot]?

    private enum Load: Equatable {
        case loading
        case failed(String)
        case loaded([MarketplaceBot])
    }

    @State private var load: Load = MarketplaceGallery.preloaded.map { .loaded($0) } ?? .loading
    @State private var query = ""
    @State private var category: String?
    @State private var attempt = 0
    @FocusState private var isSearching: Bool

    var body: some View {
        Group {
            switch load {
            case .loading:
                HStack(spacing: 8) {
                    DelayedSpinner()
                    Text("Lendo o marketplace…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .card(radius: 12)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Tentar de novo") { attempt += 1 }
                        .buttonStyle(SecondaryPillStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card(radius: 12)
            case .loaded(let bots):
                gallery(bots)
            }
        }
        .task(id: attempt) { await fetch() }
    }

    private func gallery(_ bots: [MarketplaceBot]) -> some View {
        let shown = GrokMarketplace.filter(bots, query: query, category: category)
        return VStack(alignment: .leading, spacing: 10) {
            searchField
            categoryChips(GrokMarketplace.categories(in: bots))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown, id: \.id) { bot in
                        let page = GrokMarketplace.Link.page(bot.id).url.absoluteString
                        MarketplaceRow(bot: bot, isChosen: chosen == page, isReading: reading == page) { onPick(bot) }
                    }
                }
                .padding(4)
                if shown.isEmpty {
                    Text(query.isEmpty ? "Nenhum bot nesta categoria." : "Nenhum bot com “\(query)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .frame(height: 300)
            .card(radius: 12)
            HStack {
                Text(shown.count == bots.count ? "\(bots.count) bots" : "\(shown.count) de \(bots.count) bots")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Button("Ver no site") { NSWorkspace.shared.open(GrokMarketplace.home) }
                    .buttonStyle(GhostStyle())
                    .hangsOnTrailingEdge()
                    .help(Tip.importOpenMarketplace)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
            TextField("Buscar bot", text: $query, prompt: Text("Buscar por nome, assunto ou autor"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearching)
            if !query.isEmpty {
                Button("Limpar", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.faint)
                    .help(Tip.clearSearch)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(radius: 10, stroke: isSearching ? Palette.lineStrong : Palette.line)
    }

    private func categoryChips(_ categories: [String]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button("Todos") { category = nil }
                    .buttonStyle(ChipStyle(isSelected: category == nil))
                ForEach(categories, id: \.self) { name in
                    Button(GrokMarketplace.categoryLabel(name)) { category = category == name ? nil : name }
                        .buttonStyle(ChipStyle(isSelected: category == name))
                }
            }
        }
        .scrollIndicators(.never)
        .help(Tip.importMarketplaceCategory)
    }

    private func fetch() async {
        if case .loaded = load { return }
        load = .loading
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[MarketplaceBot], MarketplaceFailure> in
            do { return .success(try await GrokMarketplace.catalog()) } catch {
                return .failure(error as? MarketplaceFailure ?? .unreadable)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let bots): load = .loaded(bots)
        case .failure(let failure): load = .failed(failure.errorDescription ?? "")
        }
    }

    /// The color of a bot's card, from the marketplace's name for it.
    static func color(_ name: String) -> Color {
        switch name {
        case "green": Color(hex: 0x2FB36B)
        case "violet": Color(hex: 0x8B5CF6)
        case "magenta": Color(hex: 0xD9468F)
        case "orange": Color(hex: 0xF08A24)
        case "cyan": Color(hex: 0x1FB5C9)
        case "red": Color(hex: 0xE5484D)
        case "blue": Color(hex: 0x3B82F6)
        case "yellow": Color(hex: 0xD9A514)
        case "brown": Color(hex: 0x9A6B47)
        case "black": Color(hex: 0x3A3A3A)
        default: Color(hex: 0x6B6B6B)
        }
    }
}

private struct MarketplaceRow: View {
    let bot: MarketplaceBot
    let isChosen: Bool
    let isReading: Bool
    let onPick: () -> Void
    @State private var isHovering = false

    private var summary: String { bot.summary.isEmpty ? bot.description : bot.summary }

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(bot.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(MarketplaceGallery.color(bot.color), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(bot.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                        if !bot.creatorName.isEmpty {
                            Text("de \(bot.creatorName)").font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1)
                        }
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                ZStack {
                    if isReading {
                        DelayedSpinner().transition(.opacity)
                    } else if isChosen {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentText)
                            .transition(.opacity)
                    }
                }
                .frame(width: 16, height: 26)
                .motion(Motion.content, value: isReading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isChosen ? Palette.ghostSelected : isHovering ? Palette.ghostHover : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Tip.importPickBot)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
