import Foundation
import Testing
@testable import Orb

/// The model lists are refreshed in the background: a provider whose list fails is not asked again at every pass.
@Suite final class ModelRefreshTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbModelRefresh-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private actor Asked {
        private(set) var count = 0
        func note() { count += 1 }
    }

    @MainActor private func model(failing: Bool, asked: Asked) -> AppModel {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .ollama)] // local: usable without a key
        model.loadModels = { _ in
            await asked.note()
            if failing { throw LLMError.http(status: 503, message: "gateway fora do ar") }
            return [ProviderModel(id: "m", name: "m", format: .chat)]
        }
        return model
    }

    @Test @MainActor func aListThatFailsIsNotAskedAgainAtEveryPass() async {
        let asked = Asked()
        let model = model(failing: true, asked: asked)
        let start = Date.now

        await model.refreshAllModels(now: start)
        await model.refreshAllModels(now: start.addingTimeInterval(30)) // the next passes of the scheduler
        await model.refreshAllModels(now: start.addingTimeInterval(60))
        #expect(await asked.count == 1)

        await model.refreshAllModels(now: start.addingTimeInterval(ModelRefreshBackoff.firstWait + 1)) // after the first wait
        #expect(await asked.count == 2)
        await model.refreshAllModels(now: start.addingTimeInterval(ModelRefreshBackoff.firstWait + 60)) // the wait doubled
        #expect(await asked.count == 2)
        await model.refreshAllModels(now: start.addingTimeInterval(ModelRefreshBackoff.firstWait * 4)) // 10 minutes after the second failure
        #expect(await asked.count == 3)
    }

    @Test @MainActor func aListThatLoadsIsKeptForHours() async {
        let asked = Asked()
        let model = model(failing: false, asked: asked)
        await model.refreshAllModels()
        await model.refreshAllModels()
        #expect(await asked.count == 1)
        #expect(model.providers.first?.models.map(\.id) == ["m"])
    }

    @Test @MainActor func aFreshListReadByAnOlderBuildIsReadAgainAtOnce() async {
        let asked = Asked()
        let model = model(failing: false, asked: asked)
        // Read a minute ago, but by a build that did not keep each model's thinking levels.
        model.updateProvider(.ollama) {
            $0.models = [ProviderModel(id: "m", name: "m", format: .chat)]
            $0.modelsUpdatedAt = .now.addingTimeInterval(-60)
            $0.catalogVersion = nil
        }
        await model.refreshAllModels()
        #expect(await asked.count == 1)
        #expect(model.providers.first?.catalogVersion == ModelCatalog.version)
        await model.refreshAllModels()
        #expect(await asked.count == 1)
    }
}
