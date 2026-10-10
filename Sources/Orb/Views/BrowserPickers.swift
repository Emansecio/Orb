import SwiftUI

// The two pickers under "Navegar na web" in the Orb's panel: which browser the Orb uses and where it searches, each with
// what is installed or missing said on the spot. The words and states are plain values (tested); the view only draws them.

/// What the pickers say about the engine and the search provider.
enum BrowserPickerCopy {
    /// How a status line looks.
    enum Tone: Equatable, Sendable { case ready, warning, neutral }

    /// Where a status line sends the person, when it has something to do in Ajustes.
    enum Action: Equatable, Sendable {
        case installEngine, addSearchKey

        var title: String {
            switch self {
            case .installEngine: "Instalar em Ajustes"
            case .addSearchKey: "Adicionar em Ajustes"
            }
        }

        var tip: String {
            switch self {
            case .installEngine: Tip.installBrowserEngine
            case .addSearchKey: Tip.addSearchKey
            }
        }
    }

    struct Line: Equatable, Sendable {
        var text: String
        var tone: Tone
        var action: Action?

        var symbol: String {
            switch tone {
            case .ready: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .neutral: "circle.dotted"
            }
        }
    }

    /// The pickers show while the Orb has "Navegar na web".
    static func showsPickers(_ capabilities: Set<Capability>) -> Bool { capabilities.contains(.browser) }

    /// What the chosen engine has on this Mac. `status` is nil while it is being looked for.
    static func engineLine(_ engine: BrowserEngineKind, status: BrowserEngineStatus?) -> Line {
        guard engine.drivesABrowser else { return Line(text: "Não precisa instalar nada", tone: .ready) }
        guard let status else { return Line(text: "Conferindo o que está instalado…", tone: .neutral) }
        guard !status.isReady else { return Line(text: "Pronto", tone: .ready) }
        let missing = status.missing.map(\.name).joined(separator: " e ")
        return Line(text: "Não instalado: falta \(missing). Até lá, o Orb só lê e pesquisa em páginas simples.", tone: .warning,
                    action: .installEngine)
    }

    /// One line on what the provider is.
    static func searchSummary(_ provider: SearchProvider) -> String {
        switch provider {
        case .duckduckgo: "Sem conta. Pelo navegador do Orb, ou pela página simples do DuckDuckGo."
        case .google: "Sempre pelo navegador do Orb, nunca por API."
        case .tinyfish: "API com cota gratuita. Precisa da sua chave, guardada no Keychain."
        }
    }

    /// What the search provider needs and lacks, or nil when there is nothing to say. `hasKey` is nil while it is being read;
    /// `browserIsReady` is whether the Orb's engine can run (Google needs it).
    static func searchLine(_ provider: SearchProvider, engine: BrowserEngineKind, browserIsReady: Bool?, hasKey: Bool?) -> Line? {
        switch provider {
        case .duckduckgo:
            return nil
        case .google:
            guard browserIsReady == false || !engine.drivesABrowser else { return nil }
            return Line(text: "Sem navegador pronto, a busca vai para o DuckDuckGo.", tone: .warning,
                        action: engine.drivesABrowser ? .installEngine : nil)
        case .tinyfish:
            switch hasKey {
            case nil: return nil
            case true?: return Line(text: "Chave guardada", tone: .ready)
            case false?: return Line(text: "Sem chave. Até lá, a busca vai para o DuckDuckGo.", tone: .warning, action: .addSearchKey)
            }
        }
    }
}

extension SettingsRouter {
    /// The "Navegador" tab of Ajustes, where engines are installed and the TinyFish key is kept: its raw value is this.
    static let browserTab = "browser"

    static func requestBrowser(defaults: UserDefaults = .standard) { defaults.set(browserTab, forKey: requestKey) }

    @MainActor static func openBrowser(using openSettings: OpenSettingsAction) {
        requestBrowser()
        openSettings()
    }
}

/// The two pickers and their status lines, rows of the Orb's "O que pode usar" section.
struct BrowserPickerRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let botID: UUID
    /// What the engine has on this Mac, read in the background; read again when the app comes back to the front (the person
    /// may have installed it in the Terminal meanwhile).
    @State private var status: BrowserEngineStatus?
    @State private var hasKey: Bool?
    @State private var comingBack = 0

    private struct Check: Hashable {
        var engine: BrowserEngineKind
        var provider: SearchProvider
        var comingBack: Int
    }

    var body: some View {
        if let live = model.liveBot(botID) {
            let bot = live.bot
            Group {
                Picker("Navegador", selection: engineBinding) {
                    ForEach(BrowserEngineKind.allCases) { Text($0.label).tag($0) }
                }
                .help(Tip.browserEngine)
                caption(bot.browserEngine.summary)
                statusLine(BrowserPickerCopy.engineLine(bot.browserEngine, status: status?.engine == bot.browserEngine ? status : nil))

                Picker("Pesquisa", selection: providerBinding) {
                    ForEach(SearchProvider.allCases) { Text($0.label).tag($0) }
                }
                .help(Tip.searchProvider)
                caption(BrowserPickerCopy.searchSummary(bot.searchProvider))
                if let line = BrowserPickerCopy.searchLine(bot.searchProvider, engine: bot.browserEngine,
                                                           browserIsReady: status?.engine == bot.browserEngine ? status?.isReady : nil,
                                                           hasKey: hasKey) {
                    statusLine(line)
                }
            }
            .task(id: Check(engine: bot.browserEngine, provider: bot.searchProvider, comingBack: comingBack)) {
                let engine = bot.browserEngine, provider = bot.searchProvider
                async let found = model.browserEngineStatus(for: engine)
                async let key = model.hasSearchKey(for: provider)
                let (newStatus, newKey) = await (found, key)
                guard !Task.isCancelled else { return }
                status = newStatus
                hasKey = provider == .tinyfish ? newKey : nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in comingBack += 1 }
        }
    }

    private var engineBinding: Binding<BrowserEngineKind> {
        Binding(get: { model.liveBot(botID)?.bot.browserEngine ?? .default },
                set: { model.setBrowserEngine($0, for: botID) })
    }

    private var providerBinding: Binding<SearchProvider> {
        Binding(get: { model.liveBot(botID)?.bot.searchProvider ?? .duckduckgo },
                set: { model.setSearchProvider($0, for: botID) })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSwap(text)
    }

    private func statusLine(_ line: BrowserPickerCopy.Line) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(line.text, systemImage: line.symbol)
                .font(.caption)
                .foregroundStyle(line.tone == .warning ? Palette.warn : line.tone == .ready ? Palette.ok : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSwap(line.text)
            if let action = line.action {
                Button(action.title, systemImage: "arrow.up.right") { SettingsRouter.openBrowser(using: openSettings) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(action.tip)
                    .transition(.quiet)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
