import SwiftUI

/// The API-key row of Ajustes, the same for the providers and the web search: a saved key shows its state with "Trocar"
/// (and "Apagar" when the caller allows it); otherwise a secure field with "Salvar", "Cancelar" or "Obter chave".
///
/// The caller owns the typed `key` and `isReplacing` (it clears them when the save ends, or puts the key back when the
/// Keychain refuses) and does the saving: `onSave` runs on Return and on "Salvar", and must itself ignore a blank key.
struct SavedKeyField: View {
    let title: String
    let hasKey: Bool
    /// The saved key was refused by the service: says "Chave recusada" instead of "Chave salva".
    var isRejected = false
    @Binding var key: String
    @Binding var isReplacing: Bool
    /// "Salvar" is dimmed while the caller is busy with another request.
    var isWorking = false
    /// Where to get a key, shown while the field is empty and not replacing.
    var keyPage: URL?
    /// "Apagar" shows only when the caller can delete the saved key.
    var onDelete: (() -> Void)?
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    /// What sits after the secure field: the save button once something is typed, then the way out of "Trocar", then the
    /// link to get a key. Never "Salvar" for an empty field.
    enum Trailing: Equatable {
        case save, cancel, getKey, none

        static func of(key: String, isReplacing: Bool, hasKeyPage: Bool) -> Trailing {
            if !key.isEmpty { return .save }
            if isReplacing { return .cancel }
            return hasKeyPage ? .getKey : .none
        }
    }

    var body: some View {
        LabeledContent(title) {
            if hasKey && !isReplacing {
                HStack(spacing: 10) {
                    if isRejected {
                        Label("Chave recusada", systemImage: "exclamationmark.circle").foregroundStyle(Palette.warn)
                    } else {
                        Label("Chave salva", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                    }
                    Button("Trocar") {
                        isReplacing = true
                        isFocused = true
                    }
                    .help(Tip.replaceKey)
                    if let onDelete {
                        Button("Apagar", action: onDelete)
                            .help(Tip.deleteKey)
                    }
                }
                .buttonStyle(GhostStyle())
                .controlSize(.small)
            } else {
                HStack {
                    SecureField("Chave", text: $key, prompt: Text("Cole a chave"))
                        .labelsHidden()
                        .focused($isFocused)
                        .onSubmit(onSave)
                    switch Trailing.of(key: key, isReplacing: isReplacing, hasKeyPage: keyPage != nil) {
                    case .save:
                        Button("Salvar", action: onSave)
                            .disabled(isWorking)
                            .help(Tip.saveKey)
                            .chipButton()
                    case .cancel:
                        Button("Cancelar") { isReplacing = false }
                            .help(Tip.keepKey)
                            .buttonStyle(GhostStyle())
                            .controlSize(.small)
                    case .getKey:
                        if let keyPage {
                            Link("Obter chave", destination: keyPage)
                                .help(Tip.getKey)
                        }
                    case .none:
                        EmptyView()
                    }
                }
            }
        }
    }
}
