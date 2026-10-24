import SwiftUI

/// Picks a model as "provider/model", grouped by provider. With `allowsDefault`, "" means the app's default model.
///
/// A `Picker` builds a row for every model before it shows anything, which a gateway that lists hundreds of them
/// turns into half a second or more every time the panel opens. Past `ModelSearch.longListAbove` models the field is a button
/// that opens a searchable list instead, which builds only the rows on screen. In a menu (`inMenu`) the list is
/// already built lazily, so it stays as it was.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var title = "Modelo"
    var allowsDefault = true
    var inMenu = false

    private var defaultLabel: String {
        guard let ref = ModelRef(model.defaultModel) else { return "Padrão" }
        // Without the default model's account connected there is no name to show, and the raw id would read as noise.
        guard let name = model.account(ref.provider)?.models.first(where: { $0.id == ref.model })?.name else { return "Padrão" }
        return "Padrão (\(name))"
    }

    private var isKnown: Bool {
        selection.isEmpty || model.modelChoices.contains { choice in
            choice.models.contains { ModelRef(provider: choice.account.kind, model: $0.id).text == selection }
        }
    }

    var body: some View {
        let choices = model.modelChoices
        if !inMenu, ModelSearch.isLongList(choices) {
            SearchableModelField(selection: $selection, title: title, allowsDefault: allowsDefault,
                                 defaultLabel: defaultLabel, choices: choices)
        } else {
            Picker(title, selection: $selection) {
                if allowsDefault { Text(defaultLabel).tag("") }
                // A model of a provider that is not connected (yet): still said by its name, not its id.
                if !isKnown { Text(model.modelName(selection)).tag(selection) }
                ForEach(choices, id: \.account.kind) { choice in
                    Section(choice.account.kind.label) {
                        ForEach(choice.models) { item in
                            Text(item.name).tag(ModelRef(provider: choice.account.kind, model: item.id).text)
                        }
                    }
                }
            }
        }
    }
}

/// The long-list form of `ModelPicker`: the chosen model's name, and a popover with search to change it.
private struct SearchableModelField: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    let title: String
    let allowsDefault: Bool
    let defaultLabel: String
    let choices: [(account: ProviderAccount, models: [ProviderModel])]
    @State private var isOpen = false

    private var currentLabel: String {
        if selection.isEmpty { return allowsDefault ? defaultLabel : "Escolher…" }
        return model.modelName(selection)
    }

    var body: some View {
        LabeledContent(title) {
            Button { isOpen = true } label: {
                // Looks like the pop-up button of a Picker in a Form (the "Esforço" and "Permissões" rows beside it): the value
                // in the same weight and color, and the chevron in the same small rounded box.
                HStack(spacing: 6) {
                    Text(currentLabel).lineLimit(1).truncationMode(.middle)
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 15, height: 17)
                        .background(Palette.ghostSelected, in: .rect(cornerRadius: 4))
                }
                .padding(.trailing, 2) // the native pop-up keeps its box this far in from the row's edge
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Tip.chooseModel)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                ModelChooser(selection: $selection, allowsDefault: allowsDefault, defaultLabel: defaultLabel,
                             choices: choices) { isOpen = false }
            }
            .accessibilityLabel(title)
            .accessibilityValue(currentLabel)
        }
    }
}

/// Models matching what was typed (name or id, ignoring case and accents); everything when nothing was typed.
enum ModelSearch {
    /// More models than this make a long list: Ajustes shows a searchable popover instead of a `Picker`, and the
    /// composer's list starts with its providers folded.
    static let longListAbove = 40

    static func isLongList(_ choices: [(account: ProviderAccount, models: [ProviderModel])]) -> Bool {
        choices.reduce(0) { $0 + $1.models.count } > longListAbove
    }

    static func matches(_ model: ProviderModel, _ query: String) -> Bool {
        matches(model, words: words(query))
    }

    /// The words of a query, split once for a whole list.
    static func words(_ query: String) -> [Substring] { query.split(whereSeparator: \.isWhitespace) }

    static func matches(_ model: ProviderModel, words: [Substring]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = model.name + " " + model.id
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// What Return picks in the search field: the first model shown, or the app's default (tag "") when nothing was typed
    /// and the list offers one. Nil when there is nothing to pick.
    static func submitted(_ shown: [(account: ProviderAccount, models: [ProviderModel])], query: String, allowsDefault: Bool) -> String? {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return allowsDefault ? "" : nil }
        return shown.first.flatMap { choice in choice.models.first.map { ModelRef(provider: choice.account.kind, model: $0.id).text } }
    }
}

/// The "Buscar modelo" field above a model list: takes focus when it appears; Return calls `onSubmit`.
struct ModelSearchField: View {
    @Binding var query: String
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Buscar modelo", text: $query)
            .popoverSearchField()
            .focused($isFocused)
            .onSubmit(onSubmit)
            .padding(10)
            .onAppear { isFocused = true }
    }
}

/// Search field above a lazily built list of every enabled provider's models.
private struct ModelChooser: View {
    @Binding var selection: String
    let allowsDefault: Bool
    let defaultLabel: String
    let choices: [(account: ProviderAccount, models: [ProviderModel])]
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        let words = ModelSearch.words(query)
        let shown = choices.map { (account: $0.account, models: $0.models.filter { ModelSearch.matches($0, words: words) }) }
            .filter { !$0.models.isEmpty }
        VStack(spacing: 0) {
            ModelSearchField(query: $query) {
                if let tag = ModelSearch.submitted(shown, query: query, allowsDefault: allowsDefault) {
                    selection = tag
                    done()
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if allowsDefault && query.isEmpty {
                            row(defaultLabel, tag: "", help: "")
                        }
                        ForEach(shown, id: \.account.kind) { choice in
                            Section {
                                ForEach(choice.models) { item in
                                    row(item.name, tag: ModelRef(provider: choice.account.kind, model: item.id).text, help: item.id)
                                }
                            } header: {
                                Text(choice.account.kind.label)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial)
                            }
                        }
                        if shown.isEmpty {
                            Text("Nenhum modelo encontrado.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                // With hundreds of models the current one can be far below the first screen. The lazy stack has not laid
                // its rows out when the task starts, so scrolling waits a cycle to find the row.
                .task {
                    guard !selection.isEmpty else { return }
                    await Task.yield()
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private func row(_ name: String, tag: String, help: String) -> some View {
        ModelPopoverRow(name: name, detail: "", isSelected: selection == tag, help: help) {
            selection = tag
            done()
        }
        .id(tag)
    }
}

extension AppModel {
    /// The catalog entry of the model a bot's `model` string resolves to (its own, or the default when empty).
    func modelInfo(forModel model: String) -> ProviderModel? {
        guard let ref = ModelRef(model.isEmpty ? defaultModel : model) else { return nil }
        return account(ref.provider)?.models.first { $0.id == ref.model }
    }

    /// How a chosen model ("provider/model") is shown: by the provider's name for it ("Sonnet 5.5") whenever the provider
    /// is set up, connected or not; by its id otherwise.
    func modelName(_ selection: String) -> String {
        guard let ref = ModelRef(selection) else { return selection }
        return account(ref.provider)?.models.first { $0.id == ref.model }?.name ?? ref.model
    }

    /// Why the chosen model cannot answer now, for the line under the Orb's picker: its provider was removed, is off,
    /// is still being checked, or is not connected. Nil when it can (and for the app's default, "").
    func modelUnavailableNote(_ selection: String) -> String? {
        guard let ref = ModelRef(selection) else { return nil }
        // "Claude Code", not "Claude Code (sua assinatura)": the sentence already says what is wrong with it.
        let provider = ref.provider.label.components(separatedBy: " (").first ?? ref.provider.label
        guard let account = account(ref.provider) else {
            return "\(provider) não está mais em Ajustes. Escolha outro modelo ou adicione o provedor de novo."
        }
        if !account.isEnabled { return "\(provider) está desligado em Ajustes → Modelos." }
        if !hasCheckedConnections { return "Conferindo a conexão com \(provider)…" }
        if !isUsable(account) { return "\(provider) não está conectado. Conecte em Ajustes → Modelos ou escolha outro modelo." }
        return nil
    }
}
