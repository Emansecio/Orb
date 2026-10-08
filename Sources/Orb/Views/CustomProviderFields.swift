import SwiftUI

/// Extra setup for the custom "Gateway próprio" provider: which wire format the gateway speaks, its headers,
/// and manual model ids (many gateways have no /models). This is the sanctioned way to run the Orb engine
/// against your own Claude/Max subscription: a gateway you run holds the token; the app only talks to it.
struct CustomProviderFields: View {
    @Environment(AppModel.self) private var model
    let account: ProviderAccount

    @State private var headersText = ""
    @State private var newModel = ""

    private var isClaudeGateway: Bool { account.format == .messages }

    var body: some View {
        Picker("Formato", selection: Binding(
            get: { account.format },
            set: { format in
                model.updateProvider(.custom) {
                    $0.format = format
                    for index in $0.models.indices { $0.models[index].format = format }
                }
            }
        )) {
            Text("Chat (OpenAI)").tag(APIFormat.chat)
            Text("Responses (OpenAI)").tag(APIFormat.responses)
            Text("Messages (Anthropic / Claude)").tag(APIFormat.messages)
        }

        if isClaudeGateway {
            Label("Formato do Claude. Para usar sua assinatura (inclusive Max) no motor do app, rode um gateway que faça o login da sua conta e aponte a URL acima para ele. O token fica no gateway, não no Orb.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Cabeçalhos (um por linha, Nome: valor)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $headersText)
                .font(.body.monospaced())
                .frame(minHeight: 48)
                .onChange(of: headersText) { saveHeaders() }
        }

        VStack(alignment: .leading, spacing: 4) {
            if account.models.isEmpty {
                Text("Nenhum modelo. Clique em “Atualizar modelos” ou adicione os ids à mão.")
                    .font(.caption)
                    .foregroundStyle(Palette.faint)
            }
            ForEach(account.models) { item in
                HStack {
                    Text(item.id).font(.caption.monospaced())
                    Spacer()
                    Button("Remover", systemImage: "minus.circle") { remove(item) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack {
                TextField("Adicionar modelo pelo id", text: $newModel, prompt: Text("ex.: claude-fable-5-1"))
                    .onSubmit(addModel)
                Button("Adicionar", action: addModel).disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task(id: account.kind) { headersText = serialize(account.headers) }
    }

    private func serialize(_ headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func saveHeaders() {
        let pairs = headersText.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
        }
        model.updateProvider(.custom) { $0.headers = Dictionary(pairs, uniquingKeysWith: { _, last in last }) }
    }

    private func addModel() {
        let id = newModel.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        model.updateProvider(.custom) {
            if !$0.models.contains(where: { $0.id == id }) {
                $0.models.append(ProviderModel(id: id, name: id, format: $0.format))
                $0.modelsUpdatedAt = .now
            }
        }
        newModel = ""
    }

    private func remove(_ item: ProviderModel) {
        model.updateProvider(.custom) { $0.models.removeAll { $0.id == item.id } }
    }
}
