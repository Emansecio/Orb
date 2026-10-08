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
        #expect(page.text.contains("See the docs (https://example.com/docs) and this (https://site.test/rel/path?a=1&b=2)."))
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
        #expect(output.contains("Veja mais (https://links.test/mais)"))
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
        let first = try await fetch("long.test", stub)
        #expect(first.contains("[caracteres 1–30000 de \(long.count)]"))
        #expect(first.contains("use offset=30000 para continuar"))

        let second = try await fetch("long.test", stub, ["offset": .string("30000"), "max_chars": .number(100)])
        #expect(second.contains("[caracteres 30001–30100 de"))
        #expect(second.contains("use offset=30100"))

        let rest = try await fetch("long.test", stub, ["offset": .number(Double(long.count - 10))])
        #expect(!rest.contains("para continuar"))
        #expect(try await fetch("long.test", stub, ["offset": .number(1_000_000)]).contains("além do fim"))

        // max_chars is capped at 30,000.
        let capped = try await fetch("long.test", stub, ["max_chars": .number(500_000)])
        #expect(capped.contains("1–30000"))
    }

    @Test func fetchChecksTheStatusAndTheURL() async throws {
        let tool = WebFetchTool(session: WebStubProtocol.session(host: "gone.test", .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("<p>nope</p>".utf8))))
        await #expect(throws: ToolError("O site respondeu HTTP 404.")) {
            try await tool.run(.object(["url": .string("https://gone.test/x")]), context: workspace.context)
        }
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
        do {
            _ = try await tool.run(.object(["url": .string("https://cutpdf.test/")]), context: workspace.context)
            Issue.record("a truncated PDF should not read as complete")
        } catch let error as ToolError {
            #expect(error.message.contains("save_to"))
            #expect(error.message.contains("read_file"))
        }
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
