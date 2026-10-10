import Foundation
import Testing
@testable import Orb

/// `web_search` through the real browsers, against the real DuckDuckGo and Google. A search page that asks for a person (a captcha,
/// a consent page) is not a failure of the tool: it must say so (`SearchBlocked`) instead of inventing results.
@Suite(.serialized)
struct RealBrowserSearchTests {
    static func search(_ engine: BrowserEngineKind, _ provider: SearchProvider, query: String = "swift programming language") async throws -> String? {
        await RealBrowsers.gate.lock()
        let profiles = FileManager.default.temporaryDirectory.appending(path: "OrbRealSearch-\(UUID().uuidString)")
        let hub = BrowserHub(profilesDirectory: profiles, locate: { RealBrowsers.status($0) })
        let botID = UUID()
        defer { try? FileManager.default.removeItem(at: profiles) }
        defer { Task { await RealBrowsers.gate.unlock() } }
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory, botID: botID)
        context.browser = BrowserAccess(hub: hub, engine: engine, searchProvider: provider)
        var report: String?
        do {
            let start = ContinuousClock.now
            report = try await WebSearchTool().run(.object(["query": .string(query), "count": .number(5)]), context: context)
            print("[\(engine.rawValue)/\(provider.rawValue)] web_search in \(start.duration(to: .now)):\n\(report ?? "")")
        } catch let blocked as SearchBlocked {
            print("[\(engine.rawValue)/\(provider.rawValue)] blocked, as it should say: \(blocked.message)")
        } catch {
            await hub.closeAll()
            throw error
        }
        await hub.closeAll()
        return report
    }

    /// The report has real results: a numbered list with addresses.
    static func expectResults(_ report: String?, provider: String) {
        guard let report else { return } // blocked: said so
        #expect(report.contains("(\(provider))"), "\(report)")
        #expect(!report.contains("no results found"), "\(report)")
        #expect(report.contains("1. ") && report.contains("https://"), "\(report)")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.chrome)), .timeLimit(.minutes(3))) func chromeSearchesDuckDuckGo() async throws {
        Self.expectResults(try await Self.search(.chrome, .duckduckgo), provider: "DuckDuckGo")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.chrome)), .timeLimit(.minutes(3))) func chromeSearchesGoogle() async throws {
        Self.expectResults(try await Self.search(.chrome, .google), provider: "Google")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.obscura)), .timeLimit(.minutes(3))) func obscuraSearchesDuckDuckGo() async throws {
        Self.expectResults(try await Self.search(.obscura, .duckduckgo), provider: "DuckDuckGo")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.obscura)), .timeLimit(.minutes(3))) func obscuraSearchesGoogle() async throws {
        Self.expectResults(try await Self.search(.obscura, .google), provider: "Google")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.cloak)), .timeLimit(.minutes(3))) func cloakSearchesDuckDuckGo() async throws {
        Self.expectResults(try await Self.search(.cloak, .duckduckgo), provider: "DuckDuckGo")
    }

    @Test(.enabled(if: RealBrowsers.isReady(.cloak)), .timeLimit(.minutes(3))) func cloakSearchesGoogle() async throws {
        Self.expectResults(try await Self.search(.cloak, .google), provider: "Google")
    }
}
