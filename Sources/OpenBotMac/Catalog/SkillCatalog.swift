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

    private let session: URLSession
    private var documents: [String: SkillDocument] = [:]

    init(session: URLSession = .shared) { self.session = session }

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
        let path = try await locate(skill)
        guard let text = String(data: try await fetch(Self.raw.appending(path: "\(skill.repo)/HEAD/\(path)")), encoding: .utf8) else {
            throw CatalogError.unreadable(skill.name)
        }
        let parsed = Self.parse(text)
        let folder = (path as NSString).deletingLastPathComponent
        let document = SkillDocument(
            name: parsed.fields["name"] ?? skill.name,
            description: parsed.fields["description"] ?? "",
            instructions: parsed.body,
            folderURL: Self.github.appending(path: "\(skill.repo)/tree/HEAD/\(folder)")
        )
        documents[skill.id] = document
        return document
    }

    /// Path of the SKILL.md inside the repo: common layouts first, then the repository tree.
    private func locate(_ skill: CatalogSkill) async throws -> String {
        let id = skill.skillId
        for path in ["skills/\(id)/SKILL.md", "\(id)/SKILL.md", "skills/.curated/\(id)/SKILL.md", ".claude/skills/\(id)/SKILL.md"] {
            if (try? await fetch(Self.raw.appending(path: "\(skill.repo)/HEAD/\(path)"), method: "HEAD")) != nil {
                return path
            }
        }
        guard let treeURL = URL(string: "https://api.github.com/repos/\(skill.repo)/git/trees/HEAD?recursive=1") else {
            throw CatalogError.unreadable(skill.name)
        }
        let paths = (try await fetchJSON(treeURL)["tree"]?.array ?? []).compactMap { $0["path"]?.string }
        if let match = paths.first(where: { $0.hasSuffix("/\(id)/SKILL.md") }) ?? paths.first(where: { $0 == "SKILL.md" }) {
            return match
        }
        throw CatalogError.unreadable(skill.name)
    }

    // MARK: Network

    private func fetch(_ url: URL, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

    var errorDescription: String? {
        switch self {
        case .http(let status) where status == 403: "O catálogo limitou as consultas por agora. Tente de novo em alguns minutos."
        case .http(let status): "O catálogo respondeu HTTP \(status)."
        case .invalidResponse: "O catálogo devolveu uma resposta inesperada."
        case .unreadable(let name): "Não encontrei o SKILL.md de “\(name)” no GitHub."
        }
    }
}
