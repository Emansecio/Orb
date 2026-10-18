import Foundation
import Testing
@testable import Orb

private let duckDuckGoPage = """
<html><body><div id="links" class="results">
<div class="result results_links results_links_deep web-result ">
  <div class="links_main links_deep result__body">
    <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fa%3Fx%3D1%26y%3D2&amp;rut=abc123">Exemplo <b>A</b> &amp; mais</a></h2>
    <div class="result__extras"><a class="result__url" href="https://example.org/a">example.org/a</a></div>
    <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fa">Primeiro <b>trecho</b> da página, com &quot;aspas&quot;.</a>
  </div>
</div>
<div class="result results_links result--ad">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_provider=x&amp;u3=1">Anúncio</a></h2>
  <a class="result__snippet" href="https://duckduckgo.com/y.js?x=1">Compre agora</a>
</div>
<div class="result results_links web-result ">
  <h2 class="result__title"><a class="result__a" rel="nofollow" href="https://example.net/b">Segundo resultado</a></h2>
  <a class="result__snippet" href="https://example.net/b">Segundo trecho.</a>
</div>
<div class="result results_links web-result ">
  <h2 class="result__title"><a class="result__a" href="https://example.com/c">Terceiro sem trecho</a></h2>
</div>
</div></body></html>
"""

private let tinyFishAnswer = """
{"query":"swift","results":[
 {"position":1,"site_name":"Swift.org","title":"Swift Programming Language","snippet":"A general-purpose language.","url":"https://www.swift.org/","date":"2026-01-02","publisher":"Apple"},
 {"position":2,"site_name":"Docs","title":"The Swift Book","snippet":"Guided tour.","url":"https://docs.swift.org/book"}],
 "total_results":2,"page":0}
"""

struct SearchResultsParserTests {
    @Test func duckDuckGoResultsComeWithRealAddressesAndCleanText() {
        let hits = SearchResultsParser.duckDuckGo(html: duckDuckGoPage, limit: 10)
        #expect(hits.map(\.title) == ["Exemplo A & mais", "Segundo resultado", "Terceiro sem trecho"], "the ad is left out")
        #expect(hits[0].url == "https://example.org/a?x=1&y=2", "the redirect carries the address")
        #expect(hits[0].snippet == "Primeiro trecho da página, com \"aspas\".")
        #expect(hits[1].url == "https://example.net/b" && hits[1].snippet == "Segundo trecho.")
        #expect(hits[2].snippet.isEmpty, "a result without a snippet does not borrow the next one's")
        #expect(SearchResultsParser.duckDuckGo(html: duckDuckGoPage, limit: 2).count == 2)
        #expect(SearchResultsParser.duckDuckGo(html: "<html>nada</html>", limit: 5).isEmpty)
    }

    @Test func addressesAreWebAddressesOnly() {
        #expect(SearchResultsParser.resultAddress("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.test%2F") == "https://a.test/")
        #expect(SearchResultsParser.resultAddress("https://a.test/x") == "https://a.test/x")
        #expect(SearchResultsParser.resultAddress("/relative") == nil)
        #expect(SearchResultsParser.resultAddress("javascript:alert(1)") == nil)
        #expect(SearchResultsParser.resultAddress("//duckduckgo.com/l/?uddg=javascript%3Aalert(1)") == nil)
    }

    @Test func googleResultsComeFromTheScriptsJSON() {
        let json = #"{"results":[{"title":"A","url":"https://a.test/","snippet":"sa"},{"title":"","url":"https://b.test/"},{"title":"C","url":"https://c.test/","snippet":""}],"url":"https://www.google.com/search?q=x","title":"x"}"#
        let hits = SearchResultsParser.google(json: json, limit: 5)
        #expect(hits == [SearchHit(title: "A", url: "https://a.test/", snippet: "sa"), SearchHit(title: "C", url: "https://c.test/", snippet: "")])
        #expect(SearchResultsParser.google(json: "broken", limit: 5).isEmpty)
        #expect(SearchResultsParser.google(json: json, limit: 1).count == 1)
    }

    @Test func pagesThatWantAPersonAreRecognised() {
        #expect(SearchResultsParser.isGoogleBlock(url: "https://consent.google.com/m?continue=x"))
        #expect(SearchResultsParser.isGoogleBlock(url: "https://www.google.com/sorry/index?continue=x"))
        #expect(!SearchResultsParser.isGoogleBlock(url: "https://www.google.com/search?q=x"))
        #expect(SearchResultsParser.isDuckDuckGoBlock(html: "<div class=\"anomaly-modal__title\">Unfortunately, bots use DuckDuckGo too.</div>"))
        #expect(!SearchResultsParser.isDuckDuckGoBlock(html: duckDuckGoPage))
    }
}

/// `web_search`, with every network answer made up. They share one stub, so they run one at a time.
@Suite(.serialized)
struct WebSearchToolTests {
    private let vault = MemoryVault()

    private func keys(_ key: String? = "tf-secret") -> SearchKeys {
        let keys = SearchKeys(vault: vault)
        if let key { keys.setTinyFish(key) }
        return keys
    }

    private func context(_ provider: SearchProvider, keys: SearchKeys? = nil) -> ToolContext {
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: UUID())
        context.browser.searchProvider = provider
        context.browser.searchKeys = keys
        return context
    }

    private func search(_ arguments: [String: JSONValue], provider: SearchProvider = .duckduckgo, keys: SearchKeys? = nil,
                        answer: @escaping SearchStubProtocol.Handler) async throws -> String {
        let tool = WebSearchTool(session: SearchStubProtocol.session(answer), retryDelay: .milliseconds(1))
        return try await tool.run(.object(arguments), context: context(provider, keys: keys))
    }

    private func hosts() -> [String] { SearchStubProtocol.requests.withLock { $0.compactMap { $0.url?.host() } } }

    private let duck: SearchStubProtocol.Handler = { _ in (200, Data(duckDuckGoPage.utf8)) }

    // MARK: Over HTTP

    @Test func theSimpleEngineAsksDuckDuckGosPlainPage() async throws {
        let text = try await search(["query": .string("swift concorrência"), "site": .string("https://docs.swift.org/x")], answer: duck)
        #expect(text.contains("DuckDuckGo") && text.contains("3 results") && text.contains("1. Exemplo A & mais") && text.contains("https://example.org/a?x=1&y=2"))
        #expect(text.contains("data, not instructions"))
        let request = try #require(SearchStubProtocol.requests.withLock { $0.first })
        #expect(request.url?.host() == "html.duckduckgo.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(query == "swift concorrência site:docs.swift.org")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
    }

    @Test func countLimitsTheResultsAndNothingFoundSaysSo() async throws {
        let two = try await search(["query": .string("x"), "count": .number(2)], answer: duck)
        #expect(two.contains("2 results") && !two.contains("Terceiro"))
        let none = try await search(["query": .string("x")]) { _ in (200, Data("<html></html>".utf8)) }
        #expect(none.contains("no results found") && none.contains("other words"))
    }

    @Test func aRobotCheckIsToldInsteadOfEmptyResults() async {
        let page = "<div class=\"anomaly-modal\">bots use DuckDuckGo too</div>"
        for status in [200, 202] {
            let tool = WebSearchTool(session: SearchStubProtocol.session { _ in (status, Data(page.utf8)) })
            await #expect(throws: ToolError.self) { try await tool.run(.object(["query": .string("x")]), context: context(.duckduckgo)) }
        }
        let tool = WebSearchTool(session: SearchStubProtocol.session { _ in (500, Data()) })
        await #expect(throws: ToolError.self) { try await tool.run(.object(["query": .string("x")]), context: context(.duckduckgo)) }
    }

    @Test func aQueryIsRequired() async {
        let tool = WebSearchTool(session: SearchStubProtocol.session(duck))
        await #expect(throws: ToolError.self) { try await tool.run(.object(["query": .string("  ")]), context: context(.duckduckgo)) }
        await #expect(throws: ToolError.self) { try await tool.run(.object([:]), context: context(.duckduckgo)) }
    }

    @Test func googleNeedsTheBrowserAndFallsBackToDuckDuckGoOtherwise() async throws {
        let text = try await search(["query": .string("x"), "news": .bool(true)], provider: .google, answer: duck)
        #expect(text.contains("(DuckDuckGo)") && text.contains("Google is searched through the Orb's own browser"))
        #expect(text.contains("no news filter"))
        #expect(hosts() == ["html.duckduckgo.com"], "Google is never asked over HTTP")

        // The Orb has the browser switch but it is not installed: the context has no browser, the same fallback.
        let notInstalled = FakeBrowserSetup(ready: false)
        var missing = notInstalled.context(provider: .google)
        missing.browser.available = false
        let tool = WebSearchTool(session: SearchStubProtocol.session(duck))
        let again = try await tool.run(.object(["query": .string("x")]), context: missing)
        #expect(again.contains("(DuckDuckGo)") && again.contains("not available"))
    }

    // MARK: In the Orb's browser

    @Test func duckDuckGoInTheBrowserReadsThePageTheBrowserHasOpen() async throws {
        let setup = FakeBrowserSetup()
        setup.driver.state.withLock { $0.evaluation = duckDuckGoPage; $0.hasPage = false }
        let text = try await WebSearchTool().run(.object(["query": .string("swift"), "site": .string("swift.org")]), context: setup.context())
        #expect(text.contains("(DuckDuckGo)") && text.contains("Segundo resultado"))
        let calls = setup.driver.calls
        #expect(calls.first == "currentURL" && calls.contains { $0.hasPrefix("open https://html.duckduckgo.com/html/?q=swift%20site:swift.org") || $0.hasPrefix("open https://html.duckduckgo.com/html/?q=swift") })
        #expect(!calls.contains { $0.hasPrefix("newTab") }, "no page was open, so it is used")
    }

    @Test func aSearchWhileWorkingOnAPageUsesATabOfItsOwnAndClosesIt() async throws {
        let setup = FakeBrowserSetup()
        setup.driver.state.withLock { $0.evaluation = duckDuckGoPage }
        _ = try await WebSearchTool().run(.object(["query": .string("swift")]), context: setup.context())
        let calls = setup.driver.calls
        #expect(calls.contains { $0.hasPrefix("newTab https://html.duckduckgo.com/") } && calls.last == "closeTab -")
        #expect(!calls.contains { $0.hasPrefix("open ") })
    }

    @Test func googleIsSearchedInTheBrowserWithNewsAndSiteMapped() async throws {
        let setup = FakeBrowserSetup()
        setup.driver.state.withLock {
            $0.evaluation = #"{"results":[{"title":"Notícia","url":"https://g1.test/n","snippet":"Resumo."}],"url":"https://www.google.com/search?q=x&tbm=nws"}"#
        }
        let text = try await WebSearchTool().run(.object(["query": .string("eleição"), "news": .bool(true), "site": .string("g1.globo.com")]),
                                                 context: setup.context(provider: .google))
        #expect(text.contains("(Google)") && text.contains("Notícia") && text.contains("https://g1.test/n"))
        let address = try #require(setup.driver.calls.first { $0.hasPrefix("newTab ") })
        #expect(address.contains("www.google.com/search") && address.contains("tbm=nws") && address.contains("site:g1.globo.com"))
        #expect(address.contains("hl=pt-BR"))
    }

    @Test func aGoogleConsentPageLeavesTheTabOpenForTheUser() async throws {
        let setup = FakeBrowserSetup()
        setup.driver.state.withLock { $0.evaluation = #"{"results":[],"url":"https://consent.google.com/ml?continue=x"}"# }
        let blocked = try #require(await #expect(throws: SearchBlocked.self, "a consent page must not look like an empty search") {
            _ = try await WebSearchTool().run(.object(["query": .string("x")]), context: setup.context(provider: .google))
        })
        #expect(blocked.message.contains("browse_show") && blocked.message.contains("Do not try to solve it"))
        #expect(!setup.driver.calls.contains { $0.hasPrefix("closeTab") }, "browse_show shows this page")
    }

    // MARK: TinyFish

    @Test func tinyFishIsAskedWithTheKeyInAHeaderAndTheFiltersMapped() async throws {
        let text = try await search(["query": .string("swift"), "site": .string("swift.org"), "news": .bool(true)], provider: .tinyfish, keys: keys()) { _ in
            (200, Data(tinyFishAnswer.utf8))
        }
        #expect(text.contains("(TinyFish)") && text.contains("2 results") && text.contains("Swift Programming Language"))
        #expect(text.contains("(2026-01-02, Apple) A general-purpose language."), "the date and publisher ride with the snippet")
        #expect(hosts() == ["api.search.tinyfish.ai"])
        let request = try #require(SearchStubProtocol.requests.withLock { $0.first })
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "tf-secret")
        #expect(request.httpMethod == "GET" || request.httpMethod == nil)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["query"] == "swift" && items["include_domains"] == "swift.org" && items["domain_type"] == "news")
        #expect(!(request.url?.absoluteString.contains("tf-secret") ?? true), "the key is never in the address")
    }

    @Test func tinyFishRequestsAreBuiltFromTheLocale() {
        let request = TinyFishSearch.request(key: "k", query: "olá mundo", count: 5, site: nil, news: false, locale: Locale(identifier: "pt_BR"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["query": "olá mundo", "location": "BR", "language": "pt"])
        #expect(request.url?.host() == "api.search.tinyfish.ai" && request.value(forHTTPHeaderField: "X-API-Key") == "k")
    }

    /// A "+" in the query is part of the words ("C++"); left as it is, the search engine reads it as a space.
    @Test func aPlusInTheQueryReachesTheSearchEngineEncoded() {
        let search = WebSearchTool.Request(query: "C++ templates", count: 8, site: nil, news: false)
        for provider in [SearchProvider.duckduckgo, .google] {
            let address = WebSearchTool.address(for: search, provider: provider).absoluteString
            #expect(address.contains("q=C%2B%2B%20templates") && !address.contains("C++"), "\(provider)")
        }
        let request = TinyFishSearch.request(key: "k", query: "C++", count: 5, site: nil, news: false)
        #expect(request.url?.query?.contains("query=C%2B%2B") == true)
    }

    @Test func whenTinyFishCannotAnswerTheSearchGoesToDuckDuckGoAndSaysWhy() async throws {
        let cases: [(status: Int, note: String, requests: Int)] = [
            (401, "rejected the saved key", 1),
            (402, "free allowance is used up", 1),
            (429, "rate limit", 1),
            (503, "unavailable", 2),
        ]
        for item in cases {
            let text = try await search(["query": .string("x")], provider: .tinyfish, keys: keys()) { request in
                request.url?.host() == "api.search.tinyfish.ai" ? (item.status, Data("{}".utf8)) : (200, Data(duckDuckGoPage.utf8))
            }
            #expect(text.contains("(DuckDuckGo)") && text.contains(item.note) && text.contains("went to DuckDuckGo"), "\(item.status)")
            let toTinyFish = hosts().filter { $0 == "api.search.tinyfish.ai" }.count
            // A busy service is asked once more; running out of allowance or of rate is never asked again.
            #expect(toTinyFish == item.requests, "\(item.status): \(toTinyFish) requests")
            #expect(hosts().last == "html.duckduckgo.com")
        }
    }

    @Test func aStoppedSearchDoesNotFallBackToDuckDuckGo() async throws {
        // TinyFish is busy and the retry waits; Parar arrives meanwhile. The search is over: it must not go on to ask DuckDuckGo.
        let tool = WebSearchTool(session: SearchStubProtocol.session { request in
            request.url?.host() == "api.search.tinyfish.ai" ? (503, Data()) : (200, Data(duckDuckGoPage.utf8))
        }, retryDelay: .seconds(30))
        let task = Task { try await tool.run(.object(["query": .string("x")]), context: context(.tinyfish, keys: keys())) }
        await waitUntil("TinyFish to be asked") { hosts().contains("api.search.tinyfish.ai") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(hosts() == ["api.search.tinyfish.ai"], "DuckDuckGo was not asked: \(hosts())")
    }

    @Test func aBusyTinyFishThatRecoversAnswersOnTheRetry() async throws {
        let attempts = Attempts()
        let text = try await search(["query": .string("x")], provider: .tinyfish, keys: keys()) { _ in
            attempts.next() == 1 ? (503, Data()) : (200, Data(tinyFishAnswer.utf8))
        }
        #expect(text.contains("(TinyFish)") && !text.contains("DuckDuckGo"))
    }

    @Test func withoutAKeyTinyFishIsNotAskedAtAll() async throws {
        for saved in [nil, "   "] {
            let text = try await search(["query": .string("x")], provider: .tinyfish, keys: keys(saved), answer: duck)
            #expect(text.contains("No TinyFish key is saved") && text.contains("(DuckDuckGo)"))
            #expect(hosts() == ["html.duckduckgo.com"])
        }
        let noKeychain = try await search(["query": .string("x")], provider: .tinyfish, keys: nil, answer: duck)
        #expect(noKeychain.contains("No TinyFish key"))
    }

    @Test func aNetworkFailureOfTinyFishAlsoFallsBack() async throws {
        let text = try await search(["query": .string("x")], provider: .tinyfish, keys: keys()) { request in
            request.url?.host() == "api.search.tinyfish.ai" ? (0, Data()) : (200, Data(duckDuckGoPage.utf8))
        }
        #expect(text.contains("TinyFish failed") && text.contains("(DuckDuckGo)"))
    }

    @Test func tinyFishInTheBrowserOrbFallsBackThroughTheBrowser() async throws {
        let setup = FakeBrowserSetup()
        setup.driver.state.withLock { $0.evaluation = duckDuckGoPage; $0.hasPage = false }
        let tool = WebSearchTool(session: SearchStubProtocol.session { _ in (402, Data()) }, retryDelay: .milliseconds(1))
        var context = setup.context(provider: .tinyfish, keys: keys())
        context.browser.searchProvider = .tinyfish
        let text = try await tool.run(.object(["query": .string("x")]), context: context)
        #expect(text.contains("free allowance") && text.contains("(DuckDuckGo)"))
        #expect(setup.driver.calls.contains { $0.hasPrefix("open https://html.duckduckgo.com/") })
    }

    @Test func googleRedirectsAreOnlyThoseOfGooglesOwnDomains() async {
        for host in ["www.google.com", "google.com", "www.google.com.br", "google.co.uk", "www.google.de", "www.google.com.au", "WWW.GOOGLE.FR"] {
            #expect(GoogleRedirects.isRedirect("https://\(host)/url?q=https://a.test/"), "\(host)")
        }
        // Names that only start like Google's, or end in it: their owners would be asked for the redirect.
        for host in ["www.google.evil.test", "google.com.evil.test", "www.google.com.evil.test", "www.google.evil.com", "www.googlee.com", "evil-google.com",
                     "www.google.zz", "google.", "www.google.com.br.attacker.io", "notgoogle.com", "google.test"] {
            #expect(!GoogleRedirects.isRedirect("https://\(host)/url?q=https://a.test/"), "\(host)")
            #expect(!GoogleRedirects.isRedirect("https://\(host)/goto?url=CAES"), "\(host)")
        }
        // And no request goes to them while the results are resolved.
        let session = SearchStubProtocol.session { _ in (302, Data()) }
        let fake = SearchHit(title: "x", url: "https://www.google.evil.test/goto?url=CAES", snippet: "")
        let resolved = await GoogleRedirects.resolve([fake], http: session)
        #expect(resolved == [fake] && SearchStubProtocol.requests.withLock { $0.isEmpty })
        // The same for the redirect of DuckDuckGo's own results.
        #expect(SearchResultsParser.resultAddress("//evilduckduckgo.com/l/?uddg=https%3A%2F%2Fa.test%2F") == "https://evilduckduckgo.com/l/?uddg=https%3A%2F%2Fa.test%2F",
                "an address of another domain is left as it is, not unwrapped")
        #expect(SearchResultsParser.resultAddress("//html.duckduckgo.com/l/?uddg=https%3A%2F%2Fa.test%2F") == "https://a.test/")
    }

    // MARK: The key

    @Test func theKeyLivesInTheVaultOfTheAppAndEmptyRemovesIt() {
        let keys = SearchKeys(vault: vault)
        #expect(keys.tinyFish == nil)
        #expect(keys.setTinyFish("  tf-123 \n"))
        #expect(keys.tinyFish == "tf-123")
        #expect(vault.get("search-tinyfish") == "tf-123" && SearchKeys.tinyFishAccount == "search-tinyfish")
        #expect(SearchKeys(vault: vault).tinyFish == "tf-123", "one key for the whole app")
        #expect(keys.setTinyFish("   "))
        #expect(keys.tinyFish == nil && vault.get("search-tinyfish") == nil)
    }

    @Test func anEmptyFieldNeverReachesTheKeychain() {
        let keys = SearchKeys(vault: vault)
        #expect(keys.setTinyFish("tf-123"))
        for typed in ["", "   ", "\n"] {
            #expect(SearchKeyCopy.valueToSave(typed) == nil, "Return on an empty field stores nothing and deletes nothing")
            if let value = SearchKeyCopy.valueToSave(typed) { keys.setTinyFish(value) }
        }
        #expect(keys.tinyFish == "tf-123")
        #expect(SearchKeyCopy.valueToSave(" abc ") == "abc")
    }

    @Test func resetRemovesTheKeyWithTheProvidersKeys() {
        #expect(ResetPlan.providerAccounts.contains(SearchKeys.tinyFishAccount))
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
