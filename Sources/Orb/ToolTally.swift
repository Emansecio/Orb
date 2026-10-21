import Foundation

/// The line of a run of the Orb's actions folded in the chat: what they did, counted by what kind of thing it was, in the
/// order it was first done ("Rodou 7 comandos, leu 1 arquivo e fez 2 buscas"). Pure, so the tests can read it.
enum ToolTally {
    /// What an action did, for counting. Read from its title (the tools' own words, see `WorkPhrase`): a title not
    /// known here (a connector's, a new tool's) counts as an action.
    enum Act: Equatable {
        case command, read, change, list, search, page, click, fill, other

        init(_ call: ToolCall) {
            switch call.title {
            case "Rodando no Terminal", "Rodando em segundo plano": self = .command
            case "Lendo arquivo", "Lendo caderno": self = .read
            case "Editando arquivo", "Gravando arquivo", "Movendo para a Lixeira": self = .change
            case "Listando pasta": self = .list
            case "Procurando arquivos", "Buscando no conteúdo", "Pesquisando na web", "Buscando na memória": self = .search
            case "Lendo página", "Baixando arquivo", "Lendo a aba do navegador", "Abrindo página", "Abrindo uma aba": self = .page
            // The Orb's browser names what it clicks or fills ("Clicando em “Verificar”", `BrowseClickTool`).
            case let title where call.kind == .browser && title.hasPrefix("Clicando"): self = .click
            case let title where call.kind == .browser && title.hasPrefix("Preenchendo"): self = .fill
            default: self = .other
            }
        }

        /// "rodou 7 comandos", "leu 1 arquivo".
        func phrase(_ count: Int) -> String {
            let one = count == 1
            return switch self {
            case .command: "rodou \(count) \(one ? "comando" : "comandos")"
            case .read: "leu \(count) \(one ? "arquivo" : "arquivos")"
            case .change: "alterou \(count) \(one ? "arquivo" : "arquivos")"
            case .list: "listou \(count) \(one ? "pasta" : "pastas")"
            case .search: "fez \(count) \(one ? "busca" : "buscas")"
            case .page: "abriu \(count) \(one ? "página" : "páginas")"
            case .click: "clicou \(count) \(one ? "vez" : "vezes")"
            case .fill: "preencheu \(count) \(one ? "campo" : "campos")"
            case .other: "fez \(count) \(one ? "ação" : "ações")"
            }
        }
    }

    /// The kinds of thing named one by one; the rest is "e mais N ações", so the line stays one line.
    static let namedLimit = 3

    /// "Rodou 7 comandos, leu 1 arquivo e fez 2 buscas". An action of a kind not named comes last as "outras".
    static func summary(_ calls: [ToolCall], capitalized: Bool = true) -> String {
        var order: [Act] = []
        var counts: [Act: Int] = [:]
        for call in calls {
            let act = Act(call)
            if counts[act] == nil { order.append(act) }
            counts[act, default: 0] += 1
        }
        // "fez 2 ações" reads as everything else only after the kinds that have a name.
        order.sort { ($0 == .other ? 1 : 0) < ($1 == .other ? 1 : 0) }
        let named = order.prefix(namedLimit)
        var parts = named.map { act in
            act == .other && named.count > 1 ? otherPhrase(counts[act]!) : act.phrase(counts[act]!)
        }
        let rest = order.dropFirst(namedLimit).reduce(0) { $0 + counts[$1]! }
        if rest > 0 { parts.append("mais \(rest) \(rest == 1 ? "ação" : "ações")") }
        let line = PortugueseList.join(parts)
        return capitalized ? line.prefix(1).uppercased() + line.dropFirst() : line
    }

    /// "fez 2 outras ações", after kinds that were named.
    private static func otherPhrase(_ count: Int) -> String {
        count == 1 ? "fez 1 outra ação" : "fez \(count) outras ações"
    }

    /// How many of the actions ended with an error (or were stopped), and whether the Orb got over it.
    struct Failures: Equatable {
        /// "1 com erro", "3 com erro".
        var text: String
        /// The last action of the run did not fail (it worked, or still runs): the Orb recovered, so the mark stays quiet
        /// instead of red.
        var recovered: Bool
    }

    /// nil when no action failed.
    static func failures(_ calls: [ToolCall]) -> Failures? {
        let failed = calls.reduce(0) { $0 + ($1.state == .failed ? 1 : 0) }
        guard failed > 0 else { return nil }
        return Failures(text: "\(failed) com erro", recovered: calls.last?.state != .failed)
    }

    /// From the first action's start to the last one's end, nil while any still runs (they may overlap: the tools of
    /// one step run together).
    static func span(_ calls: [ToolCall]) -> TimeInterval? {
        guard !calls.isEmpty, calls.allSatisfy({ $0.state != .running }) else { return nil }
        let start = calls.map(\.startedAt).min()!
        guard let end = calls.compactMap(\.finishedAt).max() else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    /// "Trabalhou por 1 min 05 s · rodou 11 comandos e leu 1 arquivo": the line of a finished request's work (without
    /// the time when it is not known). Actions with a description of their own are said by it (`intentVariants`).
    static func work(_ calls: [ToolCall], seconds: Int?) -> String {
        workVariants(calls, seconds: seconds)[0]
    }

    /// `work`, from the fullest wording to the shortest, for the row to take the first that fits.
    static func workVariants(_ calls: [ToolCall], seconds: Int?) -> [String] {
        let time = seconds.map { "Trabalhou por \(ElapsedFormat.text(seconds: $0))" } ?? "Trabalhou"
        guard !calls.isEmpty else { return [time] }
        guard let said = intentVariants(calls, capitalized: false) else { return ["\(time) · \(summary(calls, capitalized: false))"] }
        return said.map { "\(time) · \($0)" }
    }

    /// The folded line of a run in the Orb's browser leads with the site it is on, the last one it opened ("gympass.com ·
    /// Abriu 1 página, clicou 3 vezes e preencheu 2 campos"); any other run is its `summary`, or what its actions were for.
    static func line(_ calls: [ToolCall]) -> String {
        lineVariants(calls)[0]
    }

    /// `line`, from the fullest wording to the shortest (one when the actions have no descriptions): the row takes the first
    /// that fits its width, so a word is never cut in two.
    static func lineVariants(_ calls: [ToolCall]) -> [String] {
        if let said = intentVariants(calls) { return said }
        let opened = calls.last { $0.kind == .browser && ["Abrindo página", "Abrindo uma aba"].contains($0.title) }
        guard let site = opened.flatMap({ WorkPhrase.host(of: WorkPhrase.firstLine(of: $0.detail)) }) else { return [summary(calls)] }
        return ["\(site) · \(summary(calls))"]
    }

    // MARK: What the actions were for

    /// The most descriptions a line names before "e mais N".
    static let intentLimit = 3

    /// The run by what its actions were for, from the fullest wording to the shortest, or nil when none has a description:
    /// each distinct description once, in the order it happened, in the preterite ("Leu o histórico dos três chats,
    /// conferiu se a vaga do Marcus já saiu e mais 4"). The actions left out of the names (without a description, or past
    /// the limit) are the "mais N".
    static func intentVariants(_ calls: [ToolCall], capitalized: Bool = true) -> [String]? {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for call in calls {
            guard let intent = call.intent else { continue }
            let key = intent.lowercased()
            if counts[key] == nil { order.append(intent) }
            counts[key, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        var variants: [String] = []
        for count in stride(from: min(order.count, intentLimit), through: 1, by: -1) {
            let named = order.prefix(count)
            let rest = calls.count - named.reduce(0) { $0 + counts[$1.lowercased(), default: 0] }
            var parts = named.map(ToolIntent.pastInSentence)
            if capitalized { parts[0] = ToolIntent.pastOpening(named[0]) }
            if rest > 0 { parts.append("mais \(rest)") }
            let line = PortugueseList.join(parts)
            if variants.last != line { variants.append(line) }
        }
        return variants
    }

    /// "12 ações", set quiet at the end of a line that names what the actions were for; nil for one action or none with a
    /// description.
    static func countNote(_ calls: [ToolCall]) -> String? {
        guard calls.count >= 2, calls.contains(where: { $0.intent != nil }) else { return nil }
        return "\(calls.count) ações"
    }

    /// The symbol of the row: the one of its actions when they are all of one kind, a stack otherwise.
    static func symbol(_ calls: [ToolCall]) -> String {
        guard let first = calls.first?.kind, calls.allSatisfy({ $0.kind == first }) else { return "rectangle.stack" }
        return first.symbol
    }
}
