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
        /// What happens meanwhile, said a step quieter than the problem itself (nil when there is none to name).
        var consequence: String?

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

    /// The pickers have something to tell the person (a browser not ready, a search that falls back): they show open then,
    /// whatever was folded. Still looking (`status` nil) is not a problem yet.
    static func hasProblem(capabilities: Set<Capability>, status: BrowserStatus?, provider: SearchProvider, hasKey: Bool?) -> Bool {
        guard showsPickers(capabilities) else { return false }
        let browserFailed = status.map { browserLine(status: $0).tone == .warning } ?? false
        let searchFailed = searchLine(provider, browserIsReady: status?.isReady, hasKey: hasKey)?.tone == .warning
        return browserFailed || searchFailed
    }

    /// What the Orb's browser has on this Mac. `status` is nil while it is being looked for. `orbName` is who only reads simple
    /// pages meanwhile ("Até lá, Atlas só lê páginas simples").
    static func browserLine(status: BrowserStatus?, orbName: String = "o Orb") -> Line {
        guard let status else { return Line(text: "Conferindo o que está instalado…", tone: .neutral) }
        guard !status.isReady else { return Line(text: status.program.map { "Pronto · usa o \($0.label)" } ?? "Pronto", tone: .ready) }
        let missing = status.missing.map(\.name).joined(separator: " e ")
        return Line(text: "Falta instalar \(missing)", tone: .warning, action: .installBrowser,
                    consequence: "Até lá, \(orbName) só lê páginas simples.")
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
            return Line(text: "Sem navegador pronto", tone: .warning, action: .installBrowser,
                        consequence: "A busca vai para o DuckDuckGo.")
        case .tinyfish:
            switch hasKey {
            case nil: return nil
            case true?: return Line(text: "Chave guardada", tone: .ready)
            case false?: return Line(text: "Sem chave", tone: .warning, action: .addSearchKey,
                                       consequence: "Até lá, a busca vai para o DuckDuckGo.")
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
        show(using: openSettings)
    }
}

/// "Navegar na web" in the Orb's "Pode usar" card: its switch row, which folds the two pickers (how the browser runs, where it
/// searches), and the proxy row when the Orb chose one. What the pickers say (a browser not installed, no search key) shows
/// only as a problem, and then they are open whatever was folded; the descriptions are the pickers' hover texts.
struct BrowserPickerRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(InspectorFold.browserKey) private var storedOpen = false
    let botID: UUID
    /// The switch of the capability itself: the pickers show while it is on.
    @Binding var isOn: Bool
    /// What the browser has on this Mac and whether the search key is kept. The panel reads them (it opens the whole card
    /// on a problem even while this part is folded away) and the app coming back to the front reads them again.
    let status: BrowserStatus?
    let hasKey: Bool?

    /// The pickers start under the title, past the icon column.
    static let indent: CGFloat = 28

    var body: some View {
        if let live = model.liveBot(botID) {
            let bot = live.bot
            let hasProblem = BrowserPickerCopy.hasProblem(capabilities: bot.capabilities, status: status,
                                                          provider: bot.searchProvider, hasKey: hasKey)
            let isOpen = isOn && InspectorFold.isOpen(stored: storedOpen, hasProblem: hasProblem)
            titleRow(bot, isOpen: isOpen, hasProblem: hasProblem)
                .foldContent()
            if isOn, let proxy = bot.browserProxy {
                proxyRow(proxy)
                    .transition(.quiet)
            }
            if isOpen {
                picker("Navegador", selection: modeBinding) {
                    ForEach(BrowserMode.allCases) { Text($0.label).tag($0) }
                }
                .help(Tip.browserMode)
                .padding(.leading, Self.indent)
                .foldContent()
                if let line = problemLine(BrowserPickerCopy.browserLine(status: status, orbName: bot.name)) {
                    statusLine(line)
                        .padding(.leading, Self.indent)
                        .foldContent()
                }
                picker("Pesquisa", selection: providerBinding) {
                    ForEach(SearchProvider.allCases) { Text($0.label).tag($0) }
                }
                .help(BrowserPickerCopy.searchSummary(bot.searchProvider))
                .padding(.leading, Self.indent)
                .foldContent()
                if let line = BrowserPickerCopy.searchLine(bot.searchProvider, browserIsReady: status?.isReady, hasKey: hasKey)
                    .flatMap(problemLine) {
                    statusLine(line)
                        .padding(.leading, Self.indent)
                        .foldContent()
                }
            }
        }
    }

    /// A picker with its title beside it when both fit, and above it in the narrowest panel: beside, the value was cut to
    /// "Segu…" and "DuckD…".
    private func picker<Value: Hashable, Options: View>(_ title: String, selection: Binding<Value>,
                                                        @ViewBuilder options: @escaping () -> Options) -> some View {
        // Title and picker apart in both: a Form's own picker row asks for more than it needs, so `ViewThatFits` stacked it
        // even at 360 pt. The title is hidden from VoiceOver, the picker keeps it as its label.
        let label = Text(title).accessibilityHidden(true)
        let field = Picker(title, selection: selection, content: options).labelsHidden()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                field.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                field
            }
        }
    }

    /// The status lines that are good news ("Pronto · usa o Google Chrome", "Chave guardada") or still looking are left out:
    /// the pickers speak up only when something is wrong.
    private func problemLine(_ line: BrowserPickerCopy.Line) -> BrowserPickerCopy.Line? {
        line.tone == .warning ? line : nil
    }

    // MARK: Title row

    /// The switch row: icon, title (and, folded, what the pickers are set to) with the chevron, and the switch. Clicking the
    /// text or the chevron folds; the switch is only the switch. Without the capability there is nothing to fold.
    private func titleRow(_ bot: Bot, isOpen: Bool, hasProblem: Bool) -> some View {
        HStack(spacing: 8) {
            if isOn {
                Button {
                    toggleFold(isOpen: isOpen, hasProblem: hasProblem)
                } label: {
                    HStack(spacing: 6) {
                        title(bot, showsSummary: !isOpen)
                        Spacer(minLength: 4)
                        FoldChevron(isOpen: isOpen)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(FoldRowStyle())
                .help(Tip.toggleBrowserOptions(isOpen: isOpen))
                .accessibilityLabel(Capability.browser.label)
                .accessibilityValue(InspectorFold.spokenState(isOpen: isOpen, summary: summaryText(bot)))
            } else {
                title(bot, showsSummary: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(Capability.browser.label, isOn: $isOn)
                .labelsHidden()
        }
        .help(Tip.capability(.browser))
    }

    private func title(_ bot: Bot, showsSummary: Bool) -> some View {
        HStack(spacing: 4) {
            // The icons share one width, so the titles start on one x whatever the symbol (terminal, globe, window…).
            Label {
                Text(Capability.browser.label)
            } icon: {
                Image(systemName: Capability.browser.symbol).frame(width: 20)
            }
            // Two lines before an ellipsis: in the narrowest panel the chevron and the switch leave "Navegar na web" no room.
            .lineLimit(2)
            .layoutPriority(1)
            // The summary is a bonus: it shows whole or not at all, never squeezing the title.
            if showsSummary {
                ViewThatFits(in: .horizontal) {
                    summary(bot)
                    Color.clear.frame(width: 0, height: 0)
                }
                .transition(.quiet)
            }
        }
    }

    private func summary(_ bot: Bot) -> some View {
        Text("· \(summaryText(bot))")
            .font(Typography.small)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func summaryText(_ bot: Bot) -> String {
        BrowserFoldSummary.text(mode: bot.browserMode, provider: bot.searchProvider)
    }

    private func toggleFold(isOpen: Bool, hasProblem: Bool) {
        let next = InspectorFold.stored(afterClickWhen: isOpen, stored: storedOpen, hasProblem: hasProblem)
        storedOpen = next // the height changes at once; what comes fades in (`foldContent`)
    }

    // MARK: Rows

    /// The same shape as a status line: a caption with its icon, and the action under it as a link. What the proxy means
    /// is its hover text.
    private func proxyRow(_ proxy: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Proxy: \(BrowserProxy.display(proxy))", systemImage: "network")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button("Remover") { model.removeBrowserProxy(for: botID) }
                .buttonStyle(QuietTextStyle())
                .font(Typography.small)
                .help(Tip.removeBrowserProxy)
        }
        .padding(.leading, Self.indent)
        .help("Escolhido pelo Orb. O navegador dele passa por esse proxy; remover o deixa direto")
        .accessibilityElement(children: .contain)
    }

    private var modeBinding: Binding<BrowserMode> {
        Binding(get: { model.liveBot(botID)?.bot.browserMode ?? .default },
                set: { model.setBrowserMode($0, for: botID) })
    }

    private var providerBinding: Binding<SearchProvider> {
        Binding(get: { model.liveBot(botID)?.bot.searchProvider ?? .duckduckgo },
                set: { model.setSearchProvider($0, for: botID) })
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
            .font(Typography.small)
            .foregroundStyle(line.tone == .warning ? Palette.warn : line.tone == .ready ? Palette.ok : Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .textSwap(line.text)
            if let consequence = line.consequence {
                Text(consequence)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = line.action {
                // No arrow: the link says where it goes ("Ajustes"), and the line above already carries the icon.
                Button(action.title) { SettingsRouter.openBrowser(using: openSettings) }
                    .buttonStyle(QuietTextStyle())
                    .font(Typography.small)
                    .help(action.tip)
                    .transition(.quiet)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
