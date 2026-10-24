import Foundation

/// A skill listed by the Skills.sh index (the content itself lives in a GitHub repository).
struct CatalogSkill: Identifiable, Hashable, Sendable {
    /// "owner/repo/skillId"
    let id: String
    let repo: String
    let skillId: String
    let name: String
    let installs: Int

    /// Publishers whose skills are maintained by a known organization.
    var isFromKnownSource: Bool {
        let owner = repo.split(separator: "/").first.map(String.init) ?? ""
        return ["anthropics", "openai", "github", "vercel-labs", "microsoft", "google", "huggingface", "cloudflare", "stripe"]
            .contains(owner.lowercased())
    }
}

/// The SKILL.md of a catalog skill, split into its frontmatter and instructions.
struct SkillDocument: Hashable, Sendable {
    let name: String
    let description: String
    let instructions: String
    /// GitHub folder with the skill (instructions may reference other files there).
    let folderURL: URL
}

/// Searches the public Skills.sh index and reads SKILL.md files (open Agent Skills format) from GitHub.
actor SkillCatalog {
    static let shared = SkillCatalog()

    // Literal URLs, always valid.
    private static let github = URL(string: "https://github.com")!
    private static let raw = URL(string: "https://raw.githubusercontent.com")!

    /// One request: the body and the HTTP status. Tests hand in their own.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    private let send: Fetch
    private var documents: [String: SkillDocument] = [:]
    /// Each repository's SKILL.md files, listed once (several cards of a search often come from the same repository,
    /// and GitHub allows few listings an hour without an account).
    private var trees: [String: Task<[String], Error>] = [:]
    /// The SKILL.md files already read, by "owner/repo/path": a search reads the same ones for several cards.
    private var files: [String: Task<(text: String?, answered: Bool), Never>] = [:]

    /// Ceilings for the three caches above (the actor lives as long as the session): the oldest entry goes first.
    private static let capacity = (documents: 100, trees: 20, files: 100)
    private var documentOrder: [String] = []
    private var treeOrder: [String] = []
    private var fileOrder: [String] = []

    private static func remember<V>(_ key: String, _ value: V, in cache: inout [String: V], order: inout [String], capacity: Int) {
        if cache.updateValue(value, forKey: key) == nil {
            order.removeAll { $0 == key } // a key dropped by hand is not counted twice
            order.append(key)
        }
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }

    init(session: URLSession = .shared) {
        send = { request in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    init(fetch: @escaping Fetch) { send = fetch }

    /// Up to `limit` skills matching `query` (at least 2 characters), most installed first.
    func search(_ query: String, limit: Int = 40) async throws -> [CatalogSkill] {
        var components = URLComponents(string: "https://skills.sh/api/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return [] }
        let json = try await fetchJSON(url)
        let skills = (json["skills"]?.array ?? []).compactMap { item -> CatalogSkill? in
            guard let id = item["id"]?.string, let repo = item["source"]?.string, let skillId = item["skillId"]?.string,
                  repo.split(separator: "/").count == 2 else { return nil }
            return CatalogSkill(id: id, repo: repo, skillId: skillId, name: item["name"]?.string ?? skillId,
                                installs: item["installs"]?.int ?? 0)
        }
        return Array(skills.sorted { $0.installs > $1.installs }.prefix(limit))
    }

    /// The skill's SKILL.md (cached).
    func document(for skill: CatalogSkill) async throws -> SkillDocument {
        if let cached = documents[skill.id] { return cached }
        let (path, text) = try await locate(skill)
        let parsed = Self.parse(text)
        let folder = (path as NSString).deletingLastPathComponent
        let document = SkillDocument(
            name: parsed.fields["name"] ?? skill.name,
            description: parsed.fields["description"] ?? "",
            instructions: parsed.body,
            folderURL: Self.github.appending(path: "\(skill.repo)/tree/HEAD/\(folder)")
        )
        Self.remember(skill.id, document, in: &documents, order: &documentOrder, capacity: Self.capacity.documents)
        return document
    }

    /// The SKILL.md of `skill` and its path in the repository. The index names a skill by the `name` its SKILL.md
    /// declares, and the folder is often called something else ("design-taste-frontend" lives in
    /// `skills/taste-skill/`): the common layouts first, then the repository's SKILL.md files, by folder and then by
    /// the name inside.
    private func locate(_ skill: CatalogSkill) async throws -> (path: String, text: String) {
        let id = skill.skillId
        for path in ["skills/\(id)/SKILL.md", "\(id)/SKILL.md", "skills/.curated/\(id)/SKILL.md", ".claude/skills/\(id)/SKILL.md"] {
            if let text = await file(skill.repo, path) { return (path, text) }
        }
        let paths = try await skillFiles(in: skill.repo)
        // A plugin's skill comes as "plugin::skill" ("stitch::extract-design-md"); its folder has the skill's own name.
        let bare = id.components(separatedBy: "::").last ?? id
        if let path = paths.first(where: { $0.hasSuffix("/\(id)/SKILL.md") || $0.hasSuffix("/\(bare)/SKILL.md") }),
           let text = await file(skill.repo, path) {
            return (path, text)
        }
        // By the name inside, read together (raw files are not limited like the listing), the repository's own copy before
        // the ones other tools keep in dot-folders.
        let candidates = Array(paths.sorted { Self.isMirror($0) == Self.isMirror($1) ? $0 < $1 : !Self.isMirror($0) }
            .prefix(Self.maxNameLookups))
        let texts = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, path) in candidates.enumerated() { group.addTask { (index, await self.file(skill.repo, path)) } }
            var texts = [String?](repeating: nil, count: candidates.count)
            for await (index, text) in group { texts[index] = text }
            return texts
        }
        for (path, text) in zip(candidates, texts) {
            if let text, let name = Self.parse(text).fields["name"],
               name.caseInsensitiveCompare(id) == .orderedSame || name.caseInsensitiveCompare(bare) == .orderedSame { return (path, text) }
        }
        if paths == ["SKILL.md"], let text = texts.first ?? nil { return ("SKILL.md", text) }
        throw CatalogError.missing(skill.name)
    }

    /// SKILL.md files whose name is looked at, at most: a repository of hundreds of skills is not read whole for one card.
    static let maxNameLookups = 60

    /// A copy of a skill kept for another tool (`.cursor/skills/…`, `.gemini/skills/…`).
    private static func isMirror(_ path: String) -> Bool { path.hasPrefix(".") }

    /// The SKILL.md files of `repo`, listed once.
    private func skillFiles(in repo: String) async throws -> [String] {
        if let listing = trees[repo] { return try await listing.value }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/HEAD?recursive=1") else { return [] }
        let listing = Task { [self] in
            (try await fetchJSON(url)["tree"]?.array ?? []).compactMap { $0["path"]?.string }
                .filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }
        }
        Self.remember(repo, listing, in: &trees, order: &treeOrder, capacity: Self.capacity.trees)
        do {
            return try await listing.value
        } catch {
            trees[repo] = nil // a refusal (the hourly limit) is tried again on the next search
            throw error
        }
    }

    /// A file of `repo` at HEAD, or nil when it is not there. Only an answer is kept (the file, or a 404): a timeout, a 5xx, a refusal
    /// or no network is tried again by the next call, not remembered as "not there" until the app restarts.
    private func file(_ repo: String, _ path: String) async -> String? {
        let key = "\(repo)/\(path)"
        if let reading = files[key] { return await reading.value.text }
        let url = Self.raw.appending(path: "\(repo)/HEAD/\(path)")
        let reading = Task { [self] () -> (text: String?, answered: Bool) in
            do {
                return (String(data: try await fetch(url), encoding: .utf8), true)
            } catch CatalogError.http(404) {
                return (nil, true)
            } catch {
                return (nil, false)
            }
        }
        Self.remember(key, reading, in: &files, order: &fileOrder, capacity: Self.capacity.files)
        let result = await reading.value
        if !result.answered, files[key] == reading { files[key] = nil }
        return result.text
    }

    // MARK: Network

    private func fetch(_ url: URL) async throws -> Data {
        let (data, status) = try await send(URLRequest(url: url, timeoutInterval: 20))
        guard (200..<300).contains(status) else { throw CatalogError.http(status) }
        return data
    }

    private func fetchJSON(_ url: URL) async throws -> JSONValue {
        guard let json = JSONValue.parse(String(decoding: try await fetch(url), as: UTF8.self)) else {
            throw CatalogError.invalidResponse
        }
        return json
    }

    // MARK: Parsing

    /// Splits YAML frontmatter (`---` … `---`) from the Markdown body. Handles `key: value`, quoted values and
    /// folded/literal blocks (`>` / `|`) — enough for SKILL.md's flat fields.
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let current = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let piece = line.trimmingCharacters(in: .whitespaces)
                fields[current] = [fields[current] ?? "", piece].filter { !$0.isEmpty }.joined(separator: " ")
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { key = nil; continue }
            key = parts[0]
            var value = parts[1]
            if [">", "|", ">-", "|-"].contains(value) { value = "" }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            fields[parts[0]] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }
}

enum CatalogError: LocalizedError {
    case http(Int)
    case invalidResponse
    case unreadable(String)
    /// The index still lists it, but its repository no longer has it (renamed or removed).
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .http(let status) where status == 403: "O catálogo limitou as consultas por agora. Tente de novo em alguns minutos."
        case .http(let status): "O catálogo respondeu HTTP \(status)."
        case .invalidResponse: "O catálogo devolveu uma resposta inesperada."
        case .unreadable(let name): "Não encontrei o SKILL.md de “\(name)” no GitHub."
        case .missing(let name): "“\(name)” não está mais no repositório: foi renomeada ou removida. Procure pelo nome novo."
        }
    }
}

extension CatalogError {
    /// What the preview says when the SKILL.md did not come: the catalog's own sentences (already in Portuguese), and a
    /// plain one for a network failure, whose system text is neither.
    static func previewText(for error: Error) -> String {
        error is URLError ? "Sem conexão com o catálogo." : error.localizedDescription
    }

    /// What a skill's card says when its SKILL.md is not there: the short form of the reason.
    static func cardText(for error: Error) -> String {
        switch error as? CatalogError {
        case .missing?: "Não está mais no repositório (renomeada ou removida)."
        case .http(403)?: "O GitHub limitou as consultas; abra para tentar de novo."
        default: "Descrição indisponível; abra para tentar de novo."
        }
    }
}
