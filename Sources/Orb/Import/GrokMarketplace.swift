import Foundation

// "Importar de outro assistente → Link do marketplace": a bot of the Grok Bot marketplace (x.ai/bot/marketplace), read
// from its public page and turned into an `OrbImport`, so it goes through the same preview and checkboxes as any import.
// The page is a Next.js page: the bot comes as JSON inside the page's `self.__next_f.push([1,"…"])` scripts. The
// marketplace's list holds every bot's card but not its contents (the panel's gallery is made of those cards); a bot's own
// page holds the contents.

/// One bot as the marketplace page describes it. Every field is optional: what is missing is left out.
struct MarketplaceBot: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        var name = ""
        var description = ""
        var content = ""

        private enum CodingKeys: String, CodingKey { case name, description, content }
    }

    var id = ""
    var name = ""
    var creatorName = ""
    var description = ""
    var summary = ""
    var addHref = ""
    /// The marketplace's own categories, in English ("Marketing", "From Grok Bot Team"): see `GrokMarketplace.categoryLabel`.
    var categories: [String] = []
    /// The color of its card ("green", "violet"…).
    var color = ""
    var instructions = ""
    var memories: [Entry] = []
    var skills: [Entry] = []
    var routines: [Entry] = []
    var integrations: [Entry] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, creatorName, description, summary, addHref, categories, color, instructions, memories, skills, routines, integrations
    }
}

extension MarketplaceBot {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? values.decode(String.self, forKey: key)) ?? "" }
        func list(_ key: CodingKeys) -> [Entry] { (try? values.decode([Entry].self, forKey: key)) ?? [] }
        id = text(.id)
        name = text(.name)
        creatorName = text(.creatorName)
        description = text(.description)
        summary = text(.summary)
        addHref = text(.addHref)
        categories = ((try? values.decode([String?].self, forKey: .categories)) ?? []).compactMap { $0 }.filter { !$0.isEmpty }
        color = text(.color)
        instructions = text(.instructions)
        memories = list(.memories)
        skills = list(.skills)
        routines = list(.routines)
        integrations = list(.integrations)
    }
}

extension MarketplaceBot.Entry {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        description = (try? values.decode(String.self, forKey: .description)) ?? ""
        content = (try? values.decode(String.self, forKey: .content)) ?? ""
    }
}

/// Why a marketplace link could not be read, in the words the panel shows.
enum MarketplaceFailure: Error, Equatable, LocalizedError, Sendable {
    case notALink, offline, blocked, notFound, unreadable

    var errorDescription: String? {
        switch self {
        case .notALink: "Isto não é o link de um bot do marketplace do Grok Bot. Abra o bot em x.ai/bot/marketplace e copie o endereço da página."
        case .offline: "Não consegui abrir o marketplace. Confira a internet e tente de novo."
        case .blocked: "O site do marketplace não respondeu agora. Tente de novo em instantes."
        case .notFound: "Não achei este bot no marketplace. Ele pode ter saído de lá."
        case .unreadable: "A página do bot mudou de formato e não consegui ler. Avise para atualizarmos o Orb."
        }
    }
}

enum GrokMarketplace {
    static let home = URL(string: "https://x.ai/bot/marketplace")!

    /// What a link names: the bot's page (`/bot/marketplace/bots/<slug>`) or its "Add" link (`/bot/<id>`, also the
    /// `grokbot://app/v1/bot-template?id=<id>` the "Add to Grok Bot" button opens).
    enum Link: Equatable, Sendable {
        case page(String)
        case share(String)

        var url: URL {
            switch self {
            case .page(let slug): URL(string: "https://x.ai/bot/marketplace/bots/\(slug)")!
            case .share(let id): URL(string: "https://x.ai/bot/\(id)")!
            }
        }
    }

    private static let token = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{1,80}$"#)

    private static func isToken(_ text: String) -> Bool {
        token.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The link in what was pasted (the first address in it), or nil when it is not a marketplace bot.
    static func link(in pasted: String) -> Link? {
        let words = pasted.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" })
        guard let word = words.first(where: { $0.contains("x.ai/") || $0.hasPrefix("grokbot:") }) else { return nil }
        var text = String(word)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text) else { return nil }
        if parts.scheme == "grokbot" {
            guard let id = parts.queryItems?.first(where: { $0.name == "id" })?.value, isToken(id) else { return nil }
            return .share(id)
        }
        guard ["https", "http"].contains(parts.scheme ?? ""), ["x.ai", "www.x.ai"].contains(parts.host?.lowercased() ?? "") else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard path.first == "bot" else { return nil }
        if path.count == 4, path[1] == "marketplace", path[2] == "bots", isToken(path[3]) { return .page(path[3]) }
        if path.count == 2, path[1] != "marketplace", isToken(path[1]) { return .share(path[1]) }
        return nil
    }

    // MARK: Reading

    /// Fetches a page. Injected by the tests; the app uses `URLSession`.
    typealias Fetch = @Sendable (URL) async throws -> String

    static let fetchPage: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw MarketplaceFailure.offline
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404, 410: throw MarketplaceFailure.notFound
        default: throw MarketplaceFailure.blocked
        }
        guard data.count <= 8_000_000, let html = String(data: data, encoding: .utf8) else { throw MarketplaceFailure.unreadable }
        return html
    }

    /// The bot a link names, read from the marketplace. An "Add" link is looked up in the marketplace's list first.
    static func bot(_ link: Link, fetch: Fetch = fetchPage) async throws -> MarketplaceBot {
        let slug: String
        switch link {
        case .page(let page): slug = page
        case .share(let id):
            let listed = bots(inPage: try await fetch(home))
            guard !listed.isEmpty else { throw MarketplaceFailure.unreadable }
            guard let found = listed.first(where: { $0.addHref == "/bot/\(id)" }), !found.id.isEmpty else { throw MarketplaceFailure.notFound }
            slug = found.id
        }
        let html = try await fetch(Link.page(slug).url)
        let found = bots(inPage: html)
        guard let bot = found.first(where: { $0.id == slug }) else {
            throw found.isEmpty && !html.contains("__next_f") ? MarketplaceFailure.notFound : MarketplaceFailure.unreadable
        }
        return bot
    }

    /// Every bot described in a marketplace page (the objects with a creator and skills), in the order they come.
    static func bots(inPage html: String) -> [MarketplaceBot] {
        let payload = Array(pagePayload(html).utf8)
        let opening = Array(#"{"id":""#.utf8)
        var found: [MarketplaceBot] = [], seen = Set<String>()
        var index = 0
        while index + opening.count <= payload.count {
            guard payload[index] == opening[0], Array(payload[index..<index + opening.count]) == opening,
                  let end = closingBrace(payload, from: index) else {
                index += 1
                continue
            }
            let data = Data(payload[index...end])
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["creatorName"] != nil, object["skills"] != nil,
               let bot = try? JSONDecoder().decode(MarketplaceBot.self, from: data), !seen.contains(bot.id) {
                seen.insert(bot.id)
                found.append(bot)
                index = end + 1
            } else {
                index += 1
            }
        }
        return found
    }

    private static let chunk = try! NSRegularExpression(pattern: #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#)

    /// The page's data: the strings of its `self.__next_f.push([1,"…"])` scripts, unescaped and joined.
    static func pagePayload(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        return chunk.matches(in: html, range: range).compactMap { match -> String? in
            guard let inner = Range(match.range(at: 1), in: html),
                  let data = "\"\(html[inner])\"".data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(String.self, from: data)
        }.joined()
    }

    /// Where the JSON object that opens at `start` closes (strings and escapes respected), or nil when it does not.
    private static func closingBrace(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    // MARK: The gallery

    /// Every bot of the marketplace's list, as its cards describe them (no contents: those come from the bot's page).
    /// Kept for a while, so going back and forth between the tabs does not fetch the list again.
    static func catalog(fetch: Fetch = fetchPage, now: Date = .now) async throws -> [MarketplaceBot] {
        if let kept = await CatalogCache.shared.bots(at: now) { return kept }
        let bots = Self.bots(inPage: try await fetch(home)).filter { !$0.id.isEmpty && isToken($0.id) && !$0.name.isEmpty }
        guard !bots.isEmpty else { throw MarketplaceFailure.unreadable }
        await CatalogCache.shared.keep(bots, at: now)
        return bots
    }

    /// The list a few minutes old at most.
    actor CatalogCache {
        static let shared = CatalogCache()
        static let lifetime: TimeInterval = 15 * 60
        private var kept: (bots: [MarketplaceBot], at: Date)?

        func bots(at now: Date) -> [MarketplaceBot]? {
            guard let kept, now >= kept.at, now.timeIntervalSince(kept.at) < Self.lifetime else { return nil }
            return kept.bots
        }

        func keep(_ bots: [MarketplaceBot], at now: Date) { kept = (bots, now) }
        func clear() { kept = nil }
    }

    /// The categories the bots are in, the fullest first (ties in alphabetical order).
    static func categories(in bots: [MarketplaceBot]) -> [String] {
        var counts: [String: Int] = [:]
        for bot in bots { for category in Set(bot.categories) { counts[category, default: 0] += 1 } }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }

    /// A category in the app's words; one it does not know keeps the marketplace's.
    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "From Grok Bot Team": "Do time do Grok Bot"
        case "Sales": "Vendas"
        case "Personal": "Pessoal"
        case "Engineering": "Engenharia"
        case "Product": "Produto"
        case "Operations": "Operações"
        case "Recruiting & People": "Recrutamento e pessoas"
        case "Support", "Customer Support": "Atendimento"
        case "Finance": "Finanças"
        case "Research": "Pesquisa"
        case "Education": "Educação"
        default: category
        }
    }

    /// The bots in `category` (nil: all) whose name, summary, description or creator has every word typed (accents and
    /// case aside), in the list's order; a name that starts with the first word comes first.
    static func filter(_ bots: [MarketplaceBot], query: String, category: String?) -> [MarketplaceBot] {
        let words = MemoryText.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let inCategory = category.map { wanted in bots.filter { $0.categories.contains(wanted) } } ?? bots
        guard !words.isEmpty else { return inCategory }
        let matching = inCategory.filter { bot in
            let text = MemoryText.fold([bot.name, bot.summary, bot.description, bot.creatorName].joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
        let first = words[0]
        var starts: [MarketplaceBot] = [], others: [MarketplaceBot] = []
        for bot in matching { if MemoryText.fold(bot.name).hasPrefix(first) { starts.append(bot) } else { others.append(bot) } }
        return starts + others
    }

    // MARK: Into the import

    private static let genericMemoryName = try! NSRegularExpression(pattern: #"^\s*memory\s*\d*\s*$"#, options: .caseInsensitive)

    /// The bot as an import: its instructions (or, without them, its description) are the identity, its memories are
    /// facts, its skills are skills; its routines become procedures to read (no routine is created by an import) and its
    /// integrations one fact saying what it used. The last fact says where it came from.
    static func orbImport(_ bot: MarketplaceBot, link: Link) throws -> OrbImport {
        let name = ImportSanitizer.line(bot.name, limit: 40)
        var found = OrbImport(source: name.isEmpty ? "Grok Bot" : "\(name) (Grok Bot)")
        found.name = name
        found.role = ImportSanitizer.line(bot.summary.isEmpty ? bot.description : bot.summary, limit: 120)
        found.link = link.url.absoluteString
        found.identity = OrbImportReader.identity(from: bot.instructions.isEmpty ? bot.description : bot.instructions)
        found.facts = bot.memories.prefix(ImportLimits.listed).compactMap { memory in
            let text = ImportSanitizer.block(memory.description.isEmpty ? memory.content : memory.description, limit: MemoryBank.maximumLength)
            guard !text.isEmpty else { return nil }
            let title = genericMemoryName.firstMatch(in: memory.name, range: NSRange(memory.name.startIndex..., in: memory.name)) == nil
                ? ImportSanitizer.line(memory.name, limit: 80) : ""
            return ImportItem(text, title: title)
        }
        let integrations = bot.integrations.map { entry in
            [entry.name, entry.description].map { ImportSanitizer.line($0, limit: 160) }.filter { !$0.isEmpty }.joined(separator: ": ")
        }.filter { !$0.isEmpty }
        if !integrations.isEmpty {
            found.facts.append(ImportItem("O bot original usava estas integrações (conecte as equivalentes em Conectores, se quiser): "
                                          + integrations.joined(separator: "; ") + ".", title: "Integrações do bot original"))
        }
        found.procedures = bot.routines.prefix(ImportLimits.procedures).compactMap { routine in
            let text = ImportSanitizer.block([routine.description, routine.content].filter { !$0.isEmpty }.joined(separator: "\n"),
                                             limit: MemoryBank.maximumLength)
            guard !text.isEmpty else { return nil }
            return ImportItem(text, title: "Rotina do bot original: " + ImportSanitizer.line(routine.name, limit: 80))
        }
        found.skills = OrbImportReader.limitSkills(bot.skills.compactMap { skill in
            OrbImportReader.skill(title: skill.name, summary: skill.description,
                                  body: skill.content.isEmpty ? skill.description : skill.content)
        })
        guard !found.isEmpty else { throw MarketplaceFailure.unreadable }
        let credit = bot.creatorName.isEmpty ? "" : ", de \(ImportSanitizer.line(bot.creatorName, limit: 80))"
        let origin = ImportItem("Este Orb veio do bot \(name.isEmpty ? "sem nome" : name)\(credit), do marketplace do Grok Bot: \(link.url.absoluteString)",
                                title: "Origem")
        found.facts = Array(found.facts.prefix(ImportLimits.listed - 1)) + [origin]
        return found
    }

    /// Reads the link all the way to the preview. The import keeps the bot's own page (an "Add" link becomes it).
    static func read(_ link: Link, fetch: Fetch = fetchPage) async throws -> OrbImport {
        let bot = try await bot(link, fetch: fetch)
        return try orbImport(bot, link: bot.id.isEmpty ? link : .page(bot.id))
    }
}
