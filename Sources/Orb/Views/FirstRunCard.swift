import SwiftUI

// First use: connecting a model in one to three clicks without leaving the window. One model of the steps
// (`FirstRunModel`), two faces: the card that replaces the empty chat's suggestions, and the compact banner above the
// composer once a conversation exists. Ajustes → Modelos shows the card too while no provider is set up.

/// Which servers are answering on this Mac, so the card can offer them. A 1-second look at the usual ports.
enum LocalServerProbe {
    static let candidates: [(kind: ProviderKind, url: URL)] = [
        (.ollama, URL(string: "http://localhost:11434/v1/models")!),
        (.lmstudio, URL(string: "http://localhost:1234/v1/models")!),
    ]

    static func running(candidates: [(kind: ProviderKind, url: URL)] = candidates,
                        session: URLSession? = nil) async -> [ProviderKind] {
        let session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 1
            configuration.timeoutIntervalForResource = 2
            return URLSession(configuration: configuration)
        }()
        return await withTaskGroup(of: ProviderKind?.self) { group in
            for candidate in candidates {
                group.addTask {
                    guard let (_, response) = try? await session.data(from: candidate.url),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return candidate.kind
                }
            }
            var found: [ProviderKind] = []
            for await kind in group { if let kind { found.append(kind) } }
            return candidates.map(\.kind).filter(found.contains)
        }
    }
}

/// When the "connect a model" card or banner is offered: never while the connections are still being looked at (at
/// launch `connected` is empty only because nobody has looked yet), and only when neither this Orb's model (it may
/// differ from the default one) nor the default one can be used: the card connects a provider as the default model, so
/// it cannot fix an Orb whose own model is down while the default one works.
enum SetupPrompt {
    /// `hasItems` is read last, and only when it matters, so a streaming chat is not redrawn by a banner that is off.
    static func shows(connectionsChecked: Bool, orbHasModel: Bool, connectedName: String?, hasItems: @autoclosure () -> Bool,
                      alwaysShown: Bool = false) -> Bool {
        alwaysShown || connectedName != nil || (connectionsChecked && !orbHasModel && hasItems())
    }
}

/// The one path that is already ready to use when the welcome screen opens, so it can be offered as a single big
/// button instead of a list of three: Claude Code installed and logged in (the user's own subscription, nothing to
/// type). nil when nothing is ready: the card with its paths stays as it is.
struct FirstRunOffer: Equatable {
    /// "fulano@x.com · Claude Max".
    var account: String
    /// The click also makes the Atlas. Not when memories kept from deleted Orbs wait: those can start the new Orb, so
    /// the click only connects and the screen moves on to them.
    var createsAtlas: Bool

    static func resolve(claude: ClaudeCodeStatus?, keptCount: Int = 0) -> FirstRunOffer? {
        guard let claude, claude.isInstalled, claude.isLoggedIn else { return nil }
        return FirstRunOffer(account: claude.accountLabel, createsAtlas: keptCount == 0)
    }

    var buttonTitle: String { createsAtlas ? "Usar meu Claude Code e começar" : "Usar meu Claude Code" }
    var workingTitle: String { "Conectando…" }

    var detail: String {
        createsAtlas
            ? "Você já está conectado como \(account). Um clique conecta e cria o Atlas, seu primeiro Orb."
            : "Você já está conectado como \(account). Um clique conecta."
    }

    var accessibilityHint: String {
        createsAtlas ? "Conecta o Claude Code, cria o Atlas e abre a conversa com ele" : "Conecta o Claude Code"
    }

    static let othersTitle = "Outras formas de conectar"
}

private struct FirstRunError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The steps of connecting a first model. Every path ends the same way: a provider with models and a default model,
/// or a message saying why not (the card stays, with "Tentar de novo"). Starting another path while one waits (a
/// browser tab closed, a login nobody finishes) cancels the first, so no path is ever locked out.
@MainActor @Observable
final class FirstRunModel {
    enum Choice: Hashable { case claudeCode, chatgpt, key, local(ProviderKind) }

    struct Failure: Equatable {
        var choice: Choice
        var message: String
    }

    /// What `claude auth status` says; nil while it is being read.
    private(set) var claude: ClaudeCodeStatus?
    private(set) var localServers: [ProviderKind] = []
    private(set) var working: Choice?
    private(set) var failure: Failure?
    /// Set when a model was just connected: "Claude Code". The card shows "Pronto" for a moment.
    private(set) var connectedName: String?
    /// Claude Code and the local servers have been looked for (or were given): until then the welcome screen keeps
    /// the place of its action, so the big button is never shown and then taken back.
    private(set) var hasDetected: Bool
    /// "Usar meu Claude Code e começar" is under way: the screen stays on the card until the Atlas exists, instead of
    /// showing "Criar meu primeiro Orb" for the instant between the model being ready and the Orb being made.
    private(set) var isStarting = false
    /// Claude Code was installed and logged in when `detect` looked. Decided there, not by later changes of `claude`
    /// (connecting rereads it), so the big button stays through a failure and "Tentar de novo".
    private var readyPath: Bool

    /// How long "Pronto" stays on screen.
    var readyDelay: Duration = .seconds(1.4)
    /// Set by the owner (it has the app model); `connect` asks it once the work is done.
    var isReady: () -> Bool = { true }
    /// Makes a connected provider's first model the default when the old default cannot be used.
    var adoptDefault: (ProviderKind) -> Void = { _ in }
    /// The browser login of ChatGPT; stands in for the real one in tests.
    var signInChatGPT: (AppModel) async throws -> Void = { try await $0.signIn(.chatgpt) }

    private var task: Task<Bool, Never>?
    private var generation = 0
    /// The last browser login of ChatGPT worked and only the model list failed: one retry reuses that login.
    private var reusesChatGPTLogin = false

    /// `claude`: what Claude Code already reported (snapshots show the card as it looks once it has looked).
    init(claude: ClaudeCodeStatus? = nil) {
        self.claude = claude
        hasDetected = claude != nil
        readyPath = FirstRunOffer.resolve(claude: claude) != nil
    }

    /// What the welcome screen offers as its one big button (nil: nothing was ready, the card shows).
    func offer(keptCount: Int) -> FirstRunOffer? {
        readyPath ? FirstRunOffer.resolve(claude: claude, keptCount: keptCount) : nil
    }

    /// Wires `isReady` and `adoptDefault` to the app model.
    func attach(_ model: AppModel) {
        isReady = { [weak model] in model?.isProviderReady ?? false }
        adoptDefault = { [weak model] in model?.adoptDefaultModel(from: $0) }
    }

    /// Looks for Claude Code and local servers. Quiet and read-only: `claude auth status` and two local requests.
    func detect() async {
        async let status = ClaudeCode.shared.status()
        async let servers = LocalServerProbe.running()
        claude = await status
        localServers = await servers
        readyPath = FirstRunOffer.resolve(claude: claude) != nil
        hasDetected = true
    }

    /// `showsReady: false` skips the "Pronto" beat: the caller moves on at once.
    @discardableResult
    func connectClaudeCode(model: AppModel, showsReady: Bool = true) -> Task<Bool, Never> {
        connect(.claudeCode, kind: .claudeCode, name: "Claude Code", showsReady: showsReady) {
            model.addProvider(.claudeCode)
            await model.refreshConnections()
            if model.claudeCode.isLoggedIn {
                try await model.refreshModels(.claudeCode)
            } else {
                try await model.signIn(.claudeCode)
            }
            self.claude = model.claudeCode
        }
    }

    /// "Usar meu Claude Code e começar": connects Claude Code and, once a model is ready, makes the Atlas (the same Orb
    /// as "Começar com o Atlas"), which opens its chat. The task answers whether the Atlas was made. Nothing is made
    /// when another path took over meanwhile or when an Orb appeared by another way.
    @discardableResult
    func connectClaudeCodeAndStart(model: AppModel, base: URL = OrbFolder.defaultBase) -> Task<Bool, Never> {
        startingAtlas(after: connectClaudeCode(model: model, showsReady: false), model: model, base: base)
    }

    /// The second half of the click, once `connecting` (the path just started) is under way (internal for tests,
    /// which connect without the real `claude`).
    func startingAtlas(after connecting: Task<Bool, Never>, model: AppModel, base: URL) -> Task<Bool, Never> {
        let mine = generation
        isStarting = true
        return Task {
            let connected = await connecting.value
            defer { if mine == generation { isStarting = false } }
            guard connected, mine == generation, model.bots.isEmpty else { return false }
            model.createSuggestedOrb(base: base)
            return true
        }
    }

    @discardableResult
    func connectChatGPT(model: AppModel) -> Task<Bool, Never> {
        connect(.chatgpt, kind: .chatgpt, name: "ChatGPT") {
            // A retry after a failed model list must not ask for another login. Only once: a token the list keeps
            // refusing is signed in again, not retried forever.
            let reuses = self.reusesChatGPTLogin
            self.reusesChatGPTLogin = false
            if reuses, await model.hasChatGPTLogin() {
                model.addProvider(.chatgpt)
                await model.refreshConnections()
                try await model.refreshModels(.chatgpt)
            } else {
                do {
                    try await self.signInChatGPT(model)
                } catch {
                    let kept = await model.hasChatGPTLogin()
                    self.reusesChatGPTLogin = kept && !(error is CancellationError)
                    throw error
                }
            }
        }
    }

    @discardableResult
    func connectLocal(_ kind: ProviderKind, model: AppModel) -> Task<Bool, Never> {
        connect(.local(kind), kind: kind, name: kind.shortName) {
            model.addProvider(kind)
            try await model.refreshModels(kind)
        }
    }

    /// `save` and `discard` stand in for the keychain and the network in tests: `save` keeps the key and loads the
    /// models; `discard(kind, existed)` undoes a key that did not work.
    @discardableResult
    func connectKey(_ key: String, kind: ProviderKind, model: AppModel,
                    save: ((String, ProviderKind) async throws -> Void)? = nil,
                    discard: ((ProviderKind, Bool) -> Void)? = nil) -> Task<Bool, Never> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Task { false } }
        let existed = model.account(kind) != nil
        return connect(.key, kind: kind, name: kind.shortName) {
            model.addProvider(kind)
            do {
                if let save { try await save(trimmed, kind) } else { try await model.setKey(trimmed, for: kind) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A key that did not work is not kept, so trying again starts clean.
                if let discard {
                    discard(kind, existed)
                } else if !existed {
                    model.removeProvider(kind)
                } else {
                    model.signOut(kind)
                }
                throw FirstRunError(message: "Essa chave não funcionou: \(error.localizedDescription)")
            }
        }
    }

    /// Tries the failed path again. A key needs the text, so the owner reopens its field instead.
    func retry(model: AppModel) {
        switch failure?.choice {
        case .claudeCode?: connectClaudeCode(model: model)
        case .chatgpt?: connectChatGPT(model: model)
        case .local(let kind)?: connectLocal(kind, model: model)
        case .key?, nil: break
        }
    }

    /// Stops waiting for what is under way (the login stops with it) and leaves every path free.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        working = nil
        failure = nil
        connectedName = nil
        isStarting = false
    }

    /// Starts one path; the latest wins. The task answers whether a model got connected. `showsReady: false` goes
    /// straight on once the model is ready, without the "Pronto" beat (the caller has somewhere to go).
    @discardableResult
    func connect(_ choice: Choice, kind: ProviderKind, name: String, showsReady: Bool = true,
                 _ work: @escaping @MainActor () async throws -> Void) -> Task<Bool, Never> {
        task?.cancel()
        generation += 1
        let mine = generation
        working = choice
        failure = nil
        connectedName = nil
        isStarting = false
        let started = Task { await self.run(choice, kind: kind, name: name, generation: mine, showsReady: showsReady, work) }
        task = started
        return started
    }

    private func run(_ choice: Choice, kind: ProviderKind, name: String, generation mine: Int, showsReady: Bool,
                     _ work: @MainActor () async throws -> Void) async -> Bool {
        do {
            try await work()
            guard mine == generation else { return false }
            adoptDefault(kind)
            guard isReady() else {
                throw FirstRunError(message: choice.isLocal
                    ? "\(name) respondeu, mas não tem nenhum modelo. Baixe um nele e tente de novo."
                    : "Conectou, mas não encontrei nenhum modelo para usar.")
            }
            guard showsReady else {
                working = nil
                return true
            }
            connectedName = name
            try? await Task.sleep(for: readyDelay)
            if mine == generation {
                connectedName = nil
                working = nil
            }
            return true
        } catch {
            guard mine == generation else { return false }
            working = nil
            failure = Failure(choice: choice, message: error.localizedDescription)
            return false
        }
    }
}

private extension FirstRunModel.Choice {
    var isLocal: Bool { if case .local = self { true } else { false } }
}

// MARK: - The card

/// Where the card is shown: in the empty chat (it speaks about the Orb), on the welcome screen (no Orb yet) or in
/// Ajustes → Modelos.
enum FirstRunStyle {
    case chat(botName: String)
    case welcome
    case settings

    var title: String {
        switch self {
        case .chat(let name): "Vamos preparar \(name.isEmpty ? "seu Orb" : name)"
        case .welcome: "Primeiro, conecte um modelo"
        case .settings: "Conecte um modelo"
        }
    }

    var subtitle: String {
        switch self {
        case .chat: "Escolha de onde vem a inteligência do Orb. Você pode mudar quando quiser em Ajustes."
        case .welcome: "É de onde vem a inteligência dos seus Orbs. Leva um minuto, e dá para trocar depois em Ajustes."
        case .settings: "Escolha de onde vem a inteligência dos seus Orbs. Você pode mudar quando quiser."
        }
    }

    /// The "Mais opções em Ajustes" link under the paths (Ajustes itself is already there in the settings form).
    var showsSettingsLink: Bool {
        if case .settings = self { false } else { true }
    }
}

/// The card's own frame in the chat; in Ajustes it sits in the form's section, which already is one.
private struct FirstRunFrame: ViewModifier {
    let style: FirstRunStyle
    let isPulsing: Bool

    func body(content: Content) -> some View {
        switch style {
        case .chat, .welcome:
            content
                .padding(18)
                .frame(maxWidth: 460, alignment: .leading)
                .card(radius: 16, stroke: isPulsing ? Palette.accent : Palette.line, lineWidth: isPulsing ? 2 : 1)
        case .settings:
            content
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FirstRunCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: FirstRunStyle
    /// The owner's model, so it can keep the card on screen for the "Pronto" beat. Created here when not given.
    var run: FirstRunModel?
    /// Looks for Claude Code and local servers when it appears (`claude auth status`, two local ports). Snapshots turn
    /// it off, so a capture asks nothing of the machine.
    var detectsOnAppear = true
    /// Under "Outras formas de conectar" on the welcome screen: no title (the disclosure above is it) and without the
    /// Claude Code row (the big button is that path).
    var asAlternatives = false
    @State private var ownRun = FirstRunModel()
    @State private var isKeyOpen = false
    @State private var keyKind = ProviderKind.openai
    @State private var key = ""
    @State private var isPulsing = false
    @FocusState private var keyFocused: Bool

    private var steps: FirstRunModel { run ?? ownRun }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 14) {
            if !asAlternatives {
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(style.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let name = steps.connectedName {
                Label("Pronto: \(name) conectado.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ok)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    if !asAlternatives { claudeCodeRow(steps) }
                    FirstRunRow(symbol: "bubble.left.and.bubble.right", title: "Entrar com ChatGPT",
                                subtitle: "Para quem tem ChatGPT Plus ou Pro. Abre o navegador para você entrar.",
                                phase: phase(.chatgpt, steps), isEnabled: steps.working != .chatgpt,
                                onCancel: steps.cancel) {
                        steps.connectChatGPT(model: model)
                    }
                    ForEach(steps.localServers) { kind in
                        FirstRunRow(symbol: "desktopcomputer", title: "Usar o \(kind.shortName) que já está rodando aqui",
                                    subtitle: "Roda no seu Mac, sem enviar nada para fora.",
                                    phase: phase(.local(kind), steps), isEnabled: steps.working != .local(kind),
                                    onCancel: steps.cancel) {
                            steps.connectLocal(kind, model: model)
                        }
                    }
                    keyRow(steps)
                }
                if style.showsSettingsLink {
                    Button("Mais opções em Ajustes") { SettingsRouter.open(.models, using: openSettings) }
                        .buttonStyle(.plain)
                        .help(Tip.modelSettings)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accentText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .modifier(FirstRunFrame(style: style, isPulsing: isPulsing))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isPulsing)
        .animateChanges(of: steps.connectedName)
        .task {
            steps.attach(model)
            if detectsOnAppear { await steps.detect() }
        }
        .onChange(of: model.setupNudge) { pulse() }
        .accessibilityElement(children: .contain)
    }

    private func pulse() {
        isPulsing = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            isPulsing = false
        }
    }

    private func phase(_ choice: FirstRunModel.Choice, _ steps: FirstRunModel) -> FirstRunRow.Phase {
        if steps.working == choice { return .working }
        if let failure = steps.failure, failure.choice == choice { return .failed(failure.message) }
        return .idle
    }

    // MARK: Rows

    @ViewBuilder private func claudeCodeRow(_ steps: FirstRunModel) -> some View {
        let installed = steps.claude?.isInstalled
        let loggedIn = steps.claude?.isLoggedIn == true
        let subtitle: String = switch (installed, loggedIn) {
        case (nil, _): "Procurando o Claude Code neste Mac…"
        case (false, _): "Não encontrei o Claude Code neste Mac."
        case (true, true): "Você já está conectado como \(steps.claude?.accountLabel ?? "sua conta"). Usa sua assinatura Claude Pro ou Max."
        case (true, false): "Usa sua assinatura Claude Pro ou Max. Abre o navegador para você entrar."
        }
        FirstRunRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Usar meu Claude Code", subtitle: subtitle,
                    badge: installed == true ? "Recomendado" : nil,
                    phase: phase(.claudeCode, steps),
                    workingText: loggedIn ? "Conectando…" : "Aguardando o navegador…",
                    isEnabled: steps.working != .claudeCode && installed == true,
                    trailingLink: installed == false ? ("Como instalar", ClaudeCode.setupPage) : nil,
                    onCancel: steps.cancel) {
            steps.connectClaudeCode(model: model)
        }
    }

    @ViewBuilder private func keyRow(_ steps: FirstRunModel) -> some View {
        VStack(spacing: 0) {
            FirstRunRow(symbol: "key", title: "Colar uma chave de API",
                        subtitle: "OpenAI, Claude, xAI ou OpenRouter. Cobrança por uso, direto no provedor.",
                        phase: isKeyOpen ? .idle : phase(.key, steps), isEnabled: true,
                        trailingSymbol: isKeyOpen ? "chevron.up" : "chevron.down", framed: !isKeyOpen) {
                withAnimation(Motion.panel(reduceMotion: reduceMotion)) { isKeyOpen.toggle() }
                if isKeyOpen { keyFocused = true }
            }
            if isKeyOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Provedor", selection: $keyKind) {
                        ForEach(ProviderKind.firstUseKeyKinds) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack(spacing: 8) {
                        SecureField("Cole sua chave", text: $key)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Palette.raised, in: .rect(cornerRadius: 8))
                            .focused($keyFocused)
                            .onSubmit(connectKey)
                            .accessibilityLabel("Chave de API de \(keyKind.shortName)")
                        Button(steps.working == .key ? "Conectando…" : "Conectar", action: connectKey)
                            .buttonStyle(PrimaryPillStyle())
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || steps.working == .key)
                    }
                    HStack {
                        if let page = keyKind.keyPage {
                            Link("Obter chave de \(keyKind.shortName)", destination: page)
                                .font(.system(size: 12))
                                .help(Tip.getKey)
                        }
                        Spacer()
                    }
                    if let failure = steps.failure, failure.choice == .key {
                        Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .card(radius: 12, stroke: isKeyOpen ? Palette.lineStrong : Palette.line)
    }

    private func connectKey() {
        let value = key
        Task {
            if await steps.connectKey(value, kind: keyKind, model: model).value { key = "" }
        }
    }
}

/// One way to connect, as a whole-row button: icon, what it is, one line of why, and what is happening to it.
private struct FirstRunRow: View {
    enum Phase: Equatable { case idle, working, failed(String) }

    let symbol: String
    let title: String
    let subtitle: String
    var badge: String?
    var phase: Phase = .idle
    var workingText = "Aguardando o navegador…"
    var isEnabled = true
    var trailingSymbol = "chevron.right"
    var trailingLink: (title: String, url: URL?)?
    /// Draws its own card (the key row draws one around the row and its form).
    var framed = true
    /// Shown beside a path that is waiting (a login in the browser), so it can be given up.
    var onCancel: (() -> Void)?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .frame(width: 30, height: 30)
                .background(Palette.raised, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    if let badge { CatalogBadge(text: badge, tint: Palette.accentText) }
                }
                switch phase {
                case .idle:
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                case .working:
                    Text(workingText)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)

        Button(action: action) {
            if framed {
                content.card(radius: 12, fill: isHovering && isEnabled ? Palette.raised : Palette.surface)
            } else {
                content.background(isHovering && isEnabled ? Palette.ghostHover : .clear, in: .rect(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled || phase == .working ? 1 : 0.6)
        .onHover { isHovering = $0 }
        .overlay(alignment: .trailing) {
            // A real link or button beside the row, not inside the button (nothing inside a button takes its own click).
            if let trailingLink, let url = trailingLink.url {
                Link(trailingLink.title, destination: url)
                    .font(.system(size: 12))
                    .padding(.trailing, 12)
            } else if phase == .working, let onCancel {
                Button("Cancelar", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accentText)
                    .help(Tip.stopConnecting)
                    .padding(.trailing, 40)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(phaseText)")
        .accessibilityAddTraits(.isButton)
    }

    private var phaseText: String {
        switch phase {
        case .idle: subtitle
        case .working: workingText
        case .failed(let message): message
        }
    }

    @ViewBuilder private var trailing: some View {
        if phase == .working {
            ProgressView().controlSize(.small)
        } else if case .failed = phase {
            Text("Tentar de novo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accentText)
        } else if trailingLink == nil {
            Image(systemName: trailingSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.hint)
        }
    }
}

// MARK: - The compact banner

/// Above the composer once a conversation exists and no model is connected: the same paths in one row of buttons.
/// With an empty chat the card above takes its place, so it shows nothing then.
struct FirstRunBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    /// For snapshots: shown even over an empty chat.
    var alwaysShown = false
    @State private var steps = FirstRunModel()
    @State private var isAskingKey = false
    @State private var keyKind = ProviderKind.openai
    @State private var key = ""
    @State private var isPulsing = false

    var body: some View {
        // The banner is a row of its own above the composer: it rises in and fades out, and the composer goes up and
        // down with it (§2.13). It is bound to the one fact that decides it, never to the conversation. A new Orb's chat is
        // a new view (`.id(botID)`), so there the banner is simply there.
        VStack(spacing: 0) {
            if shows { banner.transition(.adapted(.rise, reduceMotion: reduceMotion)) }
        }
        .motion(Motion.enter, value: shows)
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: steps.connectedName == nil ? "cpu" : "checkmark.circle.fill")
                    .foregroundStyle(steps.connectedName == nil ? Palette.muted : Palette.ok)
                    .contentTransition(.opacity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(steps.connectedName.map { "Pronto: \($0) conectado." } ?? "Conecte um modelo para começar")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(steps.failure == nil ? Palette.muted : Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            if steps.connectedName == nil {
                WrappingLayout(spacing: 8) {
                    if steps.claude?.isInstalled == true {
                        Button(steps.claude?.isLoggedIn == true ? "Usar Claude Code" : "Entrar com Claude Code") {
                            steps.connectClaudeCode(model: model)
                        }
                        .buttonStyle(PrimaryPillStyle())
                        .help(steps.claude?.isLoggedIn == true ? Tip.useClaudeCode : Tip.signInClaudeCode)
                        .disabled(steps.working == .claudeCode)
                    }
                    Button("Entrar com ChatGPT") { steps.connectChatGPT(model: model) }
                        .buttonStyle(steps.claude?.isInstalled == true ? AnyButtonStyle(SecondaryPillStyle()) : AnyButtonStyle(PrimaryPillStyle()))
                        .help(Tip.signInChatGPT)
                        .disabled(steps.working == .chatgpt)
                    ForEach(steps.localServers) { kind in
                        Button("Usar \(kind.shortName)") { steps.connectLocal(kind, model: model) }
                            .buttonStyle(SecondaryPillStyle())
                            .help(Tip.useLocalServer(kind.shortName))
                            .disabled(steps.working == .local(kind))
                    }
                    Button("Colar chave de API…") { isAskingKey = true }
                        .buttonStyle(SecondaryPillStyle())
                        .popover(isPresented: $isAskingKey, arrowEdge: .top) { keyPopover }
                        .help(Tip.pasteKey)
                        .disabled(steps.working == .key)
                    if steps.working != nil {
                        Button("Cancelar") { steps.cancel() }
                            .buttonStyle(GhostStyle())
                            .help(Tip.stopConnecting)
                            .transition(.opacity)
                    } else if steps.failure != nil {
                        Button("Tentar de novo", action: retry)
                            .buttonStyle(GhostStyle())
                            .help(Tip.retryConnecting)
                            .transition(.opacity)
                    }
                    Button("Ajustes") { SettingsRouter.open(.models, using: openSettings) }
                        .buttonStyle(GhostStyle())
                        .help(Tip.modelSettings)
                }
            }
        }
        .padding(14)
        .card(radius: 14, stroke: isPulsing ? Palette.accent : Palette.line, lineWidth: isPulsing ? 2 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isPulsing)
        // The phrases and the buttons that change as the connection goes (waiting, failed, ready) swap in place.
        .animateChanges(of: BannerPhase(connectedName: steps.connectedName, working: steps.working, failure: steps.failure?.message))
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .task {
            steps.attach(model)
            await steps.detect()
        }
        .onChange(of: model.setupNudge) {
            isPulsing = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                isPulsing = false
            }
        }
    }

    /// With a model connected this reads nothing of the conversation, so streaming does not redraw it.
    private var shows: Bool {
        SetupPrompt.shows(connectionsChecked: model.hasCheckedConnections, orbHasModel: model.hasModelSetup(for: botID),
                          connectedName: steps.connectedName, hasItems: !model.orbTranscript(botID).items.isEmpty,
                          alwaysShown: alwaysShown)
    }

    private var subtitle: String {
        if steps.connectedName != nil { return "Já pode conversar." }
        if let failure = steps.failure { return failure.message }
        switch steps.working {
        case .claudeCode?, .chatgpt?: return "Aguardando o navegador…"
        case .some: return "Conectando…"
        case nil: return "Use sua assinatura ou cole uma chave. Leva um minuto."
        }
    }

    private var keyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Provedor", selection: $keyKind) {
                ForEach(ProviderKind.firstUseKeyKinds) { Text($0.shortName).tag($0) }
            }
            .labelsHidden()
            SecureField("Cole sua chave", text: $key)
                .onSubmit(connect)
            HStack {
                if let page = keyKind.keyPage { Link("Obter chave", destination: page).font(.system(size: 12)) }
                Spacer()
                Button("Conectar", action: connect)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func connect() {
        let value = key
        isAskingKey = false
        Task {
            if await steps.connectKey(value, kind: keyKind, model: model).value { key = "" }
        }
    }

    /// A key that failed is still in the field: asking again shows it, to fix or to send once more.
    private func retry() {
        if steps.failure?.choice == .key { isAskingKey = true } else { steps.retry(model: model) }
    }
}

/// What the banner's phrases and buttons depend on, as one value (the animation of their swaps is bound to it).
private struct BannerPhase: Equatable {
    var connectedName: String?
    var working: FirstRunModel.Choice?
    var failure: String?
}

/// Lets two different button styles be chosen at run time.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
