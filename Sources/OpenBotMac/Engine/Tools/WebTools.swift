import Foundation

struct WebFetchTool: AgentTool {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let spec = ToolSpec(
        name: "web_fetch",
        description: """
        Fetch a web page over http(s) and return its readable text (scripts, styles and navigation removed) \
        with the final URL and title. Long pages are truncated.
        """,
        parameters: .schema([
            "url": .property("string", "Full http:// or https:// URL."),
        ], required: ["url"]))

    var kind: ToolCall.Kind { .browser }
    var capability: Capability? { .browser }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Lendo página", arguments["url"]?.string ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        let address = try arguments.requiredString("url")
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw ToolError("Endereço inválido: use uma URL http:// ou https://.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw ToolError("O site respondeu HTTP \(status).")
        }

        var header = "URL: \((response.url ?? url).absoluteString)"
        let mimeType = response.mimeType ?? ""
        let body = Self.decode(data, charset: response.textEncodingName)
        let text: String
        if mimeType.contains("html") {
            let page = HTMLText.convert(body)
            if let title = page.title, !title.isEmpty { header += "\nTítulo: \(title)" }
            text = page.text
        } else if mimeType.hasPrefix("text/") || mimeType.contains("json") || mimeType.contains("xml") {
            text = body
        } else {
            return header + "\nConteúdo \(mimeType) de \(data.count) bytes (não é texto)."
        }
        return header + "\n\n" + text.truncated(to: 30_000)
    }

    private static func decode(_ data: Data, charset: String?) -> String {
        if let charset {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Turns HTML into readable plain text with regular expressions (no WebKit).
enum HTMLText {
    static func convert(_ html: String) -> (title: String?, text: String) {
        let title = firstGroup(#"<title\b[^>]*>([\s\S]*?)</title\s*>"#, in: html).map { collapseWhitespace(decodeEntities($0)) }
        var text = html
        for (pattern, template) in rules {
            text = replace(pattern, in: text, with: template)
        }
        return (title, collapseWhitespace(decodeEntities(text)))
    }

    /// Applied in order; link text survives because only the tags are removed.
    private static let rules: [(String, String)] = [
        (#"<!--[\s\S]*?-->"#, ""),
        (#"<(script|style|nav|noscript|svg|template|iframe|head)\b[^>]*>[\s\S]*?</\1\s*>"#, ""),
        (#"<li\b[^>]*>"#, "\n• "),
        (#"</?(?:p|div|h[1-6]|ul|ol|li|tr|table|section|article|header|footer|main|aside|blockquote|pre|form|dl|dt|dd|figure|figcaption|br|hr)\b[^>]*>"#, "\n"),
        (#"</?t[dh]\b[^>]*>"#, " "),
        (#"<[^>]*>"#, ""),
    ]

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")
        let result = NSMutableString(string: text)
        // Back to front so earlier ranges stay valid.
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
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
