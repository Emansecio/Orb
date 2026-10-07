import SwiftUI

/// Picks a bot's model: the provider default ("") or one of the fetched models.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var title = "Modelo"

    private var choices: [String] {
        var list = model.models
        if !selection.isEmpty && !list.contains(selection) { list.insert(selection, at: 0) }
        return list
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text(model.provider.defaultModel.isEmpty ? "Padrão" : "Padrão (\(model.provider.defaultModel))").tag("")
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
    }
}
