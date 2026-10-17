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

    /// How many of the actions failed (or were stopped), nil for none: "1 falhou", "2 falharam".
    static func failures(_ calls: [ToolCall]) -> String? {
        let failed = calls.reduce(0) { $0 + ($1.state == .failed ? 1 : 0) }
        guard failed > 0 else { return nil }
        return failed == 1 ? "1 falhou" : "\(failed) falharam"
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
    /// the time when it is not known).
    static func work(_ calls: [ToolCall], seconds: Int?) -> String {
        let time = seconds.map { "Trabalhou por \(ElapsedFormat.text(seconds: $0))" } ?? "Trabalhou"
        return calls.isEmpty ? time : "\(time) · \(summary(calls, capitalized: false))"
    }

    /// The folded line of a run in the Orb's browser leads with the site it is on, the last one it opened ("gympass.com ·
    /// Abriu 1 página, clicou 3 vezes e preencheu 2 campos"); any other run is its `summary`.
    static func line(_ calls: [ToolCall]) -> String {
        let opened = calls.last { $0.kind == .browser && ["Abrindo página", "Abrindo uma aba"].contains($0.title) }
        guard let site = opened.flatMap({ WorkPhrase.host(of: WorkPhrase.firstLine(of: $0.detail)) }) else { return summary(calls) }
        return "\(site) · \(summary(calls))"
    }

    /// The symbol of the row: the one of its actions when they are all of one kind, a stack otherwise.
    static func symbol(_ calls: [ToolCall]) -> String {
        guard let first = calls.first?.kind, calls.allSatisfy({ $0.kind == first }) else { return "rectangle.stack" }
        return first.symbol
    }
}
