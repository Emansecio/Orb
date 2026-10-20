import Foundation
import os

/// What a process needs to be the same as the one a turn would start: anything here that differs means a new process.
struct ClaudePipeSetup: Sendable, Equatable {
    var model: String
    var effort: String?
    var cacheTTL: String?
    var tools: [ToolSpec]
    var toolChoice: ToolChoice
}

/// Live CLI processes whose turn ended, kept per conversation so the next message goes to the SAME process: it still holds the
/// whole prompt exactly as the provider's cache saw it (with the CLI's own trailing blocks), which a process started over a
/// replayed session file cannot reproduce. The clients live one turn, so what outlives them is kept here.
///
/// At most `limit` processes stay open (the least recently used is closed first) and each one expires after `timeout` (see
/// `ClaudePipeIdlePool.defaultTimeout`). A conversation has at most one.
final class ClaudePipeIdlePool: @unchecked Sendable {
    /// Open processes: a few, because each one is a Node process of a hundred-odd MB.
    static let defaultLimit = 4
    /// Past this the provider's cache of the prompt is cold anyway (5 min without the one-hour option, an hour with), and a
    /// process nobody comes back for should not stay: 20 minutes covers a user reading, thinking and typing.
    static let defaultTimeout: Duration = .seconds(20 * 60)

    static let shared = ClaudePipeIdlePool()

    struct Entry {
        var run: ClaudePipeRun
        /// What the process has seen: the messages of the last call and the assistant's answer to them.
        var seen: [ChatMessage]
        var setup: ClaudePipeSetup
        var expiry: Task<Void, Never>
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: [(conversation: String, entry: Entry)]())

    init(limit: Int = ClaudePipeIdlePool.defaultLimit) { self.limit = max(1, limit) }

    /// Takes the conversation's process out of the pool (the caller decides to use or end it).
    func take(_ conversation: String) -> Entry? {
        let entry = state.withLock { list -> Entry? in
            guard let index = list.firstIndex(where: { $0.conversation == conversation }) else { return nil }
            return list.remove(at: index).entry
        }
        entry?.expiry.cancel()
        return entry
    }

    /// Keeps `run` for the conversation's next message, ending a process it replaces and the oldest past the limit.
    func put(_ conversation: String, run: ClaudePipeRun, seen: [ChatMessage], setup: ClaudePipeSetup, timeout: Duration) {
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.expire(run)
        }
        let dropped = state.withLock { list -> [Entry] in
            var dropped: [Entry] = []
            list.removeAll { item in
                guard item.conversation == conversation else { return false }
                dropped.append(item.entry)
                return true
            }
            list.append((conversation, Entry(run: run, seen: seen, setup: setup, expiry: expiry)))
            while list.count > limit { dropped.append(list.removeFirst().entry) }
            return dropped
        }
        for entry in dropped { Self.end(entry) }
    }

    /// Ends the conversation's process (it was forgotten, cleared or the Orb deleted).
    func stop(_ conversation: String) {
        if let entry = take(conversation) { Self.end(entry) }
    }

    /// Ends every process (the app is quitting).
    func stopAll() {
        let all = state.withLock { list in defer { list.removeAll() }; return list.map(\.entry) }
        for entry in all { Self.end(entry) }
    }

    var count: Int { state.withLock { $0.count } }

    private func expire(_ run: ClaudePipeRun) {
        let entry = state.withLock { list -> Entry? in
            guard let index = list.firstIndex(where: { $0.entry.run === run }) else { return nil }
            return list.remove(at: index).entry
        }
        if let entry { Self.end(entry) }
    }

    private static func end(_ entry: Entry) {
        entry.expiry.cancel()
        entry.run.stop(interrupt: false)
    }
}
