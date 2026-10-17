import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Orb

// Ajustes, first use and the empty chat: the logic behind them (statuses, validation, routing, summaries, prompts, contrast).

// MARK: Contrast

struct PaletteContrastTests {
    /// WCAG relative luminance of an sRGB color given as 0...1 components.
    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// `ink` (with its own alpha) painted over `background`, against `background`.
    private func contrast(_ ink: Color, over background: Color) -> Double {
        let fg = NSColor(ink).usingColorSpace(.sRGB)!, bg = NSColor(background).usingColorSpace(.sRGB)!
        let alpha = Double(fg.alphaComponent)
        func mix(_ f: CGFloat, _ b: CGFloat) -> Double { Double(f) * alpha + Double(b) * (1 - alpha) }
        let top = luminance(mix(fg.redComponent, bg.redComponent), mix(fg.greenComponent, bg.greenComponent),
                            mix(fg.blueComponent, bg.blueComponent))
        let base = luminance(Double(bg.redComponent), Double(bg.greenComponent), Double(bg.blueComponent))
        return (max(top, base) + 0.05) / (min(top, base) + 0.05)
    }

    @Test func textInksMeetAAOnEverySurface() {
        for surface in [Palette.canvas, Palette.chrome, Palette.surface, Palette.raised] {
            for ink in [Palette.faint, Palette.muted, Palette.secondary, Palette.ink] {
                #expect(contrast(ink, over: surface) >= 4.5)
            }
        }
    }

    @Test func hintStaysQuieterThanFaint() {
        #expect(contrast(Palette.hint, over: Palette.canvas) < 4.5)
        #expect(contrast(Palette.hint, over: Palette.canvas) < contrast(Palette.faint, over: Palette.canvas))
        #expect(contrast(Palette.faint, over: Palette.canvas) < contrast(Palette.muted, over: Palette.canvas), "the steps stay distinct")
    }
}

// MARK: Providers

struct ProviderPresentationTests {
    private func account(_ kind: ProviderKind, models: Int = 0, enabled: Bool = true, url: String? = nil) -> ProviderAccount {
        var account = ProviderAccount(kind: kind)
        account.isEnabled = enabled
        if let url { account.baseURL = url }
        account.models = (0..<models).map { ProviderModel(id: "m\($0)", name: "m\($0)", format: .chat) }
        return account
    }

    private func status(_ kind: ProviderKind, models: Int = 0, connected: Bool = false, enabled: Bool = true, url: String? = nil,
                        error: ProviderCheckFailure? = nil, checking: Bool = false) -> ProviderStatus {
        ProviderStatus.make(kind: kind, account: account(kind, models: models, enabled: enabled, url: url), isConnected: connected,
                            lastError: error, isChecking: checking)
    }

    @Test func everyProviderIsInExactlyOneGroupAndTheGroupsKeepTheirOrder() {
        let all = ProviderGroup.allCases.flatMap(\.kinds)
        #expect(Set(all) == Set(ProviderKind.allCases))
        #expect(all.count == ProviderKind.allCases.count)
        #expect(ProviderGroup.allCases.map(\.title) == ["Assinatura (sem chave)", "Chave de API", "No seu Mac", "Avançado"])
        #expect(ProviderKind.claudeCode.group == .subscription)
        #expect(ProviderKind.xai.group == .apiKey)
        #expect(ProviderKind.ollama.group == .local)
        #expect(ProviderKind.custom.group == .advanced)
    }

    @Test func aMissingKeyOrSignInIsSaidBeforeAnythingElse() {
        #expect(status(.xai) == .needsKey)
        #expect(status(.chatgpt) == .needsSignIn)
        #expect(status(.claudeCode) == .needsSignIn)
        #expect(status(.custom, url: "") == .needsURL)
    }

    @Test func aLocalServerIsNeverConnectedWithoutAnswering() {
        #expect(status(.ollama, error: .unreachable) == .offline(host: "localhost:11434"))
        #expect(status(.lmstudio, error: .unreachable) == .offline(host: "localhost:1234"))
        #expect(status(.ollama) == .noModels, "an answer with no models is said so, not 'Conectado' alone")
        #expect(status(.ollama, checking: true) == .checking)
        #expect(status(.ollama, models: 3).isReady)
    }

    @Test func aGatewayIsUnverifiedUntilItAnswers() {
        #expect(status(.custom, url: "https://gw.example/v1") == .unverified)
        #expect(status(.custom, models: 2, url: "https://gw.example/v1").isReady)
        #expect(status(.custom, url: "https://gw.example/v1", error: .other("HTTP 401")) == .failed("HTTP 401"))
    }

    @Test func aFailureAfterModelsWereLoadedIsStillShown() {
        #expect(status(.xai, models: 4, connected: true, error: .other("chave inválida")) == .failed("chave inválida"))
        #expect(status(.xai, models: 4, connected: true).isReady)
        #expect(status(.xai, models: 4, connected: true, enabled: false) == .disabled)
    }

    @Test func summariesAreShortAndHonest() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(ProviderStatus.needsKey.summary() == "Falta a chave")
        #expect(ProviderStatus.offline(host: "x").summary() == "Servidor não encontrado")
        #expect(ProviderStatus.ready(count: 1, updated: nil).summary() == "1 modelo")
        #expect(ProviderStatus.ready(count: 3, updated: nil).summary() == "3 modelos")
        let withTime = ProviderStatus.ready(count: 3, updated: now.addingTimeInterval(-7200)).summary(now: now)
        #expect(withTime.hasPrefix("3 modelos · atualizado "))
        #expect(ProviderStatus.noModels.summary() == "Conectado · sem modelos")
    }

    @Test func explanationsNameTheServerAndWhatToCheck() {
        let offline = ProviderStatus.offline(host: "localhost:11434")
        #expect(offline.explanation(for: .ollama) == "Não encontrei o Ollama em localhost:11434. Ele está aberto?")
        #expect(offline.explanation(for: .lmstudio)?.contains("LM Studio") == true)
        #expect(offline.explanation(for: .custom)?.contains("localhost:11434") == true)
        #expect(ProviderStatus.ready(count: 1, updated: nil).explanation(for: .xai) == nil)
    }

    @Test func connectionFailuresAreToldFromOtherErrors() {
        #expect(ProviderCheck.failure(from: URLError(.cannotConnectToHost)) == .unreachable)
        #expect(ProviderCheck.failure(from: LLMError.network(code: URLError.Code.timedOut.rawValue, message: "x")) == .unreachable)
        if case .other(let message) = ProviderCheck.failure(from: LLMError.http(status: 500, message: "no")) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("an HTTP error is not 'unreachable'")
        }
        #expect(ProviderCheck.hostLabel("http://localhost:11434/v1") == "localhost:11434")
        #expect(ProviderCheck.hostLabel("https://gw.example/v1") == "gw.example")
    }

    @Test func aRefusedKeyIsToldFromOtherHTTPErrors() {
        for status in [401, 403] {
            if case .rejected(let message) = ProviderCheck.failure(from: LLMError.http(status: status, message: "Invalid API key")) {
                #expect(message.contains("Chave ou login inválido"))
            } else {
                Issue.record("\(status) with a bad key is a refused credential")
            }
        }
        // A spent balance, a model the workspace turned off or a plan without API are not a bad key.
        for message in ["Insufficient balance", "Model x is disabled", "upgrade_required"] {
            #expect(ProviderCheck.failure(from: LLMError.http(status: 401, message: message)) == .other(LLMError.http(status: 401, message: message).localizedDescription))
        }
        #expect(ProviderCheck.failure(from: LLMError.http(status: 429, message: "slow")) != .rejected("x"))
        let refused = ProviderStatus.make(kind: .openai, account: account(.openai, models: 2), isConnected: true,
                                          lastError: .rejected("Chave ou login inválido (401). Confira em Ajustes → Modelos. Detalhe do provedor: x"),
                                          isChecking: false)
        #expect(refused.isProblem)
        #expect(refused.explanation(for: .openai) == "Chave ou login inválido (401). Detalhe do provedor: x")
    }

    @Test func removingSaysWhatItDoes() {
        #expect(ProviderKind.xai.removeButtonTitle == "Remover e apagar a chave")
        #expect(ProviderKind.chatgpt.removeButtonTitle == "Remover e sair da conta")
        #expect(ProviderKind.ollama.removeButtonTitle == "Remover")
    }
}

struct GatewayFormTests {
    @Test func theAddressNeedsAnHTTPSchemeAndAHost() {
        #expect(GatewayForm.urlState("") == .empty)
        #expect(GatewayForm.urlState("   ") == .empty)
        #expect(GatewayForm.urlState("meu-gateway.exemplo/v1") == .invalid)
        #expect(GatewayForm.urlState("ftp://gw.example") == .invalid)
        #expect(GatewayForm.urlState("http://") == .invalid)
        #expect(GatewayForm.urlState("https://meu-gateway.exemplo/v1") == .valid)
        #expect(GatewayForm.urlState(" http://localhost:8080/v1 ") == .valid)
    }

    @Test func headersAreOnePerLineAndBadLinesAreReported() {
        let parsed = GatewayForm.parseHeaders("x-api-key: abc\n\nAuthorization:Bearer t:o:k\nsem-dois-pontos\n: sem-nome\nNome Com Espaço: v")
        #expect(parsed.values == ["x-api-key": "abc", "Authorization": "Bearer t:o:k"])
        #expect(parsed.badLines == [4, 5, 6])
        #expect(GatewayForm.headerWarning(parsed) == "As linhas 4, 5, 6 não estão no formato Nome: valor.")
        #expect(GatewayForm.headerWarning(GatewayForm.parseHeaders("a: b")) == nil)
        #expect(GatewayForm.headerWarning(GatewayForm.parseHeaders("a b")) == "A linha 1 não está no formato Nome: valor.")
    }

    @Test func everyFormatHasADescription() {
        for format in [APIFormat.chat, .responses, .messages] { #expect(!GatewayForm.formatSubtitle(format).isEmpty) }
    }
}

// MARK: Ajustes routing

struct SettingsRouterTests {
    @Test func theTabAskedForWins() {
        #expect(SettingsRouter.initialTab(request: "permissions", stored: "general", isProviderReady: false) == .permissions)
        #expect(SettingsRouter.initialTab(request: "models", stored: "permissions", isProviderReady: true) == .models)
    }

    @Test func withoutAModelItOpensOnModelsElseOnTheLastTab() {
        #expect(SettingsRouter.initialTab(request: "", stored: "general", isProviderReady: false) == .models)
        #expect(SettingsRouter.initialTab(request: "", stored: "permissions", isProviderReady: true) == .permissions)
        #expect(SettingsRouter.initialTab(request: "", stored: "", isProviderReady: true) == .general)
        #expect(SettingsRouter.initialTab(request: "lixo", stored: "lixo", isProviderReady: true) == .general)
    }

    @Test func requestingATabWritesItWhereSettingsReadsIt() throws {
        let suite = "orb.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsRouter.request(.permissions, defaults: defaults)
        #expect(defaults.string(forKey: SettingsRouter.requestKey) == "permissions")
    }

    @Test func tabsAreInTheOrderGeralModelosNavegadorUsoPermissoes() {
        #expect(SettingsTab.allCases.map(\.title) == ["Geral", "Modelos", "Navegador", "Uso", "Permissões"])
    }

    @Test @MainActor func theVersionLineReadsTheBundleOrSaysItIsADevBuild() {
        #expect(GeneralSettings.versionText(["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "7"]) == "1.2.0 (7)")
        #expect(GeneralSettings.versionText(["CFBundleShortVersionString": "1.2.0"]) == "1.2.0")
        #expect(GeneralSettings.versionText([:]) == "versão de desenvolvimento")
        #expect(GeneralSettings.versionText(["CFBundleShortVersionString": "1.0.243", "CFBundleVersion": "243", "OrbGitCommit": "9ac1745"]) == "1.0.243 · 9ac1745")
        #expect(GeneralSettings.versionText(["CFBundleShortVersionString": "1.0.243", "CFBundleVersion": "243"]) == "1.0.243")
        #expect(GeneralSettings.versionText(["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1", "OrbGitCommit": "unknown"]) == "1.0.0 (1)")
    }
}

// MARK: Permissões

@MainActor
struct MacPermissionsSummaryTests {
    private let essentials: [MacPermissionKind] = [.accessibility, .screenRecording, .fullDiskAccess]

    private func statuses(_ value: MacPermissionStatus) -> [MacPermissionKind: MacPermissionStatus] {
        Dictionary(uniqueKeysWithValues: (essentials + AutomationTarget.known.map(MacPermissionKind.automation)).map { ($0, value) })
    }

    @Test func nothingIsSaidUntilEverythingWasRead() {
        #expect(!MacPermissionsSummary.make(statuses: [:], notifications: .allowed).isLoaded)
        #expect(!MacPermissionsSummary.make(statuses: statuses(.granted), notifications: nil).isLoaded)
        #expect(MacPermissionsSummary.make(statuses: [:], notifications: nil).title == "Verificando…")
    }

    @Test func allGrantedIsTudoPronto() {
        let summary = MacPermissionsSummary.make(statuses: statuses(.granted), notifications: .allowed)
        #expect(summary.isComplete)
        #expect(summary.title == "Tudo pronto")
        #expect(summary.automationText == "9 de 9 liberados")
    }

    @Test func missingEssentialsAreCountedAndNamed() {
        var all = statuses(.granted)
        all[.accessibility] = .notGranted
        all[.fullDiskAccess] = .denied
        let summary = MacPermissionsSummary.make(statuses: all, notifications: .denied)
        #expect(summary.title == "Faltam 3 permissões")
        #expect(summary.missing == ["Acessibilidade", "Acesso Total ao Disco", "Notificações"])
        all[.fullDiskAccess] = .granted
        #expect(MacPermissionsSummary.make(statuses: all, notifications: .allowed).title == "Falta 1 permissão")
    }

    @Test func anUnknownStatusIsNotCountedAsMissingAndAutomationDoesNotCount() {
        var all = statuses(.appNotRunning)
        all[.accessibility] = .granted
        all[.screenRecording] = .granted
        all[.fullDiskAccess] = .unknown
        let summary = MacPermissionsSummary.make(statuses: all, notifications: .unavailable)
        #expect(summary.isComplete)
        #expect(summary.automationGranted == 0)
    }

    @Test func notificationAnswersMapToStatuses() {
        #expect(NotificationPermission.allowed.status == .granted)
        #expect(NotificationPermission.denied.status == .denied)
        #expect(NotificationPermission.notDetermined.status == .notDetermined)
        #expect(NotificationPermission.map(.authorized) == .allowed)
        #expect(NotificationPermission.map(.denied) == .denied)
        #expect(NotificationPermission.map(.notDetermined) == .notDetermined)
    }

    @Test func theModelReadsNotificationsWithItsOtherRows() async {
        let stub = StubMacPermissionSystem()
        let model = MacPermissionsModel(checker: MacPermissionChecker(system: stub), notifications: { .denied })
        #expect(!model.summary.isLoaded)
        await model.refresh()
        #expect(model.notifications == .denied)
        #expect(model.summary.missing.contains("Notificações"))
    }

    @Test func eachRowOffersOneButtonThatFitsItsState() {
        let mail = MacPermissionKind.automation(AutomationTarget.known[0])
        #expect(PermissionRowAction.resolve(kind: .accessibility, status: nil, canAsk: false) == nil)
        #expect(PermissionRowAction.resolve(kind: .accessibility, status: .granted, canAsk: false) == nil)
        #expect(PermissionRowAction.resolve(kind: .accessibility, status: .notGranted, canAsk: true) == .ask)
        #expect(PermissionRowAction.resolve(kind: .screenRecording, status: .notGranted, canAsk: false) == .openSystemSettings)
        #expect(PermissionRowAction.resolve(kind: .fullDiskAccess, status: .notGranted, canAsk: false) == .openSystemSettings)
        #expect(PermissionRowAction.resolve(kind: mail, status: .appNotRunning, canAsk: false) == .openAppAndAsk(appName: "Mail"))
        #expect(PermissionRowAction.resolve(kind: mail, status: .denied, canAsk: false) == .openSystemSettings)
        #expect(PermissionRowAction.resolve(kind: mail, status: .notDetermined, canAsk: true) == .ask)
        #expect(PermissionRowAction.openAppAndAsk(appName: "Mail").title == "Abrir Mail e pedir")
        #expect(PermissionRowAction.openSystemSettings.title == "Abrir Ajustes do Sistema")
    }

    @Test func aFailedToolMapsToTheRowThatFixesIt() async {
        let stub = StubMacPermissionSystem()
        let checker = MacPermissionChecker(system: stub)
        #expect(await MacPermissionProblem.accessibility.permissionKind(checker) == .accessibility)
        #expect(await MacPermissionProblem.fullDiskAccess.permissionKind(checker) == .fullDiskAccess)
        #expect(await MacPermissionProblem.automation(app: "Mail").permissionKind(checker) == .automation(AutomationTarget.known[0]))
        #expect(await MacPermissionProblem.automation(app: nil).permissionKind(checker) == nil)
    }
}

// MARK: First use

struct LocalServerProbeTests {
    @Test func offersOnlyTheServersThatAnswerWithOK() async {
        StubProtocol.responses.withLock {
            $0["ollama.probe.test"] = .init(status: 200, body: "{\"data\":[]}")
            $0["lmstudio.probe.test"] = .init(status: 500)
        }
        let found = await LocalServerProbe.running(
            candidates: [(.ollama, URL(string: "http://ollama.probe.test/v1/models")!),
                         (.lmstudio, URL(string: "http://lmstudio.probe.test/v1/models")!)],
            session: StubProtocol.session)
        #expect(found == [.ollama])
    }

    @Test func aServerThatIsNotThereIsNotOffered() async {
        StubProtocol.responses.withLock { $0["gone.probe.test"] = .init(failure: URLError.cannotConnectToHost.rawValue) }
        let found = await LocalServerProbe.running(candidates: [(.ollama, URL(string: "http://gone.probe.test/v1/models")!)],
                                                   session: StubProtocol.session)
        #expect(found.isEmpty)
    }
}

@MainActor
struct FirstRunStyleTests {
    @Test func theCardSpeaksAboutTheOrbInTheChatAndAboutModelsInAjustes() {
        #expect(FirstRunStyle.chat(botName: "Atlas").title == "Vamos preparar Atlas")
        #expect(FirstRunStyle.chat(botName: "Lia").title == "Vamos preparar Lia")
        #expect(FirstRunStyle.chat(botName: "").title == "Vamos preparar seu Orb")
        #expect(FirstRunStyle.settings.title == "Conecte um modelo")
    }

    @Test func tryingToSendWithoutAModelNudgesTheCardAndKeepsTheTranscriptClean() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-test-\(UUID().uuidString)")
        defer { removeTestFolder(folder) }
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false)
        let id = try #require(model.bots.first?.id)
        model.providers = []
        model.defaultModel = ""
        #expect(!model.isProviderReady)
        let before = model.setupNudge
        #expect(!model.send("oi", to: id, fromUser: true))
        #expect(model.setupNudge == before + 1)
        #expect(model.orbTranscript(id).items.isEmpty, "no notice is written for what the card already says")
        // Not typed by the user (a routine, quick ask): the notice stays, so the failure is not silent.
        #expect(!model.send("oi", to: id))
        #expect(model.orbTranscript(id).items.count == 1)
    }
}

@MainActor
struct FirstRunModelTests {
    private struct Boom: LocalizedError { var errorDescription: String? { "chave recusada" } }

    private func makeModel() -> (AppModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-test-\(UUID().uuidString)")
        let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false)
        model.providers = []
        model.defaultModel = ""
        return (model, folder)
    }

    private func steps(for model: AppModel) -> FirstRunModel {
        let steps = FirstRunModel()
        steps.attach(model)
        steps.readyDelay = .milliseconds(150)
        return steps
    }

    private func addOllama(_ model: AppModel, models: Int) {
        model.addProvider(.ollama)
        model.updateProvider(.ollama) { $0.models = (0..<models).map { ProviderModel(id: "m\($0)", name: "m\($0)", format: .chat) } }
        if models > 0, ModelRef(model.defaultModel) == nil { model.defaultModel = ModelRef(provider: .ollama, model: "m0").text }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aConnectedModelShowsReadyForAMomentAndThenClears() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        let task = steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") { self.addOllama(model, models: 2) }
        #expect(steps.working == .local(.ollama))
        await waitFor { steps.connectedName != nil }
        #expect(steps.connectedName == "Ollama")
        #expect(steps.failure == nil)
        #expect(await task.value)
        #expect(steps.connectedName == nil)
        #expect(steps.working == nil)
        #expect(model.isProviderReady)
    }

    @Test func aServerWithoutModelsFailsWithAMessageAndStaysRetryable() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        let ok = await steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") { self.addOllama(model, models: 0) }.value
        #expect(!ok)
        #expect(steps.connectedName == nil && steps.working == nil)
        #expect(steps.failure?.choice == .local(.ollama))
        #expect(steps.failure?.message.contains("não tem nenhum modelo") == true)
        // The next try starts clean.
        #expect(await steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") { self.addOllama(model, models: 1) }.value)
        #expect(steps.failure == nil)
    }

    @Test func aWorkThatThrowsReportsItsOwnMessage() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        _ = await steps.connect(.chatgpt, kind: .chatgpt, name: "ChatGPT") { throw Boom() }.value
        #expect(steps.failure == .init(choice: .chatgpt, message: "chave recusada"))
        #expect(steps.working == nil)
    }

    @Test func aStaleDefaultGivesWayToTheProviderJustConnected() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        // The old default points to a provider that is listed but has no key: not usable, yet not gone either.
        model.addProvider(.xai)
        model.defaultModel = ModelRef(provider: .xai, model: "grok-4").text
        #expect(!model.isProviderReady)
        let steps = steps(for: model)
        let ok = await steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") {
            model.addProvider(.ollama)
            model.updateProvider(.ollama) { $0.models = [ProviderModel(id: "llama3", name: "llama3", format: .chat)] }
        }.value
        #expect(ok)
        #expect(model.defaultModel == ModelRef(provider: .ollama, model: "llama3").text)
        #expect(model.isProviderReady)
    }

    @Test func adoptingTurnsOnAProviderThatWasSwitchedOffAndKeepsAWorkingDefault() {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        addOllama(model, models: 2)
        model.updateProvider(.ollama) { $0.isEnabled = false }
        #expect(!model.isProviderReady)
        #expect(model.adoptDefaultModel(from: .ollama))
        #expect(model.account(.ollama)?.isEnabled == true)
        #expect(model.isProviderReady)
        model.updateProvider(.ollama) { $0.models.append(ProviderModel(id: "other", name: "other", format: .chat)) }
        model.defaultModel = ModelRef(provider: .ollama, model: "other").text
        #expect(!model.adoptDefaultModel(from: .ollama), "a default that works is left alone")
        #expect(model.defaultModel == ModelRef(provider: .ollama, model: "other").text)
    }

    @Test func aKeyThatFailsIsDiscardedWithWhetherTheProviderExistedBefore() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        var discarded: [(ProviderKind, Bool)] = []
        let ok = await steps.connectKey("  sk-ruim  ", kind: .openai, model: model,
                                        save: { key, _ in
                                            #expect(key == "sk-ruim", "the key is trimmed")
                                            throw Boom()
                                        },
                                        discard: { discarded.append(($0, $1)) }).value
        #expect(!ok)
        #expect(discarded.count == 1 && discarded[0].0 == .openai && discarded[0].1 == false)
        #expect(steps.failure?.choice == .key)
        #expect(steps.failure?.message == "Essa chave não funcionou: chave recusada")
        // With the provider already listed, the revert says so (it signs out instead of removing).
        let again = await steps.connectKey("sk-outra", kind: .openai, model: model,
                                           save: { _, _ in throw Boom() }, discard: { discarded.append(($0, $1)) }).value
        #expect(!again && discarded.count == 2 && discarded[1].1 == true)
    }

    @Test func aBlankKeyDoesNothing() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        let ok = await steps.connectKey("   ", kind: .openai, model: model, save: { _, _ in Issue.record("saved a blank key") }).value
        #expect(!ok && steps.working == nil && steps.failure == nil && model.account(.openai) == nil)
    }

    @Test func startingAnotherPathGivesUpTheOneStillWaiting() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        // A login nobody finishes: it waits until it is cancelled.
        let abandoned = steps.connect(.chatgpt, kind: .chatgpt, name: "ChatGPT") { try await Task.sleep(for: .seconds(60)) }
        #expect(steps.working == .chatgpt)
        let second = steps.connect(.local(.ollama), kind: .ollama, name: "Ollama") { self.addOllama(model, models: 1) }
        #expect(await abandoned.value == false)
        #expect(steps.failure == nil, "the abandoned path does not report an error")
        #expect(await second.value)
        #expect(steps.working == nil)
    }

    @Test func cancelFreesEveryPathAndSaysNothing() async {
        let (model, folder) = makeModel()
        defer { removeTestFolder(folder) }
        let steps = steps(for: model)
        let waiting = steps.connect(.claudeCode, kind: .claudeCode, name: "Claude Code") { try await Task.sleep(for: .seconds(60)) }
        steps.cancel()
        #expect(steps.working == nil && steps.failure == nil)
        #expect(await waiting.value == false)
        #expect(steps.working == nil && steps.failure == nil)
    }
}

// MARK: Empty chat

struct EmptyChatContentTests {
    private func bot(folder: String = "", _ capabilities: Set<Capability> = [.terminal, .browser, .computerUse]) -> Bot {
        var bot = Bot(name: "Atlas", role: "x", orb: OrbConfig())
        bot.workingDirectory = folder
        bot.capabilities = capabilities
        return bot
    }

    @Test func theHomeFolderGetsEverydayPromptsAndAnOwnFolderGetsPromptsAboutIt() {
        let home = EmptyChatContent.suggestions(for: bot(), interviewPending: false).map(\.text)
        #expect(home.contains("Organize minha pasta Downloads"))
        let own = EmptyChatContent.suggestions(for: bot(folder: "~/Orbs/Atlas"), interviewPending: false).map(\.text)
        #expect(!own.contains("Organize minha pasta Downloads"))
        #expect(own.contains("O que tem na sua pasta? Me dê um resumo"))
    }

    @Test func theHomeFolderWrittenOutIsStillTheHomeFolder() {
        let home = "/Users/teste"
        let written = bot(folder: home)
        #expect(EmptyChatContent.folderText(for: written, home: home) == "Trabalha na pasta pessoal")
        #expect(EmptyChatContent.suggestions(for: written, interviewPending: false, home: home).first?.text == "Organize minha pasta Downloads")
        #expect(EmptyChatContent.folderText(for: bot(folder: home + "/Orbs/Atlas"), home: home) == "Trabalha em ~/Orbs/Atlas")
        let own = EmptyChatContent.suggestions(for: bot(folder: home + "/Orbs/Atlas"), interviewPending: false, home: home)
        #expect(own.first?.text == "O que tem na sua pasta? Me dê um resumo")
    }

    @Test func aCapabilityThatIsOffOffersNothingThatNeedsIt() {
        let terminalOnly = EmptyChatContent.suggestions(for: bot(.init([.terminal])), interviewPending: false).map(\.symbol)
        #expect(!terminalOnly.contains("globe") && !terminalOnly.contains("calendar"))
        let webOnly = EmptyChatContent.suggestions(for: bot(.init([.browser])), interviewPending: false).map(\.symbol)
        #expect(webOnly == ["globe"])
        let none = EmptyChatContent.suggestions(for: bot(.init()), interviewPending: false)
        #expect(none.count == 3, "a text-only Orb still gets prompts")
        #expect(none.allSatisfy { !["globe", "calendar", "folder"].contains($0.symbol) })
    }

    @Test func theInterviewOfferComesFirstAndTheListIsCapped() {
        let list = EmptyChatContent.suggestions(for: bot(), interviewPending: true)
        #expect(list.first?.symbol == "questionmark.bubble")
        #expect(list.count == EmptyChatContent.limit)
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(EmptyChatContent.suggestions(for: bot(), interviewPending: false).count == EmptyChatContent.limit)
    }

    @Test func promptsMixKindsInsteadOfExhaustingOne() {
        let symbols = EmptyChatContent.suggestions(for: bot(), interviewPending: false).map(\.symbol)
        #expect(symbols.prefix(3) == ["folder", "globe", "calendar"])
    }

    @Test func theFolderAndCapabilityLinesUseTheAppsWords() {
        #expect(EmptyChatContent.folderText(for: bot()) == "Trabalha na pasta pessoal")
        #expect(EmptyChatContent.folderText(for: bot(folder: "~/Orbs/Atlas")) == "Trabalha em ~/Orbs/Atlas")
        #expect(EmptyChatContent.folderText(for: bot(.init([.browser]))) == nil, "no Terminal, no folder to speak of")
        #expect(EmptyChatContent.capabilityNames(for: bot()) == ["Terminal e arquivos", "Navegar na web", "Controlar apps do Mac"])
        #expect(EmptyChatContent.capabilityNames(for: bot(.init())) == [])
    }
}

struct ModelSearchTests {
    private func choices(_ query: String) -> [(account: ProviderAccount, models: [ProviderModel])] {
        let openrouter = ProviderAccount(kind: .openrouter)
        let xai = ProviderAccount(kind: .xai)
        let all = [
            (account: openrouter, models: [ProviderModel(id: "meta/llama-4", name: "Llama 4", format: .chat),
                                           ProviderModel(id: "openai/gpt-5", name: "GPT-5", format: .chat)]),
            (account: xai, models: [ProviderModel(id: "grok-4", name: "Grok 4", format: .chat)]),
        ]
        return all.map { (account: $0.account, models: $0.models.filter { ModelSearch.matches($0, query) }) }.filter { !$0.models.isEmpty }
    }

    @Test func returnPicksTheFirstModelShown() {
        #expect(ModelSearch.submitted(choices("gpt"), query: "gpt", allowsDefault: true) == "openrouter/openai/gpt-5")
        #expect(ModelSearch.submitted(choices("4"), query: "4", allowsDefault: false) == "openrouter/meta/llama-4")
        #expect(ModelSearch.submitted(choices("grok"), query: "grok", allowsDefault: true) == "xai/grok-4")
    }

    @Test func returnWithNothingTypedPicksTheDefaultWhenThereIsOne() {
        #expect(ModelSearch.submitted(choices(""), query: "", allowsDefault: true) == "")
        #expect(ModelSearch.submitted(choices(""), query: "", allowsDefault: false) == nil)
    }

    @Test func returnWithNoMatchDoesNothing() {
        #expect(ModelSearch.submitted(choices("zzz"), query: "zzz", allowsDefault: true) == nil)
    }
}
