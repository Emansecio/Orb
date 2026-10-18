import Foundation
import os
import Testing
@testable import Orb

/// Serves canned HTTP responses keyed by host, so parallel tests don't interfere.
final class WebStubProtocol: URLProtocol {
    struct Stub: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    static let stubs = OSAllocatedUnfairLock<[String: Stub]>(initialState: [:])

    static func session(host: String, _ stub: Stub) -> URLSession {
        stubs.withLock { $0[host] = stub }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stubs.withLock({ $0[url.host() ?? ""] }),
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The first group of `pattern` in `text` as a number.
private func firstNumber(_ pattern: String, in text: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return Int(text[range])
}

final class WebToolTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func fetch(_ host: String, _ stub: WebStubProtocol.Stub, path: String = "/", _ extra: [String: JSONValue] = [:]) async throws -> String {
        let tool = WebFetchTool(session: WebStubProtocol.session(host: host, stub))
        return try await workspace.run(tool, ["url": .string("https://\(host)\(path)")].merging(extra) { $1 })
    }

    private func html(_ body: String, charset: String = "text/html; charset=utf-8") -> WebStubProtocol.Stub {
        .init(headers: ["Content-Type": charset], body: Data(body.utf8))
    }

    // MARK: Links

    @Test func linksStayAsTextWithURL() {
        let page = HTMLText.convert("""
        <p>See <a href="https://example.com/docs">the docs</a> and <a class="x" href='/rel/path?a=1&amp;b=2'>this</a>.</p>
        <a href="#top">Top</a> <a href="javascript:void(0)">Run</a> <a href="https://x.dev"><img src="logo.png"></a>
        <a href="https://same.dev/">https://same.dev/</a> <a href="mailto:a@b.co">Mail me</a>
        <nav><a href="/skipped">Nav link</a></nav>
        """, baseURL: URL(string: "https://site.test/base/page"))
        // A link inside the page's own site shows only its path; the page's address says where it is.
        #expect(page.text.contains("See the docs (https://example.com/docs) and this (/rel/path?a=1&b=2)."))
        #expect(page.hasSiteLinks)
        #expect(page.text.contains("Top") && !page.text.contains("#top"))
        #expect(!page.text.contains("javascript"))
        #expect(!page.text.contains("https://x.dev"), "image-only links add noise")
        #expect(page.text.contains("https://same.dev/") && !page.text.contains("https://same.dev/ ("))
        #expect(page.text.contains("Mail me (mailto:a@b.co)"))
        #expect(!page.text.contains("skipped"))
    }

    @Test func conversionHandlesManyPagesQuickly() {
        let page = (1...2_000).map { "<li><a href=\"/p/\($0)\">item \($0)</a></li>" }.joined()
        let start = ContinuousClock.now
        for _ in 0..<5 { _ = HTMLText.convert("<ul>\(page)</ul>") }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    // MARK: web_fetch

    @Test func fetchReturnsTitleTextAndLinks() async throws {
        let output = try await fetch("links.test", html("<title>Olá</title><body><p>Veja <a href=\"/mais\">mais</a></p></body>"), path: "/a/b")
        #expect(output.contains("URL: https://links.test/a/b"))
        #expect(output.contains("Título: Olá"))
        #expect(output.contains("Veja mais (/mais)"))
        #expect(output.contains("Links começando com / são deste site (https://links.test)."))
    }

    @Test func fetchHonorsMetaCharsetAndHeaderCharset() async throws {
        let latin = try #require("<html><head><meta charset=\"iso-8859-1\"><title>Café</title></head><body>coração açúcar</body></html>".data(using: .isoLatin1))
        let sniffed = try await fetch("meta.test", .init(headers: ["Content-Type": "text/html"], body: latin))
        #expect(sniffed.contains("Título: Café"))
        #expect(sniffed.contains("coração açúcar"))

        let httpEquiv = try #require("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"><p>“aspas” – ok</p>".data(using: .windowsCP1252))
        #expect(try await fetch("equiv.test", .init(headers: ["Content-Type": "text/html"], body: httpEquiv)).contains("“aspas” – ok"))

        let header = try #require("<p>ação</p>".data(using: .isoLatin1))
        #expect(try await fetch("header.test", .init(headers: ["Content-Type": "text/html; charset=ISO-8859-1"], body: header)).contains("ação"))

        // No declaration and not valid UTF-8: Windows-1252, like browsers.
        let undeclared = try #require("<p>ação</p>".data(using: .windowsCP1252))
        #expect(try await fetch("none.test", .init(headers: ["Content-Type": "text/html"], body: undeclared)).contains("ação"))

        // UTF-8 stays UTF-8 without any declaration.
        #expect(try await fetch("utf8.test", .init(headers: ["Content-Type": "text/html"], body: Data("<p>ação</p>".utf8))).contains("ação"))
    }

    @Test func fetchPagesLongTextWithOffset() async throws {
        let text = (0..<4_000).map { String(format: "%04d", $0) }.joined(separator: " ")   // 19,999 characters
        let long = String(repeating: text + "\n", count: 4)
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(long.utf8))
        // A piece ends at a space, never inside a number, and the note says where it really stopped.
        let first = try await fetch("long.test", stub)
        let end = try #require(firstNumber(#"\[caracteres 1–(\d+) de \d+\]"#, in: first))
        #expect((9_000...12_000).contains(end))
        #expect(first.contains("use offset=\(end) para continuar"))
        let character = long[long.index(long.startIndex, offsetBy: end - 1)]
        #expect(character == " ")

        let second = try await fetch("long.test", stub, ["offset": .number(Double(end)), "max_chars": .number(100)])
        #expect(second.contains("[caracteres \(end + 1)–"))
        #expect(second.contains("de \(long.count)]"))

        let rest = try await fetch("long.test", stub, ["offset": .number(Double(long.count - 10))])
        #expect(!rest.contains("para continuar"))
        #expect(try await fetch("long.test", stub, ["offset": .number(1_000_000)]).contains("além do fim"))

        // max_chars is capped at 24,000, and a page that big still fits under ToolOutputCap (it would lose its middle above).
        let capped = try await fetch("long.test", stub, ["max_chars": .number(500_000)])
        #expect(capped.contains("[caracteres 1–2") && capped.count < ToolOutputCap.limit)
        #expect(capped.count < ToolOutputCap.limit)
    }

    @Test func fetchChecksTheStatusAndTheURL() async throws {
        let tool = WebFetchTool(session: WebStubProtocol.session(host: "gone.test", .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("<p>nope</p>".utf8))))
        let error = try #require(await #expect(throws: ToolError.self, "a 404 should not read as a page") {
            _ = try await tool.run(.object(["url": .string("https://gone.test/x")]), context: workspace.context)
        })
        #expect(error.message.hasPrefix("O site respondeu HTTP 404 para https://gone.test/x."))
        #expect(error.message.contains("confira a URL"))
        await #expect(throws: ToolError.self) { try await tool.run(.object(["url": .string("file:///etc/passwd")]), context: workspace.context) }
        await #expect(throws: ToolError.self) { try await tool.run(.object([:]), context: workspace.context) }
    }

    @Test func fetchReadsPDFResponsesAsText() async throws {
        let pdf = try Fixtures.pdf(pages: ["Contrato primeira", "Contrato segunda"])
        let output = try await fetch("pdf.test", .init(headers: ["Content-Type": "application/pdf"], body: pdf))
        #expect(output.contains("--- Página 1 ---\nContrato primeira"))
        #expect(output.contains("Contrato segunda"))
    }

    @Test func fetchSuggestsSaveToWhenAPDFWasCutShort() async throws {
        let pdf = try Fixtures.pdf(pages: ["Relatório longo"])
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "application/pdf"], body: pdf.prefix(pdf.count / 2))
        let tool = WebFetchTool(session: WebStubProtocol.session(host: "cutpdf.test", stub), pdfLimit: pdf.count / 2)
        let error = try #require(await #expect(throws: ToolError.self, "a truncated PDF should not read as complete") {
            _ = try await tool.run(.object(["url": .string("https://cutpdf.test/")]), context: workspace.context)
        })
        #expect(error.message.contains("save_to"))
        #expect(error.message.contains("read_file"))
    }

    @Test func fetchReadsAPDFServedWithAGenericType() async throws {
        let pdf = try Fixtures.pdf(pages: ["olá pdf"])
        var context = workspace.context
        context.canSaveFiles = false // without save_to, a PDF that is not read is lost
        for (index, type) in ["binary/octet-stream", "application/force-download", "application/x-download", "application/download"].enumerated() {
            let host = "generic\(index).test"
            let tool = WebFetchTool(session: WebStubProtocol.session(host: host, .init(headers: ["Content-Type": type], body: pdf)), cache: WebPageCache())
            let output = try await tool.run(.object(["url": .string("https://\(host)/doc.pdf")]), context: context)
            #expect(output.contains("olá pdf") && output.contains("--- Página 1 ---"), "\(type): \(output)")
        }
        // Not a PDF: the answer is the same as for any binary.
        let other = WebFetchTool(session: WebStubProtocol.session(host: "blob.test", .init(headers: ["Content-Type": "binary/octet-stream"], body: Data(repeating: 1, count: 64))),
                                 cache: WebPageCache())
        let output = try await other.run(.object(["url": .string("https://blob.test/x")]), context: context)
        #expect(output.contains("não é texto"))
    }

    @Test func aGenericTypeKeepsThePDFLimitOnlyForAPDF() async throws {
        let pdf = try Fixtures.pdf(pages: ["relatório grande"])
        var context = workspace.context
        context.canSaveFiles = false
        // A PDF over the limit for other types (5 MB in the app) is still read whole under a generic type.
        let small = pdf.count / 2
        let session = WebStubProtocol.session(host: "bigpdf.test", .init(headers: ["Content-Type": "binary/octet-stream"], body: pdf))
        let output = try await WebFetchTool(session: session, textLimit: small, cache: WebPageCache())
            .run(.object(["url": .string("https://bigpdf.test/r")]), context: context)
        #expect(output.contains("relatório grande"), "\(output)")
        // Anything else stops at the lower limit: the answer says "more than", not that it was read whole.
        let blob = Data(repeating: 1, count: 4_000)
        let other = WebFetchTool(session: WebStubProtocol.session(host: "bigblob.test", .init(headers: ["Content-Type": "binary/octet-stream"], body: blob)),
                                 textLimit: 1_000, cache: WebPageCache())
        let text = try await other.run(.object(["url": .string("https://bigblob.test/x")]), context: context)
        #expect(text.contains("mais de") && text.contains("não é texto"), "\(text)")
    }

    @Test func aPDFCutBySizeWithoutTheTerminalDoesNotSuggestAnotherTry() async throws {
        let pdf = try Fixtures.pdf(pages: ["Relatório longo"])
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "application/pdf"], body: pdf.prefix(pdf.count / 2))
        let tool = WebFetchTool(session: WebStubProtocol.session(host: "cutnoterm.test", stub), pdfLimit: pdf.count / 2, cache: WebPageCache())
        var context = workspace.context
        context.canSaveFiles = false
        let error = try #require(await #expect(throws: ToolError.self, "a truncated PDF should not read as complete") {
            _ = try await tool.run(.object(["url": .string("https://cutnoterm.test/")]), context: context)
        })
        #expect(!error.message.contains("conexão melhor") && error.message.contains("Terminal"), "\(error.message)")
    }

    @Test func fetchSurvivesHugeOffsets() async throws {
        let stub = html("<p>curta</p>")
        for value in [JSONValue.number(1e19), .number(Double(Int.max)), .string("1e19"), .string("99999999999999999999")] {
            #expect(try await fetch("huge.test", stub, ["offset": value]).contains("além do fim"))
        }
    }

    @Test func fetchSaysWhenContentIsNotText() async throws {
        let output = try await fetch("bin.test", .init(headers: ["Content-Type": "image/png"], body: Data(repeating: 1, count: 2_048)))
        #expect(output.contains("image/png"))
        #expect(output.contains("não é texto"))
        #expect(output.contains("save_to"))
    }

    @Test func saveToDownloadsTheResponseToAFile() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let output = try await fetch("dl.test", .init(headers: ["Content-Type": "application/zip"], body: payload), path: "/f.zip",
                                     ["save_to": .string("downloads/f.zip")])
        #expect(output.contains("salvos em"))
        #expect(try workspace.read("downloads/f.zip") == payload)
        // No temporary files are left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.url("downloads").path)
        #expect(names == ["f.zip"])

        // Replaces an existing file and writes through a symlink.
        try workspace.write("real.bin", "old")
        try workspace.link("alias.bin", to: "real.bin")
        _ = try await fetch("dl.test", .init(headers: ["Content-Type": "application/zip"], body: Data("new".utf8)), ["save_to": .string("alias.bin")])
        #expect(try workspace.readText("real.bin") == "new")
        #expect(try FileManager.default.attributesOfItem(atPath: workspace.url("alias.bin").path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func saveToDoesNotWriteOnHTTPErrorsOrIntoFolders() async throws {
        await #expect(throws: ToolError.self) {
            try await fetch("err.test", .init(status: 500, body: Data("x".utf8)), ["save_to": .string("out.bin")])
        }
        #expect(!FileManager.default.fileExists(atPath: workspace.url("out.bin").path))
        try FileManager.default.createDirectory(at: workspace.url("folder"), withIntermediateDirectories: true)
        await #expect(throws: ToolError.self) {
            try await fetch("ok.test", .init(body: Data("x".utf8)), ["save_to": .string("folder")])
        }
    }

    @Test func fetchStaysSensitiveAndDescribesSaving() {
        let tool = WebFetchTool()
        #expect(tool.risk(.object(["url": .string("https://a.test")])) == .sensitive)
        #expect(tool.risk(.object(["url": .string("https://a.test"), "save_to": .string("~/x")])) == .sensitive)
        let summary = tool.summary(.object(["url": .string("https://a.test/f.zip"), "save_to": .string("~/Downloads/f.zip")]))
        #expect(summary.title == "Baixando arquivo")
        #expect(summary.detail == "https://a.test/f.zip\n→ ~/Downloads/f.zip")
        #expect(tool.summary(.object(["url": .string("https://a.test")])).title == "Lendo página")
    }
}

// MARK: - Conversion

struct WebConversionTests {
    private let base = URL(string: "https://en.wikipedia.org/wiki/Swift")

    private func convert(_ html: String) -> HTMLText.Page { HTMLText.convert(html, baseURL: base) }

    /// A page shaped like Wikipedia's: skip link, header with a language list, the article, then footer.
    private var article: String {
        let filler = String(repeating: "Swift is a general-purpose programming language built by Apple and the open-source community. ", count: 12)
        let languages = (1...60).map { "<li class=\"interlanguage-link\"><a href=\"https://x.wikipedia.org/wiki/L\($0)\">Lang\($0)</a></li>" }.joined()
        return """
        <html><head><title>Swift - Wikipedia</title></head><body>
        <a class="mw-jump-link" href="#bodyContent">Jump to content</a>
        <header class="vector-header"><a href="/">Wikipedia</a><nav>Menu</nav>
        <div class="vector-dropdown"><ul>\(languages)</ul></div></header>
        <main id="content" role="main">
        <header class="page-titlebar"><h1>Swift</h1></header>
        <div hidden>never shown</div>
        <p>\(filler)See <a href="/wiki/LLVM">LLVM</a> and <a href="/wiki/Swift#History">history</a>.</p>
        <h2>History<span class="mw-editsection"><a href="/w/index.php?action=edit">edit</a></span></h2>
        <p>Started in 2010.</p>
        </main>
        <footer>Privacy policy</footer></body></html>
        """
    }

    @Test func aPageStartsWithItsArticleNotItsFurniture() {
        let page = convert(article)
        #expect(page.text.hasPrefix("# Swift\n"))
        #expect(!page.text.contains("Jump to content") && !page.text.contains("Lang1") && !page.text.contains("Menu"))
        #expect(!page.text.contains("never shown") && !page.text.contains("Privacy policy") && !page.text.contains("edit"))
        #expect(page.text.contains("## History"))
        // Links inside the site are short; the one back to the page itself is only text.
        #expect(page.text.contains("LLVM (/wiki/LLVM)"))
        #expect(page.text.contains("and history.") , "a link back to the same page adds no address")
        #expect(page.hasSiteLinks)
    }

    @Test func percentEncodedPathsAreShownReadable() {
        let page = HTMLText.convert("<p><a href=\"/wiki/Bras%C3%ADlia\">Brasília</a> <a href=\"/a%20b\">x</a> <a href=\"/wiki/Foo_(bar)\">y</a> <a href=\"/q?a=%28\">z</a></p>",
                                    baseURL: URL(string: "https://pt.wikipedia.org/wiki/Brasil"))
        #expect(page.text.contains("Brasília (/wiki/Brasília)"))
        // Kept encoded where decoding would break the "(url)": a space, a parenthesis.
        #expect(page.text.contains("x (/a%20b)") && page.text.contains("z (/q?a=%28)"))
        #expect(page.text.contains("y (/wiki/Foo_(bar))"))
    }

    @Test func reservedPercentEncodingsKeepTheirMeaningInLinks() {
        let html = """
        <p><a href="/wiki/What_Is_Life%3F">q</a> <a href="/s?search=a%26b&x=1">amp</a> <a href="/s?q=c%2B%2B">plus</a>
        <a href="/wiki/AC%2FDC">slash</a> <a href="/wiki/100%25">pct</a> <a href="https://other.org/a%23b">hash</a>
        <a href="/wiki/Bras%C3%A3o%3F">mixed</a> <a href="/wiki/a%C2%A0b">nbsp</a> <a href="/wiki/x%E2%80%AEy">bidi</a>
        <a href="/wiki/%+f%zz">odd</a></p>
        """
        let text = HTMLText.convert(html, baseURL: URL(string: "https://en.wikipedia.org/wiki/Swift")).text
        for expected in ["q (/wiki/What_Is_Life%3F)", "amp (/s?search=a%26b&x=1)", "plus (/s?q=c%2B%2B)", "slash (/wiki/AC%2FDC)",
                         "pct (/wiki/100%25)", "hash (https://other.org/a%23b)", "mixed (/wiki/Brasão%3F)",
                         "nbsp (/wiki/a%C2%A0b)", "bidi (/wiki/x%E2%80%AEy)", "odd (/wiki/%25+f%25zz)"] {
            #expect(text.contains(expected), "\(expected) in \(text)")
        }
    }

    @Test func theWordHiddenInsideAnAttributeValueHidesNothing() {
        let filler = String(repeating: "Conteúdo importante da página principal. ", count: 40)
        let html = """
        <main><p>\(filler)</p>
        <div class="mt-4 hidden lg:block"><p>Tabela de preços</p></div>
        <a title="Show hidden files" href="/files">Baixar o relatório</a>
        <section aria-label="Steps, hidden details"><p>Passo um: importante.</p></section>
        <div hidden>escondido</div><div HIDDEN="">tambem escondido</div><div hidden="false">visivel</div></main>
        """
        let text = HTMLText.convert(html, baseURL: base).text
        #expect(text.contains("Tabela de preços") && text.contains("Baixar o relatório (/files)") && text.contains("Passo um: importante."))
        #expect(text.contains("visivel"))
        #expect(!text.contains("escondido"))
    }

    @Test func looseAngleBracketsStayTextAndAreFast() {
        let text = HTMLText.convert("<p>if a <b>x</b> < b then 'c' and d > e</p>").text
        #expect(text == "if a x < b then 'c' and d > e")
        let chunk = "a < b i "
        for html in ["<p>" + String(repeating: chunk, count: 20_000) + "</p>",
                     "<p>" + String(repeating: "<b i ", count: 20_000) + "</p>",
                     "<p>" + String(repeating: "<a \"x ", count: 20_000) + "</p>",
                     "<p>" + String(repeating: "<!-- x ", count: 20_000) + "</p>",
                     String(repeating: "<p>x<a ' ", count: 20_000) + ">",
                     "<p>" + String(repeating: "<a href=\"/x\">link ", count: 20_000),
                     String(repeating: "<h2>t ", count: 20_000),
                     String(repeating: "<pre>t ", count: 20_000),
                     String(repeating: "<script>x ", count: 20_000) + "fim"] {
            let start = ContinuousClock.now
            let page = HTMLText.convert(html, baseURL: base)
            #expect(ContinuousClock.now - start < .seconds(2), "\(html.prefix(20))")
            #expect(page.text.isEmpty == html.hasSuffix("fim"), "only the unclosed script page has nothing left to read")
        }
        #expect(HTMLText.convert("<p>" + String(repeating: chunk, count: 5) + "</p>").text.hasPrefix("a < b i a < b i"))
    }

    @Test func unclosedPairedTagsAreHandledLikeABrowserWould() {
        let article = String(repeating: "Texto do artigo. ", count: 20)
        // An unclosed <script> swallows the rest of the page (it is code); an unclosed <a> only loses its tag.
        #expect(HTMLText.convert("<p>antes</p><script>var x = 1; <b>nao</b>").text == "antes")
        let linked = HTMLText.convert("<p>\(article)<a href=\"/x\">sem fim</p><p>depois</p>").text
        #expect(linked.contains("sem fim") && linked.contains("depois"))
        #expect(HTMLText.convert("<a href=\"/ok\">fechado</a> e <a href=\"/solto\">solto").text.contains("fechado (/ok)"))
    }

    @Test func aDroppedListItemWithoutEndTagDoesNotSwallowThePage() {
        let filler = String(repeating: "Texto principal do artigo. ", count: 30)
        let html = """
        <main><p>\(filler)</p><ul><li class="interlanguage-link"><a href="/a">Lang</a><li>Item two<li>Item three</ul>
        <div aria-hidden="true">hide me</div><p>fim</p>
        <ul><li class="interlanguage-link">Fora<ul><li>aninhado</li></ul></li><li>Dentro</li></ul></main>
        """
        let text = HTMLText.convert(html, baseURL: base).text
        #expect(text.contains("Item two") && text.contains("Item three") && text.contains("fim") && text.contains("Dentro"))
        #expect(!text.contains("Lang") && !text.contains("hide me") && !text.contains("Fora") && !text.contains("aninhado"))
    }

    @Test func aTableInsideACellKeepsItsPlace() {
        let text = convert("<table><tr><td><table><tr><td>inner1</td><td>inner2</td></tr></table></td><td>outer2</td></tr></table>").text
        let order = ["inner1", "inner2", "outer2"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted())
        #expect(!text.contains("\nouter2"), "outer2 stays in the outer row: \(text)")
    }

    @Test func linksToOtherSitesAndSchemesStayAbsolute() {
        let page = convert("<p><a href=\"https://swift.org/docs\">docs</a> <a href=\"http://en.wikipedia.org/wiki/X\">plain</a> <a href=\"/wiki/Swift\">self</a></p>")
        #expect(page.text.contains("docs (https://swift.org/docs)"))
        #expect(page.text.contains("plain (http://en.wikipedia.org/wiki/X)"))
        #expect(!page.text.contains("self (") , "a link to the page itself adds nothing")
    }

    @Test func codeKeepsItsIndentationAndIsFenced() {
        let page = convert("""
        <p>Example:</p>
        <pre class="language-swift"><code>func f() {
            if x &lt; 1 {
                return 1
            }
        }
        </code></pre><p>After <code>f()</code>.</p>
        """)
        #expect(page.text.contains("```swift\nfunc f() {\n    if x < 1 {\n        return 1\n    }\n}\n```"))
        #expect(page.text.contains("After `f()`."))
        // Language from the <code> tag, MDN's "brush:" class, and a longer fence when the code holds backticks.
        #expect(convert("<pre><code class=\"language-python\">def a():\n    pass</code></pre>").text == "```python\ndef a():\n    pass\n```")
        #expect(convert("<pre class=\"brush: js notranslate\">let a = 1</pre>").text == "```js\nlet a = 1\n```")
        #expect(convert("<pre>```\nx\n```</pre>").text.hasPrefix("````"))
    }

    @Test func tablesBecomeRowsAndHeadingsKeepTheirLevel() {
        let page = convert("""
        <h1>Title</h1><h3 id="x">Sub <a href="https://a.test/x">link</a></h3>
        <table><tr><th>Nome</th><th>Idade</th></tr>
        <tr><td>Ana <b>Maria</b></td><td><p>30</p><p>anos</p></td></tr><tr><td></td><td></td></tr></table>
        """)
        #expect(page.text.contains("# Title\n\n### Sub link (https://a.test/x)\n"))
        #expect(page.text.contains("| Nome | Idade |\n| --- | --- |\n| Ana Maria | 30 anos |"))
        #expect(!page.text.contains("|  |"), "an empty row is dropped")
    }

    @Test func sourceLineBreaksAreNotTextBreaks() {
        let page = convert("<p>Um parágrafo\nquebrado no fonte.</p><p>Outro</p><button>Enviar</button><button>Cancelar</button><select><option>Brasil</option><option>Portugal</option></select>")
        #expect(page.text.contains("Um parágrafo quebrado no fonte."))
        #expect(page.text.contains("Enviar Cancelar") && !page.text.contains("Brasil"))
    }

    @Test func imageDescriptionsAreKeptButIconLinksAreNot() {
        let page = convert("<p>Veja <img src=\"a.png\" alt=\"Gráfico de barras\"> e <img src=\"t.gif\"> <a href=\"https://x.test/\"><img alt=\"logo\"></a></p>")
        #expect(page.text.contains("[imagem: Gráfico de barras]"))
        #expect(!page.text.contains("x.test"), "an image-only link adds no address")
    }

    @Test func attributesThatHoldAngleBracketsDoNotLeakIntoTheText() {
        let page = convert("<p>antes</p><div data-mw='{\"a\":\"<br/>{{cite}}\"}'>dentro</div><p>depois</p>")
        #expect(page.text == "antes\ndentro\ndepois" || page.text.contains("dentro") && !page.text.contains("cite") && !page.text.contains("{"))
    }

    @Test func aPageThatHidesItsWholeAppIsStillRead() {
        let body = String(repeating: "Texto de verdade da página. ", count: 80)
        let page = convert("<html><body><div id=\"root\" aria-hidden=\"true\"><p>\(body)</p></div></body></html>")
        #expect(page.text.contains("Texto de verdade"), "a modal's aria-hidden on the whole app must not blank the page")
    }

    @Test func aMainElementThatIsOnlyATeaserIsNotThePage() {
        let long = String(repeating: "Notícia importante com bastante texto. ", count: 60)
        let page = convert("<body><main><p>pouco</p></main><section><p>\(long)</p></section></body>")
        #expect(page.text.contains("Notícia importante"))
    }

    @Test func pagesThatNeedJavaScriptSaySo() {
        let spa = convert("<html><head><title>App</title><script src=\"/app.js\"></script></head><body><div id=\"root\"></div><noscript>You need to enable JavaScript to run this app.</noscript></body></html>")
        #expect(spa.needsJavaScript)
        #expect(spa.text.contains("You need to enable JavaScript to run this app."))
        let empty = convert("<html><head><script>challenge()</script></head><body></body></html>")
        #expect(empty.needsJavaScript && empty.text.isEmpty)
        // A page with real text, or with no scripts, is not flagged.
        #expect(!convert("<html><body><p>\(String(repeating: "texto ", count: 60))</p><script>x()</script></body></html>").needsJavaScript)
        #expect(!convert("<html><body></body></html>").needsJavaScript)
        // A short page that just loads a script (example.com) reads fine.
        let short = "<html><body><p>This domain is for use in documentation examples without needing permission. This is not a service; avoid relying on it.</p><script src=/s.js></script></body></html>"
        #expect(!convert(short).needsJavaScript && !convert(short).text.contains("Nota"))
    }

    @Test func linkAddressesAreASmallPartOfAWikipediaStylePage() {
        let items = (1...200).map { "<p>Veja <a href=\"/wiki/Artigo_\($0)\">artigo \($0)</a> sobre o assunto em questão e seus detalhes.</p>" }.joined()
        let page = convert("<main>\(items)</main>")
        let addresses = try! NSRegularExpression(pattern: #" \(/wiki/[^)]*\)"#).matches(in: page.text, range: NSRange(page.text.startIndex..., in: page.text)).reduce(0) { $0 + $1.range.length }
        #expect(Double(addresses) / Double(page.text.count) < 0.25)
    }
}

// MARK: - web_fetch results

final class WebFetchBehaviorTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func tool(_ host: String, _ stub: WebStubProtocol.Stub, cache: WebPageCache = WebPageCache()) -> WebFetchTool {
        WebFetchTool(session: WebStubProtocol.session(host: host, stub), cache: cache)
    }

    private func arguments(_ host: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["url": .string("https://\(host)/doc")].merging(extra) { $1 })
    }

    @Test func aJavaScriptPageComesBackWithAnExplanation() async throws {
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "text/html"], body: Data("<html><head><script>x()</script></head><body></body></html>".utf8))
        let output = try await tool("spa.test", stub).run(arguments("spa.test"), context: workspace.context)
        #expect(output.contains("JavaScript") && output.contains("browser_tab"))
        #expect(!output.contains("(sem texto)"))
    }

    @Test func httpErrorsSayWhatToDo() async throws {
        for (status, hint) in [(403, "bloqueia leitores"), (429, "espere"), (503, "Erro no servidor"), (410, "confira a URL")] {
            let host = "status\(status).test"
            let error = try #require(await #expect(throws: ToolError.self, "HTTP \(status) should fail") {
                _ = try await tool(host, .init(status: status)).run(arguments(host), context: workspace.context)
            })
            #expect(error.message.contains("HTTP \(status) para https://\(host)/doc") && error.message.contains(hint), "\(error.message)")
        }
    }

    @Test func networkFailuresAreExplainedInPortuguese() {
        let url = URL(string: "http://exemplo.test/x")!
        let cases: [(URLError.Code, String)] = [
            (.appTransportSecurityRequiresSecureConnection, "https://"),
            (.cannotFindHost, "não existe"), (.dnsLookupFailed, "não existe"),
            (.timedOut, "20 s"), (.serverCertificateUntrusted, "não contorna"), (.serverCertificateHasBadDate, "não contorna"),
            (.notConnectedToInternet, "sem conexão"), (.cannotConnectToHost, "Não consegui conectar"),
        ]
        for (code, expected) in cases {
            let message = WebFetchTool.explain(URLError(code), url: url).message
            #expect(message.contains(expected), "\(code.rawValue): \(message)")
            #expect(!message.contains("The ") && !message.contains("could not"), "\(code.rawValue) must not be English: \(message)")
        }
        #expect(WebFetchTool.explain(URLError(.cannotFindHost), url: url).message.contains("exemplo.test"))
    }

    @Test func aFailureOnTheWireReachesTheModelExplained() async throws {
        // The stub has nothing for this host, so the session fails with unsupportedURL.
        let session = WebStubProtocol.session(host: "other.test", .init())
        let fetch = WebFetchTool(session: session, cache: WebPageCache())
        await #expect(throws: ToolError.self) { try await fetch.run(.object(["url": .string("https://nostub.test/")]), context: workspace.context) }
    }

    @Test func theBundleAllowsPlainHTTP() throws {
        // App Transport Security blocks http:// in a bundled app (tests run outside one and do not see it), so the
        // Info.plist the script writes must allow it: web_fetch is meant to read any address.
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/bundle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>"))
    }

    @Test func aDownloadAnnouncedAsTooBigFailsBeforeAnyByteIsRead() async throws {
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "application/zip", "Content-Length": "200000000"], body: Data("x".utf8))
        let error = try #require(await #expect(throws: ToolError.self, "a 200 MB download should be refused") {
            _ = try await tool("big.test", stub).run(arguments("big.test", ["save_to": .string("big.zip")]), context: workspace.context)
        })
        #expect(error.message.contains("100 MB") && error.message.contains("limite do save_to"))
        #expect(!FileManager.default.fileExists(atPath: workspace.url("big.zip").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)
        #expect(!names.contains { $0.hasPrefix(".orb-download") })
    }

    @Test func saveToNeedsTheFilesSwitch() async throws {
        var context = workspace.context
        context.canSaveFiles = false
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "application/zip"], body: Data("x".utf8))
        let error = try #require(await #expect(throws: ToolError.self, "save_to writes a file, so it needs \"Terminal e arquivos\"") {
            _ = try await tool("nofiles.test", stub).run(arguments("nofiles.test", ["save_to": .string("a.zip")]), context: context)
        })
        #expect(error.message.contains("Terminal e arquivos"))
        #expect(!FileManager.default.fileExists(atPath: workspace.url("a.zip").path))
        // Reading the page is still fine.
        #expect(try await tool("nofiles.test", .init(headers: ["Content-Type": "text/plain"], body: Data("ok".utf8))).run(arguments("nofiles.test"), context: context).contains("ok"))
    }

    @Test func continuingALongPageReusesTheDownloadAndKeepsOffsetsConsistent() async throws {
        let cache = WebPageCache()
        let lines = (1...3_000).map { "linha número \($0) com algum texto" }.joined(separator: "\n")
        let first = tool("cache.test", .init(headers: ["Content-Type": "text/plain"], body: Data(lines.utf8)), cache: cache)
        let page1 = try await first.run(arguments("cache.test"), context: workspace.context)
        let next = try #require(firstNumber(#"use offset=(\d+) para continuar"#, in: page1))
        #expect(page1.contains("[caracteres 1–\(next) de"))
        // A cut at a line break: the next piece starts at a whole line.
        // The site now answers something else; the continuation still comes from the page that was read first.
        let changed = tool("cache.test", .init(headers: ["Content-Type": "text/plain"], body: Data("OUTRO CONTEÚDO".utf8)), cache: cache)
        let page2 = try await changed.run(arguments("cache.test", ["offset": .number(Double(next))]), context: workspace.context)
        #expect(page2.contains("[caracteres \(next + 1)–") && page2.contains("linha número") && !page2.contains("OUTRO"))
        let body = page2.components(separatedBy: "\n").dropFirst(3).first ?? ""
        #expect(body.hasPrefix("linha número "), "the second piece starts at the beginning of a line: \(body)")
        // Without an offset the page is fetched again.
        #expect(try await changed.run(arguments("cache.test"), context: workspace.context).contains("OUTRO CONTEÚDO"))
    }

    @Test func findReturnsPassagesWithTheirOffsets() async throws {
        let text = (1...400).map { $0 == 250 ? "aqui está a AGULHA procurada" : "palha número \($0) sem nada especial" }.joined(separator: "\n")
        let fetch = tool("find.test", .init(headers: ["Content-Type": "text/plain"], body: Data(text.utf8)))
        let output = try await fetch.run(arguments("find.test", ["find": .string("agulha")]), context: workspace.context)
        let offset = try #require(firstNumber(#"offset=(\d+): "#, in: output))
        #expect(output.contains("AGULHA procurada"))
        // The offset is where reading should begin, a little before the match.
        let before = text.index(text.startIndex, offsetBy: offset)
        #expect(text[before...].hasPrefix("") && text.distance(from: before, to: text.range(of: "AGULHA")!.lowerBound) <= 130)
        let none = try await fetch.run(arguments("find.test", ["find": .string("inexistente")]), context: workspace.context)
        #expect(none.contains("Nenhuma ocorrência"))
        // Many matches are capped.
        let many = WebFetchTool.passages(of: "x", in: String(repeating: "um x aqui e bastante texto em volta dele para separar. ", count: 100))
        #expect(many.components(separatedBy: "\n• ").count - 1 == WebFetchTool.maxFindMatches && many.contains("+"))
    }

    @Test func aPictureReachesTheModelAsAPicture() async throws {
        let png = try Fixtures.png(text: "Olá")
        let stub = WebStubProtocol.Stub(headers: ["Content-Type": "image/png"], body: png)
        let store = ImageStore(dataFolder: workspace.directory)
        var context = workspace.context
        context.imageStore = store
        context.botID = UUID()
        context.acceptsImages = true
        let result = try await tool("pic.test", stub).runWithImages(arguments("pic.test"), context: context)
        #expect(result.images.count == 1 && result.text.contains("image/png") && result.text.contains("anexada"))
        #expect(FileManager.default.fileExists(atPath: result.images[0].path))
        // A model that cannot see pictures gets the old note.
        context.acceptsImages = false
        let blind = try await tool("pic.test", stub).runWithImages(arguments("pic.test"), context: context)
        #expect(blind.images.isEmpty && blind.text.contains("save_to"))
    }

    @Test func cacheForgetsOldPagesAndKeepsFewOfThem() async {
        let cache = WebPageCache()
        for index in 0..<(WebPageCache.capacity + 3) {
            await cache.store(.init(header: "h", text: "t\(index)", truncatedDownload: nil), for: "u\(index)")
        }
        #expect(await cache.entry(for: "u0") == nil)
        #expect(await cache.entry(for: "u\(WebPageCache.capacity + 2)")?.text == "t\(WebPageCache.capacity + 2)")
        let later = Date().addingTimeInterval(WebPageCache.lifetime + 1)
        #expect(await cache.entry(for: "u\(WebPageCache.capacity + 2)", now: later) == nil)
        await cache.store(.init(header: "h", text: String(repeating: "a", count: WebPageCache.largestText + 1), truncatedDownload: nil), for: "huge")
        #expect(await cache.entry(for: "huge") == nil)
    }
}

// MARK: - Endless responses

/// Answers 200 and then keeps sending `chunk` every `interval` until the load is stopped, like an event stream or a radio.
final class EndlessStreamProtocol: URLProtocol {
    struct Stream: Sendable {
        var mime: String
        var chunk: Data
        var interval: TimeInterval
        var served = 0
        var stopped = false
    }

    static let streams = OSAllocatedUnfairLock<[String: Stream]>(initialState: [:])

    static func session(host: String, _ stream: Stream) -> URLSession {
        streams.withLock { $0[host] = stream }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EndlessStreamProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func stream(_ host: String) -> Stream? { streams.withLock { $0[host] } }

    private let running = OSAllocatedUnfairLock(initialState: true)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let stream = Self.stream(host),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": stream.mime]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // The first piece comes with the headers: on a busy machine the queue below may start only after the reader's
        // deadline, and a cut with nothing read is a different case from the one these tests are about.
        client?.urlProtocol(self, didLoad: stream.chunk)
        Self.streams.withLock { $0[host]?.served += stream.chunk.count }
        // URLProtocol is not Sendable; this loop is the only code that touches it after `startLoading` returns.
        nonisolated(unsafe) let me = self
        DispatchQueue.global().async {
            while me.running.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: stream.interval)
                guard me.running.withLock({ $0 }) else { break }
                me.client?.urlProtocol(me, didLoad: stream.chunk)
                Self.streams.withLock { $0[host]?.served += stream.chunk.count }
            }
        }
    }

    override func stopLoading() {
        running.withLock { $0 = false }
        if let host = request.url?.host() { Self.streams.withLock { $0[host]?.stopped = true } }
    }
}

final class EndlessResponseTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func arguments(_ host: String) -> JSONValue { .object(["url": .string("https://\(host)/events")]) }

    @Test func aStreamThatNeverEndsIsCutAtTheDeadlineWithWhatArrived() async throws {
        let host = "sse.test"
        let session = EndlessStreamProtocol.session(host: host, .init(mime: "text/event-stream", chunk: Data("data: x\n\n".utf8), interval: 0.05))
        // A loose deadline: with the whole suite queued at the start of a run, no piece was read within 2 s.
        let tool = WebFetchTool(session: session, cache: WebPageCache(), readDeadline: .seconds(5))
        let started = ContinuousClock.now
        let output = try await tool.run(arguments(host), context: workspace.context)
        // Far from the 7 days of a plain URLSession, but generous: the whole suite runs on a loaded machine.
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(output.contains("data: x"))
        #expect(output.contains("não terminou"))
    }

    @Test func aTypeThatIsNotTextIsAnsweredFromTheHeaders() async throws {
        let host = "radio.test"
        let session = EndlessStreamProtocol.session(host: host, .init(mime: "audio/mpeg", chunk: Data(repeating: 1, count: 65_536), interval: 0.01))
        let tool = WebFetchTool(session: session, cache: WebPageCache(), readDeadline: .seconds(20))
        let started = ContinuousClock.now
        let output = try await tool.run(arguments(host), context: workspace.context)
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(output.contains("audio/mpeg") && output.contains("não é texto") && output.contains("save_to"))
        // The load is dropped, not read to the limit.
        for _ in 0..<40 where EndlessStreamProtocol.stream(host)?.stopped != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(EndlessStreamProtocol.stream(host)?.stopped == true)
        #expect((EndlessStreamProtocol.stream(host)?.served ?? .max) < WebFetchTool.maxBytes)
    }

    @Test func theNotTextAnswerReadsWellWithAndWithoutASize() {
        let unknown = WebFetchTool.notTextMessage(mimeType: "audio/mpeg", length: -1)
        #expect(unknown.hasPrefix("Conteúdo audio/mpeg (não é texto)") && !unknown.contains(" de (não é"))
        #expect(WebFetchTool.notTextMessage(mimeType: "application/zip", length: 1_024).hasPrefix("Conteúdo application/zip de \(AttachmentKind.fileSize(1_024)) (não é texto)"))
    }

    @Test func unreadableTypesAreRecognisedFromTheirMimeType() {
        for readable in ["", "text/plain", "text/event-stream", "application/json", "application/pdf", "application/xhtml+xml", "image/svg+xml",
                         "application/octet-stream", "application/javascript", "binary/octet-stream", "application/force-download",
                         "application/x-download", "application/download"] {
            #expect(WebFetchTool.isReadable(readable, wantsImage: false), "\(readable)")
        }
        for unreadable in ["audio/mpeg", "video/mp4", "application/zip", "image/png", "font/woff2"] {
            #expect(!WebFetchTool.isReadable(unreadable, wantsImage: false), "\(unreadable)")
        }
        #expect(WebFetchTool.isReadable("image/png", wantsImage: true))
    }

    @Test func aPDFWhoseSizeIsAnnouncedIsReadToTheEndOnASlowLink() async throws {
        let pdf = try Fixtures.pdf(pages: ["Relatório lento"])
        let host = "slowpdf.test"
        let session = SlowBodyProtocol.session(host: host, .init(mime: "application/pdf", body: pdf, piece: max(pdf.count / 5, 1), interval: 0.2, announcesLength: true))
        // The deadline for a body of unknown length would cut this one (it takes about a second).
        let tool = WebFetchTool(session: session, cache: WebPageCache(), readDeadline: .milliseconds(300))
        let output = try await tool.run(arguments(host), context: workspace.context)
        #expect(output.contains("Relatório lento"), "\(output)")
        #expect(!output.contains("não terminou"))
    }

    @Test func aPDFOfUnknownLengthCutByTimeSaysSoAndSuggestsSaveTo() async throws {
        let host = "endlesspdf.test"
        let session = EndlessStreamProtocol.session(host: host, .init(mime: "application/pdf", chunk: Data("%PDF-1.4 ".utf8), interval: 0.05))
        let tool = WebFetchTool(session: session, cache: WebPageCache(), readDeadline: .seconds(1))
        let error = try #require(await #expect(throws: ToolError.self, "a PDF cut by time should not read as complete") {
            _ = try await tool.run(arguments(host), context: workspace.context)
        })
        #expect(error.message.contains("save_to") && error.message.contains("não terminou"), "\(error.message)")
        var context = workspace.context
        context.canSaveFiles = false
        let withoutFiles = try #require(await #expect(throws: ToolError.self, "a PDF cut by time should not read as complete") {
            _ = try await tool.run(arguments(host), context: context)
        })
        #expect(!withoutFiles.message.contains("save_to") && withoutFiles.message.contains("não terminou"), "\(withoutFiles.message)")
    }

    @Test func aPageCutByTimeKeepsTheNoteWhenItIsReadInPieces() async throws {
        let host = "slowpage.test"
        let session = EndlessStreamProtocol.session(host: host, .init(mime: "text/html", chunk: Data("<p>palavra palavra</p>".utf8), interval: 0.05))
        // A loose deadline: on a busy machine (the whole suite in parallel) no piece may arrive within 1 s.
        let tool = WebFetchTool(session: session, cache: WebPageCache(), readDeadline: .seconds(3))
        let first = try await tool.run(arguments(host), context: workspace.context)
        #expect(first.contains("não terminou"))
        let again = try await tool.run(.object(["url": .string("https://\(host)/events"), "offset": .number(5)]), context: workspace.context)
        #expect(again.contains("[... a resposta não terminou em 3 s; o resto não foi lido ...]"), "\(again)")
    }
}

/// Serves a body in pieces, one every `interval`, like a slow link; with or without announcing its length.
final class SlowBodyProtocol: URLProtocol {
    struct Body: Sendable {
        var mime: String
        var body: Data
        var piece: Int
        var interval: TimeInterval
        var announcesLength: Bool
    }

    static let bodies = OSAllocatedUnfairLock<[String: Body]>(initialState: [:])

    static func session(host: String, _ body: Body) -> URLSession {
        bodies.withLock { $0[host] = body }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowBodyProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let running = OSAllocatedUnfairLock(initialState: true)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let served = Self.bodies.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers = ["Content-Type": served.mime]
        if served.announcesLength { headers["Content-Length"] = String(served.body.count) }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // URLProtocol is not Sendable; this loop is the only code that touches it after `startLoading` returns.
        nonisolated(unsafe) let me = self
        DispatchQueue.global().async {
            var start = 0
            while start < served.body.count, me.running.withLock({ $0 }) {
                me.client?.urlProtocol(me, didLoad: served.body.subdata(in: start..<min(start + served.piece, served.body.count)))
                start += served.piece
                Thread.sleep(forTimeInterval: served.interval)
            }
            if me.running.withLock({ $0 }) { me.client?.urlProtocolDidFinishLoading(me) }
        }
    }

    override func stopLoading() { running.withLock { $0 = false } }
}
