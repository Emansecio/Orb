import Foundation

// The shapes `OrbImportReader` understands in text: the "Cartão do Orb" (Markdown, what `ImportPrompt` asks for),
// Character Card JSON and plain text. Each takes what it knows and drops the rest.

extension OrbImportReader {
    // MARK: Cartão do Orb

    private enum Part: Hashable {
        case how, preferences, facts, procedures, skills

        /// Procedures and skills are made of `###` entries; the others are lists or text.
        var hasEntries: Bool { self == .procedures || self == .skills }

        static let procedureTitle = "Procedimentos"

        /// The headings each part answers to (folded: no accents, lowercase), the Portuguese ones first.
        static let names: [(Part, [String])] = [
            (.how, ["como funciona", "instrucoes", "identidade", "persona", "personalidade", "instructions", "identity", "how it works"]),
            (.preferences, ["preferencias", "preferences"]),
            (.facts, ["sobre mim", "sobre voce", "fatos", "memoria", "memorias", "lembrancas", "about me", "facts", "memory", "memories"]),
            (.procedures, ["procedimentos", "procedures", "workflows", "fluxos de trabalho"]),
            (.skills, ["skills", "skill", "habilidades"]),
        ]

        init?(heading: String) {
            let folded = MemoryText.fold(heading)
            guard let found = Self.names.first(where: { $0.1.contains { folded == $0 || folded.hasPrefix($0 + " ") || folded.hasPrefix($0 + "(") } })
            else { return nil }
            self = found.0
        }
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marks = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), trimmed.dropFirst(marks.count).first == " " else { return nil }
        return (marks.count, trimmed.dropFirst(marks.count).trimmingCharacters(in: CharacterSet(charactersIn: " *:")))
    }

    private static let fieldPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s*)?\**(name|nome|role|papel|vibe|origem|origin|source|fonte)\**\s*:\s*\**\s*(.+?)\s*$"#, options: .caseInsensitive)

    /// `Papel: …`, `- **Name:** …`: a line of a card's header or of an OpenClaw IDENTITY.md. A value left as the prompt's
    /// `<placeholder>` is not one.
    static func field(_ line: String) -> (key: String, value: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = fieldPattern.firstMatch(in: line, range: range), let key = Range(match.range(at: 1), in: line),
              let value = Range(match.range(at: 2), in: line) else { return nil }
        let text = String(line[value]).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        return text.isEmpty || (text.hasPrefix("<") && text.hasSuffix(">")) ? nil : (line[key].lowercased(), text)
    }

    /// The card, wherever it is in the text (inside a code block, with talk before or after it); nil when no heading
    /// of it is there.
    static func readCard(_ text: String) -> OrbImport? {
        var name = "", role = "", origin = ""
        var current: (part: Part, level: Int)?
        var seen = false
        var lines: [Part: [String]] = [:]
        var entries: [Part: [(title: String, lines: [String])]] = [:]
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            if let head = heading(line) {
                if let part = Part(heading: head.title) {
                    current = (part, head.level)
                    seen = true
                } else if let now = current, head.level > now.level {
                    // A subtitle of a list (`### Trabalho` under "Sobre mim") is not an item; in the instructions it is a line.
                    if now.part.hasEntries { entries[now.part, default: []].append((head.title, [])) } else if now.part == .how { lines[now.part, default: []].append(head.title) }
                } else {
                    current = nil
                    if head.level == 1, name.isEmpty { name = cardName(head.title) }
                }
            } else if let now = current {
                if now.part.hasEntries {
                    // Text under "Procedimentos" before any `###` is one procedure of that name.
                    if entries[now.part]?.isEmpty ?? true, now.part == .procedures, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        entries[now.part] = [(Part.procedureTitle, [])]
                    }
                    if !(entries[now.part]?.isEmpty ?? true) { entries[now.part]![entries[now.part]!.count - 1].lines.append(line) }
                } else {
                    lines[now.part, default: []].append(line)
                }
            } else if let (key, value) = field(line) {
                switch key {
                case "name", "nome": name = name.isEmpty ? value : name
                case "role", "papel": role = value
                default: origin = value
                }
            }
        }
        guard seen else { return nil }
        var card = OrbImport(source: origin.isEmpty ? "Cartão do Orb" : ImportSanitizer.line(origin, limit: 40))
        card.name = ImportSanitizer.line(name, limit: 40)
        card.role = ImportSanitizer.line(role, limit: 120)
        card.identity = identity(from: (lines[.how] ?? []).joined(separator: "\n"))
        card.preferences = items(self.entries((lines[.preferences] ?? []).joined(separator: "\n")), allowsLinks: false)
        card.facts = items(self.entries((lines[.facts] ?? []).joined(separator: "\n")))
        card.procedures = (entries[.procedures] ?? []).prefix(ImportLimits.procedures).compactMap { title, body in
            let text = ImportSanitizer.block(body.joined(separator: "\n"), limit: MemoryBank.maximumLength)
            return text.isEmpty ? nil : ImportItem(text, title: ImportSanitizer.line(title, limit: 80))
        }
        card.skills = limitSkills((entries[.skills] ?? []).prefix(ImportLimits.listedSkills).compactMap { title, body in
            skill(title: title, summary: "", body: body.joined(separator: "\n"))
        })
        return card
    }

    /// "Orb: Atlas" or "Atlas": the card's title is the name; the prompt's `<placeholder>` is not one.
    private static func cardName(_ title: String) -> String {
        var name = title
        if let range = name.range(of: #"^orb\s*[:\-–—]\s*"#, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(range) }
        return name.hasPrefix("<") ? "" : name
    }

    /// `### /comando: o que faz` or `### Nome` with its instructions under it.
    static func skill(title: String, summary: String, body: String) -> ImportSkill? {
        var head = title.trimmingCharacters(in: .whitespaces)
        let isCommand = head.hasPrefix("/")
        if isCommand { head.removeFirst() }
        var about = summary
        if let cut = head.range(of: ":") ?? head.range(of: " — ") ?? head.range(of: " - ") {
            about = String(head[cut.upperBound...])
            head = String(head[..<cut.lowerBound])
        }
        let slug = Skill.cleanSlug(head)
        let instructions = ImportSanitizer.instructions(body)
        guard !slug.isEmpty, !instructions.isEmpty else { return nil }
        let spaced = slug.replacingOccurrences(of: "-", with: " ")
        let name = isCommand ? spaced.prefix(1).uppercased() + spaced.dropFirst() : ImportSanitizer.line(head, limit: 60)
        let shown = ImportSanitizer.line(about)
        let first = ImportSanitizer.line(instructions.components(separatedBy: .newlines).first ?? "")
        return ImportSkill(slug: slug, name: name, summary: MemoryText.clip(shown.isEmpty ? first : shown, ImportLimits.skillSummary),
                           instructions: instructions)
    }

    /// At most `ImportLimits.skills` of them start checked.
    static func limitSkills(_ skills: [ImportSkill]) -> [ImportSkill] {
        var checked = 0
        return skills.prefix(ImportLimits.listedSkills).map { skill in
            var skill = skill
            if skill.isOn { checked += 1 }
            if checked > ImportLimits.skills { skill.isOn = false }
            return skill
        }
    }

    // MARK: Lists

    /// The identity text: the lines cleaned, up to `ImportLimits.identityText` characters (the plan splits it between the
    /// identity and the memory); what passes it is counted in `omitted`, for the preview to say.
    static func identity(from text: String) -> ImportItem? {
        let whole = ImportSanitizer.block(text, limit: .max)
        let body = String(whole.prefix(ImportLimits.identityText)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        var item = ImportItem(body, allowsLinks: false)
        item.omitted = max(0, whole.count - ImportLimits.identityText)
        return item
    }

    static func items(_ entries: [String], allowsLinks: Bool = true) -> [ImportItem] {
        entries.prefix(ImportLimits.listed).compactMap { entry in
            let text = ImportSanitizer.line(entry)
            return text.isEmpty ? nil : ImportItem(text, allowsLinks: allowsLinks)
        }
    }

    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(?:[-*•]|\d+[.)])\s+"#)
    private static let comments = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

    /// One entry per thing: split at `§` (Hermes), else at each list marker (the lines under one belong to it), else at
    /// each line, or at each paragraph for a file. HTML comments (`<!-- written … -->`) and headings are dropped.
    static func entries(_ text: String, byParagraph: Bool = false) -> [String] {
        let clean = comments.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        if clean.contains("§") { return clean.components(separatedBy: "§").map(flat).filter { !$0.isEmpty } }
        let lines = clean.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        func isBullet(_ line: String) -> Bool { bullet.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        if lines.contains(where: isBullet) {
            var found: [String] = []
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if isBullet(line) || found.isEmpty {
                    found.append(line.replacingOccurrences(of: bullet.pattern, with: "", options: .regularExpression))
                } else {
                    found[found.count - 1] += " " + line
                }
            }
            return found.map(flat).filter { !$0.isEmpty }
        }
        if byParagraph {
            return lines.joined(separator: "\n").components(separatedBy: "\n\n").map(flat).filter { !$0.isEmpty }
        }
        return lines.map(flat).filter { !$0.isEmpty }
    }

    private static func flat(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Free text

    /// Text with no headings: lines or list items become memories, unless it reads like instructions ("Você é…",
    /// "Atue como…"), then it becomes the identity. The preview lets the person say which.
    static func readFreeText(_ text: String, asInstructions: Bool?) -> OrbImport {
        let start = MemoryText.fold(String(text.prefix(80)))
        let guess = ["voce e ", "you are ", "atue como", "act as ", "aja como", "seu papel", "your role"].contains { start.hasPrefix($0) }
        var found = OrbImport(source: "Texto colado")
        found.isFreeText = true
        found.freeText = text
        found.asInstructions = asInstructions ?? guess
        if found.asInstructions { found.identity = identity(from: text) } else { found.facts = items(entries(text)) }
        return found
    }

    // MARK: Character Card JSON

    /// nil when the text is not JSON at all (a list of dates in brackets is text); throws for JSON that is no card.
    static func readJSON(_ text: String) throws -> OrbImport? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            if text.hasPrefix("{") { throw ImportFailure.notACard }
            return nil
        }
        if let list = object as? [[String: Any]] {
            throw list.contains { $0["mapping"] != nil } ? ImportFailure.chatGPTHistory : ImportFailure.unrecognized
        }
        guard let top = object as? [String: Any] else { throw ImportFailure.unrecognized }
        // V2 and V3 keep everything under `data`; V1 has the fields at the top.
        let card = (top["data"] as? [String: Any]).flatMap { $0["name"] != nil ? $0 : nil } ?? top
        let fields = ["description", "personality", "scenario", "system_prompt", "first_mes", "character_book"]
        guard let name = (card["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              fields.contains(where: { card[$0] != nil }) else { throw ImportFailure.notACard }
        let nickname = (card["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name

        func value(_ key: String) -> String {
            var value = (card[key] as? String) ?? ""
            for (pattern, replacement) in [(#"\{\{\s*original\s*\}\}"#, ""), (#"\{\{\s*char\s*\}\}|<BOT>"#, nickname),
                                           (#"\{\{\s*user\s*\}\}|<USER>"#, "a pessoa")] {
                // The replacement is a regex template: a `$0` or a `\` in the character's name is text, not a reference.
                value = value.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: replacement),
                                                   options: [.regularExpression, .caseInsensitive])
            }
            return value
        }

        var found = OrbImport(source: "Cartão de personagem")
        found.name = ImportSanitizer.line(name, limit: 40)
        let description = ImportSanitizer.line(value("description"), limit: 400)
        found.role = MemoryText.clip(description.range(of: ". ").map { String(description[..<$0.lowerBound]) } ?? description, 80)
        found.identity = identity(from: ["system_prompt", "personality", "scenario", "description"].map(value).filter { !$0.isEmpty }.joined(separator: "\n"))
        let entries = ((card["character_book"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
        found.facts = entries.filter { $0["enabled"] as? Bool == true }.prefix(ImportLimits.listed).compactMap { entry in
            let content = ImportSanitizer.line((entry["content"] as? String) ?? "")
            let title = (entry["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (entry["keys"] as? [String])?.first ?? ""
            return content.isEmpty ? nil : ImportItem(content, title: ImportSanitizer.line(title, limit: 80))
        }
        return found
    }
}
