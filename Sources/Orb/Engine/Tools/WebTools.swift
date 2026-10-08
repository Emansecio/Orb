import Foundation

struct WebFetchTool: AgentTool {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// The most one call returns (`max_chars` can ask for up to this), and what it returns by default. Both stay under
    /// `ToolOutputCap.limit`: longer pages are read in pieces with `offset`, which the note at the end spells out.
    static let maxCharacters = ToolOutputBudget.pageCharacters
    static let defaultCharacters = ToolOutputBudget.webPageDefault
    /// Pages larger than this are cut (keeps memory bounded on huge downloads).
    static let maxBytes = 5_000_000
    /// PDFs are often bigger and cannot be opened when cut (the index sits at the end), so they get more room.
    static let maxPDFBytes = 25_000_000
    /// Largest file `save_to` will download.
    static let maxDownloadBytes = 100_000_000

    let session: URLSession
    /// Bytes read from a PDF response before cutting it; a parameter so tests need not serve 25 MB.
    let pdfLimit: Int

    init(session: URLSession = .shared, pdfLimit: Int = WebFetchTool.maxPDFBytes) {
        self.session = session
        self.pdfLimit = pdfLimit
    }

    let spec = ToolSpec(
        name: "web_fetch",
        description: """
        Fetch a web page over http(s) and return its readable text (scripts and navigation removed, links as \
        "text (url)") with the final URL and title. JSON, XML and plain text come back as is, PDFs as text. One \
        call returns 12,000 characters by default (`max_chars` up to 24,000); a note at the end gives the \
        `offset` to continue. To keep a file (image, archive, PDF…) pass `save_to` instead.
        """,
        parameters: .schema([
            "url": .property("string"),
            "offset": .property("integer", "First character, to continue a long page (default 0)."),
            "max_chars": .property("integer"),
            "save_to": .property("string", "Download to this path instead (up to 100 MB; replaces a file)."),
        ], required: ["url"]))

    var kind: ToolCall.Kind { .browser }
    var capability: Capability? { .browser }
    /// A request can carry data out in its URL, so fetching asks first (unless "Sempre permitir"); saving to a
    /// file also writes to disk. Both stay sensitive.
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let address = arguments["url"]?.string ?? ""
        guard let destination = arguments.nonEmptyString("save_to") else { return ("Lendo página", address) }
        return ("Baixando arquivo", address + "\n→ " + destination)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let address = try arguments.requiredString("url")
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw ToolError("Endereço inválido: use uma URL http:// ou https://.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        // The status is known from the headers alone; do not download an error page's body to find out.
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw ToolError("O site respondeu HTTP \(status).")
        }
        let finalURL = response.url ?? url

        if let destination = arguments.nonEmptyString("save_to") {
            let target = context.url(for: destination)
            let size = try await Self.download(bytes, to: target)
            return "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(response.mimeType ?? "tipo desconhecido")) de \(finalURL.absoluteString) salvos em \(WriteFileTool.location(target, target.resolvingLinkChain))"
        }

        let mimeType = (response.mimeType ?? "").lowercased()
        let limit = mimeType.contains("pdf") ? pdfLimit : Self.maxBytes
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        let cut = data.count >= limit

        var header = "URL: \(finalURL.absoluteString)"
        let text: String
        if mimeType.contains("pdf") || data.starts(with: Array("%PDF".utf8)) {
            do {
                text = try await runDetached { [data] in try DocumentReader.allPDFText(data) }
            } catch let error as ToolError where cut {
                throw ToolError("\(error.message) A resposta passa de \(limit / 1_000_000) MB e foi lida só em parte, o que costuma impedir a abertura de um PDF. Baixe com save_to e leia com read_file (use pages para escolher as páginas).")
            }
        } else if mimeType.contains("html") {
            let charset = response.textEncodingName
            let page = try await runDetached { [data] in
                HTMLText.convert(WebText.decode(data, headerCharset: charset, sniffMeta: true), baseURL: finalURL)
            }
            if let title = page.title, !title.isEmpty { header += "\nTítulo: \(title)" }
            text = page.text
        } else if mimeType.hasPrefix("text/") || mimeType.contains("json") || mimeType.contains("xml") || mimeType.contains("javascript") {
            text = WebText.decode(data, headerCharset: response.textEncodingName, sniffMeta: mimeType.contains("xml"))
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return header + "\nConteúdo \(mimeType.isEmpty ? "de tipo desconhecido" : mimeType) de \(cut ? "mais de " : "")\(bytes) (não é texto). Use save_to para baixá-lo."
        }
        return header + "\n\n" + Self.page(of: text, arguments: arguments, truncatedDownload: cut ? limit : nil)
    }

    /// `max_chars` characters from `offset`, with a note on where to continue.
    static func page(of text: String, arguments: JSONValue, truncatedDownload: Int?) -> String {
        let total = text.count
        let offset = arguments.integer("offset", default: 0, in: 0...Int.max)
        let length = arguments.integer("max_chars", default: defaultCharacters, in: 1...maxCharacters)
        if total == 0 { return "(sem texto)" }
        guard offset < total else { return "O texto tem só \(total) caracteres; offset=\(offset) está além do fim." }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(length, total - offset))
        var result = String(text[start..<end])
        if offset > 0 || end < text.endIndex {
            result = "[caracteres \(offset + 1)–\(offset + result.count) de \(total)]\n" + result
        }
        if end < text.endIndex {
            result += "\n[... mais \(total - offset - length) caracteres; use offset=\(offset + length) para continuar ...]"
        } else if let limit = truncatedDownload {
            result += "\n[... a resposta passa de \(limit / 1_000_000) MB; o resto não foi lido ...]"
        }
        return result
    }

    /// Streams the body to a temporary file next to `target` and moves it into place, so a failed or oversized
    /// download never leaves a half-written file behind. Returns the size in bytes.
    private static func download(_ bytes: URLSession.AsyncBytes, to target: URL) async throws -> Int {
        let destination = target.resolvingLinkChain
        guard !destination.isExistingDirectory else { throw ToolError("\(destination.path) é uma pasta; informe o nome do arquivo em save_to.") }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appending(path: ".orb-download-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw ToolError("Não consegui gravar em \(destination.path).") }
        var completed = false
        defer { if !completed { try? manager.removeItem(at: temporary) } }

        let handle = try FileHandle(forWritingTo: temporary)
        var buffer = Data()
        var total = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    total += buffer.count
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if total + buffer.count > maxDownloadBytes {
                    throw ToolError("O arquivo passa de \(maxDownloadBytes / 1_000_000) MB; baixe com run_command (curl -L -o).")
                }
            }
            total += buffer.count
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        completed = true
        return total
    }
}

/// Decodes response bodies the way browsers do: byte-order mark, then the HTTP charset, then (for markup) a
/// `<meta charset>`, then strict UTF-8, and Windows-1252 as the last resort.
enum WebText {
    static func decode(_ data: Data, headerCharset: String?, sniffMeta: Bool) -> String {
        let marks: [[UInt8]] = [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]]
        if marks.contains(where: { data.starts(with: $0) }), let file = TextFile.decode(data) { return file.text }
        if let charset = headerCharset, let text = string(data, charset: charset) { return text }
        if sniffMeta, let charset = metaCharset(in: data.prefix(4096)), let text = string(data, charset: charset) { return text }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private static func string(_ data: Data, charset: String) -> String? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }

    private static let metaCharsetRegex = try! NSRegularExpression(pattern: #"<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_.:\-]+)"#, options: .caseInsensitive)

    /// The tag is ASCII in every encoding in use, so reading the head as Latin-1 finds it.
    private static func metaCharset(in head: Data) -> String? {
        guard let text = String(data: head, encoding: .isoLatin1),
              let match = metaCharsetRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Turns HTML into readable plain text with regular expressions (no WebKit).
enum HTMLText {
    /// Links appear as "text (url)", relative ones resolved against `baseURL`.
    static func convert(_ html: String, baseURL: URL? = nil) -> (title: String?, text: String) {
        let title = firstGroup(titleRegex, in: html).map { collapseWhitespace(decodeEntities($0)) }
        var text = html
        for rule in cleanupRules { text = rule.apply(to: text) }
        text = inlineLinks(text, baseURL: baseURL)
        for rule in layoutRules { text = rule.apply(to: text) }
        return (title, collapseWhitespace(decodeEntities(text)))
    }

    /// A regular expression and its replacement template, compiled once (pages are converted often).
    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // Static, known-valid patterns.
            regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            self.template = template
        }

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }

    private static let titleRegex = try! NSRegularExpression(pattern: #"<title\b[^>]*>([\s\S]*?)</title\s*>"#, options: .caseInsensitive)
    private static let linkRegex = try! NSRegularExpression(pattern: #"<a\b([^>]*)>([\s\S]*?)</a\s*>"#, options: .caseInsensitive)
    private static let hrefRegex = try! NSRegularExpression(pattern: #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: .caseInsensitive)
    private static let tagRegex = try! NSRegularExpression(pattern: #"<[^>]*>"#)
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")

    /// Applied before links are read: whatever is dropped here must not leak its links into the text.
    private static let cleanupRules = [
        Rule(#"<!--[\s\S]*?-->"#, ""),
        Rule(#"<(script|style|nav|noscript|svg|template|iframe|head)\b[^>]*>[\s\S]*?</\1\s*>"#, ""),
    ]

    /// Applied after links are rewritten; link text survives because only the tags are removed.
    private static let layoutRules = [
        Rule(#"<li\b[^>]*>"#, "\n• "),
        Rule(#"</?(?:p|div|h[1-6]|ul|ol|li|tr|table|section|article|header|footer|main|aside|blockquote|pre|form|dl|dt|dd|figure|figcaption|br|hr)\b[^>]*>"#, "\n"),
        Rule(#"</?t[dh]\b[^>]*>"#, " "),
        Rule(#"<[^>]*>"#, ""),
    ]

    /// `<a href="u">text</a>` becomes `text (u)`; fragments, `javascript:` links, links without text (icons)
    /// and links whose text already is the address stay as they were.
    private static func inlineLinks(_ html: String, baseURL: URL?) -> String {
        let result = NSMutableString(string: html)
        let source = html as NSString
        for match in linkRegex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let attributes = source.substring(with: match.range(at: 1))
            let inner = source.substring(with: match.range(at: 2))
            guard let target = linkTarget(attributes, baseURL: baseURL) else { continue }
            let label = collapseWhitespace(decodeEntities(tagRegex.stringByReplacingMatches(
                in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")))
            guard !label.isEmpty, label != target, label + "/" != target, label != target + "/" else { continue }
            result.replaceCharacters(in: match.range, with: inner + " (\(target))")
        }
        return result as String
    }

    private static func linkTarget(_ attributes: String, baseURL: URL?) -> String? {
        guard let match = hrefRegex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) else { return nil }
        let raw = (1...3).lazy.compactMap { Range(match.range(at: $0), in: attributes).map { String(attributes[$0]) } }.first ?? ""
        let href = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = href.lowercased()
        guard !href.isEmpty, !href.hasPrefix("#"), !lowered.hasPrefix("javascript:"), !lowered.hasPrefix("data:") else { return nil }
        return URL(string: href, relativeTo: baseURL)?.absoluteString ?? href
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        let result = NSMutableString(string: text)
        // Back to front so earlier ranges stay valid.
        for match in entityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            if let character = entity(result.substring(with: match.range(at: 1))) {
                result.replaceCharacters(in: match.range, with: character)
            }
        }
        return (result as String).precomposedStringWithCanonicalMapping
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "ordm": "º", "ordf": "ª",
    ]

    /// Accented Latin letters such as `&atilde;` and `&ccedil;`, built from a base letter and a combining mark.
    private static let accents: [String: String] = [
        "acute": "\u{301}", "grave": "\u{300}", "circ": "\u{302}", "tilde": "\u{303}", "uml": "\u{308}",
        "cedil": "\u{327}", "ring": "\u{30A}",
    ]

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if let value = namedEntities[name] { return value }
        guard let letter = name.first, letter.isLetter, let mark = accents[String(name.dropFirst())] else { return nil }
        return String(letter) + mark
    }

    /// Collapses runs of spaces, trims lines and keeps at most one blank line in a row.
    private static func collapseWhitespace(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty || lines.last?.isEmpty == false { lines.append(words) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ToolBox {
    static let webTools: [any AgentTool] = [WebFetchTool()]
}
