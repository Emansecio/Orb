import Foundation

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

/// Turns HTML into readable text with regular expressions (no WebKit): a light Markdown with `#` headings, code
/// blocks fenced and untouched, tables as `| a | b |` rows and links as "text (url)", from the page's main content
/// only (menus, language lists, footers, hidden elements and sidebars are left out).
enum HTMLText {
    struct Page {
        var title: String?
        var text: String
        /// Some links are written as "(/path)": they point inside the page's own site.
        var hasSiteLinks = false
        /// Almost no text but scripts: the page builds its content in the browser, or asks for a bot check first.
        var needsJavaScript = false
    }

    /// What `web_fetch` adds when a page came back nearly empty because it needs JavaScript.
    static let javaScriptNote = """
    [Nota: esta página monta o conteúdo com JavaScript (ou exige um teste anti-robô) e web_fetch não executa scripts. \
    Tente uma versão estática ou a API do site (um .json, ?action=raw, old.reddit.com…), outra fonte, ou, com "Controlar \
    apps do Mac" ligado, abra a página com open e leia com browser_tab (include_text).]
    """

    /// Links appear as "text (url)", relative ones resolved against `baseURL`; links to the same site as `baseURL`
    /// are shortened to their path.
    static func convert(_ html: String, baseURL: URL? = nil) -> Page {
        let html = neutralizingStrayAngles(html.replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: ""))
        let title = firstGroup(titleRegex, in: html).map { collapseWhitespace(decodeEntities($0)) }
        var text = html
        for rule in cleanupRules { text = rule.apply(to: text) }
        text = pruned(text)
        text = mainContent(of: text) ?? text

        // Code first, so nothing below touches its whitespace; it comes back at the end.
        var codeBlocks: [String] = []
        text = codeBlockRegex.replacing(in: text) { groups in
            codeBlocks.append(fence(code: codeText(groups[2]), language: language(preAttributes: groups[1], inner: groups[2])))
            return "\n\n\u{E000}\(codeBlocks.count - 1)\u{E001}\n\n"
        }
        // Source line breaks are not breaks of the text: the tags decide where lines end.
        text = Rule(#"\s+"#, " ").apply(to: text)

        var hasSiteLinks = false
        (text, hasSiteLinks) = inlineLinks(text, baseURL: baseURL)
        text = headingRegex.replacing(in: text) { groups in
            let line = oneLine(groups[2])
            return line.isEmpty ? "\n" : "\n\n" + String(repeating: "#", count: Int(groups[1]) ?? 1) + " " + line + "\n\n"
        }
        // Innermost rows first, so a table inside a cell stays in its place; a few rounds cover any real nesting.
        for _ in 0..<6 {
            let rows = rowRegex.replacing(in: text) { groups in tableRow(groups[1]) }
            if rows == text { break }
            text = rows
        }
        text = imageRegex.replacing(in: text) { groups in
            guard let alt = attribute("alt", in: groups[1]).map({ collapseWhitespace($0) }), !alt.isEmpty else { return "" }
            return " [imagem: \(alt.count > 120 ? String(alt.prefix(120)) + "…" : alt)] "
        }
        for rule in layoutRules { text = rule.apply(to: text) }
        text = collapseWhitespace(decodeEntities(text))
        text = placeholderRegex.replacing(in: text) { groups in Int(groups[1]).flatMap { codeBlocks.indices.contains($0) ? codeBlocks[$0] : nil } ?? "" }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hardly any text but scripts: the page builds itself in the browser (or wants a bot check first). A short page that
        // only loads a script (example.com) is not one, unless its `<noscript>` asks for JavaScript.
        var needsJavaScript = false
        if text.count < 200, html.range(of: "<script", options: .caseInsensitive) != nil {
            // `<noscript>` often holds the only readable text of such a page ("You need to enable JavaScript…").
            let fallback = noscriptText(html)
            if text.count < 80 || fallback.range(of: "javascript", options: .caseInsensitive) != nil {
                needsJavaScript = true
                if !fallback.isEmpty, !text.contains(fallback) { text += (text.isEmpty ? "" : "\n\n") + fallback }
            }
        }
        return Page(title: title, text: text, hasSiteLinks: hasSiteLinks, needsJavaScript: needsJavaScript)
    }

    // MARK: Stray angle brackets

    /// Elements the patterns below read as `<name …>…</name>` with a lazy match: an opening tag after the page's last
    /// closing one makes the pattern read to the end of the page, and thousands of them make it quadratic.
    private static let pairedNames: Set<String> = [
        "a", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "header", "title", "script", "style", "nav", "noscript", "svg",
        "template", "iframe", "head", "footer", "aside", "select", "dialog",
    ]

    /// Makes the page safe for the regular expressions below, in one linear pass: every `<` that does not start a
    /// tag they could match (`a < b`, a tag that never closes) becomes `&lt;`, so it stays text, and an opening tag
    /// of a paired element with no closing tag after it is dropped (an unclosed `<script>` or `<style>` takes the
    /// rest of the page with it, as in a browser). Loose brackets and unclosed tags in the thousands would otherwise
    /// make every pattern read to the end of the page from each of them (quadratic time on a hostile or odd page).
    static func neutralizingStrayAngles(_ html: String) -> String {
        guard html.contains("<") else { return html }
        let units = Array(html.utf16)
        let count = units.count
        let lt = unit("<"), gt = unit(">"), bang = unit("!"), dash = unit("-")
        let slash = unit("/"), question = unit("?"), doubleQuote = unit("\""), singleQuote = unit("'")
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        func index(of unit: UInt16, from start: Int) -> Int? {
            var position = start
            while position < count { if units[position] == unit { return position }; position += 1 }
            return nil
        }
        let lastAngle = units.lastIndex(of: gt) ?? -1
        var stray: [Int] = []
        var opens: [String: [Range<Int>]] = [:]
        var lastClose: [String: Int] = [:]
        func noteTag(_ range: Range<Int>) {
            var cursor = range.lowerBound + 1
            let isClose = units[cursor] == slash
            if isClose { cursor += 1 }
            var end = cursor
            while end < range.upperBound, end - cursor < 10, isLetter(units[end]) || (end > cursor && (48...57).contains(units[end])) { end += 1 }
            guard end > cursor else { return }
            let name = String(decoding: units[cursor..<end], as: UTF16.self).lowercased()
            guard pairedNames.contains(name) else { return }
            if isClose { lastClose[name] = range.lowerBound }
            else if units[range.upperBound - 2] != slash { opens[name, default: []].append(range) }
        }
        var quoteAware = true       // tags end at the first `>` outside quotes, like the patterns below
        var quoteFailures = 0
        var commentsOpen = true     // false once a `<!--` had no `-->`: none after it has one either
        var position = 0
        while position < count {
            guard units[position] == lt else { position += 1; continue }
            let start = position
            let next = start + 1 < count ? units[start + 1] : 0
            if next == bang, start + 3 < count, units[start + 2] == dash, units[start + 3] == dash {
                if commentsOpen, let end = commentEnd(units, from: start + 4) { position = end; continue }
                commentsOpen = false
                stray.append(start)
                position += 1
                continue
            }
            let startsTag = isLetter(next) || next == bang || next == question || (next == slash && start + 2 < count && isLetter(units[start + 2]))
            guard startsTag, start < lastAngle else { stray.append(start); position += 1; continue }
            var cursor = start + 1
            if quoteAware {
                var end: Int?
                var interrupted = false
                while cursor < count {
                    let unit = units[cursor]
                    if unit == gt { end = cursor + 1; break }
                    if unit == lt { interrupted = true; break }  // another `<` before the `>`: this one was text
                    if unit == doubleQuote || unit == singleQuote {
                        guard let close = index(of: unit, from: cursor + 1) else { break }
                        cursor = close + 1
                    } else {
                        cursor += 1
                    }
                }
                if let end { noteTag(start..<end); position = end; continue }
                // An attempt that reached the end of the page is costly: after a few, stop trusting quotes.
                if !interrupted {
                    quoteFailures += 1
                    if quoteFailures >= 16 { quoteAware = false }
                }
                stray.append(start)
                position += 1
            } else {
                // The tag ends at the next `>`; a quote or another `<` before it and the patterns would not match it.
                var close = cursor
                while close < count, ![gt, lt, doubleQuote, singleQuote].contains(units[close]) { close += 1 }
                guard close < count, units[close] == gt else { stray.append(start); position += 1; continue }
                noteTag(start..<(close + 1))
                position = close + 1
            }
        }
        // (start, end, replacement): loose brackets are escaped, unclosed opening tags removed.
        var edits: [(range: Range<Int>, replacement: [UInt16])] = stray.map { ($0..<($0 + 1), Array("&lt;".utf16)) }
        for (name, ranges) in opens {
            let unclosed = ranges.filter { $0.lowerBound > (lastClose[name] ?? -1) }
            guard let first = unclosed.first else { continue }
            if name == "script" || name == "style" { edits.append((first.lowerBound..<count, [])) }
            else { edits += unclosed.map { ($0, []) } }
        }
        guard !edits.isEmpty else { return html }
        edits.sort { $0.range.lowerBound < $1.range.lowerBound }
        var output: [UInt16] = []
        output.reserveCapacity(count + stray.count * 3)
        var copied = 0
        for edit in edits where edit.range.lowerBound >= copied {
            output += units[copied..<edit.range.lowerBound]
            output += edit.replacement
            copied = edit.range.upperBound
        }
        output += units[copied...]
        return String(decoding: output, as: UTF16.self)
    }

    private static func unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

    /// The index just after the `-->` that closes a comment whose text starts at `start`.
    private static func commentEnd(_ units: [UInt16], from start: Int) -> Int? {
        let dash = unit("-"), gt = unit(">")
        var position = start
        while position + 2 < units.count {
            if units[position] == dash, units[position + 1] == dash, units[position + 2] == gt { return position + 3 }
            position += 1
        }
        return nil
    }

    // MARK: Rules

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

    /// The inside of a tag after its name: quoted values may hold `>` (a `data-mw` JSON, an `onclick`).
    private static let tagBody = #"(?:"[^"]*"|'[^']*'|[^'"<>])*"#
    private static let titleRegex = try! NSRegularExpression(pattern: #"<title\b"# + tagBody + #">([\s\S]*?)</title\s*>"#, options: .caseInsensitive)
    private static let linkRegex = try! NSRegularExpression(pattern: #"<a\b("# + tagBody + #")>([\s\S]*?)</a\s*>"#, options: .caseInsensitive)
    private static let tagRegex = try! NSRegularExpression(pattern: #"<(?=[A-Za-z/!?])(?:"[^"]*"|'[^']*'|[^'"<>])*>"#)
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")
    private static let codeBlockRegex = try! NSRegularExpression(pattern: #"<pre\b("# + tagBody + #")>([\s\S]*?)</pre\s*>"#, options: .caseInsensitive)
    private static let headingRegex = try! NSRegularExpression(pattern: #"<h([1-6])\b"# + tagBody + #">([\s\S]*?)</h\1\s*>"#, options: .caseInsensitive)
    private static let rowRegex = try! NSRegularExpression(pattern: #"<tr\b"# + tagBody + #">((?:(?!<tr\b)[\s\S])*?)</tr\s*>"#, options: .caseInsensitive)
    private static let cellRegex = try! NSRegularExpression(pattern: #"<(t[dh])\b"# + tagBody + #">([\s\S]*?)(?=</t[dh]\s*>|<t[dh]\b|$)"#, options: .caseInsensitive)
    private static let imageRegex = try! NSRegularExpression(pattern: #"<img\b("# + tagBody + #")>"#, options: .caseInsensitive)
    private static let codeTagRegex = try! NSRegularExpression(pattern: #"<code\b("# + tagBody + #")>"#, options: .caseInsensitive)
    private static let headerRegex = try! NSRegularExpression(pattern: #"<header\b"# + tagBody + #">([\s\S]*?)</header\s*>"#, options: .caseInsensitive)
    private static let placeholderRegex = try! NSRegularExpression(pattern: "\u{E000}([0-9]+)\u{E001}")
    private static let anyTagRegex = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b((?:"[^"]*"|'[^']*'|[^'"<>])*)>"#)

    /// Applied before links are read: whatever is dropped here must not leak its links into the text. Besides
    /// scripts and styles, menus, footers, sidebars and form widgets, which are the site and not the page.
    private static let cleanupRules = [
        Rule(#"<!--[\s\S]*?-->"#, ""),
        Rule(#"<(script|style|nav|noscript|svg|template|iframe|head|footer|aside|select|dialog)\b"# + tagBody + #">[\s\S]*?</\1\s*>"#, ""),
    ]

    /// Applied after links are rewritten; link text survives because only the tags are removed.
    private static let layoutRules = [
        Rule(#"<li\b"# + tagBody + ">", "\n• "),
        Rule(#"</?(?:p|div|ul|ol|tr|table|caption|section|article|header|main|blockquote|form|dl|dt|dd|figure|figcaption|br|hr|details|summary|h[1-6]|pre)\b"# + tagBody + ">", "\n"),
        Rule(#"</?(?:button|option|label|td|th|input|textarea)\b"# + tagBody + ">", " "),
        Rule(#"<code\b"# + tagBody + #">|</code\s*>"#, "`"),
        Rule(#"<(?=[A-Za-z/!?])(?:"[^"]*"|'[^']*'|[^'"<>])*>"#, ""),
    ]

    // MARK: Pruning

    /// Elements that are the page's furniture, not its content: hidden ones, ARIA landmarks other than the main one,
    /// and a few well-known classes (Wikipedia's language list, "[edit]" links, navigation boxes).
    private static let droppableTags: Set<String> = ["div", "span", "section", "ul", "ol", "li", "a", "form", "table", "details", "button", "label"]
    private static let droppedRoles: Set<String> = ["navigation", "banner", "contentinfo", "complementary", "search", "dialog", "alertdialog"]
    private static let droppedClasses: Set<String> = [
        "mw-editsection", "mw-jump-link", "navbox", "vector-dropdown", "vector-page-toolbar", "vector-sticky-header",
        "interlanguage-link", "mw-indicators", "skip-link", "noprint", "printfooter", "headerlink",
    ]

    /// Drops the furniture: a `<header>` with no heading in it, and the elements `isFurniture` flags, in one pass
    /// (their contents go with them). If that would leave almost nothing, the page is used as it was: a script
    /// that sets `aria-hidden` on the whole app while a dialog is open must not blank the page.
    private static func pruned(_ html: String) -> String {
        var result = headerRegex.replacing(in: html) { groups in
            groups[1].range(of: #"<h[1-6]\b"#, options: [.regularExpression, .caseInsensitive]) == nil ? "" : nil
        }
        result = droppingElements(from: result)
        return textLength(result) * 6 < textLength(html) ? html : result
    }

    private static func droppingElements(from html: String) -> String {
        let source = html as NSString
        var cuts: [NSRange] = []
        // `depth` counts open tags of the same name; for a list item it counts the lists opened inside it instead.
        var dropping: (name: String, depth: Int, start: Int)?
        anyTagRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            let isClose = match.range(at: 1).length > 0
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let selfClosing = source.substring(with: match.range).hasSuffix("/>")
            if var current = dropping {
                if current.name == "li" {
                    // A list item may omit its end tag: the next item or the end of its list closes it.
                    switch (name, isClose) {
                    case ("ul", false), ("ol", false):
                        current.depth += selfClosing ? 0 : 1
                        dropping = current
                        return
                    case ("ul", true), ("ol", true):
                        if current.depth == 0 {
                            cuts.append(NSRange(location: current.start, length: match.range.location - current.start))
                            dropping = nil
                        } else {
                            current.depth -= 1
                            dropping = current
                        }
                        return
                    case ("li", true) where current.depth == 0:
                        cuts.append(NSRange(location: current.start, length: match.range.location + match.range.length - current.start))
                        dropping = nil
                        return
                    case ("li", false) where current.depth == 0:
                        cuts.append(NSRange(location: current.start, length: match.range.location - current.start))
                        dropping = nil  // this item may be furniture too: judged below
                    default:
                        return
                    }
                } else {
                    guard name == current.name else { return }
                    if isClose { current.depth -= 1 }
                    else if !selfClosing { current.depth += 1 }
                    if current.depth == 0 {
                        cuts.append(NSRange(location: current.start, length: match.range.location + match.range.length - current.start))
                        dropping = nil
                    } else {
                        dropping = current
                    }
                    return
                }
            }
            guard !isClose, droppableTags.contains(name), !selfClosing,
                  isFurniture(source.substring(with: match.range(at: 3))) else { return }
            dropping = (name, name == "li" ? 0 : 1, match.range.location)
        }
        // An item still open at the end of the page runs to the end of it.
        if let open = dropping, open.name == "li" { cuts.append(NSRange(location: open.start, length: source.length - open.start)) }
        guard !cuts.isEmpty else { return html }
        let result = NSMutableString(string: html)
        for cut in cuts.reversed() { result.deleteCharacters(in: cut) }
        return result as String
    }

    private static func isFurniture(_ attributeText: String) -> Bool {
        let attributes = attributes(in: attributeText)
        if let hidden = attributes["hidden"], hidden.isEmpty || ["hidden", "until-found"].contains(hidden.lowercased()) { return true }
        if attributes["aria-hidden"]?.lowercased() == "true" { return true }
        if let role = attributes["role"]?.lowercased(), droppedRoles.contains(role) { return true }
        if let style = attributes["style"],
           style.range(of: #"(^|;)\s*display\s*:\s*none"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if let classes = attributes["class"] {
            return classes.split(whereSeparator: \.isWhitespace).contains { droppedClasses.contains($0.lowercased()) }
        }
        return false
    }

    private static let mainCandidates: [(regex: NSRegularExpression, only: Bool)] = [
        (#"<(main)\b[^>]*>"#, false),
        (#"<(article)\b[^>]*>"#, true),
        // No `<` before the attribute: a run of loose brackets must not make each of them read on to the next `>`.
        (#"<([a-z]+)\b[^<>]*\srole\s*=\s*["']?main["']?[^>]*>"#, false),
        (#"<([a-z]+)\b[^<>]*\sid\s*=\s*["']?(?:mw-content-text|main-content|content|main)["']?[\s>/][^>]*>"#, false),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    /// The first of these that holds the page's text: `<main>`, the only `<article>`, `role="main"`, or an id that
    /// sites use for it. It must carry a real share of the page (a card or a teaser is not the page).
    private static func mainContent(of html: String) -> String? {
        let total = textLength(html)
        guard total > 1_000 else { return nil }
        let source = html as NSString
        for (regex, only) in mainCandidates {
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
            guard let first = matches.first, !only || matches.count == 1 else { continue }
            let name = source.substring(with: first.range(at: 1)).lowercased()
            guard let content = balancedContent(of: name, after: first.range.location + first.range.length, in: html) else { continue }
            let inner = source.substring(with: content)
            let length = textLength(inner)
            if length >= 500, length * 5 >= total { return inner }
        }
        return nil
    }

    /// The range between an opening tag (ending at `location`) and its closing tag, counting nested tags of the same name.
    private static func balancedContent(of name: String, after location: Int, in html: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: "<(/?)\(name)\\b" + tagBody + ">", options: .caseInsensitive) else { return nil }
        let source = html as NSString
        var depth = 1
        var range: NSRange?
        regex.enumerateMatches(in: html, range: NSRange(location: location, length: source.length - location)) { match, _, stop in
            guard let match else { return }
            if match.range(at: 1).length > 0 { depth -= 1 }
            else if !source.substring(with: match.range).hasSuffix("/>") { depth += 1 }
            if depth == 0 {
                range = NSRange(location: location, length: match.range.location - location)
                stop.pointee = true
            }
        }
        return range
    }

    /// Characters of text outside tags, whitespace aside (a cheap measure of how much a piece of markup says).
    private static func textLength(_ html: String) -> Int {
        let stripped = tagRegex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        return stripped.utf16.reduce(0) { $0 + ($1 > 32 ? 1 : 0) }
    }

    // MARK: Attributes

    /// `name`, `name=value`, `name="value"` or `name='value'`: names are read outside the quotes, so a value that
    /// mentions another attribute ("Show hidden files") is not mistaken for it.
    private static let attributeRegex = try! NSRegularExpression(pattern: #"([^\s"'=/<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#)

    /// The attributes of a tag by lowercase name, values with entities decoded ("" for a bare attribute); the
    /// first of a repeated attribute wins, as in browsers.
    private static func attributes(in text: String) -> [String: String] {
        let source = text as NSString
        var found: [String: String] = [:]
        attributeRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            let name = source.substring(with: match.range(at: 1)).lowercased()
            guard found[name] == nil else { return }
            let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
            found[name] = value.map { decodeEntities(source.substring(with: $0)) } ?? ""
        }
        return found
    }

    /// The value of an attribute in the text of a tag's attributes, or nil.
    private static func attribute(_ name: String, in text: String) -> String? {
        attributes(in: text)[name]
    }

    // MARK: Code, tables, headings

    private static let lineBreakRule = Rule(#"<br\b"# + tagBody + ">", "\n")
    private static let blockSpaceRule = Rule(#"</?(?:br|p|div|li|ul|ol|tr|td|th)\b"# + tagBody + ">", " ")

    private static func codeText(_ inner: String) -> String {
        let withBreaks = lineBreakRule.apply(to: inner)
        let plain = tagRegex.stringByReplacingMatches(in: withBreaks, range: NSRange(withBreaks.startIndex..., in: withBreaks), withTemplate: "")
        var lines = decodeEntities(plain).replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\t", with: "    ") }
        while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
        while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The language a code block declares (`class="language-swift"` on the `<pre>` or on the `<code>` inside it).
    private static func language(preAttributes: String, inner: String) -> String {
        var sources = [preAttributes]
        if let match = codeTagRegex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)), let range = Range(match.range(at: 1), in: inner) {
            sources.append(String(inner[range]))
        }
        for attributes in sources {
            for name in ["class", "data-lang", "data-language"] {
                guard let value = attribute(name, in: attributes) else { continue }
                let words = value.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
                for (index, word) in words.enumerated() {
                    for prefix in ["language-", "lang-", "highlight-source-"] where word.hasPrefix(prefix) { return String(word.dropFirst(prefix.count)) }
                    // MDN: class="brush: js".
                    if word == "brush:", words.indices.contains(index + 1) { return words[index + 1] }
                    if name != "class" { return word }
                }
            }
        }
        return ""
    }

    private static func fence(code: String, language: String) -> String {
        let longestRun = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let marker = String(repeating: "`", count: max(3, longestRun + 1))
        return marker + language + "\n" + code + "\n" + marker
    }

    /// One line of text from markup that may hold tags and line breaks (a heading, a table cell).
    private static func oneLine(_ inner: String) -> String {
        let spaced = blockSpaceRule.apply(to: inner)
        let plain = tagRegex.stringByReplacingMatches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced), withTemplate: "")
        return collapseWhitespace(plain)
    }

    /// `<tr>` as `| a | b |`, followed by `| --- |` when every cell is a header.
    private static func tableRow(_ inner: String) -> String {
        var cells: [String] = []
        var headersOnly = true
        let source = inner as NSString
        for match in cellRegex.matches(in: inner, range: NSRange(location: 0, length: source.length)) {
            if source.substring(with: match.range(at: 1)).lowercased() == "td" { headersOnly = false }
            cells.append(oneLine(source.substring(with: match.range(at: 2))))
        }
        guard cells.contains(where: { !$0.isEmpty }) else { return "\n" }
        var row = "\n| " + cells.joined(separator: " | ") + " |"
        if headersOnly { row += "\n|" + String(repeating: " --- |", count: cells.count) }
        return row
    }

    private static let headRule = Rule(#"<head\b[^>]*>[\s\S]*?</head\s*>"#, "")
    private static let scriptRule = Rule(#"<(style|script)\b[^>]*>[\s\S]*?</\1\s*>"#, "")
    private static let noscriptRegex = try! NSRegularExpression(pattern: #"<noscript\b[^>]*>([\s\S]*?)</noscript\s*>"#, options: .caseInsensitive)

    private static func noscriptText(_ html: String) -> String {
        let body = headRule.apply(to: html)
        let source = body as NSString
        let parts = noscriptRegex.matches(in: body, range: NSRange(location: 0, length: source.length)).map { match -> String in
            var inner = scriptRule.apply(to: source.substring(with: match.range(at: 1)))
            inner = tagRegex.stringByReplacingMatches(in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")
            return collapseWhitespace(decodeEntities(inner))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Links

    /// `<a href="u">text</a>` becomes `text (u)`; fragments, `javascript:` links, links without text (icons)
    /// and links whose text already is the address stay as they were. A link inside the page's own site shows
    /// only its path (the page's address is in the header), percent-encoding undone where it stays readable.
    private static func inlineLinks(_ html: String, baseURL: URL?) -> (text: String, hasSiteLinks: Bool) {
        let result = NSMutableString(string: html)
        let source = html as NSString
        var hasSiteLinks = false
        for match in linkRegex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let attributes = source.substring(with: match.range(at: 1))
            let inner = source.substring(with: match.range(at: 2))
            guard let raw = attribute("href", in: attributes)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let label = collapseWhitespace(decodeEntities(tagRegex.stringByReplacingMatches(
                in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")))
            if raw.hasPrefix("#") {
                // "Skip to content" and the like are for keyboards, not for reading.
                if label.range(of: #"^(skip to|jump to|pular para|ir para)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    result.replaceCharacters(in: match.range, with: "")
                }
                continue
            }
            let lowered = raw.lowercased()
            guard !lowered.hasPrefix("javascript:"), !lowered.hasPrefix("data:") else { continue }
            let absolute = URL(string: raw, relativeTo: baseURL)?.absoluteString ?? raw
            guard let target = shown(absolute, relativeTo: baseURL) else { continue }
            let shownTarget = target.text
            guard !label.isEmpty, ![absolute, shownTarget].contains(where: { label == $0 || label + "/" == $0 || label == $0 + "/" }) else { continue }
            if target.isSite { hasSiteLinks = true }
            result.replaceCharacters(in: match.range, with: inner + " (\(shownTarget))")
        }
        return (result as String, hasSiteLinks)
    }

    /// How a link target is written: its path when it stays on the page's site, nil for a link back to the same page.
    private static func shown(_ absolute: String, relativeTo base: URL?) -> (text: String, isSite: Bool)? {
        guard let base, let url = URL(string: absolute), let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.host?.lowercased() == base.host()?.lowercased(), url.scheme?.lowercased() == base.scheme?.lowercased(),
              components.port == base.port else { return (readable(absolute), false) }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let basePath = base.path(percentEncoded: true).isEmpty ? "/" : base.path(percentEncoded: true)
        if path == basePath, components.percentEncodedQuery == base.query(percentEncoded: true) { return nil }
        let local = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "") + (components.percentEncodedFragment.map { "#" + $0 } ?? "")
        return (readable(local), true)
    }

    /// Percent-encoded letters undone (Wikipedia links are mostly "%D0%…"). Only sequences that decode to a
    /// printable non-ASCII character change: `%3F`, `%26`, `%2B`, `%23`, `%25`, `%2F`, a space or a bracket keep
    /// their meaning in the address, and invisible or whitespace characters stay encoded so the "(url)" is honest.
    private static func readable(_ address: String) -> String {
        guard address.contains("%") else { return address }
        let bytes = Array(address.utf8)
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        func hexByte(at index: Int) -> UInt8? {
            guard index + 2 < bytes.count, bytes[index] == UInt8(ascii: "%"),
                  let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) else { return nil }
            return high << 4 | low
        }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if let lead = hexByte(at: index), lead >= 0xC0 {
                let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
                var sequence = [lead]
                var next = index + 3
                while sequence.count < length, let byte = hexByte(at: next), byte & 0xC0 == 0x80 {
                    sequence.append(byte)
                    next += 3
                }
                if sequence.count == length, let character = String(bytes: sequence, encoding: .utf8),
                   !character.unicodeScalars.contains(where: { scalar in
                       scalar.properties.isWhitespace || [.control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned]
                           .contains(scalar.properties.generalCategory)
                   }) {
                    output += sequence
                    index = next
                    continue
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Text

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text.precomposedStringWithCanonicalMapping }
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

private extension NSRegularExpression {
    /// Replaces each match with what `transform` returns for its groups (group 0 is the whole match); nil keeps the match.
    func replacing(in text: String, with transform: ([String]) -> String?) -> String {
        let source = text as NSString
        let matches = self.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
            output += transform(groups) ?? groups[0]
            cursor = match.range.location + match.range.length
        }
        return output + source.substring(from: cursor)
    }
}
