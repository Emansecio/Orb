import Foundation
import os
import Testing
@testable import Orb

/// A browser whose close waits until the test lets it finish.
private final class SlowClosingDriver: BrowserDriver, @unchecked Sendable {
    private struct Gate {
        var released = false
        var waiting: CheckedContinuation<Void, Never>?
    }

    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    let closeStarted = OSAllocatedUnfairLock(initialState: false)

    func release() {
        let waiting = gate.withLock { gate -> CheckedContinuation<Void, Never>? in
            gate.released = true
            defer { gate.waiting = nil }
            return gate.waiting
        }
        waiting?.resume()
    }

    func close() async throws {
        closeStarted.withLock { $0 = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = gate.withLock { gate -> Bool in
                if gate.released { return true }
                gate.waiting = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open(_ url: String) async throws -> BrowserPage { BrowserPage(url: url, title: "") }
    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot { BrowserSnapshot(url: "", tree: "", refs: [:]) }
    func click(_ ref: String) async throws {}
    func fill(_ ref: String, text: String) async throws {}
    func select(_ ref: String, value: String) async throws {}
    func press(_ key: String) async throws {}
    func scroll(_ direction: BrowserScrollDirection, pixels: Int) async throws {}
    func read() async throws -> BrowserReadout { BrowserReadout(url: "", content: "") }
    func screenshot(to file: URL) async throws {}
    func back() async throws -> BrowserPage { BrowserPage(url: "", title: "") }
    func tabs() async throws -> [BrowserTab] { [] }
    func newTab(_ url: String?) async throws {}
    func selectTab(_ id: String) async throws {}
    func closeTab(_ id: String?) async throws {}
    func attribute(_ name: String, of ref: String) async throws -> String? { nil }
    func evaluate(_ script: String) async throws -> String { "" }
    func currentURL() async throws -> String? { nil }
    func setHeaded(_ headed: Bool) async throws -> BrowserPage { BrowserPage(url: "", title: "") }
}

struct BrowserHubReplacementTests {
    @Test func aCallThatFindsTheNewBrowserWaitsForTheOldOnesCloseToFinish() async throws {
        let old = SlowClosingDriver(), fresh = SlowClosingDriver()
        let made = OSAllocatedUnfairLock(initialState: 0)
        let hub = BrowserHub(profilesDirectory: nil, locate: { BrowserStatus(agentBrowser: "/x/ab") }, makeDriver: { _ in
            made.withLock { count in
                count += 1
                return count == 1 ? old : fresh
            }
        })
        let botID = UUID()
        _ = try await hub.session(botID: botID, mode: .background)
        hub.setProxy("socks5://127.0.0.1:1080", botID: botID)

        let returned = OSAllocatedUnfairLock(initialState: 0)
        let first = Task {
            _ = try await hub.session(botID: botID, mode: .background)
            returned.withLock { $0 += 1 }
        }
        for _ in 0..<200 where !old.closeStarted.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(old.closeStarted.withLock { $0 })
        // The second call finds the new session already installed: it still waits, because the close names the same session.
        let second = Task {
            _ = try await hub.session(botID: botID, mode: .background)
            returned.withLock { $0 += 1 }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(returned.withLock { $0 } == 0, "no call returns while the old browser is still closing")

        old.release()
        try await first.value
        try await second.value
        #expect(returned.withLock { $0 } == 2)
    }
}
