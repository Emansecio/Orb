import Foundation
import os
import Testing
@testable import Orb

/// Answers each address with a redirect or a page, keyed by the full address, so parallel tests (each with its own hosts) don't interfere.
final class RedirectStubProtocol: URLProtocol {
    enum Answer: Sendable {
        case redirect(String)
        case page(String)
    }

    static let answers = OSAllocatedUnfairLock<[String: Answer]>(initialState: [:])

    static func session(_ table: [String: Answer]) -> URLSession {
        answers.withLock { $0.merge(table) { $1 } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.answers.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch answer {
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            // When the redirect is followed the session has already stopped this load; when it is refused, the redirect's own
            // response is the answer and has to end like any other.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .page(let text):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class WebRedirectTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func fetch(_ address: String, _ table: [String: RedirectStubProtocol.Answer]) async throws -> String {
        let tool = WebFetchTool(session: RedirectStubProtocol.session(table), cache: WebPageCache())
        return try await workspace.run(tool, ["url": .string(address)])
    }

    @Test func redirectWithinTheSameHostIsFollowed() async throws {
        let output = try await fetch("https://same.redirect.test/a", [
            "https://same.redirect.test/a": .redirect("https://SAME.redirect.test./b"),
            "https://SAME.redirect.test./b": .page("chegou"),
        ])
        #expect(output.contains("chegou"))
    }

    @Test func httpUpgradedToHttpsOnTheSameHostIsFollowed() async throws {
        let output = try await fetch("http://up.redirect.test/a", [
            "http://up.redirect.test/a": .redirect("https://up.redirect.test/a"),
            "https://up.redirect.test/a": .page("seguro"),
        ])
        #expect(output.contains("seguro"))
    }

    @Test func redirectToAnotherHostIsNotFollowedAndSaysWhere() async throws {
        let error = await #expect(throws: ToolError.self) {
            _ = try await self.fetch("https://open.redirect.test/go", [
                "https://open.redirect.test/go": .redirect("https://evil.redirect.test/steal"),
                "https://evil.redirect.test/steal": .page("NÃO DEVIA CHEGAR"),
            ])
        }
        let message = try #require(error?.message)
        #expect(message.contains("https://evil.redirect.test/steal"))
        #expect(message.contains("web_fetch"))
        #expect(!message.contains("NÃO DEVIA CHEGAR"))
    }

    @Test func redirectToLocalhostIsNotFollowed() async throws {
        let error = await #expect(throws: ToolError.self) {
            _ = try await self.fetch("https://lan.redirect.test/go", [
                "https://lan.redirect.test/go": .redirect("http://localhost:8080/admin"),
                "http://localhost:8080/admin": .page("interno"),
            ])
        }
        #expect(error?.message.contains("http://localhost:8080/admin") == true)
    }

    @Test func httpsDowngradedToHttpIsRefused() async throws {
        let error = await #expect(throws: ToolError.self) {
            _ = try await self.fetch("https://down.redirect.test/a", [
                "https://down.redirect.test/a": .redirect("http://down.redirect.test/a"),
                "http://down.redirect.test/a": .page("sem criptografia"),
            ])
        }
        #expect(error?.message.contains("http://down.redirect.test/a") == true)
    }

    @Test func policyComparesHostsWithoutCaseOrTrailingDot() {
        func follows(_ from: String, _ to: String) -> Bool { WebRedirectPolicy.follows(from: URL(string: from), to: URL(string: to)) }
        #expect(follows("https://a.dev/x", "https://A.DEV./y"))
        #expect(follows("http://a.dev", "https://a.dev"))
        #expect(!follows("https://a.dev", "http://a.dev"))
        #expect(!follows("https://a.dev", "https://b.dev"))
        #expect(!follows("https://a.dev", "https://sub.a.dev"))
        #expect(!follows("https://a.dev", "https://a.dev.evil.com"))
    }
}
