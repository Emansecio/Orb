import SwiftUI

/// Picks a model as "provider/model", grouped by provider. With `allowsDefault`, "" means the app's default model.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var title = "Modelo"
    var allowsDefault = true

    private var defaultLabel: String {
        guard let ref = ModelRef(model.defaultModel) else { return "Padrão" }
        let name = model.account(ref.provider)?.models.first { $0.id == ref.model }?.name ?? ref.model
        return "Padrão (\(name))"
    }

    private var isKnown: Bool {
        selection.isEmpty || model.modelChoices.contains { choice in
            choice.models.contains { ModelRef(provider: choice.account.kind, model: $0.id).text == selection }
        }
    }

    var body: some View {
        Picker(title, selection: $selection) {
            if allowsDefault { Text(defaultLabel).tag("") }
            if !isKnown { Text(ModelRef(selection)?.model ?? selection).tag(selection) }
            ForEach(model.modelChoices, id: \.account.kind) { choice in
                Section(choice.account.kind.label) {
                    ForEach(choice.models) { item in
                        Text(item.name).tag(ModelRef(provider: choice.account.kind, model: item.id).text)
                    }
                }
            }
        }
    }
}
