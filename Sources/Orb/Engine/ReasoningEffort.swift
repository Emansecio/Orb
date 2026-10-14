import Foundation

/// How hard a model thinks before it answers (the "Esforço" of an Orb). Each provider's catalog says which levels a
/// model takes (Claude Code's `supportedEffortLevels`, ChatGPT's `supported_reasoning_levels`); the Orb keeps its
/// choice by the provider's own name for the level, and sends it only to a model that lists it.
enum ReasoningEffort {
    /// The levels the Orb knows, lightest first. A level a catalog lists outside this set is left out: ChatGPT's
    /// "ultra" also hands the task to helpers of Codex's own harness, which the Orb does not run.
    static let known = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func label(_ level: String) -> String {
        switch level {
        case "none": "Nenhum"
        case "minimal": "Mínimo"
        case "low": "Baixo"
        case "medium": "Médio"
        case "high": "Alto"
        case "xhigh": "Muito alto"
        case "max": "Máximo"
        default: level
        }
    }

    /// The known levels among those a catalog lists, in the Orb's order; nil when none is left (the model has no setting).
    static func levels(_ listed: [String]) -> [String]? {
        let kept = known.filter(listed.contains)
        return kept.isEmpty ? nil : kept
    }

    /// The level a turn sends: the Orb's choice when its model takes it; nil (the provider's default) otherwise.
    static func sent(_ chosen: String, for model: ProviderModel?) -> String? {
        guard !chosen.isEmpty, model?.efforts?.contains(chosen) == true else { return nil }
        return chosen
    }

    /// The picker's first option: the model's own default, named when the catalog says which it is.
    static func defaultLabel(for model: ProviderModel?) -> String {
        guard let level = model?.defaultEffort, known.contains(level) else { return "Padrão do modelo" }
        return "Padrão (\(label(level)))"
    }

    /// The line under the picker: a level the model does not take, or a cost worth knowing about.
    static func note(_ chosen: String, for model: ProviderModel?) -> String? {
        guard !chosen.isEmpty else { return nil }
        guard model?.efforts != nil else { return "Este modelo não tem ajuste de esforço; ele usa o padrão dele." }
        guard sent(chosen, for: model) != nil else {
            return "Este modelo não tem o esforço \(label(chosen)); ele usa o padrão dele."
        }
        return ["xhigh", "max"].contains(chosen)
            ? "Esforço alto deixa as respostas mais lentas e gasta mais do limite da assinatura." : nil
    }
}
