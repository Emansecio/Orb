import Foundation
import Testing
@testable import Orb

/// The Orb's model picker when the chosen model's provider cannot answer: the model keeps its name, and a line says why.
@Suite final class ModelUnavailableNoteTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbModelNote-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    @MainActor private func model(connected: Set<ProviderKind>) -> AppModel {
        let store = Store(directory: root)
        store.save(AppState.initial)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        var account = ProviderAccount(kind: .claudeCode)
        account.models = [ProviderModel(id: "sonnet", name: "Sonnet 5.5", format: .claudeCode)]
        model.providers = [account]
        model.publishConnections(connected)
        return model
    }

    @Test @MainActor func aModelOfAProviderNotConnectedYetIsStillSaidByItsName() {
        let model = model(connected: [])
        #expect(model.modelName("claudeCode/sonnet") == "Sonnet 5.5")
        #expect(model.modelName("claudeCode/outro") == "outro")
        #expect(model.modelName("ollama/llama") == "llama")
    }

    @Test @MainActor func theNoteSaysWhyTheModelCannotAnswer() {
        let off = model(connected: [])
        #expect(off.modelUnavailableNote("claudeCode/sonnet")
                == "Claude Code não está conectado. Conecte em Ajustes → Modelos ou escolha outro modelo.")
        #expect(off.modelUnavailableNote("ollama/llama")
                == "Ollama não está mais em Ajustes. Escolha outro modelo ou adicione o provedor de novo.")

        off.beginConnectionCheck()
        #expect(off.modelUnavailableNote("claudeCode/sonnet") == "Conferindo a conexão com Claude Code…")

        let on = model(connected: [.claudeCode])
        #expect(on.modelUnavailableNote("claudeCode/sonnet") == nil)
        #expect(on.modelUnavailableNote("") == nil)
        on.providers[0].isEnabled = false
        #expect(on.modelUnavailableNote("claudeCode/sonnet") == "Claude Code está desligado em Ajustes → Modelos.")
    }
}
