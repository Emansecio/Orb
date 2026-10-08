import AppKit
import Foundation

// The logic behind the Orb's panel and the new-Orb sheet that is worth testing without drawing anything: which tab
// an Orb opens on, how its look is summarized, how its memory is grouped and searched, the sheet's height.

/// The panel's tabs.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case general, memory, folder, routines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Geral"
        case .memory: "Memória"
        case .folder: "Pasta e acessos"
        case .routines: "Rotinas"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .memory: "brain"
        case .folder: "folder"
        case .routines: "clock.arrow.circlepath"
        }
    }
}

/// The tab each Orb's panel was last on (a per-viewer convenience: it never reaches the Orb's data).
enum InspectorTabMemory {
    static let key = "inspectorTabs"

    static func tab(for botID: UUID, defaults: UserDefaults = .standard) -> InspectorTab {
        let stored = defaults.dictionary(forKey: key) as? [String: String]
        return stored?[botID.uuidString].flatMap(InspectorTab.init(rawValue:)) ?? .general
    }

    static func remember(_ tab: InspectorTab, for botID: UUID, defaults: UserDefaults = .standard) {
        var stored = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        if tab == .general { stored[botID.uuidString] = nil } else { stored[botID.uuidString] = tab.rawValue }
        defaults.set(stored, forKey: key)
    }
}

/// How the panel talks about what the Orb may use: a name and one line each.
enum CapabilityCopy {
    static func title(_ capability: Capability) -> String {
        switch capability {
        case .terminal: "Terminal e arquivos"
        case .browser: "Navegar na web"
        case .computerUse: "Controlar apps do Mac"
        case .connectors: "Conectores"
        }
    }

    static func subtitle(_ capability: Capability) -> String {
        switch capability {
        case .terminal: "Rodar comandos e ler e escrever arquivos"
        case .browser: "Abrir e ler páginas da internet"
        case .computerUse: "Abrir, clicar e digitar em outros apps"
        case .connectors: "Usar as ferramentas dos seus conectores"
        }
    }

    /// The connectors row's line: how many are on, since the toggle alone does not say.
    static func connectorsLine(enabled: Int, total: Int) -> String {
        switch (enabled, total) {
        case (_, 0): "Nenhum conector instalado"
        case (0, _): "Nenhum ativo (\(total) instalado\(total == 1 ? "" : "s"))"
        case (1, _): "1 conector ativo"
        default: "\(enabled) conectores ativos"
        }
    }
}

/// The look of an Orb in one line ("Índigo · Pílulas · Equilibrado"), so the panel does not list every option.
enum AppearanceSummary {
    @MainActor
    static func text(for orb: OrbConfig, catalog: OrbCatalog = .shared) -> String {
        [catalog.label(.color, orb.color), catalog.label(.eyes, orb.eyes), orb.temperament.label].joined(separator: " · ")
    }
}

/// One kind of memory with the items to show under its heading.
struct MemoryGroup: Identifiable, Equatable, Sendable {
    var kind: MemoryKind
    var items: [MemorySnapshot.Item]
    var id: MemoryKind { kind }

    var title: String {
        switch kind {
        case .preferencia: "Preferências"
        case .fato: "Fatos"
        case .procedimento: "Procedimentos"
        case .sessao: "Conversas guardadas"
        case .identidade: "Identidade"
        }
    }
}

enum MemoryGroups {
    /// What the memory screen lists, in this order. The identity has its own block.
    static let kinds: [MemoryKind] = [.preferencia, .fato, .procedimento, .sessao]

    /// More items than this and the panel offers a search field.
    static let searchableAbove = 6

    /// Items grouped by kind (empty groups left out), in the order given (the snapshot comes newest first, so no
    /// sorting here); only those matching `query` (every word of it, ignoring case and accents, in the title or the
    /// text), and only `kind` when given. Searching folds each item's text once: `cache` keeps it between keystrokes.
    static func make(_ items: [MemorySnapshot.Item], matching query: String = "", kind only: MemoryKind? = nil,
                     cache: FoldedTextCache? = nil) -> [MemoryGroup] {
        let words = SearchText.words(query)
        let matching = words.isEmpty ? items : items.filter { matches($0, words, cache: cache) }
        if words.isEmpty { cache?.clear() }
        return kinds.compactMap { kind in
            guard only == nil || only == kind else { return nil }
            let inKind = matching.filter { $0.kind == kind }
            return inKind.isEmpty ? nil : MemoryGroup(kind: kind, items: inKind)
        }
    }

    static func matches(_ item: MemorySnapshot.Item, _ words: [String], cache: FoldedTextCache? = nil) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = cache?.folded(item) ?? SearchText.fold(item.title + " " + item.body)
        return words.allSatisfy { haystack.contains($0) }
    }

    /// "12 lembranças · 9 conversas guardadas", for the line under the memory's heading.
    static func summary(_ items: [MemorySnapshot.Item]) -> String {
        let sessions = items.filter { $0.kind == .sessao }.count
        let notes = items.count - sessions
        var parts: [String] = []
        if notes > 0 { parts.append(notes == 1 ? "1 lembrança" : "\(notes) lembranças") }
        if sessions > 0 { parts.append(sessions == 1 ? "1 conversa guardada" : "\(sessions) conversas guardadas") }
        return parts.isEmpty ? "Nada guardado ainda" : parts.joined(separator: " · ")
    }
}

/// The folded (lowercase, no accents) text of memory items, kept while someone types in the search field so each
/// keystroke only compares strings. An item that changed is folded again; the cache is emptied when the search ends.
final class FoldedTextCache {
    private var entries: [String: (item: MemorySnapshot.Item, folded: String)] = [:]

    func folded(_ item: MemorySnapshot.Item) -> String {
        if let entry = entries[item.path], entry.item == item { return entry.folded }
        let folded = SearchText.fold(item.title + " " + item.body)
        entries[item.path] = (item, folded)
        return folded
    }

    /// Called when a search ends, so forgotten items do not stay in memory.
    func clear() {
        entries.removeAll(keepingCapacity: false)
    }
}

enum SearchText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    static func words(_ query: String) -> [String] {
        fold(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// The height of the new-Orb sheet: the whole form when the window is tall enough, the window's height less a
/// margin when it is not (the form scrolls then).
enum NewBotSheetLayout {
    static let preferredHeight: CGFloat = 700
    static let minimumHeight: CGFloat = 520
    static let margin: CGFloat = 60

    static func height(preferred: CGFloat = preferredHeight, windowHeight: CGFloat?) -> CGFloat {
        guard let windowHeight, windowHeight > 0 else { return preferred }
        return min(preferred, max(minimumHeight, windowHeight - margin))
    }

    /// The app window a sheet opens over (the sheet itself is the key window by then).
    @MainActor
    static func height(preferred: CGFloat = preferredHeight) -> CGFloat {
        height(preferred: preferred, windowHeight: (NSApp.mainWindow ?? NSApp.keyWindow)?.contentLayoutRect.height)
    }
}
