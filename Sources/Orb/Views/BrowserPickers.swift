import SwiftUI

// The two pickers under "Navegar na web" in the Orb's panel: how the Orb's browser runs and where it searches, each with
// what is installed or missing said on the spot. The words and states are plain values (tested); the view only draws them.

/// What the pickers say about the engine and the search provider.
enum BrowserPickerCopy {
    /// How a status line looks.
    enum Tone: Equatable, Sendable { case ready, warning, neutral }

    /// Where a status line sends the person, when it has something to do in Ajustes.
    enum Action: Equatable, Sendable {
        case installBrowser, addSearchKey

        var title: String {
            switch self {
            case .installBrowser: "Instalar em Ajustes"
            case .addSearchKey: "Adicionar em Ajustes"
            }
        }

        var tip: String {
            switch self {
            case .installBrowser: Tip.installBrowser
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

    /// What the Orb's browser has on this Mac. `status` is nil while it is being looked for.
    static func browserLine(status: BrowserStatus?) -> Line {
        guard let status else { return Line(text: "Conferindo o que está instalado…", tone: .neutral) }
        guard !status.isReady else { return Line(text: status.program.map { "Pronto · usa o \($0.label)" } ?? "Pronto", tone: .ready) }
        let missing = status.missing.map(\.name).joined(separator: " e ")
        return Line(text: "Não instalado: falta \(missing). Até lá, o Orb só lê e pesquisa em páginas simples.", tone: .warning,
                    action: .installBrowser)
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
    /// `browserIsReady` is whether the Orb's browser can run (Google needs it).
    static func searchLine(_ provider: SearchProvider, browserIsReady: Bool?, hasKey: Bool?) -> Line? {
        switch provider {
        case .duckduckgo:
            return nil
        case .google:
            guard browserIsReady == false else { return nil }
            return Line(text: "Sem navegador pronto, a busca vai para o DuckDuckGo.", tone: .warning, action: .installBrowser)
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
    /// The "Navegador" tab of Ajustes, where the browser is installed and the TinyFish key is kept: its raw value is this.
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
    /// What the browser has on this Mac, read in the background; read again when the app comes back to the front (the person
    /// may have installed it in the Terminal meanwhile).
    @State private var status: BrowserStatus?
    @State private var hasKey: Bool?
    @State private var comingBack = 0

    private struct Check: Hashable {
        var provider: SearchProvider
        var comingBack: Int
    }

    var body: some View {
        if let live = model.liveBot(botID) {
            let bot = live.bot
            Group {
                Picker("Navegador", selection: modeBinding) {
                    ForEach(BrowserMode.allCases) { Text($0.label).tag($0) }
                }
                .help(Tip.browserMode)
                caption(bot.browserMode.summary)
                statusLine(BrowserPickerCopy.browserLine(status: status))

                Picker("Pesquisa", selection: providerBinding) {
                    ForEach(SearchProvider.allCases) { Text($0.label).tag($0) }
                }
                .help(Tip.searchProvider)
                caption(BrowserPickerCopy.searchSummary(bot.searchProvider))
                if let line = BrowserPickerCopy.searchLine(bot.searchProvider, browserIsReady: status?.isReady, hasKey: hasKey) {
                    statusLine(line)
                }
            }
            .task(id: Check(provider: bot.searchProvider, comingBack: comingBack)) {
                let provider = bot.searchProvider
                async let found = model.browserStatus()
                async let key = model.hasSearchKey(for: provider)
                let (newStatus, newKey) = await (found, key)
                guard !Task.isCancelled else { return }
                status = newStatus
                hasKey = provider == .tinyfish ? newKey : nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in comingBack += 1 }
        }
    }

    private var modeBinding: Binding<BrowserMode> {
        Binding(get: { model.liveBot(botID)?.bot.browserMode ?? .default },
                set: { model.setBrowserMode($0, for: botID) })
    }

    private var providerBinding: Binding<SearchProvider> {
        Binding(get: { model.liveBot(botID)?.bot.searchProvider ?? .duckduckgo },
                set: { model.setSearchProvider($0, for: botID) })
    }

    /// The mode's and the provider's descriptions: the same line as under "Terminal e arquivos" and its siblings.
    private func caption(_ text: String) -> some View {
        Text(text)
            .capabilityCaption()
            .textSwap(text)
    }

    private func statusLine(_ line: BrowserPickerCopy.Line) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(line.text)
            } icon: {
                // Looking is work in progress, not a state: the app's own spinner (after its short delay), never an empty circle.
                if line.tone == .neutral {
                    DelayedSpinner().scaleEffect(0.6).frame(width: 14, height: 14)
                } else {
                    Image(systemName: line.symbol)
                }
            }
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
