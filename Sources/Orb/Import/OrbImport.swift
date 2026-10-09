import Foundation

// "Importar de outro assistente": what another assistant knew about the person, read from a pasted answer, a file or a
// folder, shown in a preview and written into the new Orb's memory. Everything here is data: no permission, mode,
// capability, connector or routine ever comes from an import. The reader is `OrbImportReader`.

/// One thing the preview lists, with its checkbox. Anything that looks like an order to the Orb starts unchecked.
struct ImportItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title = ""
    var text: String
    var isSuspicious: Bool
    var isOn: Bool
    /// Characters of the original that reading left out (`ImportLimits.identityText`).
    var omitted = 0

    /// `text` as it is read; `allowsLinks: false` makes a link suspicious (identity and preferences are instructions).
    init(_ text: String, title: String = "", allowsLinks: Bool = true) {
        self.text = text
        self.title = title
        isSuspicious = ImportGuard.isSuspicious(title + " " + text, allowsLinks: allowsLinks)
        isOn = !isSuspicious
    }
}

/// A skill the import would create: limited to the new Orb, run only when the person types `/slug`.
struct ImportSkill: Identifiable, Equatable, Sendable {
    let id = UUID()
    var slug: String
    var name: String
    var summary: String
    var instructions: String
    var isSuspicious: Bool
    var isOn: Bool

    init(slug: String, name: String, summary: String, instructions: String, isOn: Bool = true) {
        self.slug = slug
        self.name = name
        self.summary = summary
        self.instructions = instructions
        isSuspicious = ImportGuard.isSuspicious(name + " " + summary + " " + instructions)
        self.isOn = isOn && !isSuspicious
    }
}

/// What was read, before the person confirms it.
struct OrbImport: Equatable, Sendable {
    /// "ChatGPT", "Hermes", "Cartão de personagem", "Texto colado"…
    var source: String
    var name = ""
    var role = ""
    var identity: ImportItem?
    var preferences: [ImportItem] = []
    var facts: [ImportItem] = []
    var procedures: [ImportItem] = []
    var skills: [ImportSkill] = []
    /// Free text without headings: the preview asks whether it is instructions or memories (`asInstructions`).
    var isFreeText = false
    var asInstructions = false
    /// The free text itself, for reading it the other way.
    var freeText = ""

    var isEmpty: Bool { identity == nil && preferences.isEmpty && facts.isEmpty && procedures.isEmpty && skills.isEmpty }
}

/// How much of an import fits: the identity and preferences go to every prompt, so they have the prompt's shares.
enum ImportLimits {
    static let identity = MemoryBank.identityShare
    /// How much of the instructions is read: the part over `identity` goes to the memory, in pages of
    /// `MemoryBank.maximumLength`; what passes this is left out, and the preview says how much.
    static let identityText = 6_000
    static let preferences = 40, preferenceLength = 240, preferencesTotal = MemoryBank.preferencesShare
    static let facts = 60, procedures = 12, skills = 5
    /// What is listed in the preview (the rest is dropped when reading).
    static let listed = 60, listedSkills = 20
    static let skillInstructions = 4_000, skillSummary = 160
    static let bytes = 1_000_000, fileBytes = 200_000
}

/// What `OrbImport` writes, after the selection and the limits: the identity text, the memory pages and the skills.
struct ImportPlan: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        var kind: MemoryKind
        var title: String
        var text: String
    }

    var identity = ""
    var pages: [Page] = []
    var skills: [ImportSkill] = []

    var instructionCount: Int { identity.isEmpty ? 0 : 1 }
    var memoryCount: Int { pages.count }
    var isEmpty: Bool { identity.isEmpty && pages.isEmpty && skills.isEmpty }

    /// "1 instrução, 9 lembranças, 2 skills".
    var summary: String { parts.joined(separator: ", ") }

    /// "1 instrução, 9 lembranças e 2 skills": for the Orb's first conversation.
    var sentence: String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " e " + parts[parts.count - 1]
    }

    private var parts: [String] {
        func count(_ number: Int, _ one: String, _ many: String) -> String? { number == 0 ? nil : number == 1 ? "1 \(one)" : "\(number) \(many)" }
        return [count(instructionCount, "instrução", "instruções"), count(memoryCount, "lembrança", "lembranças"),
                count(skills.count, "skill", "skills")].compactMap { $0 }
    }
}

extension OrbImport {
    /// The checked items within the limits. The identity above 1 500 characters keeps its start and the whole text
    /// becomes facts of up to 2 000 characters each (searchable, and data); preferences beyond 40, 240 characters each or 1 500 in all become
    /// facts too; facts stop at 60, procedures at 12 and skills at 5.
    func plan() -> ImportPlan {
        var plan = ImportPlan()
        var preferences: [ImportPlan.Page] = [], facts: [ImportPlan.Page] = []
        if let identity, identity.isOn {
            plan.identity = MemoryText.clip(identity.text, ImportLimits.identity)
            if identity.text.count > ImportLimits.identity {
                let pieces = Self.pieces(of: identity.text)
                facts += pieces.enumerated().map { index, piece in
                    .init(kind: .fato, title: "Instruções completas de \(source)" + (pieces.count > 1 ? " (\(index + 1)/\(pieces.count))" : ""),
                          text: piece)
                }
            }
        }
        facts += self.facts.filter(\.isOn).map { .init(kind: .fato, title: $0.title, text: $0.text) }
        var used = 0
        for item in self.preferences where item.isOn {
            let text = MemoryText.clip(MemoryText.flatten(item.text), ImportLimits.preferenceLength)
            if preferences.count < ImportLimits.preferences, used + text.count + 2 <= ImportLimits.preferencesTotal {
                used += text.count + 2
                preferences.append(.init(kind: .preferencia, title: "", text: text))
            } else {
                facts.append(.init(kind: .fato, title: "", text: item.text))
            }
        }
        plan.pages = preferences + facts.prefix(ImportLimits.facts)
            + procedures.filter(\.isOn).prefix(ImportLimits.procedures).map { .init(kind: .procedimento, title: $0.title, text: $0.text) }
        plan.skills = Array(skills.filter(\.isOn).prefix(ImportLimits.skills))
        return plan
    }

    /// `text` in pieces a memory page can hold (`MemoryBank.maximumLength`), cut between lines where it can.
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = [], current = ""
        for var line in text.split(separator: "\n") {
            while !line.isEmpty {
                if !current.isEmpty, current.count + 1 + line.count > MemoryBank.maximumLength {
                    pieces.append(current)
                    current = ""
                }
                let head = line.prefix(MemoryBank.maximumLength - (current.isEmpty ? 0 : current.count + 1))
                current += (current.isEmpty ? "" : "\n") + head
                line = line.dropFirst(head.count)
            }
        }
        return current.isEmpty ? pieces : pieces + [current]
    }
}

/// Cleans text from outside before it is shown or written: secrets out, no way to close the memory block or fake a
/// heading.
enum ImportSanitizer {
    /// One line: `MemoryText.flatten` (no heading marks, no control characters) after the secrets are scrubbed.
    static func line(_ text: String, limit: Int = 500) -> String {
        MemoryText.clip(MemoryText.flatten(withoutTags(MemorySanitizer.scrub(text))), limit)
    }

    /// Several lines, each one cleaned as `line` does (a heading's `#` goes, a list's `- ` stays); empty lines go.
    static func block(_ text: String, limit: Int) -> String {
        let lines = withoutTags(MemorySanitizer.scrub(text)).components(separatedBy: .newlines)
            .map { MemoryText.flatten($0) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Instructions of a skill: secrets and control characters out, lines and indentation kept (they run only when the
    /// person types the command).
    static func instructions(_ text: String, limit: Int = ImportLimits.skillInstructions) -> String {
        let visible = String(String.UnicodeScalarView(withoutTags(MemorySanitizer.scrub(text)).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }))
        return String(visible.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// The memory block's tags, which would let a note close it and speak as the prompt.
    static func withoutTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?\s*memory_notes[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
}

/// Spots text that reads as an order to the Orb (skip the permission, ignore the rules, run this, send that). Not a
/// wall: the item stays in the preview, unchecked and marked, and the person decides. The permissions themselves are
/// enforced by the code, whatever a note says.
enum ImportGuard {
    private static let phrases = [
        "ignore as instrucoes", "ignore as regras", "ignore todas as", "ignore previous", "ignore all previous",
        "ignore the previous", "ignore your instructions", "ignore your rules", "desconsidere as instrucoes",
        "esqueca as instrucoes", "forget your instructions", "system prompt", "prompt de sistema",
        "sem pedir permissao", "sem pedir confirmacao", "sem pedir autorizacao", "without asking", "without permission",
        "without confirmation", "nunca peca", "nunca pergunte", "nao peca permissao", "nao pergunte antes",
        "never ask", "don't ask", "do not ask", "bypass", "modo sem permissao", "sudo ", "rm -rf", "base64 -d",
        "envie para", "send to ", "api key", "apikey", "chave de api", "chave da api", "jailbreak", "exfiltr",
    ]

    private static let patterns = [#"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh"#]
        .map { try! NSRegularExpression(pattern: $0) }

    private static let link = try! NSRegularExpression(pattern: #"https?://|www\."#)

    /// Accents, case and the curly apostrophe do not matter. `allowsLinks: false` also flags a web address.
    static func isSuspicious(_ text: String, allowsLinks: Bool = true) -> Bool {
        let folded = MemoryText.fold(text).replacingOccurrences(of: "’", with: "'")
        let range = NSRange(folded.startIndex..., in: folded)
        return phrases.contains { folded.contains($0) }
            || patterns.contains { $0.firstMatch(in: folded, range: range) != nil }
            || (!allowsLinks && link.firstMatch(in: folded, range: range) != nil)
    }
}
