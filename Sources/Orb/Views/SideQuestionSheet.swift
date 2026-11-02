import SwiftUI

/// A question about the chat that does not enter it (`SideQuestion`). Closing the sheet lets the answer go.
struct SideQuestionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    @State private var question = ""
    @State private var answer = ""
    @State private var problem: String?
    @State private var asking: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var isAsking: Bool { asking != nil }
    private var canAsk: Bool { !isAsking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            TextField("Sobre o que está nesta conversa…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.text)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(ask)
                .sheetTextField()
                .accessibilityLabel("Sua pergunta")
            if !answer.isEmpty {
                ScrollView {
                    MarkdownChunk(source: answer, cached: false)
                        .font(Palette.conversationFont)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            if let problem {
                Text(problem)
                    .font(Typography.label)
                    .foregroundStyle(Palette.warn)
            }
        }
        .padding(.horizontal, Spacing.sheetEdge)
        .padding(.bottom, Spacing.l)
        .orbSheet(CommandName.askAside, subtitle: "A resposta fica aqui: não entra na conversa nem na memória do Orb.", size: .large) {
            SheetFooter(cancelTitle: "Fechar", cancel: close, primaryTitle: isAsking ? "Perguntando…" : "Perguntar",
                        isPrimaryDisabled: !canAsk, primary: ask)
        }
        .onAppear { isFocused = true }
        .onDisappear { asking?.cancel() }
    }

    private func ask() {
        guard canAsk else { return }
        answer = ""
        problem = nil
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        asking = Task {
            let outcome = await model.askAside(text, of: botID) { answer = $0 }
            if case .failed(let reason) = outcome, !Task.isCancelled { problem = reason }
            asking = nil
        }
    }

    private func close() {
        asking?.cancel()
        dismiss()
    }
}
