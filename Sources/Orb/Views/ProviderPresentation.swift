import Foundation

// How Ajustes → Modelos talks about providers: which group each one belongs to, a short name, and an honest
// one-line status. Everything here is a pure function of values, so it is tested without a window.

/// The groups of the provider list and of the "Adicionar provedor" menu, in display order.
enum ProviderGroup: CaseIterable, Identifiable, Sendable {
    case subscription, apiKey, local, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .subscription: "Assinatura (sem chave)"
        case .apiKey: "Chave de API"
        case .local: "No seu Mac"
        case .advanced: "Avançado"
        }
    }

    var kinds: [ProviderKind] {
        switch self {
        case .subscription: [.claudeCode, .chatgpt]
        case .apiKey: [.openai, .anthropic, .xai, .openrouter, .opencodeZen, .opencodeGo, .commandCode]
        case .local: [.ollama, .lmstudio]
        case .advanced: [.custom]
        }
    }
}

extension ProviderKind {
    var group: ProviderGroup {
        ProviderGroup.allCases.first { $0.kinds.contains(self) } ?? .advanced
    }

    /// The name inside a group, where "(sua assinatura)" or "(chave de API)" would only repeat the group's title.
    var shortName: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claudeCode: "Claude Code"
        case .openai: "OpenAI"
        case .anthropic: "Claude"
        case .opencodeZen: "OpenCode Zen"
        case .opencodeGo: "OpenCode Go"
        case .commandCode: "Command Code"
        case .xai: "xAI (Grok)"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .custom: "Gateway próprio"
        }
    }

    /// A line for the add menu's help and for the first-use card.
    var tagline: String {
        switch self {
        case .chatgpt: "Para quem tem ChatGPT Plus ou Pro"
        case .claudeCode: "Usa sua assinatura Claude Pro ou Max"
        case .openai: "Modelos GPT, cobrados por uso"
        case .anthropic: "Modelos Claude, cobrados por uso"
        case .opencodeZen: "Vários modelos, pré-pago"
        case .opencodeGo: "Modelos abertos por assinatura"
        case .commandCode: "Vários laboratórios, uma chave"
        case .xai: "Modelos Grok, cobrados por uso"
        case .openrouter: "Centenas de modelos com uma chave"
        case .ollama: "Roda no seu Mac, sem enviar nada para fora"
        case .lmstudio: "Roda no seu Mac, sem enviar nada para fora"
        case .custom: "Um servidor seu, compatível com OpenAI ou Claude"
        }
    }

    /// Providers whose server runs on this Mac (so "offline" is a normal state, not an error).
    var isLocalServer: Bool { self == .ollama || self == .lmstudio }

    /// The providers that take a pasted key and are offered on the first-use card.
    static let firstUseKeyKinds: [ProviderKind] = [.openai, .anthropic, .xai, .openrouter]

    /// The consequence of removing it, in the confirmation's button.
    var removeButtonTitle: String {
        if needsKey || self == .custom { return "Remover e apagar a chave" }
        if self == .chatgpt { return "Remover e sair da conta" }
        return "Remover"
    }
}

// MARK: Status

/// What a provider row says about itself in one line.
enum ProviderStatus: Equatable {
    case disabled
    case needsSignIn
    case needsKey
    case needsURL
    case checking
    /// The server did not answer (local servers and gateways).
    case offline(host: String)
    case failed(String)
    /// Connected, but the list of models is empty (nothing installed, or not loaded yet).
    case noModels
    /// A gateway whose address is set but that has not answered yet.
    case unverified
    case ready(count: Int, updated: Date?)

    /// `isConnected`: a key in the Keychain or a sign-in. `lastError`: why the last model refresh failed, if it did.
    static func make(kind: ProviderKind, account: ProviderAccount, isConnected: Bool, lastError: ProviderCheckFailure?,
                     isChecking: Bool) -> ProviderStatus {
        if !account.isEnabled { return .disabled }
        if kind == .custom, account.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return .needsURL }
        if kind.usesSignIn, !isConnected { return .needsSignIn }
        if kind.needsKey, !isConnected { return .needsKey }
        if !account.models.isEmpty, lastError == nil { return .ready(count: account.models.count, updated: account.modelsUpdatedAt) }
        if isChecking { return .checking }
        switch lastError {
        case .unreachable: return .offline(host: ProviderCheck.hostLabel(account.baseURL))
        case .other(let message), .rejected(let message): return .failed(message)
        case nil: break
        }
        return kind == .custom ? .unverified : .noModels
    }

    /// The short text of the collapsed row.
    func summary(now: Date = .now) -> String {
        switch self {
        case .disabled: "Desativado"
        case .needsSignIn: "Não conectado"
        case .needsKey: "Falta a chave"
        case .needsURL: "Falta a URL"
        case .checking: "Verificando…"
        case .offline: "Servidor não encontrado"
        case .failed: "Não conseguiu atualizar"
        case .noModels: "Conectado · sem modelos"
        case .unverified: "Ainda não verificado"
        case .ready(let count, let updated):
            [count == 1 ? "1 modelo" : "\(count) modelos", updated.map { "atualizado " + Self.relative($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The sentence shown inside the open row when the short text is not enough.
    func explanation(for kind: ProviderKind) -> String? {
        switch self {
        case .offline(let host):
            switch kind {
            case .ollama: "Não encontrei o Ollama em \(host). Ele está aberto?"
            case .lmstudio: "Não encontrei o LM Studio em \(host). Ele está aberto, com o servidor local ligado?"
            default: "Não consegui falar com \(host). O endereço está certo e o servidor está no ar?"
            }
        // The row already shows the key and the message is read right there, so "Confira em Ajustes → Modelos" would point
        // to the screen the person is on (it stays in chat notices, where it opens the settings).
        case .failed(let message): message.replacingOccurrences(of: " Confira em Ajustes → Modelos.", with: "")
        case .noModels where kind == .ollama: "O Ollama está aberto, mas sem modelos. Baixe um pelo próprio Ollama e atualize."
        case .noModels where kind == .lmstudio: "O LM Studio respondeu, mas sem modelos carregados."
        case .needsURL: "Informe o endereço do gateway para começar."
        default: nil
        }
    }

    var isProblem: Bool {
        switch self {
        case .offline, .failed, .needsKey, .needsSignIn, .needsURL: true
        default: false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// "há 2 h" (abbreviated, pt-BR).
    static func relative(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Why the last model refresh failed.
enum ProviderCheckFailure: Equatable {
    case unreachable
    /// The provider turned the key or login down (401/403): the key row says so instead of "Chave salva".
    case rejected(String)
    case other(String)
}

enum ProviderCheck {
    /// "localhost:11434" from "http://localhost:11434/v1".
    static func hostLabel(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), let host = url.host else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func failure(from error: Error) -> ProviderCheckFailure {
        let unreachable: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut,
                                                .notConnectedToInternet, .dnsLookupFailed]
        if let url = error as? URLError, unreachable.contains(url.code) { return .unreachable }
        if case LLMError.network(let code, _) = error, unreachable.contains(URLError.Code(rawValue: code)) { return .unreachable }
        if (error as? LLMError)?.isCredentialRefusal == true { return .rejected(error.localizedDescription) }
        return .other(error.localizedDescription)
    }
}

// MARK: Gateway form

/// Validation of the "Gateway próprio" fields.
enum GatewayForm {
    enum URLState: Equatable { case empty, invalid, valid }

    static func urlState(_ text: String) -> URLState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return .invalid }
        return .valid
    }

    struct Headers: Equatable {
        var values: [String: String] = [:]
        /// Lines (1-based) that are not "Nome: valor".
        var badLines: [Int] = []
    }

    /// One header per line, "Nome: valor". Blank lines are ignored; a line without a name or a colon is reported.
    static func parseHeaders(_ text: String) -> Headers {
        var result = Headers()
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].contains(" ") {
                result.values[parts[0]] = parts[1]
            } else {
                result.badLines.append(offset + 1)
            }
        }
        return result
    }

    static func headerWarning(_ headers: Headers) -> String? {
        guard let first = headers.badLines.first else { return nil }
        return headers.badLines.count == 1
            ? "A linha \(first) não está no formato Nome: valor."
            : "As linhas \(headers.badLines.map(String.init).joined(separator: ", ")) não estão no formato Nome: valor."
    }

    static func formatSubtitle(_ format: APIFormat) -> String {
        switch format {
        case .chat: "O mais comum: serve a maioria dos gateways e servidores locais."
        case .responses: "A API Responses da OpenAI."
        case .messages: "A API Messages da Anthropic, para gateways de Claude."
        case .claudeCode: ""
        }
    }
}
