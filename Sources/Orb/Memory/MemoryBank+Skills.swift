import Foundation

// The Orb's skills inside its memory folder. `_skills.json` is a copy of the skills the Orb may use, written by the app,
// so `recall` can load one on demand; `_propostas/<comando>.md` holds what the Orb proposed until you decide.
// Neither folder is a memory page: they are not searched, listed in the panel or forgotten with "Esquecer".

extension MemoryBank {
    static let proposalsFolder = "_propostas"
    static let skillsFile = "_skills.json"
    /// Proposals waiting for you at once; more than this is the Orb talking to itself.
    static let maximumProposals = 5
    /// What you turned down, inside `_propostas/` (so it goes wherever the proposals go), newest first.
    static let declinedFile = "_recusadas.json"
    static let maximumDeclined = 12

    // MARK: Proposals

    /// Keeps `text` (a whole SKILL.md) for you to decide on, or says why not. The same command replaces its proposal.
    /// `unprompted`: the background review proposes it, not a turn in which you may have asked for it. What you already
    /// turned down is refused then; proposed in a turn, it is kept and no longer counts as turned down.
    func proposeSkill(_ text: String, unprompted: Bool = false) -> SkillProposalOutcome {
        guard !isClosed else { return .refused("The memory is not available now.") }
        let skills = skillDigests()
        // The proposals still waiting count as skills too: otherwise a second one for the same task passes while the first
        // waits, and the user ends up saving both.
        let waiting = proposals().filter { pending in !skills.contains { $0.slug == pending.slug } }.map {
            SkillDigest(slug: $0.slug, name: $0.slug, summary: $0.summary, instructions: $0.instructions, improvable: true)
        }
        let proposal: SkillProposal
        switch SkillProposal.validate(text, among: skills + waiting) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let valid): proposal = valid
        }
        let improves = skills.contains { $0.slug == proposal.slug }
        let declined = declinedProposals()
        let again = declined.first { proposal.wasDeclined(as: $0, improving: improves) }
        if let again, unprompted {
            return .refused("The user already declined this proposal (/\(again.slug)). Do not propose it again: answer \"Nothing to save.\".")
        }
        guard proposals().filter({ $0.slug != proposal.slug }).count < Self.maximumProposals else {
            return .refused("\(Self.maximumProposals) proposals are already waiting for the user. Do not propose more until they decide.")
        }
        let folder = directory.appending(path: Self.proposalsFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? Data(proposal.markdown().utf8).write(to: folder.appending(path: proposal.slug + ".md"), options: .atomic)) != nil else {
            return .refused("The proposal could not be written (folder unavailable).")
        }
        if let again { writeDeclined(declined.filter { $0.slug != again.slug }) } // kept now: no longer turned down
        return .proposed(slug: proposal.slug, isUpdate: improves)
    }

    /// What waits for you, newest first.
    func proposals() -> [SkillProposal] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: Self.proposalsFolder),
                                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "md" }.compactMap(Self.readProposal).sorted { $0.modified > $1.modified }
    }

    func proposal(_ slug: String) -> SkillProposal? {
        guard !slug.isEmpty, slug == Skill.cleanSlug(slug) else { return nil }
        return Self.readProposal(directory.appending(path: "\(Self.proposalsFolder)/\(slug).md"))
    }

    /// You decided (saved it, or did not want it): it goes away.
    func discardProposal(_ slug: String) {
        guard !slug.isEmpty, slug == Skill.cleanSlug(slug) else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: "\(Self.proposalsFolder)/\(slug).md"))
    }

    /// You did not want it: it goes away, and the review does not propose the same again (`proposeSkill`).
    func declineProposal(_ slug: String) {
        guard !isClosed, let proposal = proposal(slug) else { return }
        let digest = SkillDigest(slug: slug, name: slug, summary: proposal.summary, instructions: proposal.instructions, improvable: true)
        writeDeclined([digest] + declinedProposals().filter { $0.slug != slug })
        discardProposal(slug)
    }

    func declinedProposals() -> [SkillDigest] {
        (try? Data(contentsOf: directory.appending(path: "\(Self.proposalsFolder)/\(Self.declinedFile)")))
            .flatMap { try? JSONDecoder().decode([SkillDigest].self, from: $0) } ?? []
    }

    private func writeDeclined(_ declined: [SkillDigest]) {
        guard let data = try? JSONEncoder().encode(Array(declined.prefix(Self.maximumDeclined))) else { return }
        try? data.write(to: directory.appending(path: "\(Self.proposalsFolder)/\(Self.declinedFile)"), options: .atomic)
    }

    /// The skill was renamed: its proposal follows (the file name and the `name:` inside it). Nothing moves when the new
    /// command already has a proposal of its own.
    func renameProposal(from old: String, to new: String) {
        guard !isClosed, new == Skill.cleanSlug(new), var proposal = proposal(old), self.proposal(new) == nil else { return }
        proposal.slug = new
        let folder = directory.appending(path: Self.proposalsFolder)
        guard (try? Data(proposal.markdown().utf8).write(to: folder.appending(path: new + ".md"), options: .atomic)) != nil else { return }
        discardProposal(old)
    }

    private static func readProposal(_ url: URL) -> SkillProposal? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        return SkillProposal.read(text, modified: modified)
    }

    // MARK: The Orb's skills

    /// Writes the skills the Orb may use, only when they changed since the file was written (the app does it for every message).
    func publishSkills(_ skills: [SkillDigest]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = directory.appending(path: Self.skillsFile)
        guard !isClosed, let data = try? encoder.encode(skills), (try? Data(contentsOf: url)) != data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func skillDigests() -> [SkillDigest] {
        (try? Data(contentsOf: directory.appending(path: Self.skillsFile))).flatMap { try? JSONDecoder().decode([SkillDigest].self, from: $0) } ?? []
    }

    /// A skill longer than this names its sections, so the next read can load only the one it needs.
    static let longSkill = 6_000

    /// `recall "/slug"`: the skill's instructions, or what the Orb has instead. `recall "/slug#section"`: its opening
    /// (where a skill decides which part applies) and the first `## ` section whose heading has that text.
    func skillText(named query: String) -> String {
        let parts = query.split(separator: "#", maxSplits: 1).map(String.init)
        let slug = Skill.cleanSlug(parts.first ?? query)
        let skills = skillDigests()
        guard let skill = skills.first(where: { $0.slug == slug }) else {
            return "No skill /\(slug) for this Orb." + (skills.isEmpty ? "" : " Available: " + skills.map { "/" + $0.slug }.joined(separator: ", ") + ".")
        }
        let header = "Skill /\(skill.slug), \(skill.name) (instructions the user wrote, approved or installed; follow them for this task):\n\n"
        let sections = Self.sections(of: skill.instructions)
        if parts.count == 2, sections.count > 1 {
            let wanted = MemoryText.fold(parts[1])
            guard let section = sections.dropFirst().first(where: { MemoryText.fold($0.heading).contains(wanted) }) else {
                return "No section \"\(parts[1])\" in /\(slug). Sections: " + sections.dropFirst().map(\.heading).joined(separator: "; ") + "."
            }
            return header + [sections[0].text, section.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let index = skill.instructions.count > Self.longSkill && sections.count > 2
            ? "\n\nSections, loadable with recall \"/\(slug)#section\": " + sections.dropFirst().map(\.heading).joined(separator: "; ") + "."
            : ""
        return header + skill.instructions + index
    }

    /// The skill split at its `## ` headings: first what comes before any of them (empty heading), then each section.
    /// A `#` inside a fenced block is not a heading, and `### ` stays in its section.
    static func sections(of text: String) -> [(heading: String, text: String)] {
        var sections: [(heading: String, lines: [String])] = [("", [])]
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle() }
            if !fenced, line.hasPrefix("## ") { sections.append((String(line.dropFirst(3)), [])) }
            sections[sections.count - 1].lines.append(line)
        }
        return sections.map { ($0.heading, $0.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
