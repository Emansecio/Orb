import Foundation
import os
import Testing
@testable import Orb

// `refreshConnections` reads slowly (the Keychain, then `claude auth status`), and several of them can overlap with a sign-out
// or a key change. What happened meanwhile must not be undone by a result that was read earlier. Nothing here touches the
// real Keychain, ChatGPT's session or the `claude` CLI: the sources are fakes.

@MainActor
final class ConnectionsRefreshTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbConnections-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    /// Stands in for `claude auth status`: the first `held` calls wait until released, the rest answer at once.
    private final class FakeStatus: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (calls: 0, waiting: [CheckedContinuation<Void, Never>]()))
        let held: Int
        let loggedInAfterHold: Bool
        let loggedInAtOnce: Bool
        init(held: Int, loggedInAfterHold: Bool, loggedInAtOnce: Bool) {
            self.held = held
            self.loggedInAfterHold = loggedInAfterHold
            self.loggedInAtOnce = loggedInAtOnce
        }
        var calls: Int { state.withLock { $0.calls } }
        func read() async -> ClaudeCodeStatus {
            let index = state.withLock { state in defer { state.calls += 1 }; return state.calls }
            guard index < held else { return ClaudeCodeStatus(isInstalled: true, isLoggedIn: loggedInAtOnce) }
            await withCheckedContinuation { continuation in state.withLock { $0.waiting.append(continuation) } }
            return ClaudeCodeStatus(isInstalled: true, isLoggedIn: loggedInAfterHold)
        }
        func release() {
            let waiting = state.withLock { state in defer { state.waiting = [] }; return state.waiting }
            waiting.forEach { $0.resume() }
        }
        /// Releases only the call that has waited longest.
        func releaseOldest() {
            let oldest = state.withLock { $0.waiting.isEmpty ? nil : $0.waiting.removeFirst() }
            oldest?.resume()
        }
    }

    /// The keys "in the Keychain" of a test: read by `keyedProviders`, written by `storeKey`.
    private final class FakeKeys: Sendable {
        private let keys: OSAllocatedUnfairLock<Set<ProviderKind>>
        init(_ keys: Set<ProviderKind>) { self.keys = OSAllocatedUnfairLock(initialState: keys) }
        var all: Set<ProviderKind> { keys.withLock { $0 } }
        func store(_ key: String, _ kind: ProviderKind) {
            keys.withLock { if key.isEmpty { $0.remove(kind) } else { $0.insert(kind) } }
        }
    }

    private func model(keys: FakeKeys, status: FakeStatus) -> AppModel {
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, devRun: false)
        model.connectionSources = ConnectionSources(keyedProviders: { keys.all }, storeKey: { keys.store($0, $1) },
                                                    hasChatGPTCredential: { false }, signOutOfChatGPT: {},
                                                    claudeCodeStatus: { await status.read() })
        model.providers = [ProviderAccount(kind: .claudeCode), ProviderAccount(kind: .openai)]
        return model
    }

    @Test func aSignOutDuringARefreshIsNotUndoneByIt() async {
        let status = FakeStatus(held: 1, loggedInAfterHold: true, loggedInAtOnce: true)
        let model = model(keys: FakeKeys([.openai]), status: status)
        let refresh = Task { await model.refreshConnections() }
        await waitUntil("the refresh to be waiting for Claude Code") { status.calls == 1 }

        model.signOut(.openai) // the key was read before this, and is stale now
        status.release()
        await refresh.value

        #expect(!model.connected.contains(.openai))
        #expect(model.connected.contains(.claudeCode))
    }

    @Test func aSlowRefreshDoesNotOverwriteANewerOne() async {
        let status = FakeStatus(held: 1, loggedInAfterHold: true, loggedInAtOnce: false)
        let model = model(keys: FakeKeys([]), status: status)
        let slow = Task { await model.refreshConnections() }
        await waitUntil("the first refresh to be waiting") { status.calls == 1 }

        await model.refreshConnections() // started later, answers at once: Claude Code is signed out
        #expect(!model.connected.contains(.claudeCode))
        status.release()
        await slow.value

        #expect(!model.connected.contains(.claudeCode))
        #expect(!model.claudeCode.isLoggedIn)
        #expect(model.hasCheckedConnections)
    }

    @Test func aKeySavedAfterASignOutIsKept() async {
        let status = FakeStatus(held: 0, loggedInAfterHold: false, loggedInAtOnce: false)
        let model = model(keys: FakeKeys([.openai]), status: status)
        model.signOut(.openai)
        #expect(!model.connected.contains(.openai))
        model.connectionSources.storeKey("sk-test", .openai) // not `setKey`: that would also load models over the network
        await model.refreshConnections() // begins after the sign-out, so it reads what is stored
        #expect(model.connected.contains(.openai))
    }

    @Test func anOutdatedRefreshReturnsOnlyOnceTheNewestHasPublished() async throws {
        let status = FakeStatus(held: 2, loggedInAfterHold: true, loggedInAtOnce: true)
        let model = model(keys: FakeKeys([]), status: status)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let first = Task { await model.refreshConnections(); returned.withLock { $0 = true } }
        await waitUntil("the first refresh to be waiting") { status.calls == 1 }
        let second = Task { await model.refreshConnections() }
        await waitUntil("the second refresh to be waiting") { status.calls == 2 }

        status.releaseOldest() // the outdated one has its answer, the newest does not
        try await Task.sleep(for: .milliseconds(150))
        #expect(!returned.withLock { $0 }, "the outdated refresh returned before the newest published")
        #expect(!model.connected.contains(.claudeCode))

        status.releaseOldest()
        await first.value
        #expect(model.connected.contains(.claudeCode)) // what its caller reads after the await
        #expect(model.claudeCode.isLoggedIn)
        await second.value
    }
}
