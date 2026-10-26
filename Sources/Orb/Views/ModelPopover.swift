import SwiftUI

/// The composer's model list: a search field, the models used lately, the app's default and then every provider's
/// models, in a lazily built list (a gateway may offer hundreds). Providers fold, so the list starts short.
struct ModelPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let botID: UUID
    let done: () -> Void

    @State private var query = ""
    @State private var recents = RecentModels()
    /// Providers the user folded (or that start folded because the list is long).
    @State private var folded: Set<ProviderKind> = []
    @State private var didSetFolds = false
    /// The list's measured height, already capped: a long list re-measures as rows come and go, and only a change under the
    /// cap needs to redraw the popover.
    @State private var listHeight = ModelPopover.maxListHeight
    private nonisolated static let maxListHeight: CGFloat = 320
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selection = model.live(botID).modelID
        let listing = ModelListing(choices: model.modelChoices, recents: recents.ids, query: query)
        let isSearch = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            ModelSearchField(query: $query) { if let first = listing.submitted(query: query) { choose(first) } }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !isSearch {
                        ModelPopoverRow(name: defaultName.name, detail: defaultName.detail, isSelected: selection.isEmpty) { choose("") }
                        if !listing.recents.isEmpty {
                            header("Recentes")
                            ForEach(listing.recents, id: \.ref) { recent in
                                ModelPopoverRow(name: recent.name, detail: recent.provider, isSelected: selection == recent.ref) { choose(recent.ref) }
                            }
                        }
                    }
                    ForEach(listing.groups, id: \.provider) { group in
                        let isFolded = !isSearch && folded.contains(group.provider)
                        providerHeader(group, isFolded: isFolded, isSearch: isSearch)
                        if !isFolded {
                            ForEach(group.models) { item in
                                let ref = ModelRef(provider: group.provider, model: item.id).text
                                ModelPopoverRow(name: item.name, detail: "", isSelected: selection == ref, help: item.id) { choose(ref) }
                                    // Folding a provider fades its rows (the popover keeps its size); typing in the search does not.
                                    .transition(isSearch ? .identity : .quiet)
                            }
                        }
                    }
                    if listing.groups.isEmpty && isSearch {
                        Text("Nenhum modelo encontrado.")
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if listing.groups.isEmpty {
                        Text("Conecte um provedor para escolher modelos.")
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .transition(.quiet)
                    }
                }
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { min($0.size.height, Self.maxListHeight) } action: { listHeight = $0 }
            }
            // A short list ends where it ends; only a long one fills the popover and scrolls.
            .frame(height: listHeight)
            Divider()
            Button {
                done()
                SettingsRouter.open(.models, using: openSettings)
            } label: {
                Label("Gerenciar provedores…", systemImage: "gearshape")
                    .font(Typography.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(Tip.modelSettings)
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 320)
        .onAppear {
            recents = RecentModels()
            guard !didSetFolds else { return }
            didSetFolds = true
            let choices = model.modelChoices
            if ModelSearch.isLongList(choices) {
                let current = ModelRef(selection.isEmpty ? model.defaultModel : selection)?.provider
                folded = Set(choices.map(\.account.kind)).subtracting(current.map { [$0] } ?? [])
            }
        }
    }

    /// The row that follows the app's default model: its name, with what makes it special in gray.
    private var defaultName: (name: String, detail: String) {
        guard let ref = ModelRef(model.defaultModel) else { return ("Padrão do app", "") }
        let name = model.account(ref.provider)?.models.first { $0.id == ref.model }?.name ?? ref.model
        return (name, "padrão do app")
    }

    private func choose(_ ref: String) {
        model.update(botID) { $0.model = ref }
        recents.record(ref)
        done()
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// A provider's name; a button that folds its models unless a search is showing them all.
    private func providerHeader(_ group: ModelListing.Group, isFolded: Bool, isSearch: Bool) -> some View {
        Button {
            guard !isSearch else { return }
            if folded.contains(group.provider) { folded.remove(group.provider) } else { folded.insert(group.provider) }
        } label: {
            HStack(spacing: 4) {
                if !isSearch {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        // The arrow turns in the content curve; under Reduce Motion it just takes its new direction.
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: isFolded)
                        .frame(width: 10)
                }
                Text(group.provider.label)
                Text("\(group.models.count)").foregroundStyle(Palette.faint)
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isSearch ? "" : (isFolded ? "Mostra os modelos deste provedor" : "Recolhe os modelos deste provedor"))
        .accessibilityLabel("\(group.provider.label), \(group.models.count) \(group.models.count == 1 ? "modelo" : "modelos")")
        .accessibilityHint(isSearch ? "" : (isFolded ? "Mostrar modelos" : "Recolher modelos"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row of a model list: the name, what makes it special in gray, and a check on the chosen one.
struct ModelPopoverRow: View {
    let name: String
    let detail: String
    let isSelected: Bool
    var help = ""
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail).font(Typography.small).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentText)
                }
            }
            .font(Typography.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering, in: .rect)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
