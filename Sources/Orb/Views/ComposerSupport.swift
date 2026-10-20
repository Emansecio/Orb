import Foundation
import UniformTypeIdentifiers

// The logic behind the composer's pieces, apart from their views so it can be tested: texts of the permission chip,
// searching skills, the working line's clock, the icon of an attachment, recently used models, and when the
// inspector steps aside.

// MARK: Permission

enum PermissionChipText {
    /// What the chip says: the mode, and how many standing grants apply (they only count where the Orb asks).
    static func label(_ permission: PermissionState) -> String {
        let count = permission.rules.count
        guard permission.mode == .ask, count > 0 else { return permission.mode.label }
        return "\(permission.mode.label) · \(count)"
    }

    /// The same for a screen reader and the tooltip: "Perguntar antes, 4 liberações".
    static func spoken(_ permission: PermissionState) -> String {
        let count = permission.rules.count
        guard permission.mode == .ask, count > 0 else { return permission.mode.label }
        return "\(permission.mode.label), \(count) \(count == 1 ? "liberação" : "liberações")"
    }

    /// The heading of the picker's footer, nil when there is nothing standing to explain. The count comes last, so
    /// one rule or many reads right.
    static func grantsTitle(_ permission: PermissionState) -> String? {
        let count = permission.rules.count
        return count > 0 ? "Liberações permanentes: \(count)" : nil
    }
}

// MARK: Skills

enum SkillSearch {
    /// The skills a typed word brings up, best first: a name or slug that starts with it, then one that contains it,
    /// then one whose summary does. Ignores case and accents; nothing typed lists them in the order given.
    static func matches(_ skills: [Skill], _ query: String) -> [Skill] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return skills }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func score(_ skill: Skill) -> Int? {
            // The slug typed in full comes first, so it is never cut from the few suggestions shown
            // (and Return sends it) behind longer slugs that merely start the same way.
            if words.count == 1, skill.slug.compare(words[0], options: .caseInsensitive) == .orderedSame { return -1 }
            var total = 0
            for word in words {
                if skill.slug.range(of: word, options: options.union(.anchored)) != nil
                    || skill.name.range(of: word, options: options.union(.anchored)) != nil {
                    total += 0
                } else if skill.slug.range(of: word, options: options) != nil || skill.name.range(of: word, options: options) != nil {
                    total += 1
                } else if skill.summary.range(of: word, options: options) != nil {
                    total += 2
                } else {
                    return nil
                }
            }
            return total
        }
        return skills.enumerated().compactMap { index, skill in score(skill).map { (index, $0, skill) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.2)
    }

    /// Whether the draft is exactly a skill's `/slug`: nothing left to complete, so Return sends it as it is.
    static func isComplete(_ draft: String, skills: [Skill]) -> Bool {
        guard let query = slashQuery(in: draft) else { return false }
        // Exact, as `SystemPrompt.expandSkill` matches.
        return skills.contains { $0.slug == query }
    }

    /// What is being typed after a leading "/" while it is still one word (`"/res"` → `"res"`); nil once the
    /// draft is anything else, so the suggestions go away as soon as you move on.
    static func slashQuery(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        return rest.contains(where: \.isWhitespace) ? nil : String(rest)
    }
}

// MARK: Clock

enum ElapsedFormat {
    /// "12 s", "1 min 05 s", "1 h 02 min": short, with fixed-width seconds past a minute so it does not jitter.
    static func text(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min " + String(format: "%02d", seconds % 60) + " s" }
        return "\(seconds / 3600) h " + String(format: "%02d", seconds % 3600 / 60) + " min"
    }

    /// The working line's clock: empty during the first second, so a quick answer never flashes "0 s".
    static func working(since start: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        return seconds < 1 ? "" : text(seconds: seconds)
    }
}

// MARK: Attachments

enum AttachmentKind {
    /// An SF Symbol for a file by its type: documents, spreadsheets, PDFs, archives, audio, video, code.
    static func symbol(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
            return "tablecells"
        }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) || type.conforms(to: .content) { return "doc.text" }
        return "doc"
    }

    /// "2,1 MB"; nil when the size is unknown.
    static func size(_ bytes: Int?) -> String? {
        bytes.map { fileSize(Int64($0)) }
    }

    /// "2,1 MB": the one way sizes are written (Finder style).
    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Models

/// The models picked most recently in any Orb, newest first, kept across launches.
struct RecentModels: Equatable {
    static let limit = 3
    private static let key = "orb.recentModels"

    private(set) var ids: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = (defaults.stringArray(forKey: Self.key) ?? []).filter { ModelRef($0) != nil }
    }

    /// Moves `id` ("provider/model") to the front. The app's default ("") is not a model of its own and is skipped.
    mutating func record(_ id: String) {
        guard ModelRef(id) != nil else { return }
        ids = Array(([id] + ids.filter { $0 != id }).prefix(Self.limit))
        defaults.set(ids, forKey: Self.key)
    }

    static func == (lhs: RecentModels, rhs: RecentModels) -> Bool { lhs.ids == rhs.ids }
}

/// The rows of the composer's model list for a typed search: what to show, grouped. Kept apart from the view so the
/// grouping is testable and the list is built once per keystroke, not per row.
struct ModelListing: Equatable {
    struct Group: Equatable {
        var provider: ProviderKind
        var models: [ProviderModel]
    }

    /// Recently used models that are still available (only when nothing is typed).
    var recents: [(ref: String, name: String, provider: String)]
    var groups: [Group]

    static func == (lhs: ModelListing, rhs: ModelListing) -> Bool {
        lhs.groups == rhs.groups && lhs.recents.map(\.ref) == rhs.recents.map(\.ref)
    }

    init(choices: [(account: ProviderAccount, models: [ProviderModel])], recents: [String], query: String) {
        let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let words = ModelSearch.words(query)
        groups = choices.compactMap { choice in
            let models = typed ? choice.models.filter { ModelSearch.matches($0, words: words) } : choice.models
            return models.isEmpty ? nil : Group(provider: choice.account.kind, models: models)
        }
        guard !typed else {
            self.recents = []
            return
        }
        self.recents = recents.compactMap { text in
            guard let ref = ModelRef(text),
                  let model = choices.first(where: { $0.account.kind == ref.provider })?.models.first(where: { $0.id == ref.model })
            else { return nil }
            return (text, model.name, ref.provider.label)
        }
    }

    /// What Return in the search field picks: the first model a search brings up, and nothing while nothing is typed (an empty
    /// field lists every model, and its first is not what the person sees selected or asked for).
    func submitted(query: String) -> String? {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : first
    }

    /// The first model of the list.
    var first: String? {
        guard let group = groups.first, let model = group.models.first else { return nil }
        return ModelRef(provider: group.provider, model: model.id).text
    }
}

// MARK: Layout

/// Steps the Orb's side panel aside when the window gets narrow and brings it back when it is wide again, unless
/// you closed it yourself in between. It acts when the window crosses the limit, not on every resize: a panel you
/// open in a narrow window stays open.
struct InspectorAutoClose: Equatable {
    /// Below this window width the chat would be left with less than 600 pt next to the sidebar and the panel.
    static let narrowBelow: CGFloat = 1180
    /// A little more than that to come back, so a window resized around the limit does not make the panel flicker.
    static let wideFrom: CGFloat = 1210

    /// The panel was open and the window got narrow: it is closed until the window is wide again.
    private(set) var closedByWidth = false
    private var isNarrow: Bool?

    /// Whether `width` is on the other side of the limit from the last one told. Read-only, so a caller holding this in
    /// `@State` can ask on every resize without writing the state.
    func crosses(width: CGFloat) -> Bool { narrows(at: width) != isNarrow }

    private func narrows(at width: CGFloat) -> Bool { (isNarrow ?? false) ? width < Self.wideFrom : width < Self.narrowBelow }

    /// The window is now `width` wide and the panel is (`isOpen`) or is not open. Returns what to do to the panel:
    /// true opens it, false closes it, nil leaves it as it is.
    mutating func windowResized(to width: CGFloat, isOpen: Bool) -> Bool? {
        let narrow = narrows(at: width)
        guard narrow != isNarrow else { return nil }
        isNarrow = narrow
        if narrow, isOpen {
            closedByWidth = true
            return false
        }
        if !narrow, closedByWidth {
            closedByWidth = false
            return isOpen ? nil : true
        }
        return nil
    }

    /// You opened or closed the panel yourself: what the window width did before no longer counts.
    mutating func userToggled() { closedByWidth = false }
}
